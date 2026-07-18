require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def skey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

private def stype(ov : OastProviderOverlay, s : String) : Nil
  s.each_char { |c| ov.handle_key(skey(Termisu::Input::Key::LowerA, c)) }
end

describe Gori::Tui::OastProviderOverlay do
  it "defaults to Interactsh and cycles type with ←/→" do
    ov = OastProviderOverlay.adding
    ov.kind.should eq(Gori::Oast::ProviderKind::Interactsh)
    ov.editing?.should be_false

    ov.handle_key(skey(Termisu::Input::Key::Down)).should eq(:stay)  # type row
    ov.handle_key(skey(Termisu::Input::Key::Right)).should eq(:stay) # Interactsh -> CustomHttp
    ov.kind.should eq(Gori::Oast::ProviderKind::CustomHttp)
    ov.handle_key(skey(Termisu::Input::Key::Right)).should eq(:stay) # CustomHttp -> WebhookSite
    ov.kind.should eq(Gori::Oast::ProviderKind::WebhookSite)
    ov.handle_key(skey(Termisu::Input::Key::Left)).should eq(:stay) # WebhookSite -> CustomHttp
    ov.kind.should eq(Gori::Oast::ProviderKind::CustomHttp)
  end

  it "seeds edit mode from an existing provider" do
    ov = OastProviderOverlay.editing(42_i64, "My Provider", Gori::Oast::ProviderKind::Boast, "https://boast.example", "my-token")
    ov.editing?.should be_true
    ov.edit_id.should eq(42_i64)
    ov.provider_name.should eq("My Provider")
    ov.kind.should eq(Gori::Oast::ProviderKind::Boast)
    ov.host.should eq("https://boast.example")
    ov.token.should eq("my-token")
  end

  it "renders without crashing and maps a click to a row" do
    ov = OastProviderOverlay.adding
    screen = Screen.new(MemoryBackend.new(80, 24))
    area = Rect.new(0, 0, 80, 24)
    ov.render(screen, area)
    box = ov.overlay_box(area).not_nil!
    ov.row_at(box, box.x + 3, box.y + 2).should eq(0) # name row
    ov.row_at(box, box.x + 3, box.y + 3).should eq(1) # type row
    ov.row_at(box, box.x + 3, box.y + 6).should eq(4) # save row
  end
end
