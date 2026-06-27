require "../spec_helper"

include Gori::Verb

# Minimal recording ExecContext for exercising handlers.
private class FakeContext < ExecContext
  property selected : Int64? = nil
  property tab : Symbol = :history
  getter calls = [] of Symbol

  def quit! : Nil
    @calls << :quit
  end

  def leave_project : Nil
    @calls << :leave_project
  end

  def current_tab : Symbol
    @tab
  end

  def focus_pane(pane : Symbol) : Nil
    @calls << :focus_pane
  end

  def enter_content : Nil
    @calls << :enter_content
  end

  def status(message : String) : Nil
    @calls << :status
  end

  def open_palette : Nil
    @calls << :open_palette
  end

  def close_overlay : Nil
    @calls << :close_overlay
  end

  def focus_tab(tab : Symbol) : Nil
    @calls << tab
  end

  def focus_visible_tab(n : Int32) : Nil
    @calls << :focus_visible_tab
  end

  def cycle_tab(delta : Int32) : Nil
    @calls << :cycle_tab
  end

  def move_selection(delta : Int32) : Nil
    @calls << :move
  end

  def open_detail : Nil
    @calls << :open_detail
  end

  def close_detail : Nil
    @calls << :close_detail
  end

  def toggle_follow : Nil
    @calls << :toggle_follow
  end

  def selected_flow_id : Int64?
    @selected
  end

  def copy_selection : Nil
    @calls << :copy
  end

  def history_query : Nil
    @calls << :history_query
  end

  def scroll_detail(delta : Int32) : Nil
    @calls << :scroll_detail
  end

  def toggle_detail_pane : Nil
    @calls << :toggle_detail_pane
  end

  def move_detail_pane(dir : Int32) : Nil
    @calls << :move_detail_pane
  end

  def toggle_detail_hex : Nil
    @calls << :toggle_detail_hex
  end

  def toggle_reveal : Nil
    @calls << :toggle_reveal
  end

  def toggle_pretty : Nil
    @calls << :toggle_pretty
  end

  def replay_selected : Nil
    @calls << :replay_selected
  end

  def replay_new : Nil
    @calls << :replay_new
  end

  def replay_send : Nil
    @calls << :replay_send
  end

  def replay_toggle_hex : Nil
    @calls << :replay_toggle_hex
  end

  def replay_toggle_sni : Nil
    @calls << :replay_toggle_sni
  end

  def replay_toggle_auto_content_length : Nil
    @calls << :replay_toggle_auto_content_length
  end

  def fuzz_selected : Nil
    @calls << :fuzz_selected
  end

  def fuzz_from_replay : Nil
    @calls << :fuzz_from_replay
  end

  def fuzz_run : Nil
    @calls << :fuzz_run
  end

  def fuzz_stop : Nil
    @calls << :fuzz_stop
  end

  def fuzz_new : Nil
    @calls << :fuzz_new
  end

  def fuzz_automark : Nil
    @calls << :fuzz_automark
  end

  def sitemap_move(delta : Int32) : Nil
    @calls << :sitemap_move
  end

  def sitemap_toggle : Nil
    @calls << :sitemap_toggle
  end

  def sitemap_expand : Nil
    @calls << :sitemap_expand
  end

  def sitemap_collapse : Nil
    @calls << :sitemap_collapse
  end

  def sitemap_query : Nil
    @calls << :sitemap_query
  end

  def scope_open : Nil
    @calls << :scope_open
  end

  def scope_add_host : Nil
    @calls << :scope_add_host
  end

  def scope_toggle_lens : Nil
    @calls << :scope_toggle_lens
  end

  def scope_add_rule : Nil
    @calls << :scope_add_rule
  end

  def scope_edit_rule : Nil
    @calls << :scope_edit_rule
  end

  def scope_delete_rule : Nil
    @calls << :scope_delete_rule
  end

  def scope_rule_selected? : Bool
    true
  end

  def rules_open : Nil
    @calls << :rules_open
  end

  def finding_create : Nil
    @calls << :finding_create
  end

  def findings_new : Nil
    @calls << :findings_new
  end

  def findings_move(delta : Int32) : Nil
    @calls << :findings_move
  end

  def findings_open : Nil
    @calls << :findings_open
  end

  def finding_close : Nil
    @calls << :finding_close
  end

  def findings_delete : Nil
    @calls << :findings_delete
  end

  def finding_severity(delta : Int32) : Nil
    @calls << :finding_severity
  end

  def finding_status(delta : Int32) : Nil
    @calls << :finding_status
  end

  def finding_edit_notes : Nil
    @calls << :finding_edit_notes
  end

  def finding_edit_title : Nil
    @calls << :finding_edit_title
  end

  def finding_open_flow : Nil
    @calls << :finding_open_flow
  end

  def finding_replay_flow : Nil
    @calls << :finding_replay_flow
  end

  def findings_export(format : Symbol) : Nil
    @calls << :findings_export
  end

  def toggle_capture : Nil
    @calls << :toggle_capture
  end

  def intercept_toggle : Nil
    @calls << :intercept_toggle
  end

  def intercept_forward : Nil
    @calls << :intercept_forward
  end

  def intercept_drop : Nil
    @calls << :intercept_drop
  end

  def intercept_forward_all : Nil
    @calls << :intercept_forward_all
  end

  def intercept_query : Nil
    @calls << :intercept_query
  end

  def intercept_cycle_direction : Nil
    @calls << :intercept_cycle_direction
  end

  def selected_intercept_id : Int64?
    @selected
  end

  def export_ca : Nil
    @calls << :export_ca
  end

  def regenerate_ca : Nil
    @calls << :regenerate_ca
  end

  def open_browser_picker : Nil
    @calls << :open_browser_picker
  end

  def comparer_pick(slot : Symbol) : Nil
    @calls << :comparer_pick
  end

  def comparer_swap : Nil
    @calls << :comparer_swap
  end

  def comparer_toggle_pane : Nil
    @calls << :comparer_toggle_pane
  end

  def comparer_add_selected : Nil
    @calls << :comparer_add_selected
  end

  def open_settings(section : Symbol) : Nil
    @calls << :open_settings
  end
