require "./screen"
require "./theme"
require "./frame"
require "../settings"

module Gori::Tui
  # The interactive settings editor — the UI that controls gori's persisted config
  # (Gori::Settings). Sections: NETWORK (proxy bind + upstream proxy), EDITOR (the
  # external ^E editor), THEME (the TUI colour theme). Reusable by both the Runner
  # (a :settings overlay) and the ProjectPicker (a settings mode). Hotkeys are TODO.
  #
  # Apply semantics: the upstream proxy takes effect immediately (Upstream.dial
  # reads it live). The bind address is persisted here; in-project the Runner
  # rebinds the running proxy to it immediately, and the picker (no live proxy)
  # has it take effect on the next project open. The theme is applied by the Runner
  # on save (Theme.apply + a full repaint).
  class SettingsView
    # `bool` fields are on/off toggles (value kept as "on"/"off"); a field with
    # `choices` cycles among those values (←/→/space); the rest are free-text lines.
    record Field, label : String, hint : String, bool : Bool = false, choices : Array(String)? = nil

    NETWORK_FIELDS = [
      Field.new("Bind IP", "proxy listen address"),
      Field.new("Bind Port", "proxy listen port (0-65535)"),
      Field.new("Upstream proxy", "host:port — blank = connect directly"),
    ]
    EDITOR_FIELDS = [
      Field.new("External editor", "e.g. vim · code --wait — blank = $VISUAL/$EDITOR/vi"),
      Field.new("Markdown highlight", "syntax-colour markdown in Notes/Project — ←/→/space toggles", bool: true),
    ]
    THEME_FIELDS = [
      Field.new("Theme", "TUI colour theme — ←/→/space cycles, ↵ applies", choices: Theme.available),
    ]
    SECTIONS = {:network => NETWORK_FIELDS, :editor => EDITOR_FIELDS, :theme => THEME_FIELDS}

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
                when :theme  then [Theme.canonical(Settings.theme)]
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
      if choice_field? # a choice field swallows typing; space cycles to the next option
        cycle(1) if ch == ' '
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
      return if bool_field? || choice_field? || @cursor == 0
      v = @values[@focused]
      c = @cursor.clamp(0, v.size)
      @values[@focused] = "#{v[0, c - 1]}#{v[c..]}"
      @cursor = c - 1
      @status = nil
    end

    # ←/→: a toggle field flips, a choice field cycles, a text field moves the caret.
    def toggle_or_move(delta : Int32) : Nil
      if bool_field?
        toggle
      elsif choice_field?
        cycle(delta)
      else
        move_cursor(delta)
      end
    end

    def move_cursor(delta : Int32) : Nil
      @cursor = (@cursor + delta).clamp(0, @values[@focused].size)
    end

    private def bool_field? : Bool
      fields[@focused].bool
    end

    private def choice_field? : Bool
      !fields[@focused].choices.nil?
    end

    private def toggle : Nil
      @values[@focused] = @values[@focused] == "on" ? "off" : "on"
      @status = nil
    end

    # Advance the focused choice field by `delta` (wraps; Crystal's % is modulo, so
    # -1 wraps to the last option for ←).
    private def cycle(delta : Int32) : Nil
      choices = fields[@focused].choices
      return unless choices
      i = choices.index(@values[@focused]) || 0
      @values[@focused] = choices[(i + delta) % choices.size]
      @status = nil
    end

    # Validate, apply, and persist. Returns a status message for the caller to
    # toast (nil decoded values are not possible here — port is the only check).
    def save : String
      if @section == :theme
        Settings.theme = @values[0] # always one of THEME_FIELDS' choices (set only via cycle)
        return persist
      end
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
      Frame.card(screen, box, "SETTINGS · #{@section.to_s.upcase}", border: Theme.border_focus)

      flds.each_with_index do |field, i|
        ry = box.y + 2 + i
        focused = i == @focused
        bg = focused ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(box.x + 1, ry, w - 2, 1), bg)
        screen.cell(box.x + 1, ry, focused ? '▎' : ' ', Theme.accent, bg)
        screen.text(box.x + 3, ry, field.label, focused ? Theme.text_bright : Theme.text, bg)
        screen.text(box.x + 3 + label_w + 1, ry, "›", focused ? Theme.accent : Theme.muted, bg)
        vx = box.x + 3 + label_w + 3
        vw = {box.right - vx - 1, 1}.max
        value = @values[i]
        if choices = field.choices
          # List the options left-to-right; the active one is emphasised (◉ + bright).
          cx = vx
          left = vw
          choices.each do |opt|
            break if left <= 0
            on = opt == value
            seg = "#{on ? '◉' : '◯'} #{opt}"
            screen.text(cx, ry, seg, on ? Theme.text_bright : Theme.muted, bg, width: left)
            adv = seg.size + 2
            cx += adv
            left -= adv
          end
        elsif field.bool
          on = value == "on"
          glyph = on ? "◉ on" : "◯ off"
          col = focused ? Theme.text_bright : (on ? Theme.green : Theme.muted)
          screen.text(vx, ry, glyph, col, bg, width: vw)
        elsif focused
          screen.input_line(vx, ry, value, @cursor, @preedit, Theme.text_bright, bg, width: vw)
        elsif value.empty?
          screen.text(vx, ry, field.hint, Theme.muted, bg, width: vw)
        else
          screen.text(vx, ry, value, Theme.text, bg, width: vw)
        end
      end

      # status line (left) + hint (right) on the bottom interior row
      note_y = box.bottom - 2
      if status = @status
        color = status.starts_with?("invalid") || status.starts_with?("save failed") ? Theme.yellow : Theme.green
        screen.text(box.x + 3, note_y, "• #{status}", color, Theme.panel)
      else
        screen.text(box.x + 3, note_y, fields[@focused].hint, Theme.muted, Theme.panel)
      end
      hint = "↑/↓ field · ↵ save · esc close"
      screen.text(box.right - hint.size - 2, note_y, hint, Theme.muted, Theme.panel)
    end
  end
end
