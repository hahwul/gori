require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/rewriter.cr — the Rewriter (Match & Replace) tab's rule list.
private def in_rewriter(rule : Bool = false) : FakeExecContext
  ctx = FakeExecContext.new
  ctx.current_tab = :rewriter
  ctx.rewriter_rule_selected = rule
  ctx
end

describe "Gori::Verbs.register_rewriter" do
  r = Gori::Verbs.registry

  it "gates every rule action on a SELECTED rule, but leaves add and reload open" do
    empty = in_rewriter
    picked = in_rewriter(rule: true)

    %w[rewriter.edit rewriter.toggle rewriter.delete rewriter.move-up
      rewriter.move-down rewriter.duplicate].each do |id|
      r[id].available?(empty).should be_false
      r[id].available?(picked).should be_true
    end
    r["rewriter.add"].available?(empty).should be_true
    r["rewriter.reload"].available?(empty).should be_true
  end

  it "still requires the Rewriter tab even with a rule selected" do
    # rewriter_rule_selected? is pane state that survives a tab switch, so the tab half of
    # the gate is what stops these firing from another tab's Body.
    ctx = FakeExecContext.new
    ctx.current_tab = :history
    ctx.rewriter_rule_selected = true
    r["rewriter.edit"].available?(ctx).should be_false
    r["rewriter.add"].available?(ctx).should be_false
  end

  it "moves a rule in apply order with a signed delta" do
    # Apply order IS the semantics of a rule set; up/down must not share a sign.
    ctx = in_rewriter(rule: true)
    r["rewriter.move-up"].call(ctx)
    ctx.args_for(:rewriter_move).should eq(["-1"])
    ctx = in_rewriter(rule: true)
    r["rewriter.move-down"].call(ctx)
    ctx.args_for(:rewriter_move).should eq(["1"])
  end

  it "routes the remaining actions to their own intents" do
    {"rewriter.add"       => :rewriter_add,
     "rewriter.edit"      => :rewriter_edit,
     "rewriter.toggle"    => :rewriter_toggle,
     "rewriter.delete"    => :rewriter_delete,
     "rewriter.duplicate" => :rewriter_duplicate,
     "rewriter.reload"    => :rewriter_reload,
    }.each { |id, intent| verb_intents(r, id).should eq([intent]) }
  end
end
