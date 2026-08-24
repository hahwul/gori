require "socket"
require "./codec/http1"

module Gori::Proxy
  # The SOCKS5 wire vocabulary (RFC 1928, plus RFC 1929 username/password auth), and the SERVER
  # half of the handshake.
  #
  # gori speaks both ends of this protocol and they must not drift: `Upstream.dial_via_socks5`
  # reaches an origin THROUGH someone else's SOCKS5 proxy (`ssh -D`, Tor, a jump host), and a
  # `socks5` listener IS one for a client that cannot be pointed at an HTTP proxy. The constants
  # and the address encoding live here so that the two halves cannot disagree about what a byte
  # means — the same reason `Codec::Http1` owns the framing predicates both directions test.
  module Socks5
    VERSION = 5_u8

    # Method-selection (§3). gori's listener offers NO-AUTH and nothing else: the forward-proxy
    # listener beside it has no authentication either, and a SOCKS listener that asked for a
    # password would be claiming an access control the rest of the process does not have. A
    # client that offers no acceptable method is told so with 0xFF and closed.
    AUTH_NONE         =    0_u8
    AUTH_USERPWD      =    2_u8
    AUTH_UNACCEPTABLE = 0xff_u8

    # Commands (§4). CONNECT is the only one gori can serve: BIND needs a listening socket on
    # the client's behalf, and UDP ASSOCIATE is a datagram relay — which is the same reason
    # HTTP/3 is out of reach (every listener here is a TCP socket). Both are refused with the
    # code the RFC defines rather than by hanging up, so the client reports the real cause.
    CMD_CONNECT       = 1_u8
    CMD_BIND          = 2_u8
    CMD_UDP_ASSOCIATE = 3_u8

    ATYP_IPV4   = 1_u8
    ATYP_DOMAIN = 3_u8
    ATYP_IPV6   = 4_u8

    # RFC 1928 caps a domain name at one length byte, and RFC 1929 caps each credential the
    # same way. A longer value cannot be encoded, so a request carrying one fails rather than
    # being truncated into a request for a DIFFERENT host than was asked for.
    MAX_FIELD = 255

    # Reply codes (§6). Only the ones gori can actually produce are named.
    REP_SUCCEEDED          = 0_u8
    REP_GENERAL_FAILURE    = 1_u8
    REP_NOT_ALLOWED        = 2_u8
    REP_CMD_NOT_SUPPORTED  = 7_u8
    REP_ATYP_NOT_SUPPORTED = 8_u8

    # What a client asked gori to reach. `host` is the DOMAIN name when the client sent one,
    # which is the whole reason this listener is worth having: the destination arrives named,
    # so nothing downstream has to recover it from an SNI or a `Host` header the way the
    # transparent path does.
    record Target, host : String, port : Int32

    # Read exactly `n` bytes, or nil on EOF/short read — every SOCKS field is fixed-length, so a
    # partial read is a protocol failure, not something to proceed past.
    def self.read_exactly(io : IO, n : Int32) : Bytes?
      return Bytes.empty if n == 0
      buf = Bytes.new(n)
      io.read_fully?(buf) ? buf : nil
    end

    # An IP literal's network-order bytes: 4 for IPv4, 16 for IPv6. IPv4 is read off the
    # canonical dotted text; IPv6 is copied out of the sockaddr the OS already parsed, rather
    # than re-implementing "::" expansion here (in6_addr is exactly the 16 address bytes).
    def self.address_bytes(ip : Socket::IPAddress) : Bytes
      return ipv4_bytes(ip) if ip.family == Socket::Family::INET
      ipv6_bytes(ip)
    end

    private def self.ipv4_bytes(ip : Socket::IPAddress) : Bytes
      out = Bytes.new(4)
      ip.address.split('.').each_with_index { |octet, i| out[i] = octet.to_u8 }
      out
    end

    private def self.ipv6_bytes(ip : Socket::IPAddress) : Bytes
      addr = ip.to_unsafe.as(Pointer(LibC::SockaddrIn6)).value.sin6_addr
      ptr = pointerof(addr).as(Pointer(UInt8))
      out = Bytes.new(16)
      16.times { |i| out[i] = ptr[i] }
      out
    end

    # What one handshake produced: the target the client asked for, or the sentence explaining
    # why it was refused. Exactly one is non-nil. A refusal has ALREADY been answered on the
    # wire in the form the RFC defines where there was one to send; the sentence is for the
    # operator, who otherwise gets a connection that closed for no stated reason.
    record Negotiation, target : Target?, refusal : String?, silent : Bool = false,
      timed_out : Bool = false do
      # Did the client say ANYTHING — was there a greeting at all? Its own answer, because a
      # caller has to tell "a client did something gori refuses" (worth recording on the
      # project) from "a TCP connection opened and went nowhere" (a port scan, a health check,
      # a speculative preconnect — which every other listener mode records nothing for).
      def silent? : Bool
        silent
      end

      # Silent AND still holding the socket open — the #755 shape, and a different fact from a
      # silent client that HUNG UP. One is a peer waiting for a banner gori will never send
      # (server-speaks-first on a port somebody redirected here), which is worth a flow; the
      # other is a scan, which is not. Only ever true beside `silent`.
      def timed_out? : Bool
        timed_out
      end
    end

    # --- the SERVER half ---------------------------------------------------------------
    #
    # Method negotiation, then one CONNECT request. This deliberately does NOT answer a
    # successful request: the caller has checks of its own to make (a target naming gori's own
    # listener is the obvious one) and `succeeded` is unsendable once retracted. Call `grant`
    # when the target is acceptable, `refuse` when it is not.
    #
    # A read that TIMES OUT is answered here rather than raised at the caller, and the point of
    # that is the GREETING: a peer that connects and says nothing at all is the #755 shape and
    # gets its own flow, while one that stops part-way through a handshake it started is a
    # client doing something — two different records. Raised out of here, both arrived at the
    # caller as one `IO::TimeoutError` and were filed as the first, so a client that had sent a
    # greeting and a method list was recorded as never having spoken.
    def self.negotiate(io : IO, bind : Socket::IPAddress?) : Negotiation
      greeting =
        begin
          read_exactly(io, 2)
        rescue IO::TimeoutError
          return Negotiation.new(nil, "the client opened a connection to this SOCKS5 listener " \
                                      "and sent no greeting", silent: true, timed_out: true)
        end
      unless greeting
        return Negotiation.new(nil, "the client closed before sending a SOCKS5 greeting", silent: true)
      end
      unless greeting[0] == VERSION
        return refused("this is a SOCKS5 listener and the connection opened with version " \
                       "#{greeting[0]}, not 5. Nothing was read past that byte")
      end
      methods = read_exactly(io, greeting[1].to_i)
      return refused("the client closed in the middle of its SOCKS5 method list") unless methods
      unless methods.includes?(AUTH_NONE)
        # Not a refusal REPLY: the client has not sent a request yet, and §3 answers a greeting
        # with a method selection. 0xFF is that answer.
        io.write(Bytes[VERSION, AUTH_UNACCEPTABLE])
        io.flush
        return refused("the client offered no authentication method gori serves. This listener " \
                       "offers NO-AUTH only, like the HTTP proxy listener beside it")
      end
      io.write(Bytes[VERSION, AUTH_NONE])
      io.flush
      request(io, bind)
    rescue IO::TimeoutError
      # PAST the greeting, so this client is not silent: it opened a SOCKS5 handshake and then
      # stopped part-way through one. On the record like every other refusal where the client
      # actually said something.
      refused("the client stopped part-way through the SOCKS5 handshake and sent no more")
    end

    # VER CMD RSV ATYP DST.ADDR DST.PORT (§4).
    private def self.request(io : IO, bind : Socket::IPAddress?) : Negotiation
      head = read_exactly(io, 4)
      return refused("the client closed before sending a SOCKS5 request") unless head
      return refused("the SOCKS5 request named version #{head[0]}, not 5") unless head[0] == VERSION
      if unserved = unserved_request(io, head, bind)
        return unserved
      end
      host = read_address(io, head[3])
      # A known type that would not read: the client stopped mid-address. Distinct from the
      # refusal above, and it must stay distinct — "your client hung up" and "gori does not
      # speak that" send an operator to two different places.
      return refused("the client closed in the middle of the SOCKS5 destination address") if host.nil?
      port_bytes = read_exactly(io, 2)
      return refused("the client closed before sending the SOCKS5 destination port") unless port_bytes
      port = (port_bytes[0].to_i << 8) | port_bytes[1].to_i
      if host.empty? || port == 0
        refuse(io, REP_GENERAL_FAILURE, bind)
        return refused("the SOCKS5 request named #{host.inspect}:#{port}, which is not a destination")
      end
      # The DOMAIN form is a client-chosen byte string with only a length byte behind it, and it
      # becomes this connection's `fixed_host`: the name gori dials, records on every flow and
      # gates the Sandbox on. `request_token_safe?` is the one home for "may these bytes be a
      # single token" (#390/#394/#397) — a name carrying SP, CR, LF, NUL or DEL is not a host by
      # any reading, and refusing it here is cheaper than discovering which of those three
      # consumers minds first.
      unless Codec::Http1.request_token_safe?(host)
        refuse(io, REP_GENERAL_FAILURE, bind)
        return refused("the SOCKS5 request named a destination carrying a byte no host can " \
                       "hold (space, CR, LF, NUL or DEL): #{host.inspect}")
      end
      Negotiation.new(Target.new(host, port), nil)
    end

    # The two things about a request gori settles before reading a byte more of it: whether it
    # can read the address at all, and whether it serves the command. Non-nil means the refusal
    # has gone out and the caller is done with this connection.
    private def self.unserved_request(io : IO, head : Bytes, bind : Socket::IPAddress?) : Negotiation?
      # The address type comes FIRST, because it is what decides how many bytes the rest of the
      # request occupies. An undefined one leaves the stream unreadable — there is no length to
      # skip — so nothing after this point can be trusted, including the drain the command
      # refusal below would otherwise do.
      unless head[3] == ATYP_IPV4 || head[3] == ATYP_IPV6 || head[3] == ATYP_DOMAIN
        refuse(io, REP_ATYP_NOT_SUPPORTED, bind)
        return refused("the SOCKS5 request used address type #{head[3]}, which RFC 1928 does " \
                       "not define — its length is unknown, so nothing further could be read")
      end
      return nil if head[1] == CMD_CONNECT
      # The address is still read off the socket before the refusal goes out, or the reply lands
      # in the middle of a request the client is still sending.
      read_address(io, head[3])
      refuse(io, REP_CMD_NOT_SUPPORTED, bind)
      named = case head[1]
              when CMD_BIND          then "BIND"
              when CMD_UDP_ASSOCIATE then "UDP ASSOCIATE"
              else                        "command #{head[1]}"
              end
      refused("gori's SOCKS5 listener serves CONNECT only, and this request asked for " \
              "#{named}. BIND needs a socket opened on the client's behalf and UDP ASSOCIATE " \
              "is a datagram relay — every listener gori has is a TCP socket")
    end

    private def self.refused(reason : String) : Negotiation
      Negotiation.new(nil, reason)
    end

    # Answer `succeeded`. gori sends this BEFORE it has dialled anything, deliberately, and
    # exactly as the CONNECT path does one protocol over (`Tunnel#intercept` writes
    # `200 Connection Established` and then peeks). The destination is not dialled until gori
    # knows what the client is going to say to it: whether the host is on the passthrough list,
    # whether the Sandbox refuses it, whether it is TLS or h2c or plain HTTP. A dial that then
    # fails lands on the flow as an error, which is where an operator reads it — the same
    # answer, in the same place, as every other listener mode gives.
    def self.grant(io : IO, bind : Socket::IPAddress?) : Nil
      reply(io, REP_SUCCEEDED, bind)
    end

    # :ditto: for a target the caller decided against.
    def self.refuse(io : IO, code : UInt8, bind : Socket::IPAddress?) : Nil
      reply(io, code, bind)
    end

    # DST.ADDR for `atyp`, as text, or nil when it could not be read. The caller has already
    # settled that `atyp` is one of the three §4 defines, so nil here means a short read and
    # nothing else.
    #
    # A literal is spelled by `Socket::IPAddress` and not by hand: gori compares hosts as TEXT
    # in several places that matter (the Sandbox, `Settings.tls_passthrough?`, the store's host
    # column, the History filter), so `0:0:0:0:0:0:0:1` and `::1` being the same address is not
    # something any of them would notice. An IPv6 literal comes back BRACKETED on top of that,
    # because every caller downstream reads a host as a URL authority and a bare `::1` there is
    # ambiguous with the port separator.
    private def self.read_address(io : IO, atyp : UInt8) : String?
      case atyp
      when ATYP_IPV4
        read_exactly(io, 4).try { |b| Socket::IPAddress.v4(b[0], b[1], b[2], b[3], port: 0).address }
      when ATYP_IPV6
        read_exactly(io, 16).try do |b|
          g = StaticArray(UInt16, 8).new { |i| (b[i * 2].to_u16 << 8) | b[i * 2 + 1] }
          "[#{Socket::IPAddress.v6(g[0], g[1], g[2], g[3], g[4], g[5], g[6], g[7], port: 0).address}]"
        end
      when ATYP_DOMAIN
        len = read_exactly(io, 1) || return nil
        read_exactly(io, len[0].to_i).try { |b| String.new(b) }
      end
    end

    # VER REP RSV ATYP BND.ADDR BND.PORT. `bind` is the address the client reached gori on,
    # which is what §6 asks for; clients overwhelmingly ignore it, but a wrong LENGTH here
    # desyncs the stream, so the address type and its bytes must agree. Nil `bind` — a socket
    # whose local address could not be read — emits the all-zero IPv4 form every implementation
    # accepts as "unspecified".
    private def self.reply(io : IO, code : UInt8, bind : Socket::IPAddress?) : Nil
      io.write(Bytes[VERSION, code, 0_u8])
      if bind && bind.family == Socket::Family::INET6
        io.write(Bytes[ATYP_IPV6])
        io.write(address_bytes(bind))
      elsif bind
        io.write(Bytes[ATYP_IPV4])
        io.write(address_bytes(bind))
      else
        io.write(Bytes[ATYP_IPV4, 0_u8, 0_u8, 0_u8, 0_u8])
      end
      port = bind.try(&.port) || 0
      io.write(Bytes[(port >> 8).to_u8, (port & 0xFF).to_u8])
      io.flush
    end
  end
end
