require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"
require "../support/fake_context"

# The `env.syntax` SWITCH as an operator reaches it: the `s` mnemonic on the Settings → Env
# card and the `env.syntax` verb on the Project tab's ENV pane.
#
# Both flip a GLOBAL setting that decides how bytes ALREADY STORED in project DBs, drafts, rule
# replacements and slot headers are read. That is why the toast is asserted rather than merely
# the state: the one thing an operator cannot discover by looking is that nothing is rewritten,
# and a surface that flips silently turns every following unexpanded token into a bug report
# against the send path.

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
  # "did a TUI surface flip the grammar in this session" is process state (see `EnvSyntaxSeam`),
  # so it is reset around every example — a leaked claim would make the next example's save skip
  # the reload it is there to assert.
  Gori::Tui::EnvSyntaxSeam.owned = false
  begin
    yield
  ensure
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    Gori::Tui::EnvSyntaxSeam.owned = false
    Gori::Settings.env_syntax = saved_syntax
    Gori::Settings.env_prefix = saved_prefix
    Gori::Settings.env_vars = saved_vars
    FileUtils.rm_rf(dir)
  end
end

# Rewrite the `env` section of the settings file the way a PEER process does — `gori settings
# env-syntax namespaced` in another terminal, or a second gori window's own card. The card in this
# example holds a snapshot taken before this landed.
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

# The card wired the way `Runner#open_settings` wires it, so the toggle really goes through
# `save_env` (which is what assigns `Settings.env_syntax` from the overlay's working copy).
private def env_card(&) : Nil
  ov = Gori::Tui::EnvOverlay.new
  toasts = [] of String
  ov.on_toast = ->(msg : String) { toasts << msg; nil }
  # Mirrors `Runner#save_env` line for line, INCLUDING the order: adopt the file's grammar (a
  # peer may have switched it), resync the card's display copy, then write the vars and the
  # prefix. It deliberately does NOT assign `Settings.env_syntax` from the overlay — the `s`
  # toggle owns that, and handing the snapshot back on every var edit is the bug below.
  ov.on_save = -> {
    Gori::Tui::EnvSyntaxSeam.refresh_from_disk
    ov.sync_syntax
    prefix, vars = ov.to_config
    Gori::Settings.env_prefix = prefix
    Gori::Settings.env_vars = vars.dup
    Gori::Settings.save
  }
  yield OverlayHarness.new(ov), ov, toasts
end

