require "json"
require "./paths"

module Gori
  # Global, persisted user settings — the editable runtime CONFIG for one gori
  # process (the `settings:*` command-palette entries control this). Currently the
  # NETWORK section: the proxy bind address + an optional upstream proxy. Theme and
  # hotkeys are TODO. Persisted as JSON at <config_dir>/settings.json.
  #
  # Loaded once at startup (CLI flags then override the bind in memory); the
  # Settings UI edits these class properties and calls `save`. `upstream_proxy` is
  # read live by Upstream.dial, so changing it applies immediately; `bind_host`/
  # `bind_port` are applied by App on the next project open (the live proxy keeps
  # its current bind).
  module Settings
    class_property bind_host : String = "127.0.0.1"
    class_property bind_port : Int32 = 8070
    class_property upstream_proxy : String = "" # "host:port" HTTP proxy; "" = connect directly

    def self.path : String
      File.join(Paths.config_dir, "settings.json")
    end

    # Load persisted values into the class properties. Tolerant: a missing or
    # malformed file leaves the defaults (or CLI-provided values) in place.
    def self.load : Nil
      raw = File.read(path)
      net = JSON.parse(raw)["network"]?
      return unless net
      self.bind_host = net["bind_host"]?.try(&.as_s?) || bind_host
      self.bind_port = net["bind_port"]?.try(&.as_i?) || bind_port
      self.upstream_proxy = net["upstream_proxy"]?.try(&.as_s?) || upstream_proxy
    rescue
      # no file yet / unreadable / bad JSON — keep current values
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
          j.field "network" do
            j.object do
              j.field "bind_host", bind_host
              j.field "bind_port", bind_port
              j.field "upstream_proxy", upstream_proxy
            end
          end
        end
      end
    end

    # Parse `upstream_proxy` into {host, port}, or nil when unset/blank. Accepts
    # "host:port" with an optional "http://" scheme prefix; defaults the port to
    # 8080 when omitted.
    def self.upstream_proxy_addr : {String, Int32}?
      value = upstream_proxy.strip
      return nil if value.empty?
      value = value.sub(/\Ahttps?:\/\//, "").rstrip('/')
      idx = value.rindex(':')
      return {value, 8080} unless idx
      host = value[0...idx]
      return nil if host.empty?
      {host, value[(idx + 1)..].to_i? || 8080}
    end
  end
end
