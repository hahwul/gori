require "../store"
require "../repeater/flow_request"
require "../proxy/codec/http1"

module Gori
  module Prism
    # Build a synthetic FlowDetail from a persisted Repeater tab so Passive.analyze can
    # run over Repeater send results the same way it runs over History flows. Returns nil
    # when there is no scorable response (no head, or only an error with empty head).
    def self.detail_from_repeater(record : Store::RepeaterRecord) : Store::FlowDetail?
      head = record.response_head
      return nil if head.nil? || head.empty?

      scheme, host, port = Repeater::FlowRequest.parse_target(record.target)
      return nil if host.empty?

      req_text = record.request
      # Take whichever blank-line boundary occurs FIRST — the editor uses bare-LF, so a
      # literal "\r\n\r\n" inside the body must not win over the true earlier "\n\n" head
      # boundary (the naive `crlf || lf` fallback would snap to the body's sequence).
      sep = [req_text.index("\r\n\r\n"), req_text.index("\n\n")].compact.min?
      req_head_s = sep ? req_text[0, sep] : req_text
      req_body_s = if sep
                     n = req_text[sep, 4]? == "\r\n\r\n" ? 4 : 2
                     req_text[(sep + n)..]?
                   end
      # The Repeater editor serializes request text with BARE-LF line endings, but
      # Http1.parse_headers recognizes only CRLF: without normalizing the internal separators,
      # the first CRLF found is the appended terminator, so parse_headers starts at the blank
      # line and returns an EMPTY header list — every request-side rule (CORS Origin, Basic
      # auth, request tech fingerprints) then silently misses on Repeater/CLI/MCP-sourced scans.
      # Normalize LF→CRLF, then ensure the head ends with a blank line for parse_request_head.
      head_crlf = req_head_s.gsub(/\r?\n/, "\r\n")
      req_head_bytes = (head_crlf.ends_with?("\r\n\r\n") ? head_crlf : "#{head_crlf.rstrip}\r\n\r\n").to_slice
      req_body = req_body_s.try { |b| b.empty? ? nil : b.to_slice }

      req = Proxy::Codec::Http1.parse_request_head(req_head_bytes)
      method = req.method.presence || "GET"
      target = req.target.presence || "/"

      resp = Proxy::Codec::Http1.parse_response_head(head)
      status = resp.status
      content_type = resp.headers.get?("Content-Type")
      body = record.response_body
      size = req_head_bytes.size.to_i64 + (req_body.try(&.size) || 0).to_i64 +
             head.size.to_i64 + (body.try(&.size) || 0).to_i64

      # Prefer the source History flow id when the tab was spawned from one; otherwise 0
      # (scan_detail normalizes 0 → nil for sample_flow_id so we don't invent a flow link).
      row_id = record.flow_id || 0_i64
      row = Store::FlowRow.new(
        row_id, 0_i64, scheme, method, host, port, target,
        status, size, Store::FlowState::Complete,
        body.try(&.size.to_i64), record.response_duration_us, content_type)

      Store::FlowDetail.new(
        row,
        record.http2? ? "HTTP/2" : "HTTP/1.1",
        req_head_bytes,
        req_body,
        head,
        body,
        sni: record.sni)
    end
  end
end
