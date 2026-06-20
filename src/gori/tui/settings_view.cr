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
  # reads it live); the bind address is persisted and applied on the next project
  # open (the running proxy keeps its current bind).
  class SettingsView
    record Field, label : String, hint : String

    FIELDS = [
      Field.new("Bind IP", "proxy listen address"),
      Field.new("Bind Port", "proxy listen port (0-65535)"),
      Field.new("Upstream proxy", "host:port — blank = connect directly"),
    ]

    getter? saved : Bool = false

    def initialize
      @values = ["", "", ""]
      @focused = 0
      @cursor = 0
      @preedit = ""
      @status = nil.as(String?)
      reload
    end

    # Pull current values from the live Settings (called when the editor opens).
    def reload : Nil
      @values = [Settings.bind_host, Settings.bind_port.to_s, Settings.upstream_proxy]
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
      v = @values[@focused]
      c = @cursor.clamp(0, v.size)
      @values[@focused] = "#{v[0, c]}#{ch}#{v[c..]}"
      @cursor = c + 1
      @preedit = ""
      @status = nil
    end

    def backspace : Nil
      return if @cursor == 0
      v = @values[@focused]
      c = @cursor.clamp(0, v.size)
      @values[@focused] = "#{v[0, c - 1]}#{v[c..]}"
      @cursor = c - 1
      @status = nil
    end

    def move_cursor(delta : Int32) : Nil
      @cursor = (@cursor + delta).clamp(0, @values[@focused].size)
    end

    # Validate, apply, and persist. Returns a status message for the caller to
    # toast (nil decoded values are not possible here — port is the only check).
    def save : String
      port = @values[1].strip.to_i?
      unless port && 0 <= port <= 65535
        @status = "invalid port"
        return "settings: invalid bind port #{@values[1].inspect}"
      end
      bind_changed = @values[0].strip != Settings.bind_host || port != Settings.bind_port
      Settings.bind_host = @values[0].strip
      Settings.bind_port = port
      Settings.upstream_proxy = @values[2].strip
      @values = [Settings.bind_host, Settings.bind_port.to_s, Settings.upstream_proxy]
      ok = Settings.save
      @saved = ok
      @status = ok ? "saved" : "save failed"
      if !ok
        "settings: save failed (could not write #{Settings.path})"
      elsif bind_changed
        "settings saved — bind applies on next project open"
      else
        "settings saved"
      end
    end

    def render(screen : Screen, area : Rect) : Nil
      label_w = FIELDS.max_of(&.label.size)
      w = {area.w - 4, 64}.min
      h = FIELDS.size + 6
      return if w < 30 || area.h < h
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      box = Rect.new(x, y, w, h)
      Frame.card(screen, box, "SETTINGS · NETWORK", border: Theme::BORDER_FOCUS)

      FIELDS.each_with_index do |field, i|
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
        if focused
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
        screen.text(box.x + 3, note_y, FIELDS[@focused].hint, Theme::MUTED, Theme::PANEL)
      end
      hint = "↑/↓ field · ↵ save · esc close"
      screen.text(box.right - hint.size - 2, note_y, hint, Theme::MUTED, Theme::PANEL)
    end
  end
end
