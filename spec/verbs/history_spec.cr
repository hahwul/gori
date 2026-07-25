require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/history.cr — the History list + detail, the Repeater workbench, and
# (registered in the same file) the Fuzzer and Miner verbs. Each example pins the INTENT
# a verb dispatches on the recording ExecContext and the `available?` gate around it.
# A context sitting on `tab` with a flow selected — what most of these verbs gate on.
private def on(tab : Symbol, selected : Int64? = nil) : FakeExecContext
  ctx = FakeExecContext.new
  ctx.current_tab = tab
  ctx.selected = selected
  ctx
end

describe "Gori::Verbs.register_history" do
  r = Gori::Verbs.registry

  describe "History list (Body)" do
    it "moves the selection with a signed delta" do
      ctx = FakeExecContext.new
      r["body.down"].call(ctx)
      ctx.args_for(:move_selection).should eq(["1"])
      ctx = FakeExecContext.new
      r["body.up"].call(ctx)
      ctx.args_for(:move_selection).should eq(["-1"])
    end

    # The two gates are NOT interchangeable: a list-wide action (filter/follow/clear)
    # only needs the tab, a flow action needs a selected row too. Widening the flow gate
    # to in_history would let 'y'/^R/'X' fire against nothing.
    it "gates flow actions on a selected flow and list actions on the tab alone" do
      empty = on(:history)
      picked = on(:history, 7_i64)
      elsewhere = on(:repeater, 7_i64)

      {"body.open"        => :open_detail,
       "history.copy"     => :copy_selection,
       "history.repeater" => :repeater_selected,
       "history.discover" => :history_discover,
       "history.compare"  => :comparer_add_selected,
       "history.delete"   => :history_delete,
      }.each do |id, intent|
        r[id].available?(empty).should be_false
        r[id].available?(picked).should be_true
        r[id].available?(elsewhere).should be_false
        verb_intents(r, id).should eq([intent])
      end

      {"history.query"         => :history_query,
       "history.toggle-follow" => :toggle_follow,
       "history.clear"         => :history_clear,
      }.each do |id, intent|
        r[id].available?(empty).should be_true
        r[id].available?(elsewhere).should be_false
        verb_intents(r, id).should eq([intent])
      end
    end

    it "keeps the destructive list verbs menu-only, on capitals that don't shadow a chord" do
      # 'x' is select-line and 'c' is compare in the same Body COMMON view, so delete/clear
      # take 'X'/'C'. A lowercase mnemonic here would silently shadow one of those.
      r["history.delete"].chords.should be_empty
      r["history.delete"].menu_key.should eq('X')
      r["history.clear"].chords.should be_empty
      r["history.clear"].menu_key.should eq('C')
      r["history.probe-active"].menu_key.should eq('A')
      verb_intents(r, "history.probe-active").should eq([:probe_active_selected])
    end
  end

  describe "History detail" do
    # These mirror the list's space menu so muscle memory carries into the drill-in — and
    # each one that navigates AWAY closes the detail FIRST, so the overlay doesn't float
    # over the destination tab. Order is the whole point of the assertion.
    it "closes the detail before jumping to another tab" do
      verb_intents(r, "detail.repeater").should eq([:close_detail, :repeater_selected])
      verb_intents(r, "detail.issue").should eq([:close_detail, :issue_create])
      verb_intents(r, "detail.fuzz").should eq([:close_detail, :fuzz_selected])
      verb_intents(r, "detail.mine").should eq([:close_detail, :mine_selected])
      verb_intents(r, "detail.sequence").should eq([:close_detail, :sequence_selected])
      verb_intents(r, "detail.probe-active").should eq([:close_detail, :probe_active_selected])
    end

    it "keeps the in-place actions from closing the detail" do
      verb_intents(r, "detail.compare").should eq([:comparer_add_selected])
      verb_intents(r, "detail.copy").should eq([:detail_copy_selection])
      verb_intents(r, "detail.copy-flow").should eq([:copy_selection])
      verb_intents(r, "detail.copy-as").should eq([:copy_as_open])
      verb_intents(r, "detail.add-host").should eq([:scope_add_host])
      verb_intents(r, "detail.delete").should eq([:history_delete])
    end

    it "walks the panes and the caret with signed deltas" do
      ctx = FakeExecContext.new
      r["detail.next-pane"].call(ctx)
      ctx.args_for(:move_detail_pane).should eq(["1"])
      ctx = FakeExecContext.new
      r["detail.prev-pane"].call(ctx)
      ctx.args_for(:move_detail_pane).should eq(["-1"])
      ctx = FakeExecContext.new
      r["detail.down"].call(ctx)
      ctx.args_for(:scroll_detail).should eq(["1"])
      ctx = FakeExecContext.new
      r["detail.up"].call(ctx)
      ctx.args_for(:scroll_detail).should eq(["-1"])
      verb_intents(r, "detail.toggle-pane").should eq([:toggle_detail_pane])
      verb_intents(r, "detail.close").should eq([:close_detail])
    end

    it "leaves the view toggles visible so they front the detail's space menu" do
      # The palette is Global-only, so un-hiding them cannot leak them there.
      %w[detail.toggle-hex detail.toggle-ws detail.toggle-pretty].each do |id|
        r[id].hidden?.should be_false
        r[id].scope.should eq(Gori::Verb::Scope::HistoryDetail)
      end
      r["detail.toggle-hex"].menu_key.should eq('e') # ^X has no menu key; plain 'x' is select-line
      verb_intents(r, "detail.toggle-hex").should eq([:toggle_detail_hex])
      verb_intents(r, "detail.toggle-ws").should eq([:toggle_reveal])
      verb_intents(r, "detail.toggle-pretty").should eq([:toggle_pretty])
    end
  end

  describe "Repeater workbench" do
    it "gates every Repeater verb on the Repeater tab" do
      ctx = on(:history)
      %w[repeater.send repeater.new repeater.minimize repeater.insert-marker
        repeater.auto-mark repeater.toggle-hex repeater.toggle-http2
        repeater.send-group repeater.toggle-diff].each do |id|
        r[id].available?(ctx).should be_false
        r[id].available?(on(:repeater)).should be_true
      end
    end

    it "routes send / new / minimize / group-send to their own intents" do
      verb_intents(r, "repeater.send").should eq([:repeater_send])
      verb_intents(r, "repeater.new").should eq([:repeater_new])
      verb_intents(r, "repeater.minimize").should eq([:repeater_minimize])
      verb_intents(r, "repeater.send-group").should eq([:repeater_send_group])
    end

    it "routes Copy through read_copy (the single smart copy), gated on a read pane" do
      verb = r["repeater.copy"]
      verb.available?(on(:repeater)).should be_false # not in read mode
      ctx = on(:repeater)
      ctx.repeater_read_mode = true
      verb.available?(ctx).should be_true
      verb_intents(r, "repeater.copy").should eq([:read_copy])
      r["repeater.copy-as"].menu_key.should eq('Y') # pairs with copy's 'y'
      verb_intents(r, "repeater.copy-as").should eq([:copy_as_open])
    end

    it "shows the sub-tab jump only once there are two sessions to pick between" do
      one = on(:repeater)
      one.repeater_tab_count = 1
      two = on(:repeater)
      two.repeater_tab_count = 2
      %w[repeater.find-subtab repeater.filter-subtabs].each do |id|
        r[id].available?(one).should be_false
        r[id].available?(two).should be_true
        r[id].section.should eq(:tab) # seeds has_section?(Repeater, :tab) for the tab-bar menu
      end
      # Duplicate needs only ONE session — it clones what is open.
      r["repeater.duplicate-subtab"].available?(one).should be_true
      r["repeater.duplicate-subtab"].available?(on(:repeater)).should be_false # zero sessions
    end

    it "keeps the marker actions on the :request section and the diff toggles on :response" do
      {"repeater.insert-marker" => :repeater_insert_marker,
       "repeater.mark-word"     => :repeater_mark_word,
       "repeater.auto-mark"     => :repeater_auto_mark,
       "repeater.clear-marks"   => :repeater_clear_marks,
       "repeater.attach-chain"  => :repeater_attach_chain,
       "repeater.toggle-hex"    => :repeater_toggle_hex,
       "repeater.toggle-http2"  => :repeater_toggle_http2,
      }.each do |id, intent|
        r[id].section.should eq(:request)
        verb_intents(r, id).should eq([intent])
      end

      {"repeater.toggle-diff"     => :repeater_toggle_resp_diff,
       "repeater.toggle-resp-hex" => :repeater_toggle_resp_hex,
       "repeater.toggle-pretty"   => :toggle_pretty,
      }.each do |id, intent|
        r[id].section.should eq(:response)
        verb_intents(r, id).should eq([intent])
      end

      r["repeater.toggle-sni"].section.should eq(:target)
      verb_intents(r, "repeater.toggle-sni").should eq([:repeater_toggle_sni])
    end

    it "gates Link to issue/note on the session having been persisted" do
      # link_repeater_id is nil until the session has a row — linking before that would
      # attach evidence to an id that does not exist.
      ctx = on(:repeater)
      r["link.repeater.to-issue"].available?(ctx).should be_false
      r["link.repeater.to-note"].available?(ctx).should be_false
      ctx.link_repeater = 4_i64
      r["link.repeater.to-issue"].available?(ctx).should be_true
      r["link.repeater.to-note"].available?(ctx).should be_true
      verb_intents(r, "link.repeater.to-issue").should eq([:link_to_issue])
      verb_intents(r, "link.repeater.to-note").should eq([:link_to_note])
    end
  end

  describe "Fuzzer (register_fuzz)" do
    it "sends to the Fuzzer from History (selected flow) and from Repeater (template)" do
      r["history.fuzz"].available?(on(:history)).should be_false
      r["history.fuzz"].available?(on(:history, 3_i64)).should be_true
      verb_intents(r, "history.fuzz").should eq([:fuzz_selected])

      r["repeater.fuzz"].available?(on(:history, 3_i64)).should be_false
      r["repeater.fuzz"].available?(on(:repeater)).should be_true
      verb_intents(r, "repeater.fuzz").should eq([:fuzz_from_repeater])
    end

    it "gates the Fuzzer-scope actions on the Fuzzer tab" do
      ctx = on(:fuzzer)
      {"fuzz.run"             => :fuzz_run,
       "fuzz.stop"            => :fuzz_stop,
       "fuzz.new"             => :fuzz_new,
       "fuzz.automark"        => :fuzz_automark,
       "fuzz.attach-chain"    => :fuzz_attach_chain,
       "fuzz.list-paste"      => :fuzz_list_paste,
       "fuzz.pretty-template" => :fuzz_pretty_template,
       "fuzz.toggle-http2"    => :fuzz_toggle_http2,
       "fuzz.clear-marks"     => :fuzz_clear_marks,
      }.each do |id, intent|
        r[id].available?(ctx).should be_true
        r[id].available?(on(:repeater)).should be_false
        verb_intents(r, id).should eq([intent])
      end
    end

    it "shares one sub-tab search/filter counter across the workbench tabs" do
      ctx = on(:fuzzer)
      ctx.subtab_search_tab_count = 2
      r["fuzz.find-subtab"].available?(ctx).should be_true
      r["fuzz.filter-subtabs"].available?(ctx).should be_true
      verb_intents(r, "fuzz.find-subtab").should eq([:subtab_search_open])
      verb_intents(r, "fuzz.filter-subtabs").should eq([:subtab_filter_open])
    end

    it "gates the Fuzzer Copy on read mode, like the Repeater one" do
      ctx = on(:fuzzer)
      r["fuzzer.copy"].available?(ctx).should be_false
      ctx.fuzzer_read_mode = true
      r["fuzzer.copy"].available?(ctx).should be_true
      verb_intents(r, "fuzzer.copy").should eq([:read_copy])
    end

    it "gates Link to issue/note on the FUZZ session id, not the repeater one" do
      # link.fuzzer.* and link.repeater.* are near-identical registrations; each must read
      # its OWN id, or the Fuzzer entries are offered against a session that isn't there.
      ctx = on(:fuzzer)
      ctx.link_repeater = 4_i64 # a live repeater session must not unlock the Fuzzer verbs
      r["link.fuzzer.to-issue"].available?(ctx).should be_false
      r["link.fuzzer.to-note"].available?(ctx).should be_false
      ctx.link_fuzz = 8_i64
      r["link.fuzzer.to-issue"].available?(ctx).should be_true
      r["link.fuzzer.to-note"].available?(ctx).should be_true
      ctx.current_tab = :repeater
      r["link.fuzzer.to-issue"].available?(ctx).should be_false # linkable fuzz, wrong tab
      verb_intents(r, "link.fuzzer.to-issue").should eq([:link_to_issue])
      verb_intents(r, "link.fuzzer.to-note").should eq([:link_to_note])
    end
  end

  describe "Miner (register_miner)" do
    it "sends to the Miner from History, the detail, and Repeater" do
      r["history.mine"].available?(on(:history)).should be_false
      r["history.mine"].available?(on(:history, 1_i64)).should be_true
      verb_intents(r, "history.mine").should eq([:mine_selected])
      verb_intents(r, "repeater.mine").should eq([:mine_from_repeater])
    end

    it "gates 'Send to Repeater' on a selected finding, not just the Miner tab" do
      ctx = on(:miner)
      r["mine.repeater"].available?(ctx).should be_false
      ctx.miner_has_issue = true
      r["mine.repeater"].available?(ctx).should be_true
      verb_intents(r, "mine.repeater").should eq([:mine_repeater_selected])
    end

    it "routes run / stop / duplicate on the Miner tab" do
      ctx = on(:miner)
      r["mine.run"].available?(ctx).should be_true
      r["mine.stop"].available?(ctx).should be_true
      verb_intents(r, "mine.run").should eq([:mine_run])
      verb_intents(r, "mine.stop").should eq([:mine_stop])
      verb_intents(r, "mine.duplicate-subtab").should eq([:miner_duplicate_subtab])
    end

    it "runs the active Probe checks against the current Repeater request" do
      r["repeater.probe-active"].available?(on(:repeater)).should be_true
      verb_intents(r, "repeater.probe-active").should eq([:probe_active_from_repeater])
    end
  end
end
