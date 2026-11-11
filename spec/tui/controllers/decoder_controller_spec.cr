require "../../spec_helper"
require "../../support/fake_host"
require "file_utils"

include Gori::Tui

private DECODER_CTL_CA = File.tempname("gori-decoder-ctl-ca")
Spec.after_suite { FileUtils.rm_rf(DECODER_CTL_CA) }

private def with_decoder_controller(&)
  root = File.tempname("gori-decoder-ctl")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("decoder")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(DECODER_CTL_CA), Gori::Verbs.registry, project)
  begin
    yield DecoderController.new(FakeHost.new(session))
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# `Send selection to → Decoder` appended a conversion beside the blank one the tab opens
# with, and a conversion with text and no chain was labelled `empty`: the strip read
# `1:empty  2:empty` with 35 bytes in the second.
describe "DecoderController#decoder_from_text" do
  it "fills the blank conversion instead of leaving it behind" do
    with_decoder_controller do |ctl|
      ctl.decoder_from_text("Date: Wed, 11 Nov 2026")
      ctl.subtab_labels.should eq(["1:Date: Wed, 11 Nov 2…"])
      ctl.decoder_from_text("second")
      ctl.subtab_labels.should eq(["1:Date: Wed, 11 Nov 2…", "2:second"])
    end
  end

  it "appends beside a conversion that holds a chain or a name" do
    with_decoder_controller do |ctl|
      ctl.load_chain("b64", "base64")
      ctl.decoder_from_text("abc")
      ctl.subtab_labels.size.should eq(2)
    end
  end

  it "appends beside whitespace the operator typed, and beside an input they can undo back to" do
    with_decoder_controller do |ctl|
      ctl.editor_enter_insert.should be_true
      ctl.paste_text("  ").should be_true
      ctl.decoder_from_text("abc")
      ctl.subtab_labels.should eq(["1:empty", "2:abc"])

      ctl.decoder_new
      ctl.editor_enter_insert.should be_true
      ctl.paste_text("x").should be_true
      ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Backspace))
      ctl.decoder_from_text("def")
      ctl.subtab_labels.should eq(["1:empty", "2:abc", "3:empty", "4:def"])
    end
  end

  it "reads only the front of a long line, and draws control bytes as spaces" do
    with_decoder_controller do |ctl|
      ctl.decoder_from_text("  a\tb\u0001c" + "x" * 50_000)
      ctl.subtab_labels.should eq(["1:a b c#{"x" * 14}…"])
    end
  end

  it "labels a conversion by its chain first, then its input, then empty" do
    with_decoder_controller do |ctl|
      ctl.subtab_labels.should eq(["1:empty"])
      ctl.decoder_from_text("\n  hello  \nworld")
      ctl.subtab_labels.should eq(["1:hello"])
      ctl.load_chain("b64", "base64")
      ctl.subtab_labels.last.should_not contain("hello")
    end
  end
end