end

describe Gori::Verb do
  describe "P1: one definition feeds both keymap and palette" do
    it "resolves the same verb id via a chord AND a palette search" do
      reg = Gori::Verbs.registry
      keymap = Keymap.build(reg)

      # keybinding path: ctrl-p (Global) -> app.palette
      via_key = keymap.lookup(Chord.new("p", ctrl: true), Scope::Body)
      via_key.should eq("app.palette")

      # palette path: the Ctrl-P palette is the Global (app-control) surface
      via_palette = reg.for_scope(Scope::Global, FakeContext.new, "palette").map(&.id)
      via_palette.should contain("app.palette")
    end
  end

  describe Keymap do
    it "prefers a scope-specific binding then falls back to Global" do
      reg = Gori::Verbs.registry
      keymap = Keymap.build(reg)

      # escape in PaletteOpen -> palette.close (scope-specific)
      keymap.lookup(Chord.new("escape"), Scope::PaletteOpen).should eq("palette.close")
      # escape in HistoryDetail -> detail.close (different verb, same chord)
      keymap.lookup(Chord.new("escape"), Scope::HistoryDetail).should eq("detail.close")
      # ←/→ in HistoryDetail walk the panes (left no longer just closes)
      keymap.lookup(Chord.new("right"), Scope::HistoryDetail).should eq("detail.next-pane")
      keymap.lookup(Chord.new("left"), Scope::HistoryDetail).should eq("detail.prev-pane")
      keymap.lookup(Chord.new("x"), Scope::HistoryDetail).should eq("detail.toggle-hex")
      # a Global chord (^P palette) resolves from ANY scope
      keymap.lookup(Chord.new("p", ctrl: true), Scope::Body).should eq("app.palette")
      # 'q' (back to projects) is bound only on the tab bar (Sidebar), not in a body —
      # as a Global chord it used to dump you to the picker mid-browse.
      keymap.lookup(Chord.new("q"), Scope::Sidebar).should eq("app.back-key")
      keymap.lookup(Chord.new("q"), Scope::Body).should be_nil
      # an unbound chord
      keymap.lookup(Chord.new("z"), Scope::Body).should be_nil
      # scope-specific: the top menu navigates horizontally, the body vertically
      keymap.lookup(Chord.new("right"), Scope::Sidebar).should eq("sidebar.next")
      keymap.lookup(Chord.new("down"), Scope::Sidebar).should eq("sidebar.enter")
      keymap.lookup(Chord.new("down"), Scope::Body).should eq("body.down")
    end

    it "supports multiple chords per verb" do
      reg = Gori::Verbs.registry
      keymap = Keymap.build(reg)
      keymap.lookup(Chord.new("j"), Scope::Body).should eq("body.down")
      keymap.lookup(Chord.new("down"), Scope::Body).should eq("body.down")
    end

    it "binds ctrl-n to a new blank replay in the Replay scope" do
      reg = Gori::Verbs.registry
      keymap = Keymap.build(reg)
      keymap.lookup(Chord.new("n", ctrl: true), Scope::Replay).should eq("replay.new")

      ctx = FakeContext.new
      reg["replay.new"].call(ctx)
      ctx.calls.should contain(:replay_new)
    end

    it "descends from the tab menu via enter_content (so sub-tab tabs land on the strip first)" do
      reg = Gori::Verbs.registry
      keymap = Keymap.build(reg)
      # ↓/↵/j on the tab bar resolve to sidebar.enter…
      keymap.lookup(Chord.new("down"), Scope::Sidebar).should eq("sidebar.enter")
      keymap.lookup(Chord.new("enter"), Scope::Sidebar).should eq("sidebar.enter")

      # …which descends through enter_content (NOT focus_pane), letting the Runner
      # route Replay/Notes onto their sub-tab strip before the body.
      ctx = FakeContext.new
      reg["sidebar.enter"].call(ctx)
      ctx.calls.should contain(:enter_content)
      ctx.calls.should_not contain(:focus_pane)
    end
  end

  describe "migrated tab-local chords resolve in their per-tab scope" do
    it "binds the Replay request-pane toggles + send in Replay scope" do
      km = Keymap.build(Gori::Verbs.registry)
      km.lookup(Chord.new("r", ctrl: true), Scope::Replay).should eq("replay.send")
      km.lookup(Chord.new("x", ctrl: true), Scope::Replay).should eq("replay.toggle-hex")
      km.lookup(Chord.new("s", ctrl: true), Scope::Replay).should eq("replay.toggle-sni")
      km.lookup(Chord.new("l", ctrl: true), Scope::Replay).should eq("replay.toggle-auto-content-length")
    end

    it "binds the Fuzzer run/stop/automark chords in Fuzzer scope" do
      km = Keymap.build(Gori::Verbs.registry)
      km.lookup(Chord.new("r", ctrl: true), Scope::Fuzzer).should eq("fuzz.run")
      km.lookup(Chord.new("x", ctrl: true), Scope::Fuzzer).should eq("fuzz.stop")
      km.lookup(Chord.new("a", ctrl: true), Scope::Fuzzer).should eq("fuzz.automark")
    end

    it "binds the Intercept catch chords in Intercept scope, shadowing the Global/Body keys" do
      km = Keymap.build(Gori::Verbs.registry)
      km.lookup(Chord.new("c"), Scope::Intercept).should eq("intercept.direction")
      km.lookup(Chord.new("/"), Scope::Intercept).should eq("intercept.filter")
      # …without breaking capture (`c`) elsewhere or History's `/` filter
      km.lookup(Chord.new("c"), Scope::Body).should eq("capture.toggle")
      km.lookup(Chord.new("/"), Scope::Body).should eq("history.query")
    end

    it "routes the new Replay toggle verbs through the matching ExecContext methods" do
      reg = Gori::Verbs.registry
      ctx = FakeContext.new
      reg["replay.toggle-hex"].call(ctx)
      reg["replay.toggle-sni"].call(ctx)
      reg["replay.toggle-auto-content-length"].call(ctx)
      ctx.calls.should contain(:replay_toggle_hex)
      ctx.calls.should contain(:replay_toggle_sni)
      ctx.calls.should contain(:replay_toggle_auto_content_length)
    end
  end

  describe Registry do
    it "gates verbs by availability (P4) and hides cursor verbs from the palette" do
      reg = Gori::Verbs.registry
      ctx = FakeContext.new

      # no selection -> open-detail unavailable, copy unavailable
      ids = reg.search("", ctx).map(&.id)
      ids.should_not contain("body.open")
      ids.should_not contain("history.copy")
      ids.should_not contain("body.down") # hidden

      ctx.selected = 5_i64
      ids2 = reg.search("", ctx).map(&.id)
      ids2.should contain("body.open")
      ids2.should contain("history.copy")
    end

    it "fuzzy-ranks results and rejects non-subsequence queries" do
      reg = Gori::Verbs.registry
      ctx = FakeContext.new
      reg.search("quit", ctx).first.id.should eq("app.quit")
      reg.search("zzxq-nope", ctx).should be_empty
    end

    it "for_scope is STRICTLY scope-local — no Global fallback (the two surfaces are disjoint)" do
      reg = Gori::Verbs.registry
      ctx = FakeContext.new
      ctx.selected = 5_i64 # so the flow-gated Body actions are available

      body = reg.for_scope(Scope::Body, ctx)
      body.each do |v|
        v.hidden?.should be_false
        v.scope.should eq(Scope::Body) # strictly Body — Global app-control stays out of ":"
      end
      ids = body.map(&.id)
      ids.should contain("history.replay") # an area action surfaces
      ids.should_not contain("app.quit")   # app-control belongs to Ctrl-P, not ":"
      ids.should_not contain("nav.next-tab")

      # The palette source is the Global slice (app control) — and it has NO area actions.
      gids = reg.for_scope(Scope::Global, ctx).map(&.id)
      gids.should contain("app.quit")
      gids.should contain("nav.next-tab") # tab navigation lives in Ctrl-P
      gids.any?(&.starts_with?("history.")).should be_false

      # fuzzy query narrows within the scope (same ranking as #search)
      reg.for_scope(Scope::Body, ctx, "replay").first.id.should eq("history.replay")
    end

    it "rejects duplicate ids" do
      reg = Registry.new
      reg.register(Definition.new("dup", "A", "", Scope::Global) { |_| nil })
      expect_raises(Gori::Error, /duplicate/) do
        reg.register(Definition.new("dup", "B", "", Scope::Global) { |_| nil })
      end
    end
  end

  describe "handler execution" do
    it "runs through Definition#call and returns the handler's status message" do
      ctx = FakeContext.new
      verb = Definition.new("t.msg", "T", "", Scope::Global) { |_c| "did it" }
      verb.call(ctx).should eq("did it")

      reg = Gori::Verbs.registry
      reg["app.quit"].call(ctx)
      ctx.calls.should contain(:quit)
    end
  end
end
