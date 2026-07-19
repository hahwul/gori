require "../../store"
require "../../proxy/codec/http1"
require "../../proxy/codec/content_decode"
require "./js_scan"

module Gori
  module Probe
    module Passive
      # Everything a passive rule needs about one captured flow, parsed/decoded ONCE and
      # shared across rules (the request/response heads, the URL, and a lazily-decoded body
      # text). Passing this to every rule keeps each rule self-contained and avoids re-parsing.
      # Optional `ws_messages` feeds the WebSocket payload rule (empty for plain HTTP).
      class Context
        BODY_CAP = 64 * 1024 # per-side ceiling on body text fed to the string scans
        # A larger ceiling used ONLY by the client-side rules: DOM sinks in real minified SPA
        # bundles routinely sit past the 64 KiB body_text prefix, so those rules decode more.
        CLIENT_BODY_CAP = 256 * 1024

        getter detail : Store::FlowDetail
        getter ws_messages : Array(Store::WsMessage)

        @req : Proxy::Codec::RawRequest?
        @resp : Proxy::Codec::RawResponse?
        @resp_done = false
        @url : String?
        @decoded_body : Bytes?
        @decoded_body_done = false
        @body_text : String?
        @body_text_done = false
        @client_body_text : String?
        @client_body_text_done = false
        @client_scripts : Array(String)?
        @client_scripts_nocomment : Array(String)?
        @client_code : Array(String)?
        @ct_low : String?
        @ct_low_done = false
        @html : Bool?
        @js : Bool?

        def initialize(@detail : Store::FlowDetail, @ws_messages = [] of Store::WsMessage)
        end

        # Request head parsed lazily + memoized. The HTTP analyze() path reaches this on its
        # first rule (Tech), so total work is unchanged there; but the WS-rescan path
        # (analyze_ws → only WsPayloads, which never reads req/response) then no longer parses
        # the handshake heads on every frame batch of a chatty 101 socket. parse_request_head
        # is pure and total (never raises), so lazy is behavior-identical.
        def req : Proxy::Codec::RawRequest
          @req ||= Proxy::Codec::Http1.parse_request_head(@detail.request_head)
        end

        # Source URL, built lazily (a WS frame batch that emits no detection never touches it).
        def url : String
          @url ||= @detail.row.url
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

        # The response Content-Type, downcased ONCE per flow. html?/js? are each called from
        # several rules plus the body getters (~12 calls per flow between them), and every call
        # used to allocate its own throwaway downcased copy of the same header value. Rules that
        # need to run their own substring tests should read this rather than downcase again.
        def ct_low : String?
          return @ct_low if @ct_low_done
          @ct_low_done = true
          @ct_low = content_type.try(&.downcase)
        end

        # Memoised: the answer cannot change for a given flow, and both getters sit on the
        # per-flow path that the passive fiber shares with the proxy.
        def html? : Bool
          h = @html
          return h unless h.nil?
          @html = !!ct_low.try(&.includes?("text/html"))
        end

        # A JavaScript response (external bundle / module), distinct from an HTML document with
        # inline scripts. Used to gate the client-side rules alongside html?.
        def js? : Bool
          j = @js
          return j unless j.nil?
          low = ct_low
          @js = low.nil? ? false : (low.includes?("javascript") || low.includes?("ecmascript"))
        end

        def request_origin : String?
          req.headers.get?("Origin")
        end

        # The parsed response head if one exists (including a 101 upgrade) — used by the tech
        # fingerprints, which inspect upgrade/server headers regardless of status. Parsed lazily
        # + memoized with a done-flag so a genuine nil (no response head) is not re-tested.
        def raw_response : Proxy::Codec::RawResponse?
          return @resp if @resp_done
          @resp_done = true
          @resp = @detail.response_head.try { |h| Proxy::Codec::Http1.parse_response_head(h) }
        end

        # A real, scorable HTTP response: excludes a 101 upgrade and the synthetic status 0
        # (no response captured). The header/cookie/CORS/body rules gate on this.
        def response : Proxy::Codec::RawResponse?
          r = raw_response
          return nil if r.nil? || row.status == 101 || row.status == 0
          r
        end

        # Response body inflated ONCE at the largest cap any rule needs, then shared by both
        # body_text (a BODY_CAP prefix) and client_body_text (a CLIENT_BODY_CAP prefix). For an
        # HTML/JS document BOTH getters are live, so decoding here — at CLIENT_BODY_CAP — content-
        # decodes the body a single time instead of twice: the deterministic first BODY_CAP bytes
        # of the larger inflate are byte-identical to a BODY_CAP-capped inflate, so body_text is
        # unchanged. A non-document flow needs only BODY_CAP, so it caps there and never over-
        # inflates. An unencoded body returns its raw bytes verbatim (the per-getter slice caps it).
        private def decoded_body : Bytes?
          return @decoded_body if @decoded_body_done
          @decoded_body_done = true
          cap = (html? || js?) ? CLIENT_BODY_CAP : BODY_CAP
          decoded, _ = Proxy::Codec::ContentDecode.decode(@detail.response_head, @detail.response_body, cap)
          @decoded_body = decoded || @detail.response_body
        end

        # Decoded, capped, scrubbed response body text — computed once and shared by the rules
        # that scan the body. nil when there is no body. Slices the shared `decoded_body` buffer
        # to its first BODY_CAP bytes.
        def body_text : String?
          return @body_text if @body_text_done
          @body_text_done = true
          bytes = decoded_body
          @body_text = (bytes && !bytes.empty?) ? String.new(bytes[0, {bytes.size, BODY_CAP}.min]).scrub : nil
        end

        # Decoded, larger-capped (CLIENT_BODY_CAP), scrubbed body — computed once and shared by
        # the client-side rules. Only materialised for an HTML or JS response (a non-document
        # flow pays nothing); slices the same shared `decoded_body` buffer as body_text.
        def client_body_text : String?
          return @client_body_text if @client_body_text_done
          @client_body_text_done = true
          return @client_body_text = nil unless html? || js?
          bytes = decoded_body
          @client_body_text = (bytes && !bytes.empty?) ? String.new(bytes[0, {bytes.size, CLIENT_BODY_CAP}.min]).scrub : nil
        end

        # RAW executable JS fragments (inline <script> bodies for HTML, whole body for JS),
        # extracted once and shared. The string-literal-driven client rules (postMessage,
        # prototype pollution) scan these so a "message"/"__proto__" string is still visible.
        def client_scripts : Array(String)
          @client_scripts ||= JsScan.scripts(client_body_text, html?, js?)
        end

        # The same fragments with comments and string/template literals blanked (JsScan.strip),
        # so the DOM-XSS source->sink correlation never matches a sink or source that lived in a
        # string or comment. Memoised so the lex runs at most once per flow.
        def client_code : Array(String)
          @client_code ||= client_scripts.map { |s| JsScan.strip(s) }
        end

        # The fragments with ONLY comments blanked (string/template CONTENTS kept). The
        # string-literal-keyed rules (postMessage, prototype pollution) scan these so a
        # "message"/"__proto__" inside a live string is still seen, but the same keyword in a
        # commented-out example/debug line no longer false-matches. Memoised per flow.
        def client_scripts_nocomment : Array(String)
          @client_scripts_nocomment ||= client_scripts.map { |s| JsScan.strip_comments(s) }
        end

        # --- region text for user-defined custom match rules ---------------------------------
        # Scrubbed views of each message region so a custom rule can match string/regex against
        # request/response × header/body/whole. Lazy + memoized; a rule that never asks pays
        # nothing. body_text (above) already covers the response body region.
        @req_head_text : String?
        @req_body_text : String?
        @req_body_text_done = false
        @resp_head_text : String?
        @resp_head_text_done = false

        # Raw request head (request line + headers) as scrubbed text.
        def request_head_text : String
          @req_head_text ||= String.new(@detail.request_head).scrub
        end

        # Decoded, capped, scrubbed request body text (nil when there is no body). A request body
        # is rarely content-encoded, but decode through the request head anyway so a gzip'd upload
        # still matches on its plaintext.
        def request_body_text : String?
          return @req_body_text if @req_body_text_done
          @req_body_text_done = true
          body = @detail.request_body
          if body && !body.empty?
            decoded, _ = Proxy::Codec::ContentDecode.decode(@detail.request_head, body, BODY_CAP)
            bytes = decoded || body
            @req_body_text = String.new(bytes[0, {bytes.size, BODY_CAP}.min]).scrub
          end
          @req_body_text
        end

        # Scrubbed response head (status line + headers); nil when no response head was captured.
        def response_head_text : String?
          return @resp_head_text if @resp_head_text_done
          @resp_head_text_done = true
          @resp_head_text = @detail.response_head.try { |h| String.new(h).scrub }
        end
      end
    end
  end
end
