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
    # `choices` cycles among those values (←/→/space); an `opener` field is an action row
    # whose ↵ opens the named sub-overlay (e.g. :hosts) and whose value column is
    # display-only; the rest are free-text lines.
    record Field, label : String, hint : String, bool : Bool = false, choices : Array(String)? = nil, opener : Symbol? = nil

    NETWORK_FIELDS = [
      Field.new("Bind IP", "global default listen address — projects may pin their own"),
      Field.new("Bind Port", "global default port (0-65535) — project overrides win when set"),
      Field.new("Upstream proxy", "host:port — blank = connect directly; projects may override"),
      Field.new("Verify upstream TLS", "check the upstream server's certificate — off accepts any cert (MITM/testing); ←/→/space toggles", bool: true),
      Field.new("Info page on direct access", "serve a gori welcome + CA-download page to browsers that hit the listen address directly — ←/→/space toggles", bool: true),
      Field.new("Connect timeout (s)", "how long an upstream TCP/proxy connect may take before giving up — seconds (min 1)"),
      Field.new("Idle timeout (s)", "initial read/write timeout on the upstream socket — seconds (min 1)"),
      Field.new("Capture body limit (MiB)", "max body bytes captured + stored per flow — MiB (min 1); applies to NEW flows only"),
      Field.new("Hostname overrides", "↵ to edit the global IP→host map (a /etc/hosts for this proxy)", opener: :hosts),
    ]
    EDITOR_FIELDS = [
      Field.new("External editor", "e.g. vim · code --wait — blank = $VISUAL/$EDITOR/vi"),
      Field.new("Markdown highlight", "syntax-colour markdown in Notes/Project — ←/→/space toggles", bool: true),
      Field.new("Mouse", "click + scroll-wheel navigation (off restores native text selection)", bool: true),
      Field.new("Pretty-print bodies", "reflow JSON/XML/form/… in History detail + Repeater response — display only; ←/→/space toggles", bool: true),
    ]
    # The THEME section is special: a single field whose value is the selected theme
    # name, but rendered as a vertical, scrollable list (built-ins + user themes) rather
    # than the inline ←/→ cycle the other `choices` fields use. `choices` is kept only so
    # `choice_field?` swallows typing; the live list comes from Theme.available.
    THEME_FIELDS = [
      Field.new("Theme", "TUI colour theme — ↑/↓ select, ↵ applies", choices: Theme.available),
    ]
    # Layout: vertical list of per-area prefs (extend by appending fields + Settings keys).
    LAYOUT_DEPTH_CHOICES = ["all", "0", "1", "2", "3"]
    LAYOUT_ORDER_CHOICES = ["newest first", "oldest first"]
    LAYOUT_FIELDS        = [
      Field.new("History Req/Res preview",
        "list page: bottom pane shows selected flow request + response — ←/→/space toggles",
        bool: true),
      Field.new("Probe issue preview",
        "list page: bottom pane shows selected issue summary — ←/→/space toggles",
        bool: true),
      Field.new("Issues preview",
        "list page: bottom pane shows selected issue summary — ←/→/space toggles",
        bool: true),
      Field.new("History list order",
        "newest first (default, live tail at top) or oldest first — ←/→ cycles",
        choices: LAYOUT_ORDER_CHOICES),
      Field.new("Sitemap expand depth",
        "how deep the tree opens after reload — ←/→ cycles (all = fully expanded)",
        choices: LAYOUT_DEPTH_CHOICES),
    ]
    # Statusline: an opt-in bottom row that runs a command and shows its output.
    STATUSLINE_FIELDS = [
      Field.new("Statusline",
        "run a command and show its output at the very bottom — ←/→/space toggles",
        bool: true),
      Field.new("Command",
        "shell command (/bin/sh -c) — receives a JSON context (project, capture, flows, proxy) on stdin"),
      Field.new("Interval (s)",
        "how often to re-run the command — seconds (min 1)"),
    ]
    # Display: message-body rendering prefs (two choice fields + a bool + a text cap).
    DISPLAY_PANE_CHOICES = ["request", "response"]
    DISPLAY_TIME_CHOICES = ["absolute", "relative"]
    DISPLAY_FIELDS       = [
      Field.new("Default detail pane",
        "which pane a freshly-opened History flow shows first — ←/→ cycles",
        choices: DISPLAY_PANE_CHOICES),
      Field.new("History list time",
        "list time column: absolute (MM-DD HH:MM:SS) or relative (3s/5m/2h) — ←/→ cycles",
        choices: DISPLAY_TIME_CHOICES),
      Field.new("Line numbers",
        "show the line-number gutter on the message body views — ←/→/space toggles",
        bool: true),
      Field.new("Preview body limit (KiB)",
        "how many body bytes the History list preview reads/shows — KiB (min 1)"),
    ]
    # Notifications: bell/toast toggles + ring-buffer retention.
    NOTIFICATIONS_FIELDS = [
      Field.new("Bell on result",
        "ring the terminal bell on a background result/alert (miner/fuzzer/probe/discover) — ←/→/space toggles",
        bool: true),
      Field.new("Toast on result",
        "also flash a bottom-bar toast for fuzzer/probe/discover results — ←/→/space toggles",
        bool: true),
      Field.new("Retention (count)",
        "how many notifications the ring buffer keeps — count (min 1)"),
    ]
    # General: clipboard + quit-confirm toggles.
    GENERAL_FIELDS = [
      Field.new("Clipboard (OSC 52)",
        "copy to the system clipboard via the OSC 52 terminal escape — off makes copies no-op — ←/→/space toggles",
        bool: true),
      Field.new("Confirm before quit",
        "require a confirm modal to quit (instead of double-press ^D) — ←/→/space toggles",
        bool: true),
    ]
    SECTIONS = {
      :network       => NETWORK_FIELDS,
      :editor        => EDITOR_FIELDS,
      :theme         => THEME_FIELDS,
      :layout        => LAYOUT_FIELDS,
      :statusline    => STATUSLINE_FIELDS,
      :display       => DISPLAY_FIELDS,
      :notifications => NOTIFICATIONS_FIELDS,
      :general       => GENERAL_FIELDS,
    }

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
                when :editor        then [Settings.editor, Settings.editor_markdown ? "on" : "off", Settings.mouse ? "on" : "off", Settings.pretty_bodies_default ? "on" : "off"]
                when :theme         then [Theme.canonical(Settings.theme)]
                when :layout        then layout_values
                when :statusline    then [Settings.statusline_enabled? ? "on" : "off", Settings.statusline_command, Settings.statusline_interval.to_s]
                when :display       then [Settings.default_detail_pane, Settings.history_time_format, Settings.show_gutter ? "on" : "off", Settings.preview_body_kib.to_s]
                when :notifications then [Settings.notify_bell? ? "on" : "off", Settings.notify_toast? ? "on" : "off", Settings.notify_retention.to_s]
                when :general       then [Settings.clipboard_osc52? ? "on" : "off", Settings.confirm_quit? ? "on" : "off"]
                else                     [Settings.bind_host, Settings.bind_port.to_s, Settings.upstream_proxy, Settings.verify_upstream? ? "on" : "off", Settings.serve_landing? ? "on" : "off", Settings.connect_timeout_secs.to_s, Settings.io_timeout_secs.to_s, Settings.capture_max_mib.to_s, hostnames_summary]
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
                when :layout then [
                  Settings::DEFAULT_HISTORY_PREVIEW ? "on" : "off",
                  Settings::DEFAULT_PROBE_PREVIEW ? "on" : "off",
                  Settings::DEFAULT_ISSUES_PREVIEW ? "on" : "off",
                  order_label(Settings::DEFAULT_HISTORY_LIST_ORDER),
                  depth_label(Settings::DEFAULT_SITEMAP_EXPAND_DEPTH),
                ]
                when :statusline then [
                  Settings::DEFAULT_STATUSLINE_ENABLED ? "on" : "off",
                  Settings::DEFAULT_STATUSLINE_COMMAND,
                  Settings::DEFAULT_STATUSLINE_INTERVAL.to_s,
                ]
                when :display then [
                  Settings::DEFAULT_DETAIL_PANE,
                  Settings::DEFAULT_HISTORY_TIME_FORMAT,
                  Settings::DEFAULT_SHOW_GUTTER ? "on" : "off",
                  Settings::DEFAULT_PREVIEW_BODY_KIB.to_s,
                ]
                when :notifications then [
                  Settings::DEFAULT_NOTIFY_BELL ? "on" : "off",
                  Settings::DEFAULT_NOTIFY_TOAST ? "on" : "off",
                  Settings::DEFAULT_NOTIFY_RETENTION.to_s,
                ]
                when :general then [
                  Settings::DEFAULT_CLIPBOARD_OSC52 ? "on" : "off",
                  Settings::DEFAULT_CONFIRM_QUIT ? "on" : "off",
                ]
                else [Settings::DEFAULT_BIND_HOST, Settings::DEFAULT_BIND_PORT.to_s, Settings::DEFAULT_UPSTREAM_PROXY, Settings::DEFAULT_VERIFY_UPSTREAM ? "on" : "off", Settings::DEFAULT_SERVE_LANDING ? "on" : "off", Settings::DEFAULT_CONNECT_TIMEOUT_SECS.to_s, Settings::DEFAULT_IO_TIMEOUT_SECS.to_s, Settings::DEFAULT_CAPTURE_MAX_MIB.to_s, hostnames_summary]
                end
      @focused = 0
      @cursor = @values[0].size
      @preedit = ""
      @status = nil
    end

    private def layout_values : Array(String)
      [
        Settings.history_preview ? "on" : "off",
        Settings.probe_preview ? "on" : "off",
        Settings.issues_preview ? "on" : "off",
        order_label(Settings.history_list_order),
        depth_label(Settings.sitemap_expand_depth),
      ]
    end

    private def depth_label(d : Int32) : String
      d < 0 ? "all" : d.to_s
    end

    private def depth_from_label(s : String) : Int32
      s == "all" ? -1 : (s.to_i? || Settings::DEFAULT_SITEMAP_EXPAND_DEPTH)
    end

    private def order_label(order : String) : String
      order == "oldest" ? "oldest first" : "newest first"
    end

    private def order_from_label(s : String) : String
      s.starts_with?("oldest") ? "oldest" : "newest"
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
      return if opener_field? # an action row — typing does nothing (↵ opens its overlay)
      if bool_field?          # a toggle field swallows typing; space flips it
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
      return if bool_field? || choice_field? || opener_field? || @cursor == 0
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

    private def opener_field? : Bool
      !fields[@focused].opener.nil?
    end

    # The sub-overlay the focused action row opens (↵), or nil for an ordinary field. The
    # Runner consults this on ↵ to open the editor (e.g. :hosts) instead of saving.
    def focused_opener : Symbol?
      fields[@focused].opener
    end

    # The display value for the "Hostname overrides" action row — a live count + an ↵ cue.
    private def hostnames_summary : String
      n = Settings.hostname_overrides.size
      n == 0 ? "none — ↵ to add" : "#{n} entr#{n == 1 ? "y" : "ies"} — ↵ to edit"
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
      if @section == :layout
        Settings.history_preview = @values[0] == "on"
        Settings.probe_preview = @values[1] == "on"
        Settings.issues_preview = @values[2] == "on"
        Settings.history_list_order = Settings.normalize_history_list_order(order_from_label(@values[3]))
        Settings.sitemap_expand_depth = Settings.normalize_sitemap_depth(depth_from_label(@values[4]))
        @values = layout_values
        return persist
      end
      if @section == :statusline
        iv = @values[2].strip.to_i?
        unless iv && iv >= 1
          @status = "invalid interval"
          return "settings: invalid statusline interval #{@values[2].inspect} (seconds, min 1)"
        end
        Settings.statusline_enabled = @values[0] == "on"
        Settings.statusline_command = @values[1] # blank is valid (no-op while enabled)
        Settings.statusline_interval = iv
        @values = [Settings.statusline_enabled? ? "on" : "off", Settings.statusline_command, iv.to_s]
        return persist
      end
      if @section == :display
        kib = @values[3].strip.to_i?
        unless kib && kib >= 1
          @status = "invalid preview limit"
          return "settings: invalid preview body limit #{@values[3].inspect} (KiB, min 1)"
        end
        kib = kib.clamp(1, Settings::MAX_PREVIEW_BODY_KIB) # keep kib*1024 within Int32
        Settings.default_detail_pane = @values[0] == "response" ? "response" : "request"
        Settings.history_time_format = @values[1] == "relative" ? "relative" : "absolute"
        Settings.show_gutter = @values[2] == "on"
        Settings.preview_body_kib = kib
        @values = [Settings.default_detail_pane, Settings.history_time_format, Settings.show_gutter ? "on" : "off", Settings.preview_body_kib.to_s]
        return persist
      end
      if @section == :notifications
        ret = @values[2].strip.to_i?
        unless ret && ret >= 1
          @status = "invalid retention"
          return "settings: invalid notification retention #{@values[2].inspect} (count, min 1)"
        end
        Settings.notify_bell = @values[0] == "on"
        Settings.notify_toast = @values[1] == "on"
        Settings.notify_retention = ret
        @values = [Settings.notify_bell? ? "on" : "off", Settings.notify_toast? ? "on" : "off", ret.to_s]
        return persist
      end
      if @section == :general
        Settings.clipboard_osc52 = @values[0] == "on"
        Settings.confirm_quit = @values[1] == "on"
        @values = [Settings.clipboard_osc52? ? "on" : "off", Settings.confirm_quit? ? "on" : "off"]
        return persist
      end
      port = @values[1].strip.to_i?
      unless port && 0 <= port <= 65535
        @status = "invalid port"
        return "settings: invalid bind port #{@values[1].inspect}"
      end
      up = @values[2].strip
      if err = Settings.upstream_proxy_port_error(up)
        @status = "invalid upstream port"
        return err
      end
      ct = @values[5].strip.to_i?
      unless ct && ct >= 1
        @status = "invalid connect timeout"
        return "settings: invalid connect timeout #{@values[5].inspect} (seconds, min 1)"
      end
      it = @values[6].strip.to_i?
      unless it && it >= 1
        @status = "invalid idle timeout"
        return "settings: invalid idle timeout #{@values[6].inspect} (seconds, min 1)"
      end
      cap = @values[7].strip.to_i?
      unless cap && cap >= 1
        @status = "invalid capture limit"
        return "settings: invalid capture limit #{@values[7].inspect} (MiB, min 1)"
      end
      cap = cap.clamp(1, Settings::MAX_CAPTURE_MAX_MIB) # keep cap*1024*1024 within Int32 (never break the proxy)
      Settings.bind_host = @values[0].strip
      Settings.bind_port = port
      Settings.upstream_proxy = up
      Settings.verify_upstream = @values[3] == "on"
      Settings.serve_landing = @values[4] == "on"
      Settings.connect_timeout_secs = ct
      Settings.io_timeout_secs = it
      Settings.capture_max_mib = cap
      @values = [Settings.bind_host, Settings.bind_port.to_s, Settings.upstream_proxy, Settings.verify_upstream? ? "on" : "off", Settings.serve_landing? ? "on" : "off", Settings.connect_timeout_secs.to_s, Settings.io_timeout_secs.to_s, Settings.capture_max_mib.to_s, hostnames_summary]
      persist
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
      if field.opener # an action row: show its summary (display-only), accent to signal ↵ opens it
        screen.text(vx, ry, value, focused ? Theme.text_bright : Theme.accent, bg, width: vw)
      elsif choices = field.choices
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
      iw = {box.right - (box.x + 3) - 1, 0}.max # interior width so long hints can't bleed past the box border
      if status = @status
        color = status.starts_with?("invalid") || status.starts_with?("save failed") ? Theme.yellow : Theme.green
        screen.text(box.x + 3, note_y, "• #{status}", color, Theme.panel, width: iw)
      elsif @section == :theme
        names = Theme.available
        screen.text(box.x + 3, note_y, "theme #{(names.index(@values[0]) || 0) + 1}/#{names.size}", Theme.muted, Theme.panel, width: iw)
      else
        screen.text(box.x + 3, note_y, fields[@focused].hint, Theme.muted, Theme.panel, width: iw)
      end
      hint = @section == :theme ? "↑/↓ select · ↵ apply · ^R reset · esc close" : "↑/↓ field · ↵ save · ^R reset · esc close"
      hx = {box.right - hint.size - 2, box.x + 1}.max # never start left of the box interior
      screen.text(hx, note_y, hint, Theme.muted, Theme.panel, width: {box.right - hx - 1, 0}.max)
    end
  end
end
