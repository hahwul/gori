require "json"
require "socket"

# ENV section: global hostname overrides (a process-wide /etc/hosts) and the
# `$KEY`-substitution env vars (global + a per-project runtime-only layer). See
# settings.cr for the module-level overview and the load/save/serialize orchestration.
module Gori::Settings
  DEFAULT_ENV_PREFIX = "$"

  # Global hostname overrides (a process-wide /etc/hosts): ordered {host (lowercased),
  # ip} pairs. Read LIVE by Upstream.dial (edits apply on the next flow); layered
  # UNDER each project's own HostOverrides, which wins on a host collision. Edited via
  # settings:network (the HostsOverlay).
  class_property hostname_overrides : Array({String, String}) = [] of {String, String}
  class_property env_prefix : String = DEFAULT_ENV_PREFIX
  class_property env_vars : Array({String, String}) = [] of {String, String}
  class_property project_env_vars : Array({String, String}) = [] of {String, String}

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

  # True when `ip` is a real IPv4/IPv6 literal (not a hostname that TCPSocket would
  # re-resolve). Mirrors HostOverrides.valid?'s IP check without coupling Settings to
  # the proxy model.
  private def self.valid_ip?(ip : String) : Bool
    Socket::IPAddress.new(ip, 0)
    true
  rescue
    false
  end

  # Omit when empty so an untouched install never writes "hostname_overrides": [].
  private def self.serialize_hostname_overrides(j : JSON::Builder) : Nil
    unless hostname_overrides.empty?
      j.field "hostname_overrides" do
        j.array do
          hostname_overrides.each { |(host, ip)| j.object { j.field "host", host; j.field "ip", ip } }
        end
      end
    end
  end

  private def self.serialize_env(j : JSON::Builder) : Nil
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
end
