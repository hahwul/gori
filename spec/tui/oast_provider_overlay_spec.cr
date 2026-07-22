require "../spec_helper"
require "../support/memory_backend"

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
