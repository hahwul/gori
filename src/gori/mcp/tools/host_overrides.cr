require "json"
require "../../store"
require "../../host_overrides"

module Gori
  module MCP
    class Tools
      private def list_host_overrides : Result
        Result.new(JSON.build do |j|
          j.array do
            HostOverrides.load(store).entries.each do |e|
              j.object do
                j.field "id", e.id
                j.field "host", e.host
                j.field "ip", e.ip
              end
            end
          end
        end)
      end

      private def add_host_override(h) : Result
        host = str(h, "host").try(&.strip)
        return err("missing required 'host'", "INVALID_ARGUMENT", field: "host") if host.nil? || host.empty?
        ip = str(h, "ip").try(&.strip)
        return err("missing required 'ip'", "INVALID_ARGUMENT", field: "ip") if ip.nil? || ip.empty?
        return err("invalid host/ip (host hostname-shaped; ip an IPv4/IPv6 literal, optionally IP:PORT or [v6]:PORT)", "INVALID_ARGUMENT") unless HostOverrides.valid?(host, ip)
        ov = HostOverrides.load(store)
        # `OverrideHost.key`, not `downcase` — it is the form `add` will STORE, so a lookup that
        # spelled it any other way would miss the row it just wrote. A fully-qualified argument
        # ("api.test.") is the case that separates them, and missing here costs both answers
        # below: the duplicate would come back as retryable PROJECT_BUSY (the #414 loop the
        # comment right under this exists to prevent) and a success would report `"id": null`.
        normalized = Gori::OverrideHost.key(host)
        # The DUPLICATE question is deterministic and can never succeed on retry, so answer it
        # here as a non-retryable INVALID_ARGUMENT — reporting it as retryable PROJECT_BUSY made
        # an agent that trusts `retryable` loop forever (the #414 shape, fixed there in
        # add_scope_rule).
        if ov.entries.any? { |e| e.host == normalized }
          return err("a host override for '#{normalized}' already exists (update it by id with update_host_override)",
            "INVALID_ARGUMENT", field: "host")
        end
        unless ov.add(host, ip)
          # host/ip were validated above and the duplicate is answered above, so what is left is
          # the store refusing the write — which `add` only started reporting once it verified
          # the row landed. Before that it returned true here and this tool emitted `{"id": null}`
          # as success for an override the proxy would never dial.
          return busy("host override NOT added (store busy or unwritable); no override was created")
        end
        entry = ov.entries.find { |e| e.host == normalized }
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", entry.try(&.id)
            j.field "host", normalized
            j.field "ip", ip
          end
        end)
      end

      private def update_host_override(h) : Result
        id = int(h, "id")
        return err(id_error(h, "id"), "INVALID_ARGUMENT", field: "id") unless id
        ov = HostOverrides.load(store)
        return not_found("no host override with id #{id}") unless ov.entries.any? { |e| e.id == id }
        host = str(h, "host").try(&.strip)
        ip = str(h, "ip").try(&.strip)
        return err("'host' and 'ip' are both required", "INVALID_ARGUMENT") if host.nil? || host.empty? || ip.nil? || ip.empty?
        return err("invalid host/ip (host hostname-shaped; ip an IPv4/IPv6 literal, optionally IP:PORT or [v6]:PORT)", "INVALID_ARGUMENT") unless HostOverrides.valid?(host, ip)
        # Split the two causes HostOverrides#update collapses into one `false`: a collision with
        # ANOTHER entry is deterministic (never retry), a rolled-back store write is transient.
        # `OverrideHost.key` for the same reason as `add` above — `update` dedupes on the folded
        # host, so a check spelled any other way hands the deterministic case to `busy`.
        normalized = Gori::OverrideHost.key(host)
        if ov.entries.any? { |e| e.id != id && e.host == normalized }
          return err("another host override already covers '#{normalized}'", "INVALID_ARGUMENT", field: "host")
        end
        unless ov.update(id, host, ip)
          return busy("host override NOT updated (store busy or unwritable); it is unchanged")
        end
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "host", normalized; j.field "ip", ip } })
      end

      private def delete_host_override(h) : Result
        id = int(h, "id")
        return err(id_error(h, "id"), "INVALID_ARGUMENT", field: "id") unless id
        ov = HostOverrides.load(store)
        return not_found("no host override with id #{id}") unless ov.entries.any? { |e| e.id == id }
        return busy("host override NOT deleted (store busy or unwritable); it is unchanged") unless ov.remove(id)
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "deleted", true } })
      end

      # The tools/list schemas for the host-override tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_host_overrides_tools(j : JSON::Builder) : Nil
        tool j, "list_host_overrides",
          "List the project's host overrides (/etc/hosts-style: dial a specific IP for a hostname; " \
          "SNI/Host header unchanged). Project overrides win over the global Settings ones on a " \
          "collision." { }

        return unless @allow_actions

        tool j, "add_host_override",
          "Add a host override (dial a specific IP for a hostname; SNI/Host header unchanged) — " \
          "used by send_request/send_websocket/repeater and the live proxy." do |s|
          s.field "host", strprop("hostname to override (case-insensitive)"), required: true
          s.field "ip", strprop("IPv4/IPv6 literal to dial, optionally IP:PORT (or [v6]:PORT) to move the port too"), required: true
        end

        tool j, "update_host_override", "Update an existing host override by id." do |s|
          s.field "id", intprop("host override id (see list_host_overrides)"), required: true
          s.field "host", strprop("new hostname"), required: true
          s.field "ip", strprop("new IPv4/IPv6 literal, optionally IP:PORT (or [v6]:PORT)"), required: true
        end

        tool j, "delete_host_override", "Delete a host override by id." do |s|
          s.field "id", intprop("host override id (see list_host_overrides)"), required: true
        end
      end
    end
  end
end
