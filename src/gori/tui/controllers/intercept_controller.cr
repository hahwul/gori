require "../tab_controller"
require "../intercept_view"
require "../url"
require "../../interceptor"

module Gori::Tui
  # The Intercept tab: the hold-and-decide queue (P4). Owns the InterceptView (a
  # list pane + an inline editor pane) and the intercept verbs. The view self-frames
  # its panes and is reloaded every frame off the 50ms loop so async holds appear
  # live. `view` is exposed for the shell's still-centralized orthogonal prompts
  # (^G/^F/^E).
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
      if @intercept.editing?
        "type to edit · ^R forward · ⇧↹/esc queue"
      elsif @intercept.querying?
        "type condition · ↵ apply · esc clear"
      else
        "↑/↓ move · ⇧←/→ h-scroll · ↵/e edit · f fwd · d drop · F all · / filter · c catch · i on/off · space cmds · ↹ detail · esc tabs"
      end
    end

    def goto_symbol : Symbol? # the held-message editor is ^G/^F-searchable
      @intercept.editing? ? :intercept : nil
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      @intercept.reload(@host.session.interceptor)             # live refresh (50ms loop)
      @intercept.render(screen, rect, focused: focus == :body) # view frames its own panes
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
        # shift+←/→ (h-scroll the preview) checked here rather than inside
        # handle_queue_key — that dispatch is already at ameba's complexity ceiling.
        queue_key_hscroll(ev) || handle_queue_key(ev) # false for c / / (and other unhandled keys) → defer to the keymap
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
    # false (the catch `c` / filter `/`, and anything unhandled) defers to the keymap —
    # those are now Intercept-scope verbs so they're rebindable. The queue is a navigable
    # list (not a text field), so deferring unhandled keys is safe; the held-bytes editor
    # and condition bar keep swallowing `c`/`/` as literal text (separate handlers).
    # ⇧F = "forward all". Most terminals deliver a typed capital as the char 'F' with NO
    # shift modifier (only Kitty's protocol sets shift), so accept both (cf. Keybind's
    # `c.ascii_uppercase?` normalisation) — else ⇧F is a dead key on a plain terminal.
    private def forward_all_key?(ev : Termisu::Event::Key) : Bool
      (ev.key.lower_f? && ev.shift?) || (ev.char || ev.key.to_char) == 'F'
    end

    private def handle_queue_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      # A modified chord (^F, alt+…) must NOT trigger a queue action — bare `key.lower_f?`
      # matches Ctrl+F too, which would IRREVERSIBLY forward the selected held message.
      # Defer modified chords to the central keymap (shift is kept for ⇧F forward-all).
      return false if ev.ctrl? || ev.alt?
      case
      when key.escape?              then @host.request_focus(:menu)
      when key.lower_j?, key.down?  then @intercept.move(1)
      when key.lower_k?, key.up?    then @intercept.at_top? ? @host.request_focus(:menu) : @intercept.move(-1)
      when key.enter?, key.lower_e? then @intercept.toggle_edit
      when forward_all_key?(ev)     then intercept_forward_all
      when key.lower_f?             then intercept_forward
      when key.lower_d?             then intercept_drop
      when key.lower_i?             then intercept_toggle
      else                               return false
      end
      true
    end

    # Shift+←/→ horizontal scroll for the read-only held-item preview — kept OUT of
    # handle_queue_key (called from handle_body_key instead), since that dispatch is
    # already at ameba's complexity ceiling.
    private def queue_key_hscroll(ev : Termisu::Event::Key) : Bool
      key = ev.key
      if key.left? && ev.shift?
        @intercept.hscroll_detail(-1)
        true
      elsif key.right? && ev.shift?
        @intercept.hscroll_detail(1)
        true
      else
        false
      end
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
      if zone = @intercept.bar_zone_at(rect, mx, my) # click the top filter bar
        @host.focus_body
        zone == :direction ? intercept_cycle_direction : intercept_query
        return true
      end
      return true unless pane = @intercept.pane_at(rect, mx, my)
      @host.focus_body
      if pane == :list
        @intercept.focus_list
        if idx = @intercept.list_row_at(rect, mx, my)
          @intercept.select_index(idx)
        end
      else
        @intercept.focus_detail
        @intercept.editor_click_to_cursor(rect, mx, my)
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
      @host.session.interceptor.forward_all
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
    # (response) — for forward/drop toasts; the queue's internal id means nothing to the user.
    private def intercept_label(it : Interceptor::Item) : String
      it.kind.request? ? "#{it.method} #{Url.origin_path(it.target)}" : it.target
    end
  end
end
