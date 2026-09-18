require "json"
require "./overlay"
require "./frame"
require "./screen"
require "./theme"
require "../agent/event"

module Gori::Tui
  # The card a hosted agent's held tool call raises (#1093): what it wants to run, and three
  # answers. Not a `ConfirmDialog` — that card is strictly two buttons, and "allow for this
  # session" is a third OUTCOME, not a modifier on allow: the answer the operator gives to
  # the fifth `Read` of the turn is "stop asking me about Read", and folding that into a
  # checkbox next to a yes/no would hide the one button they came for.
  #
  # Every answer is a decision about THIS gori session only. The CLI's own suggestion
  # (`permission_suggestions`, which would write a rule into the operator's `~/.claude`
  # settings) is never offered here: gori does not edit the operator's agent configuration
  # behind their back.
  #
  # `esc` and click-away are DENY. There is no "decide later": the CLI holds the tool call —
  # and the whole turn — until it hears back, so dismissing the card without an answer would
  # leave the agent wedged with nothing on screen saying why. The open-site maps the
  # `:cancel` outcome to a deny for the same reason.
  class AgentPermissionOverlay < Overlay
    MAX_WIDTH  = 76
    MIN_WIDTH  = 40
    MIN_HEIGHT =  7
    # Rows the card spends around the text: borders, a blank over the buttons, the button
    # row, a blank under it.
    CHROME_H = 5
    # Lines of the input preview before an elision row.
    PREVIEW_CAP = 12

    alias Decision = Gori::Agent::Decision

    BUTTONS = [
      {Decision::Allow, 'a', "allow"},
      {Decision::AllowForSession, 's', "allow for session"},
      {Decision::Deny, 'd', "deny"},
    ]

    getter request : Gori::Agent::Event::PermissionAsked
    # What the operator chose. nil until a button was pressed; the open-site's `on_commit`
    # reads it, and `on_close` without one is a deny.
    getter answered : Decision?

    def initialize(@request : Gori::Agent::Event::PermissionAsked)
      # The safe default under ↵ is DENY: an operator who hits enter to dismiss a card they
      # did not read must not have run the command.
      @selected = 2
      @answered = nil
      @drawn = true
    end

    def key : OverlayKind
      OverlayKind::AgentPermission
    end

    def title : String
      "PERMISSION"
    end

    def hint : String
      "←/→ choose · ↵ #{BUTTONS[@selected][2]} · a allow · s allow for session · d/esc deny"
    end

    def takes_pasted?(ev : Termisu::Event::Key) : Bool
      false
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      return :stay if ev.ctrl? || ev.alt?
      key = ev.key
      case
      when key.escape?
        answer(Decision::Deny)
      when key.left?, key.back_tab?
        @selected = (@selected - 1) % BUTTONS.size
        :stay
      when key.right?, key.tab?
        @selected = (@selected + 1) % BUTTONS.size
        :stay
      when key.enter?
        @drawn ? answer(BUTTONS[@selected][0]) : :stay
        # The mnemonics are matched on the KEY, like `ConfirmDialog.affirmative?`: termisu's
        # `key.a?` is case-insensitive and knows nothing about modifiers, which is why ctrl/alt
        # were refused above — `^A`/`^D` are live chords elsewhere and must not answer a card.
      when key.a? then @drawn ? answer(Decision::Allow) : :stay
      when key.s? then @drawn ? answer(Decision::AllowForSession) : :stay
      when key.d? then @drawn ? answer(Decision::Deny) : :stay
      else             :stay
      end
    end

    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return answer(Decision::Deny) if box.nil? || !box.contains?(mx, my)
      button_rects(box).each_with_index do |r, i|
        return answer(BUTTONS[i][0]) if r.contains?(mx, my)
      end
      :stay
    end

    # A stray wheel notch must not re-aim the lit button.
    def handle_wheel(step : Int32) : Nil
    end

    def render(screen : Screen, area : Rect) : Nil
      @drawn = false
      box = overlay_box(area)
      return unless box
      @drawn = true
      Frame.card(screen, box, "#{@request.display.upcase} WANTS TO RUN", border: Theme.border_focus)
      room = box.h - CHROME_H
      lines = display_lines
      shown = lines.size > room ? lines[0, {room - 1, 0}.max] + ["… #{lines.size - room + 1} more lines"] : lines
      shown.each_with_index do |line, i|
        fg = line.starts_with?("  ") ? Theme.text : Theme.muted
        screen.text(box.x + 2, box.y + 1 + i, line, fg, Theme.panel, width: box.w - 4)
      end
      button_rects(box).each_with_index do |r, i|
        selected = i == @selected
        danger = BUTTONS[i][0].deny?
        text = " #{button_text(i)} "
        if selected
          bg = danger ? Theme.red : Theme.accent_bg
          screen.fill(r, bg)
          screen.text(r.x, r.y, text, Theme.text_bright, bg, attr: Attribute::Bold)
        else
          screen.text(r.x, r.y, text, danger ? Theme.red : Theme.muted, Theme.panel)
        end
      end
    end

    # The centred card, or nil when `area` cannot hold even the buttons.
    def overlay_box(area : Rect) : Rect?
      return nil if area.w < MIN_WIDTH || area.h < MIN_HEIGHT
      lines = display_lines
      content = {lines.max_of { |l| Screen.display_width(l) }, button_row_width,
                 Screen.draw_width(@request.display) + 16}.max
      w = (content + 4).clamp(MIN_WIDTH, {area.w - 2, MAX_WIDTH}.min)
      h = {lines.size + CHROME_H, area.h - 2}.min
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    # The text rows: the input (the command, or the pretty JSON), then the CLI's own
    # description and its reason for asking. Indented rows are the input, so the renderer can
    # light them as text and the rest as commentary.
    def display_lines : Array(String)
      lines = [] of String
      input_lines.each { |l| lines << "  #{l}" }
      lines << "" unless lines.empty?
      lines << @request.description unless @request.description.empty?
      lines << "asked because: #{@request.reason}" unless @request.reason.empty?
      lines << "this answer lives in gori, for this session only"
      lines
    end

    private def input_lines : Array(String)
      h = JSON.parse(@request.input_json).as_h?
      raw =
        if h && (cmd = h["command"]?.try(&.as_s?))
          cmd.split('\n')
        elsif h && h.size == 1 && (v = h.values.first.as_s?)
          ["#{h.keys.first}: #{v}"].flat_map(&.split('\n'))
        else
          JSON.parse(@request.input_json).to_pretty_json.split('\n')
        end
      raw.size > PREVIEW_CAP ? raw[0, PREVIEW_CAP] + ["… #{raw.size - PREVIEW_CAP} more"] : raw
    rescue JSON::ParseException
      [@request.input_json[0, 200]]
    end

    private def answer(d : Decision) : Symbol
      @answered = d
      :commit
    end

    private def button_text(i : Int32) : String
      "[#{BUTTONS[i][1]}] #{BUTTONS[i][2]}"
    end

    private def button_row_width : Int32
      BUTTONS.size.times.sum { |i| Screen.draw_width(button_text(i)) + 2 } + 2 * (BUTTONS.size - 1)
    end

    def button_rects(box : Rect) : Array(Rect)
      x = box.x + (box.w - button_row_width) // 2
      y = box.bottom - 3
      BUTTONS.size.times.map do |i|
        w = Screen.draw_width(button_text(i)) + 2
        r = Rect.new(x, y, w, 1)
        x += w + 2
        r
      end.to_a
    end
  end
end
