module Gori::Proxy::Tls
  # Reads the destination hostname out of a TLS ClientHello, for the TRANSPARENT listener.
  #
  # On the normal proxy path the destination arrives in a `CONNECT host:port` line, so gori
  # knows the name before any handshake. A transparent listener gets no such line — the client
  # believes it is talking to the origin — and the only name on the wire is the SNI extension.
  # It has to be read BEFORE the handshake, because everything downstream keys on knowing the
  # host first: which leaf certificate to mint, the sandbox gate, the TLS passthrough list, and
  # the origin ALPN probe.
  #
  # Parsed here rather than through OpenSSL's servername callback for exactly that reason: the
  # callback fires mid-handshake, by which point the decisions above have already been made.
  module ClientHello
    # A ClientHello must fit one TLS record, and a record body is capped at 2^14 by RFC 8446.
    # Reading past that is a malformed peer, not a big handshake — and an unbounded read here
    # would be a memory-DoS on an unauthenticated connection.
    MAX_RECORD             =  16_384
    RECORD_HANDSHAKE       = 0x16_u8
    HANDSHAKE_CLIENT_HELLO = 0x01_u8
    EXT_SERVER_NAME        =  0x0000
    SNI_HOST_NAME          = 0x00_u8

    # Peek a ClientHello off `io` and return {sni, consumed}. `consumed` is every byte read, so
    # the caller can replay them into a PrefixIO and hand the stream on untouched — this must
    # never swallow bytes, or the handshake it is inspecting would break.
    #
    # `sni` is nil when the record is not a ClientHello, carries no SNI (an IP-literal target,
    # or an old client), or is malformed. The caller decides what to do about that; parsing
    # never raises, because this runs on an accepted socket before any authentication.
    def self.peek_sni(io : IO) : {String?, Bytes}
      header = Bytes.new(5)
      return {nil, Bytes.empty} unless io.read_fully?(header)
      # Record header: type(1) legacy_version(2) length(2).
      length = (header[3].to_i << 8) | header[4].to_i
      return {nil, header} unless header[0] == RECORD_HANDSHAKE && length > 0 && length <= MAX_RECORD

      body = Bytes.new(length)
      got = read_available(io, body)
      # A SHORT record: hand back only the bytes that genuinely arrived. Returning the whole
      # buffer would replay zero padding the peer never sent and corrupt the stream — the
      # failure mode this function exists to avoid.
      return {nil, concat(header, body[0, got])} if got < length
      {parse_sni(body), concat(header, body)}
    end

    # Fill as much of `buf` as the peer sends, returning the byte count. IO#read_fully? cannot
    # be used here: it reports failure without saying how much it consumed, and those bytes are
    # exactly what the caller must replay.
    private def self.read_available(io : IO, buf : Bytes) : Int32
      total = 0
      while total < buf.size
        n = io.read(buf[total, buf.size - total])
        break if n == 0
        total += n
      end
      total
    end

    private def self.concat(a : Bytes, b : Bytes) : Bytes
      joined = Bytes.new(a.size + b.size)
      a.copy_to(joined)
      b.copy_to(joined[a.size, b.size])
      joined
    end

    # The SNI host from a handshake record body, or nil. Every step is bounds-checked against
    # the slice: a truncated or hostile ClientHello must yield nil, never an exception on the
    # accept path and never a read past the buffer.
    private def self.parse_sni(body : Bytes) : String?
      r = Reader.new(body)
      return nil unless r.u8 == HANDSHAKE_CLIENT_HELLO
      return nil unless r.skip(3)     # handshake length (24-bit)
      return nil unless r.skip(2)     # legacy_version
      return nil unless r.skip(32)    # random
      return nil unless r.skip_vec(1) # legacy_session_id
      return nil unless r.skip_vec(2) # cipher_suites
      return nil unless r.skip_vec(1) # legacy_compression_methods
      ext_total = r.u16
      return nil unless ext_total # no extensions at all (pre-SNI client)
      parse_extensions(r, ext_total)
    end

    private def self.parse_extensions(r : Reader, total : Int32) : String?
      stop = r.pos + total
      while r.pos < stop
        type = r.u16
        size = r.u16
        return nil unless type && size
        if type == EXT_SERVER_NAME
          data = r.take(size)
          return data ? parse_server_name_list(data) : nil
        end
        return nil unless r.skip(size)
      end
      nil
    end

    # server_name_list: list_length(2) then entries of type(1) length(2) value. Only
    # host_name (0) is defined, and in practice there is exactly one entry.
    private def self.parse_server_name_list(data : Bytes) : String?
      r = Reader.new(data)
      list_len = r.u16
      return nil unless list_len
      stop = {r.pos + list_len, data.size}.min
      while r.pos < stop
        kind = r.u8
        size = r.u16
        return nil unless kind && size
        value = r.take(size)
        return nil unless value
        next unless kind == SNI_HOST_NAME
        name = String.new(value)
        # A name gori is going to mint a certificate for and dial: reject anything that is not
        # a plausible DNS name rather than passing odd bytes into the cert builder and the
        # scope gate. Also drops the empty-SNI case.
        return nil unless name.matches?(/\A[A-Za-z0-9]([A-Za-z0-9.\-_]*[A-Za-z0-9])?\z/)
        return name.downcase
      end
      nil
    end

    # A bounds-checked cursor over the handshake bytes. Every accessor returns nil past the
    # end instead of raising, so one `return nil unless` per field is the whole error handling.
    private struct Reader
      getter pos : Int32

      def initialize(@buf : Bytes)
        @pos = 0
      end

      def u8 : UInt8?
        return nil if @pos >= @buf.size
        v = @buf[@pos]
        @pos += 1
        v
      end

      def u16 : Int32?
        return nil if @pos + 1 >= @buf.size
        v = (@buf[@pos].to_i << 8) | @buf[@pos + 1].to_i
        @pos += 2
        v
      end

      def skip(n : Int32) : Bool
        return false if n < 0 || @pos + n > @buf.size
        @pos += n
        true
      end

      def take(n : Int32) : Bytes?
        return nil if n < 0 || @pos + n > @buf.size
        slice = @buf[@pos, n]
        @pos += n
        slice
      end

      # Skip a length-prefixed vector whose length field is `len_bytes` wide.
      def skip_vec(len_bytes : Int32) : Bool
        n = case len_bytes
            when 1 then u8.try(&.to_i)
            when 2 then u16
            end
        n ? skip(n) : false
      end
    end
  end
end
