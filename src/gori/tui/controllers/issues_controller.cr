require "../tab_controller"
require "../issues_view"
require "../clipboard"
require "../../store"
require "../../issues_export"
require "../../hotkeys"

module Gori::Tui
  # The Issues tab: the triage list + an issue's detail (with an inline notes
  # editor) + Markdown/JSON export. Owns IssuesView. The "new/edit issue" FORM is
  # a shell overlay (@overlay == :issue_new), so it stays in the Runner; the three
  # cross-tab jumps (issue → its flow in History, issue → Repeater, new-from-flow)
  # are shell mediators. Detail notes use READ/INS (like Notes): the shell routes
  # detail keys here before the focus ring when an issue is open.
  class IssuesController < TabController
    def initialize(host : Host)
      super(host)
      @issues = IssuesView.new
      # The peer notes value an `esc` overwrite is currently armed against — see
      # `save_notes_or_report`. nil when nothing is armed, which is every state but the one
      # right after a refusal the operator has read.
      @notes_overwrite_armed = nil.as(String?)
    end

    # Would `commit` REFUSE the open Issues writeup right now? Asked by the quit and
    # leave-project prompts, which are the two places the buffer dies for good and the only two
    # where a status line arrives too late to be read (the loop breaks immediately after
    # `commit_pending_edits`).
    #
    # Gated on INS exactly as `commit` is, so the prompt describes what will actually happen. A
    # dirty buffer the NOR/INS chip stepped out of is dropped at quit too — but by the INS gate,
    # not by this conflict, and a line blaming a peer for it would send the operator looking for
    # a collision that is not the reason. That silence is older than this guard and is its own
    # question.
    #
    # `@host.session.store`, not a cached row: the answer has to be about the version on disk at
    # the moment the operator is being asked, which is the moment they can still act on it.
    def notes_conflict_pending? : Bool
      return false unless @issues.notes_insert_mode?
      @issues.notes_conflict?(@host.session.store)
    end

    def view : IssuesView
      @issues
    end

    def tab : Symbol
      :issues
    end

    def command_scope : Verb::Scope
      @issues.detail_open? ? Verb::Scope::IssuesDetail : Verb::Scope::Issues
    end

    # PageUp/PageDown/Home/End over the issues list (view clamps the selection). The
    # detail view is a short title/notes/links form with no vertical body to page, so
    # leave those keys untouched when it's open.
    def body_scroll(delta : Int32) : Bool
      return false if @issues.detail_open?
      end_range_gesture unless preview_scroll_focused? # a page key is cursor nav, like ↑/↓
      @issues.move(delta)
      true
    end

    def body_badge : Symbol
      @issues.notes_insert_mode? ? :editor : :body
    end

    def body_hint(focus : Symbol) : String
      reg = @host.session.registry
      filt = Hotkeys.binding_label(reg, "issues.filter", "/")
      nnew = Hotkeys.binding_label(reg, "issues.new", "n")
      y = Hotkeys.binding_label(reg, "issue.copy", "y")
      # Named in every state the chord can FIRE from, which is every list state — `command_scope`
      # answers Scope::Issues for the marks state and both preview focuses too, and only an open
      # detail (or the `/` bar, which claims every key) leaves it. Naming it in the default branch
      # alone would rebuild the gap #899 closed elsewhere: a destructive key nothing on screen
      # advertises, in the three states an operator actually triages from.
      clear = Hotkeys.binding_label(reg, "issues.clear", "⇧X")
      if @issues.detail_open?
        if @issues.notes_insert_mode?
          I18n.ui("type to edit · ⇧arrows select · ^Y copy · esc save · ^W discard")
        elsif @issues.notes_focused?
          I18n.ui("↑/↓ move · ⇧arrows select · %{y} copy · i/↵ edit · space cmds · esc links", y: y)
        else
          I18n.ui("↑/↓ links · ↵ open · i/↵ notes · o flow · r repeater · space cmds · ←/esc back")
        end
      elsif @issues.querying?
        I18n.ui("type to filter · ↹ complete · ↵ apply · esc clear")
      elsif @issues.preview_enabled? && @issues.preview_focus == :preview
        I18n.ui("↑/↓ scroll preview · ↹ list · ↵ open full · %{clear} clear · space cmds · esc tabs", clear: clear)
      elsif @issues.mark_count > 0
        # Marks re-point what `space` acts on AND take over esc (handle_body_key shadows
        # issues.leave while a set is live), so the standing "esc tabs" hint would be wrong.
        #
        # `clear ALL` in capitals, and `esc drops marks` spelled out, because this is the one
        # state where the two words mean different sets: `space`/`d` act on the marks, ⇧X does
        # not — it wipes the project. A bare "clear" here would read as "clear the marked ones".
        mark = Hotkeys.binding_label(reg, "issues.mark-toggle", "t")
        I18n.ui("%{n} marked · %{mark} mark · ⇧↑/⇧↓ range · space acts on marks · %{clear} clear ALL · esc drops marks", n: @issues.mark_count, mark: mark, clear: clear)
      elsif @issues.preview_enabled?
        I18n.ui("↑/↓ move · ↵ open · ↹ preview · %{filt} filter · %{new} new · %{clear} clear · space cmds · esc tabs", filt: filt, new: nnew, clear: clear)
      else
        I18n.ui("↑/↓ move · ↵ open · %{filt} filter · %{new} new · %{clear} clear · space cmds · esc tabs", filt: filt, new: nnew, clear: clear)
      end
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      focused = focus == :body
      BodyChrome.framed(screen, rect, focused) { |inner| @issues.render(screen, inner, focused: focused) }
    end

    # --- mouse drag + double-click (see TabController#supports_drag?) ---
    # The NOTES pane of an open issue only: the issue LIST selects rows. No focus/save side
    # effects — the press that began the gesture already ran them.
    def supports_drag? : Bool
      @issues.detail_open?
    end

    def handle_drag(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless @issues.detail_open?
      @issues.notes_drag_to_cursor(rect.inset(1, 1), mx, my)
    end

    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      return false unless @issues.detail_open?
      @issues.notes_select_word(rect.inset(1, 1), mx, my)
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      inner = rect.inset(1, 1)
      if @issues.detail_open?
        card = @issues.notes_card_rect(inner)
        # NOR/INS chip on the NOTES card border toggles insert (same as ↵ / esc).
        if !card.empty? && Frame.mode_badge_hit(mx, my, card.y, card.right - 1, card.x + 7,
             @issues.notes_insert_mode?)
          if @issues.notes_insert_mode?
            @issues.exit_notes_insert!
          else
            @issues.enter_notes_insert!
          end
          return true
        end
        notes_rect = @issues.notes_body_rect(inner)
        if !notes_rect.empty? && mx >= notes_rect.x && mx < notes_rect.right &&
           my >= notes_rect.y && my < notes_rect.bottom
          @issues.notes_click_to_cursor(inner, mx, my)
        end
        return true
      end
      @host.focus_body
      if @issues.preview_enabled? && @issues.preview_at?(inner, mx, my)
        @issues.set_preview_focus(:preview)
        return true
      end
      list_rect, _ = @issues.list_split(inner)
      # The list's scroll gauge on the frame's right hairline: jump the cursor to the row it
      # points at. Before the filter-bar arm, which has no `mx` bound of its own.
      if row = @issues.gauge_row_at(inner, mx, my)
        @issues.set_preview_focus(:list)
        @issues.select_index(row)
        return true
      end
      if my == list_rect.y && !@issues.querying?
        @issues.start_query
        return true
      end
      return true unless idx = @issues.list_row_at(inner, mx, my)
      @issues.set_preview_focus(:list)
      if idx == @issues.selected_index
        issues_open
      else
        end_range_gesture # a plain click collapses the range, same as a plain arrow
        @issues.select_index(idx)
      end
      true
    end

    def handle_wheel(step : Int32) : Bool
      if @issues.detail_open?
        if @issues.notes_insert_mode? || @issues.notes_focused?
          @issues.notes_scroll_wheel(step)
        else
          @issues.scroll_links_wheel(step)
        end
      else
        # Deliberately NOT end_range_gesture: a wheel reads as "scroll the viewport", not as
        # a selection gesture, so it must not destroy a mark set the way a cursor key does.
        @issues.move(step)
      end
      true
    end

    # esc clears the marks; Tab cycles list ↔ preview focus when that layout is active. Runs
    # BEFORE the Issues keymap, so the esc branch shadows issues.leave ONLY while marks are
    # set — with none set, esc still pops to the tab bar. (The `/` filter bar claims every
    # key ahead of this while it's up, so filter-esc is unaffected.)
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      return false if @issues.detail_open?
      return false if ev.ctrl? || ev.alt?
      if ev.key.escape? && @issues.mark_count > 0
        @issues.clear_marks
        return true
      end
      if @issues.preview_enabled? && ev.key.tab?
        @issues.cycle_preview_focus
        return true
      end
      false
    end

    def handle_detail_key(ev : Termisu::Event::Key) : Bool
      return false unless @issues.detail_open?
      key = ev.key
      c = ev.char || key.to_char
      if @issues.notes_insert_mode?
        return handle_notes_insert_key(ev, key, c)
      end
      if !@issues.notes_focused? && c == 'i'
        @issues.enter_notes_insert!
        return true
      end
      if key.space? && !ev.ctrl? && !ev.alt?
        @host.open_space_menu
        return true
      end
      if @issues.notes_focused?
        return handle_notes_read_key(ev, key, c)
      end
      false
    end

    private def handle_notes_read_key(ev : Termisu::Event::Key, key, c : Char?) : Bool
      selecting = ev.shift?
      case
      when key.escape?
        @issues.focus_links!
      when key.enter?, c == 'i'
        @issues.enter_notes_insert!
      when key.up?                           then @issues.notes_read_move(-1, 0, selecting: selecting)
      when key.down?                         then @issues.notes_read_move(1, 0, selecting: selecting)
      when key.left?                         then @issues.notes_read_move(0, -1, selecting: selecting)
      when key.right?                        then @issues.notes_read_move(0, 1, selecting: selecting)
      when @issues.notes_read_motion_key(ev) then nil # Home/End/Page — the shared editor set
      when c == 'x'                          then @issues.notes_select_line
      when c == 'y'                          then issues_notes_copy
      else
        return false
      end
      true
    end

    private def handle_notes_insert_key(ev : Termisu::Event::Key, key, c : Char?) : Bool
      case
      when ev.ctrl? && key.lower_w?
        # Disarmed on the way out: an arm granted for a refusal the operator then answered with
        # `^W` must not still be sitting there for the NEXT edit of this issue, where a second
        # `esc` would write over a peer without ever showing the refusal that earns it.
        @notes_overwrite_armed = nil
        @issues.cancel_notes_edit
      when ev.ctrl_z? then @issues.notes_undo
      when (ev.ctrl? || ev.alt?) && !@issues.notes_word_delete_key?(ev) && !editing_motion?(ev)
        # Every other modified chord defers to the central keymap so it stays rebindable —
        # `^Y` Copy above all, which is the only way to copy an INS selection here (bare `y`
        # is a literal character, and typing it would REPLACE the selection). ⌥⌫ and ⌥/⌃
        # motion are this editor's own and are excluded above.
        return false
      when key.escape? then save_notes_or_report
      when key.enter?  then @issues.notes_newline
        # Before plain ⌫, which would swallow the modified form as a one-character delete.
      when @issues.notes_word_delete_key?(ev) then @issues.notes_motion_key(ev)
      when key.backspace?                     then @issues.notes_backspace
        # ⇧arrows select, Page keys, ⌥←/→ by word — TextArea#handle_motion_key.
      when @issues.notes_motion_key(ev) then nil
      else
        if c && !ev.ctrl? && !ev.alt?
          @issues.notes_insert(c)
          report_replaced(@issues.notes_last_replaced) # a printable over a selection REPLACES it
          @issues.set_preedit("")
        end
      end
      true
    end

    # ⇧←/→ used to h-scroll the notes pane, which shadowed the character selection every other
    # text pane gives them. `handle_notes_read_key` took the chord back for the selection, and
    # the notes pane now soft-wraps — there is nothing off to the side to scroll to — so the
    # `hscroll_notes` chain is gone rather than kept as a no-op that still moves a caret.

    def set_preedit(text : String) : Bool
      if @issues.querying?
        @issues.query_set_preedit(text)
        true
      elsif @issues.notes_insert_mode?
        @issues.set_preedit(text)
        true
      else
        false
      end
    end

    def querying? : Bool
      @issues.querying?
    end

    def handle_query_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.enter?     then @issues.stop_query
      when key.escape?    then @issues.cancel_query
      when key.tab?       then @issues.query_complete
      when key.backspace? then @issues.query_backspace
      when key.left?      then @issues.query_move(-1)
      when key.right?     then @issues.query_move(1)
      else
        if c && !ev.ctrl? && !ev.alt?
          @issues.query_insert(c)
          @issues.query_set_preedit("")
        end
      end
      true
    end

    def on_enter : Nil
      @issues.reload(@host.session.store)
    end

    # `refresh_detail` reloads the list too, so it REPLACES the bare reload this used to do
    # rather than joining it. Without it the tab was refreshed in halves: the list behind an
    # open issue picked up a peer's severity/status/notes edit while the detail card on top of
    # it kept rendering the row it was opened with — the same split HistoryController closed
    # with its own detail refresh. It is gated on `detail_open?` inside the view, not on an
    # overlay: an Issues detail is in-tab state, so `@host.overlay` is `:none` while it is up.
    def on_external_change : Nil
      return unless @issues.refresh_detail(@host.session.store, announce: true)
      # An INS buffer is never overwritten (refresh_detail leaves it alone and says so here).
      # Announce instead — the alternative is the operator finding out at `esc`, when the save
      # is refused for a reason nothing on screen had hinted at. Latched to once per distinct
      # peer value: this tick also fires on this session's OWN captures.
      @host.status("notes changed by another session — esc will refuse to overwrite; ^W discards yours")
    end

    # The flush the shell runs on a tab switch and on `commit_pending_edits` (quit /
    # leave-project). NO retry hint here, unlike the `esc` path: on a tab switch the buffer
    # really is still there, but on the quit path the Runner is torn down immediately after —
    # nothing more is drawn and the text goes with the session. That last case is pre-existing
    # and deliberate (quit wins; `NotesView#save` keeps `@dirty` on a failed write and nobody
    # blocks the exit on it either), so this reports without promising a retry that one of its
    # three callers cannot honour.
    def commit : Nil
      # Still INS-gated, deliberately, now that `IssuesView#notes_dirty?` can be true in READ
      # (the NOR/INS chip leaves the editor without saving). `esc` is this pane's save key and
      # the chip is not — flushing a buffer the operator stepped out of would persist an edit
      # they never committed, on a tab switch they may not connect to it. What that buffer
      # needed was to stop being silently ERASED, and it no longer is: the tick and a re-entry
      # both leave it alone, so `i` picks the text back up exactly where it was.
      return unless @issues.notes_insert_mode?
      # The lost-update refusal belongs here as much as on `esc`: a tab switch and a quit both
      # route through this, and either one would have written this window's buffer over a peer's
      # writeup without the operator ever seeing the two versions.
      #
      # NOT armable from here, unlike `esc`. A tab switch is not a save — the buffer stays in
      # the view and `i` picks it back up — so the honest answer is "not saved, here is where to
      # go", and the message names the pane's own key rather than turning an unrelated keypress
      # into a write. The quit caller is louder still: `Runner#quit_message` /
      # `leave_confirm_message` put this conflict in the modal, because a status line posted
      # from inside a teardown is never rendered and the operator would have learned about it
      # by finding the writeup gone.
      if @issues.notes_conflict?(@host.session.store)
        @host.status("notes NOT saved — another session rewrote them; esc in the notes pane overwrites theirs, ^W takes theirs")
        return
      end
      return if @issues.save_notes(@host.session.store)
      @host.status("notes NOT saved — project busy")
    end

    # `esc` out of the notes editor. IssuesView#save_notes returns false when the write was
    # rolled back (cross-process SQLite busy/lock) and then leaves the buffer AND insert mode
    # exactly as they were, so the typed text is still on screen and a second `esc` is a real
    # retry. Say so — reporting nothing is what made a busy project look like it had saved
    # while it had discarded the writeup.
    private def save_notes_or_report : Nil
      # Ahead of the write, because `update_issue` sets the column wholesale — there is no
      # row-version to lose the race against, so the last esc in either window silently won and
      # the other operator's writeup was simply gone. Stay in INS on the refusal, so the typed
      # text is still on screen.
      #
      # And the refusal ARMS the next `esc` rather than standing forever. A guard on this pane
      # can only be an interruption, never a veto: the operator is the one who knows whether
      # their paragraph or the peer's is the one to keep, and a refusal with no way through left
      # them with three keys that all lose their text (`^W` takes the peer's, a tab switch
      # refuses again, quitting drops it). Second `esc` writes. That is the same shape as every
      # other "are you sure" in the app — informed, then allowed — and the informing is the part
      # that was missing, not the forbidding.
      #
      # Armed against the VALUE, so it cannot be pre-armed and cannot go stale: a peer who
      # writes again between the two presses moves the key, and the second `esc` refuses afresh
      # against the version nobody has seen yet.
      if key = @issues.notes_conflict_key(@host.session.store)
        if @notes_overwrite_armed != key
          @notes_overwrite_armed = key
          @host.status("notes NOT saved — another session rewrote them; esc again overwrites theirs, ^W takes theirs, ^Y copies yours")
          return
        end
      end
      # Either there was no conflict, or the operator answered one. Disarm before the write, so
      # an arm can never outlive the press it was granted for.
      @notes_overwrite_armed = nil
      return if @issues.save_notes(@host.session.store)
      @host.status("notes NOT saved — project busy; your text is still here, esc to retry")
    end

    def issues_notes_read_mode? : Bool
      @issues.detail_open? && @issues.notes_focused? && !@issues.notes_insert_mode?
    end

    def issues_notes_selection_active? : Bool
      @issues.notes_selection?
    end

    def issues_notes_select_line : Nil
      @issues.notes_select_line
    end

    def issues_notes_clear_selection : Nil
      @issues.notes_clear_selection
    end

    def issues_move(delta : Int32) : Nil
      if @issues.preview_enabled? && @issues.preview_focus == :preview
        @issues.move(delta)
        return
      end
      # ↑ at the top row pops focus up to the tab bar. The cursor stays put there, so the
      # marks (and any range in flight) stay put with it.
      if delta < 0 && @issues.at_top?
        return @host.request_focus(:menu)
      end
      end_range_gesture
      @issues.move(delta)
    end

    # A plain (unshifted) cursor key ends the ⇧arrow range gesture and hands its marks back
    # (IssuesView#end_mark_gesture). Says so only when marks actually went away, so arrowing
    # down an unmarked list stays silent — and names what survived, since `t`/⇧T marks are
    # deliberately not the gesture's to drop.
    private def end_range_gesture : Nil
      return if @issues.end_mark_gesture == 0
      n = @issues.mark_count
      @host.status(n == 0 ? "selection cleared" : "selection cleared — #{n} still marked")
    end

    # A preview pane (not the list) holds focus, so ↑/↓ and the wheel scroll that pane.
    private def preview_scroll_focused? : Bool
      @issues.preview_enabled? && @issues.preview_focus != :list
    end

    def issues_open : Nil
      @issues.open_detail(@host.session.store)
    end

    def issue_close : Nil
      @issues.close_detail
    end

    # --- marks (multi-select) -------------------------------------------------

    # The effective target set for a batch verb: the marks if any, else the cursor row.
    # Runner#issues_target_ids wraps this with the open-detail case.
    def target_issue_ids : Array(Int64)
      @issues.target_ids
    end

    def marked_issue_count : Int32
      @issues.mark_count
    end

    # The one privileged target when a batch verb needs a single representative — the value
    # the severity/status picker opens on (see IssuesView#primary_target_id).
    def primary_target_issue_id : Int64?
      @issues.primary_target_id
    end

    def issues_mark_toggle : Nil
      return @host.status("no issue to mark") unless @issues.selected_id
      @issues.toggle_mark
      @host.status(mark_status)
    end

    def issues_mark_all : Nil
      return @host.status("no issues to mark") if @issues.empty?
      @issues.mark_all
      @host.status(mark_status)
    end

    def issues_mark_clear : Nil
      @issues.clear_marks
      @host.status("marks cleared")
    end

    def issues_mark_extend(delta : Int32) : Nil
      return if @issues.empty?
      @issues.extend_marks(delta)
      @host.status(mark_status)
    end

    # Shared mark toast — says the count AND how much of it is off-window, matching the
    # filter-bar chip, so a set larger than the visible list is never a surprise.
    private def mark_status : String
      n = @issues.mark_count
      return "no marks — verbs act on the cursor row" if n == 0
      hidden = @issues.marked_hidden_count
      msg = "#{n} issue#{n == 1 ? "" : "s"} marked"
      msg += " (#{hidden} not visible)" if hidden > 0
      msg
    end

    # Space-menu delete. Capture the ids NOW so a peer write between the confirm opening and
    # being accepted can't retarget it. Works from the list (marks, else the cursor row) or
    # from the open detail, which is pinned to ONE issue.
    def issues_delete : Nil
      from_detail = @issues.detail_open?
      ids = from_detail ? [@issues.detail_issue.try(&.id)].compact : @issues.target_ids
      return if ids.empty?
      # Marks can outlive the visible list (a filter change, a peer delete), so a batch
      # confirm spells out the split: this dialog — not the list chip — is the last thing
      # read before data is destroyed.
      # Two labels — see HistoryController#delete_selected, which this mirrors: the confirm
      # body quotes the name, the toast reports it after a colon.
      name =
        if ids.size == 1
          @issues.issue_summary(ids.first)
        else
          hidden = @issues.hidden_count(ids)
          "#{ids.size} issues#{hidden > 0 ? " (#{hidden} not visible)" : ""}"
        end
      label = ids.size == 1 ? "“#{name}”" : name
      @host.confirm(ids.size == 1 ? "DELETE ISSUE" : "DELETE ISSUES",
        "Delete #{label}?\nThis can't be undone.", confirm_label: I18n.ui("delete"), danger: true) do
        # A rolled-back write (cross-process SQLite busy/lock) leaves the issues AND the marks
        # in place — say so instead of reporting a delete that didn't happen, so the set is
        # still there to retry.
        unless @issues.delete_ids(@host.session.store, ids)
          @host.status("issue NOT deleted (project busy) — the marks are kept, try again")
          next
        end
        @host.status("issue deleted: #{name}")
      end
    end

    # ⇧X — the whole-tab wipe, in the family History, Probe, Authorize and the ACTIVITY feed
    # already share (#899). This tab was the one clear-all-shaped list left out of that
    # rollout, so the chord an operator learns as "clears this tab" answered nothing here.
    #
    # The count comes from the STORE, never `@issues.empty?`: that answers for the FILTERED
    # list, so `/ severity:critical` matching nothing would have turned a project holding 40
    # issues into a "nothing to clear" toast — the one reading of this key that would be a
    # lie. It is also the number the confirm names, so the gate and the prompt cannot
    # disagree, and it is read at PRESS time, so a peer's writes since the last reload count.
    #
    # An empty project gets a toast rather than a dialog, the way `probe_clear` and
    # `activity_clear` answer theirs: an advertised key that opens a dialog over nothing reads
    # as busywork, and one that answers with silence reads as a key that failed.
    #
    # Deliberately NOT mark-aware. With three rows marked `d` deletes those three and this
    # deletes everything — so the confirm says ALL and names the total, which is the number
    # that differs from the mark count the operator is looking at.
    def issues_clear : Nil
      n = @host.session.store.count_issues
      return @host.status("issues: nothing to clear") if n <= 0
      @host.confirm(I18n.ui("CLEAR ISSUES"),
        I18n.sys_n(n, "Delete ALL %{n} issue for this project?\nIts notes, CVSS score and evidence links go too.\nThis can't be undone.", "Delete ALL %{n} issues for this project?\nTheir notes, CVSS scores and evidence links go too.\nThis can't be undone.", n: n),
        confirm_label: I18n.ui("clear"), danger: true) do
        ok = @issues.clear(@host.session.store)
        @host.status(ok ? "issues cleared" : "issues NOT cleared (project busy) — every issue is still there")
      end
    end

    # `]`/`[` and `}`/`{`. A rolled-back write leaves the issue on its OLD value, which the
    # re-read then paints back — indistinguishable from "the key did nothing" unless it says
    # so. Same sentence Runner#apply_issue_choice uses for the picker path.
    def issue_severity(delta : Int32) : Nil
      return if @issues.severity_delta(delta, @host.session.store)
      @host.status("severity NOT changed — project busy; try again")
    end

    def issue_status(delta : Int32) : Nil
      return if @issues.status_delta(delta, @host.session.store)
      @host.status("status NOT changed — project busy; try again")
    end

    def issue_edit_notes : Nil
      @issues.enter_notes_insert!
    end

    def issue_link_move(delta : Int32) : Nil
      return if @issues.notes_insert_mode? || @issues.notes_focused?
      @issues.move_links(delta)
    end

    def issues_copy : Nil
      text = @issues.notes_copy_text
      if text.empty?
        @host.status("nothing to copy")
        return
      end
      written = Clipboard.copy(text)
      @host.status("copied #{written}b to clipboard#{Clipboard.note(written, text)}")
    end

    # The notes selection (or current line) text without copying — "Send selection to".
    def issues_notes_selection_text : String
      @issues.notes_copy_text
    end

    def issues_copy_all : Nil
      text = @issues.notes_copy_all
      if text.empty?
        @host.status("nothing to copy")
        return
      end
      written = Clipboard.copy(text)
      @host.status("copied notes to clipboard (#{written}b)#{Clipboard.note(written, text)}")
    end

    # `y` in the notes pane: the selection when one is held, else the WHOLE notes. The keymap's
    # `issue.copy` (-> Runner#read_copy) has always answered that way, but this pane raw-
    # dispatches `y` ahead of the keymap and fell back to the caret's LINE — so the chord the
    # verb registers and the key the operator actually presses gave different answers.
    def issues_notes_copy : Nil
      issues_notes_selection_active? ? issues_copy : issues_copy_all
    end

    # Write the issue report to `path` (the destination came from ExportOverlay — this used
    # to hardcode <project dir>/issues.{md,json} and clobber it silently). Returns true when
    # the shell should close the popup; false keeps it up so a correctable failure doesn't
    # cost the typed path.
    #
    # The trailing newline mirrors `gori run issues --export=PATH`, so this and the CLI write
    # byte-identical files for the same project and format (`--format=markdown|json`; the
    # CLI's DEFAULT --format is `text`, a different report entirely). JSON.build emits no
    # trailing newline of its own, so the JSON export gains one here.
    def issues_export_to(format : Symbol, path : String) : Bool
      store = @host.session.store
      issues = store.issues
      if issues.empty?
        @host.status("no issues to export")
        return true
      end
      content = case format
                when :json  then Issues::Export.json(issues, store)
                when :sarif then Issues::Export.sarif(issues, store, @host.session.project.name)
                else             Issues::Export.markdown(issues, store, @host.session.project.name)
                end
      File.write(path, content.ends_with?('\n') ? content : "#{content}\n")
      msg = "exported #{issues.size} issue#{issues.size == 1 ? "" : "s"} → #{path}"
      # Only warn when the report landed INSIDE the ephemeral project dir. The path used to
      # always be in there, so the warning was unconditional; now the operator picks it, and
      # a file written to their cwd survives the project just fine.
      if @host.session.project.ephemeral? && path.starts_with?(@host.session.project.dir)
        msg += "  ⚠ temp project — copy it before closing"
      end
      @host.status(msg)
      true
    rescue ex
      @host.status("export failed: #{ex.message}")
      false
    end
  end
end
