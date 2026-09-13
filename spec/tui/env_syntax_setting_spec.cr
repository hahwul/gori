require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"
require "../support/fake_context"

# `env.syntax` as the TUI meets it: REPORTED, never switched.
#
# The grammar decides how bytes ALREADY STORED in project DBs, drafts, rule replacements and slot
# headers are read, so switching it has to re-spell them — which is `gori settings env-syntax`'s
# work (global rules there and then, each project at its next open). A TUI key could only write
# the setting, so there is none; what the TUI owes the operator instead is (a) naming the grammar
# in force, and (b) never writing a stale copy of it back over a peer's switch, because the `env`
# section is merged WHOLE and this card saves on every keystroke.

# `Settings.env_syntax=` bumps the highlight rev and the overlay PERSISTS on every mutation, so
# a leaked syntax (or a settings.json written into the real home) would change what every later
# example in the suite thinks a `$KEY` means.
private def with_settings_home(&)
  saved_syntax = Gori::Settings.env_syntax
  saved_prefix = Gori::Settings.env_prefix
  saved_vars = Gori::Settings.env_vars
  prev_home = ENV["GORI_HOME"]?
  dir = File.tempname("gori-env-syntax")
  Dir.mkdir_p(dir)
  ENV["GORI_HOME"] = dir
  begin
    yield
  ensure
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    Gori::Settings.env_syntax = saved_syntax
    Gori::Settings.env_prefix = saved_prefix
    Gori::Settings.env_vars = saved_vars
    FileUtils.rm_rf(dir)
  end
end

# Rewrite the `env` section of the settings file the way a PEER process does — `gori settings
# env-syntax namespaced` in another terminal, or a second gori window's own CLI run. The card in
# this example opened before that landed.
private def peer_writes_syntax(syntax : String) : Nil
  path = Gori::Settings.path
  root = (File.exists?(path) ? JSON.parse(File.read(path)).as_h : {} of String => JSON::Any)
  env = (root["env"]?.try(&.as_h?) || {} of String => JSON::Any).dup
  env["syntax"] = JSON::Any.new(syntax)
  root["env"] = JSON::Any.new(env)
  File.write(path, root.to_json)
end

private def file_syntax : String?
  path = Gori::Settings.path
  return nil unless File.exists?(path)
  JSON.parse(File.read(path))["env"]?.try(&.["syntax"]?).try(&.as_s?)
end

# The card wired the way `Runner#open_settings` wires it, so a var edit really goes through
# `save_env`.
private def env_card(&) : Nil
  ov = Gori::Tui::EnvOverlay.new
  toasts = [] of String
  ov.on_toast = ->(msg : String) { toasts << msg; nil }
  # Mirrors `Runner#save_env` line for line, INCLUDING the order: adopt the file's grammar (a
  # peer may have switched it), then write the vars and the prefix. It deliberately carries no
  # grammar of its own — the card holds no working copy to hand back.
  ov.on_save = -> {
    Gori::Tui::EnvSyntaxSeam.refresh_from_disk
    prefix, vars = ov.to_config
    Gori::Settings.env_prefix = prefix
    Gori::Settings.env_vars = vars.dup
    Gori::Settings.save
  }
  yield OverlayHarness.new(ov), ov, toasts
end

