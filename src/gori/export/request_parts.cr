require "./curl"
require "../proxy/codec/content_decode"

module Gori
  module Export
    # The captured request, decomposed once for the CODE serializers (`Export::PythonRequests`,
    # `Export::JsFetch`, `Export::GoHttp`, `Export::Httpie`) and the CSRF PoC. Every one of them
    # answers the same three questions — what URL, which headers a generated client should send,
    # what body — and answering them independently is how six serializers drift. So the parse and
    # the "which headers actually go on the wire" decision live here, once, on top of the request
    # primitives `Export::Curl` already owns (`split_message` / `split_lines` / `parse_request_line`
    # / `resolve_url` / `each_header`, all byte-wise and obs-fold-aware).
    module RequestParts
      # A request split into its runnable parts. `headers` is every field as captured
      # ({name, value}, obs-folds already folded), before any drop decision — that is
      # `sendable`'s job. `body` is the WIRE body (chunk framing still on).
      record Parts,
        method : String,
        url : String,
        version : String,
        headers : Array({String, String}),
        body : String

      # {method, url, version, headers, body} for a request, or nil when there is nothing
      # runnable to emit — matching `Curl.text`, and for its two reasons: no request line to
      # resolve a URL from, or a request line gori cannot FRAME, whose `parts[1]` is some token
      # other than the request-target (see `Curl.request_line_refusal`). Refusing here covers
      # all five code serializers at once — the parse living in one place is what this module
      # is for, and a per-serializer guard is how six of them drift.
      def self.from_wire(wire : String, target : String) : Parts?
        head, body = Curl.split_message(wire)
        lines = Curl.split_lines(head)
        request_line = lines.first? || ""
        return nil if request_line.strip.empty?
        return nil if Curl.request_line_refusal(request_line)
        header_lines = lines.size > 1 ? lines[1..] : [] of String
        method, req_target, version = Curl.parse_request_line(request_line)
        url = Curl.resolve_url(req_target, target, header_lines)
        return nil if url.empty?
        headers = [] of {String, String}
        Curl.each_header(header_lines) { |n, v| headers << {n, v} }
        Parts.new(method, url, version, headers, body)
      end

      # The body a generated client should hand its HTTP library, and the headers to set
      # alongside it. A library frames the request itself, so this peels what the library will
      # re-add and drops what gori synthesized:
      #   * the FINAL `chunked` transfer coding comes OFF the wire body (the same de-chunk
      #     `Export::Curl.unchunk` does — sending the chunk-framed bytes under the library's own
      #     framing would frame them twice), and its Transfer-Encoding token drops with it;
      #   * Content-Length is dropped (every library recomputes it from the body it is given);
      #   * gori's synthesized h2 `MARKER_HEADERS` never reach generated code;
      #   * Host is dropped only when it is the URL's own authority — a Host that disagrees with
      #     the URL is the request (a Host-header test), so it rides.
      record Sendable, headers : Array({String, String}), body : String

      def self.sendable(parts : Parts) : Sendable
        body, remaining_te = unchunk(parts)
        kept = [] of {String, String}
        te_written = false
        parts.headers.each do |(name, value)|
          down = name.downcase
          next if Curl::MARKER_HEADERS.includes?(down)
          next if down == "content-length"
          next if down == "host" && Curl.host_is_url_authority?(value, parts.url)
          if down == "transfer-encoding"
            # The peeled coding list is emitted once, at the first TE line, and vanishes
            # entirely when `chunked` was the only coding.
            next if te_written
            te_written = true
            next if remaining_te.empty?
            kept << {name, remaining_te}
            next
          end
          kept << {name, value}
        end
        Sendable.new(kept, body)
      end

      # {entity, the Transfer-Encoding value to keep} — the final `chunked` coding peeled off,
      # or {body, ""} untouched when nothing declared chunked framing over a non-empty body.
      # Like `Curl.unchunk`, a head that declares chunked over bytes that are NOT chunk-framed
      # (a hand-authored Repeater request, an import that stored the entity) keeps the operator's
      # bytes rather than silently dropping them to nothing.
      private def self.unchunk(parts : Parts) : {String, String}
        return {parts.body, ""} if parts.body.empty?
        codings = transfer_codings(parts.headers)
        return {parts.body, ""} unless codings.last? == "chunked"
        wire = parts.body.to_slice
        entity = String.new(Proxy::Codec::ContentDecode.dechunk(wire))
        complete = Proxy::Codec::ContentDecode.chunked_complete?(wire)
        return {parts.body, ""} if !complete && entity.empty?
        {entity, codings[0, codings.size - 1].join(", ")}
      end

      # The header names (original casing, first-seen order) that appear more than once,
      # case-insensitively. A dict/object literal collapses these to one value, so the Python and
      # fetch serializers use this to either preserve the duplicates (fetch's pair-array form) or
      # say they could not (Python's note) — curl and Go emit a line per occurrence and need it not.
      def self.duplicate_header_names(headers : Array({String, String})) : Array(String)
        counts = Hash(String, Int32).new(0)
        headers.each { |(n, _)| counts[n.downcase] += 1 }
        seen = Set(String).new
        dups = [] of String
        headers.each do |(n, _)|
          d = n.downcase
          next unless counts[d] > 1
          next if seen.includes?(d)
          seen << d
          dups << n
        end
        dups
      end

      # Every Transfer-Encoding coding across all TE lines, in wire order, lowercased — a
      # repeated field is one comma-list (RFC 9110 §5.3), so the final coding is the last token
      # of the last line.
      private def self.transfer_codings(headers : Array({String, String})) : Array(String)
        codes = [] of String
        headers.each do |(name, value)|
          next unless name.downcase == "transfer-encoding"
          value.split(',').each do |tok|
            t = tok.strip.downcase
            codes << t unless t.empty?
          end
        end
        codes
      end
    end
  end
end
