require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/params.cr — the Params sub-tab (under Target), plus the Sitemap's `p` into it.
describe "Gori::Verbs.register_params" do
  r = Gori::Verbs.registry

  it "routes the Params verbs to their own intents" do
    {"params.run"          => :params_run,
     "params.all-headers"  => :params_toggle_headers,
     "params.clear-target" => :params_clear_target,
     "params.open-flow"    => :params_open_flow,
     "params.copy-names"   => :params_copy_names,
     "params.export"       => :params_export,
     "params.mine"         => :params_mine,
     "sitemap.params"      => :sitemap_params,
    }.each { |id, intent| verb_intents(r, id).should eq([intent]) }
  end

  # `esc` peels one layer: the Sitemap-node filter first, then focus up to the strip.
  it "clears a node filter on esc before leaving for the sub-tab strip" do
    ctx = FakeExecContext.new
    ctx.params_targeted = true
    r["params.to-menu"].call(ctx)
    ctx.call_names.should eq([:params_clear_target])
    verb_intents(r, "params.to-menu").should eq([:focus_pane])
  end

  it "binds `p` on the Sitemap and ⇧Y / ^R on Params" do
    r["sitemap.params"].chords.should eq([typed_chord("p")])
    r["params.copy-names"].chords.should eq([typed_chord("y", shift: true)])
    r["params.run"].chords.should eq([typed_chord("r", ctrl: true)])
  end
end
