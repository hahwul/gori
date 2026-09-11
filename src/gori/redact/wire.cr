require "../proxy/codec/http1"
require "../proxy/codec/content_decode"
require "../media_type"
require "../store/models"
require "../redact"

module Gori
  module Redact
    # The body engine applied to a whole HTTP MESSAGE — head plus entity — and the framing
    # repair that has to follow it.
    #
    # Sanitizing a body changes its length, and it usually has to UNDO the transfer the body
    # arrived under to read it at all (a gzipped or chunked entity has no fields to match until
    # it is decoded). A head left describing the captured entity would then be describing an
    # entity that is not there: `Content-Length` off by the difference, `Content-Encoding: gzip`
    # over plain text, `Transfer-Encoding: chunked` over an unframed body. Every consumer of an
    # export is entitled to read those three — curl re-sends the command, a HAR reader renders
    # the entry, the operator eyeballs `--format raw` — so the sanitized head is repaired to
    # describe the sanitized body, and `decoded?` records that the repair happened.
    #
    # ## What this does NOT touch, on purpose
    #
    # The request line and the header block, apart from those three framing fields. A profile
    # describes BODY structure (#1035); a credential in a `Cookie` header or a `?token=` query
    # string is a different axis with its own consumers (`row.target`, a HAR `url`, the copy
    # menu's URL row, curl's argument) that would have to move together or disagree with each
    # other. So the marker every surface prints says "bodies", never "sanitized" unqualified —
    # see `Redact::Report#summary`.
    module Wire
      # One side of an exchange, sanitized.
      record Sanitized,
        head : Bytes,
        body : Bytes?,
        result : Result,
        decoded : Bool = false do
        def count : Int32
          result.count
        end

        def hits : Array(Hit)
          result.hits
        end

        # Was the transfer undone to read the body — so this head no longer carries the
        # `Content-Encoding` / `Transfer-Encoding` the capture did?
        def decoded? : Bool
          decoded
        end
      end

      # Sanitize one message. A nil/empty body is returned untouched with an `Empty` result, so
      # a GET costs one Content-Type lookup and no copies.
      def self.message(head : Bytes?, body : Bytes?, matcher : Matcher) : Sanitized
        raw_head = head || Bytes.empty
        if body.nil? || body.empty?
          return Sanitized.new(head: raw_head, body: body,
            result: Result.new(text: "", hits: [] of Hit, shape: Shape::Empty))
        end
        # The entity as its fields actually are, not as it was transferred.
        #
        # A decode that FAILED still hands back bytes — `inflate` returns whatever came out
        # before the stream broke, with the failure in `note` — and those are taken as NOT
        # decoded here. Sanitizing a half-inflated prefix and then emitting a head that says the
        # body is plain would be gori asserting something about bytes it could not read; the raw
        # entity is almost never valid UTF-8, so `Matcher#body` withholds it whole instead,
        # which is the honest answer.
        raw, note = Proxy::Codec::ContentDecode.decode(head, body)
        decoded = Proxy::Codec::ContentDecode.decode_failed?(note) ? nil : raw
        entity = decoded || body
        result = matcher.body(entity, MediaType.of(head))
        clean = result.bytes
        Sanitized.new(head: reframe(raw_head, clean.size, drop_transfer: !decoded.nil?),
          body: clean, result: result, decoded: !decoded.nil?)
      end

      # One message held as a SINGLE buffer — head, blank line, body — which is how the
      # Repeater and the TUI's copy menu carry a message, as opposed to the head/body pair a
      # store row keeps. Splits, sanitizes, and rejoins.
      #
      # A buffer with no CRLF-framed blank line in it is all head by the only view of a header
      # block this module has (see `reframe`): returned untouched, with an `Empty` result,
      # because there is no entity to inspect and inventing one out of the last line would
      # corrupt a request the operator is about to copy.
      #
      # The one shape that reaches here that way is a Repeater request typed in HEX mode, which
      # is byte-exact by design and may frame its head however the operator chose; every other
      # caller is CRLF (`RepeaterView#expand_wire` normalizes the head, and a capture cannot end
      # a head on anything else). The count a surface then reports is 0 — nothing was examined,
      # as opposed to nothing matching — which is the honest reading of a buffer gori could not
      # split, and `--no-redact` / a non-hex edit is the way to have it looked at.
      def self.wire(text : String, matcher : Matcher) : {String, Result}
        bytes = text.to_slice
        at = header_block_end(bytes)
        if at.nil?
          return {text, Result.new(text: "", hits: [] of Hit, shape: Shape::Empty)}
        end
        sep = terminator_at(bytes, at)
        head = bytes[0, at + sep]
        body = bytes[(at + sep), bytes.size - at - sep]
        clean = message(head, body, matcher)
        {String.new(clean.head) + String.new(clean.body || Bytes.empty), clean.result}
      end

      # The head, describing `size` bytes of unencoded entity.
      #
      # `Content-Length` is replaced rather than adjusted: a head may legitimately carry none
      # (a chunked response) or several (a request-smuggling probe, which gori captures exactly
      # as sent), and "whatever was there, now one field with the right number" is the only rule
      # that is right for all of them. `drop_transfer` additionally removes the two fields that
      # describe a transfer this body no longer has.
      def self.reframe(head : Bytes, size : Int32, drop_transfer : Bool) : Bytes
        # A head with no CRLF anywhere has no header block by `strip_header_lines`' view, so it
        # would keep whatever `Content-Length` it carries and gain a second one beside it. gori
        # cannot repair a block it cannot parse, and a head with two framing fields is worse
        # than a head with a stale one — so this leaves it exactly as captured. Only a
        # hand-authored request reaches here that way; everything gori captures or imports is
        # CRLF-framed (`Codec::Http1.read_head` will not end a head on anything else).
        return head unless crlf_anywhere?(head)
        stripped = Proxy::Codec::Http1.strip_header_lines(head, "content-length") { true }
        if drop_transfer
          stripped = Proxy::Codec::Http1.strip_header_lines(stripped, "content-encoding") { true }
          stripped = Proxy::Codec::Http1.strip_header_lines(stripped, "transfer-encoding") { true }
        end
        insert_content_length(stripped, size)
      end

      # Write `Content-Length: n` as the LAST field of the block. Last rather than first
      # because that is where `Import::Builder.request_head` already re-emits it (see
      # `Export::Har`'s header comment), so a sanitized head and a re-imported one order their
      # fields the same way.
      private def self.insert_content_length(head : Bytes, size : Int32) : Bytes
        field = "Content-Length: #{size}\r\n".to_slice
        at = header_block_end(head)
        io = IO::Memory.new(head.size + field.size + 4)
        if at
          io.write(head[0, at])
          io.write(field)
          io.write(head[at, head.size - at])
        else
          # A head with no terminating blank line — a capture cut at the head cap, or a
          # hand-authored Repeater request. Close it properly rather than appending a field
          # onto whatever the last line turned out to be.
          io.write(head)
          io.write(CRLF) unless head.size >= 2 && terminator_at(head, head.size - 2) == 2
          io.write(field)
          io.write(CRLF)
        end
        io.to_slice
      end

      CRLF = "\r\n".to_slice

      # Where a new header line may be inserted: the start of the blank line that ends the
      # header block, or nil when the head carries no blank line at all.
      #
      # CRLF only, deliberately: this has to agree with `Http1.strip_header_lines`, which is
      # what removed the old field, and its own header explains why a bare LF inside a field
      # value must not be read as a line break. `reframe` refuses a head with no CRLF outright,
      # so the two never disagree about where the block ends.
      private def self.header_block_end(head : Bytes) : Int32?
        i = 0
        while i < head.size
          term = terminator_at(head, i)
          if term > 0
            nxt = i + term
            return nxt if terminator_at(head, nxt) > 0
            i = nxt
          else
            i += 1
          end
        end
        nil
      end

      # Is there a CRLF anywhere in the head? `Slice#index` compares ELEMENTS, so it cannot be
      # asked this about a two-byte needle.
      private def self.crlf_anywhere?(head : Bytes) : Bool
        i = 0
        while i + 1 < head.size
          return true if terminator_at(head, i) == 2
          i += 1
        end
        false
      end

      # The length of the CRLF starting at `i`, or 0 when there is none there.
      private def self.terminator_at(head : Bytes, i : Int32) : Int32
        return 0 if i < 0 || i >= head.size
        head[i] == 0x0d_u8 && i + 1 < head.size && head[i + 1] == 0x0a_u8 ? 2 : 0
      end
    end

    # What one sanitized FLOW amounts to — both sides plus everything a surface has to say
    # about them. Surfaces print `summary` and, for `--redact-preview`, walk `lines`.
    record Report,
      profile : Profile,
      request : Wire::Sanitized,
      response : Wire::Sanitized,
      pattern_errors : Array(String) = [] of String do
      def count : Int32
        request.count + response.count
      end

      def redacted? : Bool
        count > 0
      end

      # Did either body have to fall back to the conservative text pass because it did not
      # parse? A json_pointer rule cannot fire there, so it changes what the artifact is worth
      # and the reporter says so.
      def fell_back? : Bool
        request.result.fell_back || response.result.fell_back
      end

      # Did reading either body require undoing its transfer — so the exported heads no longer
      # carry the `Content-Encoding` / `Transfer-Encoding` the capture did?
      def decoded? : Bool
        request.decoded? || response.decoded?
      end

      # `{side, hit}` for every replacement, request side first — the preview's rows, and the
      # audit trail behind the count.
      def replacements : Array({String, Hit})
        rows = [] of {String, Hit}
        request.hits.each { |h| rows << {"request", h} }
        response.hits.each { |h| rows << {"response", h} }
        rows
      end
    end

    module Wire
      # A captured WebSocket transcript, frame by frame.
      #
      # A frame payload is an entity with no head of its own, so it goes through the body engine
      # directly and is sniffed the same way (JSON when it looks like JSON, the text pass
      # otherwise, withheld whole when it is not valid UTF-8 — a binary frame therefore does not
      # survive a sanitized export, which is the conservative answer and the reason the raw path
      # exists). gori's own `[gori] …` advisory rows go through unchanged in practice: they carry
      # no field names a profile matches.
      def self.ws_messages(messages : Array(Store::WsMessage),
                           matcher : Matcher) : {Array(Store::WsMessage), Int32}
        count = 0
        clean = messages.map do |m|
          result = matcher.body(m.payload, nil)
          next m unless result.redacted?
          count += result.count
          Store::WsMessage.new(m.id, m.flow_id, m.repeater_id, m.created_at, m.direction,
            m.opcode, result.bytes, m.shape)
        end
        {clean, count}
      end

      # Both sides of a stored flow, sanitized, plus the report that describes them.
      #
      # Returns a NEW `FlowDetail`; the one handed in is untouched, and so is the row behind it.
      # Every format `gori run show` can print renders from a detail, so sanitizing here is the
      # single integration point for all of them — text, json, raw, HAR, curl and the four
      # client-code snippets — instead of eight places that could each forget.
      def self.flow(detail : Store::FlowDetail,
                    matcher : Matcher) : {Store::FlowDetail, Report}
        req = message(detail.request_head, detail.request_body, matcher)
        res = message(detail.response_head, detail.response_body, matcher)
        clean = Store::FlowDetail.new(
          detail.row, detail.http_version,
          req.head, req.body,
          detail.response_head.nil? ? nil : res.head, res.body,
          detail.h2_conn_id, detail.h2_stream_id,
          detail.request_body_truncated?, detail.response_body_truncated?,
          detail.error, detail.sni)
        {clean, Report.new(matcher.profile, req, res, matcher.pattern_errors)}
      end
    end
  end
end
