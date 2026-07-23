require "./proxy/codec/message"
require "./store/models"

module Gori
  # The single boundary where wire messages (truth) become storage projections.
  # Keeping all projection extraction in one place means the History list / QL
  # columns have exactly one definition (and one place to fix). The raw head
  # bytes pass straight through as the truth (P7); connection-level context
  # (scheme/host/port/tls) is supplied by the proxy, which already resolved it.
  module FlowMapper
    def self.request(req : Proxy::Codec::RawRequest, *,
                     scheme : String, host : String, port : Int32, created_at : Int64,
                     body : Bytes? = nil, sni : String? = nil,
                     alpn : String? = nil, tls_version : String? = nil,
                     body_truncated : Bool = false, body_size : Int64? = nil) : Store::CapturedRequest
      # A malformed request-line (unencoded space ⇒ >3 tokens, or the h2 preface) makes
      # split(' ') mis-slice target/version — target becomes a truncated fragment and
      # version a garbage token. RawRequest keeps those for the live forwarding/keep-alive
      # logic, but they must NOT reach storage: History would render a
      # deceptively-plausible-but-wrong URL and the garbage token would pollute the
      # http_version column. Store the verbatim request-line as the target (honestly broken
      # and greppable) and blank the version. The raw head bytes remain the byte-exact truth
      # (P7) regardless.
      malformed = req.malformed?
      Store::CapturedRequest.new(
        created_at: created_at,
        scheme: scheme,
        host: host,
        port: port,
        method: req.method,
        target: malformed ? req.request_line : req.target,
        http_version: malformed ? "" : req.version,
        head: req.raw_head,
        body: body,
        sni: sni,
        alpn: alpn,
        tls_version: tls_version,
        body_truncated: body_truncated,
        body_size: body_size,
      )
    end

    def self.response(resp : Proxy::Codec::RawResponse, *, flow_id : Int64,
                      body : Bytes? = nil, ttfb_us : Int64? = nil,
                      duration_us : Int64? = nil,
                      state : Store::FlowState = Store::FlowState::Complete,
                      error : String? = nil,
                      body_truncated : Bool = false, body_size : Int64? = nil) : Store::CapturedResponse
      Store::CapturedResponse.new(
        flow_id: flow_id,
        status: resp.status,
        head: resp.raw_head,
        body: body,
        reason: resp.reason.presence,
        content_type: resp.headers.get?("Content-Type"),
        content_encoding: resp.headers.get?("Content-Encoding"),
        ttfb_us: ttfb_us,
        duration_us: duration_us,
        state: state,
        error: error,
        body_truncated: body_truncated,
        body_size: body_size,
      )
    end

    # A flow the human deliberately dropped via Intercept (P4). Recorded as
    # Aborted so it's visible in History distinct from upstream errors.
    def self.aborted_response(flow_id : Int64, message : String, *,
                              ttfb_us : Int64? = nil, duration_us : Int64? = nil) : Store::CapturedResponse
      Store::CapturedResponse.new(
        flow_id: flow_id,
        status: 0,
        head: Bytes.new(0),
        body: nil,
        ttfb_us: ttfb_us,
        duration_us: duration_us,
        state: Store::FlowState::Aborted,
        error: message,
      )
    end

    # No response was obtained (upstream failure, timeout). We still record the
    # flow so the human sees the failure (P4/P7). `duration_us` preserves the
    # attempt time (how long before the failure) so an error Flow isn't left with
    # a null duration in History.
    def self.error_response(flow_id : Int64, message : String, duration_us : Int64? = nil) : Store::CapturedResponse
      Store::CapturedResponse.new(
        flow_id: flow_id,
        status: 0,
        head: Bytes.new(0),
        body: nil,
        duration_us: duration_us,
        state: Store::FlowState::Error,
        error: message,
      )
    end
  end
end
