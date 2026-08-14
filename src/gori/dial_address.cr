require "socket"

module Gori
  # The KEY half of a host override: the form of a hostname both override layers store and
  # look up by, so "does this request match an override?" has ONE answer.
  #
  # Lives beside `DialAddress` (the value half) for the same reason that one does: the
  # per-project table (`Gori::HostOverrides`) and the global `settings.json`
  # `hostname_overrides` list must agree, and `Settings` deliberately does not depend on the
  # proxy model.
  #
  # Two things are folded away. CASE, because DNS names are case-insensitive and both layers
  # already lowercased. And a TRAILING ROOT DOT, because `example.com.` and `example.com` name
  # the same host — `SelfPage.magic_host?` has always chomped it, so an override on the
  # reserved name could be escaped by one spelling and not the other, and an entry typed WITH
  # the dot was a silent dead override that no request could ever match.
  module OverrideHost
    # The lookup/storage key for `host`. `rstrip` rather than `chomp` so the pathological
    # "example.com.." folds too instead of leaving a dot behind that still matches nothing.
    def self.key(host : String) : String
      host.strip.downcase.rstrip('.')
    end
  end

  # The VALUE half of a host override: the address gori dials in place of a name.
  #
  # It used to be an IP literal and nothing else, which encoded the belief that redirecting a
  # host is only ever a question of WHICH MACHINE. It is not — "point https://api.prod.example/
  # at the build running on 127.0.0.1:8443" is the ordinary shape of the test, and the port
  # always came from the request URL, so it could not be said at all. On the active send paths
  # an operator can work around that with `--target` plus a hand-written `Host:` header; when
  # the traffic comes from a real browser or a mobile app through the proxy there is no
  # equivalent, because gori is not the one writing the URL.
  #
  # So a value is `IP` or `IP:PORT` (`[v6]:PORT` for IPv6, since a bare v6 literal's own colons
  # cannot be told from a port separator). A bare `IP` still means "same port as the request",
  # which is what every existing entry says and keeps saying.
  #
  # Lives here, not on `HostOverrides`, because BOTH override layers must agree on the grammar:
  # the per-project table (`Gori::HostOverrides`) and the global `settings.json`
  # `hostname_overrides` list, and `Settings` deliberately does not depend on the proxy model.
  # One parser means a spelling accepted by one layer can never be rejected by the other.
  module DialAddress
    # A parsed override value. `port` is nil when the value names none, which means "keep the
    # request's own port". A record rather than a tuple because a nilable tuple of a nilable
    # element is exactly the shape Crystal 1.21's codegen miscompiles here ("Load operand must
    # be a pointer") — and because `.port` reads better at the call site than `[1]`.
    record Target, ip : String, port : Int32?

    # The parsed value, or nil when `value` is not an IP literal (optionally with a port).
    #
    # A HOSTNAME is still rejected, for the reason it always was: `TCPSocket` would resolve it,
    # so an override mapping a name to another name is a re-resolution loop rather than the
    # /etc/hosts-style mapping this is modelled on.
    def self.parse(value : String) : Target?
      v = value.strip
      return nil if v.empty?
      if v.starts_with?('[')
        return nil unless close = v.index(']')
        inner = v[1...close]
        rest = v[(close + 1)..]
        return nil unless ip?(inner)
        return Target.new(inner, nil) if rest.empty?
        return nil unless rest.starts_with?(':')
        port = valid_port(rest[1..])
        return port ? Target.new(inner, port) : nil
      end
      # A bare IPv6 literal ("::1") is tried WHOLE first: its own colons would otherwise be
      # split as a port separator and the address silently truncated.
      return Target.new(v, nil) if ip?(v)
      return nil unless idx = v.rindex(':')
      host = v[0...idx]
      return nil unless ip?(host)
      port = valid_port(v[(idx + 1)..])
      port ? Target.new(host, port) : nil
    end

    # The address without its port — what a display or a duplicate check wants.
    def self.ip(value : String) : String?
      parse(value).try(&.ip)
    end

    def self.valid?(value : String) : Bool
      !parse(value).nil?
    end

    # A dialable TCP port. 0 is excluded deliberately: it means "let the kernel choose" on a
    # BIND and nothing at all on a connect, so accepting it would store an override that can
    # never complete a dial.
    private def self.valid_port(text : String) : Int32?
      port = text.to_i?
      port && port > 0 && port <= 65535 ? port : nil
    end

    private def self.ip?(text : String) : Bool
      Socket::IPAddress.new(text, 0)
      true
    rescue
      false
    end
  end
end
