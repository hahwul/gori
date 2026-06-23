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
