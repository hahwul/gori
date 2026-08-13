require "./screen"
require "./theme"
require "./frame"
require "./overlay"
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
    # `readonly` is a DISPLAY row: it shows a live summary of something configured elsewhere and
    # swallows every edit. It exists so a table that lives only in settings.json is still
    # discoverable from the UI, without pretending to be editable here.
    record Field, label : String, hint : String, bool : Bool = false, choices : Array(String)? = nil,
      opener : Symbol? = nil, readonly : Bool = false

    NETWORK_FIELDS = [
      Field.new("Bind IP", "global default listen address — projects may pin their own"),
      Field.new("Bind Port", "global default port (0-65535) — project overrides win when set"),
      Field.new("Upstream proxy", "host:port — blank = connect directly; projects may override"),
      Field.new("Verify upstream TLS", "check the upstream server's certificate — off accepts any cert (MITM/testing); ←/→/space toggles", bool: true),
      Field.new("Info page and CA download", "serve a gori welcome + CA-download page to browsers that hit the listen address, or http://gori.proxy/ when already proxied — ←/→/space toggles", bool: true),
      Field.new("Connect timeout (s)", "how long an upstream TCP/proxy connect may take before giving up — seconds (min 1)"),
      Field.new("Idle timeout (s)", "initial read/write timeout on the upstream socket — seconds (min 1)"),
      Field.new("Capture body limit (MiB)", "max body bytes captured + stored per flow — MiB (min 1); applies to NEW flows only"),
      Field.new("HTTP/2", "auto follows the origin's ALPN; off forces HTTP/1.1 on every tunnelled connection (for reproducing a finding on h1) — ←/→ cycles",
        choices: Settings::HTTP2_MODES),
      Field.new("TLS passthrough", "comma-separated hosts to relay WITHOUT decrypting (for certificate-pinned apps) — acme.test covers subdomains, *.acme.test globs; nothing is captured for them"),
      Field.new("Upstream rules",
        "per-host routing / SOCKS5 / proxy auth — edit with `gori settings --edit` (network.upstream_rules)",
        readonly: true),
      Field.new("Outbound TLS",
        "per-host client certificates + protocol range — edit with `gori settings --edit` (outbound_tls)",
        readonly: true),
      Field.new("Hostname overrides", "↵ to edit the global IP→host map (a /etc/hosts for this proxy)", opener: :hosts),
    ]
    # Command-modifier labels. The stored values are "ctrl"/"alt" (Settings.command_modifier);
    # these are what the row shows — see #modifier_label / #modifier_from_label.
    COMMAND_MODIFIER_CHOICES = ["Ctrl", "Option (⌥)"]

    EDITOR_FIELDS = [
      Field.new("External editor", "e.g. vim · code --wait — blank = $VISUAL/$EDITOR/vi"),
      Field.new("Markdown highlight", "syntax-colour markdown in Notes/Project — ←/→/space toggles", bool: true),
      Field.new("Mouse", "click + scroll-wheel navigation (off restores native text selection)", bool: true),
      Field.new("Pretty-print bodies", "reflow JSON/XML/form/… in History detail + Repeater response — display only; ←/→/space toggles", bool: true),
    ]
    # KEYS is its own section rather than a row in EDITOR: it configures key INPUT, not text
    # editing. It sits between Editor and Hotkeys in the same group, so "which modifier" and
    # "which binding" read as the pair they are.
    KEYS_FIELDS = [
      Field.new("Command modifier", "which modifier fronts gori's built-in shortcuts (^P ^N ^W ^G ^F ^B ^E ^, ^1-9) — Option ADDS ⌥ as an alias, Ctrl keeps working; for terminals/multiplexers that swallow the Ctrl form (tmux's ^B, Ctrl+digit). macOS Terminal/iTerm must be set to send Option as Meta. ←/→ cycles",
        choices: COMMAND_MODIFIER_CHOICES),
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
    # Display: message-body + chrome prefs (three choice fields, three bools, a text cap).
    DISPLAY_PANE_CHOICES = ["request", "response"]
    DISPLAY_TIME_CHOICES = ["absolute", "relative"]
    # Kept short: all three render inline on one row inside the settings box.
    DISPLAY_TITLE_CHOICES = ["project + tab", "tab", "off"]
    DISPLAY_FIELDS        = [
      Field.new("Default detail pane",
        "which pane a freshly-opened History flow shows first — ←/→ cycles",
        choices: DISPLAY_PANE_CHOICES),
      Field.new("History list time",
        "list time column: absolute (MM-DD HH:MM:SS) or relative (3s/5m/2h) — ←/→ cycles",
        choices: DISPLAY_TIME_CHOICES),
      Field.new("Line numbers",
        "show the line-number gutter on the message body views — ←/→/space toggles",
        bool: true),
      Field.new("Wrap long lines",
        "a line too wide for a message pane spills onto continuation rows (the gutter numbers the first) — off scrolls it sideways instead, following the caret — ←/→/space toggles",
        bool: true),
      Field.new("Preview body limit (KiB)",
        "how many body bytes the History list preview reads/shows — KiB (min 1)"),
      Field.new("Resource meter",
        "show gori's own CPU/memory at the far right of the bottom bar — ←/→/space toggles",
        bool: true),
      Field.new("Terminal title",
        "what gori writes into the terminal window title — off leaves it to your shell/tmux — ←/→ cycles",
        choices: DISPLAY_TITLE_CHOICES),
    ]
    # Companion: Miss Ring, the mascot in the body's bottom-right corner.
    COMPANION_MOTION_CHOICES    = ["lively", "calm"]
    COMPANION_PLACEMENT_CHOICES = ["body", "bar"]
    COMPANION_FIELDS            = [
      Field.new("Companion (Miss Ring)",
        "show the mascot in the body's bottom-right corner — she covers three rows and repaints about once a second while you're at the keyboard — ←/→/space toggles",
        bool: true),
      Field.new("Placement",
        "body = an 8x3 sprite in the tab body's bottom-right corner; bar = a one-row chip in the status row beside CPU/MEM, which covers nothing and drops the speech bubble — ←/→ cycles",
        choices: COMPANION_PLACEMENT_CHOICES),
      Field.new("Motion",
        "lively = blinks, winks, a glint sweep and the odd yawn or smile; calm halves the blink rate and drops the rest (SSH/battery) — ←/→ cycles",
        choices: COMPANION_MOTION_CHOICES),
      Field.new("Notices",
        "announce new background results in a speech bubble, and react to them — independent of the bottom-bar toast — ←/→/space toggles",
        bool: true),
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
    # General: clipboard + quit-confirm + update-check toggles.
    GENERAL_FIELDS = [
      Field.new("Clipboard (OSC 52)",
        "copy to the system clipboard via the OSC 52 terminal escape — off makes copies no-op — ←/→/space toggles",
        bool: true),
      Field.new("Confirm before quit",
        "require a confirm modal to quit (instead of double-press ^D) — ←/→/space toggles",
        bool: true),
      Field.new("Update check",
        "on startup, check GitHub for a newer release and show a one-line notice on the project picker — off = no outbound check; ←/→/space toggles",
        bool: true),
      Field.new("History retention (flows)",
        "how many newest flows a project keeps before the oldest are dropped — 0 = unlimited; applies on the next project open"),
    ]
    SECTIONS = {
      :network       => NETWORK_FIELDS,
      :editor        => EDITOR_FIELDS,
      :keys          => KEYS_FIELDS,
      :theme         => THEME_FIELDS,
      :layout        => LAYOUT_FIELDS,
      :statusline    => STATUSLINE_FIELDS,
      :display       => DISPLAY_FIELDS,
      :companion     => COMPANION_FIELDS,
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
      @baseline = [] of String # last persisted/loaded values — @values != @baseline means unsaved
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
                when :editor        then editor_values
                when :keys          then keys_values
                when :theme         then [Theme.canonical(Settings.theme)]
                when :layout        then layout_values
                when :statusline    then [Settings.statusline_enabled? ? "on" : "off", Settings.statusline_command, Settings.statusline_interval.to_s]
                when :display       then display_values
                when :companion     then companion_values
                when :notifications then [Settings.notify_bell? ? "on" : "off", Settings.notify_toast? ? "on" : "off", Settings.notify_retention.to_s]
                when :general       then general_values
                else                     network_values
                end
      @focused = 0
      @cursor = @values[0].size
      @preedit = ""
      @status = nil
      @saved = false
      @baseline = @values.dup
      @theme_scroll = 0 # render scrolls to the selected theme on the first frame
    end

    # True when the working copy differs from what was last loaded/persisted. The
    # Preferences modal stacks several sections but ↵ saves only the focused one, so it
    # needs this to flag an edited-but-unsaved section instead of dropping it on esc.
    def dirty? : Bool
      @values != @baseline
    end

    # Revert the working copy of the CURRENT section to its factory defaults (the values a
    # fresh install ships with — Settings::DEFAULT_*). Like every other edit here it touches
    # the working copy only: it applies on save (↵) and is discarded on esc. The caller
    # live-previews the restored default theme in the :theme section.
    def reset_to_defaults : Nil
      @values = case @section
                when :editor then [
                  Settings::DEFAULT_EDITOR,
                  Settings::DEFAULT_EDITOR_MARKDOWN ? "on" : "off",
                  Settings::DEFAULT_MOUSE ? "on" : "off",
                  Settings::DEFAULT_PRETTY_BODIES ? "on" : "off",
                ]
                when :keys  then [modifier_label(Settings::DEFAULT_COMMAND_MODIFIER)]
                when :theme then [Theme.canonical(Settings::DEFAULT_THEME)]
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
                  Settings::DEFAULT_WRAP_LINES ? "on" : "off",
                  Settings::DEFAULT_PREVIEW_BODY_KIB.to_s,
                  Settings::DEFAULT_RESOURCE_METER ? "on" : "off",
                  title_label(Settings::DEFAULT_TERMINAL_TITLE),
                ]
                when :companion then [
                  Settings::DEFAULT_COMPANION ? "on" : "off",
                  Settings::DEFAULT_COMPANION_PLACEMENT,
                  Settings::DEFAULT_COMPANION_MOTION,
                  Settings::DEFAULT_COMPANION_NOTICES ? "on" : "off",
                ]
                when :notifications then [
                  Settings::DEFAULT_NOTIFY_BELL ? "on" : "off",
                  Settings::DEFAULT_NOTIFY_TOAST ? "on" : "off",
                  Settings::DEFAULT_NOTIFY_RETENTION.to_s,
                ]
                when :general then [
                  Settings::DEFAULT_CLIPBOARD_OSC52 ? "on" : "off",
                  Settings::DEFAULT_CONFIRM_QUIT ? "on" : "off",
                  Settings::DEFAULT_UPDATE_CHECK_ENABLED ? "on" : "off",
                  Settings::DEFAULT_RETENTION_FLOWS.to_s,
                ]
                else [Settings::DEFAULT_BIND_HOST, Settings::DEFAULT_BIND_PORT.to_s, Settings::DEFAULT_UPSTREAM_PROXY, Settings::DEFAULT_VERIFY_UPSTREAM ? "on" : "off", Settings::DEFAULT_SERVE_LANDING ? "on" : "off", Settings::DEFAULT_CONNECT_TIMEOUT_SECS.to_s, Settings::DEFAULT_IO_TIMEOUT_SECS.to_s, Settings::DEFAULT_CAPTURE_MAX_MIB.to_s, Settings::DEFAULT_HTTP2, passthrough_label(Settings::DEFAULT_TLS_PASSTHROUGH), rule_count_label(Settings.upstream_rules.size, "rule"), rule_count_label(Settings.outbound_tls.size, "entry", "entries"), hostnames_summary]
                end
      @focused = 0
      @cursor = @values[0].size
      @preedit = ""
      @status = nil
    end

    # The NETWORK row values, read from the live Settings. One helper for both the load
    # (`reload`) and the post-save rebuild (`commit`) so the two can't drift out of step with
    # NETWORK_FIELDS — the values are positional, so an inserted field would otherwise have to
    # be mirrored in three separate literals.
    private def network_values : Array(String)
      [
        Settings.bind_host,
        Settings.bind_port.to_s,
        Settings.upstream_proxy,
        Settings.verify_upstream? ? "on" : "off",
        Settings.serve_landing? ? "on" : "off",
        Settings.connect_timeout_secs.to_s,
        Settings.io_timeout_secs.to_s,
        Settings.capture_max_mib.to_s,
        Settings.http2,
        passthrough_label(Settings.tls_passthrough),
        rule_count_label(Settings.upstream_rules.size, "rule"),
        rule_count_label(Settings.outbound_tls.size, "entry", "entries"),
        hostnames_summary,
      ]
    end

    # The EDITOR row values, read from the live Settings — same reason as #network_values:
    # the values are positional, so a literal per call site drifts from EDITOR_FIELDS the
    # moment a row is inserted or removed.
    private def editor_values : Array(String)
      [
        Settings.editor,
        Settings.editor_markdown ? "on" : "off",
        Settings.mouse ? "on" : "off",
        Settings.pretty_bodies_default ? "on" : "off",
      ]
    end

    # The KEYS row values (one row today — the command modifier).
    private def keys_values : Array(String)
      [modifier_label(Settings.command_modifier)]
    end

    # "ctrl"/"alt" ↔ the row's display labels (unknown → the Ctrl default, matching
    # Settings.normalize_command_modifier).
    private def modifier_label(value : String) : String
      value == "alt" ? COMMAND_MODIFIER_CHOICES[1] : COMMAND_MODIFIER_CHOICES[0]
    end

    private def modifier_from_label(label : String) : String
      label == COMMAND_MODIFIER_CHOICES[1] ? "alt" : "ctrl"
    end

    # The GENERAL row values, read from the live Settings — one helper for the load and the
    # post-save rebuild, so the positional values can't drift from GENERAL_FIELDS.
    private def general_values : Array(String)
      [
        Settings.clipboard_osc52? ? "on" : "off",
        Settings.confirm_quit? ? "on" : "off",
        Settings.update_check_enabled? ? "on" : "off",
        Settings.retention_max_flows.to_s,
      ]
    end

    # The passthrough list as one editable line, and back. Comma-separated rather than a
    # dedicated list overlay: these are a handful of host patterns, and a text field keeps the
    # whole Network section inline (the overlay is reserved for the hostname map, which has two
    # columns per entry). ", " on the way out reads better; parsing accepts commas or spaces.
    # "none — see settings.json" / "2 rules". A display row for a table gori does not yet edit
    # in the TUI: the count is what tells you it is there at all.
    private def rule_count_label(n : Int32, one : String, many : String = "") : String
      return "none — configured in settings.json" if n == 0
      "#{n} #{n == 1 ? one : (many.presence || "#{one}s")}"
    end

    private def passthrough_label(patterns : Array(String)) : String
      patterns.join(", ")
    end

    private def passthrough_from_label(value : String) : Array(String)
      value.split(/[,\s]+/).compact_map(&.strip.presence)
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

    private def display_values : Array(String)
      [
        Settings.default_detail_pane,
        Settings.history_time_format,
        Settings.show_gutter ? "on" : "off",
        Settings.wrap_lines? ? "on" : "off",
        Settings.preview_body_kib.to_s,
        Settings.resource_meter? ? "on" : "off",
        title_label(Settings.terminal_title),
      ]
    end

    # Positional, like every other *_values reader: a literal at each call site would drift
    # from COMPANION_FIELDS the moment a row is inserted.
    private def companion_values : Array(String)
      [
        Settings.companion? ? "on" : "off",
        Settings.companion_placement,
        Settings.companion_motion,
        Settings.companion_notices? ? "on" : "off",
      ]
    end

    # "tab"/"off" label as themselves; only the default mode reads differently in the UI
    # ("project" stored, "project + tab" shown) since the title carries both.
    private def title_label(mode : String) : String
      mode == "project" ? "project + tab" : mode
    end

    private def title_from_label(s : String) : String
      DISPLAY_TITLE_CHOICES.includes?(s) && s != "project + tab" ? s : "project"
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
      return if readonly_field? # a display row — nothing to type into
      return if opener_field?   # an action row — typing does nothing (↵ opens its overlay)
      if bool_field?            # a toggle field swallows typing; space flips it
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
      return if bool_field? || choice_field? || opener_field? || readonly_field? || @cursor == 0
      v = @values[@focused]
      c = @cursor.clamp(0, v.size)
      @values[@focused] = "#{v[0, c - 1]}#{v[c..]}"
      @cursor = c - 1
      @status = nil
    end

    # Forward-delete (the Del key): remove the character UNDER the caret, leaving the
    # caret where it is — the natural complement to backspace after ←/→ caret moves.
    # No-op on toggle/choice/action rows or with the caret already at end-of-line.
    # `readonly_field?` belongs here for the same reason it does in `insert`/`backspace`:
    # a display row must swallow EVERY edit. Without it a ← (which falls through to
    # move_cursor on a non-bool/non-choice row) pulls the caret off end-of-line, defeating
    # the `c >= v.size` brake below — so Del would chew up the live summary and flip
    # `dirty?`, painting a spurious "● unsaved" for an edit the operator never made.
    def delete : Nil
      return if bool_field? || choice_field? || opener_field? || readonly_field?
      v = @values[@focused]
      c = @cursor.clamp(0, v.size)
      return if c >= v.size
      @values[@focused] = "#{v[0, c]}#{v[(c + 1)..]}"
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

    private def readonly_field? : Bool
      fields[@focused].readonly
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
        @values = editor_values
        return persist
      end
      if @section == :keys
        Settings.command_modifier = Settings.normalize_command_modifier(modifier_from_label(@values[0]))
        @values = keys_values
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
        kib = @values[4].strip.to_i?
        unless kib && kib >= 1
          @status = "invalid preview limit"
          return "settings: invalid preview body limit #{@values[4].inspect} (KiB, min 1)"
        end
        kib = kib.clamp(1, Settings::MAX_PREVIEW_BODY_KIB) # keep kib*1024 within Int32
        Settings.default_detail_pane = @values[0] == "response" ? "response" : "request"
        Settings.history_time_format = @values[1] == "relative" ? "relative" : "absolute"
        Settings.show_gutter = @values[2] == "on"
        Settings.wrap_lines = @values[3] == "on"
        Settings.preview_body_kib = kib
        Settings.resource_meter = @values[5] == "on"
        Settings.terminal_title = title_from_label(@values[6])
        @values = display_values
        return persist
      end
      if @section == :companion
        Settings.companion = @values[0] == "on"
        Settings.companion_placement = Settings.normalize_companion_placement(@values[1])
        Settings.companion_motion = Settings.normalize_companion_motion(@values[2])
        Settings.companion_notices = @values[3] == "on"
        @values = companion_values
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
        if err = Settings.retention_error(@values[3])
          @status = "invalid retention"
          return err
        end
        Settings.clipboard_osc52 = @values[0] == "on"
        Settings.confirm_quit = @values[1] == "on"
        Settings.update_check_enabled = @values[2] == "on"
        Settings.retention_max_flows = @values[3].strip.to_i
        @values = general_values
        return persist
      end
      if err = Settings.bind_host_error(@values[0])
        @status = "invalid bind IP"
        return err
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
      passthrough = passthrough_from_label(@values[9])
      if err = Settings.tls_passthrough_error(passthrough)
        @status = "invalid TLS passthrough host"
        return err
      end
      # An explicit bind edit HERE supersedes a `-l`/`-p` launch override. That override is
      # process-only and invisible on this screen, and the rebind Runner#apply_settings performs
      # compares `effective_bind_*` — where the override wins — so leaving it in place made this
      # edit report "settings saved" while the proxy stayed on the flag's address, with no
      # in-session way to clear it. Only on an actual CHANGE: a save that left the bind alone
      # (an upstream-proxy or timeout edit) must not silently drop the override and yank the
      # proxy off the port the operator launched it on.
      if @values[0].strip != Settings.bind_host || port != Settings.bind_port
        Settings.cli_bind_host = nil
        Settings.cli_bind_port = nil
      end
      Settings.bind_host = @values[0].strip
      Settings.bind_port = port
      Settings.upstream_proxy = up
      Settings.verify_upstream = @values[3] == "on"
      Settings.serve_landing = @values[4] == "on"
      Settings.connect_timeout_secs = ct
      Settings.io_timeout_secs = it
      Settings.capture_max_mib = cap
      Settings.http2 = @values[8]
      Settings.tls_passthrough = passthrough
      @values = network_values
      persist
    end

    private def persist : String
      ok = Settings.save
      @saved = ok
      @baseline = @values.dup if ok # the working copy IS the persisted state now → no longer dirty
      @status = ok ? "saved" : "save failed"
      # `<thing> applied — could not save to <path>`, the shape the rest of the app uses and
      # `Runner#toggle_companion` documents: every setter above ran BEFORE `Settings.save`, so on a
      # failed write the change IS live in this session and only persistence is missing. The
      # old `settings: save failed (…)` said the second half and left the operator to guess
      # the first — on the highest-traffic save in the app.
      ok ? "settings saved" : "settings applied — could not save to #{Settings.path}"
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
      # The overlay's centered card: draw the fields into the interior (1-col inset, 2 rows
      # below the title). The Settings tab calls render_fields_into against its own content
      # rect — SAME field drawing, so overlay and tab can never diverge visually.
      render_fields_into(screen, Rect.new(box.x + 1, box.y + 2, box.w - 2, fields.size), @focused)
    end

    # Draw this section's fields into `rect`, one row per field starting at rect.y, and
    # highlight `focused_idx` (-1 = focus is elsewhere, e.g. another stacked section in the
    # Settings tab: no row is lit and no input caret is drawn). `viewport` bounds the
    # visible rows (top + bottom clip) — the Settings tab passes its scrolled content rect
    # so a block that starts above/below the pane is clipped; the overlay lets it default to
    # `rect` (block == viewport, no extra clipping). Shared by the overlay and the tab.
    def render_fields_into(screen : Screen, rect : Rect, focused_idx : Int32, viewport : Rect = rect) : Nil
      flds = fields
      label_w = flds.max_of(&.label.size)
      flds.each_with_index do |field, i|
        ry = rect.y + i
        next if ry < viewport.y
        break if ry >= viewport.bottom
        focused = i == focused_idx
        bg = focused ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(rect.x, ry, rect.w, 1), bg)
        screen.cell(rect.x, ry, focused ? '▎' : ' ', Theme.accent, bg)
        screen.text(rect.x + 2, ry, field.label, focused ? Theme.text_bright : Theme.text, bg)
        screen.text(rect.x + 2 + label_w + 1, ry, "›", focused ? Theme.accent : Theme.muted, bg)
        vx = rect.x + 2 + label_w + 3
        vw = {rect.right - vx, 1}.max
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
        screen.text(vx, ry, Hotkeys.retag(field.hint), Theme.muted, bg, width: vw)
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
        draw_theme_row(screen, box, names[i], i == sel, list_top + row)
      end
      # The shared gauge on the card's own hairline, replacing the ▲/▼/↕ glyphs this list used
      # to paint into its last interior column — an affordance that existed nowhere else in
      # gori, said only "there is more" rather than how much, and cost a column the swatch
      # now gets back.
      Frame.scroll_gauge(screen, Rect.new(box.x + 1, list_top, box.w - 2, vp),
        names.size, @theme_scroll, true, Theme.panel)
    end

    private def draw_theme_row(screen : Screen, box : Rect, name : String, selected : Bool, ry : Int32) : Nil
      bg = selected ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, selected ? '▎' : ' ', Theme.accent, bg)
      screen.cell(box.x + 3, ry, selected ? '◉' : '◯', selected ? Theme.accent : Theme.muted, bg)
      # The swatch now runs to the last interior column (box.right-2) — the scroll marker that
      # used to sit there moved onto the card's hairline as a gauge.
      swatch_w = 7
      sx = box.right - 1 - swatch_w
      name_w = {sx - (box.x + 5) - 1, 1}.max
      screen.text(box.x + 5, ry, name, selected ? Theme.text_bright : Theme.text, bg, width: name_w)
      draw_swatch(screen, sx, ry, name)
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

    # The two-row footer block: the note (save status / focused field's hint) on its OWN
    # row, the keybind hint right-aligned on the row below. They MUST NOT share a row —
    # a field hint is routinely wider than the gap left by the right-aligned keybinds, so
    # drawing both on one row painted the hint under the keybind text and the two read as
    # one garbled string ("which pane a fresh↑/↓ field · ↵ save · …"). overlay_box already
    # budgets 3 footer rows (blank + note + keybinds — see content_rows + 6), so the note
    # row costs no extra height and gets the full interior width.
    private def render_footer(screen : Screen, box : Rect) : Nil
      note_y = box.bottom - 3
      hint_y = box.bottom - 2
      iw = {box.right - (box.x + 3) - 1, 0}.max # interior width so long hints can't bleed past the box border
      if status = @status
        color = status.starts_with?("invalid") || status.starts_with?("save failed") ? Theme.yellow : Theme.green
        screen.text(box.x + 3, note_y, "• #{status}", color, Theme.panel, width: iw)
      elsif @section == :theme
        names = Theme.available
        screen.text(box.x + 3, note_y, "theme #{(names.index(@values[0]) || 0) + 1}/#{names.size}", Theme.muted, Theme.panel, width: iw)
      else
        screen.text(box.x + 3, note_y, Hotkeys.retag(fields[@focused].hint), Theme.muted, Theme.panel, width: iw)
      end
      hint = @section == :theme ? "↑/↓ select · ↵ apply · ^R reset · esc close" : "↑/↓ field · ↵ save · ^R reset · esc close"
      hx = {box.right - hint.size - 2, box.x + 1}.max # never start left of the box interior
      screen.text(hx, hint_y, hint, Theme.muted, Theme.panel, width: {box.right - hx - 1, 0}.max)
    end
  end

  # The dedicated per-section settings CARD on the Overlay seam (@overlay is :settings).
  # SettingsView itself stays a plain form engine because three surfaces share it — this
  # card, the Preferences modal's inline sections (render_fields_into) and the project
  # picker's theme card — and only one of them is a Runner modal. So the modal is this
  # thin Overlay around it rather than the engine itself.
  #
  # In-app only the THEME section reaches the card: open_settings routes every other
  # section into the Preferences modal. It still drives any section, so the opener-row and
  # save paths below are the engine's, not theme-specific.
  #
  # Runner coupling is injected at the open-site: a saved section is live-applied by the
  # shell (apply_settings_saved), ^R raises the reset confirm, ↑/↓/←/→ live-preview the
  # theme being cycled, an opener row hands off to its own editor, and ^P leaves for the
  # command palette.
  class SettingsOverlay < Overlay
    property on_palette : Proc(Nil)?
    property on_preview : Proc(Nil)?
    property on_reset : Proc(Nil)?
    property on_save : Proc(Symbol, String, Nil)?
    property on_open_editor : Proc(Symbol, Nil)?

    getter view : SettingsView

    def initialize(section : Symbol = :theme)
      @view = SettingsView.new
      @view.reload(section)
    end

    def section : Symbol
      @view.section
    end

    # The theme being previewed (nil outside :theme) — the shell's live-preview closure
    # reads it rather than the overlay applying a theme itself.
    def theme_value : String?
      @view.theme_value
    end

    # Run by the ^R confirm's action, which the shell owns (the confirm outlives one key).
    def reset_to_defaults : Nil
      @view.reset_to_defaults
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::Settings
    end

    def title : String
      "SETTINGS"
    end

    def hint : String
      "↑/↓ field · type to edit · ↵ save · ^R reset · esc close"
    end

    def render(screen : Screen, area : Rect) : Nil
      @view.render(screen, area)
    end

    # SettingsView returns an EMPTY rect where render declines to draw, so a click there
    # falls through to !contains? and closes instead of focusing a field on an undrawn card.
    def overlay_box(area : Rect) : Rect?
      @view.overlay_box(area)
    end

    def set_preedit(text : String) : Nil
      @view.set_preedit(text)
    end

    # ↑/↓ and the wheel share this — in :theme the section's single field IS the list, so
    # this scrolls the theme selection and previews it.
    def move(step : Int32) : Nil
      @view.move_field(step)
      preview
    end

    # ↑/↓ pick a field, type to edit, ↵ save (persist + apply), esc close, ^P palette.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      if ev.ctrl? && key.lower_p?
        on_palette.try(&.call)
      elsif ev.ctrl? && key.lower_r?
        # ^R (not a bare letter — those are typed into the focused field) reverts the
        # section to its factory defaults, gated behind a confirm like the tab-bar reset.
        on_reset.try(&.call)
      elsif key.escape?
        return :cancel
      elsif key.enter?
        activate
      else
        handle_field_key(ev)
      end
      :stay
    end

    # ↑/↓ move between fields (in :theme the section IS the list, so they scroll it) and
    # ←/→ flip a toggle, cycle a choice or move the caret — each live-previewing whatever
    # theme it lands on. ⌫/Del and any printable edit the focused field.
    private def handle_field_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      c = ev.char || key.to_char
      if key.up?
        move(-1)
      elsif key.down?
        move(1)
      elsif key.left?
        @view.toggle_or_move(-1)
        preview
      elsif key.right?
        @view.toggle_or_move(1)
        preview
      elsif key.backspace?
        @view.backspace
      elsif key.delete?
        @view.delete
      elsif c && !ev.ctrl? && !ev.alt?
        @view.insert(c)
        @view.set_preedit("")
        preview # space cycles the theme in the :theme section — preview it too
      end
    end

    # A click outside dismisses; a row click focuses that field, opens an action row's
    # sub-editor (mouse parity with ↵), or live-previews a clicked theme.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = @view.overlay_box(area)
      return :cancel unless box.contains?(mx, my)
      if idx = @view.field_at(box, mx, my)
        @view.set_field(idx)
        if opener = @view.focused_opener
          on_open_editor.try(&.call(opener))
        else
          preview # clicking a theme row live-previews it (no-op outside :theme)
        end
      end
      :stay
    end

    # ↵: an action row (e.g. "Hostname overrides") opens its sub-editor instead of saving
    # the section — the sub-editor persists on its own. Any other row saves, and the shell
    # live-applies the section through apply_settings_saved so the Preferences modal and
    # this card can't drift.
    private def activate : Nil
      if opener = @view.focused_opener
        on_open_editor.try(&.call(opener))
        return
      end
      msg = @view.save
      on_save.try(&.call(@view.section, msg))
    end

    private def preview : Nil
      on_preview.try(&.call)
    end
  end
end
