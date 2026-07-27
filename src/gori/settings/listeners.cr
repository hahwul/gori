require "json"

# LISTENERS section (settings.json "listeners"): ADDITIONAL sockets the proxy accepts on,
# alongside the primary `network.bind_host`/`bind_port`. See settings.cr for the load/save
# orchestration.
#
# The primary bind deliberately stays a scalar rather than becoming element 0 of this array.
# "The proxy address" is singular everywhere it matters — the status bar, the statusline JSON,
# the CA-download page, the self-loop refusal, `CaptureStatus`, and the live rebind — because it
# is the address you point a client at. A transparent listener is not that; it is a socket the
# kernel redirects traffic into. Folding them into one list would make every one of those
# surfaces answer "which one?" for no gain.
module Gori::Settings
  # proxy       — an ordinary forward proxy: clients send absolute-form requests or CONNECT.
  #               Use it to expose a second address (e.g. a LAN interface for a phone) without
  #               widening the primary bind to 0.0.0.0.
  # transparent — the client believes it is talking to the origin. There is no CONNECT and no
  #               absolute-form target, so the destination comes from the `Host` header for
  #               cleartext and from the TLS SNI for HTTPS. Requires the kernel to redirect
  #               traffic here (pf / iptables REDIRECT).
  LISTENER_MODES = ["proxy", "transparent"]

  # One additional listener. `target_port` is the port gori dials upstream for a TRANSPARENT
  # connection whose derived host names no port: a transparent listener cannot know the original
  # destination port from the socket alone (that needs SO_ORIGINAL_DST on Linux or a pf lookup on
  # macOS, neither of which gori does), so the redirect rule's intent is declared here instead —
  # the listener taking redirected :443 traffic sets 443. Ignored in proxy mode.
  record Listener,
    host : String,
    port : Int32,
    mode : String = "proxy",
    target_port : Int32 = 0 do
    def transparent? : Bool
      mode == "transparent"
    end

    # The upstream port for a transparent connection, when the derived host carries none.
    # `tls` picks the sensible default so a plain `{host, port, mode}` entry works for both
    # halves of a redirect pair without the operator spelling out 80/443.
    def effective_target_port(tls : Bool) : Int32
      return target_port if target_port > 0
      tls ? 443 : 80
    end
  end

  class_property listeners : Array(Listener) = [] of Listener

  # Tolerant parse, like every other section: an entry without a usable host/port is dropped, an
  # unknown mode is dropped rather than silently becoming "proxy" (which would expose an
  # unintended forward proxy on a LAN address), and a non-array node keeps the current value.
  private def self.parse_listeners(node : JSON::Any?) : Array(Listener)
    arr = node.try(&.as_a?)
    return listeners unless arr
    out = [] of Listener
    arr.each do |e|
      next unless o = e.as_h?
      host = o["host"]?.try(&.as_s?).try(&.strip)
      port = o["port"]?.try(&.as_i?)
      next if host.nil? || host.empty? || port.nil? || !(0 <= port <= 65535)
      mode = o["mode"]?.try(&.as_s?).try(&.strip.downcase) || "proxy"
      next unless LISTENER_MODES.includes?(mode)
      target = o["target_port"]?.try(&.as_i?) || 0
      target = 0 unless 0 <= target <= 65535
      out << Listener.new(host, port, mode, target)
    end
    out
  end

  private def self.serialize_listeners(j : JSON::Builder) : Nil
    return if listeners.empty?
    j.field "listeners" do
      j.array do
        listeners.each do |l|
          j.object do
            j.field "host", l.host
            j.field "port", l.port
            j.field "mode", l.mode
            j.field "target_port", l.target_port if l.target_port > 0
          end
        end
      end
    end
  end

  # nil if `listener` is usable; an error message otherwise. Checked at save time so a bad
  # address surfaces here rather than as an opaque bind failure on the next project open.
  def self.listener_error(listener : Listener) : String?
    if err = bind_host_error(listener.host)
      return err
    end
    return "settings: listener needs a host" if listener.host.strip.empty?
    return "settings: listener port must be 0-65535" unless 0 <= listener.port <= 65535
    return "settings: listener mode must be one of #{LISTENER_MODES.join(", ")}" unless LISTENER_MODES.includes?(listener.mode)
    unless 0 <= listener.target_port <= 65535
      return "settings: listener target_port must be 0-65535"
    end
    # A transparent listener that also carries a target_port in PROXY mode is a sign the
    # operator meant transparent; accepting it silently would ignore the field.
    if listener.target_port > 0 && !listener.transparent?
      return "settings: target_port only applies to a transparent listener"
    end
    nil
  end

  # The upstream port a transparent connection should use: the listener's configured
  # target_port when set, else the conventional port for the protocol. One helper so the
  # cleartext and TLS branches of the transparent path cannot disagree.
  def self.listener_target_port(configured : Int32, tls : Bool) : Int32
    return configured if configured > 0
    tls ? 443 : 80
  end

  # Every additional listener that passes validation, with duplicates of the PRIMARY bind
  # removed — binding the same address twice would fail, and the operator would be left with
  # a listener error about an address they can see is configured exactly once.
  def self.valid_listeners : Array(Listener)
    listeners.reject do |l|
      !listener_error(l).nil? || (l.port == effective_bind_port && same_bind_host?(l.host, effective_bind_host))
    end
  end

  # Whether two bind hosts name the same socket. A raw `==` missed every alternate spelling —
  # `localhost` vs `127.0.0.1`, `[::1]` vs `::1`, `LOCALHOST` — so an entry that duplicates
  # the primary in any of those forms survived here and then failed to bind, reported as a
  # listener error rather than recognised as the duplicate it is.
  #
  # Deliberately NOT a resolver: a DNS lookup while assembling the listener list would be a
  # blocking side effect at project open, and the loopback names are the only ones that matter
  # in practice. Everything else falls back to the literal comparison, which is what it was.
  # This is a best-effort de-duplication, not a bind guarantee — the kernel still has the last
  # word, and Session collects that failure per listener.
  private def self.same_bind_host?(a : String, b : String) : Bool
    na = canonical_bind_host(a)
    nb = canonical_bind_host(b)
    return true if na == nb
    # A wildcard bind already covers every address on the machine, so an extra listener on a
    # concrete address of the same family and port cannot bind beside it.
    wildcard_bind?(na) || wildcard_bind?(nb) ? na.includes?(':') == nb.includes?(':') : false
  end

  # Bracket-stripped, downcased, with the loopback NAMES folded onto their literals so the
  # spellings a person actually types compare equal.
  private def self.canonical_bind_host(h : String) : String
    v = h.strip
    v = v[1...-1] if v.starts_with?('[') && v.ends_with?(']')
    v = v.downcase
    # Only the spellings bind_host_error actually accepts: it rejects "*", so folding that
    # would be inventing a syntax no one can save.
    case v
    when "localhost"     then "127.0.0.1"
    when "ip6-localhost" then "::1"
    when ""              then "0.0.0.0" # an unspecified bind IS the wildcard
    else                      v
    end
  end

  private def self.wildcard_bind?(h : String) : Bool
    h == "0.0.0.0" || h == "::"
  end
end
