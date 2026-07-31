require "../tab_controller"
require "../intercept_view"
require "../url"
require "../../interceptor"
require "../../hotkeys"

module Gori::Tui
  # The Intercept tab: the hold-and-decide queue (P4). Owns the InterceptView (a
  # list pane + an inline editor pane) and the intercept verbs. The shell frames
  # the body (like History/Repeater's empty state); the view self-frames its inner
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
        "type condition · ↹ complete · ↵ apply · esc clear"
      else
        queue_hint(reg)
      end
    end

    # The queue hint. Over a mark set it says so and names the batch keys — forward/drop then
    # act on every mark, so a hint still reading "fwd" would understate what `f` is about to
    # do. (`i on/off` and `↹ detail` come off the base line to make room: the i:CATCH chip
    # already carries its own chord, and Tab is the app-wide focus ring.)
    private def queue_hint(reg : Verb::Registry) : String
      f = Hotkeys.binding_label(reg, "intercept.forward", "f")
      d = Hotkeys.binding_label(reg, "intercept.drop", "d")
      mark = Hotkeys.binding_label(reg, "intercept.mark-toggle", "t")
      n = @intercept.mark_count
      if n > 0
        all = Hotkeys.binding_label(reg, "intercept.mark-all", "⇧T")
        return "#{n} marked · #{f} fwd all · #{d} drop all · #{mark} mark · #{all} mark all · esc clear · space cmds"
      end
      fa = Hotkeys.binding_label(reg, "intercept.forward-all", "⇧F")
      filt = Hotkeys.binding_label(reg, "intercept.filter", "/")
      catch = Hotkeys.binding_label(reg, "intercept.direction", "c")
      "↑/↓ move · #{mark} mark · ⇧↑/↓ range · ⇧←/→ h-scroll · ↵/e edit · #{f} fwd · #{d} drop · #{fa} all · #{filt} filter · #{catch} catch · space cmds · esc tabs"
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
          listen: {proxy.host, proxy.port}, capturing: @host.session.capturing?)
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
      # ⇧↑/⇧↓ belong to intercept.mark-extend-* in the keymap. The arrow branches below
      # ignore the shift modifier, so without this they would swallow the range gesture as a
      # plain move and the verbs would never fire.
      return false if ev.shift? && (key.up? || key.down?)
      case
      when key.escape?              then queue_escape
      when key.lower_j?, key.down?  then queue_move(1)
      when key.lower_k?, key.up?    then @intercept.at_top? ? @host.request_focus(:menu) : queue_move(-1)
      when key.enter?, key.lower_e? then open_editor
      else                               return false # f/d/⇧F/i/c/t/⇧T… → keymap
      end
      true
    end

    # ↵/e on the queue. `toggle_edit` already refuses a binary WebSocket message; a refusal
    # with no explanation reads as a dead key, so say why — the detail pane's READ-ONLY badge
    # is only visible once the row is selected.
    private def open_editor : Nil
      if @intercept.read_only_selection?
        @host.status("binary WebSocket message — read-only (forward or drop it unchanged)")
        return
      end
      @intercept.toggle_edit
    end

    # esc over a mark set hands the marks back first — the reflex clear, mirroring History,
    # where it shadows the pop-to-tab-bar ONLY while marks are set.
    private def queue_escape : Nil
      if @intercept.mark_count > 0
        @intercept.clear_marks
        @host.status("marks cleared")
      else
        @host.request_focus(:menu)
      end
    end

    # A plain (unshifted) cursor key ends the ⇧arrow range gesture before it moves. Kept out
    # of InterceptView#move deliberately: the wheel shares that method, and a wheel notch
    # reads as "scroll the viewport", not as a selection gesture (#457).
    private def queue_move(delta : Int32) : Nil
      end_range_gesture
      @intercept.move(delta)
    end

    # Hand back what the ⇧arrow gesture marked, and say so only when marks actually went away
    # — arrowing down an unmarked queue stays silent. Names what survived, since `t`/⇧T marks
    # are deliberately not the gesture's to drop.
    private def end_range_gesture : Nil
      return if @intercept.end_mark_gesture == 0
      n = @intercept.mark_count
      @host.status(n == 0 ? "selection cleared" : "selection cleared — #{n} still marked")
    end

    # Shift+←/→ horizontal scroll for the read-only held-item preview — kept OUT of
    # handle_queue_key (called from handle_body_key instead), since that dispatch is already
    # at ameba's complexity ceiling. Bare arrows still navigate the queue.
    #
    # ⇧↑/⇧↓ used to scroll this preview vertically; they are now the mark-range gesture
    # (⇧arrow = "extend the selection" everywhere else in the TUI, incl. History's list and
    # the flow detail). Vertical reading moved to PgUp/PgDn/Home/End — see #body_scroll.
    private def queue_key_scroll(ev : Termisu::Event::Key) : Bool
      key = ev.key
      return false unless ev.shift?
      if key.left?
        @intercept.hscroll_detail(-1)
      elsif key.right?
        @intercept.hscroll_detail(1)
      else
        return false
      end
      true
    end

    # PageUp/PageDown/Home/End page the read-only held-message preview (the Runner routes
    # these here when handle_body_key declines them). The preview, not the queue: a hold
    # queue is a handful of rows that j/k covers, while a held body runs to thousands of
    # lines and this is now its only scroll path short of opening the editor. No editing?
    # guard is needed — handle_body_key swallows every key while the editor is up, so these
    # never reach here then (and vscroll_detail self-guards regardless).
    def body_scroll(delta : Int32) : Bool
      return false if @intercept.empty?
      @intercept.vscroll_detail(delta)
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
      when key.tab?       then ic.set_filter(@intercept.query) if @intercept.query_complete
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
          # A click on ANOTHER row is a cursor gesture, so it collapses the range exactly as a
          # plain arrow does; re-clicking the row you are already on leaves the set alone.
          end_range_gesture unless idx == @intercept.selected_index
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

    # Forward the effective target set: every marked hold, else the cursor row. The editor
    # holds at most ONE item's in-progress edit, so that item forwards its edited bytes and
    # every other target its original ones (nil ⇒ Interceptor#forward sends item.raw) — the
    # same `overrides` reasoning intercept_forward_all uses, so a batch can never send stale
    # bytes for the message you were just editing.
    def intercept_forward : Nil
      ids = @intercept.target_ids
      return if ids.empty?
      return if refuse_unresolved_env?
      ic = @host.session.interceptor
      edit = @intercept.pending_edit
      label = batch_label(ids) # built BEFORE the decisions go out — the items are gone after
      ids.each { |id| ic.forward(id, (edit && edit[0] == id) ? edit[1] : nil) }
      @intercept.reload(ic)
      @host.status("forwarded #{label}")
    end

    # Drop the effective target set. No confirm even in batch: a dropped hold answers the
    # client with a canned 502 it can retry, which is not the irreversible data loss
    # history.delete guards — and gating only the batch path would be inconsistent with the
    # single drop right next to it. The toast carries the count instead.
    def intercept_drop : Nil
      ids = @intercept.target_ids
      return if ids.empty?
      ic = @host.session.interceptor
      label = batch_label(ids)
      ids.each { |id| ic.drop(id) }
      @intercept.reload(ic)
      @host.status("dropped #{label}")
    end

    # How a forward/drop toast names its targets: the one held message when the verb ran on
    # the cursor row, else the count — a dozen "GET /a, GET /b …" labels would not fit, and
    # the count is what a batch decision is actually about.
    private def batch_label(ids : Array(Int64)) : String
      if ids.size == 1 && (it = @intercept.item_by_id(ids.first))
        return intercept_label(it)
      end
      "#{ids.size} held message#{ids.size == 1 ? "" : "s"}"
    end

    # Refuse a forward whose pending edit still names a var that resolves to nothing, and
    # say so. `Env.expand_wire` leaves an unregistered `$KEY` literal on purpose — right in
    # the editor, wrong on the socket, where the token's own characters go out as a header
    # value and the origin's 401 reads as the target rejecting a token rather than as a
    # variable that was never set (#519). Intercept forwards outside `Repeater::Plan`, so
    # the builder's refusal never covered it (#524).
    #
    # The WHOLE batch is refused, not just the edited item: forwarding the others and
    # silently holding back the one being edited would report "forwarded 4 held messages"
    # for a set the operator asked to send as one.
    private def refuse_unresolved_env? : Bool
      names = @intercept.unresolved_env
      return false if names.empty?
      @host.status("intercept: unresolved env #{Env.token_list(names)} — add it in the Project tab's ENV pane, or remove the token")
      true
    end

    def intercept_forward_all : Nil
      n = @host.session.interceptor.pending_count
      return if refuse_unresolved_env?
      # Carry the currently-loaded item's in-progress edit into the bulk forward, so
      # "forward all" doesn't send its stale original bytes (single-forward already does).
      overrides = @intercept.pending_edit.try { |e| {e[0] => e[1]} }
      @host.session.interceptor.forward_all(overrides)
      @intercept.reload(@host.session.interceptor)
      @host.status("forwarded all (#{n})")
    end

    # Open the catch-condition filter bar (a query that narrows which messages hold).
    def intercept_query : Nil
      @intercept.start_query(@host.session.store) # store backs `host:` Tab-completion
      @host.status("catch condition: host: method: path: status: scheme: · ↹ complete · ↵ apply · esc clear")
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

    # --- marks (multi-select over the hold queue) ---
    # The two gestures that MOVE the queue cursor guard on `editing?`. The keymap can't reach
    # them there (the held-bytes editor swallows every key), but the command palette can — and
    # stepping the cursor off the loaded item would leave @editing true over a different
    # hold's read-only preview, with the focus ring still saying "detail".
    def intercept_mark_toggle : Nil
      return if @intercept.editing?
      return @host.status("nothing held to mark") unless @intercept.selected_id
      @intercept.toggle_mark
      @host.status(mark_status)
    end

    def intercept_mark_all : Nil
      return @host.status("nothing held to mark") if @intercept.empty?
      @intercept.mark_all
      @host.status(mark_status)
    end

    def intercept_mark_clear : Nil
      @intercept.clear_marks
      @host.status("marks cleared")
    end

    def intercept_mark_extend(delta : Int32) : Nil
      return if @intercept.empty? || @intercept.editing?
      @intercept.extend_marks(delta)
      @host.status(mark_status)
    end

    def marked_intercept_count : Int32
      @intercept.mark_count
    end

    # Shared mark toast. No "not visible" split (History's carries one): the queue renders
    # every pending item and reload prunes marks whose hold is gone, so the count always
    # describes rows that are on screen.
    private def mark_status : String
      n = @intercept.mark_count
      return "no marks — forward/drop act on the cursor row" if n == 0
      "#{n} held message#{n == 1 ? "" : "s"} marked"
    end

    # A short human label for a held item — "GET /path" (request), the status line
    # (response), or the socket plus direction (a WebSocket message) — for forward/drop
    # toasts; the queue's internal id means nothing to the user. Reads the EDITED
    # method/status (via the view) so a forwarded edit shows what was actually sent, not the
    # stale hold-time metadata.
    #
    # Exhaustive `case ... in` for the reason `InterceptView#kind_badge` is: as a
    # `kind.request?` ternary a WebSocket message rendered here as its own status line.
    private def intercept_label(it : Interceptor::Item) : String
      method, target = @intercept.effective_method_target(it)
      case it.kind
      in .request?  then "#{method} #{Url.origin_path(target)}"
      in .response? then target
      in .ws_out?   then "WS message → #{it.host}"
      in .ws_in?    then "WS message ← #{it.host}"
      end
    end
  end
end
