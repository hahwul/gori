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
        return err("invalid host/ip (host hostname-shaped, ip an IPv4/IPv6 literal)", "INVALID_ARGUMENT") unless HostOverrides.valid?(host, ip)
        ov = HostOverrides.load(store)
        normalized = host.strip.downcase
        # host/ip are already validated above and HostOverrides#add reports NOTHING about the
        # store write, so its only remaining false is a DUPLICATE — a deterministic condition
        # that can never succeed on retry. Reporting it as retryable PROJECT_BUSY made an agent
        # that trusts `retryable` loop forever (the #414 shape, fixed there in add_scope_rule).
        if ov.entries.any? { |e| e.host == normalized }
          return err("a host override for '#{normalized}' already exists (update it by id with update_host_override)",
            "INVALID_ARGUMENT", field: "host")
        end
        unless ov.add(host, ip)
          return err("host override rejected (host must be hostname-shaped, ip an IPv4/IPv6 literal)",
            "INVALID_ARGUMENT", field: "host")
        end
        entry = ov.entries.find { |e| e.host == normalized }
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", entry.try(&.id)
            j.field "host", host.strip.downcase
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
        return err("invalid host/ip (host hostname-shaped, ip an IPv4/IPv6 literal)", "INVALID_ARGUMENT") unless HostOverrides.valid?(host, ip)
        # Split the two causes HostOverrides#update collapses into one `false`: a collision with
        # ANOTHER entry is deterministic (never retry), a rolled-back store write is transient.
        normalized = host.strip.downcase
        if ov.entries.any? { |e| e.id != id && e.host == normalized }
          return err("another host override already covers '#{normalized}'", "INVALID_ARGUMENT", field: "host")
        end
        unless ov.update(id, host, ip)
          return busy("host override NOT updated (store busy or unwritable); it is unchanged")
        end
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "host", host.strip.downcase; j.field "ip", ip } })
      end

      private def delete_host_override(h) : Result
        id = int(h, "id")
        return err(id_error(h, "id"), "INVALID_ARGUMENT", field: "id") unless id
        ov = HostOverrides.load(store)
        return not_found("no host override with id #{id}") unless ov.entries.any? { |e| e.id == id }
        return busy("host override NOT deleted (store busy or unwritable); it is unchanged") unless ov.remove(id)
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "deleted", true } })
      end
    end
  end
end
