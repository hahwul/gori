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
      Store::CapturedRequest.new(
        created_at: created_at,
        scheme: scheme,
        host: host,
        port: port,
        method: req.method,
        target: req.target,
        http_version: req.version,
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
    # flow so the human sees the failure (P4/P7).
    def self.error_response(flow_id : Int64, message : String) : Store::CapturedResponse
      Store::CapturedResponse.new(
        flow_id: flow_id,
        status: 0,
        head: Bytes.new(0),
        body: nil,
        state: Store::FlowState::Error,
        error: message,
      )
    end
  end
end
