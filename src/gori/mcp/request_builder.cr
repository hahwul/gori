require "base64"
require "json"
require "uri"
require "../env"
require "../repeater/url_request"

module Gori
  module MCP
    # Turns a `send_request` tool's structured arguments into the raw HTTP/1.1
    # request bytes the repeater engines expect, plus the scheme/host/port they dial.
    # Two modes: structured ({method,url,headers,body}) or a verbatim `raw` request
    # string (still taking scheme/host/port from `url`, since the engines need a
    # target to dial).
    #
    # What is left here is the JSON half — reading those arguments, the `*_base64` byte forms,
    # the header shapes an agent sends. Resolving the URL, validating and framing the request is
    # `Repeater::UrlRequest`, which `gori run send` shares (#1116).
    module RequestBuilder
      alias Built = Repeater::UrlRequest::Built

      # `headers` as name→value pairs, in the caller's order.
      #
      # An `as_h?`-only read answered nil for every non-object shape and the caller then
      # skipped the loop entirely — so a JSON-encoded string or a pair array meant the
      # request went out with ZERO caller headers and still reported success. An entire
      # authenticated crawl could run unauthenticated with no signal anywhere. Accept the
      # shapes an agent actually sends, and RAISE on anything else rather than vanish —
      # same contract as `parse_h2_fields`, which already takes object-or-encoded-string.
      def self.header_pairs(raw : JSON::Any?) : Array({String, String})
        return [] of {String, String} if raw.nil? || raw.raw.nil?
        node = raw
        if s = raw.as_s?
          # A whole object handed over as a JSON string — common when an agent stringifies.
          parsed = (JSON.parse(s) rescue nil)
          raise Gori::Error.new(
            "invalid 'headers' (expected an object of name->value, got an unparseable string)") unless parsed
          node = parsed
        end

        if h = node.as_h?
          return h.map { |k, v| {k, v.as_s? || v.to_s} }
        end
        if arr = node.as_a?
          return arr.map do |item|
            # `[{"name": …, "value": …}, …]` is the OTHER spelling of a header set on this
            # same server — it is what `create_session_slot{set_headers}` and
            # `authorize_start{identities}` take — so an agent that has read one schema sends
            # it here too. Refusing it made `send_request` the odd tool out for a shape gori
            # itself taught the model; the two keys together are unambiguous.
            if o = item.as_h?
              # `presence`, not `o["name"]?`: a `JSON::Any` wrapping nil is TRUTHY (which is
              # why this method's own entry guard is `raw.nil? || raw.raw.nil?`), so a null or
              # empty name would reach the wire as `": value"` — and `discover_start` formats
              # that pair into a line with nothing left to name what the caller wrote, which
              # is the refusal the sibling fix in `session_slots.cr` exists to prevent.
              n = o["name"]?.try(&.as_s?).try(&.strip).presence
              v = o["value"]?
              raise Gori::Error.new(
                "invalid 'headers' (an object entry must be {\"name\": …, \"value\": …} with a " \
                "non-empty name; a name->value map goes in 'headers' itself, not in a list)") unless n && v && !v.raw.nil?
              next {n, v.as_s? || v.to_s}
            end
            pair = item.as_a?
            raise Gori::Error.new("invalid 'headers' (array form must hold [name, value] pairs)") unless pair && pair.size == 2
            {pair[0].as_s? || pair[0].to_s, pair[1].as_s? || pair[1].to_s}
          end
        end
        raise Gori::Error.new("invalid 'headers' (expected an object of name->value)")
      end

      # A string argument that IS the message: `url`, `raw`, `method`, `body`, and the
      # `*_base64` pair. `args[…]?.try(&.as_s?)` answered nil for every other shape and each
      # caller read that nil as "absent", so a mistyped argument was accepted and then thrown
      # away — with `isError:false` and an `effective_request` echo of a request that never
      # existed:
      #
      #   * `method: 123`   → fell back to the DEFAULT and sent a GET. The caller measured a
      #                       target's handling of a verb it never sent.
      #   * `body: {…}`     → the shape an LLM reaches for on any JSON API — sent NO body and
      #                       no Content-Length.
      #   * `raw: […]`      → fell through to the structured builder and sent a bare GET to
      #                       `url` instead of the request the caller wrote.
      #
      # STRICT, unlike `Tools#str`'s scalar coercion, for the reason `strict_jstr` gives in
      # fuzz.cr: only a genuine JSON string is ever a sane input for a value spliced straight
      # onto the wire, and GUESSING at one is the failure `base64_arg` already refuses —
      # serializing an object body would invent a Content-Type and a length the caller never
      # stated. `header_pairs` (which accepts the encoded-object form) is the exception, and
      # it can be: a header set has one unambiguous JSON spelling. A body does not.
      private def self.wire_str(args : Hash(String, JSON::Any), name : String,
                                hint : String = "") : String?
        v = args[name]?
        return nil if v.nil? || v.raw.nil?
        v.as_s? || raise Gori::Error.new("invalid '#{name}' (expected a JSON string#{hint})")
      end

      # `args` is the tool's `arguments` object (a parsed JSON hash).
      #
      # The URL is resolved FIRST, before any other argument is read, so a call with a bad URL
      # and a second mistake reports the URL — the order this method has always refused in.
      def self.build(args : Hash(String, JSON::Any)) : Built
        target = Repeater::UrlRequest.target(url_arg(args))

        if b64 = base64_arg(args, "raw_base64")
          # A base64 input IS the wire: the caller encoded the exact octets it wants sent,
          # so there is nothing to normalise and nothing to expand. See `verbatim?`.
          Repeater::UrlRequest.bytes(target, b64)
        elsif (raw = wire_str(args, "raw", "; use raw_base64 for exact octets")) && !raw.empty?
          # `verbatim` means the operator's bytes ARE the message: no `$VAR` expansion and no
          # bare-LF promotion. See `Repeater::UrlRequest.raw`.
          Repeater::UrlRequest.raw(target, raw, verbatim?(args))
        else
          method = (wire_str(args, "method") || "GET").upcase
          # Refused before the body is read, the order this has always reported two mistakes in.
          Repeater::UrlRequest.check_method(method)
          # `body_base64` wins over `body`: it is the byte-exact form, and a caller that sent
          # both meant the precise one. It is NOT env-expanded — the caller already decided
          # every octet, and expanding would change the length it encoded.
          body = base64_arg(args, "body_base64") ||
                 wire_str(args, "body", "; stringify JSON yourself, or use body_base64 for exact octets")
                   .try { |b| Env.expand(b).to_slice }
          Repeater::UrlRequest.structured(target, method, RequestBuilder.header_pairs(args["headers"]?), body)
        end
      end

      # The dialed origin (scheme, host, port) from `url`, with every check `build` runs.
      # Extracted so the FIELD-NATIVE send path (`h2_fields`) resolves the same origin without
      # also building request bytes it will never send: the fields are the message.
      def self.origin(args : Hash(String, JSON::Any)) : {String, String, Int32}
        t = Repeater::UrlRequest.target(url_arg(args))
        {t.scheme, t.host, t.port}
      end

      private def self.url_arg(args : Hash(String, JSON::Any)) : String
        url = wire_str(args, "url")
        raise Gori::Error.new("'url' is required") if url.nil? || url.empty?
        url
      end

      # `as_bool?` alone read a STRINGIFIED `"true"` — which LLM clients emit constantly,
      # the schema's "boolean" being advisory — as nil, so `verbatim` silently turned OFF and
      # the bare LF the caller asked to preserve was promoted to CRLF. Matches `Tools#bool`'s
      # leniency, and must: `send.cr` reads the same key through this ONE predicate, so the
      # two cannot disagree about whether a call is verbatim.
      #
      # `raw_base64` implies it. Base64 is how a caller says "these exact octets" — JSON has
      # no other way to write one — so demanding `verbatim:true` alongside it would mean a
      # caller who forgot the flag got its bytes silently LF-promoted and env-expanded, which
      # is precisely what encoding them was meant to prevent.
      #
      # A value it cannot read RAISES, it does not fall back to false. The fallback was the
      # sharper half of the same bug: `verbatim: 1` — the shape an LLM emits as readily as
      # `true` — silently selected the mode that PROMOTES the operator's bare-LF header
      # terminator to CRLF, destroying the desync primitive `verbatim` exists to deliver, and
      # reported a clean send. Every sibling flag on the same tool (`apply_rules`,
      # `record_history`, `save_as_repeater`, `http2`, `include_sensitive_headers`) already
      # refuses an unintelligible value through `Tools#bool_arg`; this one now does too.
      # `Gori::Error` is what the tools rescue into a clean caller-facing message.
      def self.verbatim?(args : Hash(String, JSON::Any)) : Bool
        return true if wire_str(args, "raw_base64").try { |s| !s.empty? }
        v = args["verbatim"]?
        return false if v.nil? || v.raw.nil?
        b = v.as_bool?
        return b unless b.nil?
        case v.as_s?.try(&.downcase)
        when "true"  then true
        when "false" then false
        else              raise Gori::Error.new("invalid 'verbatim' (expected true or false)")
        end
      end

      # Decode a `*_base64` argument into the exact bytes it names, or nil when absent/empty.
      #
      # This is the ONLY way to put a raw 0x00 or 0x80–0xFF octet on the wire from JSON-RPC:
      # `raw`/`body` are JSON strings handed to the socket as `String#to_slice`, i.e. their
      # UTF-8 ENCODING, so `é` left as `\xc3\xa9` and a latin-1 payload, an overlong/invalid
      # UTF-8 traversal bypass, and every binary body (protobuf, gzip, a multipart upload)
      # were inexpressible — with `isError:false` and an echo of the intended text, so the
      # caller never learned. Invalid base64 is an ERROR rather than a silent fallback: a
      # caller reaching for this argument is asking for exact bytes, and quietly sending
      # different ones is the failure it came here to avoid.
      private def self.base64_arg(args : Hash(String, JSON::Any), name : String) : Bytes?
        s = wire_str(args, name)
        return nil if s.nil? || s.empty?
        begin
          Base64.decode(s)
        rescue
          raise Gori::Error.new("'#{name}' is not valid base64")
        end
      end

      # The head-only CRLF promotion `raw` gets without `verbatim`. Kept on this module because
      # `intercept_forward_edit` calls it here; the rule itself is `Repeater::UrlRequest`'s.
      def self.normalize_raw(raw : String) : Bytes
        Repeater::UrlRequest.normalize_raw(raw)
      end
    end
  end
end
