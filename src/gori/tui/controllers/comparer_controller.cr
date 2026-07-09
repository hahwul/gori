require "../tab_controller"
require "../comparer_view"
require "../subtab_clone"

module Gori::Tui
  # The Comparer tab: multi-session (sub-tabs) workspace for side-by-side flow diffs.
  # Each session is an independent ComparerView (A/B slots + pane + scroll). Session-
  # only (no project DB) — switching sub-tabs keeps prior pairs so History "Send to
  # Comparer" no longer clobbers earlier work. Strip chrome mirrors Convert/Replay.
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
      true # from the first session (Replay/Notes style)
    end

    def move_subtab(dir : Int32) : Nil
      return if @sessions.size < 2
      nidx = (@idx + dir).clamp(0, @sessions.size - 1)
      @idx = nidx unless nidx == @idx
    end

    def jump_subtab(idx : Int32) : Nil
      @idx = idx if 0 <= idx < @sessions.size && idx != @idx
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
      return unless @sessions.any? { |s| s.same?(v) }
      clean = name.strip
      v.name = clean.empty? ? nil : clean
    end

    # --- render / input ------------------------------------------------------

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      body_focused = focus == :body
      labels = subtab_strip_shown? ? subtab_labels : nil
      shell = BodyChrome.shell_focused(focus, multi_pane: false)
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, focus == :subtabs, labels, @idx, @subtab_start) do |content|
        view.render(screen, content, focused: body_focused)
      end
    end

    # Scroll + request/response toggle; a/b/s fall through to the verb keymap.
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      case
      when key.up?, key.lower_k?
        if view.at_top?
          @host.request_focus(:subtabs)
        else
          view.scroll(-1)
        end
        true
      when key.down?, key.lower_j?
        view.scroll(1)
        true
      when key.left?, key.right?, key.lower_h?, key.lower_l?
        view.toggle_pane
        true
      when key.escape?
        @host.request_focus(:subtabs)
        true
      else
        false
      end
    end

    def handle_wheel(step : Int32) : Bool
      view.scroll(step)
      true
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      inner = rect.inset(1, 1)
      if pane = view.pane_chip_at(inner, mx, my)
        view.set_pane(pane)
      end
      true
    end

    def body_hint(focus : Symbol) : String
      "←/→ req|res · ↑/↓ scroll · a/b pick · s swap · ^N new · ^W close · space cmds · ↹/esc tabs"
    end
  end
end
