require "json"
require "socket"
require "./paths"

module Gori
  # Global, persisted user settings — the editable runtime CONFIG for one gori
  # process (the `settings:*` command-palette entries control this). Currently the
  # NETWORK section (proxy bind + upstream proxy), the EDITOR (external ^E editor),
  # and the TUI THEME. Hotkeys are TODO. Persisted as JSON at <config_dir>/settings.json.
  #
  # Loaded once at startup (CLI flags then override the bind in memory); the
  # Settings UI edits these class properties and calls `save`. `upstream_proxy` is
  # read live by Upstream.dial, so changing it applies immediately; `bind_host`/
  # `bind_port` are applied by App on the next project open (the live proxy keeps
  # its current bind).
  module Settings
    # Factory defaults — the values a fresh install ships with. Declared as constants so
    # the settings editor's reset-to-defaults action and the property initializers below
    # share ONE source of truth (no drift between "what we ship" and "what reset restores").
    DEFAULT_BIND_HOST       = "127.0.0.1"
    DEFAULT_BIND_PORT       = 8070
    DEFAULT_UPSTREAM_PROXY  = ""
    DEFAULT_VERIFY_UPSTREAM = true
    DEFAULT_SERVE_LANDING   = true
    DEFAULT_EDITOR          = ""
    DEFAULT_EDITOR_MARKDOWN = true
    DEFAULT_THEME           = "goridark"
    DEFAULT_MOUSE           = true
    DEFAULT_PRETTY_BODIES   = true
    DEFAULT_ENV_PREFIX      = "$"
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

    class_property bind_host : String = DEFAULT_BIND_HOST
    class_property bind_port : Int32 = DEFAULT_BIND_PORT
    class_property upstream_proxy : String = DEFAULT_UPSTREAM_PROXY # "host:port" HTTP proxy; "" = connect directly
    # Whether the proxy/probe/repeater verify the UPSTREAM TLS certificate. The launch
    # flag --insecure-upstream seeds this false for the session (see CLI.run_tui); the
    # settings:network editor toggles it live via Session#set_verify_upstream. Global-only
    # (no per-project override). CLI `run`/MCP paths keep their own --insecure-upstream flag.
    class_property? verify_upstream : Bool = DEFAULT_VERIFY_UPSTREAM
    # Whether a browser that hits the proxy listener DIRECTLY (origin-form, no proxy
    # config) gets the gori welcome + CA-download page instead of the 502 self-loop
    # refusal. Global-only; the settings:network editor toggles it live via
    # Session#set_serve_landing (pushed to the TLS tunnel, read per-request).
    class_property? serve_landing : Bool = DEFAULT_SERVE_LANDING

    # Per-project network overrides — a RUNTIME layer set by Session.open from the OPEN
    # project's DB and NEVER persisted to settings.json (the project's own DB is the source
    # of truth). nil = inherit the matching global value above. The proxy bind + Upstream.dial
    # read the effective_* helpers, so a project can pin its own bind/upstream while the global
    # settings:network editor keeps writing the shared defaults. Stored in the project's generic
    # KV `settings` table under these keys (Store#setting/#set_setting/#delete_setting).
    PROJECT_BIND_HOST_KEY = "net.bind_host"
    PROJECT_BIND_PORT_KEY = "net.bind_port"
    PROJECT_UPSTREAM_KEY  = "net.upstream_proxy"
    class_property project_bind_host : String? = nil
    class_property project_bind_port : Int32? = nil
    class_property project_upstream_proxy : String? = nil

    def self.effective_bind_host : String
      project_bind_host || bind_host
    end

    def self.effective_bind_port : Int32
      project_bind_port || bind_port
    end

    # The upstream proxy the proxy actually dials through: a project override wins, else the
    # global. NOTE an explicit project "" (direct) is truthy in Crystal, so it correctly beats
    # a non-blank global — only an ABSENT override (nil) falls through to the global value.
    def self.effective_upstream_proxy : String
      project_upstream_proxy || upstream_proxy
    end

    # Global hostname overrides (a process-wide /etc/hosts): ordered {host (lowercased),
    # ip} pairs. Read LIVE by Upstream.dial (edits apply on the next flow); layered
    # UNDER each project's own HostOverrides, which wins on a host collision. Edited via
    # settings:network (the HostsOverlay).
    class_property hostname_overrides : Array({String, String}) = [] of {String, String}
    class_property env_prefix : String = DEFAULT_ENV_PREFIX
    class_property env_vars : Array({String, String}) = [] of {String, String}
    class_property project_env_vars : Array({String, String}) = [] of {String, String}

    # A GLOBAL user-defined Probe match rule (settings.json "scan_rules"), reusable across every
    # project. `severity` is the lowercase Store::Severity label ("info".."critical");
    # Probe.custom_rules maps these into the runtime match list. Project-scoped rules live in the
    # project DB (probe_custom_rules). `id` is a random hex token assigned on creation.
    record ScanRule,
      id : String,
      title : String,
      description : String,
      side : String,     # "request" | "response"
      region : String,   # "whole" | "header" | "body"
      kind : String,     # "string" | "regex"
      pattern : String,
      severity : String, # lowercase Store::Severity label
      enabled : Bool
    class_property scan_rules : Array(ScanRule) = [] of ScanRule

    SCAN_RULE_SIDES      = %w[request response]
    SCAN_RULE_REGIONS    = %w[whole header body]
    SCAN_RULE_KINDS      = %w[string regex]
    SCAN_RULE_SEVERITIES = %w[info low medium high critical]
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

    def self.history_newest_first? : Bool
      history_list_order != "oldest"
    end

    def self.normalize_history_list_order(s : String) : String
      s == "oldest" ? "oldest" : "newest"
    end

    # Top tab-bar layout: ordered {tab-id, visible?}. Empty = never customized → Chrome
    # reconciles to catalog defaults. Opaque String ids (Crystal has no runtime String→Symbol);
    # Chrome maps ids→catalog symbols. Only an EXPLICIT false hides a tab.
    class_property tab_prefs : Array({String, Bool}) = [] of {String, Bool}

    # Hotkey customization (settings:hotkeys). `keymap_os` pins an OS default profile —
    # "auto" tracks the build's platform; "darwin"/"linux"/"windows" force one.
    # `keymap_overrides` is SPARSE: verb-id → chord-label strings ("ctrl-p", "shift-s").
    # An empty list = explicit unbind; an absent id = use the profile default.
    class_property keymap_os : String = "auto"
    class_property keymap_overrides : Hash(String, Array(String)) = {} of String => Array(String)

    # Decoder tab scratch state (a global scratch tool, not project data). Each open
    # sub-tab (an independent conversion session) is restored on restart as a
    # {input, chain, name} tuple; decoder_chains are named, saved chain specs
    # (name -> spec) the user can re-load. Written only on commit (Esc/quit),
    # dirty-guarded, so an untouched Decoder tab never rewrites the file.
    # decoder_input/decoder_chain are the LEGACY single-session fields — read for
    # back-compat migration (see DecoderController), no longer written once
    # decoder_sessions exists.
    class_property decoder_input : String = ""
    class_property decoder_chain : String = ""
    class_property decoder_sessions : Array({String, String, String}) = [] of {String, String, String}
    class_property decoder_chains : Array({String, String}) = [] of {String, String}
    # Last Mine-parameters overlay choices (global scratch — not project data).
    # locations: checked location labels; concurrency/notify mirror the overlay.
    class_property mine_locations : Array(String) = [] of String
    class_property mine_concurrency : Int32 = 10
    class_property mine_notify : String = "when-found"
    class_property? mine_prefs_saved : Bool = false

    # The exact JSON this process last read from disk (nil = never loaded). It's the
    # 3-way-merge BASE at save time: a top-level section this process didn't change
    # (in-memory == base) yields to whatever is on disk now, so a concurrent writer's
    # unrelated edit isn't clobbered by this process persisting one unrelated field.
    @@loaded_raw : String? = nil

    def self.path : String
      File.join(Paths.home_dir, "settings.json")
    end

    # Load persisted values into the class properties. Tolerant: a missing or
    # malformed file leaves the defaults (or CLI-provided values) in place.
    def self.load : Nil
      raw = File.read(path)
      @@loaded_raw = raw
      root = JSON.parse(raw)
      if net = root["network"]?
        self.bind_host = net["bind_host"]?.try(&.as_s?) || bind_host
        self.bind_port = net["bind_port"]?.try(&.as_i?) || bind_port
        self.upstream_proxy = net["upstream_proxy"]?.try(&.as_s?) || upstream_proxy
        self.verify_upstream = load_bool(net, "verify_upstream", verify_upstream?)
        self.serve_landing = load_bool(net, "serve_landing", serve_landing?)
      end
      self.theme = root["theme"]?.try(&.as_s?) || theme # validated against the known themes by Theme.apply
      self.mouse = load_bool(root, "mouse", mouse)
      self.pretty_bodies_default = load_bool(root, "pretty_bodies", pretty_bodies_default)
      if ed = root["editor"]?
        self.editor = ed["command"]?.try(&.as_s?) || editor
        self.editor_markdown = load_bool(ed, "markdown", editor_markdown)
      end
      self.tab_prefs = parse_tab_prefs(root["tabs"]?)
      self.hostname_overrides = parse_hostname_overrides(root["hostname_overrides"]?)
      parse_env(root["env"]?)
      self.scan_rules = parse_scan_rules(root["scan_rules"]?)
      parse_hotkeys(root["hotkeys"]?)
      if cv = (root["decoder"]? || root["convert"]?) # "convert" = pre-rename key (read for back-compat)
        self.decoder_input = cv["input"]?.try(&.as_s?) || decoder_input
        self.decoder_chain = cv["chain"]?.try(&.as_s?) || decoder_chain
        self.decoder_sessions = parse_decoder_sessions(cv["sessions"]?)
        self.decoder_chains = parse_decoder_chains(cv["chains"]?)
      end
      parse_mine_prefs(root["mine"]?)
      parse_layout(root["layout"]?)
      parse_statusline(root["statusline"]?)
      Env.bump_highlight_rev
    rescue
      # no file yet / unreadable / bad JSON — keep current values
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

    # Allowed depths: -1 (all) or 0..3. Anything else falls back to default.
    def self.normalize_sitemap_depth(d : Int32) : Int32
      return d if d == -1 || (0 <= d <= 3)
      DEFAULT_SITEMAP_EXPAND_DEPTH
    end

    # load_bool over a Hash (the layout object), same false-preserving semantics as load_bool.
    private def self.load_bool_h(h : Hash(String, JSON::Any), key : String, current : Bool) : Bool
      (v = h[key]?) && !(b = v.as_bool?).nil? ? b : current
    end

    # Tolerant sub-tab session parse: a non-array (or absent) node keeps the current
    # value (older configs without a "sessions" array fall back to the legacy
    # input/chain scalars in DecoderController). Missing fields default to "" (a blank
    # session is valid — an empty sub-tab). Mirrors parse_decoder_chains.
    private def self.parse_decoder_sessions(node : JSON::Any?) : Array({String, String, String})
      arr = node.try(&.as_a?)
      return decoder_sessions unless arr
      out = [] of {String, String, String}
      arr.each do |e|
        next unless o = e.as_h?
        input = o["input"]?.try(&.as_s?) || ""
        chain = o["chain"]?.try(&.as_s?) || ""
        name = o["name"]?.try(&.as_s?) || ""
        out << {input, chain, name}
      end
      out
    end

    # Tolerant named-chain parse: a non-array (or absent) node keeps the current
    # value (older configs are safe); entries missing/blank "name" or "spec" are
    # dropped. Mirrors parse_tab_prefs.
    private def self.parse_decoder_chains(node : JSON::Any?) : Array({String, String})
      arr = node.try(&.as_a?)
      return decoder_chains unless arr
      out = [] of {String, String}
      arr.each do |e|
        next unless o = e.as_h?
        name = o["name"]?.try(&.as_s?)
        spec = o["spec"]?.try(&.as_s?)
        next if name.nil? || name.empty? || spec.nil?
        out << {name, spec}
      end
      out
    end

    private def self.parse_env(node : JSON::Any?) : Nil
      return unless e = node.try(&.as_h?)
      if pref = e["prefix"]?.try(&.as_s?)
        self.env_prefix = pref.empty? ? Env::DEFAULT_PREFIX : pref
      end
      self.env_vars = parse_env_vars(e["vars"]?)
    end

    private def self.parse_env_vars(node : JSON::Any?) : Array({String, String})
      arr = node.try(&.as_a?)
      return [] of {String, String} unless arr
      out = [] of {String, String}
      arr.each do |entry|
        next unless o = entry.as_h?
        key = o["key"]?.try(&.as_s?)
        val = o["value"]?.try(&.as_s?)
        next if key.nil? || key.empty? || val.nil?
        next unless valid_env_key?(key)
        out << {key, val}
      end
      out
    end

    private def self.valid_env_key?(key : String) : Bool
      !key.empty? && key.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
    end

    # Tolerant hostname-override parse: a non-array (or absent) node keeps the current
    # value; entries missing/blank "host" or "ip" are dropped. The host is lowercased so
    # the live lookup (host_override_ip) and the project store stay consistent. Mirrors
    # parse_decoder_chains' robustness.
    private def self.parse_hostname_overrides(node : JSON::Any?) : Array({String, String})
      arr = node.try(&.as_a?)
      return hostname_overrides unless arr
      out = [] of {String, String}
      arr.each do |e|
        next unless o = e.as_h?
        host = o["host"]?.try(&.as_s?)
        ip = o["ip"]?.try(&.as_s?)
        next if host.nil? || host.empty? || ip.nil? || ip.empty?
        next unless valid_ip?(ip) # defense-in-depth: a hand-edited non-literal "ip" would re-resolve via DNS
        out << {host.downcase, ip}
      end
      out
    end

    # Tolerant global-scan-rule parse: a non-array (or absent) node keeps the current value;
    # entries missing id/title/pattern are dropped; side/region/kind/severity are clamped to
    # their allowed sets (default to the safest choice) so a hand-edited file can't smuggle an
    # invalid enum into the match engine. Mirrors parse_hostname_overrides' robustness.
    private def self.parse_scan_rules(node : JSON::Any?) : Array(ScanRule)
      arr = node.try(&.as_a?)
      return scan_rules unless arr
      out = [] of ScanRule
      arr.each do |e|
        next unless o = e.as_h?
        id = o["id"]?.try(&.as_s?)
        title = o["title"]?.try(&.as_s?)
        pattern = o["pattern"]?.try(&.as_s?)
        next if id.nil? || id.empty? || title.nil? || title.empty? || pattern.nil? || pattern.empty?
        side = clamp_field(o["side"]?.try(&.as_s?), SCAN_RULE_SIDES, "response")
        region = clamp_field(o["region"]?.try(&.as_s?), SCAN_RULE_REGIONS, "body")
        kind = clamp_field(o["kind"]?.try(&.as_s?), SCAN_RULE_KINDS, "string")
        severity = clamp_field(o["severity"]?.try(&.as_s?), SCAN_RULE_SEVERITIES, "info")
        desc = o["description"]?.try(&.as_s?) || ""
        enabled = o["enabled"]?.try { |v| v.as_bool? }
        out << ScanRule.new(id, title, desc, side, region, kind, pattern, severity, enabled.nil? ? true : enabled)
      end
      out
    end

    private def self.clamp_field(val : String?, allowed : Array(String), default : String) : String
      v = val.try(&.downcase)
      (v && allowed.includes?(v)) ? v : default
    end

    # --- global scan-rule library CRUD (settings:probe rules → global scope) -----------------
    # Each mutation rewrites the array and persists via save (atomic + 3-way merge). add returns
    # the new rule's generated id so the caller can select it.
    def self.add_scan_rule(title : String, description : String, side : String, region : String,
                           kind : String, pattern : String, severity : String, enabled : Bool = true) : String
      id = Random::Secure.hex(4)
      self.scan_rules = scan_rules + [ScanRule.new(id, title, description, side, region, kind, pattern, severity, enabled)]
      save
      id
    end

    def self.update_scan_rule(id : String, title : String, description : String, side : String,
                              region : String, kind : String, pattern : String, severity : String) : Nil
      self.scan_rules = scan_rules.map do |r|
        r.id == id ? ScanRule.new(id, title, description, side, region, kind, pattern, severity, r.enabled) : r
      end
      save
    end

    def self.set_scan_rule_enabled(id : String, enabled : Bool) : Nil
      self.scan_rules = scan_rules.map { |r| r.id == id ? r.copy_with(enabled: enabled) : r }
      save
    end

    def self.delete_scan_rule(id : String) : Nil
      self.scan_rules = scan_rules.reject { |r| r.id == id }
      save
    end

    # True when `ip` is a real IPv4/IPv6 literal (not a hostname that TCPSocket would
    # re-resolve). Mirrors HostOverrides.valid?'s IP check without coupling Settings to
    # the proxy model.
    private def self.valid_ip?(ip : String) : Bool
      Socket::IPAddress.new(ip, 0)
      true
    rescue
      false
    end

    # Tolerant tab-bar parse: a non-array (or absent) node keeps the current value;
    # entries missing/blank "id" are dropped; "visible" absent or non-bool ⇒ visible
    # (never hide a tab from a malformed flag). Unknown/duplicate ids are left for
    # Chrome.reconcile to normalize against the canonical catalog.
    private def self.parse_tab_prefs(node : JSON::Any?) : Array({String, Bool})
      arr = node.try(&.as_a?)
      return tab_prefs unless arr
      out = [] of {String, Bool}
      arr.each do |e|
        next unless o = e.as_h?
        id = o["id"]?.try(&.as_s?)
        next if id.nil? || id.empty?
        out << {remap_legacy_id(id), o["visible"]?.try(&.as_bool?) != false} # only explicit false hides
      end
      out
    end

    # Rewrite a pre-rename tab id or verb id to its current name, so a settings.json
    # written before the Repeater/Probe/Issues/Decoder rename keeps its saved tab
    # order/visibility and custom keybindings instead of Chrome.reconcile /
    # Hotkeys.rebindable_overrides silently dropping the now-unknown id. Whole-string
    # (not prefix) substitution so compound ids like "finding.replay-flow" become
    # "issue.repeater-flow". Idempotent on already-new ids (they contain no old token).
    # Order matters: "findings" before "finding".
    private def self.remap_legacy_id(id : String) : String
      id.gsub("findings", "issues")
        .gsub("finding", "issue")
        .gsub("replay", "repeater")
        .gsub("prism", "probe")
        .gsub("convert", "decoder")
    end

    # Tolerant hotkey parse: a non-object (or absent) node keeps current values. `os`
    # is normalized (unknown → "auto"); `bindings` is a sparse verb-id → chord-label
    # list (non-array entries dropped; unparseable chord labels dropped; an empty list
    # is PRESERVED as an explicit unbind). Mirrors parse_tab_prefs' robustness.
    private def self.parse_hotkeys(node : JSON::Any?) : Nil
      return unless h = node.try(&.as_h?)
      self.keymap_os = normalize_os(h["os"]?.try(&.as_s?))
      self.keymap_overrides = parse_keymap_bindings(h["bindings"]?)
    end

    private def self.parse_mine_prefs(node : JSON::Any?) : Nil
      obj = node.try(&.as_h?)
      unless obj
        self.mine_prefs_saved = false
        return
      end
      self.mine_prefs_saved = true
      if locs = obj["locations"]?.try(&.as_a?)
        self.mine_locations = locs.compact_map(&.as_s?).map(&.downcase.strip).reject(&.empty?)
      end
      obj["concurrency"]?.try(&.as_i?).try { |n| self.mine_concurrency = n }
      obj["notify"]?.try(&.as_s?).try { |s| self.mine_notify = s }
    end

    # Persist the overlay's last confirmed choices (called when mining starts).
    def self.save_mine_prefs(locations : Array(String), concurrency : Int32, notify : String) : Nil
      self.mine_locations = locations.map(&.downcase.strip).reject(&.empty?)
      self.mine_concurrency = concurrency
      self.mine_notify = notify
      self.mine_prefs_saved = true
      save
    end

    private def self.parse_keymap_bindings(node : JSON::Any?) : Hash(String, Array(String))
      obj = node.try(&.as_h?)
      return keymap_overrides unless obj # non-object / absent → keep current
      out = {} of String => Array(String)
      obj.each do |id, v|
        next if id.empty?
        arr = v.as_a?
        next unless arr # a non-array entry is dropped (tolerant)
        # Keep only labels that parse to a real chord (round-trip safe); a list that
        # ends up empty is a deliberate unbind and is preserved. The id is remapped from
        # any pre-rename spelling so a saved binding on e.g. replay.send still resolves.
        out[remap_legacy_id(id)] = arr.compact_map(&.as_s?).select { |s| !Verb::Chord.parse(s).nil? }
      end
      out
    end

    private def self.normalize_os(raw : String?) : String
      down = raw.try(&.downcase)
      %w(darwin linux windows).includes?(down) ? down.not_nil! : "auto"
    end

    # Read a boolean field, keeping `current` when it's absent or non-bool. A plain
    # `|| current` would wrongly resurrect a stored `false` (false is falsy), so we
    # assign only when a real bool is present.
    private def self.load_bool(node : JSON::Any, key : String, current : Bool) : Bool
      (v = node[key]?) && !(b = v.as_bool?).nil? ? b : current
    end

    # Persist the current values. Never raises into the caller (a failed write must
    # not crash the TUI); returns whether it succeeded.
    def self.save : Bool
      Paths.ensure_dirs
      # Atomic write: a torn File.write (crash / two instances / disk-full) would leave a
      # half-written settings.json that load()'s blanket rescue silently resets to factory
      # defaults — losing theme, hotkeys, hostname overrides, tab prefs, decoder sessions.
      # Stage to a sibling temp then rename (atomic on POSIX), mirroring cert_authority.
      tmp = "#{path}.tmp"
      File.write(tmp, merge_with_disk(serialize))
      File.rename(tmp, path)
      @@loaded_raw = File.read(path) # our write is now the base for the next merge
      true
    rescue
      File.delete?("#{path}.tmp") rescue nil
      false
    end

    # 3-way merge (base = what we loaded, mine = `current` serialization, theirs = the
    # file on disk now) over the top-level sections, so persisting one field doesn't
    # discard a concurrent writer's edit to an unrelated one: a section this process
    # left unchanged (mine == base) yields to disk; a section it changed wins.
    private def self.merge_with_disk(current : String) : String
      base = @@loaded_raw
      return current unless base && File.exists?(path)
      disk = File.read(path)
      return current if disk == base # nobody else wrote since we loaded — nothing to merge
      cur_h = (JSON.parse(current).as_h? rescue nil)
      base_h = (JSON.parse(base).as_h? rescue nil)
      disk_h = (JSON.parse(disk).as_h? rescue nil)
      return current unless cur_h && base_h && disk_h
      keys = (cur_h.keys + disk_h.keys).uniq!
      JSON.build do |j|
        j.object do
          keys.each do |k|
            cur_v = cur_h[k]?
            # I changed this section (mine != base) → mine wins; else take disk's (a
            # concurrent writer's value, or unchanged). Drop a section absent from both.
            chosen = cur_v != base_h[k]? ? cur_v : (disk_h[k]? || cur_v)
            j.field k, chosen if chosen
          end
        end
      end
    rescue
      current # any merge hiccup falls back to the plain write (never worse than before)
    end

    private def self.serialize : String
      JSON.build do |j|
        j.object do
          j.field "theme", theme
          j.field "mouse", mouse
          j.field "pretty_bodies", pretty_bodies_default
          # Omit layout when every pref is factory default (quiet install; merge-safe section).
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
          # Omit statusline when every field is factory default (quiet install; merge-safe).
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
          j.field "network" do
            j.object do
              j.field "bind_host", bind_host
              j.field "bind_port", bind_port
              j.field "upstream_proxy", upstream_proxy
              j.field "verify_upstream", verify_upstream?
              j.field "serve_landing", serve_landing?
            end
          end
          j.field "editor" do
            j.object do
              j.field "command", editor
              j.field "markdown", editor_markdown
            end
          end
          # Omit when empty so an untouched install never writes an ambiguous "tabs": []
          # (a human reader might misread it as "all hidden").
          unless tab_prefs.empty?
            j.field "tabs" do
              j.array do
                tab_prefs.each { |(id, vis)| j.object { j.field "id", id; j.field "visible", vis } }
              end
            end
          end
          # Omit when empty so an untouched install never writes "hostname_overrides": [].
          unless hostname_overrides.empty?
            j.field "hostname_overrides" do
              j.array do
                hostname_overrides.each { |(host, ip)| j.object { j.field "host", host; j.field "ip", ip } }
              end
            end
          end
          unless env_vars.empty? && env_prefix == DEFAULT_ENV_PREFIX
            j.field "env" do
              j.object do
                j.field "prefix", env_prefix unless env_prefix == DEFAULT_ENV_PREFIX
                unless env_vars.empty?
                  j.field "vars" do
                    j.array do
                      env_vars.each { |(key, val)| j.object { j.field "key", key; j.field "value", val } }
                    end
                  end
                end
              end
            end
          end
          # Omit when empty so an untouched install never writes "scan_rules": [].
          unless scan_rules.empty?
            j.field "scan_rules" do
              j.array do
                scan_rules.each do |r|
                  j.object do
                    j.field "id", r.id
                    j.field "title", r.title
                    j.field "description", r.description
                    j.field "side", r.side
                    j.field "region", r.region
                    j.field "kind", r.kind
                    j.field "pattern", r.pattern
                    j.field "severity", r.severity
                    j.field "enabled", r.enabled
                  end
                end
              end
            end
          end
          # Omit when untouched (default profile + no overrides) so an untouched install
          # never writes a "hotkeys" block.
          unless keymap_overrides.empty? && keymap_os == "auto"
            j.field "hotkeys" do
              j.object do
                j.field "os", keymap_os
                unless keymap_overrides.empty?
                  j.field "bindings" do
                    j.object do
                      keymap_overrides.each do |id, labels|
                        j.field(id) { j.array { labels.each { |l| j.string l } } }
                      end
                    end
                  end
                end
              end
            end
          end
          # Omit the whole block when there's nothing worth persisting — no saved chains,
          # no legacy scalars, and every open session blank+unnamed — so an untouched OR
          # cleared Decoder workbench never writes a "decoder" section. Once any session
          # has content we write the "sessions" array (the source of truth); until then we
          # preserve the legacy input/chain scalars so an un-opened Decoder tab never loses
          # them. (`all?` is vacuously true for an empty array.)
          sessions_blank = decoder_sessions.all? { |(i, c, n)| i.empty? && c.empty? && n.empty? }
          if mine_prefs_saved?
            j.field "mine" do
              j.object do
                j.field "locations" do
                  j.array { mine_locations.each { |l| j.string l } }
                end
                j.field "concurrency", mine_concurrency
                j.field "notify", mine_notify
              end
            end
          end
          unless sessions_blank && decoder_chains.empty? && decoder_input.empty? && decoder_chain.empty?
            j.field "decoder" do
              j.object do
                if decoder_sessions.empty?
                  j.field "input", decoder_input
                  j.field "chain", decoder_chain
                else
                  j.field "sessions" do
                    j.array do
                      decoder_sessions.each do |(input, chain, name)|
                        j.object do
                          j.field "input", input
                          j.field "chain", chain
                          j.field "name", name unless name.empty?
                        end
                      end
                    end
                  end
                end
                unless decoder_chains.empty?
                  j.field "chains" do
                    j.array do
                      decoder_chains.each { |(name, spec)| j.object { j.field "name", name; j.field "spec", spec } }
                    end
                  end
                end
              end
            end
          end
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

    # The global override IP to dial for `host` (case-insensitive exact match), or nil
    # when no global override applies. Read LIVE by Upstream.dial, so settings edits
    # take effect on the next flow. A project-level HostOverrides entry is consulted
    # FIRST and wins on a collision (see Proxy::Upstream.connect_target).
    def self.host_override_ip(host : String) : String?
      return nil if hostname_overrides.empty?
      h = host.downcase
      hostname_overrides.each { |(oh, ip)| return ip if oh == h }
      nil
    end

    # Parse `upstream_proxy` into {host, port}, or nil when unset/blank. Accepts
    # "host:port" with an optional "http://" scheme prefix; defaults the port to
    # 8080 when omitted.
    def self.upstream_proxy_addr : {String, Int32}?
      value = effective_upstream_proxy.strip
      return nil if value.empty?
      value = value.sub(/\Ahttps?:\/\//, "").rstrip('/')
      # Bracketed IPv6 ("[::1]" / "[::1]:8080"): host is inside the brackets, the
      # optional port follows ']'. Without this the rindex(':') below would split
      # inside the IPv6 literal and yield a garbage host/port.
      if value.starts_with?('[')
        if close = value.index(']')
          host = value[1...close]
          return nil if host.empty?
          rest = value[(close + 1)..]
          return {host, rest.starts_with?(':') ? (rest[1..].to_i? || 8080) : 8080}
        end
      end
      idx = value.rindex(':')
      return {value, 8080} unless idx
      host = value[0...idx]
      return nil if host.empty?
      return {value, 8080} if host.includes?(':') # unbracketed IPv6 literal → no port
      {host, value[(idx + 1)..].to_i? || 8080}
    end

    # nil if `value` is an acceptable upstream-proxy string; an error message if its explicit
    # port segment isn't a valid 0-65535 int — so a typo ("proxy:8O80") is caught at save time
    # instead of silently resolving to 8080 (upstream_proxy_addr) and failing every captured
    # flow later, far from the mistake. Shared by settings:network AND the Project settings pane.
    def self.upstream_proxy_port_error(value : String) : String?
      return nil if value.empty?
      bare = value.sub(/\Ahttps?:\/\//, "").rstrip('/')
      if bare.starts_with?('[') # bracketed IPv6 literal: [::1] or [::1]:port — the port is after ']'
        return nil unless close = bare.index(']')
        rest = bare[(close + 1)..]
        return nil unless rest.starts_with?(':') && rest.size > 1 # no explicit port → defaults fine
        seg = rest[1..]
      else
        i = bare.rindex(':')
        return nil unless i && i < bare.size - 1 # no explicit port → defaults fine
        return nil if bare[0...i].includes?(':') # pre-colon host has a ':' → unbracketed IPv6 literal, no port
        seg = bare[(i + 1)..]
      end
      p = seg.to_i?
      (p && 0 <= p <= 65535) ? nil : "settings: invalid upstream proxy port #{seg.inspect}"
    end
  end
end

require "./env"
