require "../spec_helper"

# What the TUI has to do to the LIVE session after `Settings.reset_to_factory` lands.
#
# `Runner.new` appears nowhere under spec/ — it owns a terminal — so these are pinned by
# reading the method bodies, the idiom spec/tui/session_slots_spec.cr and
# spec/tui/subtab_find_key_spec.cr already use for the same reason. Comments are stripped
# first: a comment explaining a rule contains the tokens the rule looks for, and asserting
# against the raw text would pass on the strength of its own prose. Scoped to the METHOD
# BODY rather than the file, because "the call exists somewhere in runner.cr" is exactly
# what was true while these were missing — every ordinary edit path already made them.
private def runner_body(signature : String) : String
  src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner.cr"))
    .lines.reject(&.lstrip.starts_with?('#')).join('\n')
  body = src[/^\s*#{Regex.escape(signature)}$.*?^    end$/m]?
  body.should_not be_nil
  body.not_nil!
end

describe "Runner#apply_factory_reset" do
  # `Rules.merged` and `Colormarker`'s compiled list are SNAPSHOTS the proxy fibers read on
  # the hot path of every request and response. A factory reset deletes the global rules
  # behind them, and nothing else in this window would notice: `apply_external_change` only
  # runs on a `data_version` tick, and with capture off that tick never happens — so a rule
  # the operator had just deleted went on rewriting live traffic for the rest of the session,
  # healed only by wandering into the Rewriter tab. Every ordinary rule edit calls `reload`
  # on the spot; the reset was the one path that did not.
  it "reloads the rewrite and colour snapshots the proxy is holding" do
    body = runner_body("private def apply_factory_reset(msg : String) : String")
    body.should contain("rules.reload")
    body.should contain("colormarker.reload")
    # The render-side mark map is primed off the same colour set, and it is memoised against
    # the colormarker revision — so it has to be re-stamped here too, or History keeps
    # painting rows with custom colours the reset just dropped.
    body.should contain("Theme.set_custom_marks")
  end

  # `reset_saved_views` empties `Settings.saved_views`, so the lens History is filtering by
  # can be a view that no longer exists. `view.reload` alone repopulates the list THROUGH
  # that dead lens and says nothing; every other path that loses a view (a peer's
  # `views rm`, MCP `delete_view`, the on-enter re-resolve) prints "the X view is gone —
  # showing All". Re-resolved BEFORE the reload so the list is rebuilt against the lens that
  # actually survived.
  it "re-resolves the active saved view and says so when it is gone" do
    body = runner_body("private def apply_factory_reset(msg : String) : String")
    body.should contain("resolve_active_view")
    body.should contain("view is gone")
    body.index("resolve_active_view").not_nil!
      .should be < body.index("view.reload(@session.store)").not_nil!
  end
end

describe "Runner#save_tabs" do
  # The default arrangement is spelled as an ABSENT `tabs` key, never as a written-out copy
  # of today's defaults. `TabsOverlay#to_prefs` maps every row, so the Preferences modal's
  # `^R` on the Tabs row — reset_to_defaults, then save — used to write a twenty-entry block
  # PINNING today's `Chrome::DEFAULT_HIDDEN` into the file, while a factory reset on the same
  # input writes nothing at all. A later release moving a tab in or out of the default hidden
  # set would then be silently ignored, on the strength of a row the operator pressed "reset"
  # on.
  it "persists the default arrangement as an empty list, not as today's defaults" do
    body = runner_body("private def save_tabs(ov : TabsOverlay) : Bool")
    body.should contain("tab_prefs_of(ov)")
    body.should_not contain("ov.to_prefs")

    helper = runner_body("private def tab_prefs_of(ov : TabsOverlay) : Array({String, Bool})")
    helper.should contain("Chrome.reconcile")
    helper.should contain("[] of {String, Bool}")
  end

  # …and the comparison it makes is against the real catalog default, so this is the shape
  # `tab_prefs_of` sees when the overlay is untouched. Behavioural half: `Chrome.reconcile`
  # of an empty prefs list is what a factory reset leaves behind, so the two paths agree.
  it "reconciles an empty prefs list to the same arrangement reset_to_defaults produces" do
    ov = Gori::Tui::TabsOverlay.new
    ov.reset_to_defaults
    defaults = Gori::Tui::Chrome.reconcile([] of {String, Bool}).map { |(sym, _, vis)| {sym.to_s, vis} }
    ov.to_prefs.should eq(defaults)
  end
end
