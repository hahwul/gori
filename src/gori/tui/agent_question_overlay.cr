require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./note_detail_overlay"
require "./agent_message_notes"
require "../store"

module Gori::Tui
  # The answer card for an agent's `ask_operator` question (#1324): the question, the context
  # the agent gave, and its two to four choices, each on a digit key.
  #
  #   ┌ AGENT ASKS ───────────────────────── claude-code ┐
  #   │ Add api.example.com to scope?                    │
  #   │ asked 2m ago · expires in 28m                    │
  #   ├──────────────────────────────────────────────────┤
  #   │ It serves the same session cookie as app.exampl… │
  #   ├──────────────────────────────────────────────────┤
  #   │▎1  yes                                           │
  #   │ 2  no                                    default │
  #   └──────────────────────────────────────────────────┘
  #
  # Raised only by the operator — the ring's ↵, the `ask:` chip, `app.answer-agent` — never on
  # its own: a question that stole focus would land keystrokes meant for an editor on a choice.
  # `esc` is "later", not "no": the card closes and the question stays open. `x` is the
  # explicit "I will not choose", which the agent hears as a dismissal.
  #
  # A dumb form like its siblings: `handle_key` records the decision in `decision` and answers
  # `:commit`, and the open-site's `on_commit` writes it.
  class AgentQuestionOverlay < Overlay
    MAX_W = 72
    MIN_W = 36
    # The question gets up to three lines and the detail up to ten; past that the detail band
    # scrolls. A card taller than this is a card that hides what it sits on for no gain.
    QUESTION_ROWS =  3
    DETAIL_ROWS   = 10
    # `decision` for the explicit dismissal.
    DISMISS = -1

    getter question : Gori::AgentQuestion
    getter who : String
    getter selected : Int32
    # The choice index to answer with, or `DISMISS`; nil until a key decides.
    getter decision : Int32?

    def initialize(@question : Gori::AgentQuestion, @who : String,
                   @now_us : Proc(Int64) = -> { Time.utc.to_unix_ms * 1000 })
      @selected = @question.default.try { |d| @question.choices.index(d) } || 0
      @decision = nil
      @scroll = 0
      @detail_h = 0
    end

    # The label the decision stands for, or nil for a dismissal (or no decision yet).
    def decided_choice : String?
      d = @decision
      return nil if d.nil? || d == DISMISS
      @question.choices[d]?
    end

    def dismissed? : Bool
      @decision == DISMISS
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::AgentQuestion
    end

    def title : String
      "AGENT ASKS"
    end

    def hint : String
      "1-#{@question.choices.size}/↵ answer · ↑/↓ choose · x dismiss · esc later"
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      k = ev.key
      return :cancel if k.escape?
      if k.enter?
        @decision = @selected
        return :commit
      end
      return :stay if nav_key(k)
      c = ev.char
      return :stay if c.nil? || ev.ctrl? || ev.alt?
      char_key(c)
    end

    # ↑/↓ between the choices, ⇞/⇟ through the detail. True when the key was one of them.
    private def nav_key(k : Termisu::Input::Key) : Bool
      case
      when k.up?        then move(-1)
      when k.down?      then move(1)
      when k.page_up?   then scroll_by(-{@detail_h, 1}.max)
      when k.page_down? then scroll_by({@detail_h, 1}.max)
      else                   return false
      end
      true
    end

    # A digit answers with that choice in one key, `x` dismisses, `j`/`k` move.
    private def char_key(c : Char) : Symbol
      if (d = c.to_i?) && 1 <= d && d <= @question.choices.size
        @selected = d - 1
        @decision = @selected
        return :commit
      end
      case c
      when 'x'
        @decision = DISMISS
        return :commit
      when 'j' then move(1)
      when 'k' then move(-1)
      end
      :stay
    end

    # A click on a choice answers with it; anywhere else inside is inert; outside dismisses
    # the CARD, which is "later" — never the question.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if idx = choice_at(box, my)
        @selected = idx
        @decision = idx
        return :commit
      end
      :stay
    end

    # ↑/↓ move between the choices; the wheel scrolls the detail, which is the only thing on
    # the card long enough to need it.
    def move(d : Int32) : Nil
      @selected = (@selected + d).clamp(0, @question.choices.size - 1)
    end

    def handle_wheel(step : Int32) : Nil
      scroll_by(step)
    end

    private def scroll_by(d : Int32) : Nil
      @scroll = {@scroll + d, 0}.max
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, MAX_W}.min
      return nil if w < MIN_W
      text_w = w - 4
      fixed = fixed_rows(text_w)
      detail = detail_lines(text_w)
      room = area.h - 2 - fixed
      return nil if room < 0 || (!detail.empty? && room < 1)
      h = fixed + {detail.size, DETAIL_ROWS, room}.min
      area.center(w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        Overlay.too_small(screen, area, "the agent's question needs a larger window", "esc for later")
        return
      end
      text_w = box.w - 4
      Frame.card(screen, box, "AGENT ASKS", border: Theme.border_focus)
      Frame.border_meta(screen, box, "AGENT ASKS", @who, bg: Theme.panel)
      y = box.y + 1
      question_lines(text_w).each do |line|
        screen.text(box.x + 2, y, line, Theme.text_bright, Theme.panel, Attribute::Bold, width: text_w)
        y += 1
      end
      screen.text(box.x + 2, y, AgentMessageNotes.question_meta(@question, @now_us.call), Theme.muted, Theme.panel, width: text_w)
      y += 1
      Frame.tee_divider(screen, box, y)
      y += 1
      detail = detail_lines(text_w)
      unless detail.empty?
        @detail_h = box.bottom - 1 - @question.choices.size - 1 - y
        @scroll = @scroll.clamp(0, {detail.size - @detail_h, 0}.max)
        @detail_h.times do |i|
          line = detail[@scroll + i]?
          break unless line
          screen.text(box.x + 2, y + i, line, Theme.text, Theme.panel, width: text_w)
        end
        Frame.scroll_gauge(screen, Rect.new(box.x + 1, y, box.w - 2, @detail_h), detail.size, @scroll, true, Theme.panel)
        y += @detail_h
        Frame.tee_divider(screen, box, y)
        y += 1
      end
      @question.choices.each_with_index do |choice, i|
        draw_choice(screen, box, y + i, i, choice)
      end
    end

    private def draw_choice(screen : Screen, box : Rect, py : Int32, i : Int32, choice : String) : Nil
      sel = i == @selected
      bg = Frame.row_band(screen, box, py, sel)
      screen.text(box.x + 2, py, (i + 1).to_s, Theme.accent, bg, Attribute::Bold)
      tag = choice == @question.default ? "default" : ""
      label_w = {box.w - 6 - (tag.empty? ? 0 : tag.size + 1), 1}.max
      screen.text(box.x + 5, py, choice, sel ? Theme.text_bright : Theme.text, bg, width: label_w)
      screen.text(box.right - 2 - tag.size, py, tag, Theme.muted, bg) unless tag.empty?
    end

    # The row index of the choice drawn at `my`, mirroring render's layout from the bottom:
    # the choices are always the last rows above the border.
    private def choice_at(box : Rect, my : Int32) : Int32?
      first = box.bottom - 1 - @question.choices.size
      i = my - first
      (0 <= i && i < @question.choices.size) ? i : nil
    end

    # Borders, the question, the meta line, the divider, the choices — and the second divider
    # when a detail band sits between.
    private def fixed_rows(text_w : Int32) : Int32
      2 + question_lines(text_w).size + 1 + 1 + @question.choices.size +
        (detail_lines(text_w).empty? ? 0 : 1)
    end

    private def question_lines(text_w : Int32) : Array(String)
      lines = NoteDetailOverlay.wrap_text(AgentMessageNotes.scrub(@question.question), text_w)
      lines = [""] if lines.empty?
      return lines if lines.size <= QUESTION_ROWS
      kept = lines.first(QUESTION_ROWS)
      kept[-1] = kept[-1].rstrip + "…"
      kept
    end

    # Cached per width: render and overlay_box both ask, every frame.
    @detail_cache : {Int32, Array(String)}? = nil

    private def detail_lines(text_w : Int32) : Array(String)
      if (c = @detail_cache) && c[0] == text_w
        return c[1]
      end
      lines = @question.detail.try { |d| NoteDetailOverlay.wrap_text(d, text_w) } || [] of String
      while lines.last?.try(&.strip.empty?)
        lines.pop
      end
      @detail_cache = {text_w, lines}
      lines
    end
  end
end
