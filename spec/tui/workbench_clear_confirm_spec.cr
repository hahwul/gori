require "../spec_helper"
require "../support/fake_host"
require "file_utils"

include Gori::Tui

# The JWT, Cookie and Decoder clears drop editor text AND each editor's undo stack
# (`TextArea#set_text`), so a stray key used to wipe authored work with no recovery. They ask
# first now, the way `notes_clear` does (#1274 WP1) — and only when there is something to lose.
private CLEAR_CA = File.tempname("gori-clear-ca")

private def with_clear_session(&)
  root = File.tempname("gori-clear")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("clear")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(CLEAR_CA), Gori::Verbs.registry, project)
  begin
    yield FakeHost.new(session)
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe "workbench clears ask first" do
  it "asks before clearing a JWT session with a token in it, and not an empty one" do
    with_clear_session do |host|
      ctl = JwtController.new(host)
      ctl.clear_all
      host.confirms.should be_empty
      ctl.jwt_from_text("eyJhbGciOiJIUzI1NiJ9.e30.x")
      ctl.clear_all
      host.confirms.map(&.[0]).should eq(["CLEAR SESSION"])
    end
  end

  it "asks before clearing a Cookie session with a cookie in it, and not an empty one" do
    with_clear_session do |host|
      ctl = CookieController.new(host)
      ctl.clear_all
      host.confirms.should be_empty
      ctl.cookie_from_text("eyJ1c2VyIjoxfQ.am71Yg.sig")
      ctl.clear_all
      host.confirms.map(&.[0]).should eq(["CLEAR SESSION"])
    end
  end

  it "asks before clearing Decoder input, and not an empty one" do
    with_clear_session do |host|
      ctl = DecoderController.new(host)
      ctl.clear_all
      host.confirms.should be_empty
      ctl.decoder_from_text("aGVsbG8=")
      ctl.clear_all
      host.confirms.map(&.[0]).should eq(["CLEAR INPUT"])
    end
  end

  it "keeps every workbench clear on one menu letter, off the menu's navigation keys" do
    %w[jwt.clear cookie.clear decoder.clear notes.clear].each do |id|
      Gori::Verbs.registry[id].menu_key.should eq('K'), id
      Gori::Verbs.registry[id].group.should eq(:danger), id
    end
  end
end
