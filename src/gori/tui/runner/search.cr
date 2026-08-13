# ^G go-to-line and ^F find/replace over the focused multi-line view — reopens
# Gori::Tui::Runner (see tui/runner.cr for the event loop, Host facade, overlays, and
# rendering). Both are bottom prompts, not overlays: `goto_target` / `replace_target?`
# name which view the shell is driving, and the prompts themselves render from runner.cr.
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # Which focused multi-line view ^G/^F jumps, or nil if the context has none. The
  # detail drill-in is shell state (@overlay); the rest is each controller's call.
  private def goto_target : Symbol?
    return :detail if @overlay.detail?
    return nil unless @overlay.none? && @focus == :body
    @tabs[@active_tab]?.try(&.goto_symbol)
  end

  # The ^G "go to line" prompt: digits only; Enter jumps the captured target, Esc
  # cancels. A modal mini-input (mirrors handle_palette_key) drawn over the status.
  private def handle_goto_key(ev : Termisu::Event::Key) : Nil
    key = ev.key
    c = ev.char || key.to_char
    if key.escape?
      close_goto
    elsif key.enter?
      n = @goto_buffer.to_i?
      close_goto
      apply_goto(n) if n && n > 0
    elsif key.backspace?
      @goto_buffer = @goto_buffer[0, {@goto_buffer.size - 1, 0}.max]
    elsif c && c.ascii_number? && @goto_buffer.size < 7
      @goto_buffer += c
    end
  end

  private def apply_goto(n : Int32) : Nil
    jump_line(@goto_target, n)
  end

  # Jump a target view to 1-based line `n` (cursor for editors, scroll for the
  # read-only panes). Shared by ^G go-to-line and ^F search.
  private def jump_line(target : Symbol, n : Int32) : Nil
    case target
    when :repeater_request  then repeater_controller.current_view.try(&.goto_request_line(n))
    when :repeater_response then repeater_controller.current_view.try(&.goto_response_line(n))
    when :notes             then notes_controller.view.goto_line(n)
    when :project           then project_controller.view.goto_line(n)
    when :detail            then history_controller.view.goto_detail_line(n)
    when :intercept         then intercept_controller.view.edit_goto_line(n)
    end
  end

  private def search_lines_for(target : Symbol, query : String) : Array(Int32)
    case target
    when :repeater_request  then repeater_controller.current_view.try(&.request_search_lines(query)) || [] of Int32
    when :repeater_response then repeater_controller.current_view.try(&.response_search_lines(query)) || [] of Int32
    when :notes             then notes_controller.view.search_lines(query)
    when :project           then project_controller.view.search_lines(query)
    when :detail            then history_controller.view.detail_search_lines(query)
    when :intercept         then intercept_controller.view.edit_search_lines(query)
    else                         [] of Int32
    end
  end

  # Push the active ^F query to the target view so it highlights matches (cleared
  # with "" on close). Routes like jump_line; repeater covers both panes.
  private def set_search_hl(q : String) : Nil
    case @search_target
    when :repeater_request  then repeater_controller.current_view.try(&.request_search_hl=(q))
    when :repeater_response then repeater_controller.current_view.try(&.response_search_hl=(q))
    when :notes             then notes_controller.view.search_hl = q
    when :project           then project_controller.view.search_hl = q
    when :detail            then history_controller.view.search_hl = q
    when :intercept         then intercept_controller.view.search_hl = q
    end
  end

  # ^F incremental search: text input (IME via @search_preedit); ↑/↓ step through
  # matching lines (wraps); esc closes. Recomputes + jumps on each edit.
  # Tab flips to find&replace, where typing feeds the replacement row and ↵ swaps
  # every match (behind a confirm) instead of stepping. ↑/↓ step in both modes.
  private def handle_search_key(ev : Termisu::Event::Key) : Nil
    key = ev.key
    c = ev.char || key.to_char
    if key.escape?
      close_search
    elsif key.tab? || key.back_tab?
      toggle_search_replace
    elsif key.enter?
      @search_replace ? request_replace_confirm : search_step(1)
    elsif key.down?
      search_step(1)
    elsif key.up?
      search_step(-1)
    elsif key.backspace?
      if @search_replace
        @search_replace_buffer = @search_replace_buffer[0, {@search_replace_buffer.size - 1, 0}.max]
        @search_preedit = ""
      else
        @search_buffer = @search_buffer[0, {@search_buffer.size - 1, 0}.max]
        @search_preedit = ""
        search_refresh
      end
    elsif c && !c.control? && !ev.ctrl? && !ev.alt? # control? drops Tab/\n etc. (Space stays)
      if @search_replace
        @search_replace_buffer += c
        @search_preedit = ""
      else
        @search_buffer += c
        @search_preedit = ""
        search_refresh
      end
    end
  end

  # Tab: find ⇄ find&replace. Only the TextArea-backed targets can be written to; on a
  # read-only pane this is a no-op, and the prompt never offered it (see the hint in
  # render_search_prompt) — a toast can't explain the refusal because the prompt is
  # drawn OVER the status row that toasts render on.
  private def toggle_search_replace : Nil
    return unless @search_replace || replace_target?
    @search_replace = !@search_replace
    @search_preedit = "" # the composing text belongs to the row we just left
  end

  # Targets whose backing view is an editable TextArea. The read-only panes
  # (:repeater_response, :detail) have no mutation path at all.
  private def replace_target? : Bool
    case @search_target
    when :repeater_request, :notes, :project, :intercept then true
    else                                                      false
    end
  end

  # Occurrence count (not line count — a line with three hits counts three), so the
  # confirm can quote exactly how much is about to change.
  private def search_match_count : Int32
    case @search_target
    when :repeater_request then repeater_controller.current_view.try(&.request_match_count(@search_buffer)) || 0
    when :notes            then notes_controller.view.match_count(@search_buffer)
    when :project          then project_controller.view.match_count(@search_buffer)
    when :intercept        then intercept_controller.view.edit_match_count(@search_buffer)
    else                        0
    end
  end

  # ↵ in replace mode: gate the bulk edit behind the standard confirm (the same
  # pattern as the REMOVE MARKER guard). An empty replacement is a legitimate
  # "delete every match", so it's worded that way rather than rejected.
  private def request_replace_confirm : Nil
    return unless replace_target?
    # Nothing to confirm with an empty query or zero hits — and no toast to explain it,
    # because the prompt covers the status row. The find row above already says so: it
    # shows a blank count for an empty query and "no matches" for a fruitless one.
    return if @search_buffer.empty?
    n = search_match_count
    # -1 = the buffer is not valid UTF-8, so a PCRE cannot run over it (see
    # `TextArea#searchable?`). Named rather than folded into "no matches": this is the
    # ordinary shape of a Repeater tab seeded from a captured upload, and silence would
    # read as "your query is not in there".
    if n < 0
      return status("replace: this buffer holds bytes that are not valid UTF-8 — " \
                    "search and replace can't run over it (^F highlighting still works)")
    end
    return if n == 0
    q, r = @search_buffer, @search_replace_buffer
    plural = n == 1 ? "" : "s"
    msg = if r.empty?
            "Delete #{n} occurrence#{plural} of “#{q}”?"
          else
            "Replace #{n} occurrence#{plural} of “#{q}” with “#{r}”?"
          end
    confirm("REPLACE ALL", "#{msg}\nOne undo step — ^Z puts it back.",
      confirm_label: r.empty? ? "delete" : "replace", danger: true) do
      run_replace(q, r)
    end
  end

  private def run_replace(query : String, replacement : String) : Nil
    n = case @search_target
        when :repeater_request then repeater_controller.current_view.try(&.request_replace_matches(query, replacement)) || 0
        when :notes            then notes_controller.view.replace_matches(query, replacement)
        when :project          then project_controller.view.replace_matches(query, replacement)
        when :intercept        then intercept_controller.view.edit_replace_matches(query, replacement)
        else                        0
        end
    # The replace is done, so drop the prompt: it would otherwise sit there advertising
    # a now-stale query as "no matches", AND it covers the status row the toast needs.
    # ^F reopens in one keystroke.
    close_search
    @toast = "replaced #{n} occurrence#{n == 1 ? "" : "s"}"
  end

  private def search_refresh : Nil
    @search_hits = search_lines_for(@search_target, @search_buffer)
    @search_idx = 0
    set_search_hl(@search_buffer) # highlight matches in the target view
    jump_to_match
  end

  private def search_step(dir : Int32) : Nil
    return if @search_hits.empty? # O(1) step over the cached hits (re-find only on edit / content change)
    @search_idx = (@search_idx + dir) % @search_hits.size
    jump_to_match
  end

  # Re-find without re-jumping — called when the searched view's content changes
  # under an open prompt (a repeater result lands / a peer fills the detail), so the
  # cached hits + count stay correct without re-scanning on every ↑/↓ step.
  private def search_recompute : Nil
    return unless @search_open
    @search_hits = search_lines_for(@search_target, @search_buffer)
    @search_idx = @search_idx.clamp(0, {@search_hits.size - 1, 0}.max)
  end

  private def jump_to_match : Nil
    return if @search_hits.empty?
    jump_line(@search_target, @search_hits[@search_idx] + 1) # hits are 0-based; jump is 1-based
  end

  private def open_search(target : Symbol) : Nil
    @search_target = target
    @search_buffer = ""
    @search_preedit = ""
    @search_hits = [] of Int32
    @search_idx = 0
    @search_replace = false
    @search_replace_buffer = ""
    @search_open = true
  end

  private def close_search : Nil
    set_search_hl("") # clear the match highlight on the target view
    @search_open = false
    @search_preedit = ""
    @search_replace = false
  end
end
