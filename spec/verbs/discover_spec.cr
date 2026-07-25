require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/discover.cr — the Discover sub-tab (under Target) run controls.
describe "Gori::Verbs.register_discover" do
  r = Gori::Verbs.registry

  it "controls the current run from the Discover scope" do
    {"discover.run"   => :discover_run,
     "discover.stop"  => :discover_stop,
     "discover.pause" => :discover_toggle_pause,
    }.each do |id, intent|
      r[id].scope.should eq(Gori::Verb::Scope::Discover)
      verb_intents(r, id).should eq([intent])
    end
  end

  it "keeps pause off ctrl-p, which belongs to the command palette" do
    # Plain `p` is handled by the controller body; the verb exists for the space menu.
    r["discover.pause"].chords.should be_empty
    r["discover.pause"].menu_key.should eq('p')
    r["app.palette"].chords.should eq([Gori::Verb::Chord.new("p", ctrl: true)])
    r["discover.run"].chords.should eq([Gori::Verb::Chord.new("r", ctrl: true)])
    r["discover.stop"].chords.should eq([Gori::Verb::Chord.new("x", ctrl: true)])
  end

  it "escapes back to the Sitemap/Discover strip, not the tab bar" do
    ctx = FakeExecContext.new
    r["discover.to-menu"].call(ctx)
    ctx.args_for(:focus_pane).should eq(["subtabs"])
    r["discover.to-menu"].hidden?.should be_true
  end
end