describe Gori::Tui::EnvOverlay do
  it "carries the live spelling in the border meta, and offers no grammar key" do
    with_settings_home do
      Gori::Settings.env_syntax = Gori::Env::Syntax::Bare
      Gori::Settings.env_vars = [{"HOST", "api.test"}]
      env_card do |h, ov, toasts|
        h.assert_chrome(Gori::Tui::OverlayKind::Env, "ENVIRONMENT")
        ov.hint.should_not contain("syntax")
        # The meta is the only line on this card that says which grammar the editors two tabs
        # over are reading these rows under (`HOST → api.test` reads identically either way).
        h.rendered?("global · $KEY · 1 var").should be_true
        h.rendered?("syntax bare").should be_true
        # …and the row offers only the key it still owns: the sigil. No `s toggle` beside it.
        h.rendered?("p edit").should be_true
        h.rendered?("s toggle").should be_false

        # `s` is not a key here: it neither flips the setting nor says anything.
        h.press(Termisu::Input::Key::LowerS, 's').should eq(:open)
        Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
        toasts.should be_empty
        file_syntax.should be_nil # nothing was written, either
      end
    end
  end

  it "reports the grammar live, so a CLI switch shows up without reopening the card" do
    with_settings_home do
      Gori::Settings.env_syntax = Gori::Env::Syntax::Bare
      Gori::Settings.env_vars = [{"HOST", "api.test"}]
      env_card do |h, ov, _|
        h.rendered?("syntax bare").should be_true
        Gori::Settings.env_syntax = Gori::Env::Syntax::Namespaced # what the CLI verb assigns
        ov.syntax.should eq(Gori::Env::Syntax::Namespaced)
        h.rendered?("syntax namespaced").should be_true
        h.rendered?("global · $ENV.KEY · 1 var").should be_true
      end
    end
  end

  it "keeps to_config a 2-tuple, with the syntax read off the live setting" do
    with_settings_home do
      Gori::Settings.env_syntax = Gori::Env::Syntax::Namespaced
      Gori::Settings.env_vars = [{"HOST", "api.test"}]
      ov = Gori::Tui::EnvOverlay.new
      prefix, vars = ov.to_config # destructures as a PAIR — every existing caller reads it so
      prefix.should eq(Gori::Settings.env_prefix)
      vars.should eq([{"HOST", "api.test"}])
      ov.syntax.should eq(Gori::Env::Syntax::Namespaced) # read through, never snapshotted
    end
  end

  # The card persists on EVERY mutation and the `env` section is merged WHOLE, so a var edit used
  # to carry the card's opening snapshot of the grammar back over a peer's switch — silently, and
  # with every editor in the session then reading tokens under the grammar the operator had just
  # left. The env section is never reloaded while the TUI runs, so the reload is the fix.
  it "adopts a peer's grammar switch instead of writing a stale one back over it" do
    with_settings_home do
      Gori::Settings.env_syntax = Gori::Env::Syntax::Bare
      Gori::Settings.env_vars = [{"HOST", "api.test"}]
      Gori::Settings.save.should be_true
      env_card do |h, ov, _|
        ov.syntax.should eq(Gori::Env::Syntax::Bare) # the grammar this session started under
        peer_writes_syntax("namespaced")

        # One ordinary var edit: `a`, "KEY VALUE", ↵.
        h.press(Termisu::Input::Key::LowerA, 'a')
        h.type("TOKEN t0k")
        h.press(Termisu::Input::Key::Enter)

        file_syntax.should eq("namespaced")
        Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
        # …and the card stops describing the grammar it opened on, which is the other half of
        # the lie: the meta line is the only place on screen that names it.
        ov.syntax.should eq(Gori::Env::Syntax::Namespaced)
        h.rendered?("syntax namespaced").should be_true
        # The edit itself still landed.
        Gori::Settings.env_vars.should contain({"TOKEN", "t0k"})
        JSON.parse(File.read(Gori::Settings.path))["env"]["vars"].as_a.size.should eq(2)
      end
    end
  end

  it "reads an ABSENT env.syntax as nothing to say, and keeps the session's grammar" do
    with_settings_home do
      Gori::Settings.env_syntax = Gori::Env::Syntax::Namespaced
      Gori::Settings.env_vars = [{"HOST", "api.test"}]
      Gori::Settings.save.should be_true
      # A peer that switched writes the grammar down — `serialize_env` always does — so an ABSENT
      # key is a file from before namespaces, and flipping a live session off it is exactly the
      # clobbering this seam exists to prevent. `Settings.load` is what settles a pre-namespace file.
      File.write(Gori::Settings.path, %({"theme":"dark"}))
      Gori::Tui::EnvSyntaxSeam.disk_syntax.should be_nil
      Gori::Tui::EnvSyntaxSeam.refresh_from_disk
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      # An unknown value says nothing either — `parse_env` warns and re-spells nothing for the same
      # bytes.
      File.write(Gori::Settings.path, %({"env":{"syntax":"NAMESPACED!"}}))
      Gori::Tui::EnvSyntaxSeam.disk_syntax.should be_nil
      # Nothing to say ⇒ nothing is changed: no file, or bytes that will not parse.
      File.write(Gori::Settings.path, "{not json")
      Gori::Tui::EnvSyntaxSeam.disk_syntax.should be_nil
      File.delete(Gori::Settings.path)
      Gori::Tui::EnvSyntaxSeam.disk_syntax.should be_nil
      Gori::Tui::EnvSyntaxSeam.refresh_from_disk
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
    end
  end
end

describe "the ENV pane's space menu" do
  it "offers the prefix and no grammar switch" do
    ctx = FakeExecContext.new
    ctx.current_tab = :project
    menu = Gori::Tui::SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Env, :common, ctx)

    menu.entries.map(&.id).should contain("env.edit-prefix")
    # The grammar is not here: a menu row could only write the setting, leaving every token
    # already stored in this project's rows spelled for the grammar it just left.
    menu.entries.map(&.id).should_not contain("env.syntax")
    menu.verb_for('s').should be_nil
    menu.entries.all?(&.scope.env?).should be_true
  end
end
