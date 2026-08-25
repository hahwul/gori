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

  # The THIRD snapshot of exactly this class, and the one the fix above walked past.
  # `reset_to_factory` runs `reset_scan_rules`, emptying the GLOBAL custom probe-rule library —
  # but `Probe::Analyzer#@custom` is filled once by `load_custom` in the constructor and re-read
  # from a single place, `ProbeController#reload_rules` (the Rules sub-tab editor). So after a
  # reset the passive engine kept matching rules the operator had just deleted, minting fresh
  # `probe_issues` rows and climbing `hit_count` on the ones already there. Same class as the
  # Rewriter/Colormarker holes, one snapshot further along.
  it "reloads the Probe analyzer's custom-rule snapshot" do
    body = runner_body("private def apply_factory_reset(msg : String) : String")
    body.should contain("probe.reload_rule_config")
  end

  # Behavioural half: `reload_rule_config` is only worth calling if it actually re-reads the
  # library, so the deletion→stale→reload sequence is run for real. `delete_scan_rule` stands in
  # for `reset_scan_rules` (private, and a real `reset_to_factory` would wipe the process-wide
  # singleton other examples share) — it leaves `Settings.scan_rules` in the same state the
  # reset does, which is all the analyzer's snapshot can see.
  it "picks up a deleted global custom rule only after the reload" do
    path = File.tempname("gori-reset-probe", ".db")
    store = Gori::Store.open(path)
    begin
      id = Gori::Settings.add_scan_rule("spec canary", "", "response", "header",
        "string", "X-Spec-Canary", "info")
      id.should_not eq("")
      analyzer = Gori::Probe::Analyzer.new(store, Gori::Scope.load(store),
        Channel(Gori::Store::FlowEvent).new(1), Gori::Probe::Mode::Passive, true)

      head = "GET / HTTP/1.1\r\nHost: reset.test\r\n\r\n"
      fid = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "reset.test", port: 80,
        method: "GET", target: "/", http_version: "HTTP/1.1", head: head.to_slice,
        source: Gori::FlowSource::Kind::Proxy))
      store.update_response(Gori::Store::CapturedResponse.new(
        flow_id: fid, status: 200, reason: "OK", duration_us: 1_i64,
        head: "HTTP/1.1 200 OK\r\nX-Spec-Canary: 1\r\n\r\n".to_slice,
        body: "hi".to_slice, content_type: "text/plain"))
      store.flush
      detail = store.get_flow(fid).not_nil!

      code = "custom_g_#{id}"
      analyzer.scan_detail(detail)
      store.flush
      store.probe_issues(host: "reset.test").map(&.code).should contain(code)

      # The reset's half: the library is empty, the analyzer's snapshot is not.
      Gori::Settings.delete_scan_rule(id).should be_true
      analyzer.reload_rule_config
      store.clear_probe_issues
      store.flush
      analyzer.scan_detail(detail)
      store.flush
      store.probe_issues(host: "reset.test").map(&.code).should_not contain(code)
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
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
