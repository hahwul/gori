require "json"
require "uri"
require "../bind_address"

# LISTENERS section (settings.json "listeners"): ADDITIONAL sockets the proxy accepts on,
# alongside the primary `network.bind_host`/`bind_port`. See settings.cr for the load/save
# orchestration.
#
# The primary bind deliberately stays a scalar rather than becoming element 0 of this array.
# It is not "an address gori listens on" — it is THE FORWARD-PROXY ENDPOINT A CLIENT IS
# CONFIGURED AGAINST, and that is singular by construction. The status bar, the statusline
# JSON, the CA-download page, the self-loop refusal, `CaptureStatus` and the live rebind all
# keep answering about it; the additional listeners here are an INVENTORY, never element 0 of
# a merged list. See #499 for the full argument, which is worth summarising because it is not
# what the original version of this comment claimed:
#
#   - The CA page and the self-loop refusal are ALREADY per-listener — both ride `self_addr`,
#     the accepting `Proxy::Server`'s own address (`server.cr:161-162`), and the page prefers
#     the concrete address the device reached (`client_conn.cr:1371-1373`). A plural model
#     would have regressed them from exactly right to right-on-average.
#   - The statusline `proxy` object and `CaptureStatus` are contracts read OUTSIDE this
#     process (a user's script; another gori instance's project picker). Turning either scalar
#     into an array breaks them for no new information — the statusline already solved this
#     shape additively when upstream routing stopped being singular.
#   - The `listen` chip is a CONTROL (a click toggles capture), so a plural chip would have no
#     defined click target.
#
# The asymmetry is real rather than cosmetic: gori can move the primary bind under the
# operator (`server.cr:63-75`, the fallback ladder), so it has to be announced. Every address
# in this array was typed here by the operator, so it only has to be confirmed.
module Gori::Settings
  # proxy       — an ordinary forward proxy: clients send absolute-form requests or CONNECT.
  #               Use it to expose a second address (e.g. a LAN interface for a phone) without
  #               widening the primary bind to 0.0.0.0.
  # transparent — the client believes it is talking to the origin. There is no CONNECT and no
  #               absolute-form target, so the destination is recovered per connection: the
  #               kernel's own record of what the client dialled before the redirect
  #               (`Proxy::OrigDst`) where it can be read, and the `Host` header / TLS SNI
  #               otherwise. Requires the kernel to redirect traffic here (pf / iptables
  #               REDIRECT). Where either mode would work, `reverse` is simpler: it DECLARES the
  #               destination and needs no kernel rule and no recovery at all.
  # reverse     — the client believes it is talking to the origin, and the origin is DECLARED
  #               (`origin`) rather than derived. Same pinned-destination path as transparent
  #               with none of the derivation's failure modes, and no kernel rule: the client
  #               just has to reach this socket. This is what makes gori usable against a
  #               client that cannot be pointed at a proxy at all.
  LISTENER_MODES = ["proxy", "transparent", "reverse"]

  # One additional listener. `target_port` is the port gori dials upstream for a TRANSPARENT
  # connection when the kernel will not say — the redirect rule's intent, declared, so the
  # listener taking redirected :443 traffic sets 443. Ignored in proxy mode.
  #
  # It is now ADVISORY rather than the only answer: `Proxy::OrigDst` reads the original
  # destination off the socket (SO_ORIGINAL_DST on Linux, a pf DIOCNATLOOK on macOS) and that
  # answer OUTRANKS this field, because it is the port the client actually dialled rather than a
  # description of the rule that redirected it. It still has to exist, and is still the only
  # answer, everywhere the lookup cannot reach: a platform with neither mechanism, a macOS gori
  # not running as root (`/dev/pf` is 0600 root:wheel), and a connection made straight to the
  # listener with no redirect in front of it.
  #
  # Kept REFUSED in every non-transparent mode below for the same reason as before: accepting it
  # silently would ignore the field. Advisory is not the same as meaningless.
  #
  # `origin` is the REVERSE listener's declared destination, as an absolute URL
  # ("https://api.example.com", "http://127.0.0.1:3000"). Deliberately NOT `target_port`
  # reused: that field answers a different question (which port a DERIVED host should be
  # dialled on) and `listener_error` already refuses it in the wrong mode rather than
  # ignoring it. Reusing it would have meant one field with two meanings selected by `mode`,
  # which is the thing that precedent exists to prevent.
  record Listener,
    host : String,
    port : Int32,
    mode : String = "proxy",
    target_port : Int32 = 0,
    origin : String = "",
    rewrite_host : Bool = false do
    def transparent? : Bool
      mode == "transparent"
    end

    def reverse? : Bool
      mode == "reverse"
    end

    # The upstream port for a transparent connection the kernel could not answer for, when the
    # derived host carries none. `tls` picks the sensible default so a plain `{host, port, mode}`
    # entry works for both halves of a redirect pair without the operator spelling out 80/443.
    def effective_target_port(tls : Bool) : Int32
      return target_port if target_port > 0
      tls ? 443 : 80
    end

    # `origin` split into {scheme, host, port}, or nil when it is absent or unusable.
    # One parse shared by validation, the Session wiring and the readout, so a string that
    # saves cannot then fail to dial — and so no two of them can disagree about which port
    # a scheme-only origin means.
    def origin_target : {String, String, Int32}?
      Settings.parse_origin(origin)
    end
  end

  # Parse a reverse listener's declared origin. Strict on purpose: an absolute URL with an
  # http/https scheme and a host, port optional (the scheme's default). A bare
  # "api.example.com:8443" is REFUSED rather than assumed http — the assumption would decide,
  # silently, whether gori speaks TLS to the operator's origin.
  def self.parse_origin(origin : String) : {String, String, Int32}?
    raw = origin.strip
    return nil if raw.empty?
    uri = URI.parse(raw)
    scheme = uri.scheme.try(&.downcase) || ""
    return nil unless scheme == "http" || scheme == "https"
    # Crystal's URI KEEPS the brackets on an IPv6 literal. Strip them: what comes out of here
    # is dialled (`TCPSocket.new` wants a bare address) and used as the SNI / leaf name, and
    # `BindAddress.authority` re-adds them wherever the host is displayed as an authority.
    host = unbracket(uri.host.try(&.strip) || "")
    return nil if host.empty?
    port = uri.port || (scheme == "https" ? 443 : 80)
    1 <= port <= 65535 ? {scheme, host, port} : nil
  rescue URI::Error
    nil
  end

  private def self.unbracket(h : String) : String
    h.starts_with?('[') && h.ends_with?(']') ? h[1...-1] : h
  end

  class_property listeners : Array(Listener) = [] of Listener

  # Tolerant parse, like every other section: an entry without a usable host/port is dropped, an
  # unknown mode is dropped rather than silently becoming "proxy" (which would expose an
  # unintended forward proxy on a LAN address), and a non-array node keeps the current value.
  private def self.parse_listeners(node : JSON::Any?) : Array(Listener)
    arr = node.try(&.as_a?)
    return listeners unless arr
    listeners_from(arr)
  end

  # The `listeners` section AS IT IS ON DISK RIGHT NOW. `Settings.listeners` is the copy read
  # at startup and never re-read, and the running sockets were built from THAT — so the two
  # disagreeing is exactly the #508 drift, and a settings save is one of the moments gori is
  # holding both halves.
  #
  # A missing key means an EMPTY section here, not "keep current" as the tolerant load path
  # has it: deleting every listener is a change the operator should hear about, and the load
  # rule exists to protect a running config from a partial file, which is not this question.
  # An unreadable or unparseable file falls back to "unchanged" — the corrupt-file warning is
  # `load_root`'s job and crying drift on top of it would just be noise.
  def self.disk_listeners : Array(Listener)
    disk_listeners? || listeners
  end

  # Same read, but distinguishing "the file could not be read or parsed" (nil) from "the
  # section is absent" (an empty array). The drift CHECK can fall back to "unchanged" on an
  # unreadable file, because all it decides is whether to say something. A RECONCILE cannot:
  # acting on that fallback would tear live sockets down and rebuild them because of a typo
  # somewhere else in the document.
  def self.disk_listeners? : Array(Listener)?
    return [] of Listener unless File.exists?(path)
    node = JSON.parse(File.read(path)).as_h?.try(&.[]?("listeners"))
    arr = node.try(&.as_a?)
    return [] of Listener unless arr
    listeners_from(arr)
  rescue
    nil
  end

  private def self.listeners_from(arr : Array(JSON::Any)) : Array(Listener)
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
      origin = o["origin"]?.try(&.as_s?).try(&.strip) || ""
      rewrite_host = o["rewrite_host"]?.try(&.as_bool?) || false
      out << Listener.new(host, port, mode, target, origin, rewrite_host)
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
            j.field "origin", l.origin unless l.origin.empty?
            j.field "rewrite_host", l.rewrite_host if l.rewrite_host
          end
        end
      end
    end
  end

  # nil if `listener` is usable; an error message otherwise. Checked at save time so a bad
  # address surfaces here rather than as an opaque bind failure on the next project open.
  #
  # `among` is the set the loop check reads as "gori's other configured sockets". It defaults
  # to `Settings.listeners` — the startup copy — but a live reconcile (#508) validates a set it
  # read from disk and deliberately did NOT write back over the class property, so it has to be
  # able to say which set it means. Writing it back would make the next `Settings.save` treat
  # `listeners` as a section this process changed, and its 3-way merge would then let our copy
  # WIN over a hand edit made in between — turning a fix for a silent no-op into a silent
  # clobber of the operator's own file.
  def self.listener_error(listener : Listener, among : Array(Listener) = listeners) : String?
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
    reverse_listener_error(listener, among)
  end

  # Same discipline as the target_port check above, for the reverse listener's two fields and
  # in BOTH directions: a missing origin cannot be defaulted (there is nothing to forward to),
  # and a present one in the wrong mode is a mode mistake rather than a field to drop.
  private def self.reverse_listener_error(listener : Listener, among : Array(Listener)) : String?
    unless listener.reverse?
      return "settings: origin only applies to a reverse listener" unless listener.origin.strip.empty?
      return "settings: rewrite_host only applies to a reverse listener" if listener.rewrite_host
      return nil
    end
    return "settings: a reverse listener needs an origin (e.g. \"https://api.example.com\")" if listener.origin.strip.empty?
    target = listener.origin_target
    return "settings: listener origin must be an absolute http(s) URL, e.g. \"https://api.example.com\"" unless target
    # `listener` first, then the rest: an entry is normally IN `Settings.listeners` when it is
    # validated, but `listener_error` is also called on a candidate that is not yet (and the
    # tightest loop of all — an origin naming this listener's own socket — would be the one
    # missed if this relied on the array alone).
    if self_target?(target[1], target[2], listener, among)
      return "settings: listener origin #{listener.origin} points back at gori itself (forwarding loop)"
    end
    nil
  end

  # True when dialing `host:port` would land back on a socket gori is serving — the primary
  # bind or any configured listener. A reverse listener's destination is CONFIGURED, so unlike
  # the transparent/forward cases this loop is one an operator creates by typing, and it is
  # detectable here rather than only once traffic arrives.
  #
  # Best-effort in exactly the way `same_bind_host?` is (which is what this reuses, so the
  # wildcard and localhost-alias spellings fold the same way here as they do there): NO name
  # resolution, so an origin hostname that happens to resolve to the bind escapes this. The
  # per-connection `Upstream.loops_to_self?` backstop covers the residue for a reverse listener
  # whose origin names ITS OWN port; a cross-port loop through a hostname is not caught by
  # either, and would surface as the 2048-connection wedge described in `upstream.cr:100-119`.
  private def self.self_target?(host : String, port : Int32, own : Listener,
                                among : Array(Listener)) : Bool
    return true if port == own.port && same_bind_host?(host, own.host)
    return true if port == effective_bind_port && same_bind_host?(host, effective_bind_host)
    among.any? { |l| l.port == port && same_bind_host?(host, l.host) }
  end

  # The upstream port a transparent connection should use WHEN THE SOCKET CANNOT SAY: the
  # listener's configured target_port when set, else the conventional port for the protocol.
  # One helper so the cleartext and TLS branches of the transparent path cannot disagree —
  # `Proxy::Server#transparent_dst` now holds the same property one level up, reading the
  # kernel's answer once per connection and handing the SAME one to both branches.
  def self.listener_target_port(configured : Int32, tls : Bool) : Int32
    return configured if configured > 0
    tls ? 443 : 80
  end

  # Every additional listener that passes validation, with duplicates of the PRIMARY bind
  # removed — binding the same address twice would fail, and the operator would be left with
  # a listener error about an address they can see is configured exactly once.
  def self.valid_listeners(among : Array(Listener) = listeners) : Array(Listener)
    among.reject do |l|
      !listener_error(l, among).nil? || (l.port == effective_bind_port && same_bind_host?(l.host, effective_bind_host))
    end
  end

  # The listeners `valid_listeners` DROPPED for being unusable, each with its reason.
  # Dropping is right — an unusable entry must not become a socket — but dropping silently is
  # not: the operator's only other signal is that traffic never arrives. Session seeds its
  # `listener_errors` from this so a rejected entry reads the same as one that failed to bind.
  def self.listener_config_errors(among : Array(Listener) = listeners) : Array(String)
    among.compact_map do |l|
      if err = listener_error(l, among)
        "#{BindAddress.authority(l.host, l.port)} — #{err.lchop("settings: ")}"
      end
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
