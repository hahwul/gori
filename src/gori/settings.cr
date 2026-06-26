require "json"
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
    class_property bind_host : String = "127.0.0.1"
    class_property bind_port : Int32 = 8070
    class_property upstream_proxy : String = ""  # "host:port" HTTP proxy; "" = connect directly
    class_property editor : String = ""          # external editor for ^E; "" = $VISUAL/$EDITOR/vi
    class_property editor_markdown : Bool = true # syntax-highlight markdown in Notes/Project
    class_property theme : String = "goridark"   # TUI colour theme name (settings:theme); applied by Theme.apply
    class_property mouse : Bool = true           # TUI mouse (click + scroll-wheel) navigation; off restores native text-selection
    # Top tab-bar layout: ordered {tab-id, visible?}. Empty = never customized → Chrome
    # reconciles to catalog defaults. Opaque String ids (Crystal has no runtime String→Symbol);
    # Chrome maps ids→catalog symbols. Only an EXPLICIT false hides a tab.
    class_property tab_prefs : Array({String, Bool}) = [] of {String, Bool}

    # Convert tab scratch state (a global scratch tool, not project data). The last
    # input + chain spec are restored on restart; convert_chains are named, saved
    # chain specs (name -> spec) the user can re-load. Written only on commit
    # (Esc/quit), dirty-guarded, so an untouched Convert tab never rewrites the file.
    class_property convert_input : String = ""
    class_property convert_chain : String = ""
    class_property convert_chains : Array({String, String}) = [] of {String, String}

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
      if ed = root["editor"]?
        self.editor = ed["command"]?.try(&.as_s?) || editor
        self.editor_markdown = load_bool(ed, "markdown", editor_markdown)
      end
      self.tab_prefs = parse_tab_prefs(root["tabs"]?)
      if cv = root["convert"]?
        self.convert_input = cv["input"]?.try(&.as_s?) || convert_input
        self.convert_chain = cv["chain"]?.try(&.as_s?) || convert_chain
        self.convert_chains = parse_convert_chains(cv["chains"]?)
      end
    rescue
      # no file yet / unreadable / bad JSON — keep current values
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
      File.write(path, serialize)
      true
    rescue
      false
    end

    private def self.serialize : String
      JSON.build do |j|
        j.object do
          j.field "theme", theme
          j.field "mouse", mouse
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
          # Omit the whole block when Convert was never used, so an untouched install
          # never writes a "convert" section.
          unless convert_input.empty? && convert_chain.empty? && convert_chains.empty?
            j.field "convert" do
              j.object do
                j.field "input", convert_input
                j.field "chain", convert_chain
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
