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
    DEFAULT_EDITOR          = ""
    DEFAULT_EDITOR_MARKDOWN = true
    DEFAULT_THEME           = "goridark"
    DEFAULT_MOUSE           = true
    DEFAULT_PRETTY_BODIES   = true

    class_property bind_host : String = DEFAULT_BIND_HOST
    class_property bind_port : Int32 = DEFAULT_BIND_PORT
    class_property upstream_proxy : String = DEFAULT_UPSTREAM_PROXY # "host:port" HTTP proxy; "" = connect directly
    # Global hostname overrides (a process-wide /etc/hosts): ordered {host (lowercased),
    # ip} pairs. Read LIVE by Upstream.dial (edits apply on the next flow); layered
    # UNDER each project's own HostOverrides, which wins on a host collision. Edited via
    # settings:network (the HostsOverlay).
    class_property hostname_overrides : Array({String, String}) = [] of {String, String}
    class_property editor : String = DEFAULT_EDITOR                     # external editor for ^E; "" = $VISUAL/$EDITOR/vi
    class_property editor_markdown : Bool = DEFAULT_EDITOR_MARKDOWN     # syntax-highlight markdown in Notes/Project
    class_property theme : String = DEFAULT_THEME                       # TUI colour theme name (settings:theme); applied by Theme.apply
    class_property mouse : Bool = DEFAULT_MOUSE                         # TUI mouse (click + scroll-wheel) navigation; off restores native text-selection
    class_property pretty_bodies_default : Bool = DEFAULT_PRETTY_BODIES # pretty-print JSON/XML/form/… bodies in History detail + Replay response (display only)
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

    # Convert tab scratch state (a global scratch tool, not project data). Each open
    # sub-tab (an independent conversion session) is restored on restart as a
    # {input, chain, name} tuple; convert_chains are named, saved chain specs
    # (name -> spec) the user can re-load. Written only on commit (Esc/quit),
    # dirty-guarded, so an untouched Convert tab never rewrites the file.
    # convert_input/convert_chain are the LEGACY single-session fields — read for
    # back-compat migration (see ConvertController), no longer written once
    # convert_sessions exists.
    class_property convert_input : String = ""
    class_property convert_chain : String = ""
    class_property convert_sessions : Array({String, String, String}) = [] of {String, String, String}
    class_property convert_chains : Array({String, String}) = [] of {String, String}
    # Last Mine-parameters overlay choices (global scratch — not project data).
    # locations: checked location labels; concurrency/notify mirror the overlay.
    class_property mine_locations : Array(String) = [] of String
    class_property mine_concurrency : Int32 = 10
    class_property mine_notify : String = "when-found"
    class_property? mine_prefs_saved : Bool = false

    def self.path : String
      File.join(Paths.home_dir, "settings.json")
    end

    # Load persisted values into the class properties. Tolerant: a missing or
    # malformed file leaves the defaults (or CLI-provided values) in place.
    def self.load : Nil
      root = JSON.parse(File.read(path))
      if net = root["network"]?
        self.bind_host = net["bind_host"]?.try(&.as_s?) || bind_host
        self.bind_port = net["bind_port"]?.try(&.as_i?) || bind_port
        self.upstream_proxy = net["upstream_proxy"]?.try(&.as_s?) || upstream_proxy
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
      parse_hotkeys(root["hotkeys"]?)
      if cv = root["convert"]?
        self.convert_input = cv["input"]?.try(&.as_s?) || convert_input
        self.convert_chain = cv["chain"]?.try(&.as_s?) || convert_chain
        self.convert_sessions = parse_convert_sessions(cv["sessions"]?)
        self.convert_chains = parse_convert_chains(cv["chains"]?)
      end
      parse_mine_prefs(root["mine"]?)
    rescue
      # no file yet / unreadable / bad JSON — keep current values
    end

    # Tolerant sub-tab session parse: a non-array (or absent) node keeps the current
    # value (older configs without a "sessions" array fall back to the legacy
    # input/chain scalars in ConvertController). Missing fields default to "" (a blank
    # session is valid — an empty sub-tab). Mirrors parse_convert_chains.
    private def self.parse_convert_sessions(node : JSON::Any?) : Array({String, String, String})
      arr = node.try(&.as_a?)
      return convert_sessions unless arr
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
    private def self.parse_convert_chains(node : JSON::Any?) : Array({String, String})
      arr = node.try(&.as_a?)
      return convert_chains unless arr
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

    # Tolerant hostname-override parse: a non-array (or absent) node keeps the current
    # value; entries missing/blank "host" or "ip" are dropped. The host is lowercased so
    # the live lookup (host_override_ip) and the project store stay consistent. Mirrors
    # parse_convert_chains' robustness.
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
        out << {id, o["visible"]?.try(&.as_bool?) != false} # only explicit false hides
      end
      out
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
        # ends up empty is a deliberate unbind and is preserved.
        out[id] = arr.compact_map(&.as_s?).select { |s| !Verb::Chord.parse(s).nil? }
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
      # defaults — losing theme, hotkeys, hostname overrides, tab prefs, convert sessions.
      # Stage to a sibling temp then rename (atomic on POSIX), mirroring cert_authority.
      tmp = "#{path}.tmp"
      File.write(tmp, serialize)
      File.rename(tmp, path)
      true
    rescue
      File.delete?("#{path}.tmp") rescue nil
      false
    end

    private def self.serialize : String
      JSON.build do |j|
        j.object do
          j.field "theme", theme
          j.field "mouse", mouse
          j.field "pretty_bodies", pretty_bodies_default
          j.field "network" do
            j.object do
              j.field "bind_host", bind_host
              j.field "bind_port", bind_port
              j.field "upstream_proxy", upstream_proxy
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
          # cleared Convert workbench never writes a "convert" section. Once any session
          # has content we write the "sessions" array (the source of truth); until then we
          # preserve the legacy input/chain scalars so an un-opened Convert tab never loses
          # them. (`all?` is vacuously true for an empty array.)
          sessions_blank = convert_sessions.all? { |(i, c, n)| i.empty? && c.empty? && n.empty? }
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
          unless sessions_blank && convert_chains.empty? && convert_input.empty? && convert_chain.empty?
            j.field "convert" do
              j.object do
                if convert_sessions.empty?
                  j.field "input", convert_input
                  j.field "chain", convert_chain
                else
                  j.field "sessions" do
                    j.array do
                      convert_sessions.each do |(input, chain, name)|
                        j.object do
                          j.field "input", input
                          j.field "chain", chain
                          j.field "name", name unless name.empty?
                        end
                      end
                    end
                  end
                end
                unless convert_chains.empty?
                  j.field "chains" do
                    j.array do
                      convert_chains.each { |(name, spec)| j.object { j.field "name", name; j.field "spec", spec } }
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
      value = upstream_proxy.strip
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
  end
end
