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
      Field.new("Mouse", "click + scroll-wheel navigation (off restores native text selection)", bool: true),
      Field.new("Pretty-print bodies", "reflow JSON/XML/form/… in History detail + Replay response — display only; ←/→/space toggles", bool: true),
    ]
    # The THEME section is special: a single field whose value is the selected theme
    # name, but rendered as a vertical, scrollable list (built-ins + user themes) rather
    # than the inline ←/→ cycle the other `choices` fields use. `choices` is kept only so
    # `choice_field?` swallows typing; the live list comes from Theme.available.
    THEME_FIELDS = [
      Field.new("Theme", "TUI colour theme — ↑/↓ select, ↵ applies", choices: Theme.available),
    ]
    SECTIONS = {:network => NETWORK_FIELDS, :editor => EDITOR_FIELDS, :theme => THEME_FIELDS}

    # Max theme rows shown at once before the list scrolls (the box also shrinks to the
    # terminal height — see overlay_box).
    THEME_LIST_MAX = 10

    getter? saved : Bool = false
    getter section : Symbol = :network

    def initialize
      @values = ["", "", ""]
      @focused = 0
      @cursor = 0
      @preedit = ""
      @status = nil.as(String?)
      @theme_scroll = 0 # top row of the THEME list viewport (see render_theme_list)
      reload
    end

    private def fields
      SECTIONS[@section]
    end

    # Pull current values from the live Settings for `section` (called when the
    # editor opens). Defaults to :network so the no-arg picker call keeps working.
    def reload(section : Symbol = :network) : Nil
      @section = section
      Theme.load_custom if section == :theme # pick up theme files dropped since startup
      @values = case section
                when :editor then [Settings.editor, Settings.editor_markdown ? "on" : "off", Settings.mouse ? "on" : "off", Settings.pretty_bodies_default ? "on" : "off"]
                when :theme  then [Theme.canonical(Settings.theme)]
                else              [Settings.bind_host, Settings.bind_port.to_s, Settings.upstream_proxy]
                end
      @focused = 0
      @cursor = @values[0].size
      @preedit = ""
      @status = nil
      @saved = false
      @theme_scroll = 0 # render scrolls to the selected theme on the first frame
    end

    # Revert the working copy of the CURRENT section to its factory defaults (the values a
    # fresh install ships with — Settings::DEFAULT_*). Like every other edit here it touches
    # the working copy only: it applies on save (↵) and is discarded on esc. The caller
    # live-previews the restored default theme in the :theme section.
    def reset_to_defaults : Nil
      @values = case @section
                when :editor then [Settings::DEFAULT_EDITOR, Settings::DEFAULT_EDITOR_MARKDOWN ? "on" : "off", Settings::DEFAULT_MOUSE ? "on" : "off", Settings::DEFAULT_PRETTY_BODIES ? "on" : "off"]
                when :theme  then [Theme.canonical(Settings::DEFAULT_THEME)]
                else              [Settings::DEFAULT_BIND_HOST, Settings::DEFAULT_BIND_PORT.to_s, Settings::DEFAULT_UPSTREAM_PROXY]
                end
      @focused = 0
      @cursor = @values[0].size
      @preedit = ""
      @status = nil
    end

    # ↑/↓: move between fields — except in the THEME section, whose single field IS a
    # vertical list, so up/down move the theme selection (render keeps it on screen).
    def move_field(delta : Int32) : Nil
      if @section == :theme
        cycle(delta)
        return
      end
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
    # -1 wraps to the last option for ←). The THEME section reads the live theme list
    # (Theme.available — includes user themes loaded after this view was built) rather
    # than the field's captured `choices`.
    private def cycle(delta : Int32) : Nil
      if @section == :theme
        names = Theme.available
        return if names.empty?
        i = names.index(@values[0]) || 0
        @values[0] = names[(i + delta) % names.size]
        @status = nil
        return
      end
      choices = fields[@focused].choices
      return unless choices
      i = choices.index(@values[@focused]) || 0
      @values[@focused] = choices[(i + delta) % choices.size]
      @status = nil
    end

    # The currently-selected theme name (for live preview as the user cycles) — only
    # meaningful in the :theme section.
    def theme_value : String?
      @section == :theme ? @values[0] : nil
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
        Settings.mouse = @values[2] == "on"
        Settings.pretty_bodies_default = @values[3] == "on"
        @values = [Settings.editor, Settings.editor_markdown ? "on" : "off", Settings.mouse ? "on" : "off", Settings.pretty_bodies_default ? "on" : "off"]
        return persist
      end
      port = @values[1].strip.to_i?
      unless port && 0 <= port <= 65535
        @status = "invalid port"
        return "settings: invalid bind port #{@values[1].inspect}"
      end
      up = @values[2].strip
      if err = upstream_port_error(up)
        @status = "invalid upstream port"
        return err
      end
      Settings.bind_host = @values[0].strip
      Settings.bind_port = port
      Settings.upstream_proxy = up
      @values = [Settings.bind_host, Settings.bind_port.to_s, Settings.upstream_proxy]
      persist
    end

    # nil if the upstream-proxy string is acceptable; an error message if its explicit
    # port segment isn't a valid 0-65535 int — so a typo ("proxy:8O80") is caught at
    # save time instead of silently resolving to 8080 (Settings.upstream_proxy_addr)
    # and failing every captured flow later, far from the mistake.
    private def upstream_port_error(value : String) : String?
      return nil if value.empty?
      bare = value.sub(/\Ahttps?:\/\//, "").rstrip('/')
      i = bare.rindex(':')
      return nil unless i && i < bare.size - 1 # no explicit port → defaults are fine
      seg = bare[(i + 1)..]
      p = seg.to_i?
      (p && 0 <= p <= 65535) ? nil : "settings: invalid upstream proxy port #{seg.inspect}"
    end

    private def persist : String
      ok = Settings.save
      @saved = ok
      @status = ok ? "saved" : "save failed"
      ok ? "settings saved" : "settings: save failed (could not write #{Settings.path})"
    end

    # The centred settings box for `area` — the exact Rect render draws into (so
    # hit-tests can be mapped against the same geometry render uses). The interior
    # holds `content_rows` rows (fields, or the THEME list viewport) plus 6 rows of
    # chrome (borders + a pad + the footer note block).
    def overlay_box(area : Rect) : Rect
      w = {area.w - 4, 64}.min
      h = content_rows(area) + 6
      # Empty when render would decline to draw (same guard as render below): a click
      # then falls through to !contains? and closes instead of focusing a field on an
      # undrawn card.
      return Rect.new(area.x, area.y, 0, 0) if w < 30 || area.h < h
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    # Interior content rows for `area`: one per field, or — in the THEME section — the
    # theme-list viewport (the list size, capped to THEME_LIST_MAX and to what the
    # terminal can fit, so a long list scrolls instead of demanding the whole screen).
    private def content_rows(area : Rect) : Int32
      return fields.size unless @section == :theme
      fit = {area.h - 6, 1}.max
      {Theme.available.size, THEME_LIST_MAX, fit}.min
    end

    # The row-index under (mx,my) within `box`, mirroring render's row loop. For fields
    # it's the field index; for the THEME list it's the absolute theme index (offset by
    # the scroll). nil outside the content rows or the box.
    def field_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      row = my - (box.y + 2)
      if @section == :theme
        vp = {box.h - 6, 1}.max
        return nil if row < 0 || row >= vp
        i = @theme_scroll + row
        return i < Theme.available.size ? i : nil
      end
      (0 <= row < fields.size) ? row : nil
    end

    # Act on a clicked row: focus a field, or — in the THEME section — select that
    # theme (the caller live-previews it). Index is clamped to the valid range.
    def set_field(idx : Int32) : Nil
      if @section == :theme
        names = Theme.available
        @values[0] = names[idx.clamp(0, names.size - 1)] unless names.empty?
        return
      end
      @focused = idx.clamp(0, @values.size - 1)
      @cursor = @values[@focused].size
      @preedit = ""
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      return if box.w < 30 || area.h < box.h
      Frame.card(screen, box, "SETTINGS · #{@section.to_s.upcase}", border: Theme.border_focus)
      if @section == :theme
        render_theme_list(screen, box)
      else
        render_fields(screen, box)
      end
      render_footer(screen, box)
    end

    private def render_fields(screen : Screen, box : Rect) : Nil
      flds = fields
      w = box.w
      label_w = flds.max_of(&.label.size)
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
        render_field_value(screen, field, @values[i], vx, ry, vw, focused, bg)
      end
    end

    # The value column of one field: a choice cycle, a bool toggle, the editable line
    # (focused), the hint (empty + unfocused), or the plain value.
    private def render_field_value(screen : Screen, field : Field, value : String,
                                   vx : Int32, ry : Int32, vw : Int32, focused : Bool, bg : Color) : Nil
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

    # The THEME section: a vertical, scrollable list of theme names (built-ins + user
    # themes), each with a swatch previewing its own palette. The selected row is
    # kept on screen by following it within the viewport.
    private def render_theme_list(screen : Screen, box : Rect) : Nil
      names = Theme.available
      return if names.empty?
      sel = names.index(@values[0]) || 0
      vp = {box.h - 6, 1}.max # interior list rows (box.h == vp + 6 — see overlay_box)
      # Scroll-follow: clamp to a valid window, then nudge to keep `sel` visible.
      @theme_scroll = @theme_scroll.clamp(0, {names.size - vp, 0}.max)
      @theme_scroll = sel if sel < @theme_scroll
      @theme_scroll = sel - vp + 1 if sel >= @theme_scroll + vp

      list_top = box.y + 2
      vp.times do |row|
        i = @theme_scroll + row
        break if i >= names.size
        draw_theme_row(screen, box, names[i], i == sel, list_top + row,
          up: row == 0 && @theme_scroll > 0,
          down: row == vp - 1 && i < names.size - 1)
      end
    end

    private def draw_theme_row(screen : Screen, box : Rect, name : String, selected : Bool, ry : Int32, *, up : Bool, down : Bool) : Nil
      bg = selected ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, selected ? '▎' : ' ', Theme.accent, bg)
      screen.cell(box.x + 3, ry, selected ? '◉' : '◯', selected ? Theme.accent : Theme.muted, bg)
      # Right edge, inside the card border (box.right-1): a scroll marker on the last
      # interior column (box.right-2), then the swatch left of it with a 1-col gap.
      mark_x = box.right - 2
      swatch_w = 7
      sx = mark_x - 1 - swatch_w
      name_w = {sx - (box.x + 5) - 1, 1}.max
      screen.text(box.x + 5, ry, name, selected ? Theme.text_bright : Theme.text, bg, width: name_w)
      draw_swatch(screen, sx, ry, name)
      # Scroll marker (one glyph): ↕ when this lone row can scroll both ways (a 1-row
      # viewport on a tiny terminal), else ▲ for more-above / ▼ for more-below.
      if up && down
        screen.cell(mark_x, ry, '↕', Theme.muted, bg)
      elsif up
        screen.cell(mark_x, ry, '▲', Theme.muted, bg)
      elsif down
        screen.cell(mark_x, ry, '▼', Theme.muted, bg)
      end
    end

    # A tiny preview strip in the theme's OWN palette (not the active one): its canvas
    # colour framing a few accent ticks, so each row previews the theme without making
    # it active. Width must match `swatch_w` in draw_theme_row (1 + 5 ticks + 1).
    private def draw_swatch(screen : Screen, x : Int32, ry : Int32, name : String) : Nil
      pal = Theme.palette(name)
      return unless pal
      ticks = {pal.accent, pal.green, pal.yellow, pal.red, pal.syn_header}
      screen.cell(x, ry, ' ', pal.bg, pal.bg)
      ticks.each_with_index { |c, i| screen.cell(x + 1 + i, ry, '█', c, pal.bg) }
      screen.cell(x + 6, ry, ' ', pal.bg, pal.bg)
    end

    private def render_footer(screen : Screen, box : Rect) : Nil
      note_y = box.bottom - 2
      if status = @status
        color = status.starts_with?("invalid") || status.starts_with?("save failed") ? Theme.yellow : Theme.green
        screen.text(box.x + 3, note_y, "• #{status}", color, Theme.panel)
      elsif @section == :theme
        names = Theme.available
        screen.text(box.x + 3, note_y, "theme #{(names.index(@values[0]) || 0) + 1}/#{names.size}", Theme.muted, Theme.panel)
      else
        screen.text(box.x + 3, note_y, fields[@focused].hint, Theme.muted, Theme.panel)
      end
      hint = @section == :theme ? "↑/↓ select · ↵ apply · ^R reset · esc close" : "↑/↓ field · ↵ save · ^R reset · esc close"
      screen.text(box.right - hint.size - 2, note_y, hint, Theme.muted, Theme.panel)
    end
  end
end
