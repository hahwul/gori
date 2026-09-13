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

# The card wired the way `Runner#open_settings` wires it, so the toggle really goes through
# `save_env` (which is what assigns `Settings.env_syntax` from the overlay's working copy).
private def env_card(&) : Nil
  ov = Gori::Tui::EnvOverlay.new
  toasts = [] of String
  ov.on_toast = ->(msg : String) { toasts << msg; nil }
  ov.on_save = -> {
    prefix, vars = ov.to_config
    Gori::Settings.env_prefix = prefix
    Gori::Settings.env_vars = vars.dup
    Gori::Settings.env_syntax = ov.syntax
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
