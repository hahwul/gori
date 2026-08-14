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
        # `⇧arrows select · ^Y copy`: this editor is the one INS strip in the tree that named
        # NEITHER, which is why the guard spec's "advertises a band, names no copy key" rule
        # could not see it. Both are live — `handle_edit_key` routes ⇧arrows through
        # `edit_motion_key`, and `intercept.copy` carries `^Y` on the wider `intercept_copyable?`
        # gate precisely for this pane. Bare `y` is chordless here (the queue spends the
        # letters) AND a literal character while typing, so `^Y` is the only copy there is.
        "type to edit · ⇧arrows select · ^Y copy · ^R forward · ⇧↹/esc queue"
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
      "↑/↓ move · #{mark} mark · ⇧↑/↓ range · ↵/e edit · #{f} fwd · #{d} drop · #{fa} all · #{filt} filter · #{catch} catch · space cmds · esc tabs"
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
      elsif @intercept.editing? && (ev.ctrl? || ev.alt?) &&
            !ev.ctrl_z? && !(ev.ctrl? && key.lower_r?) && !(ev.ctrl? && key.lower_l?) &&
            !@intercept.edit_word_delete_key?(ev) && !editing_motion?(ev)
        # Any OTHER modified chord defers to the central keymap so it stays rebindable — `^Y`
        # Copy above all, which is the only way to copy an INS selection here (bare `y` is a
        # literal character, and typing it would REPLACE the selection). ^Z undo, ^R forward,
        # ^L Content-Length sync and ⌥/⌃ motion are this editor's own and stay above.
        false
      elsif @intercept.editing?
        handle_edit_key(ev)
        true
      else
        handle_queue_key(ev) # false for c / / (and other unhandled keys) → defer to the keymap
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
      elsif ev.ctrl? && key.lower_l?
        # ^L — stop resyncing Content-Length to the edited body. A CL that disagrees with the
        # body is the reason to hold a request in the first place, so the resync has to be
        # something the operator can turn off; the badge on the REQUEST (held) border shows
        # which way it is set.
        @intercept.toggle_content_length_sync
      elsif @intercept.edit_word_delete_key?(ev)
        # Before plain ⌫, which would swallow the modified form as a one-character delete.
        @intercept.edit_motion_key(ev)
      elsif key.backspace?
        @intercept.edit_backspace
      elsif key.delete?
        @intercept.edit_delete
      elsif @intercept.edit_motion_key(ev)
        # ⇧arrows select, Page keys, ⇧Home/⇧End, ⌥←/→ by word — TextArea#handle_motion_key.
      elsif c && !ev.ctrl? && !ev.alt?
        @intercept.edit_insert(c)
        report_replaced(@intercept.edit_last_replaced) # a printable over a selection REPLACES it
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

    # ⇧←/→ used to h-scroll the read-only held-item preview. The preview soft-wraps now, like
    # the editor it sits behind and like the Repeater / History panes that show the same bytes,
    # so there is nothing off to the side to scroll to and the whole `hscroll_detail` chain is
    # gone rather than kept as a no-op. (⇧↑/⇧↓ had already left for the mark-range gesture;
    # vertical reading is PgUp/PgDn/Home/End — see `#body_scroll`.)

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

    # Open dropdown ⇒ ↵ takes the highlighted candidate and shuts it (pushing the narrowed
    # condition live, as every other edit here does); closed ⇒ leave edit mode. Mirrors History.
    # ↓/↑ drive the dropdown, ←/→ the caret. Handled ahead of the `case` below rather than as
    # four more arms in it: the dropdown's two keys pushed `handle_query_key` past the complexity
    # gate CI runs, and "move something" is a different question from "what does this key do".
    # `↓`/`↑` were dead in this bar before the dropdown — a one-line field has no second row to
    # move a caret to — which is why they could be claimed without displacing anything.
    private def query_nav(key) : Bool
      case
      when key.down?  then @intercept.popup_down
      when key.up?    then @intercept.popup_up
      when key.left?  then @intercept.query_move(-1)
      when key.right? then @intercept.query_move(1)
      else                 return false
      end
      true
    end

    private def query_enter(ic) : Nil
      if @intercept.popup_open?
        ic.set_filter(@intercept.query) if @intercept.query_complete(close: true)
      else
        @intercept.stop_query
      end
    end

    # esc closes the dropdown first. Clearing the condition on a glance at the candidate list
    # would UNHOLD everything the operator had narrowed to — the one bar where the second-press
    # rule is not merely convenience.
    private def query_escape(ic) : Nil
      return @intercept.popup_close if @intercept.popup_open?
      @intercept.cancel_query
      ic.set_filter("")
    end

    def handle_query_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      ic = @host.session.interceptor
      return true if query_nav(key)
      case
      when key.enter?  then query_enter(ic)
      when key.escape? then query_escape(ic)
      when key.tab?    then ic.set_filter(@intercept.query) if @intercept.query_complete
      when key.backspace? then @intercept.query_backspace; ic.set_filter(@intercept.query)
      # Above the printable arm below, which would otherwise type the `?` (see ql_help_key?).
      when TabController.ql_help_key?(ev, @intercept.query) then @host.open_help_query(:intercept)
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

    # --- mouse drag + double-click (see TabController#supports_drag?) ---
    # Both faces of the held-message pane drag: the editor's own caret while editing, the
    # read-only preview's while previewing.
    def supports_drag? : Bool
      !@intercept.empty?
    end

    # All four pointer entries invert against `BodyChrome.frame_inner(rect)` — the SAME rect
    # `render_body` hands the view through `BodyChrome.framed`. Drag and double-click used to
    # pass the RAW body rect while the press insetted, so the press placed the caret through
    # one mapping and the gesture that continued it used another: one row down, and one or two
    # columns across, because `split_panes` divides a `w` that is 2 cells too wide. A press on
    # line N whose drag extends from line N+1 is #587's shape ("a click that landed on a line it
    # wasn't drawn on") — here inside the one pane where a selection is the point. The helper
    # exists for exactly this ("shared by render and click hit-tests"); use it, not a fourth
    # hand-written `inset(1, 1)`.
    private def hit_rect(rect : Rect) : Rect
      BodyChrome.frame_inner(rect)
    end

    def handle_drag(rect : Rect, mx : Int32, my : Int32) : Nil
      inner = hit_rect(rect)
      if @intercept.editing?
        @intercept.editor_drag_to_cursor(inner, mx, my)
      else
        @intercept.preview_click(inner, mx, my, selecting: true)
      end
    end

    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      inner = hit_rect(rect)
      @intercept.editing? ? @intercept.editor_select_word(inner, mx, my) : @intercept.preview_select_word(inner, mx, my)
    end

    # --- READ-pane delegators (the preview's read verbs + the Runner's read_* ladders) ---
    # Gates `x`/`v`/`S` — the READ-pane verbs, which the editor has no use for.
    def intercept_preview_readable? : Bool
      !@intercept.empty? && !@intercept.editing?
    end

    # Copy's gate, which is DELIBERATELY wider: it also fires while the held-bytes editor is
    # open, because an INS selection there could be built and destroyed but never copied. See
    # `InterceptView#preview_selection?` for the two selection models it routes between.
    def intercept_copyable? : Bool
      !@intercept.empty?
    end

    def intercept_preview_selection_active? : Bool
      @intercept.preview_selection?
    end

    def intercept_preview_selection_text : String
      @intercept.preview_copy_text
    end

    def intercept_preview_select_line : Nil
      @intercept.preview_select_line
    end

    def intercept_preview_clear_selection : Nil
      @intercept.preview_clear_selection
    end

    # `y`: the selection, or the whole held message when nothing is selected. The bytes here are
    # the item's own — byte-exact, which is the point of holding it.
    def intercept_preview_copy : Nil
      return unless intercept_copyable?
      sel = @intercept.preview_selection?
      text = sel ? @intercept.preview_copy_text : @intercept.preview_copy_all
      return if text.empty?
      written = Clipboard.copy(text)
      note = Clipboard.note(written, text)
      @host.status(sel ? "copied #{written}b to clipboard#{note}" : "copied all (#{written}b)#{note}")
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      inner = hit_rect(rect)
      if zone = @intercept.bar_zone_at(inner, mx, my) # click the top filter bar
        @host.focus_body
        case zone
        when :catch     then intercept_toggle
        when :direction then intercept_cycle_direction
        else                 intercept_query
        end
        return true
      end
      # The queue's scroll gauge, before the pane test — it rides the card's right hairline,
      # which `list_row_at` excludes.
      if row = @intercept.gauge_row_at(inner, mx, my)
        @host.focus_body
        @intercept.focus_list
        end_range_gesture unless row == @intercept.selected_index
        @intercept.select_index(row)
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
      elsif @intercept.editing?
        @intercept.editor_click_to_cursor(inner, mx, my)
      else
        # A click on the read-only preview places a READ caret; it no longer starts editing.
        # That is what makes the pane selectable at all — and the edit affordance was never the
        # text, it is the `e`:EDIT badge on the card's own border (plus ↵ / `e`), which the
        # bar-zone arm above already claims. The Intercept has no focus tier for this pane (Tab
        # opens the editor, ⇧arrows are the queue's mark-range gesture), so the pointer is the
        # only place a caret can come from here — hence mouse selection + `x`/`y`, and no
        # keyboard caret.
        @intercept.preview_click(inner, mx, my)
      end
      true
    end

    # The wheel with the pointer position. This tab draws two panes side by side and only the
    # LEFT one's wheel arm moves a selection, so a coordinate-free notch was wrong in both
    # directions: over the held-message pane it walked the queue (reloading a different message
    # under a preview that draws its own scroll gauge, and never scrolling that preview — whose
    # only other path is PgUp/PgDn), and inside the editor it did nothing at all, because
    # `move` bails while `@editing`. That bail stays: moving the selection with the editing flag
    # up would leave the flag on with the editor no longer rendered. The fix is to send the
    # notch to the pane under the pointer instead. Same move the Repeater's split request
    # column made — see `RepeaterController#handle_wheel_at`.
    #
    # `hit_rect` for the same reason the press uses it: the view's hit-tests all invert against
    # the framed interior `render_body` drew into.
    def handle_wheel_at(step : Int32, mx : Int32, my : Int32, rect : Rect) : Bool
      case @intercept.pane_at(hit_rect(rect), mx, my)
      when :detail then @intercept.scroll_detail_pane(step)
      when :list   then handle_wheel(step)
      end # nil → the filter-bar row, the 1-cell gap column, or an empty queue: nothing to scroll
      true
    end

    # The queue's own arm, kept separate so `:list` and any coordinate-free caller cannot
    # drift. Self-guards on `@editing` (see `InterceptView#move`).
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
      return if refuse_unappliable_edit?(ids)
      ic = @host.session.interceptor
      edit = @intercept.pending_edit
      label = batch_label(ids) # built BEFORE the decisions go out — the items are gone after
      # Count what actually went out: an item another surface (MCP, the reaper) settled first
      # is not this operator's forward, and reporting the whole batch would be a silent no-op
      # for the difference.
      sent = ids.count { |id| ic.forward(id, (edit && edit[0] == id) ? edit[1] : nil) }
      @intercept.reload(ic)
      if sent == ids.size
        @host.status("forwarded #{label}")
      else
        @host.status("forwarded #{sent} of #{ids.size} — the rest were already decided elsewhere")
      end
    end

    # Drop the effective target set. No confirm even in batch: a dropped hold answers the
    # client with a canned 502 it can retry, which is not the irreversible data loss
    # history.delete guards — and gating only the batch path would be inconsistent with the
    # single drop right next to it. The toast carries the count instead.
    def intercept_drop : Nil
      ids = @intercept.target_ids
      return if ids.empty?
      ic = @host.session.interceptor
      label = batch_label(ids) # built BEFORE the decisions go out — the items are gone after
      # Count what actually got dropped, exactly as the forward above does. `Interceptor#drop`
      # is a no-op on an item somebody else already settled — the h2/WS gates fail a hold OPEN
      # from a proxy fiber when a stream resets or the buffer ceiling is hit — and "dropped GET
      # /admin" for a request that went to the origin is the worst version of this lie: it says
      # gori BLOCKED bytes that are already on the wire.
      dropped = ids.count { |id| ic.drop(id) }
      @intercept.reload(ic)
      if dropped == ids.size
        @host.status("dropped #{label}")
      else
        @host.status("dropped #{dropped} of #{ids.size} — the rest were already decided elsewhere")
      end
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

    # Refuse a forward whose pending edit gori would never apply, and say why.
    #
    # The CLI/MCP drain has asked `Item#refuse_edit` since R3-F1; this path had not, so the
    # human got the older behaviour it was written to end — `forwarded GET …` in the status
    # bar while the settle side (`H2::StreamGate#edited` → `encode_edited || block`) threw the
    # edit away and the ORIGINAL message went on the wire. Verified against a live h2 origin:
    # the status bar said forwarded and the origin logged the untouched request.
    #
    # The message stays HELD, exactly as it does for the agent path: nothing was decided, so
    # the operator can forward it as it is, drop it, or write a different edit. And the WHOLE
    # batch is refused rather than the edited item alone — reporting "forwarded 4 held
    # messages" for a set that went out as 3 is the lie being removed.
    #
    # `ids` scopes that to the batch actually going out. The editor holds ONE item's edit and
    # `pending_edit` is keyed on the item the EDITOR loaded, not on the queue cursor — so an
    # unappliable edit left behind on a message the operator has since arrowed away from refused
    # every later forward of every OTHER hold, under a toast naming a message that was not in
    # the batch. A refusal has to be about something the operator is actually about to send.
    private def refuse_unappliable_edit?(ids : Array(Int64)) : Bool
      refusal = @intercept.refused_edit
      return false unless refusal
      item, reason = refusal
      return false unless ids.includes?(item.id)
      @host.status("edit NOT applied to #{item.label} — #{reason}")
      true
    end

    def intercept_forward_all : Nil
      ic = @host.session.interceptor
      return if refuse_unappliable_edit?(ic.pending.map(&.id))
      # Carry the currently-loaded item's in-progress edit into the bulk forward, so
      # "forward all" doesn't send its stale original bytes (single-forward already does).
      overrides = @intercept.pending_edit.try { |e| {e[0] => e[1]} }
      # The count comes BACK from the release rather than from a `pending_count` read before it:
      # a proxy fiber holding a message in that window has it forwarded too, and this toast is
      # the operator's only record of how many irreversible decisions just went out.
      n = ic.forward_all(overrides)
      @intercept.reload(ic)
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
      in .request?, .response? then it.label(method, target)
      in .ws_out?              then "WS message → #{it.host}"
      in .ws_in?               then "WS message ← #{it.host}"
      end
    end
  end
end
