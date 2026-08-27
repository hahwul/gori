require "digest/md5"
require "digest/sha256"
require "openssl"
require "./client_hello"

module Gori::Proxy::Tls
  # JA3 and JA4 fingerprints of a TLS ClientHello — WHAT AN ORIGIN SEES when gori dials it.
  #
  # This exists because `outbound_tls` is otherwise unverifiable. An operator sets `groups`
  # and `alpn` to look less like a proxy and more like a browser, and has no way to check
  # whether any of it reached the wire: OpenSSL reports the NEGOTIATED result, never the offer
  # it made. Anti-bot stacks judge the offer. So the offer is what has to be shown.
  #
  # Two halves:
  #
  #   * `parse` + `ja3` / `ja4` — pure functions over ClientHello bytes, from wherever they come.
  #   * `of_context` — the bytes themselves, obtained by letting OpenSSL write ONE ClientHello
  #     from a real `SSL_CTX` into memory (see there for why that is the honest way to ask).
  #
  # Algorithms implemented to the published specifications, not to a local reading of them:
  # JA3 per salesforce/ja3 (MD5 over five decimal fields) and JA4 per FoxIO-LLC/ja4
  # (`t13d1516h2_8daaf6152771_e5627efa2ab1`). The spec's own worked example is a spec case
  # (`spec/proxy/tls_fingerprint_spec.cr`) rather than a fixture of gori's own making — a
  # hand-built expectation would only prove this file agrees with itself.
  module Fingerprint
    # A parsed ClientHello reduced to the fields the two fingerprints read. GREASE values
    # (RFC 8701) are stripped on the way in, everywhere, because BOTH specs require it and a
    # GREASE value left in any one list would change the fingerprint on every connection —
    # OpenSSL picks them at random per handshake.
    struct Hello
      getter legacy_version : Int32
      getter ciphers : Array(Int32)
      # Extension types IN OFFER ORDER. Order is JA3's whole signal; JA4 sorts its own copy.
      getter extensions : Array(Int32)
      getter groups : Array(Int32)
      getter point_formats : Array(Int32)
      # signature_algorithms, in offer order (JA4 hashes these UNSORTED — see the spec).
      getter sig_algs : Array(Int32)
      getter supported_versions : Array(Int32)
      getter alpn : Array(Bytes)
      getter? sni : Bool

      def initialize(@legacy_version, @ciphers, @extensions, @groups, @point_formats,
                     @sig_algs, @supported_versions, @alpn, @sni)
      end
    end

    # Everything gori can say about one ClientHello. `ja3_text` and `ja4_r` are carried
    # alongside the digests deliberately: a hash an operator cannot decompose is not evidence,
    # and the raw forms are what let them see WHICH field their setting moved.
    struct Report
      getter ja3_text : String
      getter ja3 : String
      getter ja4 : String
      getter ja4_r : String

      def initialize(@ja3_text, @ja3, @ja4, @ja4_r)
      end
    end

    RECORD_HANDSHAKE       = 0x16_u8
    HANDSHAKE_CLIENT_HELLO = 0x01_u8

    EXT_SERVER_NAME        = 0x0000
    EXT_SUPPORTED_GROUPS   = 0x000a
    EXT_EC_POINT_FORMATS   = 0x000b
    EXT_SIG_ALGS           = 0x000d
    EXT_ALPN               = 0x0010
    EXT_SUPPORTED_VERSIONS = 0x002b

    # A RECORD body is capped at 2^14 (RFC 8446), and a ClientHello big enough to need more
    # than a handful of them is not one gori produced. Bounds the reassembly below so hostile
    # bytes can never make this allocate without limit.
    MAX_HELLO = 64 * 1024

    # Report for `bytes`, or nil when they are not a parseable ClientHello. Never raises: the
    # inbound caller hands it unauthenticated wire bytes.
    def self.report(bytes : Bytes) : Report?
      hello = parse(bytes) || return nil
      report(hello)
    end

    def self.report(hello : Hello) : Report
      text = ja3_text(hello)
      a, b, c = ja4_parts(hello)
      Report.new(text, Digest::MD5.hexdigest(text),
        "#{a}_#{truncated_sha256(b, b.empty?)}_#{truncated_sha256(c, ja4_c_extensions(hello).empty?)}",
        "#{a}_#{b}_#{c}")
    end

    # ── capture ────────────────────────────────────────────────────────────────────────────

    # The ClientHello `ctx` produces, obtained by handing OpenSSL an IO that records what it
    # writes and reports EOF on every read. `SSL_connect`'s first act is to emit the
    # ClientHello; the EOF that follows fails the handshake, which is the point — the bytes
    # are already captured by then and no socket, fd, listener or origin was involved.
    #
    # Why this and not a tap on the production socket: the hello is a pure function of the
    # SSL_CTX plus whether a hostname was set, and every gori dial sets one. Two connections
    # from the same context differ only in the client random, the fake session id and the SNI
    # VALUE — and none of those three appears in JA3 or JA4. So the bytes below are the same
    # bytes the origin sees, obtained without threading a wrapper IO through the proxy's hot
    # path (which would also silently disable KTLS and change what the connection-pool
    # checkout probe can see).
    #
    # It is NOT a re-derivation from settings: OpenSSL builds the hello, so extension order,
    # GREASE placement and every default gori never configured are the library's own.
    def self.of_context(ctx : OpenSSL::SSL::Context::Client,
                        hostname : String = "fingerprint.probe.invalid") : Report?
      report(hello_bytes(ctx, hostname))
    end

    # The raw ClientHello `ctx` writes. Separate from `of_context` so a spec can assert on the
    # bytes rather than only on a digest of them.
    def self.hello_bytes(ctx : OpenSSL::SSL::Context::Client,
                         hostname : String = "fingerprint.probe.invalid") : Bytes
      sink = HelloSink.new
      begin
        # sync_close: false — `sink` is ours and holds no fd; nothing to hand over.
        OpenSSL::SSL::Socket::Client.new(sink, context: ctx, sync_close: false, hostname: hostname)
      rescue
        # Expected: the peer (a memory buffer) never answers. Any OTHER failure — a context
        # OpenSSL refuses to start a handshake from — also lands here, and is reported as
        # "no fingerprint" by the empty/short slice rather than as an exception thrown at a
        # settings screen.
      end
      sink.written
    end

    # An IO that swallows writes into a buffer and is permanently at EOF. Deliberately NOT
    # `IO::Memory`: a memory IO would let OpenSSL READ BACK its own ClientHello as if it were
    # the server's answer, and the handshake would then fail somewhere much less predictable.
    private class HelloSink < IO
      @buf = IO::Memory.new

      def read(slice : Bytes) : Int32
        0
      end

      def write(slice : Bytes) : Nil
        # Stop accumulating past the cap — a context that somehow streams forever must not
        # grow this buffer without bound.
        @buf.write(slice) if @buf.bytesize < MAX_HELLO
      end

      def written : Bytes
        @buf.to_slice
      end
    end

    # ── parsing ────────────────────────────────────────────────────────────────────────────

    # Parse a ClientHello from either a TLS record stream (`0x16 …`, one or more records) or a
    # bare handshake message (`0x01 …`). Both forms occur: the capture above yields records,
    # while a caller that already stripped framing has the message. nil on anything malformed.
    def self.parse(bytes : Bytes) : Hello?
      body = bytes.empty? ? bytes : (bytes[0] == RECORD_HANDSHAKE ? handshake_payload(bytes) : bytes)
      return nil if body.empty?
      parse_handshake(body)
    rescue
      # Bounds are checked per field below, but a parser over hostile bytes must not be able
      # to take down the caller through a path that was missed.
      nil
    end

    # Concatenate the payloads of consecutive handshake records. A ClientHello larger than one
    # record IS legal (RFC 8446 §5.1 allows handshake message fragmentation), and OpenSSL will
    # produce one once the extensions grow past 16 KiB.
    private def self.handshake_payload(bytes : Bytes) : Bytes
      out = IO::Memory.new
      pos = 0
      while pos + 5 <= bytes.size
        break unless bytes[pos] == RECORD_HANDSHAKE
        len = (bytes[pos + 3].to_i << 8) | bytes[pos + 4].to_i
        break if len <= 0 || pos + 5 + len > bytes.size
        out.write(bytes[pos + 5, len])
        pos += 5 + len
        break if out.bytesize >= MAX_HELLO
      end
      out.to_slice
    end

    private def self.parse_handshake(body : Bytes) : Hello?
      r = ClientHello::Reader.new(body)
      return nil unless r.u8 == HANDSHAKE_CLIENT_HELLO
      return nil unless r.skip(3) # handshake length (24-bit)
      legacy_version = r.u16
      return nil unless legacy_version
      return nil unless r.skip(32)    # random
      return nil unless r.skip_vec(1) # legacy_session_id
      suites = r.take_vec(2)
      return nil unless suites
      return nil unless r.skip_vec(1) # legacy_compression_methods

      ciphers = u16_list(suites)
      # No extensions at all is a legal (ancient) hello, and JA3 defines the empty-field form
      # for exactly that — so it parses to a Hello with empty lists, not to nil.
      ext_total = r.u16
      return blank_ext_hello(legacy_version, ciphers) unless ext_total
      parse_extensions(r, ext_total, legacy_version, ciphers)
    end

    private def self.blank_ext_hello(legacy_version : Int32, ciphers : Array(Int32)) : Hello
      Hello.new(legacy_version, ciphers, [] of Int32, [] of Int32, [] of Int32,
        [] of Int32, [] of Int32, [] of Bytes, false)
    end

    private def self.parse_extensions(r : ClientHello::Reader, total : Int32,
                                      legacy_version : Int32, ciphers : Array(Int32)) : Hello?
      types = [] of Int32
      groups = [] of Int32
      formats = [] of Int32
      sig_algs = [] of Int32
      versions = [] of Int32
      alpn = [] of Bytes
      sni = false

      stop = r.pos + total
      while r.pos < stop
        type = r.u16
        size = r.u16
        return nil unless type && size
        data = r.take(size)
        return nil unless data
        next if grease?(type)
        types << type
        case type
        when EXT_SERVER_NAME        then sni = true
        when EXT_SUPPORTED_GROUPS   then groups = u16_list(vec(data, 2))
        when EXT_EC_POINT_FORMATS   then formats = u8_list(vec(data, 1))
        when EXT_SIG_ALGS           then sig_algs = u16_list(vec(data, 2))
        when EXT_SUPPORTED_VERSIONS then versions = u16_list(vec(data, 1))
        when EXT_ALPN               then alpn = alpn_list(vec(data, 2))
        end
      end
      Hello.new(legacy_version, ciphers, types, groups, formats, sig_algs, versions, alpn, sni)
    end

    # The inner vector of an extension body: `len_bytes` of length, then that many bytes.
    # Empty when the body is truncated — a malformed extension contributes nothing rather
    # than aborting the whole parse, matching how both reference implementations behave.
    private def self.vec(data : Bytes, len_bytes : Int32) : Bytes
      return Bytes.empty if data.size < len_bytes
      len = case len_bytes
            when 1 then data[0].to_i
            else        (data[0].to_i << 8) | data[1].to_i
            end
      return Bytes.empty if len <= 0 || len_bytes + len > data.size
      data[len_bytes, len]
    end

    private def self.u16_list(data : Bytes) : Array(Int32)
      out = [] of Int32
      i = 0
      while i + 1 < data.size
        v = (data[i].to_i << 8) | data[i + 1].to_i
        out << v unless grease?(v)
        i += 2
      end
      out
    end

    private def self.u8_list(data : Bytes) : Array(Int32)
      data.to_a.map(&.to_i)
    end

    # ALPN protocol_name_list: entries of one length byte then that many bytes. Kept as raw
    # `Bytes`, not String: JA4's ALPN rule is defined over BYTES (it has a case for a
    # non-ASCII first or last octet), and decoding to UTF-8 first would lose it.
    private def self.alpn_list(data : Bytes) : Array(Bytes)
      out = [] of Bytes
      i = 0
      while i < data.size
        len = data[i].to_i
        break if i + 1 + len > data.size
        out << data[i + 1, len]
        i += 1 + len
      end
      out
    end

    # RFC 8701 GREASE: both octets equal, low nibble `a`. Written as a test rather than a
    # 16-entry table so a value can never be missed from the list.
    def self.grease?(value : Int32) : Bool
      hi = (value >> 8) & 0xff
      lo = value & 0xff
      hi == lo && (lo & 0x0f) == 0x0a
    end

    # ── JA3 ────────────────────────────────────────────────────────────────────────────────

    # `SSLVersion,Cipher,SSLExtension,EllipticCurve,EllipticCurvePointFormat` — decimal values,
    # `-` between values, `,` between fields, GREASE removed. The version is the ClientHello's
    # own legacy_version, NOT the record header's and NOT what supported_versions says.
    def self.ja3_text(hello : Hello) : String
      String.build do |io|
        io << hello.legacy_version << ','
        hello.ciphers.join(io, '-')
        io << ','
        hello.extensions.join(io, '-')
        io << ','
        hello.groups.join(io, '-')
        io << ','
        hello.point_formats.join(io, '-')
      end
    end

    def self.ja3(hello : Hello) : String
      Digest::MD5.hexdigest(ja3_text(hello))
    end

    # ── JA4 ────────────────────────────────────────────────────────────────────────────────

    # `t13d1516h2_8daaf6152771_e5627efa2ab1`. See `ja4_raw` for the unhashed form.
    def self.ja4(hello : Hello) : String
      a, b, c = ja4_parts(hello)
      "#{a}_#{truncated_sha256(b, b.empty?)}_#{truncated_sha256(c, ja4_c_extensions(hello).empty?)}"
    end

    # JA4_r: the same fingerprint with both hashes replaced by the lists they hash. This is
    # what makes a JA4 actionable — the digest says two clients differ, the raw form says how.
    def self.ja4_raw(hello : Hello) : String
      a, b, c = ja4_parts(hello)
      "#{a}_#{b}_#{c}"
    end

    # The three sections, unhashed. One place so the digest and the raw form cannot describe
    # different hellos, and so `report` — which needs both — derives them once.
    private def self.ja4_parts(hello : Hello) : {String, String, String}
      exts = ja4_c_extensions(hello)
      {ja4_a(hello), ja4_b_text(hello), ja4_c_text(hello, exts)}
    end

    # `t` `13` `d` `15` `16` `h2` — transport, version, SNI-or-IP, cipher count, extension
    # count, ALPN ends. Always `t`: gori dials TCP, never QUIC or DTLS.
    private def self.ja4_a(hello : Hello) : String
      "t#{ja4_version(hello)}#{hello.sni? ? 'd' : 'i'}" \
      "#{two_digit(hello.ciphers.size)}#{two_digit(hello.extensions.size)}#{ja4_alpn(hello)}"
    end

    # The HIGHEST version offered in supported_versions, falling back to legacy_version when
    # that extension is absent. Reading legacy_version first is the classic mistake: every
    # TLS 1.3 client sends `0x0303` there for middlebox compatibility, so it would report
    # every modern client as TLS 1.2.
    private def self.ja4_version(hello : Hello) : String
      raw = hello.supported_versions.max? || hello.legacy_version
      case raw
      when 0x0304 then "13"
      when 0x0303 then "12"
      when 0x0302 then "11"
      when 0x0301 then "10"
      when 0x0300 then "s3"
      when 0x0002 then "s2"
      when 0xfeff then "d1"
      when 0xfefd then "d2"
      when 0xfefc then "d3"
      else             "00"
      end
    end

    # "> 99, which there should never be" — the spec's own words; the count field is two
    # characters wide and saturates rather than overflowing it.
    private def self.two_digit(n : Int32) : String
      (n > 99 ? 99 : n).to_s.rjust(2, '0')
    end

    # First and last character of the FIRST ALPN value. "00" when there is no ALPN extension,
    # no values, or an empty first value. When either the first or the last OCTET is not ASCII
    # alphanumeric the two characters come from the hex form of the whole value instead — a
    # middle non-alphanumeric byte does NOT trigger that (spec: `30 ab cd 31` → "01").
    private def self.ja4_alpn(hello : Hello) : String
      first = hello.alpn.first?
      return "00" if first.nil? || first.empty?
      head = first[0]
      tail = first[first.size - 1]
      return "#{head.unsafe_chr}#{tail.unsafe_chr}" if alnum?(head) && alnum?(tail)
      hex = first.hexstring
      "#{hex[0]}#{hex[hex.size - 1]}"
    end

    private def self.alnum?(byte : UInt8) : Bool
      (0x30_u8..0x39_u8).includes?(byte) ||
        (0x41_u8..0x5a_u8).includes?(byte) ||
        (0x61_u8..0x7a_u8).includes?(byte)
    end

    private def self.ja4_b_text(hello : Hello) : String
      hello.ciphers.map { |c| hex4(c) }.sort!.join(',')
    end

    # Extensions minus SNI (0000) and ALPN (0010): both are already reported in the `a`
    # section, and both change with the DESTINATION rather than with the client — leaving them
    # in would give one client a different `c` per host it visits.
    private def self.ja4_c_extensions(hello : Hello) : Array(String)
      hello.extensions
        .reject { |e| e == EXT_SERVER_NAME || e == EXT_ALPN }
        .map { |e| hex4(e) }
        .sort!
    end

    # Sorted extensions, then `_`, then signature algorithms IN OFFER ORDER (the spec is
    # explicit that these are not sorted). No signature algorithms ⇒ the string ends without
    # the underscore.
    private def self.ja4_c_text(hello : Hello, extensions : Array(String)) : String
      exts = extensions.join(',')
      return exts if hello.sig_algs.empty?
      "#{exts}_#{hello.sig_algs.map { |s| hex4(s) }.join(',')}"
    end

    # 12 hex characters of SHA-256, or twelve zeros when the list was empty. The spec calls
    # for the zeros rather than the hash of an empty string, "as this makes it clear to the
    # user when a field has no values".
    private def self.truncated_sha256(text : String, empty : Bool) : String
      return "000000000000" if empty
      Digest::SHA256.hexdigest(text)[0, 12]
    end

    private def self.hex4(value : Int32) : String
      value.to_s(16).rjust(4, '0')
    end
  end
end
