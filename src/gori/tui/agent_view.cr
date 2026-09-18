require "./screen"
require "./theme"
require "./frame"
require "./geometry"
require "./read_pane"
require "./text_area"
require "./text_read_state"
require "./input_mode"
require "./empty_art"
require "./highlight"
require "../agent/session"
require "../agent/transcript"

module Gori::Tui
  # The Agent tab's body (#1093): the conversation above, what you are about to say below,
  # and one row between them that says what the child is doing.
  #
  # TWO PANES, TWO WIDGETS, and they are deliberately different components. The transcript is
  # a `ReadPane` over the transcript's own `(size, line_at)` provider — never an Array — so a
  # ten-thousand-line conversation costs the viewport rather than the document (the argument
  # `ReadPane`'s header makes, and the reason `Transcript` keeps display lines incrementally
  # in the first place). The input is a `TextArea` in the Notes shape: READ to navigate and
  # copy, INS to type, because that is what every other multi-line editor in the tree does and
  # an operator should not have to learn a second one here.
  #
  # RE-POINTING THE SOURCE IS THE TRAP. `ReadPane#source` drops the wrap memo, so a view that
  # re-points every frame re-wraps every frame — which is exactly what `Transcript#version`
  # exists to prevent. `sync` re-points only when the version (or the transcript OBJECT, which
  # the history mode swaps) actually changed, and `source_repoints` is the counter a spec pins
  # that with.
  #
  # FOLLOWING THE TAIL is a mode, not a per-frame action: a streamed turn appends constantly,
  # and an operator who scrolled up to read something must not be yanked back to the bottom
  # twice a second. `@follow` is re-derived from `ReadPane#at_bottom?` after every gesture, so
  # scrolling up disarms it and scrolling back to the end re-arms it with no separate key.
  class AgentView
    # Top-to-bottom. The ring WRAPS (`pane_advance`), like the Repeater's: two panes and a
    # one-way ring would make `↹` leave the tab from the input, which is where the operator
    # spends the whole session.
    PANE_ORDER = [:transcript, :input]

    # The input pane's height: about a third of the body, floored so a draft is more than a
    # line and capped so the conversation keeps the pane. Below `MIN_BODY_H` the input is
    # given up entirely and the whole body goes to the transcript — a four-row editor under a
    # two-row conversation shows neither.
    MIN_INPUT_H =  4
    MAX_INPUT_H =  8
    MIN_BODY_H  = 10
    STATUS_H    =  1

    # Shown instead of the panes when there is nothing to show them for.
    NO_SESSION_STATUS = "no session yet"

    # A child that never spawned — `claude` is not on PATH, or the operator's `agent.command`
    # names something that is not there. The guidance body answers exactly that, so it is the
    # one dead reason that is NOT drawn as a dead band over a live-looking pane.
    NOT_FOUND = "not found"

    # The figure over the guidance card. Three rows and one cell per glyph, per `EmptyArt`'s
    # own constraints (a wide glyph shears the row). An operator's terminal on the left, the
    # agent lit in the middle, gori's tools on the right: the seat this tab is.
    ART = EmptyArt::Block.new([
      "╭────╮   ╭────╮   ╭────╮",
      "│ ▓▓ │<─>│ ██ │<─>│ ▓▓ │",
      "╰────╯   ╰────╯   ╰────╯",
    ])

    getter focus : Symbol
    # The transcript pane, for a controller that needs to drive it (scroll, page, cursor).
    getter pane : ReadPane
    # How many times `sync` re-pointed the pane's source. The version gate's observable
    # half — a spec calls `sync` twice with an unchanged transcript and pins that this
    # stayed put. Never read by the draw.
    getter source_repoints : Int32
    # Whether the pane is tracking the newest line. False while the operator has scrolled up.
    getter? follow : Bool

    def initialize
      # `gutter: false` — a transcript line is not a source line, and numbering the agent's
      # prose would read as a file. `wrap: true` because a model's paragraph IS one logical
      # line and the alternative is a pane showing its first eighty columns.
      @pane = ReadPane.new(wrap: true)
      @input = TextArea.new("")
      @input.wrap = true
      @read = TextReadState.new
      @mode = InputMode::Read
      @focus = :input
      @transcript = nil.as(Agent::Transcript?)
      @seen_version = -1
      @follow = true
      @tail_dirty = false
      @source_repoints = 0
    end

    # ---- the transcript source ---------------------------------------------------------

    # Point the pane at `transcript`, but only when it is different text than last time.
    # Called after every drain and on tab entry; see the header for why the gate matters.
    def sync(transcript : Agent::Transcript) : Nil
      same = (held = @transcript) && held.same?(transcript) && held.version == @seen_version
      @transcript = transcript
      return if same
      @seen_version = transcript.version
      @pane.source(transcript.size, ->(i : Int32) { transcript.line_at(i) })
      @source_repoints += 1
      @tail_dirty = true
    end

    def transcript : Agent::Transcript?
      @transcript
    end

    # Whether the newest line is on screen — the whole definition of "following", and it is
    # derived from the rows the draw actually laid down because that is the only place the
    # answer exists. `ReadPane#at_bottom?` is a CARET test, and the wheel deliberately moves
    # the WINDOW without putting the caret on the last line, so asking it here answered "no"
    # forever once the operator had scrolled with the mouse.
    private def tail_visible? : Bool
      return true if @pane.empty?
      @pane.last_rows.last?.try(&.li) == @pane.size - 1
    end

    # An upward gesture disarms the follow IMMEDIATELY rather than at the next frame: a turn
    # streaming at several lines a second would otherwise yank the pane back once more before
    # the draw could notice the operator had left the tail. Re-arming is the draw's job
    # (`tail_visible?`) — it is the only thing that knows what fitted.
    private def disarm_follow(step : Int32) : Nil
      @follow = false if step < 0
    end

    # ---- the status band ---------------------------------------------------------------

    # What the row between the panes says. A pure function of the session so a spec can pin
    # every state without a child process.
    def self.status_line(session : Agent::Session?) : String
      return NO_SESSION_STATUS unless session
      return "dead: #{session.dead_reason} — R to restart" if session.dead?
      n = session.pending.size
      return "⚠ #{n} permission request#{n == 1 ? "" : "s"} — press p" if n > 0
      parts = [session.running? ? "running ⟳" : session.state.to_s.downcase]
      parts << session.model unless session.model.empty?
      parts << "#{session.turns} turn#{session.turns == 1 ? "" : "s"}" if session.turns > 0
      parts << "$#{"%.2f" % session.cost_usd}" if session.cost_usd > 0
      parts.join(" · ")
    end

    def self.status_colour(session : Agent::Session?) : Color
      return Theme.muted unless session
      return Theme.red if session.dead?
      return Theme.yellow unless session.pending.empty?
      session.running? ? Theme.accent : Theme.muted
    end

    # ---- the input pane ----------------------------------------------------------------

    def input_text : String
      @input.text
    end

    def clear_input : Nil
      @input.set_text("")
    end

    def set_input(text : String) : Nil
      @input.set_text(text)
    end

    def insert_mode? : Bool
      @mode == InputMode::Insert
    end

    def enter_insert! : Nil
      @mode = InputMode::Insert
      @read.sync_from(@input)
    end

    def exit_insert! : Nil
      @mode = InputMode::Read
      # Hand the INS selection to READ rather than dropping it — the same handover
      # `NotesView#exit_insert!` makes, and for the same reason: `esc` then the copy verb is
      # the reflex, and a dropped anchor makes a visible selection uncopyable.
      @read.adopt_editor_selection(@input)
    end

    def insert(ch : Char) : Nil
      @input.insert(ch)
    end

    def last_replaced : Int32
      @input.last_replaced
    end

    def newline : Nil
      @input.insert_newline
    end

    def backspace : Nil
      @input.backspace
    end

    def delete : Nil
      @input.delete
    end

    def undo : Nil
      @input.undo
    end

    def paste(text : String) : Bool
      return false unless insert_mode?
      @input.insert_text(text)
      true
    end

    def set_preedit(text : String) : Nil
      @input.set_preedit(text)
    end

    def word_delete_key?(ev : Termisu::Event::Key) : Bool
      @input.word_delete_key?(ev)
    end

    def input_motion_key(ev : Termisu::Event::Key) : Bool
      @input.handle_motion_key(ev)
    end

    # READ-mode motion over the draft — the caret and band live in `@read`, mirroring
    # `NotesView#read_motion_key`.
    def input_read_motion_key(ev : Termisu::Event::Key) : Bool
      return false if insert_mode?
      key = ev.key
      shift = ev.shift?
      case
      when key.home?      then @input.home(shift)
      when key.end?       then @input.end_of_line(shift)
      when key.page_up?   then input_read_move(-@input.page_rows, 0, selecting: shift)
      when key.page_down? then input_read_move(@input.page_rows, 0, selecting: shift)
      else                     return false
      end
      @read.sync_to(@input, selecting: shift) if key.home? || key.end?
      true
    end

    def input_read_move(dr : Int32, dc : Int32, selecting : Bool = false) : Nil
      return if insert_mode?
      @read.move(@input, dr, dc, selecting: selecting)
    end

    def input_read_to_edge(dir : Int32) : Nil
      return if insert_mode?
      @read.to_edge(@input, dir)
    end

    def input_selection_text : String
      insert_mode? ? (@input.selection_text || @read.copy_text(@input)) : @read.copy_text(@input)
    end

    # ---- focus -------------------------------------------------------------------------

    def pane_advance(dir : Int32) : Bool
      i = PANE_ORDER.index(@focus) || 0
      focus_pane(PANE_ORDER[(i + dir) % PANE_ORDER.size])
      true
    end

    def focus_first : Nil
      focus_pane(:transcript)
    end

    def focus_last : Nil
      focus_pane(:input)
    end

    # Re-entry from outside the ring keeps the pane the view already holds; there is no
    # sub-field here to drop, so this is the documented no-op.
    def focus_resume : Nil
    end

    def focus_pane(pane : Symbol) : Nil
      @focus = pane if PANE_ORDER.includes?(pane)
    end

    # Whether ↑ should leave the body for the tab bar. The transcript answers with
    # `ReadPane#at_top?`, which is wrap-aware — a caret three visual rows into a wrapped
    # line 0 still has rows above it INSIDE the pane, and stealing its ↑ makes exactly those
    # rows unreachable (the `resp_caret_sub` reasoning in repeater_view/focus.cr). The input
    # answers with the editor's own first-row test, in both modes.
    def at_top? : Bool
      case @focus
      when :transcript then @pane.at_top?
      when :input      then @input.at_top?
      else                  false
      end
    end

    # ---- folding + copy ----------------------------------------------------------------

    # The tool call under the transcript caret, or nil on prose.
    def cursor_tool_use_id : String?
      @transcript.try(&.tool_use_id_at(@pane.cursor.cy))
    end

    # Fold/unfold the call under the caret. Returns whether anything moved, so a caller can
    # report rather than silently doing nothing on a prose line.
    def toggle_fold : Bool
      t = @transcript
      return false unless t
      return false unless id = cursor_tool_use_id
      anchor = @pane.cursor.cy
      t.toggle(id)
      sync(t)
      # The anchor is the line the operator ACTED on, not the tail: `toggle` rebuilds the
      # document under them, and a pane that jumped to the bottom would take the call they
      # just opened off screen. Following is left to `sync` when it was already armed.
      @pane.goto_line(anchor) unless @follow
      true
    end

    # The transcript selection, or — with none — the whole conversation. nil when there is
    # nothing at all, so a caller toasts "nothing to copy" rather than writing an empty
    # clipboard.
    def copy_text : String?
      return nil if @pane.empty?
      text = @pane.selection? ? @pane.copy_text : @pane.copy_all
      text.empty? ? nil : text
    end

    # ---- scrolling -----------------------------------------------------------------------

    def handle_wheel(step : Int32) : Bool
      @pane.scroll_view(step)
      disarm_follow(step)
      true
    end

    def body_scroll(delta : Int32) : Bool
      return false unless @focus == :transcript
      @pane.move(delta, 0)
      disarm_follow(delta)
      true
    end

    def page_rows : Int32?
      @focus == :transcript ? {@pane.last_h - 2, 1}.max : nil
    end

    # Transcript caret motion, with the follow flag re-derived after it.
    def transcript_move(dr : Int32, dc : Int32, selecting : Bool = false) : Nil
      @pane.move(dr, dc, selecting: selecting)
      disarm_follow(dr)
    end

    def transcript_motion_key(ev : Termisu::Event::Key) : Bool
      return false unless @pane.motion_key(ev)
      @follow = tail_visible?
      true
    end

    # ---- layout --------------------------------------------------------------------------

    # The three rects, derived ONCE so the draw and every hit-test carve the body the same
    # way. A body too short for both panes gives the input up, not the conversation.
    def layout(rect : Rect) : {Rect, Rect, Rect}
      ih = input_height(rect.h)
      sh = ih > 0 ? STATUS_H : 0
      th = {rect.h - ih - sh, 0}.max
      transcript = Rect.new(rect.x, rect.y, rect.w, th)
      status = Rect.new(rect.x, rect.y + th, rect.w, sh)
      input = Rect.new(rect.x, rect.y + th + sh, rect.w, ih)
      {transcript, status, input}
    end

    private def input_height(h : Int32) : Int32
      return 0 if h < MIN_BODY_H
      (h * 3 // 10).clamp(MIN_INPUT_H, MAX_INPUT_H)
    end

    # ---- render --------------------------------------------------------------------------

    def render(screen : Screen, rect : Rect, focused : Bool, session : Agent::Session?) : Nil
      return if rect.empty?
      if guidance?(session)
        render_guidance(screen, rect)
        return
      end
      transcript, status, input = layout(rect)
      render_transcript(screen, transcript, focused)
      render_status(screen, status, session)
      render_input(screen, input, focused)
    end

    # The body draws guidance rather than two empty panes when there is nothing behind them:
    # before the first start, and after a spawn that never happened because the command is
    # not on the operator's PATH. Every OTHER dead reason keeps the panes — the transcript
    # holds what the child said before it went, and that is the thing to read.
    #
    # The no-session arm still yields to a transcript that HAS lines: a past conversation
    # loaded read-only (`load_history`) belongs to no live session and must draw as itself.
    def guidance?(session : Agent::Session?) : Bool
      unless session
        t = @transcript
        return t.nil? || t.size == 0
      end
      session.dead? && session.dead_reason.includes?(NOT_FOUND)
    end

    private def render_transcript(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.h < 2 || rect.w < 2
      lit = focused && @focus == :transcript
      Frame.card(screen, rect, "TRANSCRIPT", bg: Theme.bg, border: Frame.pane_border(lit))
      inner = rect.inset(1, 1)
      return if inner.empty?
      styled = ->(i : Int32) { styled_line(i) }
      @pane.render(screen, inner, lit, styled_at: styled)
      # THE PARK COMES AFTER A DRAW, and it has to: `ReadPane` learns its viewport height by
      # RENDERING (`last_h` is 0 until then), and `goto_line`'s scroll-to-caret is a no-op
      # without one — so a pane parked before its first frame would sit at the top with the
      # newest line off screen. The row is therefore repainted on exactly the frames where the
      # conversation grew while following, and never at rest: `@tail_dirty` is set by `sync`
      # and spent here.
      if @follow && @tail_dirty && @pane.size > 0
        @tail_dirty = false
        @pane.goto_line(@pane.size - 1)
        @pane.render(screen, inner, lit, styled_at: styled)
      end
      @follow = tail_visible?
    end

    private def render_status(screen : Screen, rect : Rect, session : Agent::Session?) : Nil
      return if rect.h < 1 || rect.w < 1
      screen.fill(rect, Theme.bg)
      screen.text(rect.x + 1, rect.y, AgentView.status_line(session),
        AgentView.status_colour(session), Theme.bg, width: {rect.w - 2, 0}.max)
      # The follow state is the one thing the band can say that the session cannot: a pane
      # scrolled up keeps growing under the operator, and nothing else on screen says so.
      return if @follow || rect.w < 24
      mark = "⇣ tail"
      screen.text(rect.right - mark.size - 1, rect.y, mark, Theme.muted, Theme.bg)
    end

    private def render_input(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.h < 2 || rect.w < 2
      lit = focused && @focus == :input
      Frame.card(screen, rect, "INPUT", bg: Theme.bg, border: Frame.pane_border(lit))
      # Drawn unconditionally, like the Notes badge: the controller hit-tests these cells, so
      # gating the draw on focus would leave a live target painted on nothing.
      Frame.mode_badge(screen, rect.right - 1, rect.y, rect.x + 1, insert_mode?)
      inner = rect.inset(1, 1)
      return if inner.empty?
      @input.render(screen, inner, cursor: lit && insert_mode?, gauge: true, gauge_focused: lit)
      @read.paint_chrome(screen, inner, @input, lit) unless insert_mode?
    end

    # COLOUR ONLY, which is `ReadPane`'s cardinal rule for a styled provider: the span text is
    # the plain line verbatim, so the caret and the selection band land on the cells the draw
    # advanced over.
    private def styled_line(i : Int32) : Highlight::Line
      text = @pane.line(i)
      [Highlight::Span.new(text, AgentView.line_colour(text))]
    end

    # What a transcript line is, read off the prefix `Transcript#lines_of` gave it. The
    # prefixes ARE the contract between the two — the view never parses the backend's JSON,
    # and adding a kind there means adding its prefix here.
    #
    # The four-space arm is tested BEFORE the two-space one and that ordering is load-bearing:
    # an expanded tool body is indented four, a user message's continuation line two, and
    # `"    x".starts_with?("  ")` is true. Deeper indent wins.
    def self.line_colour(text : String) : Color
      case
      when text.starts_with?("› ")                            then Theme.text_bright
      when text.starts_with?("⚑")                             then Theme.yellow
      when text.starts_with?("! ")                            then Theme.red
      when text.starts_with?("? ")                            then Theme.yellow
      when text.starts_with?("  ✗")                           then Theme.red
      when text.starts_with?("  ✓")                           then Theme.muted
      when text.starts_with?("    ")                          then Theme.muted
      when text.starts_with?("▸ ") || text.starts_with?("▾ ") then Theme.muted
      when text.starts_with?("  ")                            then Theme.text_bright
      else                                                         Theme.text
      end
    end

    # ---- the guidance body ----------------------------------------------------------------

    # What the tab is, what it needs on the machine, and the one key that starts it. The
    # house shape of `traffic_empty_state.cr` — a figure, a gap, a titled card — built here
    # rather than as a variant of that module because every line of it is specific to a child
    # process that may simply not be installed, which no traffic card has to say.
    GUIDANCE = [
      "A coding agent hosted in gori, with this",
      "project's traffic on its own MCP server.",
      "",
      "Needs `claude` on your PATH:",
      "  npm i -g @anthropic-ai/claude-code",
      "",
      "The command is configurable in",
      "settings.json under agent.command.",
    ]
    GUIDANCE_KEYS = [{" ↵ ", "start the agent"}, {" R ", "restart after it exits"}]
    CARD_TITLE    = "AGENT"
    ART_GAP       =  1
    CARD_FLOOR    = 46

    private def render_guidance(screen : Screen, rect : Rect) : Nil
      return if rect.w < 24 || rect.h < 5
      inner_h = GUIDANCE.size + 1 + GUIDANCE_KEYS.size
      card_w = {rect.w - 4, {guidance_width + 4, CARD_FLOOR}.max}.min
      card_h = {inner_h + 2, rect.h}.min
      y = guidance_top(screen, rect, card_w, card_h)
      card = Rect.new(rect.x + {(rect.w - card_w) // 2, 0}.max, y, card_w, card_h)
      Frame.card(screen, card, CARD_TITLE, bg: Theme.bg, border: Theme.border)
      draw_guidance_lines(screen, card.inset(1, 1))
    end

    # Place the figure when it fits above the card, and answer the card's own top row either
    # way. The art is OPPORTUNISTIC — a short pane keeps the card and loses the figure, in
    # that order, which is the rule `TrafficEmptyState.place_art_and_card` states.
    private def guidance_top(screen : Screen, rect : Rect, card_w : Int32, card_h : Int32) : Int32
      art = rect.h >= ART.h + ART_GAP + card_h && rect.w >= ART.min_w + 4
      block_h = art ? ART.h + ART_GAP + card_h : card_h
      y = rect.y + {(rect.h - block_h) // 2, 0}.max
      return y unless art
      EmptyArt.draw(screen, ART, EmptyArt.origin_x(ART, rect.x, rect.w), y)
      y + ART.h + ART_GAP
    end

    private def draw_guidance_lines(screen : Screen, inner : Rect) : Nil
      x = inner.x + 1
      w = {inner.w - 2, 1}.max
      y = inner.y
      GUIDANCE.each do |line|
        break if y >= inner.bottom
        screen.text(x, y, line, line.starts_with?("  ") ? Theme.accent : Theme.muted, Theme.bg, width: w)
        y += 1
      end
      y += 1
      GUIDANCE_KEYS.each do |(chord, what)|
        break if y >= inner.bottom
        px = screen.text(x, y, chord, Theme.text_bright, Theme.accent_bg)
        screen.text(px + 1, y, what, Theme.muted, Theme.bg, width: {inner.right - px - 2, 0}.max)
        y += 1
      end
    end

    private def guidance_width : Int32
      GUIDANCE.max_of { |l| Screen.display_width(l) }
    end

    # ---- mouse ------------------------------------------------------------------------------

    # Focus the pane under the pointer and place its caret. A press on a folded tool line
    # opens the pair (both halves share the `tool_use_id`, so one toggle moves both).
    def handle_click(rect : Rect, mx : Int32, my : Int32, session : Agent::Session?) : Bool
      return false if guidance?(session)
      transcript, _status, input = layout(rect)
      if transcript.contains?(mx, my)
        return click_transcript(transcript, mx, my)
      elsif input.contains?(mx, my)
        return click_input(input, mx, my)
      end
      false
    end

    private def click_transcript(rect : Rect, mx : Int32, my : Int32) : Bool
      focus_pane(:transcript)
      inner = rect.inset(1, 1)
      return true if inner.empty?
      @pane.click(inner, mx, my)
      toggle_fold if cursor_tool_use_id
      true
    end

    private def click_input(rect : Rect, mx : Int32, my : Int32) : Bool
      focus_pane(:input)
      # The READ/INS chip on the top border is a button, exactly as it is in Notes.
      if Frame.mode_badge_hit(mx, my, rect.y, rect.right - 1, rect.x + 1, insert_mode?)
        insert_mode? ? exit_insert! : enter_insert!
        return true
      end
      inner = rect.inset(1, 1)
      return true if inner.empty?
      enter_insert!
      @input.click_to_cursor(inner, mx, my)
      true
    end

    def handle_drag(rect : Rect, mx : Int32, my : Int32) : Nil
      transcript, _status, input = layout(rect)
      case @focus
      when :transcript
        inner = transcript.inset(1, 1)
        return if inner.empty?
        @pane.click(inner, mx, my, selecting: true)
      when :input
        return unless insert_mode?
        inner = input.inset(1, 1)
        return if inner.empty?
        @input.click_to_cursor(inner, mx, my, selecting: true)
      end
    end

    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      transcript, _status, input = layout(rect)
      if transcript.contains?(mx, my)
        inner = transcript.inset(1, 1)
        return false if inner.empty?
        return @pane.select_word(inner, mx, my)
      elsif input.contains?(mx, my)
        inner = input.inset(1, 1)
        return false if inner.empty?
        enter_insert!
        return @input.select_word_at(inner, mx, my)
      end
      false
    end
  end
end
