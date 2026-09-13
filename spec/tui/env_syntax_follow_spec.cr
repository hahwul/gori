require "../spec_helper"
require "file_utils"

# A running TUI FOLLOWS a token-grammar switch made in another terminal.
#
# `EnvSyntaxSeam` used to only ADOPT the file's grammar, and only on an env-section save. That left
# the session reading `$ENV.KEY` while the project's own rows were still spelled bare — every draft
# and every rule replacement in the workbench became literal text, silently, and the operator's only
# clue was that their tokens had stopped resolving.
#
# So the seam FOLLOWS instead: adopt, re-spell this project, and say what it did on the three
# surfaces the open-time migration already uses. The Runner's `follow_env_syntax` is two lines over
# this pair, and it is called from the peer tick and from both env-section writes.
private CA_PATH = File.tempname("gori-tui-env-syntax-ca")

private def with_syntax_session(&)
  prev_home = ENV["GORI_HOME"]?
  prev_cfg = ENV["GORI_CONFIG"]?
  snapshot = Gori::Settings.export_document(Gori::Settings::SECTION_KEYS)
  root = File.tempname("gori-tui-env-syntax")
  Dir.mkdir_p(root)
  settings_path = File.join(root, "settings.json")
  session = nil.as(Gori::Session?)
  begin
    ENV["GORI_HOME"] = root
    ENV.delete("GORI_CONFIG")
    Gori::Settings.path_override = nil
    Gori::Settings.env_prefix = Gori::Settings::DEFAULT_ENV_PREFIX
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.project_env_vars = [] of {String, String}
    File.write(settings_path, %({"env":{"syntax":"bare"}}))
    Gori::Settings.load
    project = Gori::ProjectRegistry.new(root).temp("envsyntax")
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      Gori::Proxy::Tls::CertAuthority.load_or_create(CA_PATH), Gori::Verbs.registry, project)
    yield session, settings_path
  ensure
    session.try(&.close)
    Gori::Settings.env_syntax = Gori::Env::Syntax::Bare
    Gori::Settings.env_prefix = Gori::Settings::DEFAULT_ENV_PREFIX
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.project_env_vars = [] of {String, String}
    Gori::Settings.path_override = nil
    Gori::Env.layer = nil
    File.write(settings_path, snapshot)
    Gori::Settings.load
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    prev_cfg ? (ENV["GORI_CONFIG"] = prev_cfg) : ENV.delete("GORI_CONFIG")
    FileUtils.rm_rf(root)
  end
end

describe Gori::Tui::EnvSyntaxSeam do
  it "adopts, re-spells the open project and hands back the notices" do
    with_syntax_session do |session, settings_path|
      store = session.store
      store.set_setting(Gori::Env::PROJECT_VARS_KEY,
        Gori::Env.serialize_vars([{"API", "api.example.com"}]))
      store.insert_extract_rule("token", "", Gori::ExtractKind::Header, "set-cookie")
      rep = store.insert_repeater("https://$API",
        "GET / HTTP/1.1\r\nAuthorization: $token\r\n\r\n".to_slice, false, true, nil, 0)
      store.flush

      # Nothing to follow while the file says what this process already believes — which is every
      # call but the one after a peer's switch.
      Gori::Tui::EnvSyntaxSeam.follow(session).should be_empty

      File.write(settings_path, %({"env":{"syntax":"namespaced"}}))
      lines = Gori::Tui::EnvSyntaxSeam.follow(session)
      lines.should_not be_empty
      lines[0].should contain("re-spelled to $ENV.KEY/$BIND.NAME")
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      # …and the grammar counts as STATED, so the reconcile this pulled was allowed to run at all.
      Gori::Settings.env_syntax_stated?.should be_true

      String.new(store.get_repeater_full(rep).not_nil!.request)
        .should contain("Authorization: $BIND.token\r\n")
      store.get_repeater_full(rep).not_nil!.target.should eq("https://$ENV.API")
      store.setting(Gori::Env::PROJECT_SYNTAX_KEY).should eq("namespaced")

      # A second look is quiet: the file and the process agree now, and the marker says the rows do.
      Gori::Tui::EnvSyntaxSeam.follow(session).should be_empty

      # The notices go in the ring, `:warn` (the bytes in this operator's tabs changed), with a jump
      # to the Project tab — the same three surfaces the open-time announcement uses.
      ring = Gori::Tui::Notifications.new
      Gori::Tui::EnvSyntaxSeam.announce(lines, ring).should eq(lines.first)
      ring.all.size.should eq(lines.size)
      ring.all.first.level.should eq(:warn)
    end
  end

  it "says nothing when the file is unparseable, a peer is mid-write, or the key is absent" do
    with_syntax_session do |session, settings_path|
      File.write(settings_path, "{not json")
      Gori::Tui::EnvSyntaxSeam.follow(session).should be_empty
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)

      # An ABSENT key is a file from before namespaces, and what that means is `Settings.load`'s
      # adoption to settle — not a mid-process re-read's, which would have a stale file flip a live
      # session (and, through the marker, its next project open).
      File.write(settings_path, %({"theme":"gori"}))
      Gori::Tui::EnvSyntaxSeam.follow(session).should be_empty
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)

      # A value this build does not know is a bad file, not a new grammar.
      File.write(settings_path, %({"env":{"syntax":"NAMESPACED!"}}))
      Gori::Tui::EnvSyntaxSeam.follow(session).should be_empty
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
    end
  end
end
