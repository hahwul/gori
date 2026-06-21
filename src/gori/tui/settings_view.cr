require "./screen"
require "./theme"
require "./frame"
require "../settings"

module Gori::Tui
  # The interactive settings editor — the UI that controls gori's persisted config
  # (Gori::Settings). Currently the NETWORK section: the proxy bind address + an
  # optional upstream proxy. Reusable by both the Runner (a :settings overlay) and
  # the ProjectPicker (a settings mode). Theme/hotkeys sections are TODO.
  #
  # Apply semantics: the upstream proxy takes effect immediately (Upstream.dial
  # reads it live). The bind address is persisted here; in-project the Runner
  # rebinds the running proxy to it immediately, and the picker (no live proxy)
  # has it take effect on the next project open.
  class SettingsView
    # `bool` fields are on/off toggles (value kept as "on"/"off"); the rest are
    # free-text input lines.
    record Field, label : String, hint : String, bool : Bool = false

    NETWORK_FIELDS = [
      Field.new("Bind IP", "proxy listen address"),
      Field.new("Bind Port", "proxy listen port (0-65535)"),
      Field.new("Upstream proxy", "host:port — blank = connect directly"),
    ]
    EDITOR_FIELDS = [
      Field.new("External editor", "e.g. vim · code --wait — blank = $VISUAL/$EDITOR/vi"),
      Field.new("Markdown highlight", "syntax-colour markdown in Notes/Project — ←/→/space toggles", bool: true),
    ]
    SECTIONS = {:network => NETWORK_FIELDS, :editor => EDITOR_FIELDS}

    getter? saved : Bool = false
    getter section : Symbol = :network

    def initialize
      @values = ["", "", ""]
      @focused = 0
      @cursor = 0
      @preedit = ""
      @status = nil.as(String?)
      reload
    end

    private def fields
      SECTIONS[@section]
    end

    # Pull current values from the live Settings for `section` (called when the
    # editor opens). Defaults to :network so the no-arg picker call keeps working.
    def reload(section : Symbol = :network) : Nil
      @section = section
      @values = case section
                when :editor then [Settings.editor, Settings.editor_markdown ? "on" : "off"]
                else              [Settings.bind_host, Settings.bind_port.to_s, Settings.upstream_proxy]
                end
      @focused = 0
      @cursor = @values[0].size
      @preedit = ""
      @status = nil
      @saved = false
    end

    def move_field(delta : Int32) : Nil
      @focused = (@focused + delta).clamp(0, @values.size - 1)
      @cursor = @values[@focused].size
      @preedit = ""
    end

    def set_preedit(text : String) : Nil
      @preedit = text
    end

    def insert(ch : Char) : Nil
      if bool_field? # a toggle field swallows typing; space flips it
        toggle if ch == ' '
        return
      end
      v = @values[@focused]
      c = @cursor.clamp(0, v.size)
      @values[@focused] = "#{v[0, c]}#{ch}#{v[c..]}"
      @cursor = c + 1
      @preedit = ""
      @status = nil
    end

    def backspace : Nil
      return if bool_field? || @cursor == 0
      v = @values[@focused]
      c = @cursor.clamp(0, v.size)
      @values[@focused] = "#{v[0, c - 1]}#{v[c..]}"
      @cursor = c - 1
      @status = nil
    end

    # ←/→: on a toggle field flips it; on a text field moves the caret.
    def toggle_or_move(delta : Int32) : Nil
      bool_field? ? toggle : move_cursor(delta)
    end

    def move_cursor(delta : Int32) : Nil
      @cursor = (@cursor + delta).clamp(0, @values[@focused].size)
    end

    private def bool_field? : Bool
      fields[@focused].bool
    end

    private def toggle : Nil
      @values[@focused] = @values[@focused] == "on" ? "off" : "on"
      @status = nil
    end

    # Validate, apply, and persist. Returns a status message for the caller to
    # toast (nil decoded values are not possible here — port is the only check).
    def save : String
      if @section == :editor
        Settings.editor = @values[0].strip # blank is valid → clears to $VISUAL/$EDITOR/vi
        Settings.editor_markdown = @values[1] == "on"
        @values = [Settings.editor, Settings.editor_markdown ? "on" : "off"]
        return persist
      end
      port = @values[1].strip.to_i?
      unless port && 0 <= port <= 65535
        @status = "invalid port"
        return "settings: invalid bind port #{@values[1].inspect}"
      end
      Settings.bind_host = @values[0].strip
      Settings.bind_port = port
      Settings.upstream_proxy = @values[2].strip
      @values = [Settings.bind_host, Settings.bind_port.to_s, Settings.upstream_proxy]
      persist
    end

    private def persist : String
      ok = Settings.save
      @saved = ok
      @status = ok ? "saved" : "save failed"
      ok ? "settings saved" : "settings: save failed (could not write #{Settings.path})"
    end

    def render(screen : Screen, area : Rect) : Nil
      flds = fields
      label_w = flds.max_of(&.label.size)
      w = {area.w - 4, 64}.min
      h = flds.size + 6
      return if w < 30 || area.h < h
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      box = Rect.new(x, y, w, h)
      Frame.card(screen, box, "SETTINGS · #{@section.to_s.upcase}", border: Theme::BORDER_FOCUS)

      flds.each_with_index do |field, i|
        ry = box.y + 2 + i
        focused = i == @focused
        bg = focused ? Theme::ACCENT_BG : Theme::PANEL
        screen.fill(Rect.new(box.x + 1, ry, w - 2, 1), bg)
        screen.cell(box.x + 1, ry, focused ? '▎' : ' ', Theme::ACCENT, bg)
        screen.text(box.x + 3, ry, field.label, focused ? Theme::TEXT_BRIGHT : Theme::TEXT, bg)
        screen.text(box.x + 3 + label_w + 1, ry, "›", focused ? Theme::ACCENT : Theme::MUTED, bg)
        vx = box.x + 3 + label_w + 3
        vw = {box.right - vx - 1, 1}.max
        value = @values[i]
        if field.bool
          on = value == "on"
          glyph = on ? "◉ on" : "◯ off"
          col = focused ? Theme::TEXT_BRIGHT : (on ? Theme::GREEN : Theme::MUTED)
          screen.text(vx, ry, glyph, col, bg, width: vw)
        elsif focused
          screen.input_line(vx, ry, value, @cursor, @preedit, Theme::TEXT_BRIGHT, bg, width: vw)
        elsif value.empty?
          screen.text(vx, ry, field.hint, Theme::MUTED, bg, width: vw)
        else
          screen.text(vx, ry, value, Theme::TEXT, bg, width: vw)
        end
      end

      # status line (left) + hint (right) on the bottom interior row
      note_y = box.bottom - 2
      if status = @status
        color = status.starts_with?("invalid") || status.starts_with?("save failed") ? Theme::YELLOW : Theme::GREEN
        screen.text(box.x + 3, note_y, "• #{status}", color, Theme::PANEL)
      else
        screen.text(box.x + 3, note_y, fields[@focused].hint, Theme::MUTED, Theme::PANEL)
      end
      hint = "↑/↓ field · ↵ save · esc close"
      screen.text(box.right - hint.size - 2, note_y, hint, Theme::MUTED, Theme::PANEL)
    end
  end
end
