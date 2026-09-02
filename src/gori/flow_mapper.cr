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
                     body_truncated : Bool = false, body_size : Int64? = nil,
                     short_circuited : Bool = false,
                     advisory : String? = nil,
                     source : FlowSource::Kind,
                     source_surface : FlowSource::Surface? = nil,
                     source_ref : String? = nil) : Store::CapturedRequest
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
        short_circuited: short_circuited,
        advisory: advisory,
        source: source,
        source_surface: source_surface,
        source_ref: source_ref,
      )
    end

    def self.response(resp : Proxy::Codec::RawResponse, *, flow_id : Int64,
                      body : Bytes? = nil, ttfb_us : Int64? = nil,
                      duration_us : Int64? = nil,
                      state : Store::FlowState = Store::FlowState::Complete,
                      error : String? = nil,
                      body_truncated : Bool = false, body_size : Int64? = nil,
                      advisory : String? = nil) : Store::CapturedResponse
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
        advisory: advisory,
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

    # No response was DELIVERED (upstream failure, timeout, or a head gori refused to
    # forward). We still record the flow so the human sees the failure (P4/P7).
    # `duration_us` preserves the attempt time (how long before the failure) so an error
    # Flow isn't left with a null duration in History.
    #
    # `head` is for the second kind: the origin answered and gori declined to relay it — a
    # CL+TE response, a 1xx that declared a body. Those octets are the FINDING, not noise
    # around it (P7): a response-desync primitive is exactly what an operator points gori at,
    # and recording only gori's sentence about it left `gori run show --format raw` with
    # nothing to print. `status` stays 0 either way — gori delivered no response, and both
    # `Tui::FlowStatus` and `Repeater::ExchangeMeta` read an error row's status as that.
    #
    # The default is `Bytes.new(0)` and NOT `Bytes.empty`: the latter carries a null pointer,
    # which the SQLite driver binds as SQL NULL, and `Export::Har.skip_reason` keys on the
    # difference between a NULL head (Pending) and an EMPTY one (Error/Aborted) — the R4-F3
    # case in `spec/export/har_spec.cr`.
    def self.error_response(flow_id : Int64, message : String, duration_us : Int64? = nil,
                            head : Bytes = Bytes.new(0)) : Store::CapturedResponse
      Store::CapturedResponse.new(
        flow_id: flow_id,
        status: 0,
        head: head,
        body: nil,
        duration_us: duration_us,
        state: Store::FlowState::Error,
        error: message,
      )
    end
  end
end
