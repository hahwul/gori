require "../store"
require "../repeater/flow_request"
require "../proxy/codec/http1"

module Gori
  module Probe
    # Build a synthetic FlowDetail from a persisted Repeater tab so Passive.analyze can
    # run over Repeater send results the same way it runs over History flows. Returns nil
    # when there is no scorable response (no head, or only an error with empty head).
    # Byte-level subsequence index. `String#index` cannot be used on these bytes: they may not
    # be valid UTF-8, and scrubbing first is exactly what this file must not do to the body.
    private def self.index_seq(hay : Bytes, needle : Bytes) : Int32?
      return nil if needle.empty? || hay.size < needle.size
      last = hay.size - needle.size
      i = 0
      while i <= last
        j = 0
        while j < needle.size && hay[i + j] == needle[j]
          j += 1
        end
        return i if j == needle.size
        i += 1
      end
      nil
    end

    def self.detail_from_repeater(record : Store::RepeaterRecord) : Store::FlowDetail?
      head = record.response_head
      return nil if head.nil? || head.empty?

      scheme, host, port = Repeater::FlowRequest.parse_target(record.target)
      return nil if host.empty?

      # The boundary is found in the RAW BYTES, and the two halves are then treated
      # differently — which is the whole point:
      #
      #   * the HEAD is scrubbed and LF→CRLF normalized, because it has to survive a PCRE
      #     (`record.request` can carry invalid UTF-8: the repeater editor seeds from a
      #     captured request head+body without scrubbing) and `Http1.parse_headers` reads
      #     CRLF only. Cf. secret_in_url.cr / issues_export.one_line.
      #   * the BODY is taken VERBATIM. This file used to say the detail was for "PASSIVE
      #     ANALYSIS only (never re-sent), so scrub is lossless here" — and that is false:
      #     `Scan.scan_repeaters` hands it to `Active.analyze`, which puts `plan.request` on
      #     the wire. Scrubbing turned a binary/protobuf/multipart body's `00 ff 41 fe` into
      #     `00 ef bf bd 41 ef bf bd`, so the probe measured a request the operator never
      #     authored — differential rules compared against a differently-framed baseline, and
      #     corrupted bytes reached the origin.
      #
      # Take whichever blank-line boundary occurs FIRST — the editor uses bare-LF, so a
      # literal "\r\n\r\n" inside the body must not win over the true earlier "\n\n" head
      # boundary (the naive `crlf || lf` fallback would snap to the body's sequence).
      raw_req = record.request
      sep_crlf = index_seq(raw_req, "\r\n\r\n".to_slice)
      sep_lf = index_seq(raw_req, "\n\n".to_slice)
      sep = [sep_crlf, sep_lf].compact.min?
      req_head_s = String.new(sep ? raw_req[0, sep] : raw_req).scrub
      body_start = sep ? sep + (sep == sep_crlf ? 4 : 2) : nil
      # The Repeater editor serializes request text with BARE-LF line endings, but
      # Http1.parse_headers recognizes only CRLF: without normalizing the internal separators,
      # the first CRLF found is the appended terminator, so parse_headers starts at the blank
      # line and returns an EMPTY header list — every request-side rule (CORS Origin, Basic
      # auth, request tech fingerprints) then silently misses on Repeater/CLI/MCP-sourced scans.
      # Normalize LF→CRLF, then ensure the head ends with a blank line for parse_request_head.
      head_crlf = req_head_s.gsub(/\r?\n/, "\r\n")
      req_head_bytes = (head_crlf.ends_with?("\r\n\r\n") ? head_crlf : "#{head_crlf.rstrip}\r\n\r\n").to_slice
      req_body = body_start.try { |i| i < raw_req.size ? raw_req[i, raw_req.size - i] : nil }

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
        body.try(&.size.to_i64), record.response_duration_us, content_type,
        # The REQUEST's type too, like a captured row carries since V14 — `Proto.classify`
        # reads it, and a synthetic row that left it nil would classify a gRPC repeater send
        # as plain HTTP whenever the response came back without the type (an error, a proxy).
        request_content_type: MediaType.of(req_head_bytes))

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
