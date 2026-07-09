require "../store"
require "../replay/flow_request"
require "../proxy/codec/http1"

module Gori
  module Prism
    # Build a synthetic FlowDetail from a persisted Replay tab so Passive.analyze can
    # run over Replay send results the same way it runs over History flows. Returns nil
    # when there is no scorable response (no head, or only an error with empty head).
    def self.detail_from_replay(record : Store::ReplayRecord) : Store::FlowDetail?
      head = record.response_head
      return nil if head.nil? || head.empty?

      scheme, host, port = Replay::FlowRequest.parse_target(record.target)
      return nil if host.empty?

      req_text = record.request
      sep = req_text.index("\r\n\r\n") || req_text.index("\n\n")
      req_head_s = sep ? req_text[0, sep] : req_text
      req_body_s = if sep
                     n = req_text[sep, 4]? == "\r\n\r\n" ? 4 : 2
                     req_text[(sep + n)..]?
                   end
      # Ensure the head ends with a blank line so Http1.parse_request_head is happy.
      req_head_bytes = (req_head_s.ends_with?("\r\n\r\n") || req_head_s.ends_with?("\n\n") ?
        req_head_s : "#{req_head_s.rstrip}\r\n\r\n").to_slice
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
