require "../tab_controller"
require "../comparer_view"
require "../subtab_clone"
require "../../hotkeys"

module Gori::Tui
  # The Comparer tab: multi-session (sub-tabs) workspace for side-by-side flow diffs.
  # Each session is an independent ComparerView (A/B slots + pane + scroll). Session-
  # only (no project DB) — switching sub-tabs keeps prior pairs so History "Send to
  # Comparer" no longer clobbers earlier work. Strip chrome mirrors Decoder/Repeater.
  class ComparerController < TabController
    def initialize(host : Host)
      super(host)
      @sessions = [ComparerView.new] of ComparerView
      @idx = 0
    end

    def view : ComparerView
      @sessions[@idx]
    end

    def tab : Symbol
      :comparer
    end

    def command_scope : Verb::Scope
      Verb::Scope::Comparer
    end

    # --- sub-tab strip -------------------------------------------------------

    def subtab_labels : Array(String)
      @sessions.map_with_index { |v, i| "#{i + 1}:#{v.label}" }
    end

    def subtab_index : Int32
      @idx
    end

    def subtab_strip_shown? : Bool
      true # from the first session (Repeater/Notes style)
    end

    # --- sub-tab filter (issue #121) ---
    def subtab_filter_enabled? : Bool
      true
    end

    def filter_fields : Array(String)
      %w[name host method] # each session's A/B slots carry a target + method
    end

    def filter_subjects : Array(Repeater::SubtabFilter::Subject)
      @sessions.map(&.filter_subject)
    end

    # The ⌕ picker searches both slots' request lines (capped) — a comparison is findable
    # by a header the operator diffed, not just the two targets the summary names.
    def subtab_search_extras : Array(String)
      @sessions.map { |v| search_extra(v.search_text) }
    end

    # Filter-aware strip nav: ←/→ skip hidden chips; ^1-9 to a hidden chip drops the
    # filter (chip numbers are absolute). Sessions are in-memory, so no persist on switch.
    def move_subtab(dir : Int32) : Nil
      if t = step_visible(@idx, dir)
        @idx = t
      end
    end

    def jump_subtab(idx : Int32) : Nil
      return unless 0 <= idx < @sessions.size
      clear_subtab_filter if (h = subtab_hidden) && h.includes?(idx)
      @idx = idx if idx != @idx
    end

    def comparer_new : Nil
      @sessions << ComparerView.new
      @idx = @sessions.size - 1
      @host.request_focus(:body)
      @host.status("new comparison (#{@sessions.size} open)")
    end

    # Close active session. Last session is reset to blank (always keep ≥1).
    # ^W closes the MARKED sub-tabs when the strip carries marks, the active one otherwise
    # (`target_subtab_indices` — the one target rule).
    def comparer_close : Nil
      if refs = batch_subtab_refs
        @host.confirm("CLOSE COMPARISONS", "Close #{marked_subtab_phrase(refs.size)}?\nEach pair of slots is discarded.",
          confirm_label: "close", danger: true) { close_marked_sessions(refs) }
        return
      end
      close_at(@idx)
      @host.status(@sessions.size == 1 ? "comparison cleared" : "comparison closed (#{@sessions.size} open)")
    end

    private def close_marked_sessions(refs : Array(SubtabRef)) : Nil
      @host.status(close_marked_subtabs(refs))
      @host.resolve_subtab_focus
    end

    # Nothing here is persisted, so a close can never leave a saved session behind.
    protected def close_subtab_at(idx : Int32) : Bool
      close_at(idx)
      false
    end

    # Close sub-tab `idx`, keeping at least one comparison. The last one is RESET IN PLACE
    # rather than replaced — which is exactly why the batch driver hands its marks back
    # explicitly instead of leaning on `SubtabMarks#retain`: this view object survives the
    # close, so "still open" and "still marked" would otherwise both stay true.
    private def close_at(idx : Int32) : Nil
      return if idx < 0 || idx >= @sessions.size
      if @sessions.size <= 1
        @sessions[0].reset!
        @idx = 0
      else
        @sessions.delete_at(idx)
        # Closing a session to the LEFT slides the active one down; a bare clamp would read
        # that as "stay put" and land the operator on its neighbour.
        @idx -= 1 if idx < @idx
        @idx = @idx.clamp(0, @sessions.size - 1)
      end
    end

    # Duplicates the MARKED sub-tabs when the strip carries marks, the active one otherwise
    # (`target_subtab_indices` — the one target rule).
    def comparer_duplicate : Nil
      if refs = batch_subtab_refs
        msg = duplicate_marked_subtabs(refs, "comparison") { |i| duplicate_at(i) }
        unless msg
          @host.status("#{refs.size} sub-tabs marked — duplicate is capped at #{Runner::BATCH_SUBTAB_CAP}")
          return
        end
        @host.request_focus(:body)
        @host.status("#{msg} (#{@sessions.size} open)")
        return
      end
      duplicate_at(@idx)
      @host.request_focus(:body)
      @host.status("duplicated comparison (#{@sessions.size} open)")
    end

    # Clone sub-tab `idx` onto the end of the strip. Toast-free — the arms above say it.
    private def duplicate_at(idx : Int32) : Nil
      return unless src = @sessions[idx]?
      @sessions << src.duplicate
      @idx = @sessions.size - 1
    end

    def view_at(idx : Int32) : ComparerView?
      (0 <= idx < @sessions.size) ? @sessions[idx] : nil
    end

    # The object that IS sub-tab `idx`, for the strip's mark set (#683). The view, not the
    # index: a reconcile can reorder or drop chips under a standing mark.
    def subtab_ref(idx : Int32) : SubtabRef?
      view_at(idx)
    end

    def apply_rename(v : ComparerView, name : String) : Nil
      return unless @sessions.any?(&.same?(v))
      clean = name.strip
      v.name = clean.empty? ? nil : clean
    end

    # --- render / input ------------------------------------------------------

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      labels = subtab_strip_shown? ? subtab_labels : nil
      shell = BodyChrome.shell_focused(focus, multi_pane: false)
      subtabs_focused = focus == :subtabs
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, subtabs_focused, labels, @idx, @subtab_start, subtab_hidden, strip_divider: subtab_strip_divider?, find: subtab_find_shown?, find_lit: @host.subtab_find_focused?, marked: marked_chip_set) do |content|
        render_with_filter(screen, content, subtabs_focused) do |body|
          view.render(screen, body, focused: body_focused)
        end
      end
    end

    # Scroll + request/response toggle; a/b/s fall through to the verb keymap.
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      return true if handle_body_hscroll(ev)
      case
      when nav_up?(ev)
        # The cursor moves and drags the viewport with it; ⇧ grows a row selection. At the top
        # the ↑ still leaves for the sub-tab strip, as it always did.
        view.at_top? ? @host.request_focus(:subtabs) : view.move_rows(-1, ev.shift?)
        true
      when nav_down?(ev)
        view.move_rows(1, ev.shift?)
        true
      when nav_left?(ev), nav_right?(ev)
        view.toggle_pane
        true
      when key.escape?
        @host.request_focus(:subtabs)
        true
      else
        view.motion_key(ev) # Home / End / PgUp / PgDn, ⇧ extending
      end
    end

    # ⇧←/→ scrolls both diff columns sideways. Checked BEFORE the plain ←/→ pane toggle:
    # the bare arrows keep switching REQ ⇄ RES, the shifted ones never reach that branch.
    private def handle_body_hscroll(ev : Termisu::Event::Key) : Bool
      return false unless ev.shift?
      key = ev.key
      if key.left?
        view.hscroll(-1)
        true
      elsif key.right?
        view.hscroll(1)
        true
      else
        false
      end
    end

    # A wheel notch scrolls the viewport and leaves the row cursor where it is — a reading
    # gesture, not a cursor one. ↑/↓ are the cursor.
    def handle_wheel(step : Int32) : Bool
      view.wheel(step)
      true
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      # Carve the sub-tab strip AND the filter bar too (like Repeater), not just the
      # border — the view renders the REQ/RES chips inside that content rect, so a plain
      # inset(1,1) would hit-test the chrome rows too high and never match the chips.
      inner = body_rect_below_filter(rect)
      if pane = view.pane_chip_at(inner, mx, my)
        view.set_pane(pane)
        return true
      end
      body = view.body_rect(inner)
      view.click_row(body, mx, my) unless body.empty?
      true
    end

    # --- mouse drag + double-click (see TabController#supports_drag?) ---
    # A drag grows the ROW selection; there is no word to double-click (two columns, see
    # `ComparerView`'s row-cursor note), so the double-click declines and the plain click stands.
    def supports_drag? : Bool
      view.both_set?
    end

    def handle_drag(rect : Rect, mx : Int32, my : Int32) : Nil
      body = view.body_rect(body_rect_below_filter(rect))
      view.click_row(body, mx, my, selecting: true) unless body.empty?
    end

    # --- READ-pane delegators (the Comparer read verbs + the Runner's read_* ladders) ---
    def comparer_diff_shown? : Bool
      view.both_set?
    end

    def comparer_selection_active? : Bool
      view.selection?
    end

    def comparer_selection_text : String
      view.copy_text
    end

    def comparer_select_line : Nil
      view.select_row_line
    end

    def comparer_clear_selection : Nil
      view.clear_selection
    end

    # `y`: the selected rows, or the whole diff when nothing is selected — as unified text, which
    # is the only form a two-column diff has that pastes anywhere useful.
    def comparer_copy : Nil
      return unless view.both_set?
      sel = view.selection?
      text = sel ? view.copy_text : view.copy_all
      return if text.empty?
      written = Clipboard.copy(text)
      note = Clipboard.note(written, text)
      @host.status(sel ? "copied #{written}b to clipboard#{note}" : "copied all (#{written}b)#{note}")
    end

    def body_hint(focus : Symbol) : String
      # prev-change is its OWN verb (⇧N), not "shift + whatever next-change is bound to": the
      # old `⇧#{n}` spelling followed a rebind of `n` to a key ⇧ never reached.
      keys("←/→ req|res · ↑/↓ row · {comparer.next-change}/{comparer.prev-change} change · {comparer.toggle-fold} fold · {comparer.copy} copy · ⇧←/→ h-scroll · {comparer.pick-a}/{comparer.pick-b} pick · {comparer.swap} swap · space cmds")
    end
  end
end
