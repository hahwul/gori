module Gori::Proxy::Codec
  # A single header as it appeared on the wire (original case preserved).
  # Truth lives in the owning message's `raw_head`; this is a parsed projection
  # used for body-framing decisions and for the History detail view.
  struct Header
    getter name : String
    getter value : String

    def initialize(@name : String, @value : String)
    end
  end

  # Ordered, case-preserving header collection with case-insensitive lookup.
  # Order and original casing are kept so the projection mirrors the wire;
  # lookups are case-insensitive per RFC 7230.
  struct HeaderList
    include Enumerable(Header)

    getter entries : Array(Header)

    def initialize(@entries : Array(Header) = [] of Header)
    end

    def each(& : Header ->)
      @entries.each { |h| yield h }
    end

    def <<(header : Header) : self
      @entries << header
      self
    end

    def size : Int32
      @entries.size
    end

    # Last value for a header name (case-insensitive), or nil. Uses an
    # allocation-free case-insensitive compare (the proxy hot path does ~5–6 of
    # these per request/response; `name.downcase`/`h.name.downcase` otherwise
    # allocated a String per header per lookup — see codec_bench).
    def get?(name : String) : String?
      @entries.reverse_each { |h| return h.value if h.name.compare(name, case_insensitive: true) == 0 }
      nil
    end

    # All values for a header name (case-insensitive), in wire order.
    def get_all(name : String) : Array(String)
      result = [] of String
      @entries.each { |h| result << h.value if h.name.compare(name, case_insensitive: true) == 0 }
      result
    end

    # Whether any header carries this name (case-insensitive), allocation-free. Lets the
    # framing hot path skip `get_all` — which always allocates an Array even when the
    # header is absent — for the common no-Transfer-Encoding / no-Content-Length message.
    def has?(name : String) : Bool
      @entries.any? { |h| h.name.compare(name, case_insensitive: true) == 0 }
    end

    # Does the LIST-valued field `name` carry `token` as one of its members? Case-insensitive
    # on both halves, and across EVERY field line of that name.
    #
    # That last part is the whole reason this exists rather than `get?(name).split(',')` at each
    # caller. RFC 9110 §5.3 makes repeated field lines of a list-valued field exactly equivalent
    # to one comma-joined line, so `Connection: close` + `Connection: keep-alive` carries BOTH —
    # while `get?` returns the LAST line only, and the token an answer turns on can sit in an
    # earlier one. Two callers ask this question — `Connection` on both keep-alive decisions,
    # and the WebSocket handshake's `Upgrade` — and each reads a token whose presence decides
    # what gori does with the socket. (`Repeater::ConnPool#connection_token?` and
    # `Probe::Passive::Tech#websocket?` still carry copies of it; they belong to other
    # subsystems and are named here so the next reader finds them.)
    #
    # Allocation-free on the miss, which is the common case for both: the whole point of asking
    # `Connection` per message is that most messages carry no such token.
    def lists?(name : String, token : String) : Bool
      @entries.any? do |h|
        h.name.compare(name, case_insensitive: true) == 0 && HeaderList.list_member?(h.value, token)
      end
    end

    # Is `token` one of `value`'s comma-separated members, with OWS trimmed? Byte-wise over the
    # value so a long `Connection`/`Upgrade` field costs no Array and no per-member String.
    protected def self.list_member?(value : String, token : String) : Bool
      bytes = value.to_slice
      start = 0
      pos = 0
      while pos <= bytes.size
        if pos == bytes.size || bytes.unsafe_fetch(pos) == 0x2c_u8 # ',' — or the value's end
          return true if member_equals?(bytes, start, pos, token)
          start = pos + 1
        end
        pos += 1
      end
      false
    end

    # `bytes[from...to]`, OWS-trimmed, compared to `token` (ASCII case-insensitive).
    private def self.member_equals?(bytes : Bytes, from : Int32, to : Int32, token : String) : Bool
      while from < to && ows?(bytes.unsafe_fetch(from))
        from += 1
      end
      while to > from && ows?(bytes.unsafe_fetch(to - 1))
        to -= 1
      end
      return false unless to - from == token.bytesize
      needle = token.to_slice
      (to - from).times do |i|
        return false unless lower(bytes.unsafe_fetch(from + i)) == lower(needle.unsafe_fetch(i))
      end
      true
    end

    private def self.lower(b : UInt8) : UInt8
      b >= 0x41_u8 && b <= 0x5a_u8 ? b | 0x20_u8 : b # ASCII 'A'..'Z'
    end

    private def self.ows?(b : UInt8) : Bool
      b == 0x20_u8 || b == 0x09_u8
    end
  end

  # A captured HTTP/1.1 request. `raw_head` is the byte-exact request-line +
  # headers + terminating CRLFCRLF — the single source of truth (P7). The
  # remaining fields are parsed projections; forwarding writes `raw_head`
  # verbatim, never a re-serialization.
  struct RawRequest
    getter raw_head : Bytes
    getter method : String
    getter target : String
    getter version : String
    getter headers : HeaderList
    getter? malformed : Bool

    def initialize(@raw_head : Bytes, @method : String, @target : String,
                   @version : String, @headers : HeaderList, @malformed : Bool = false)
    end

    def host? : String?
      headers.get?("Host")
    end

    # The raw request-line as it arrived, up to (but excluding) the first CR/LF.
    # `method`/`target`/`version` come from split(' '), which mis-slices a malformed line
    # (an unencoded space ⇒ >3 tokens): target is truncated and version is a garbage token.
    # This returns the honest whole line for the stored projection (FlowMapper), mirroring
    # the first-line scan in client_conn#rewrite_request_line.
    def request_line : String
      nl = raw_head.index(0x0a_u8)
      line = nl ? raw_head[0, nl] : raw_head
      line = line[0, line.size - 1] if line.size > 0 && line.unsafe_fetch(line.size - 1) == 0x0d_u8
      String.new(line)
    end
  end

  # A captured HTTP/1.1 response. Same truth/projection split as RawRequest.
  struct RawResponse
    getter raw_head : Bytes
    getter version : String
    getter status : Int32
    getter reason : String
    getter headers : HeaderList
    getter? malformed : Bool

    def initialize(@raw_head : Bytes, @version : String, @status : Int32,
                   @reason : String, @headers : HeaderList, @malformed : Bool = false)
    end
  end
end