describe Gori::Tui::EnvOverlay do
  it "flips the grammar on `s`, persists it, and says what the flip does NOT do" do
    with_settings_home do
      Gori::Settings.env_syntax = Gori::Env::Syntax::Bare
      Gori::Settings.env_vars = [{"HOST", "api.test"}]
      env_card do |h, ov, toasts|
        h.press(Termisu::Input::Key::LowerS, 's').should eq(:open)
        ov.syntax.should eq(Gori::Env::Syntax::Namespaced)
        Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
        # Both spellings the new mode uses, and the tail that keeps the operator from reading
        # the next literal `$KEY` as a send-path bug.
        toasts.last.should eq(
          "env syntax: namespaced — $ENV.KEY / $BIND.KEY · stored tokens are not rewritten")

        h.press(Termisu::Input::Key::LowerS, 's').should eq(:open)
        ov.syntax.should eq(Gori::Env::Syntax::Bare)
        Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
        toasts.last.should eq("env syntax: bare — $KEY · stored tokens are not rewritten")
      end
    end
  end

  it "spells the toast with the WORKING prefix, not the default sigil" do
    with_settings_home do
      Gori::Settings.env_syntax = Gori::Env::Syntax::Bare
      Gori::Settings.env_prefix = "%"
      env_card do |h, _, toasts|
        h.press(Termisu::Input::Key::LowerS, 's')
        toasts.last.should contain("%ENV.KEY / %BIND.KEY")
      end
    end
  end

  it "carries the live spelling in the border meta and offers `s` in both hints" do
    with_settings_home do
      Gori::Settings.env_syntax = Gori::Env::Syntax::Bare
      Gori::Settings.env_vars = [{"HOST", "api.test"}]
      env_card do |h, ov, _|
        h.assert_chrome(Gori::Tui::OverlayKind::Env, "ENVIRONMENT")
        ov.hint.should contain("s syntax")
        # The meta is the only line on this card that says which grammar the editors two tabs
        # over are reading these rows under (`HOST → api.test` reads identically either way).
        h.rendered?("global · $KEY · 1 var").should be_true
        h.rendered?("syntax bare").should be_true
        h.rendered?("p edit · s toggle").should be_true

        h.press(Termisu::Input::Key::LowerS, 's')
        h.rendered?("global · $ENV.KEY · 1 var").should be_true
        h.rendered?("syntax namespaced").should be_true
      end
    end
  end

  it "keeps to_config a 2-tuple, with the syntax read off its own getter" do
    with_settings_home do
      Gori::Settings.env_syntax = Gori::Env::Syntax::Namespaced
      Gori::Settings.env_vars = [{"HOST", "api.test"}]
      ov = Gori::Tui::EnvOverlay.new
      prefix, vars = ov.to_config # destructures as a PAIR — every existing caller reads it so
      prefix.should eq(Gori::Settings.env_prefix)
      vars.should eq([{"HOST", "api.test"}])
      ov.syntax.should eq(Gori::Env::Syntax::Namespaced) # picked up by `reset`, not by the tuple
    end
  end

  # The card persists on EVERY mutation and the `env` section is merged WHOLE, so a var edit used
  # to carry the card's opening snapshot of the grammar back over a peer's switch — silently, and
  # with every editor in the session then reading tokens under the grammar the operator had just
  # left. The env section is never reloaded while the TUI runs, so the reload is the fix.
  it "adopts a peer's grammar switch instead of writing its snapshot back over it" do
    with_settings_home do
      Gori::Settings.env_syntax = Gori::Env::Syntax::Bare
      Gori::Settings.env_vars = [{"HOST", "api.test"}]
      Gori::Settings.save.should be_true
      env_card do |h, ov, _|
        ov.syntax.should eq(Gori::Env::Syntax::Bare) # the snapshot this card opened on
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

  it "keeps THIS session's `s` flip when the file still holds the older grammar" do
    with_settings_home do
      Gori::Settings.env_syntax = Gori::Env::Syntax::Bare
      Gori::Settings.env_vars = [{"HOST", "api.test"}]
      Gori::Settings.save.should be_true
      env_card do |h, ov, _|
        h.press(Termisu::Input::Key::LowerS, 's')
        ov.syntax.should eq(Gori::Env::Syntax::Namespaced)
        # A peer that wrote before this operator's keystroke does not get to undo it: the reload
        # yields to the session that actually asked for a grammar.
        peer_writes_syntax("bare")
        h.press(Termisu::Input::Key::LowerA, 'a')
        h.type("TOKEN t0k")
        h.press(Termisu::Input::Key::Enter)

        file_syntax.should eq("namespaced")
        Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      end
    end
  end

  it "reads an ABSENT env.syntax as bare, the way the loader does" do
    with_settings_home do
      Gori::Settings.env_syntax = Gori::Env::Syntax::Namespaced
      Gori::Settings.env_vars = [{"HOST", "api.test"}]
      Gori::Settings.save.should be_true
      # A peer that switched a vars-less install back to bare writes no `env` section at all
      # (`serialize_env` omits it), and the absence means bare forever.
      File.write(Gori::Settings.path, %({"theme":"dark"}))
      Gori::Tui::EnvSyntaxSeam.disk_syntax.should eq(Gori::Env::Syntax::Bare)
      # Nothing to say ⇒ nothing is changed: no file, or bytes that will not parse.
      File.write(Gori::Settings.path, "{not json")
      Gori::Tui::EnvSyntaxSeam.disk_syntax.should be_nil
      File.delete(Gori::Settings.path)
      Gori::Tui::EnvSyntaxSeam.disk_syntax.should be_nil
      Gori::Tui::EnvSyntaxSeam.refresh_from_disk
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
    end
  end

  it "says so when the write does not land, instead of reporting a saved grammar" do
    with_settings_home do
      Gori::Settings.env_syntax = Gori::Env::Syntax::Bare
      ov = Gori::Tui::EnvOverlay.new
      toasts = [] of String
      ov.on_toast = ->(msg : String) { toasts << msg; nil }
      ov.on_save = -> { false }
      OverlayHarness.new(ov).press(Termisu::Input::Key::LowerS, 's')
      toasts.last.should start_with("env syntax applied — could not save to")
      # Applied in memory for the session, exactly as a refused prefix write is.
      ov.syntax.should eq(Gori::Env::Syntax::Namespaced)
    end
  end
end

describe "the ENV pane's space menu" do
  it "offers the grammar switch beside the prefix, and only in the Env scope" do
    ctx = FakeExecContext.new
    ctx.current_tab = :project
    menu = Gori::Tui::SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Env, :common, ctx)

    menu.entries.map(&.id).should contain("env.syntax")
    # Reached by its mnemonic and by nothing else: a GLOBAL setting that reinterprets bytes
    # already stored in project DBs is not a key to hit while walking a list.
    menu.verb_for('s').try(&.id).should eq("env.syntax")
    menu.entries.all?(&.scope.env?).should be_true
  end
end
