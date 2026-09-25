require "../store"
require "../proxy/codec/http1"
require "../proxy/codec/content_decode"
require "../proxy/h2/head_codec"
require "./stub"
require "../url"

module Gori
  # "Mock this response" (#1237): one captured flow → the draft of a short-circuit rule that
  # answers the same request with the same response, which the operator then edits (P4) —
  # typically to flip `"isAdmin": false` or strip a client-side check out of a script.
  #
  # A SNAPSHOT, never a reference to the flow. `flows.id` is reused after a delete or a
  # retention sweep, so a rule that pointed at flow 42 could start answering with a different
  # response one day; copying the bytes into the rule sidesteps that whole class (#1160's
  # detach lesson, applied at creation time).
  #
  # The body is stored INLINE and decoded: a stub is text the operator edits, and a gzip body
  # cannot be edited. So Content-Encoding is undone and its header dropped, chunked framing is
  # undone (ClientConn re-frames every stub from the bytes it sends), and a body that is still
  # not UTF-8 after that — an image, a protobuf — is refused with the way forward: save it to a
  # file and point a `body_file` stub at it.
  #
  # One engine, three surfaces: the TUI's History action, `gori run rewriter add --from-flow`
  # and MCP `create_rule{from_flow_id}` all call `draft`, so the refusals are the same
  # everywhere.
  module MockFromFlow
    extend self

    # The draft of a rule: the operator reviews and edits it before it is saved (P4).
    #
    # `pattern` is a REGEX anchored on the request line — `\AGET /api/user(\?| )` — so it claims
    # this endpoint with any query string, and not `/api/users` or `/api/user/1` beside it.
    record Draft, host : String, pattern : String, replacement : String

    # A refusal with a stable `code` (MCP keys on it) and the sentence the CLI and TUI print.
    record Refusal, code : String, message : String

    NO_RESPONSE = "NO_RESPONSE"
    TRUNCATED   = "TRUNCATED"
    STUBBED     = "ALREADY_STUBBED"
    INTERIM     = "INTERIM_STATUS"
    UNDECODABLE = "UNDECODABLE"
    BINARY      = "BINARY_BODY"
    TOO_LARGE   = "TOO_LARGE"
    BAD_HEAD    = "BAD_HEAD"

    # The largest body a draft inlines. A stub is edited in a text area and stored in a rule
    # row that the proxy reads on every refresh; past this, a `body_file` is the right tool.
    MAX_INLINE_BODY = 1 << 20

    # Headers the snapshot drops: framing ClientConn re-derives from the bytes it sends, and
    # gori's own h2 capture markers, which are a projection gori wrote and never the origin's.
    DROPPED = %w[content-length transfer-encoding]
    MARKERS = [Proxy::H2::HeadCodec::TRAILER_MARKER, Proxy::H2::HeadCodec::PUSHED_MARKER]

    def draft(detail : Store::FlowDetail) : Draft | Refusal
      head = detail.response_head
      if (refusal = capture_refusal(detail)) || head.nil?
        return refusal || Refusal.new(NO_RESPONSE, "this flow has no response to mock")
      end
      body = editable_body(head, detail.response_body)
      return body if body.is_a?(Refusal)
      decoded, body_text = body
      head_text = stub_head(String.new(head), content_decoded: decoded)
      return head_text if head_text.is_a?(Refusal)
      replacement = body_text.empty? ? head_text : "#{head_text}\n\n#{body_text}"
      return Refusal.new(BAD_HEAD, "the captured response head does not parse as a stub") unless RuleStub.valid?(replacement)
      Draft.new(detail.row.host, request_pattern(detail.row.method, detail.row.target), replacement)
    end

    # Why this capture is not a response the origin sent, or nil when it is.
    private def capture_refusal(detail : Store::FlowDetail) : Refusal?
      row = detail.row
      if row.short_circuited?
        return Refusal.new(STUBBED, "this response was answered by gori's own short-circuit rule, " \
                                    "not the origin — mocking it again would lose where it came from")
      end
      head = detail.response_head
      unless row.state.complete? && head && !head.empty?
        return Refusal.new(NO_RESPONSE, "this flow has no complete response to mock (#{row.state.to_s.downcase})")
      end
      if detail.response_body_truncated?
        return Refusal.new(TRUNCATED, "the captured response body was truncated at the capture limit, " \
                                      "so it is not the response the origin sent")
      end
      status = row.status || 0
      Refusal.new(INTERIM, "a #{status} is not a final response, and a stub cannot answer with one") if status < 200
    end

    # {was it decoded, the body as text}: de-chunked and inflated, or the refusal.
    private def editable_body(head : Bytes, raw : Bytes?) : {Bool, String} | Refusal
      decoded, note, complete = Proxy::Codec::ContentDecode.decode_full(head, raw)
      if Proxy::Codec::ContentDecode.decode_failed?(note) || !complete
        return Refusal.new(UNDECODABLE, "the captured body could not be decoded (#{note || "incomplete"}) — " \
                                        "save it to a file and use a body_file stub instead")
      end
      body = decoded || raw || Bytes.empty
      if body.size > MAX_INLINE_BODY
        return Refusal.new(TOO_LARGE, "the body is #{body.size} bytes, over the #{MAX_INLINE_BODY}-byte inline limit — " \
                                      "save it to a file and use a body_file stub instead")
      end
      text = String.new(body)
      return {!decoded.nil?, text} if text.valid_encoding?
      Refusal.new(BINARY, "the body is binary (not UTF-8 text) — save it to a file and use a body_file stub instead")
    end

    # The request line, anchored, up to the query: `\AGET /api/me(\?| )`. The path comes out of
    # an absolute-form target (a plain-proxy capture) too, because the proxy matches the
    # origin-form head it forwards.
    def request_pattern(method : String, target : String) : String
      path = target
      if Url.absolute_form?(path)
        slash = path.index('/', path.index!("://") + 3)
        path = slash ? path[slash..] : "/"
      end
      path = path.split('?', 2)[0].split('#', 2)[0]
      "\\A#{Regex.escape(method)} #{Regex.escape(path)}(\\?| )"
    end

    # The captured head as stub text (LF-joined, like the TUI editor writes it), minus the
    # headers in `DROPPED`/`MARKERS` — and minus Content-Encoding when the body was decoded,
    # since the stub's body no longer carries it. An obs-folded line (one that starts with
    # whitespace) is refused: `parse_head` would read it as a header of its own.
    private def stub_head(text : String, content_decoded : Bool) : String | Refusal
      lines = text.split('\n').map(&.chomp('\r'))
      while lines.last?.try(&.empty?)
        lines.pop
      end
      status = lines.shift? || ""
      unless text.valid_encoding?
        return Refusal.new(BAD_HEAD, "the captured response head is not valid UTF-8")
      end
      kept = [status]
      lines.each do |line|
        if line.starts_with?(' ') || line.starts_with?('\t')
          return Refusal.new(BAD_HEAD, "the captured response head folds a header across lines (obs-fold)")
        end
        name = line.split(':', 2)[0].strip
        next if DROPPED.any? { |d| name.compare(d, case_insensitive: true) == 0 }
        next if MARKERS.any? { |m| name.compare(m, case_insensitive: true) == 0 }
        next if content_decoded && name.compare("content-encoding", case_insensitive: true) == 0
        kept << line
      end
      kept.join('\n')
    end
  end
end
