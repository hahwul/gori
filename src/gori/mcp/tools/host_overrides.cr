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
        unless ov.add(host, ip)
          return busy("failed to add host override (duplicate host, empty, or invalid)")
        end
        entry = ov.entries.find { |e| e.host == host.strip.downcase }
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
        unless ov.update(id, host, ip)
          return busy("failed to update host override (duplicate host, empty, or invalid)")
        end
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "host", host.strip.downcase; j.field "ip", ip } })
      end

      private def delete_host_override(h) : Result
        id = int(h, "id")
        return err(id_error(h, "id"), "INVALID_ARGUMENT", field: "id") unless id
        ov = HostOverrides.load(store)
        return not_found("no host override with id #{id}") unless ov.entries.any? { |e| e.id == id }
        ov.remove(id)
        Result.new(JSON.build { |j| j.object { j.field "id", id; j.field "deleted", true } })
      end
    end
  end
end
