require "./builder"
require "../env"
require "../flow_mapper"
require "../proxy/codec/http1"

module Gori
  module Import
    # Ingest for formats that carry a RAW HTTP message (the wire bytes) rather than a
    # structured description of one — today that means Burp's item export.
    #
    # `Builder` is a SERIALIZER: it takes {method, target, headers, body} and writes a head.
    # Round-tripping raw bytes through it would normalize the head, re-emit Content-Length
    # and reject the entry on `Builder::HEADER_INJECT` — destroying exactly what makes a
    # saved Burp item worth importing, since those are frequently hand-forged requests. So
    # this path stores the head BYTE-EXACT and only derives the storage projections, which
    # is the same stance the imported request TARGET already takes (#400, DESIGN.md §7).
    module Raw
      # `url` supplies scheme/host/port ONLY. The target comes from the raw request-line, so
      # a smuggling payload in the path survives import verbatim; the URL is just how we
      # learn which origin the operator captured it from.
      def self.flow(created_at : Int64, url : String, raw_request : Bytes,
                    raw_response : Bytes? = nil, duration_us : Int64? = nil) : Builder::FlowPair
        scheme, host, port, _ = Builder.endpoint(url)

        head, body = split(raw_request)
        raise Gori::Error.new("empty raw request") if head.empty?
        req = Proxy::Codec::Http1.parse_request_head(head)
        stored, trunc, size = Builder.capped(body)
        request = FlowMapper.request(req,
          scheme: scheme, host: host, port: port, created_at: created_at,
          body: stored, body_truncated: trunc, body_size: size)

        return Builder::FlowPair.new(request, nil) if raw_response.nil? || raw_response.empty?

        resp_head, resp_body = split(raw_response)
        resp = Proxy::Codec::Http1.parse_response_head(resp_head)
        resp_stored, resp_trunc, resp_size = Builder.capped(resp_body)
        response = FlowMapper.response(resp, flow_id: 0,
          body: resp_stored, duration_us: duration_us,
          body_truncated: resp_trunc, body_size: resp_size)
        Builder::FlowPair.new(request, response)
      end

      # Split wire bytes into {head, body}. Two things matter here:
      #
      # 1. The boundary is whichever blank line comes FIRST POSITIONALLY (`\n\n` or
      #    `\r\n\r\n`), not whichever form is checked first — an LF-only head followed by a
      #    body containing CRLFCRLF would otherwise split in the wrong place.
      # 2. The head is CRLF-normalized. `Http1.parse_headers` scans for CRLF only and
      #    returns an EMPTY header list for an LF-only head (see probe/from_repeater.cr),
      #    so an editor-authored or Unix-normalized Burp item would import with no headers
      #    at all. The BODY is never touched — it may be binary.
      def self.split(bytes : Bytes) : {Bytes, Bytes?}
        cut, skip = boundary(bytes)
        head = Env.normalize_crlf(bytes[0, cut])
        head = terminate(head)
        body = skip > 0 && cut + skip < bytes.size ? bytes[(cut + skip)..].dup : nil
        {head, body}
      end

      # {offset of the blank line, its length} — {bytes.size, 0} when the message is all head.
      private def self.boundary(bytes : Bytes) : {Int32, Int32}
        n = bytes.size
        i = 0
        while i < n
          b = bytes.unsafe_fetch(i)
          if b == 0x0A_u8 && i + 1 < n && bytes.unsafe_fetch(i + 1) == 0x0A_u8
            return {i + 1, 1}
          end
          if b == 0x0D_u8 && i + 3 < n && bytes.unsafe_fetch(i + 1) == 0x0A_u8 &&
             bytes.unsafe_fetch(i + 2) == 0x0D_u8 && bytes.unsafe_fetch(i + 3) == 0x0A_u8
            return {i + 2, 2}
          end
          i += 1
        end
        {n, 0}
      end

      # Every stored head ends in CRLFCRLF (that is what live capture writes and what
      # `Http1.read_head` returns), so a body-less item saved without its trailing blank
      # line still round-trips through the Repeater unchanged.
      private def self.terminate(head : Bytes) : Bytes
        return head if head.size >= 4 && head[-4, 4] == "\r\n\r\n".to_slice
        tail = head.size >= 2 && head[-2, 2] == "\r\n".to_slice ? "\r\n" : "\r\n\r\n"
        buf = IO::Memory.new(head.size + tail.bytesize)
        buf.write(head)
        buf << tail
        buf.to_slice
      end
    end
  end
end
