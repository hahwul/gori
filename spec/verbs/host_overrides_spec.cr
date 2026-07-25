require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/host_overrides.cr — the Project tab's HOST OVERRIDES pane. Its own scope,
# so a/e/d act on the override list and never on the SCOPE rules right above it.
describe "Gori::Verbs.register_host_overrides" do
  r = Gori::Verbs.registry

  it "keeps a/e/d in the HostOverrides scope, distinct from the scope-rule list" do
    {"hostoverride.add-entry"    => "a",
     "hostoverride.edit-entry"   => "e",
     "hostoverride.delete-entry" => "d",
    }.each do |id, key|
      r[id].scope.should eq(Gori::Verb::Scope::HostOverrides)
      r[id].chords.should eq([Gori::Verb::Chord.new(key)])
      # The Project scope binds the same letters to scope.add-rule/edit-rule/delete-rule.
      r[id].scope.should_not eq(Gori::Verb::Scope::Project)
    end
  end

  it "gates edit and delete on a selected entry, leaving add always available" do
    ctx = FakeExecContext.new
    r["hostoverride.add-entry"].available?(ctx).should be_true
    r["hostoverride.edit-entry"].available?(ctx).should be_false
    r["hostoverride.delete-entry"].available?(ctx).should be_false
    ctx.hostov_has_entry = true
    r["hostoverride.edit-entry"].available?(ctx).should be_true
    r["hostoverride.delete-entry"].available?(ctx).should be_true
  end

  it "routes each action to its own intent" do
    {"hostoverride.add-entry"    => :hostov_add_entry,
     "hostoverride.edit-entry"   => :hostov_edit_entry,
     "hostoverride.delete-entry" => :hostov_delete_entry,
    }.each { |id, intent| verb_intents(r, id).should eq([intent]) }
  end
end
