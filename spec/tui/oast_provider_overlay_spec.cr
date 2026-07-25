require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def skey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

private def stype(ov : OastProviderOverlay, s : String) : Nil
  s.each_char { |c| ov.handle_key(skey(Termisu::Input::Key::LowerA, c)) }
end

private def config(*, id = "42", name = "My Provider", kind = Gori::Oast::ProviderKind::Boast,
                   host = "https://boast.example", token = "my-token", enabled = true,
                   scope = "project") : Gori::Oast::ProviderConfig
  Gori::Oast::ProviderConfig.new(id, name, kind.label, host, token, enabled, scope)
end

describe Gori::Tui::OastProviderOverlay do
  it "defaults to Interactsh, project scope, and cycles type with ←/→" do
    ov = OastProviderOverlay.adding
    ov.kind.should eq(Gori::Oast::ProviderKind::Interactsh)
    ov.scope.should eq("project")
    ov.editing?.should be_false

    ov.handle_key(skey(Termisu::Input::Key::Down)).should eq(:stay)  # scope row
    ov.handle_key(skey(Termisu::Input::Key::Down)).should eq(:stay)  # type row
    ov.handle_key(skey(Termisu::Input::Key::Right)).should eq(:stay) # Interactsh -> CustomHttp
    ov.kind.should eq(Gori::Oast::ProviderKind::CustomHttp)
    ov.handle_key(skey(Termisu::Input::Key::Right)).should eq(:stay) # CustomHttp -> WebhookSite
    ov.kind.should eq(Gori::Oast::ProviderKind::WebhookSite)
    ov.handle_key(skey(Termisu::Input::Key::Left)).should eq(:stay) # WebhookSite -> CustomHttp
    ov.kind.should eq(Gori::Oast::ProviderKind::CustomHttp)
  end

  it "cycles scope between project and global with ←/→" do
    ov = OastProviderOverlay.adding
    ov.scope.should eq("project")
    ov.handle_key(skey(Termisu::Input::Key::Down)) # scope row
    ov.handle_key(skey(Termisu::Input::Key::Right))
    ov.scope.should eq("global")
    ov.handle_key(skey(Termisu::Input::Key::Right)) # wraps back
    ov.scope.should eq("project")
  end

  it "seeds edit mode from an existing (project-scope) provider config" do
    ov = OastProviderOverlay.editing(config)
    ov.editing?.should be_true
    ov.edit_id.should eq("42")
    ov.edit_scope.should eq("project")
    ov.scope.should eq("project")
    ov.provider_name.should eq("My Provider")
    ov.kind.should eq(Gori::Oast::ProviderKind::Boast)
    ov.host.should eq("https://boast.example")
    ov.token.should eq("my-token")
  end

  it "seeds edit mode from a global-scope provider config" do
    ov = OastProviderOverlay.editing(config(scope: "global"))
    ov.scope.should eq("global")
    ov.edit_scope.should eq("global")
  end

  it "renders without crashing and maps a click to a row" do
    ov = OastProviderOverlay.adding
    screen = Screen.new(MemoryBackend.new(80, 24))
    area = Rect.new(0, 0, 80, 24)
    ov.render(screen, area)
    box = ov.overlay_box(area).not_nil!
    ov.row_at(box, box.x + 3, box.y + 2).should eq(0) # name row
    ov.row_at(box, box.x + 3, box.y + 3).should eq(1) # scope row
    ov.row_at(box, box.x + 3, box.y + 4).should eq(2) # type row
    ov.row_at(box, box.x + 3, box.y + 7).should eq(5) # save row
  end
end

# Post-migration surface: the Runner no longer owns handle_oast_provider_key /
# click_oast_provider / commit_oast_provider_overlay / @oast_provider_overlay — it opens
# this overlay with OastController#save_provider injected as on_commit and dispatches
# generically (see spec/tui/overlay_dispatch_spec.cr for the shared contract).
describe "Gori::Tui::OastProviderOverlay — Overlay seam" do
  it "exposes the chrome the collapsed Runner ladders used to hard-code" do
    OverlayHarness.new(OastProviderOverlay.adding).assert_chrome(OverlayKind::OastProvider, "OAST PROVIDER")
  end

  it "carries the global-vs-project scope field through to the commit closure" do
    # The scope row decides settings.json vs the project DB — the one field whose loss
    # would silently write a provider to the wrong place.
    ov = OastProviderOverlay.adding
    h = OverlayHarness.new(ov)
    saved = [] of {String, String, String}
    h.on_commit do
      saved << {ov.provider_name, ov.scope, ov.host}
      true
    end

    h.type("my-oast")
    h.press(Termisu::Input::Key::Down)  # → scope
    h.press(Termisu::Input::Key::Right) # project → global
    3.times { h.press(Termisu::Input::Key::Down) }
    ov.on_save_row?.should be_false # host → token → Save
    h.press(Termisu::Input::Key::Down)
    ov.on_save_row?.should be_true
    h.press(Termisu::Input::Key::Enter).should eq(:closed)

    saved.should eq([{"my-oast", "global", "https://oast.pro"}])
  end

  it "keeps the form open when the controller rejects it (name/host required)" do
    ov = OastProviderOverlay.adding
    ov.valid?.should be_false # no name yet
    h = OverlayHarness.new(ov, commit: false)
    ov.set_selected(5) # Save row
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.commits.should eq(1) # save_provider DID run — it just returned false
  end

  it "esc cancels and a click-away dismisses — neither persists anything" do
    h = OverlayHarness.new(OastProviderOverlay.adding)
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    h.commits.should eq(0)

    away = OverlayHarness.new(OastProviderOverlay.adding)
    away.overlay.handle_click(away.area, 0, 0).should eq(:cancel) # raw: not a silent save
    away.click(0, 0).should eq(:closed)
    away.commits.should eq(0)
  end

  it "click selects a row, and a click on Save commits" do
    ov = OastProviderOverlay.editing(config)
    h = OverlayHarness.new(ov)
    # Rows start at box.y + 2; Save is index 5.
    h.click_in_box(3, 3).should eq(:open) # scope row
    h.click_in_box(3, 7).should eq(:closed)
    h.commits.should eq(1)
  end

  it "moves the selected field with the wheel" do
    ov = OastProviderOverlay.adding
    OverlayHarness.new(ov).wheel(2 * 3) # 6 notches down clamps onto Save
    ov.on_save_row?.should be_true
  end

  it "routes IME preedit to the focused text row" do
    h = OverlayHarness.new(OastProviderOverlay.adding)
    h.preedit("preedithere")
    h.rendered?("preedithere").should be_true
  end
end
