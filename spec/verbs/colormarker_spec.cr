require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/colormarker.cr — the Colormarker (History row-colour) tab's two lists.
private def in_colormarker(rule : Bool = false, global : Bool = false) : FakeExecContext
  ctx = FakeExecContext.new
  ctx.current_tab = :colormarker
  ctx.colormarker_rule_selected = rule
  ctx.colormarker_global_rule = global
  ctx # colormarker_rule_list_focused defaults true — the policy pane is the focused one
end

# The CUSTOM COLORS pane is the focused one (policy pane is not).
private def in_colors(color : Bool = false) : FakeExecContext
  ctx = FakeExecContext.new
  ctx.current_tab = :colormarker
  ctx.colormarker_rule_list_focused = false
  ctx.colormarker_colors_focused = true
  ctx.colormarker_color_selected = color
  ctx
end

describe "Gori::Verbs.register_colormarker" do
  r = Gori::Verbs.registry

  it "gates every rule action on a SELECTED rule, but leaves add and reload open" do
    empty = in_colormarker
    picked = in_colormarker(rule: true)

    %w[colormarker.edit colormarker.toggle colormarker.delete colormarker.move-up
      colormarker.move-down colormarker.duplicate colormarker.scope].each do |id|
      r[id].available?(empty).should be_false
      r[id].available?(picked).should be_true
    end
    r["colormarker.add"].available?(empty).should be_true
    r["colormarker.reload"].available?(empty).should be_true
  end

  it "offers the default-flip only for a GLOBAL rule" do
    # A project rule has no default to disagree with — `x` IS its state.
    r["colormarker.toggle-default"].available?(in_colormarker(rule: true)).should be_false
    r["colormarker.toggle-default"].available?(in_colormarker(rule: true, global: true)).should be_true
  end

  it "withholds the policy chords while the CUSTOM COLORS pane is focused" do
    # A chord has no `section:` to hide behind, so the rule verbs are gated on the policy pane
    # being the focused one — otherwise `x`/`s`/⇧J would act on the rule behind the colours pane.
    colors = in_colors(color: true)
    %w[colormarker.edit colormarker.toggle colormarker.delete colormarker.scope].each do |id|
      r[id].available?(colors).should be_false
    end
  end

  it "gates the custom-colour actions on the colours pane, with delete/edit needing a selection" do
    empty = in_colors
    picked = in_colors(color: true)
    r["colormarker.color-add"].available?(empty).should be_true
    r["colormarker.color-edit"].available?(empty).should be_false
    r["colormarker.color-delete"].available?(empty).should be_false
    r["colormarker.color-edit"].available?(picked).should be_true
    r["colormarker.color-delete"].available?(picked).should be_true
    # ...and never while the POLICY pane is the focused one.
    r["colormarker.color-add"].available?(in_colormarker).should be_false
  end

  it "still requires the Colormarker tab even with a rule selected" do
    # colormarker_rule_selected? is pane state that survives a tab switch, so the tab half of
    # the gate is what stops these firing from another tab's Body.
    ctx = FakeExecContext.new
    ctx.current_tab = :history
    ctx.colormarker_rule_selected = true
    ctx.colormarker_global_rule = true
    r["colormarker.edit"].available?(ctx).should be_false
    r["colormarker.add"].available?(ctx).should be_false
    r["colormarker.toggle-default"].available?(ctx).should be_false
  end

  it "moves a rule in PRECEDENCE order with a signed delta" do
    # Precedence IS the semantics of a colour rule set — the first enabled match paints the
    # row — so up/down must not share a sign.
    ctx = in_colormarker(rule: true)
    r["colormarker.move-up"].call(ctx)
    ctx.args_for(:colormarker_move).should eq(["-1"])
    ctx = in_colormarker(rule: true)
    r["colormarker.move-down"].call(ctx)
    ctx.args_for(:colormarker_move).should eq(["1"])
  end

  it "routes the remaining actions to their own intents" do
    {"colormarker.add"            => :colormarker_add,
     "colormarker.edit"           => :colormarker_edit,
     "colormarker.toggle"         => :colormarker_toggle,
     "colormarker.delete"         => :colormarker_delete,
     "colormarker.duplicate"      => :colormarker_duplicate,
     "colormarker.reload"         => :colormarker_reload,
     "colormarker.scope"          => :colormarker_scope_toggle,
     "colormarker.toggle-default" => :colormarker_toggle_default,
    }.each { |id, intent| verb_intents(r, id).should eq([intent]) }
  end

  it "routes the custom-colour actions to their own intents" do
    {"colormarker.color-add"    => :colormarker_color_add,
     "colormarker.color-edit"   => :colormarker_color_edit,
     "colormarker.color-delete" => :colormarker_color_delete,
    }.each { |id, intent| verb_intents(r, id).should eq([intent]) }
  end

  # The boot-time guarantee. Like the Rewriter's, these verbs are now partitioned into two
  # `section:`s (the two panes never render together), so a/e/d may repeat ACROSS them but must
  # be distinct WITHIN each — that is what `Registry#validate_menu_keys!` checks while BUILDING
  # the registry above, so a collision would raise before this file reached an example.
  it "derives distinct space-menu keys within each of its two focus sections" do
    rules_keys = [] of Char
    colors_keys = [] of Char
    r.each do |v|
      next unless v.scope.colormarker?
      v.menu_key.try do |k|
        v.section == :colors ? (colors_keys << k) : (rules_keys << k)
      end
    end
    rules_keys.size.should eq(11) # add/edit/toggle/copy/delete/move×2/scope/duplicate/reload/default
    rules_keys.uniq.size.should eq(11)
    colors_keys.size.should eq(3)
    colors_keys.uniq.size.should eq(3)
  end
end
