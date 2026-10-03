require "../tab_controller"
require "../comparer_view"
require "../subtab_clone"
require "./memory_session_strip"
require "../../hotkeys"

module Gori::Tui
  # The Comparer tab: multi-session (sub-tabs) workspace for side-by-side flow diffs.
  # Each session is an independent ComparerView (A/B slots + pane + scroll). Session-
  # only (no project DB) — switching sub-tabs keeps prior pairs so History "Send to
  # Comparer" no longer clobbers earlier work. Strip chrome mirrors Decoder/Repeater.
  class ComparerController < TabController
    include MemorySessionStrip

    def initialize(host : Host)
      super(host)
      @sessions = [ComparerView.new] of ComparerView
      @idx = 0
    end

    def view : ComparerView
      @sessions[@idx]
    end

    # Display… rows (#1274): which half of the two flows is diffed, and the fold.
    def menu_state(verb_id : String) : String?
      case verb_id
      when "comparer.toggle-pane" then "#{view.pane}s"
      when "comparer.toggle-fold" then SpaceMenu.on_off(view.fold?)
      end
    end

    def tab : Symbol
      :comparer
    end

    def command_scope : Verb::Scope
      Verb::Scope::Comparer
    end

    # --- sub-tab strip: `MemorySessionStrip`, plus the filter's fields and search ---
    # A session IS its view, and labels itself.
    private def session_label(v : ComparerView) : String
      v.label
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

    def comparer_new : Nil
      @sessions << ComparerView.new
      @idx = @sessions.size - 1
      @host.request_focus(:body)
      @host.status("new comparison (#{@sessions.size} open)")
    end

    # Close the active session, or the marked ones. The last one is reset to blank (always
    # keep ≥1).
    def comparer_close : Nil
      close_sessions("CLOSE COMPARISONS", "Each pair of slots is discarded.", "comparison cleared", "comparison closed")
    end

    # The last comparison is RESET IN PLACE rather than replaced — which is exactly why the
    # batch driver hands its marks back explicitly instead of leaning on `SubtabMarks#retain`:
    # this view object survives the close, so "still open" and "still marked" would otherwise
    # both stay true.
    private def blank_session(old : ComparerView) : ComparerView
      old.reset!
      old
    end

    def comparer_duplicate : Nil
      duplicate_sessions("comparison", "duplicated comparison")
    end

    # Clone sub-tab `idx` onto the end of the strip. Toast-free.
    private def duplicate_at(idx : Int32) : Nil
      return unless src = @sessions[idx]?
      @sessions << src.duplicate
      @idx = @sessions.size - 1
    end

    def view_at(idx : Int32) : ComparerView?
      (0 <= idx < @sessions.size) ? @sessions[idx] : nil
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
      # ^N / ^W from the body, as the Decoder/JWT/Cookie bodies take them — they answered
      # only from the sub-tab strip here.
      if ev.ctrl? && key.lower_n?
        comparer_new
        return true
      elsif ev.ctrl? && key.lower_w?
        comparer_close # confirm-gated in the controller; the shell re-seats focus after
        @host.resolve_subtab_focus
        return true
      end
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

    # Pointer-aware: only the diff BODY scrolls; a notch on the chip row / header is inert
    # rather than scrolling a body the pointer is not over. Same rects `handle_click` uses.
    def handle_wheel_at(step : Int32, mx : Int32, my : Int32, rect : Rect) : Bool
      inner = body_rect_below_filter(rect)
      body = view.body_rect(inner)
      view.wheel(step) if body.contains?(mx, my) || !inner.contains?(mx, my)
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

    def selection_active? : Bool
      view.selection?
    end

    def selection_text : String
      view.copy_text
    end

    def select_line : Nil
      view.select_row_line
    end

    def clear_selection : Nil
      view.clear_selection
    end

    # `y`: the selected rows, or the whole diff when nothing is selected — as unified text, which
    # is the only form a two-column diff has that pastes anywhere useful.
    def comparer_copy : Nil
      return unless view.both_set?
      sel = view.selection?
      text = sel ? view.copy_text : view.copy_all
      return if text.empty?
      copy_text(text, sel ? nil : "all")
    end

    def body_hint(focus : Symbol) : String
      # prev-change is its OWN verb (⇧P), not "shift + whatever next-change is bound to": the
      # old `⇧#{n}` spelling followed a rebind of `n` to a key ⇧ never reached.
      # `esc sub-tabs` last, where every other tab's line ends it. `handle_body_key` has
      # always sent escape to the strip; the hint was the only tab-level line in the app that
      # never said so, and a line this long is exactly where a reader stops looking.
      keys("←/→ req|res · ↑/↓ row · {comparer.next-change}/{comparer.prev-change} change · {space:comparer.toggle-fold} fold · {comparer.copy} copy · ⇧←/→ h-scroll · {comparer.pick-a}/{comparer.pick-b} pick · {comparer.swap} swap · space cmds · esc sub-tabs")
    end
  end
end
