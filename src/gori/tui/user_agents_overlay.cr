require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./text_area"
require "../settings"
require "../env"

module Gori::Tui
  # The operator's own `$GEN.USER_AGENT` list (settings:user-agents, #1154): a plain multi-line
  # editor, one User-Agent per line, the same shape `gori settings user-agents --set` reads
  # (`Settings.user_agents_from_text` is the ONE parser). An EMPTY buffer means the built-in
  # list — the buffer is never pre-filled with it, because saving an untouched copy would pin
  # today's built-in versions into settings.json and stop them refreshing with gori.
  #
  # esc saves and closes. A line that cannot be a header value refuses the close and names
  # itself, the rule `DiscoverHeadersOverlay` settled: a dropped line silently changes which
  # browser gori claims to be. As there, the refusal holds only while the card that explains it
  # is on screen; where it cannot be drawn, esc closes WITHOUT saving and the degraded line says
  # so, since there is no partial list worth writing.
  class UserAgentsOverlay < Overlay
    def initialize
      @editor = TextArea.new(Settings.user_agents.join("\n"))
      @refused = nil.as(String?)
      @card_drawn = true # see DiscoverHeadersOverlay: production draws before it reads a key
    end

    # The parsed buffer, or the first line that cannot be a User-Agent.
    def parsed : Array(String) | String
      Settings.user_agents_from_text(@editor.text)
    end

    # The list to save; call only once `parsed` answered a list.
    def user_agents : Array(String)
      parsed.as?(Array(String)) || Settings.user_agents
    end

    def refusal : String?
      (why = parsed).is_a?(String) ? "#{why} — fix or delete it" : nil
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::UserAgents
    end

    def title : String
      "USER-AGENTS"
    end

    def hint : String
      "type one per line · empty = built-in list · esc saves & closes"
    end

    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      @card_drawn = !box.nil?
      return try_commit unless box
      return try_commit unless box.contains?(mx, my)
      @editor.click_to_cursor(editor_rect(box), mx, my)
      :stay
    end

    def supports_drag? : Bool
      true
    end

    def handle_drag(area : Rect, mx : Int32, my : Int32) : Nil
      return unless box = overlay_box(area)
      @editor.click_to_cursor(editor_rect(box), mx, my, selecting: true)
    end

    def handle_double_click(area : Rect, mx : Int32, my : Int32) : Symbol
      return :pass unless box = overlay_box(area)
      @editor.select_word_at(editor_rect(box), mx, my) ? :stay : :pass
    end

    # The whole card is the editor, so a pasted line break is a newline.
    def takes_pasted?(ev : Termisu::Event::Key) : Bool
      true
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      return try_commit if ev.key.escape?
      edit(ev)
      :stay
    end

    # A refusal nobody can read is a lock, not a guard: with no card on screen, close — and
    # `on_commit` (Runner#user_agents_editor) saves only a list that parsed.
    private def try_commit : Symbol
      @refused = refusal
      (@refused && @card_drawn) ? :stay : :commit
    end

    private def edit(ev : Termisu::Event::Key) : Nil
      @refused = nil
      key = ev.key
      case
      when key.enter?                    then @editor.insert_newline
      when ev.ctrl? && key.lower_z?      then @editor.undo
      when @editor.word_delete_key?(ev)  then @editor.handle_motion_key(ev)
      when key.backspace?                then @editor.backspace
      when key.delete?                   then @editor.delete
      when @editor.handle_motion_key(ev) then nil
      else
        ch = ev.char || key.to_char
        @editor.insert(ch) if ch && !ev.ctrl? && !ev.alt?
      end
    end

    def set_preedit(text : String) : Nil
      @editor.set_preedit(text)
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 100}.min
      h = {area.h - 2, 18}.min
      return nil if w < 34 || h < 8
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    private def editor_rect(box : Rect) : Rect
      top = box.y + 1
      Rect.new(box.x + 2, top, box.w - 4, {(box.bottom - 2) - top, 1}.max)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      @card_drawn = !box.nil?
      unless box
        render_degraded(screen, area) unless area.empty?
        return
      end
      Frame.card(screen, box, "USER-AGENTS", bg: Theme.bg, border: Theme.border_focus)
      hintline = box.bottom - 2
      editor = editor_rect(box)
      if @editor.line_count == 1 && @editor.text.empty?
        screen.text(editor.x, editor.y,
          "empty — $GEN.USER_AGENT draws from the built-in list (#{Env::USER_AGENTS.size})",
          Theme.muted, Theme.bg, width: editor.w)
        screen.cursor(editor.x, editor.y)
      else
        @editor.render(screen, editor, cursor: true)
      end
      if refused = @refused
        screen.text(box.x + 2, hintline, refused, Theme.red, Theme.bg, width: box.w - 4)
      else
        screen.text(box.x + 2, hintline,
          "one per line, replaces the built-in list · a family with no line of yours uses the built-in one",
          Theme.muted, Theme.bg, width: box.w - 4)
      end
    end

    private def render_degraded(screen : Screen, area : Rect) : Nil
      if refusal
        screen.text(area.x + 1, area.y, "esc closes WITHOUT saving · a line is unusable · widen the window to fix", Theme.red, Theme.bg)
      else
        screen.text(area.x + 1, area.y, "User-Agents editor needs a larger window · esc saves & closes", Theme.muted, Theme.bg)
      end
    end
  end
end
