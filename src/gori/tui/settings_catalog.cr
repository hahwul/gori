module Gori::Tui
  # The ONE list of settings sections. Both surfaces read it, so they can't drift:
  #   - the Ctrl-P palette registers a `settings.*` verb per entry (verbs/core.cr)
  #   - the Settings tab builds its grouped sub-tabs from the same entries
  # Adding a section is a single row here — it then appears in both places.
  #
  # Before this existed the section symbol lived only inside each verb's handler
  # closure (unreadable as data), and "what sections exist" was duplicated across the
  # palette verbs, SettingsView::SECTIONS, and the Runner dispatch. This lifts the
  # identity into data so the tab can enumerate sections the same way the palette does.
  module SettingsCatalog
    # `kind` decides how the Settings tab presents the section:
    #   :form   → editable inline via the shared SettingsView field engine
    #   :opener → a single row whose ↵ opens the section's dedicated overlay
    #             (theme list, tabs/env/hotkeys editors) — reusing open_settings.
    # `sym` is the argument passed to open_settings (also the section's identity);
    # `id`/`desc` are the palette verb's id + description (kept verbatim); `title` is
    # the short label used for the sub-tab group members and section subheaders.
    # `in_tab` is false for a section reachable another way (Hostnames lives as an
    # opener FIELD inside Network) so it still gets a palette verb but no tab row.
    record Section,
      sym : Symbol,
      id : String,
      title : String,
      desc : String,
      group : Symbol,
      kind : Symbol,
      in_tab : Bool = true

    # The Settings tab's sub-tab strip, in display order. Each group gathers the
    # catalog sections tagged with its symbol (see `sections_in`).
    GROUPS = [
      {:general, "General"},
      {:appearance, "Appearance"},
      {:editor, "Editor & Keys"},
      {:network, "Network & Tabs"},
    ]

    # Every settings section. Order here is the palette registration order (grouped, so
    # the Ctrl-P listing reads grouped too) and the within-group order in the tab.
    SECTIONS = [
      # General
      Section.new(:general, "settings.general", "General",
        "Clipboard (OSC 52) integration and confirm-before-quit", :general, :form),
      Section.new(:notifications, "settings.notifications", "Notifications",
        "Terminal bell + toast on background results, and how many notifications are kept", :general, :form),
      Section.new(:statusline, "settings.statusline", "Statusline",
        "Run a command periodically and show its output as a bottom status line", :general, :form),
      # Appearance
      Section.new(:theme, "settings.theme", "Theme",
        "Switch the TUI colour theme (built-ins + your own from ~/.gori/themes/*.json)", :appearance, :opener),
      Section.new(:display, "settings.display", "Display",
        "Message-body rendering: default detail pane, list time format, line numbers, preview size", :appearance, :form),
      Section.new(:layout, "settings.layout", "Layout",
        "History list Req/Res preview and Sitemap default expand depth", :appearance, :form),
      # Editor & Keys
      Section.new(:editor, "settings.editor", "Editor",
        "Set the external editor opened by ^E in editable fields", :editor, :form),
      Section.new(:env, "settings.env", "Env",
        "Global environment variables for $KEY substitution in requests", :editor, :opener),
      Section.new(:hotkeys, "settings.hotkeys", "Hotkeys",
        "Rebind keyboard shortcuts (press a key) + pick an OS default profile", :editor, :opener),
      # Network & Tabs
      Section.new(:network, "settings.network", "Network",
        "Edit the proxy bind address + upstream proxy", :network, :form),
      Section.new(:tabs, "settings.tabs", "Tabs",
        "Customize the top tab bar — show/hide tabs and reorder them", :network, :opener),
      # Reachable via the Network section's "Hostname overrides" opener field, so it
      # keeps its palette verb but is not given its own tab row (in_tab: false).
      Section.new(:hosts, "settings.host-overrides", "Hostnames",
        "Edit global hostname overrides — a /etc/hosts mapping hosts to IPs the proxy dials", :network, :opener, in_tab: false),
    ]

    # Every section, in registration order — drives the palette verb loop.
    def self.all : Array(Section)
      SECTIONS
    end

    # The tab rows for one group, in catalog order (skips in_tab: false sections).
    def self.sections_in(group : Symbol) : Array(Section)
      SECTIONS.select { |s| s.in_tab && s.group == group }
    end
  end
end
