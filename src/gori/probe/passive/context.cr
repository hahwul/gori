require "../../store"
require "../../proxy/codec/http1"
require "../../proxy/codec/content_decode"

module Gori
  module Probe
    module Passive
      # Everything a passive rule needs about one captured flow, parsed/decoded ONCE and
      # shared across rules (the request/response heads, the URL, and a lazily-decoded body
      # text). Passing this to every rule keeps each rule self-contained and avoids re-parsing.
      # Optional `ws_messages` feeds the WebSocket payload rule (empty for plain HTTP).
      class Context
        BODY_CAP = 64 * 1024 # per-side ceiling on body text fed to the string scans

        getter detail : Store::FlowDetail
        getter req : Proxy::Codec::RawRequest
        getter url : String
        getter ws_messages : Array(Store::WsMessage)

        @resp : Proxy::Codec::RawResponse?
        @body_text : String?
        @body_text_done = false

        def initialize(@detail : Store::FlowDetail, @ws_messages = [] of Store::WsMessage)
          @req = Proxy::Codec::Http1.parse_request_head(@detail.request_head)
          @resp = @detail.response_head.try { |h| Proxy::Codec::Http1.parse_response_head(h) }
          @url = @detail.row.url
        end

        def row : Store::FlowRow
          @detail.row
        end

        def host : String
          row.host
        end

        # Source flow id for Detection.flow_id. Synthetic Repeater details use id 0 when there
        # is no parent History flow — treat that as nil so we never link to a non-existent row.
        def fid : Int64?
          id = row.id
          id > 0 ? id : nil
        end

        def scheme : String
          row.scheme
        end

        def content_type : String?
          row.content_type
        end

        def html? : Bool
          !!content_type.try(&.downcase.includes?("text/html"))
        end

        def request_origin : String?
          @req.headers.get?("Origin")
        end

        # The parsed response head if one exists (including a 101 upgrade) — used by the tech
        # fingerprints, which inspect upgrade/server headers regardless of status.
        def raw_response : Proxy::Codec::RawResponse?
          @resp
        end

        # A real, scorable HTTP response: excludes a 101 upgrade and the synthetic status 0
        # (no response captured). The header/cookie/CORS/body rules gate on this.
        def response : Proxy::Codec::RawResponse?
          r = @resp
          return nil if r.nil? || row.status == 101 || row.status == 0
          r
        end

        # Decoded, capped, scrubbed response body text — computed once and shared by the rules
        # that scan the body. nil when there is no body.
        def body_text : String?
          return @body_text if @body_text_done
          @body_text_done = true
          # Only the first BODY_CAP bytes are scanned, so cap the inflate too: a large
          # compressed body stops decoding at the prefix instead of expanding in full.
          decoded, _ = Proxy::Codec::ContentDecode.decode(@detail.response_head, @detail.response_body, BODY_CAP)
          bytes = decoded || @detail.response_body
          @body_text = (bytes && !bytes.empty?) ? String.new(bytes[0, {bytes.size, BODY_CAP}.min]).scrub : nil
        end
      end
    end
  end
end
