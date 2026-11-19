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

  # One keystroke over a bottom prompt's `{text, caret}`: the answer, or nil when `ev` is not
  # an edit — so a prompt's own arms (esc, ↵, ↑/↓ stepping) run first and this takes the rest.
  # `LineEdit` carries the motions the `/` bars gained (⌃/⌥←→ by word, Home/End, Delete,
  # ⌥⌫); ←/→ and ⌫ are the bare forms, and a printable lands AT the caret. The ^F, rename
  # and tag prompts all typed append-only before this — strictly less than the bars beside
  # them, on the most-typed prompt in the app.
  private def prompt_edit(ev : Termisu::Event::Key, text : String, cx : Int32) : {String, Int32}?
    key = ev.key
    cx = cx.clamp(0, text.size)
    if key.backspace?
      return {text, cx} if cx == 0
      {text[0, cx - 1] + text[cx..], cx - 1}
    elsif act = LineEdit.action(ev) # before the bare arrows: a modified arrow is a different request
      LineEdit.apply(act, text, cx)
    elsif key.left?
      {text, {cx - 1, 0}.max}
    elsif key.right?
      {text, {cx + 1, text.size}.min}
    elsif (c = ev.char || key.to_char) && !c.control? && !ev.ctrl? && !ev.alt? # control? drops Tab/\n etc. (Space stays)
      {text[0, cx] + c + text[cx..], cx + 1}
    end
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

  # Jump a target view to 1-based line `n`, at char index `cx` (cursor for editors, scroll
  # for the read-only panes, onto the visual row holding `cx`). Shared by ^G go-to-line
  # (cx 0) and ^F search (the match's column).
  private def jump_line(target : Symbol, n : Int32, cx : Int32 = 0) : Nil
    case target
    when :repeater_request  then repeater_controller.current_view.try(&.goto_request_line(n, cx))
    when :repeater_response then repeater_controller.current_view.try(&.goto_response_line(n, cx))
    when :notes             then notes_controller.view.goto_line(n, cx)
    when :project           then project_controller.view.goto_line(n, cx)
    when :detail            then history_controller.view.goto_detail_line(n, cx)
    when :intercept         then intercept_controller.view.edit_goto_line(n, cx)
    when :decoder_input     then decoder_controller.input_area.goto_line(n, cx)
    when :decoder_output    then decoder_controller.goto_output_line(n, cx)
    when :fuzz_template     then fuzzer_controller.current_view.try(&.goto_template_line(n, cx))
    when :fuzz_detail       then fuzzer_controller.current_view.try(&.goto_detail_line(n, cx))
    end
  end

  # ^F hits as `{line, char index}`, one per OCCURRENCE: the count says how many matches
  # there are, not how many lines hold one, and stepping visits each — a term repeated
  # forty times inside one minified body line is forty stops, each scrolled into view.
  private def search_hits_for(target : Symbol, query : String) : Array({Int32, Int32})
    none = [] of {Int32, Int32}
    case target
    when :repeater_request  then repeater_controller.current_view.try(&.request_search_hits(query)) || none
    when :repeater_response then repeater_controller.current_view.try(&.response_search_hits(query)) || none
    when :notes             then notes_controller.view.search_hits(query)
    when :project           then project_controller.view.search_hits(query)
    when :detail            then history_controller.view.detail_search_hits(query)
    when :intercept         then intercept_controller.view.edit_search_hits(query)
    when :decoder_input     then decoder_controller.input_area.search_hits(query)
    when :decoder_output    then decoder_controller.output_search_hits(query)
    when :fuzz_template     then fuzzer_controller.current_view.try(&.template_search_hits(query)) || none
    when :fuzz_detail       then fuzzer_controller.current_view.try(&.detail_search_hits(query)) || none
    else                         none
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
    when :decoder_input     then decoder_controller.input_area.search_hl = q
    when :decoder_output    then decoder_controller.output_search_hl = q
    when :fuzz_template     then fuzzer_controller.current_view.try(&.template_search_hl=(q))
    when :fuzz_detail       then fuzzer_controller.current_view.try(&.detail_search_hl=(q))
    end
  end

  # ^F incremental search: text input (IME via @search_preedit); ↑/↓ step through
  # matching lines (wraps); esc closes. Recomputes + jumps on each edit.
  # Tab flips to find&replace, where typing feeds the replacement row and ↵ swaps
  # every match (behind a confirm) instead of stepping. ↑/↓ step in both modes.
  private def handle_search_key(ev : Termisu::Event::Key) : Nil
    key = ev.key
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
    elsif @search_replace
      if edited = prompt_edit(ev, @search_replace_buffer, @search_replace_cx)
        @search_replace_buffer, @search_replace_cx = edited
        @search_preedit = ""
      end
    elsif edited = prompt_edit(ev, @search_buffer, @search_cx)
      changed = edited[0] != @search_buffer
      @search_buffer, @search_cx = edited
      @search_preedit = ""
      search_refresh if changed # a caret motion keeps the hits (and the match the operator is on)
    end
  end

  # Tab: find ⇄ find&replace. Only the TextArea-backed targets can be written to; on a
  # read-only pane this is a no-op, and the prompt never offered it (see the hint in
  # render_search_prompt) — a toast can't explain the refusal because the prompt is
  # drawn OVER the status row that toasts render on.
  private def toggle_search_replace : Nil
    return unless @search_replace || replace_target?
    @search_replace = !@search_replace
    @search_input_hit = nil
    @search_preedit = "" # the composing text belongs to the row we just left
  end

  # Targets whose backing view is an editable TextArea. The read-only panes
  # (:repeater_response, :detail, :decoder_output, :fuzz_detail) have no mutation path at all.
  private def replace_target? : Bool
    case @search_target
    when :repeater_request, :notes, :project, :intercept then true
    when :decoder_input, :fuzz_template                  then true
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
    when :decoder_input    then decoder_controller.input_area.match_count(@search_buffer)
    when :fuzz_template    then fuzzer_controller.current_view.try(&.template_match_count(@search_buffer)) || 0
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
        when :decoder_input    then decoder_controller.input_replace_matches(query, replacement)
        when :fuzz_template    then fuzzer_controller.current_view.try(&.template_replace_matches(query, replacement)) || 0
        else                        0
        end
    # The replace is done, so drop the prompt: it would otherwise sit there advertising
    # a now-stale query as "no matches", AND it covers the status row the toast needs.
    # ^F reopens in one keystroke.
    close_search
    @toast = "replaced #{Gori.plural(n, "occurrence")}"
  end

  private def search_refresh : Nil
    @search_hits = search_hits_for(@search_target, @search_buffer)
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
    @search_hits = search_hits_for(@search_target, @search_buffer)
    @search_idx = @search_idx.clamp(0, {@search_hits.size - 1, 0}.max)
  end

  private def jump_to_match : Nil
    return if @search_hits.empty?
    li, cx = @search_hits[@search_idx]
    jump_line(@search_target, li + 1, cx) # hits are 0-based; jump is 1-based
  end

  private def open_search(target : Symbol) : Nil
    if target == :detail && history_controller.view.hex_view?
      reg = @session.registry
      route = Hotkeys.binding_label(reg, "detail.toggle-hex", "")
      route = Hotkeys.route(reg, "detail.toggle-hex") if route.empty?
      return status(route ? "Switch to text to search (#{route})" : "Switch to text to search")
    end
    @search_input_hit = nil
    @search_target = target
    @search_buffer = ""
    @search_cx = 0
    @search_preedit = ""
    @search_hits = [] of {Int32, Int32}
    @search_idx = 0
    @search_replace = false
    @search_replace_buffer = ""
    @search_replace_cx = 0
    @search_open = true
  end

  private def close_search : Nil
    set_search_hl("") # clear the match highlight on the target view
    @search_open = false
    @search_input_hit = nil
    @search_preedit = ""
    @search_replace = false
  end

  FIND_INPUT_MIN = 12

  # Give the input room before fitting the secondary hints into the rest of the row.
  def self.find_row_layout(row : Rect, label : String, hint : String) : {Rect, String}
    label_w = Screen.draw_width(label)
    room = {row.w - label_w, 0}.max
    hint_room = {room - FIND_INPUT_MIN - 1, 0}.max
    fitted = Chrome.fit_hints(hint, hint_room)
    fitted = fitted.rchop(" …") if Screen.draw_width(fitted) > hint_room
    return {Rect.new(row.x + label_w, row.y, room, 1), ""} if fitted.empty? || Screen.draw_width(fitted) > hint_room
    {Rect.new(row.x + label_w, row.y, room - Screen.draw_width(fitted) - 1, 1), fitted}
  end

  private def render_search_prompt(screen : Screen, rect : Rect) : Nil
    if @search_replace
      top = Rect.new(rect.x, rect.y - 1, rect.w, 1)
      draw_find_row(screen, top, "find    › ", find_hint("tab edit find · ↑↓ step"), @search_buffer, nil)
      draw_find_row(screen, rect, "replace › ", "↵ replace all · esc done", @search_replace_buffer, @search_replace_cx)
    else
      hint = replace_target? ? "tab replace · ↑↓/↵ step · esc done" : "↑↓/↵ step · esc done"
      draw_find_row(screen, rect, "find › ", find_hint(hint), @search_buffer, @search_cx)
    end
  end

  private def draw_find_row(screen : Screen, row : Rect, label : String, hint : String, value : String, caret : Int32?) : Nil
    input, fitted = Runner.find_row_layout(row, label, hint)
    screen.fill(row, Theme.panel)
    screen.text(row.x, row.y, label, caret ? Theme.accent : Theme.muted, Theme.panel, width: row.w)
    if caret
      start = screen.input_line(input.x, input.y, value, caret, @search_preedit, Theme.text_bright, Theme.panel, width: input.w)
      # A click clears preedit before dispatch. Use the last paint to decide whether its
      # columns can map to committed text.
      @search_input_hit = @search_preedit.empty? ? {input, start} : nil
    else
      screen.text(input.x, input.y, value, Theme.text, Theme.panel, width: input.w)
    end
    color = fitted.starts_with?("no matches") ? Theme.yellow : Theme.muted
    screen.text(input.right + 1, row.y, fitted, color, Theme.panel) unless fitted.empty?
  end

  private def find_hint(hint : String) : String
    return hint if @search_buffer.empty?
    count = @search_hits.empty? ? "no matches" : "#{@search_idx + 1}/#{@search_hits.size}"
    "#{count} · #{hint}"
  end

  private def click_search_prompt(status_row : Rect, mx : Int32, my : Int32) : Nil
    first = @search_replace ? status_row.y - 1 : status_row.y
    unless status_row.x <= mx < status_row.right && first <= my <= status_row.y
      return close_search
    end
    return unless hit = @search_input_hit
    input, start = hit
    return unless input.contains?(mx, my)
    if @search_replace
      @search_replace_cx = Screen.input_click(@search_replace_buffer, start, mx - input.x)
    else
      @search_cx = Screen.input_click(@search_buffer, start, mx - input.x)
    end
  end
end
