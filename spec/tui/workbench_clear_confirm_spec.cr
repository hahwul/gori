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
      ctl.session_from_text("eyJhbGciOiJIUzI1NiJ9.e30.x")
      ctl.clear_all
      host.confirms.map(&.[0]).should eq(["CLEAR SESSION"])
    end
  end

  it "asks before clearing a Cookie session with a cookie in it, and not an empty one" do
    with_clear_session do |host|
      ctl = CookieController.new(host)
      ctl.clear_all
      host.confirms.should be_empty
      ctl.session_from_text("eyJ1c2VyIjoxfQ.am71Yg.sig")
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

private class DeferredCloseHost < FakeHost
  property pending : Proc(Nil)?

  def confirm(title : String, message : String, *, confirm_label : String, danger : Bool,
              return_to : Symbol = :none, &action : -> Nil) : Nil
    @confirms << {title, message}
    @pending = action
  end
end

describe "workbench single-session closes ask before discarding work" do
  {% for tool in [JwtController, CookieController] %}
    it "protects {{ tool.id }} text while keeping empty closes immediate" do
      with_clear_session do |base|
        host = DeferredCloseHost.new(base.session)
        ctl = {{ tool }}.new(host)
        ctl.close_session
        host.pending.should be_nil
        ctl.session_from_text("authored text")
        ctl.close_session
        host.pending.should_not be_nil
        ctl.subtab_labels.first.should_not eq("1:empty")
        host.pending.not_nil!.call
        ctl.subtab_labels.should eq(["1:empty"])
      end
    end
  {% end %}

  it "keeps Decoder input until confirmation and closes the original session after a switch" do
    with_clear_session do |base|
      host = DeferredCloseHost.new(base.session)
      ctl = DecoderController.new(host)
      ctl.decoder_close
      host.pending.should be_nil
      ctl.decoder_from_text("original")
      ctl.decoder_close
      host.pending.should_not be_nil
      ctl.decoder_new
      ctl.decoder_from_text("keep me")
      host.pending.not_nil!.call
      ctl.subtab_labels.should eq(["1:keep me"])
    end
  end

  it "protects a named comparison until confirmation" do
    with_clear_session do |base|
      host = DeferredCloseHost.new(base.session)
      ctl = ComparerController.new(host)
      ctl.comparer_close
      host.pending.should be_nil
      ctl.view.name = "keep pair"
      ctl.comparer_close
      host.pending.should_not be_nil
      ctl.view.name.should eq("keep pair")
      host.pending.not_nil!.call
      ctl.view.name.should be_nil
    end
  end
end

describe "workbench closes protect work outside the visible input" do
  {% for tool in [JwtController, CookieController] %}
    it "protects a {{ tool.id }} secret with an empty input" do
      with_clear_session do |base|
        host = DeferredCloseHost.new(base.session)
        ctl = {{ tool }}.new(host)
        ctl.@sessions.first.secret = "authored secret"
        ctl.close_session
        host.pending.should_not be_nil
        ctl.@sessions.first.secret.should eq("authored secret")
      end
    end
  {% end %}

  it "protects Decoder undo history even when the input is empty" do
    with_clear_session do |base|
      host = DeferredCloseHost.new(base.session)
      ctl = DecoderController.new(host)
      input = ctl.@sessions.first.input
      input.insert('x')
      input.backspace
      input.text.should be_empty
      input.undoable?.should be_true
      ctl.decoder_close
      host.pending.should_not be_nil
      ctl.@sessions.first.input.should be(input)
    end
  end
end
