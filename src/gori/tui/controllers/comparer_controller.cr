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
    def comparer_close : Nil
      if @sessions.size <= 1
        @sessions[0].reset!
        @idx = 0
        @host.status("comparison cleared")
      else
        @sessions.delete_at(@idx)
        @idx = @idx.clamp(0, @sessions.size - 1)
        @host.status("comparison closed (#{@sessions.size} open)")
      end
    end

    def comparer_duplicate : Nil
      @sessions << view.duplicate
      @idx = @sessions.size - 1
      @host.request_focus(:body)
      @host.status("duplicated comparison (#{@sessions.size} open)")
    end

    def view_at(idx : Int32) : ComparerView?
      (0 <= idx < @sessions.size) ? @sessions[idx] : nil
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
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, subtabs_focused, labels, @idx, @subtab_start, subtab_hidden, strip_divider: subtab_strip_divider?, find: subtab_find_count, find_lit: @host.subtab_find_focused?) do |content|
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
      when key.up?, key.lower_k?
        # The cursor moves and drags the viewport with it; ⇧ grows a row selection. At the top
        # the ↑ still leaves for the sub-tab strip, as it always did.
        view.at_top? ? @host.request_focus(:subtabs) : view.move_rows(-1, ev.shift?)
        true
      when key.down?, key.lower_j?
        view.move_rows(1, ev.shift?)
        true
      when key.left?, key.right?, key.lower_h?, key.lower_l?
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
      reg = @host.session.registry
      a = Hotkeys.binding_label(reg, "comparer.pick-a", "a")
      b = Hotkeys.binding_label(reg, "comparer.pick-b", "b")
      s = Hotkeys.binding_label(reg, "comparer.swap", "s")
      n = Hotkeys.binding_label(reg, "comparer.next-change", "n")
      f = Hotkeys.binding_label(reg, "comparer.toggle-fold", "f")
      "←/→ req|res · ↑/↓ row · #{n}/⇧#{n} change · #{f} fold · y copy · ⇧←/→ h-scroll · #{a}/#{b} pick · #{s} swap · space cmds"
    end
  end
end
