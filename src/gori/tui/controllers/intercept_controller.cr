require "../tab_controller"
require "../intercept_view"
require "../url"
require "../../interceptor"

module Gori::Tui
  # The Intercept tab: the hold-and-decide queue (P4). Owns the InterceptView (a
  # list pane + an inline editor pane) and the intercept verbs. The view self-frames
  # its panes and is reloaded every frame off the 50ms loop so async holds appear
  # live. `view` is exposed for the shell's still-centralized orthogonal prompts
  # (^G/^F/^E) until Step 10 inverts those to the Searchable/edit hooks.
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

    def body_badge : Symbol # the held-message editor captures text; else the queue list
      @intercept.editing? ? :editor : :body
    end

    def body_hint(focus : Symbol) : String
      @intercept.editing? ? "type to edit · ^R forward · ⇧↹/esc queue" \
                          : "↑/↓ move · ↵/e edit · f forward · d drop · F all · : cmds · ↹ detail · esc tabs"
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
      c = ev.char || key.to_char
      if ev.ctrl? && key.lower_p?
        @host.open_palette
      elsif ev.char == ':' && !ev.ctrl? && !ev.alt? && !@intercept.editing?
        @host.open_command # ":" cmdline in the navigable queue (editing swallows ":" as a char)
      elsif @intercept.editing?
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
        elsif c && !ev.ctrl? && !ev.alt?
          @intercept.edit_insert(c)
        end
      else
        case
        when key.escape?               then @host.request_focus(:menu)
        when key.lower_j?, key.down?   then @intercept.move(1)
        when key.lower_k?, key.up?     then @intercept.at_top? ? @host.request_focus(:menu) : @intercept.move(-1)
        when key.enter?, key.lower_e?  then @intercept.toggle_edit
        when key.lower_f? && ev.shift? then intercept_forward_all
        when key.lower_f?              then intercept_forward
        when key.lower_d?              then intercept_drop
        end
      end
      true
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
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
