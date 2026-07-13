require "../tab_controller"
require "../intercept_view"
require "../url"
require "../../interceptor"
require "../../hotkeys"

module Gori::Tui
  # The Intercept tab: the hold-and-decide queue (P4). Owns the InterceptView (a
  # list pane + an inline editor pane) and the intercept verbs. The shell frames
  # the body (like History/Replay's empty state); the view self-frames its inner
  # panes. Reloaded every frame off the 50ms loop so async holds appear live.
  # `view` is exposed for the shell's still-centralized orthogonal prompts (^G/^F/^E).
  class InterceptController < TabController
    def initialize(host : Host)
      super(host)
      @intercept = InterceptView.new
    end

    def view : InterceptView
      @intercept
    end

    def tab : Symbol
      :intercept
    end

    def command_scope : Verb::Scope
      Verb::Scope::Intercept
    end

    def body_badge : Symbol # the editor / condition bar capture text; else the queue list
      @intercept.editing? || @intercept.querying? ? :editor : :body
    end

    def body_hint(focus : Symbol) : String
      reg = @host.session.registry
      if @intercept.editing?
        "type to edit · ^R forward · ⇧↹/esc queue"
      elsif @intercept.querying?
        "type condition · ↵ apply · esc clear"
      else
        f = Hotkeys.binding_label(reg, "intercept.forward", "f")
        d = Hotkeys.binding_label(reg, "intercept.drop", "d")
        fa = Hotkeys.binding_label(reg, "intercept.forward-all", "⇧F")
        filt = Hotkeys.binding_label(reg, "intercept.filter", "/")
        catch = Hotkeys.binding_label(reg, "intercept.direction", "c")
        on = Hotkeys.binding_label(reg, "intercept.toggle", "i")
        "↑/↓ move · ⇧←/→ h-scroll · ↵/e edit · #{f} fwd · #{d} drop · #{fa} all · #{filt} filter · #{catch} catch · #{on} on/off · space cmds · ↹ detail · esc tabs"
      end
    end

    def goto_symbol : Symbol? # the held-message editor is ^G/^F-searchable
      @intercept.editing? ? :intercept : nil
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      @intercept.reload(@host.session.interceptor) # live refresh (50ms loop)
      proxy = @host.session.proxy
      body_focused = focus == :body
      shell = BodyChrome.shell_focused(focus, multi_pane: !@intercept.empty?)
      BodyChrome.framed(screen, rect, shell) do |inner|
        @intercept.render(screen, inner, focused: body_focused,
          listen: "#{proxy.host}:#{proxy.port}", capturing: @host.session.capturing?)
      end
    end

    def handle_body_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      if ev.ctrl? && key.lower_p?
        @host.open_palette
        true
      elsif ev.key.space? && !ev.ctrl? && !ev.alt? && !@intercept.editing?
        @host.open_space_menu # space menu in the navigable queue (editing swallows space as a char)
        true
      elsif @intercept.editing?
        handle_edit_key(ev)
        true
      else
        # shift+←/→/↑/↓ (scroll the read-only preview) checked here rather than inside
        # handle_queue_key — that dispatch is already at ameba's complexity ceiling.
        queue_key_scroll(ev) || handle_queue_key(ev) # false for c / / (and other unhandled keys) → defer to the keymap
      end
    end

    # Keys while editing the held-message bytes (the right detail editor).
    private def handle_edit_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if key.escape?
        @intercept.stop_edit
      elsif ev.ctrl? && key.lower_r?
        intercept_forward
      elsif key.enter?
        @intercept.edit_newline
      elsif ev.ctrl_z?
        @intercept.edit_undo
      elsif key.backspace?
        @intercept.edit_backspace
      elsif key.up?
        @intercept.edit_move(-1, 0)
      elsif key.down?
        @intercept.edit_move(1, 0)
      elsif key.left?
        @intercept.edit_move(0, -1)
      elsif key.right?
        @intercept.edit_move(0, 1)
      elsif key.home?
        @intercept.edit_home
      elsif key.end?
        @intercept.edit_end
      elsif key.delete?
        @intercept.edit_delete
      elsif c && !ev.ctrl? && !ev.alt?
        @intercept.edit_insert(c)
      end
    end

    # Keys while navigating the held queue (the left list). Returns true when consumed;
    # false defers to the keymap — catch `c`, filter `/`, forward/drop/all, Global
    # intercept toggle `i`, and breath keys are rebindable verbs. The queue is a
    # navigable list (not a text field), so deferring is safe; the held-bytes editor
    # and condition bar keep swallowing `c`/`/` as literal text (separate handlers).
    private def handle_queue_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      # Modified chords (^F find, etc.) must not hit list actions — bare `lower_f?`
      # would also match Ctrl+F and irreversibly forward a held message.
      return false if ev.ctrl? || ev.alt?
      case
      when key.escape?              then @host.request_focus(:menu)
      when key.lower_j?, key.down?  then @intercept.move(1)
      when key.lower_k?, key.up?    then @intercept.at_top? ? @host.request_focus(:menu) : @intercept.move(-1)
      when key.enter?, key.lower_e? then @intercept.toggle_edit
      else                               return false # f/d/⇧F/i/c/… → keymap
      end
      true
    end

    # Shift+←/→ (horizontal) and Shift+↑/↓ (vertical) scroll for the read-only held-item
    # preview — kept OUT of handle_queue_key (called from handle_body_key instead), since
    # that dispatch is already at ameba's complexity ceiling. Bare arrows still navigate the
    # queue (handle_queue_key); only the shifted arrows scroll the preview, so a tall held
    # body is fully readable without entering edit mode.
    private def queue_key_scroll(ev : Termisu::Event::Key) : Bool
      key = ev.key
      return false unless ev.shift?
      if key.left?
        @intercept.hscroll_detail(-1)
      elsif key.right?
        @intercept.hscroll_detail(1)
      elsif key.up?
        @intercept.vscroll_detail(-1)
      elsif key.down?
        @intercept.vscroll_detail(1)
      else
        return false
      end
      true
    end

    # --- catch-condition filter bar (a text sub-mode; the shell claims it before the
    # focus ring, exactly like History's QL bar). Returns true (always swallows). ---
    def querying? : Bool
      @intercept.querying?
    end

    def handle_query_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      ic = @host.session.interceptor
      case
      when key.enter?     then @intercept.stop_query
      when key.escape?    then @intercept.cancel_query; ic.set_filter("")
      when key.backspace? then @intercept.query_backspace; ic.set_filter(@intercept.query)
      when key.left?      then @intercept.query_move(-1)
      when key.right?     then @intercept.query_move(1)
      else
        if c && !ev.ctrl? && !ev.alt?
          @intercept.query_insert(c)
          ic.set_filter(@intercept.query) # live: narrow holding as you type (only ever narrows from "all")
          @intercept.set_preedit("")
        end
      end
      true
    end

    # Live IME composition only flows to the condition bar (the one text field besides
    # the held-message editor, which the shell routes via ^F/^G, not preedit).
    def set_preedit(text : String) : Bool
      return false unless @intercept.querying?
      @intercept.set_preedit(text)
      true
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      inner = rect.inset(1, 1)                        # framed insets 1,1
      if zone = @intercept.bar_zone_at(inner, mx, my) # click the top filter bar
        @host.focus_body
        case zone
        when :catch     then intercept_toggle
        when :direction then intercept_cycle_direction
        else                 intercept_query
        end
        return true
      end
      return true unless pane = @intercept.pane_at(inner, mx, my)
      @host.focus_body
      if pane == :list
        @intercept.focus_list
        if idx = @intercept.list_row_at(inner, mx, my)
          @intercept.select_index(idx)
        end
      else
        @intercept.focus_detail
        @intercept.editor_click_to_cursor(inner, mx, my)
      end
      true
    end

    def handle_wheel(step : Int32) : Bool
      @intercept.move(step)
      true
    end

    def on_enter : Nil
      @intercept.reload(@host.session.interceptor)
    end

    # Editor-style Tab: in the held-message editor, forward Tab types a tab rather than
    # advancing the focus ring (Shift-Tab / esc still leave for the queue).
    def editor_captures_tab? : Bool
      @intercept.editing?
    end

    def handle_editor_tab(ev : Termisu::Event::Key) : Bool
      return false unless @intercept.editing?
      @intercept.edit_insert('\t')
      true
    end

    # --- focus ring (list ◂▸ detail editor) ---
    def pane_advance(dir : Int32) : Bool
      @intercept.pane_advance(dir)
    end

    def focus_first : Nil
      @intercept.focus_first
    end

    def focus_last : Nil
      @intercept.focus_last
    end

    # --- verbs (delegated from the Runner's ExecContext; also called inline above) ---
    def intercept_toggle : Nil
      on = @host.session.interceptor.toggle
      @intercept.reload(@host.session.interceptor)
      @host.status(on ? "intercept ON — held traffic waits (HTTPS→h1 for in-scope; gRPC may fail)" : "intercept off")
    end

    def intercept_forward : Nil
      return unless it = @intercept.selected_item
      @host.session.interceptor.forward(it.id, @intercept.forward_bytes(it))
      @intercept.reload(@host.session.interceptor)
      @host.status("forwarded #{intercept_label(it)}")
    end

    def intercept_drop : Nil
      return unless it = @intercept.selected_item
      @host.session.interceptor.drop(it.id)
      @intercept.reload(@host.session.interceptor)
      @host.status("dropped #{intercept_label(it)}")
    end

    def intercept_forward_all : Nil
      n = @host.session.interceptor.pending_count
      # Carry the currently-loaded item's in-progress edit into the bulk forward, so
      # "forward all" doesn't send its stale original bytes (single-forward already does).
      overrides = @intercept.pending_edit.try { |e| {e[0] => e[1]} }
      @host.session.interceptor.forward_all(overrides)
      @intercept.reload(@host.session.interceptor)
      @host.status("forwarded all (#{n})")
    end

    # Open the catch-condition filter bar (a query that narrows which messages hold).
    def intercept_query : Nil
      @intercept.start_query
      @host.status("catch condition: host: method: path: status: scheme: · ↵ apply · esc clear")
    end

    # Cycle which leg(s) to hold: all → requests → responses → all.
    def intercept_cycle_direction : Nil
      dir = @host.session.interceptor.cycle_direction
      @intercept.reload(@host.session.interceptor)
      @host.status("intercept catch: #{direction_phrase(dir)}")
    end

    private def direction_phrase(dir : Interceptor::Direction) : String
      case dir
      when .request_only?  then "requests only"
      when .response_only? then "responses only"
      else                      "requests & responses"
      end
    end

    def selected_intercept_id : Int64?
      @intercept.selected_id
    end

    # A short human label for a held item — "GET /path" (request) or the status line
    # (response) — for forward/drop toasts; the queue's internal id means nothing to the
    # user. Reads the EDITED method/status (via the view) so a forwarded edit shows what
    # was actually sent, not the stale hold-time metadata.
    private def intercept_label(it : Interceptor::Item) : String
      method, target = @intercept.effective_method_target(it)
      it.kind.request? ? "#{method} #{Url.origin_path(target)}" : target
    end
  end
end
