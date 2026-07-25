require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/oast.cr — the OAST tab's two sub-tabs (Callbacks / Providers) and the
# cross-tab "insert a fresh payload" actions.
describe "Gori::Verbs.register_oast" do
  r = Gori::Verbs.registry

  it "splits Callbacks and Providers into distinct scopes" do
    # a/e/t/d on the Providers list must never reach the Callbacks list (and vice versa);
    # the scope split is what keeps them apart, not an available? predicate.
    %w[oast.listen oast.stop oast.generate oast.copy oast.filter].each do |id|
      r[id].scope.should eq(Gori::Verb::Scope::OastCallbacks)
    end
    %w[oast.add-provider oast.edit-provider oast.toggle-provider oast.delete-provider].each do |id|
      r[id].scope.should eq(Gori::Verb::Scope::OastProviders)
    end
  end

  it "routes each sub-tab action to its own intent" do
    {"oast.listen"          => :oast_listen,
     "oast.stop"            => :oast_stop,
     "oast.generate"        => :oast_generate,
     "oast.copy"            => :oast_copy,
     "oast.filter"          => :oast_filter,
     "oast.add-provider"    => :oast_add_provider,
     "oast.edit-provider"   => :oast_edit_provider,
     "oast.toggle-provider" => :oast_toggle_provider,
     "oast.delete-provider" => :oast_delete_provider,
    }.each { |id, intent| verb_intents(r, id).should eq([intent]) }
  end

  it "escapes back to the tab menu from either sub-tab" do
    %w[oast.callbacks-to-menu oast.providers-to-menu].each do |id|
      ctx = FakeExecContext.new
      r[id].call(ctx)
      ctx.args_for(:focus_pane).should eq(["menu"])
      r[id].hidden?.should be_true
    end
  end

  it "gates the cross-tab payload verbs on BOTH the host tab and an active listener" do
    # Without a listener there is no payload to insert, so the verb would be a dead entry
    # that toasts; without the tab check, Repeater's insert would show up in the Fuzzer.
    {"repeater.oast-insert" => {:repeater, :oast_insert_payload},
     "fuzzer.oast-insert"   => {:fuzzer, :oast_insert_payload},
     "history.oast-copy"    => {:history, :oast_copy_payload},
    }.each do |id, (tab, intent)|
      ctx = FakeExecContext.new
      ctx.current_tab = tab
      ctx.oast_payload_available = false
      r[id].available?(ctx).should be_false # right tab, no listener
      ctx.oast_payload_available = true
      r[id].available?(ctx).should be_true
      ctx.current_tab = :issues
      r[id].available?(ctx).should be_false # listener, wrong tab
      r[id].menu_key.should eq('O')
      verb_intents(r, id).should eq([intent])
    end
  end
end
