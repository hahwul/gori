require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def rdown(h : OverlayHarness, n : Int32) : Nil
  n.times { h.press(Termisu::Input::Key::Down) }
end

# The Probe custom-rule form (Probe → Rules → a/e). A dumb form: the persist — global →
# settings.json, project → project DB, plus the move between them when the scope row
# changes on an edit — is ProbeController#apply_custom_rule, injected as on_commit at the
# open-site (Runner#open_custom_rule_editor).
describe Gori::Tui::CustomRuleOverlay do
  it "exposes the chrome the Runner ladders never had for it" do
    # BEHAVIOUR CHANGE, deliberate: pre-migration this modal had NO entry in either the
    # focus-badge or the key-hint ladder, so an open custom-rule card showed the tab
    # bar's/body's stale label and hints. Under the seam `title`/`hint` are abstract, so
    # the gap is closed by construction.
    OverlayHarness.new(CustomRuleOverlay.adding).assert_chrome(OverlayKind::ProbeRule, "CUSTOM RULE")
  end

  it "drives fields → Save → on_commit → close through the generic dispatch" do
    ov = CustomRuleOverlay.adding
    h = OverlayHarness.new(ov)
    saved = [] of {String, String, String, String}
    h.on_commit do
      # rule_title, NOT title: `title` is the Overlay chrome label. ProbeController reads
      # exactly these accessors, so a collision here would persist the badge text as the
      # rule's name — silently, on every save.
      saved << {ov.rule_title, ov.description, ov.scope, ov.pattern}
      true
    end

    h.type("leaky header")
    rdown(h, 1)
    h.type("finds a debug header")
    rdown(h, 1)                         # → scope (project)
    h.press(Termisu::Input::Key::Right) # project → global
    rdown(h, 5)                         # scope → side → region → match → severity → pattern
    h.type("X-Debug")
    h.press(Termisu::Input::Key::Enter).should eq(:closed) # ↵ on the pattern row commits

    saved.should eq([{"leaky header", "finds a debug header", "global", "X-Debug"}])
  end

  it "keeps the form open when the controller rejects it (invalid rule)" do
    ov = CustomRuleOverlay.adding
    ov.valid?.should be_false # nothing filled in
    h = OverlayHarness.new(ov, commit: false)
    ov.set_selected(8) # Save row
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.commits.should eq(1) # apply_custom_rule DID run — it just returned false
  end

  it "esc cancels and a click-away dismisses — neither persists anything" do
    h = OverlayHarness.new(CustomRuleOverlay.adding)
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    h.commits.should eq(0)

    away = OverlayHarness.new(CustomRuleOverlay.adding)
    away.overlay.handle_click(away.area, 0, 0).should eq(:cancel) # raw: not a silent save
    away.click(0, 0).should eq(:closed)
    away.commits.should eq(0)
  end

  it "click selects a row, and a click on Save commits" do
    ov = CustomRuleOverlay.editing(
      Gori::Probe::CustomRule.new(id: "7", title: "leaky", description: "desc",
        side: "response", region: "body", kind: "string", pattern: "X-Debug",
        severity: Gori::Store::Severity::Info, scope: "project", enabled: true))
    h = OverlayHarness.new(ov)
    # Rows start at box.y + 2; Save is index 8.
    h.click_in_box(3, 3).should eq(:open) # the desc row
    ov.on_save_row?.should be_false
    h.click_in_box(3, 10).should eq(:closed)
    h.commits.should eq(1)
  end

  it "moves the selected field with the wheel" do
    ov = CustomRuleOverlay.adding
    OverlayHarness.new(ov).wheel(3 * 3) # 9 notches down clamps onto Save
    ov.on_save_row?.should be_true
  end

  it "routes IME preedit to the focused text row" do
    h = OverlayHarness.new(CustomRuleOverlay.adding)
    h.preedit("preedithere")
    h.rendered?("preedithere").should be_true
  end
end
