require "json"

# DISPLAY section: external editor, TUI theme/mouse/pretty-bodies, list-page layout
# (previews/order/sitemap depth), the statusline, message-body display prefs,
# notifications, and general (clipboard/confirm-quit) toggles. See settings.cr for
# the module-level overview and the load/save/serialize orchestration.
module Gori::Settings
  DEFAULT_EDITOR          = ""
  DEFAULT_EDITOR_MARKDOWN = true
  DEFAULT_THEME           = "goridark"
  DEFAULT_MOUSE           = true
  DEFAULT_PRETTY_BODIES   = true
  # Layout (settings:layout): list previews off by default; Sitemap fully expanded.
  DEFAULT_HISTORY_PREVIEW      = false
  DEFAULT_PROBE_PREVIEW        = false
  DEFAULT_ISSUES_PREVIEW       = false
  DEFAULT_HISTORY_LIST_ORDER   = "newest" # "newest" | "oldest" — list sort direction
  DEFAULT_SITEMAP_EXPAND_DEPTH = -1       # -1 = all
  # Statusline (settings:statusline): opt-in bottom row that runs a command on an
  # interval and shows its (ANSI-coloured) stdout. Off by default; no cost until enabled.
  DEFAULT_STATUSLINE_ENABLED  = false
  DEFAULT_STATUSLINE_COMMAND  = ""
  DEFAULT_STATUSLINE_INTERVAL = 3 # seconds between runs (min 1)
  # Display (settings:display): message-body rendering prefs. detail_pane = which pane a
  # freshly-opened History flow shows first; history_time_format = list time column;
  # show_gutter = line-number gutter on the message body views; preview_body_kib = how many
  # body bytes the History list PREVIEW reads/shows (display-only, not the capture limit).
  # resource_meter = the bottom bar's far-right CPU/MEM readout for gori's own process.
  DEFAULT_DETAIL_PANE         = "request"  # "request" | "response"
  DEFAULT_HISTORY_TIME_FORMAT = "absolute" # "absolute" | "relative"
  DEFAULT_SHOW_GUTTER         = true
  DEFAULT_PREVIEW_BODY_KIB    = 64
  DEFAULT_RESOURCE_METER      = true
  # Upper bound on the preview cap (KiB): kib*1024 must stay within Int32 or
  # preview_body_cap raises on the History navigation path. 65536 KiB = 64 MiB.
  MAX_PREVIEW_BODY_KIB = 65536
  # Notifications (settings:notifications): bell = terminal beep on a background result/alert;
  # toast = also flash a bottom-bar toast for fuzzer/probe/discover results; retention = ring
  # buffer size. All opt-in-friendly defaults (bell off; toast on; 100 kept).
  DEFAULT_NOTIFY_BELL      = false
  DEFAULT_NOTIFY_TOAST     = true
  DEFAULT_NOTIFY_RETENTION = 100
  # General (settings:general): clipboard_osc52 = OSC 52 terminal clipboard integration (the
  # only copy mechanism — off means copies no-op); confirm_quit = require a confirm modal to
  # quit instead of the double-press ^D.
  DEFAULT_CLIPBOARD_OSC52 = true
  DEFAULT_CONFIRM_QUIT    = false

  class_property editor : String = DEFAULT_EDITOR                     # external editor for ^E; "" = $VISUAL/$EDITOR/vi
  class_property editor_markdown : Bool = DEFAULT_EDITOR_MARKDOWN     # syntax-highlight markdown in Notes/Project
  class_property theme : String = DEFAULT_THEME                       # TUI colour theme name (settings:theme); applied by Theme.apply
  class_property mouse : Bool = DEFAULT_MOUSE                         # TUI mouse (click + scroll-wheel) navigation; off restores native text-selection
  class_property pretty_bodies_default : Bool = DEFAULT_PRETTY_BODIES # pretty-print JSON/XML/form/… bodies in History detail + Repeater response (display only)
  # Layout prefs (settings:layout). *_preview: list page shows a bottom detail pane.
  # history_list_order: "newest" (top) or "oldest" (top). sitemap_expand_depth: -1 = all.
  class_property history_preview : Bool = DEFAULT_HISTORY_PREVIEW
  class_property probe_preview : Bool = DEFAULT_PROBE_PREVIEW
  class_property issues_preview : Bool = DEFAULT_ISSUES_PREVIEW
  class_property history_list_order : String = DEFAULT_HISTORY_LIST_ORDER
  class_property sitemap_expand_depth : Int32 = DEFAULT_SITEMAP_EXPAND_DEPTH
  # Statusline (settings:statusline). command is run via `/bin/sh -c` on statusline_interval
  # seconds; its stdout (first line) is rendered at the very bottom of the TUI.
  class_property? statusline_enabled : Bool = DEFAULT_STATUSLINE_ENABLED
  class_property statusline_command : String = DEFAULT_STATUSLINE_COMMAND
  class_property statusline_interval : Int32 = DEFAULT_STATUSLINE_INTERVAL
  # Display prefs (settings:display). detail_pane/history_time_format are validated to their
  # two-value sets on load; show_gutter follows the LAYOUT bools (plain accessor); the History
  # list preview reads preview_body_cap (bytes) so the preview never pulls a multi-MiB body.
  class_property default_detail_pane : String = DEFAULT_DETAIL_PANE
  class_property history_time_format : String = DEFAULT_HISTORY_TIME_FORMAT
  class_property show_gutter : Bool = DEFAULT_SHOW_GUTTER
  class_property preview_body_kib : Int32 = DEFAULT_PREVIEW_BODY_KIB
  # `?` toggle read live by the status bar's ResourceMeter; off means it never samples.
  class_property? resource_meter : Bool = DEFAULT_RESOURCE_METER
  # Notification prefs (settings:notifications). bell/toast are `?` toggles read live at the
  # emit sites; retention bounds the ring buffer (read live by Notifications#push).
  class_property? notify_bell : Bool = DEFAULT_NOTIFY_BELL
  class_property? notify_toast : Bool = DEFAULT_NOTIFY_TOAST
  class_property notify_retention : Int32 = DEFAULT_NOTIFY_RETENTION
  # General prefs (settings:general). Both `?` toggles read live (Clipboard.copy / quit handler).
  class_property? clipboard_osc52 : Bool = DEFAULT_CLIPBOARD_OSC52
  class_property? confirm_quit : Bool = DEFAULT_CONFIRM_QUIT

  # The History-list preview body cap in BYTES (stored as KiB above). Clamped so a
  # large (or hand-edited) KiB value can never overflow Int32 (see MAX_PREVIEW_BODY_KIB).
  def self.preview_body_cap : Int32
    preview_body_kib.clamp(1, MAX_PREVIEW_BODY_KIB) * 1024
  end

  def self.history_newest_first? : Bool
    history_list_order != "oldest"
  end

  def self.normalize_history_list_order(s : String) : String
    s == "oldest" ? "oldest" : "newest"
  end

  # Tolerant layout section: absent/non-object keeps current; depth/order clamped to allowed set.
  private def self.parse_layout(node : JSON::Any?) : Nil
    return unless o = node.try(&.as_h?)
    self.history_preview = load_bool_h(o, "history_preview", history_preview)
    # "prism_preview"/"findings_preview" are the pre-rename keys, read as a fallback.
    self.probe_preview = load_bool_h(o, "probe_preview", load_bool_h(o, "prism_preview", probe_preview))
    self.issues_preview = load_bool_h(o, "issues_preview", load_bool_h(o, "findings_preview", issues_preview))
    if ord = o["history_list_order"]?.try(&.as_s?)
      self.history_list_order = normalize_history_list_order(ord)
    end
    if d = o["sitemap_expand_depth"]?.try(&.as_i?)
      self.sitemap_expand_depth = normalize_sitemap_depth(d)
    end
  end

  # Tolerant statusline section: absent/non-object keeps current; interval floored at 1.
  private def self.parse_statusline(node : JSON::Any?) : Nil
    return unless o = node.try(&.as_h?)
    self.statusline_enabled = load_bool_h(o, "enabled", statusline_enabled?)
    if cmd = o["command"]?.try(&.as_s?)
      self.statusline_command = cmd
    end
    if iv = o["interval"]?.try(&.as_i?)
      self.statusline_interval = {iv, 1}.max
    end
  end

  # Tolerant display section: absent/non-object keeps current; enums clamped to their
  # two-value sets; preview cap floored at 1 KiB.
  private def self.parse_display(node : JSON::Any?) : Nil
    return unless o = node.try(&.as_h?)
    if v = o["detail_pane"]?.try(&.as_s?)
      self.default_detail_pane = v == "response" ? "response" : "request"
    end
    if v = o["history_time_format"]?.try(&.as_s?)
      self.history_time_format = v == "relative" ? "relative" : "absolute"
    end
    self.show_gutter = load_bool_h(o, "show_gutter", show_gutter)
    if v = o["preview_body_kib"]?.try(&.as_i?)
      self.preview_body_kib = v.clamp(1, MAX_PREVIEW_BODY_KIB)
    end
    self.resource_meter = load_bool_h(o, "resource_meter", resource_meter?)
  end

  # Tolerant notifications section: absent/non-object keeps current; retention floored at 1.
  private def self.parse_notifications(node : JSON::Any?) : Nil
    return unless o = node.try(&.as_h?)
    self.notify_bell = load_bool_h(o, "bell", notify_bell?)
    self.notify_toast = load_bool_h(o, "toast", notify_toast?)
    if v = o["retention"]?.try(&.as_i?)
      self.notify_retention = {v, 1}.max
    end
  end

  # Tolerant general section: absent/non-object keeps current.
  private def self.parse_general(node : JSON::Any?) : Nil
    return unless o = node.try(&.as_h?)
    self.clipboard_osc52 = load_bool_h(o, "clipboard_osc52", clipboard_osc52?)
    self.confirm_quit = load_bool_h(o, "confirm_quit", confirm_quit?)
  end

  # Allowed depths: -1 (all) or 0..3. Anything else falls back to default.
  def self.normalize_sitemap_depth(d : Int32) : Int32
    return d if d == -1 || (0 <= d <= 3)
    DEFAULT_SITEMAP_EXPAND_DEPTH
  end

  private def self.serialize_appearance(j : JSON::Builder) : Nil
    j.field "theme", theme
    j.field "mouse", mouse
    j.field "pretty_bodies", pretty_bodies_default
  end

  # Omit layout when every pref is factory default (quiet install; merge-safe section).
  private def self.serialize_layout(j : JSON::Builder) : Nil
    unless history_preview == DEFAULT_HISTORY_PREVIEW &&
           probe_preview == DEFAULT_PROBE_PREVIEW &&
           issues_preview == DEFAULT_ISSUES_PREVIEW &&
           history_list_order == DEFAULT_HISTORY_LIST_ORDER &&
           sitemap_expand_depth == DEFAULT_SITEMAP_EXPAND_DEPTH
      j.field "layout" do
        j.object do
          j.field "history_preview", history_preview
          j.field "probe_preview", probe_preview
          j.field "issues_preview", issues_preview
          j.field "history_list_order", history_list_order
          j.field "sitemap_expand_depth", sitemap_expand_depth
        end
      end
    end
  end

  # Omit statusline when every field is factory default (quiet install; merge-safe).
  private def self.serialize_statusline(j : JSON::Builder) : Nil
    unless statusline_enabled? == DEFAULT_STATUSLINE_ENABLED &&
           statusline_command == DEFAULT_STATUSLINE_COMMAND &&
           statusline_interval == DEFAULT_STATUSLINE_INTERVAL
      j.field "statusline" do
        j.object do
          j.field "enabled", statusline_enabled?
          j.field "command", statusline_command
          j.field "interval", statusline_interval
        end
      end
    end
  end

  # Omit each opt-in section when every field is factory default (quiet install; merge-safe).
  private def self.serialize_display(j : JSON::Builder) : Nil
    unless default_detail_pane == DEFAULT_DETAIL_PANE &&
           history_time_format == DEFAULT_HISTORY_TIME_FORMAT &&
           show_gutter == DEFAULT_SHOW_GUTTER &&
           preview_body_kib == DEFAULT_PREVIEW_BODY_KIB &&
           resource_meter? == DEFAULT_RESOURCE_METER
      j.field "display" do
        j.object do
          j.field "detail_pane", default_detail_pane
          j.field "history_time_format", history_time_format
          j.field "show_gutter", show_gutter
          j.field "preview_body_kib", preview_body_kib
          j.field "resource_meter", resource_meter?
        end
      end
    end
  end

  private def self.serialize_notifications(j : JSON::Builder) : Nil
    unless notify_bell? == DEFAULT_NOTIFY_BELL &&
           notify_toast? == DEFAULT_NOTIFY_TOAST &&
           notify_retention == DEFAULT_NOTIFY_RETENTION
      j.field "notifications" do
        j.object do
          j.field "bell", notify_bell?
          j.field "toast", notify_toast?
          j.field "retention", notify_retention
        end
      end
    end
  end

  private def self.serialize_general(j : JSON::Builder) : Nil
    unless clipboard_osc52? == DEFAULT_CLIPBOARD_OSC52 &&
           confirm_quit? == DEFAULT_CONFIRM_QUIT
      j.field "general" do
        j.object do
          j.field "clipboard_osc52", clipboard_osc52?
          j.field "confirm_quit", confirm_quit?
        end
      end
    end
  end

  private def self.serialize_editor(j : JSON::Builder) : Nil
    j.field "editor" do
      j.object do
        j.field "command", editor
        j.field "markdown", editor_markdown
      end
    end
  end

  # Effective external-editor argv (program + args), WITHOUT the file path:
  # Settings.editor (if set) → $VISUAL → $EDITOR → "vi". Whitespace-split so
  # "code --wait" / "emacs -nw" keep their flags; the caller appends the path.
  def self.editor_command : Array(String)
    raw = editor.strip
    raw = ENV["VISUAL"]?.to_s.strip if raw.empty?
    raw = ENV["EDITOR"]?.to_s.strip if raw.empty?
    raw = "vi" if raw.empty?
    parts = raw.split # collapses whitespace runs, drops empties
    parts.empty? ? ["vi"] : parts
  end
end
