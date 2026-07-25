require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/env.cr — the Project tab's ENVIRONMENT pane. Its own scope, so a/e/d
# act on the env-var list and never on the SCOPE rules or HOST OVERRIDES stacked above it.
describe "Gori::Verbs.register_env" do
  r = Gori::Verbs.registry

  it "keeps a/e/d in the Env scope, distinct from the panes above it" do
    {"env.add-var" => "a", "env.edit-var" => "e", "env.delete-var" => "d"}.each do |id, key|
      r[id].scope.should eq(Gori::Verb::Scope::Env)
      r[id].chords.should eq([Gori::Verb::Chord.new(key)])
      # The same letters in the sibling panes belong to DIFFERENT verbs in DIFFERENT
      # scopes; sharing a scope would make one set silently shadow the other.
      r[id].scope.should_not eq(Gori::Verb::Scope::Project)
      r[id].scope.should_not eq(Gori::Verb::Scope::HostOverrides)
    end
  end

  it "gates edit and delete on a selected var, leaving add always available" do
    ctx = FakeExecContext.new
    r["env.add-var"].available?(ctx).should be_true
    r["env.edit-var"].available?(ctx).should be_false
    r["env.delete-var"].available?(ctx).should be_false
    ctx.env_has_var = true
    r["env.edit-var"].available?(ctx).should be_true
    r["env.delete-var"].available?(ctx).should be_true
  end

  it "leaves the GLOBAL prefix setting menu-only, out of the way of everyday edits" do
    # The prefix sigil applies app-wide, not per project — a direct chord next to add/edit
    # would read as another per-project field.
    verb = r["env.edit-prefix"]
    verb.chords.should be_empty
    verb.menu_key.should eq('p')
    verb.available?(FakeExecContext.new).should be_true
  end

  it "routes each action to its own intent" do
    {"env.add-var"     => :env_add_var,
     "env.edit-var"    => :env_edit_var,
     "env.delete-var"  => :env_delete_var,
     "env.edit-prefix" => :env_edit_prefix,
    }.each { |id, intent| verb_intents(r, id).should eq([intent]) }
  end
end
