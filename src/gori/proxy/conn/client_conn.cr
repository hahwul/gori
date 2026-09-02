require "uri"
require "../codec/http1"
require "../codec/body"
require "../codec/content_decode"
require "../sink"
require "../head_rewriter"
require "../extractor"
require "../../interceptor"
require "../../host_overrides"
require "../../outbound"
require "../prefix_io"
require "../socket_tuning"
require "../h2/relay"
require "../h2/frame"
require "../tls/client_hello"
require "../connect"
require "../upstream"
require "../pump"
require "../ws/relay"
require "../ws/handshake"
require "../../flow_mapper"
require "../../alt_svc"
require "../../sse"
require "./self_page"

module Gori::Proxy
  # Why this connection is speaking HTTP/1.1 rather than HTTP/2 — the OBSERVED reason, stamped
  # by whoever made the decision, rather than re-derived afterwards by whoever needs to explain
  # it. `ClientConn` reads exactly one of these back when an h2/gRPC client's preface lands on
  # the h1 path.
  #
  # It exists because re-deriving was wrong. The old message hard-coded two causes ("settings
  # network.http2 is \"off\" or a Match&Replace body rule is live") and pointed at a
  # `gori.log` line that names which — but `Tls::Tunnel#h2_candidate?` has FOUR such branches
  # now, and the common case is none of them: the tunnel offered h2, the ORIGIN answered
  # `http/1.1` at ALPN, `notice_downgrade` never ran, and nothing was ever written to
  # `gori.log`. So the operator was told to change a setting that was already correct and to
  # read a line that did not exist. A refusal that names the wrong reason costs more time than
  # one that names none.
  enum H2Offer
    # The causeless fallback, for a caller with no observation to stamp: it names no reason
    # rather than guessing one.
    Unknown
    # h2 was offered to the client and the client did not select it at ALPN (curl --http1.1,
    # an old browser). Nothing is wrong; the client chose.
    Offered
    # No TLS handshake on the leg that would have carried an ALPN offer: a cleartext ORIGIN
    # inside a tunnel (`tls/tunnel.cr`), or a cleartext LISTENER, where the client itself
    # arrived without one. ALPN lives inside a TLS handshake, so there was nothing to reflect,
    # and gori has no h2c of its own to offer instead.
    Cleartext
    # The four `h2_candidate?` downgrades. Each one DID write a `gori.log` line, so each one
    # may point at it.
    DisabledBySetting
    BodyRule
    ShortCircuitRule
    ExtractRule
    # The origin completed a TLS handshake and chose HTTP/1.1 at ALPN, so gori did not offer
    # h2 to the client either (there is no h2↔h1 bridge — see `reflect_origin_h2`).
    UpstreamDeclined
    # The h2 ALPN probe to the origin never completed (unreachable, or a TLS/verify refusal),
    # so gori could not learn what it speaks and kept the client on h1.
    UpstreamUnreachable

    # The sentence recorded on a flow when an h2/gRPC preface is refused on the h1 path. Only
    # the branches that actually write to `gori.log` mention it.
    def refusal_reason : String
      case self
      in Unknown             then "HTTP/2 was not negotiated on this connection"
      in Offered             then "HTTP/2 was offered to this client and it selected HTTP/1.1 at ALPN, then spoke the HTTP/2 preface anyway"
      in Cleartext           then "this connection has a cleartext leg that carried no ALPN — and ALPN, inside a TLS handshake, is the only way gori offers HTTP/2; gori does not serve h2c prior-knowledge here"
      in DisabledBySetting   then "HTTP/2 is switched off (settings network.http2; set it back to \"auto\" to keep h2) — gori.log has the matching \"h2 downgrade: <host> ...\" line"
      in BodyRule            then "a Match&Replace BODY rule is live for this host and body rewriting on HTTP/2 is not implemented yet — gori.log has the matching \"h2 downgrade: <host> ...\" line"
      in ShortCircuitRule    then "a Match&Replace short-circuit rule is live for this host and the h2 relay cannot answer a request locally — gori.log has the matching \"h2 downgrade: <host> ...\" line"
      in ExtractRule         then "a session-binding extract rule reads the response BODY for this host and body extraction on HTTP/2 is not implemented yet — gori.log has the matching \"h2 downgrade: <host> ...\" line"
      in UpstreamDeclined    then "the ORIGIN did not negotiate HTTP/2 (it chose HTTP/1.1 at ALPN), so gori did not offer h2 to this client either — gori does not translate between h2 and h1. Nothing on this proxy needs changing"
      in UpstreamUnreachable then "gori's HTTP/2 ALPN probe to the origin did not complete (unreachable, or the upstream TLS handshake was refused), so it could not learn whether the origin speaks h2 and kept this client on HTTP/1.1"
      end
    end
  end

  # Handles one client connection over an `IO` (a plaintext TCPSocket, or — after
  # the CONNECT/TLS handoff — a decrypted TLS socket; the same loop serves both,
  # which is why it is written against `IO`). Reads requests in a keep-alive
  # loop, forwards them byte-faithfully, captures the request/response pair, and
  # streams the response back.
  class ClientConn
    # Max consecutive interim 1xx responses to forward before giving up — a guard
    # against a hostile upstream streaming an unbounded run of body-less 103s.
    MAX_INTERIM = 64

    # How many DISTINCT compressed-body Match&Replace refusals one connection writes to
    # `gori.log` before it stops (#745). A tunnel is pinned to one host and can only reach two
    # or three keys; a cleartext forward-proxy connection carries whatever hosts the client
    # asks for, so the set is bounded rather than trusted. The FLOW advisory is unaffected —
    # it is one column on the flow it describes and cannot flood anything.
    COMPRESSED_SKIP_LOG_CAP = 8

    # How long the streaming request path waits for the ORIGIN to answer an
    # `Expect: 100-continue` before giving up on it and unblocking the client itself (#728).
    #
    # It has to be bounded, and short. A great many origins simply ignore the expectation and
    # wait for the body (RFC 9110 §10.1.1 permits exactly that), so an unbounded wait here
    # would trade the old three-way deadlock for a new one. 1 s is curl's own
    # `--expect100-timeout` default, i.e. the interval clients already budget for this — and
    # it costs nothing next to the status quo, where the client was the one paying it.
    EXPECT_CONTINUE_WAIT = 1.second

    # The interim gori writes ITSELF when it cannot get one from the origin — either because
    # the origin did not answer in time, or because this path had to have the whole body in
    # hand before it could dial at all (intercept hold / body rewrite / short circuit).
    # HTTP/1.1-only: `expect_continue?` carries the version test for both the buffering and the
    # streaming path, exactly as `skip_interim_responses` does its own, so a 1.0 client never
    # sees a 1xx — and never waits on one either.
    CONTINUE_RESPONSE = "HTTP/1.1 100 Continue\r\n\r\n".to_slice

    # `fixed_host`/`fixed_port` pin all requests to one origin (post-CONNECT TLS
    # tunnel); when nil the upstream is resolved per request from the target /
    # Host header (plaintext forward proxy). `tls_upstream` wraps the origin
    # connection in TLS.
    #
    # `default_port` overrides the port used when an origin-form request's Host header names
    # none. It exists for the TRANSPARENT listener: there the client dialled a port the kernel
    # redirected, so 80 is not necessarily right (see Settings::Listener#target_port). nil keeps
    # the scheme default. It is the DECLARED answer, used when the kernel has none.
    #
    # `origin_dst` is the kernel's own answer for the same connection — the address and port the
    # client dialled before the redirect rewrote them (`Proxy::OrigDst`). It settles three
    # different things, and keeping them apart is what #529 is:
    #
    #   - PORT — it outranks `default_port` AND a port in the `Host` header: the header's port
    #     is a claim about the very connection the kernel is describing, so the two can only
    #     disagree by the header being wrong or hostile. An ABSOLUTE-form target still wins
    #     outright, unchanged: that branch is the forward-proxy contract and a transparent
    #     client does not emit one.
    #   - NAME — it does NOT. The `Host` header still supplies it, because a name is what the
    #     request is addressed to, what scope matches and what History shows. `origin_dst`'s
    #     address fills in only when there is no name at all (an HTTP/1.0 or malformed request
    #     with no usable Host).
    #   - DIAL ADDRESS — it does, always (`dial_pin`). The name above is carried all the way
    #     through capture and matching, but it is no longer RESOLVED: the TCP connect goes to
    #     the address the kernel says this connection was headed for. Before #529 the name did
    #     both jobs, so a client that lied in `Host` steered gori's upstream dial to a host of
    #     its choosing. See `Upstream.connect_target` for where the pin sits relative to a
    #     hostname override.
    #
    # `rewrite_fixed_host` replaces the forwarded `Host` header with `fixed_host`'s authority.
    # It exists ONLY for a reverse listener whose operator declared `rewrite_host: true`, and it
    # is off everywhere else including the post-CONNECT tunnel — a conventional reverse proxy
    # rewrites Host implicitly, but that is a mutation of operator-supplied bytes on the live
    # path (P7), so here it has to be asked for. What is CAPTURED is unaffected: the client's
    # original head is what History shows, exactly as with a Match&Replace-free forward.
    def initialize(@io : IO, @scheme : String, @sink : FlowSink, @tls : TlsMitm? = nil,
                   @fixed_host : String? = nil, @fixed_port : Int32 = 0,
                   @listener_pinned : Bool = false,
                   @tls_upstream : Bool = false, @verify_upstream : Bool = true,
                   @rewriter : HeadRewriter? = nil, @interceptor : Gori::Interceptor? = nil,
                   @host_overrides : Gori::HostOverrides? = nil,
                   @self_addr : {String, Int32}? = nil,
                   @local_host : String? = nil,
                   @default_port : Int32? = nil,
                   @origin_dst : {String, Int32}? = nil,
                   @rewrite_fixed_host : Bool = false,
                   @extractor : ResponseExtract? = nil,
                   # Everything after this marker is named-only, which is how a REQUIRED
                   # parameter follows defaulted ones at all — and it is the shape that makes
                   # the requirement useful: they can only ever be spelled out.
                   *,
                   # REQUIRED, and deliberately: this is a claim about the TRANSPORT this
                   # connection arrived on, and only the caller that built it can make one. It
                   # was defaulted to `Cleartext` while the only non-stamping callers were the
                   # cleartext listeners in `server.cr`, which is what those observed — but a
                   # default means the NEXT caller inherits their claim by saying nothing, and
                   # the whole point of #731 was that a refusal naming the wrong reason costs
                   # more time than one naming none. A caller with nothing to observe has
                   # `H2Offer::Unknown`, which names no reason rather than guessing one.
                   @h2_offer : H2Offer,
                   # REQUIRED for the same reason, and it is a DIFFERENT claim than `h2_offer`
                   # above: did gori terminate TLS on the leg this connection arrived on? True
                   # only from `Tls::Tunnel#intercept` — the post-CONNECT tunnel and the
                   # transparent/reverse TLS listeners — false on every cleartext listener.
                   #
                   # `H2Offer::Cleartext` cannot answer it: that member covers "no TLS handshake
                   # on the leg that would have carried an ALPN offer", which is TRUE both for a
                   # cleartext listener AND for a cleartext ORIGIN inside a TLS tunnel, where the
                   # client leg is very much encrypted. Nor can `@tls`, which is what
                   # `record_non_http` used to ask (#755): `@tls` is the CONNECT MITM seam and is
                   # passed only by the cleartext forward-proxy listener, so it answered this
                   # question exactly backwards — "gori terminated TLS on this connection" for a
                   # plaintext :8080 client, and "this listener expects HTTP" inside the
                   # decrypted tunnel where `network.tls_passthrough` is the actual remedy.
                   #
                   # Read only by `non_http_remedy`, i.e. only to word an error flow's advice.
                   @client_tls : Bool)
      # Per-connection upstream reuse (see `acquire_upstream`). One live origin
      # connection kept across this client's keep-alive requests.
      @upstream = nil.as(IO?)
      @up_host = nil.as(String?)
      @up_port = 0
      # One 64 KiB copy buffer reused across every request AND response body forwarded on
      # this connection (see `copy_buf`), so a keep-alive stream stops churning a large-object
      # allocation per body. Lazily allocated on the first body copy.
      @copy_buf = nil.as(Bytes?)
      # Why the most recent upstream dial failed, set by `open_upstream` and read only when a
      # dial returned nil — lets a failed flow distinguish unreachable from a TLS/verify
      # rejection (the #323 case, whose fix is --insecure-upstream) and from an upstream proxy
      # that refused the tunnel outright. See `upstream_error_message`.
      @last_dial_error = nil.as(Upstream::DialError?)
      # Did gori remove THIS request's `Sec-WebSocket-Extensions` offer (#518)? Set per
      # request by `strip_ws_extension_offer`, read by the 101 path: an acceptance is only
      # gori's to remove when gori is the reason nothing was offered. See `WS::Handshake`.
      @ws_offer_stripped = false
      # What gori removed from THIS response's head on its own account — today only an h3
      # `Alt-Svc` (see `settle_alt_svc`) — carried to whichever record site the response takes
      # so the flow says so (`Store::FlowRow#advisory`). Assigned unconditionally at the seam,
      # which is what resets it between keep-alive requests on this connection.
      @alt_svc_note = nil.as(String?)
      # What is wrong with THIS response's start-line, or nil when it is a status line. Set
      # from the PEER's final head (before any rule touches it) in `handle_response` and
      # folded into the record by `response_advisory`, exactly like `@alt_svc_note` above —
      # and reset the same way, by being assigned unconditionally at that seam.
      @status_line_note = nil.as(String?)
      # Hosts whose h3 `Alt-Svc` strip this connection has already written to `gori.log`. The
      # advisory is the record an operator reads; the log line is for the one debugging a
      # client that stopped using QUIC, and an origin that sends `Alt-Svc` on every response
      # must not write a line per response. Bounded by `COMPRESSED_SKIP_LOG_CAP` for the same
      # reason `@compressed_skips` below is: a cleartext forward-proxy connection serves
      # whatever hosts the client's keep-alive requests name, so the set is bounded rather
      # than trusted.
      @alt_svc_logged = Set(String).new
      # One-shot: has this connection already logged an intercept hold that failed open because
      # the declared body was over the ceiling? See `warn_hold_oversize`.
      @warned_hold_oversize = false
      # Which compressed-body Match&Replace refusals this connection has already written to
      # `gori.log` — see `log_compressed_skip` for the key and the cap.
      @compressed_skips = Set(String).new
      # Has `read_client_head` ever come back with bytes on this connection? The narrow half of
      # the server-speaks-first signal (#755): a zero-byte read timeout is only worth recording on
      # a connection that never carried anything. On one that did, the same timeout is an idle
      # keep-alive reaching its end, which is how a healthy connection dies — see
      # `record_silent_client`.
      @saw_request = false
    end

    # The address every upstream dial on THIS connection is pinned to, or nil when nothing
    # pinned it (every mode but transparent, and transparent where the kernel had no answer —
    # which degrades to resolving the name, exactly as gori did before #529).
    #
    # Read at the dial, never at resolution: `resolve_forward` keeps handing back the NAME, so
    # the certificate, the sandbox, the passthrough list, scope and History are all untouched
    # by this. Only `Upstream.connect_target` sees it.
    private def dial_pin : String?
      @origin_dst.try(&.[0])
    end

    # The connection-lifetime scratch buffer for body forwarding, allocated on first use.
    # Safe to share across the request and response streams because they run sequentially on
    # this one fiber (the request body is fully forwarded before the response head is read).
    private def copy_buf : Bytes
      @copy_buf ||= Bytes.new(Codec::Body::BUFSIZE)
    end

    # One-shot teardown claim shared between a relaxed-stream copy and its client-abort watcher
    # (see stream_response_body). Deliberately a REFERENCE type: both fibers must see the SAME
    # flag, but the watcher is started with `spawn watch_client_abort(upstream, latch)` (the call
    # form, to avoid loop-var capture), which COPIES its arguments — a captured `Atomic` STRUCT
    # would be duplicated per fiber and the two would never agree (the ConnCounter hazard called
    # out in concurrency_reuse_spec). Whoever calls `claim?` first owns teardown: the watcher
    # closes upstream only if it wins, the copy raises (→ Aborted) only if it lost.
    private class TeardownLatch
      def initialize
        @claimed = Atomic(Int32).new(0)
      end

      # True to the FIRST caller only; false to every caller after. Non-blocking, so on the
      # single proxy thread a claim never interleaves with the other fiber's.
      def claim? : Bool
        @claimed.compare_and_set(0, 1)[1]
      end
    end

    def run : Nil
      loop do
        # Re-arm the client read/write timeout at the START of every keep-alive request, so a
        # prior request that RELAXED the socket for a streamed (SSE/chunked) response then kept
        # the connection alive can't carry that relaxed (untimed) state into the next request.
        SocketTuning.arm(@io, SocketTuning::CLIENT_IO_TIMEOUT)
        break unless handle_request
      end
    rescue
      # any IO error (reset, timeout, broken pipe) ends the connection
    ensure
      release_upstream
      @io.close rescue nil
    end

    # How much of an unparseable start-line the advisory quotes. The "line" can be a body
    # tail of any length, so it is clipped before it becomes a String in a History row.
    STATUS_LINE_QUOTE_MAX = 80

    # Per-connection upstream keep-alive reuse. Within one client connection —
    # especially a TLS-MITM tunnel pinned to a single origin (`@fixed_host`),
    # where EVERY request would otherwise pay a fresh TCP+TLS handshake to the
    # same server — we keep ONE upstream connection open and reuse it across the
    # client's keep-alive requests. Reuse is gated on the origin honouring
    # keep-alive (decided at the end of `handle_response`: complete body, not
    # close-delimited, no `Connection: close`); a connection that goes stale
    # while idle (the origin's own keep-alive timeout fired) is detected as an
    # EOF on the response head and transparently retried for body-less requests.
    # Returns {connection, reused?} — `reused` tells the caller a stale EOF is
    # worth one redial+resend.
    private def acquire_upstream(host : String, port : Int32) : {IO?, Bool}
      if (up = @upstream) && @up_host == host && @up_port == port
        return {up, true}
      end
      release_upstream # different origin (forward-proxy) or none yet — dial fresh
      up = open_upstream(host, port)
      if up
        @upstream = up
        @up_host = host
        @up_port = port
      end
      {up, false}
    end

    private def release_upstream : Nil
      @upstream.try(&.close) rescue nil
      @upstream = nil
      @up_host = nil
      @up_port = 0
    end

    # One client request head, or nil for every way this connection is finished with: a clean
    # close, a keep-alive connection idling to its end, an oversized head, or a read that ran
    # out of time.
    #
    # The head read is the slowloris surface, so total head-assembly time after the first byte
    # is bounded (a drip-feed that a per-read timeout can't catch). The first-byte (idle
    # keep-alive) wait stays bounded by the baseline `CLIENT_IO_TIMEOUT` armed in `run`.
    # `detect_non_http`: this is a client REQUEST head, so a non-HTTP protocol lands here (#729).
    #
    # A timeout used to unwind to `run`'s blanket rescue, which is the silence #755 is about.
    # It is answered HERE rather than there because only this call site knows the read was the
    # CLIENT head — `run`'s rescue also covers every response-head and body read on the way
    # through — and because `HeadTimeout#received` is only meaningful for this one.
    private def read_client_head : Bytes?
      Codec::Http1.read_head(@io,
        deadline: SocketTuning::HEAD_DEADLINE, timeout_sock: SocketTuning.underlying_socket(@io),
        detect_non_http: true)
    rescue ex : Codec::Http1::HeadTimeout
      record_silent_client if ex.received.zero? && !@saw_request
      nil
    end

    # Returns true to keep the connection alive for another request.
    private def handle_request : Bool
      head = read_client_head
      # nil = the client closed, a keep-alive connection went idle to its end, or the read timed
      # out (`read_client_head` has already recorded the one shape of that worth recording).
      # Standalone, not trailing this line: `crystal tool format` re-indents a comment BLOCK that
      # follows a trailing comment to that comment's column, `--check`-clean — which is how the
      # block below sat at column 22 in main.
      return false if head.nil?
      @saw_request = true

      # A non-HTTP protocol reached the HTTP parser on a BINARY preface (MQTT, a raw TLS
      # ClientHello, a binary RPC). `read_head` stopped on that first octet instead of blocking
      # to the deadline (#729); record a VISIBLE flow that names the octet and the remedy —
      # `network.tls_passthrough` — instead of closing in silence, the same way an h2-downgrade
      # rejection names its gate. A TEXT banner (SSH, SMTP) is not caught here and is not meant
      # to be: its first byte is a method-token char, indistinguishable from the version-fuzzing
      # payloads an operator sends on purpose. See `looks_like_http_request?`.
      unless Codec::Http1.looks_like_http_request?(head)
        record_non_http(head, now_us)
        return false
      end

      req = Codec::Http1.parse_request_head(head)
      return handle_connect(req) if req.method.compare("CONNECT", case_insensitive: true) == 0

      started = Time.instant
      created_at = now_us

      # A garbage h2/gRPC client preface forced onto this HTTP/1.1 path by the (intentional)
      # ALPN downgrade — see Tunnel#h2_candidate? — must NOT be treated as a real request: left
      # alone it parses as an ordinary-looking "PRI * HTTP/2.0" request and either gets
      # forwarded to an origin that can't make sense of it, or (Intercept catch mode) sits in
      # the hold queue forever as a confusing fake entry with no indication it was an h2
      # client. Reject the connection cleanly instead. No 502 is written back: a real h2/gRPC
      # client isn't expecting (or able to parse) an HTTP/1.1 response here, and the existing
      # "framing rejected" precedent below also just records + closes.
      #
      # The recorded reason names the SETTINGS to change rather than a private method the
      # operator cannot see (#492 step 4b, the same fix `Outbound#sweep_block` got in #491).
      # It no longer GUESSES which cause applies: the Tunnel stamps what it observed on this
      # connection (`H2Offer`), so the sentence is the true one and only the branches that
      # write to gori.log point at it. See `H2Offer` for what went stale under the old
      # "it cannot name which, so it points at the log" reasoning.
      if Codec::Http1.h2_preface?(req)
        record_error(req, @scheme, @fixed_host || req.host? || "", @fixed_port, created_at,
          "rejected h2/gRPC client preface on the HTTP/1.1 path: #{@h2_offer.refusal_reason}")
        return false
      end

      # A client-supplied absolute-form target with a bad/oversized port makes URI.parse
      # raise; keep the malformed attempt visible in History instead of letting it unwind
      # to run's blanket rescue (which would silently drop the flow and kill the connection).
      begin
        host, port, scheme, forward_head = resolve_forward(req)
      rescue ex : URI::Error | OverflowError
        record_error(req, @scheme, req.host? || "", 0, created_at, "malformed absolute-form target: #{ex.message}")
        write_gateway_error
        return false
      end

      # A RESERVED host (http://gori.proxy/) — the mitm.it-style entry point for a client
      # that already has gori configured as its proxy. Answered here or refused here, never
      # forwarded.
      return false if handle_reserved_host(req, scheme, host, port, created_at)

      # A browser pointed STRAIGHT at the listener gets the self-serve welcome +
      # CA-download page instead of the 502 self-loop refusal below — for a plain GET/HEAD,
      # while the setting is on. Both request forms qualify: origin-form is the no-proxy
      # device that typed the IP, absolute-form is the one that configured the proxy FIRST
      # and then typed it (#280) — that request is aimed at us, not at an origin, so there
      # is nothing to loop. Non-GET/HEAD still falls through to the refusal below.
      # Not recorded as a flow — it's a local UI hit, not proxied traffic.
      if (sa = @self_addr) && (tls = @tls) && tls.serve_landing? &&
         get_or_head?(req) && Upstream.addresses_self?(host, port, sa, @local_host)
        serve_self_page(req, tls, sa)
        return false
      end

      # Refuse to forward a request whose (override-resolved) target is gori's own
      # listener — otherwise gori dials itself, accepts that as a new client, and
      # loops forever. Record it as a visible error instead.
      if (sa = @self_addr) && Upstream.loops_to_self?(host, port, @host_overrides, sa, @local_host)
        record_error(req, scheme, host, port, created_at, "refusing to proxy to self (loop): #{host}:#{port}")
        write_gateway_error
        return false
      end

      # WebSocket: remove the client's `Sec-WebSocket-Extensions` offer before the
      # handshake leaves for the origin (#518). `client_head` is the client's own bytes
      # with the same removal applied, for the History record. See the helper.
      client_head, forward_head, record_req = strip_ws_extension_offer(req, forward_head)

      # Match&Replace (request head): rewrite the bytes sent upstream. Only when
      # a rule actually changes something do we capture the modified bytes (the
      # user's chosen semantics); otherwise the original client bytes are kept
      # byte-exact (P7). Body framing always uses the original request.
      #
      # `sent_head`/`sent_req` is the ORIGIN-FORM head/projection put on the wire —
      # resolve_forward already normalized an absolute-form forward-proxy target
      # (`GET http://h/p`) to origin-form (`GET /p`). What we RECORD must instead
      # preserve the CLIENT's original request-line form, so `record_req` re-applies
      # the same rewrite on top of `req.raw_head` (the client's original bytes): an
      # unrelated rule (e.g. add_header) then leaves the original absolute-form request
      # line byte-intact in History, while a rule that DOES target the request line still
      # shows its intended change. The wire request stays origin-form (unchanged).
      sent_req = req
      sent_head = forward_head
      if rw = @rewriter
        rewritten = rw.rewrite_request(forward_head, host)
        if rewritten != forward_head
          # A head rule that changed Content-Length/Transfer-Encoding must not desync the
          # streamed body from the head we send (#403): the body streams UNTOUCHED (P6), so
          # its framing is `forward_head`'s — restore that onto the rewritten head. No-op
          # (byte-exact) when the rule left framing alone. `record_head` mirrors it so History
          # shows exactly what went on the wire.
          sent_head = restore_framing_headers(rewritten, forward_head)
          sent_req = Codec::Http1.parse_request_head(sent_head)
          record_head = restore_framing_headers(rw.rewrite_request(client_head, host), client_head)
          record_req = Codec::Http1.parse_request_head(record_head) unless record_head == client_head
        end
      end

      # The target every SCOPE/INTERCEPT gate below reads, from the ACTUALLY-SENT head (post
      # Match&Replace). `Codec::Http1.gate_target` is `sent_req.target` on the common path and
      # only recovers when the strict `split(' ')` could not frame the request line — a doubled
      # space, a tab, or a leading blank line otherwise hands the gate `""` (or `"HTTP/1.1"`)
      # while an origin that collapses whitespace still reads the real path, which is a Sandbox
      # bypass. Read that method's comment; the wire bytes are untouched (P7).
      #
      # The RECORDED projection (`sent_req.target`, below) deliberately stays on the strict
      # parse — `request_head` is byte-exact and `target` is a derived column — so for a
      # malformed request line the History row's `target` does NOT reproduce this gate's input.
      # That is the one case where the live gate and the Scope SQL filter over History disagree.
      gate_target = Codec::Http1.gate_target(sent_req)

      # Sandbox: the hard scope gate. When enabled, ONLY requests the scope ALLOWS reach
      # upstream — everything else, including ALL traffic when no include rule is set, is
      # blocked HERE, before we touch (or even dial) the origin. Keyed on the ACTUALLY-SENT
      # target (post Match&Replace), matching the intercept gate + the captured History row.
      # We record the attempt as an aborted flow (visible in History) and answer the client
      # a distinct 403 so a sandbox block never reads like an upstream failure. The scope
      # URL is built lazily inside the interceptor, only while the sandbox is on.
      if (ic = @interceptor) && ic.sandbox_blocks?(scheme, host, gate_target, port)
        record_blocked_request(sent_req, scheme, host, port, created_at)
        write_sandbox_block
        return false
      end

      # Ambiguous/illegal request framing (CL+TE, non-final chunked, bad
      # Content-Length) means we can't determine the body boundary to forward it
      # faithfully — the codec raises to force a close. But the attempt must stay
      # VISIBLE in History (this smuggling-shape traffic is exactly what a pentester
      # wants to see); previously the raise unwound to `run`'s blanket rescue and no
      # flow was recorded at all. Record an error flow, answer 400, then close.
      #
      # The 400 matters as much as the History row: closing with ZERO bytes is
      # indistinguishable from the ORIGIN hanging up, so an operator probing a
      # smuggling shape through gori cannot tell whose refusal they just measured —
      # and would score gori's own defense as a target finding. RFC 9112 §6.3 has a
      # proxy respond 400 here. Mirrors `write_sandbox_block`'s distinct-answer
      # rationale one gate above; `X-Gori-Error` is the machine-readable half.
      begin
        req_framing, req_len = Codec::Body.request_framing(req)
      rescue ex : Gori::Error
        reason = ex.message || "ambiguous request framing"
        record_error(sent_req, scheme, host, port, created_at, "request framing rejected: #{reason}")
        write_framing_reject(reason)
        return false
      end

      # Short circuit (#511): a Match&Replace rule may ANSWER this request rather than
      # rewrite it, in which case nothing is dialed. Placement is load-bearing on both sides:
      #   - AFTER the sandbox gate, so a rule can never act on a host the operator's sandbox
      #     excludes. A stub sends nothing outward, but the sandbox is the operator's outer
      #     boundary and no rule may widen where gori participates at all.
      #   - BEFORE the intercept hold, matching where the head rewrite already runs. Holding
      #     a short-circuited request would offer a "forward" that cannot happen — the
      #     request is never going anywhere — so the hold is skipped, not lied to.
      # It also has to come after `request_framing`, because answering means draining the
      # body first (see serve_short_circuit).
      if (rw = @rewriter) && (stub = rw.short_circuit(sent_head, host))
        return serve_short_circuit(stub, req, sent_req, record_req, host, port, scheme,
          created_at, req_framing, req_len)
      end

      # Intercept (request): hold only when enabled AND in scope. Holding buffers
      # the full body (vs streaming) so the human can see/edit it; the non-hold
      # path keeps zero-buffer streaming (P6). The gate builds the scope URL lazily
      # (scheme || '://' || host || <gate target>, which for a well-formed request line IS
      # the captured target the Scope SQL filter sees — see `gate_target` above for the one
      # case they part company) only when intercept + Scope are both on, so the common
      # capture-only path spends nothing here.
      # A body whose DECLARED length is over the hold ceiling fails open (see the predicate) and
      # falls through to the streaming path below, byte-exact.
      if (ic = @interceptor) && ic.intercepts_request?(
           method: sent_req.method, host: host, target: gate_target, scheme: scheme,
           port: port, head: sent_head) && holdable_body_size?(req_framing, req_len, "request")
        return handle_held_request(ic, req, sent_req, sent_head, host, port, scheme,
          created_at, started, req_framing, req_len)
      end

      # Match&Replace (request body): a body rule can't stream — it must buffer the
      # whole body to rewrite it and re-frame the head (Content-Length). Only pay this
      # when a request-body rule is live AND there's a body to rewrite; the common path
      # (no body rule) falls straight through to zero-buffer streaming below (P6). A body
      # whose declared length exceeds MAX_REWRITE_BODY is left byte-exact (see the constant)
      # so a huge upload can't grow the proxy heap while a rule is on.
      if (rw = @rewriter) && rewrite_request_body?(rw, req_framing, req_len)
        return forward_request_rewriting_body(rw, req, sent_req, sent_head, host, port,
          scheme, created_at, started, req_framing, req_len)
      end

      # Non-hold path: stream the request body byte-for-byte (P6), unchanged.
      # Repeater-safety keys on the ACTUALLY-SENT method (sent_req): an M&R rule that rewrites
      # the request line GET→POST must not leave a non-idempotent request marked retryable.
      retryable = retryable_request?(sent_req, req_framing.none?)
      req_capture = Codec::CaptureBuffer.new(Settings.capture_max, capture_hint(req_framing, req_len))
      req_complete = true
      # `Expect: 100-continue` (#728). A client that sends it is WITHHOLDING its body until it
      # is answered, so writing the head and then blocking on `Codec::Body.stream` — which is
      # what this path used to do — parked the client, gori and the origin on each other until
      # a timeout broke the tie. Settle the expectation between the head and the body instead:
      # see `settle_expectation` for the outcomes.
      #
      # Keyed on the CLIENT's `req`, not on `sent_head`: the deadlock is the client holding its
      # body back, and only the client's own head says whether it is doing that. (A Match&Replace
      # rule that ADDS `Expect` to the wire head cannot deadlock — the client is not waiting — and
      # a rule that REMOVES it still leaves the client waiting, which the self-issued 100 covers.)
      # Also gated on a body actually being declared: an `Expect` on a bodyless request has
      # nothing to withhold, and — load-bearing for retry safety — `retryable_request?` returns
      # false for every body-declaring request, so `acquire_and_send` can NOT re-run this block.
      # That is what guarantees the origin's interim is relayed to the client at most once and no
      # body is sent twice on a stale-reuse redial.
      expects_continue = expect_continue?(req) && !req_framing.none?
      early_head = nil.as(Bytes?)
      send_body = true
      client_gone = false
      upstream, reused, sent = acquire_and_send(host, port, retryable) do |up|
        up.write(sent_head)
        if expects_continue
          up.flush # the head must be ON THE WIRE before there is anything to wait for
          early_head, send_body, client_gone = settle_expectation(up)
        end
        if send_body
          req_complete = Codec::Body.stream(@io, up, req_framing, req_len, req_capture, copy_buf)
          up.flush
        end
        true
      end
      unless upstream && sent
        release_upstream
        record_error(req, scheme, host, port, created_at, upstream_error_message(host, port, upstream))
        write_gateway_error
        return false
      end
      if client_gone
        # The client vanished while gori was answering its expectation. Nothing was forwarded
        # and nothing will be; record it rather than leave the flow Pending (mirrors the same
        # guard inside `skip_interim_responses`).
        release_upstream
        record_error(record_req, scheme, host, port, created_at,
          "connection closed while answering Expect: 100-continue")
        return false
      end
      req_body = req_framing.none? ? nil : req_capture.to_slice
      flow_id = @sink.on_request(FlowMapper.request(record_req,
        scheme: scheme, host: host, port: port, created_at: created_at, body: req_body,
        body_truncated: req_capture.truncated?, body_size: req_capture.total, source: FlowSource::Kind::Proxy))
      unless req_complete # client cut the request body short — don't reuse the connection
        release_upstream
        @sink.on_response(FlowMapper.error_response(flow_id, "client truncated request body"))
        return false
      end
      keep = handle_response(upstream, req, flow_id, started, host, port, scheme,
        reused: reused, sent_head: sent_head, can_retry: retryable, sent_req: sent_req,
        pre_read_head: early_head)
      # The expectation was settled without the body being pumped, so neither leg is reusable:
      # the client still owes those bytes, and gori sent the origin a head declaring a body it
      # never got — either socket's next bytes are ambiguous, which is where a desync starts.
      # `release_upstream` runs AFTER `handle_response` (which still had to read the response
      # body off that socket) and is idempotent, so the 101 branch having already detached the
      # slot is fine.
      unless send_body
        release_upstream
        return false
      end
      keep
    end

    # Removes the client's `Sec-WebSocket-Extensions` offer from the handshake gori is
    # about to relay (#518), returning {client-form head, wire head, recorded request}.
    # A no-op returning the inputs untouched (P7) for everything that is not a WebSocket
    # upgrade carrying an offer, which is every other request on this path.
    #
    # gori's FIRST hop-by-hop removal, and it is deliberate — see `WS::Handshake` for why
    # the client's offer (rather than the origin's acceptance) is the side that gets cut,
    # and for the cost of cutting it at all. Unconditional by necessity: extension
    # negotiation happens once, in the 101 handshake, with no renegotiation, so it cannot
    # be deferred to the moment a capture consumer turns up the way #512's h2 re-encode was.
    #
    # The recorded request mirrors the strip so History shows the handshake gori actually
    # sent. An un-stripped offer captured beside a 101 that carries no acceptance would
    # read as "the origin declined compression", which is a lie about the origin that no
    # doc line can undo.
    #
    # Runs BEFORE the Match&Replace pass on purpose: a rule (or an intercept edit) that
    # puts the header back is the operator saying so explicitly, and operator bytes win
    # here as they do everywhere else on this path. Running early costs nothing either —
    # an offer hidden from this scan by an obs-fold or `name<SP>:` is never forwarded at
    # all, because `Codec::Body.request_framing` rejects the whole request just below.
    private def strip_ws_extension_offer(req : Codec::RawRequest,
                                         forward_head : Bytes) : {Bytes, Bytes, Codec::RawRequest}
      # Reset per request: this connection is keep-alive, and the answer belongs to the
      # handshake in hand, not to the one before it.
      @ws_offer_stripped = WS::Handshake.offers_extensions?(req.headers)
      return {req.raw_head, forward_head, req} unless @ws_offer_stripped
      client_head = WS::Handshake.strip_extensions(req.raw_head)
      {client_head, WS::Handshake.strip_extensions(forward_head), Codec::Http1.parse_request_head(client_head)}
    end

    # The intercept-hold request path: buffer the body, let the human edit/drop
    # it, then forward via the reused upstream (with the same stale-reuse retry).
    private def handle_held_request(ic : Gori::Interceptor, req : Codec::RawRequest,
                                    sent_req : Codec::RawRequest, sent_head : Bytes,
                                    host : String, port : Int32, scheme : String,
                                    created_at : Int64, started : Time::Instant,
                                    req_framing : Codec::BodyFraming, req_len : Int64) : Bool
      # #728: a held request must be COMPLETE before the human can see it, so gori answers the
      # client's `Expect: 100-continue` itself rather than blocking on a body being withheld.
      # See `elicit_request_body` for why this path cannot ask the origin instead.
      unless elicit_request_body(req, req_framing)
        record_error(sent_req, scheme, host, port, created_at,
          "connection closed while answering Expect: 100-continue")
        return false
      end
      buffered, body_complete = Codec::Body.read_complete(@io, req_framing, req_len)
      unless body_complete
        # The client cut its request body short — there's nothing whole to hold/forward, and
        # forwarding a short body under the original Content-Length would desync the upstream
        # (mirrors the non-hold path's req_complete guard). Record + close instead of holding.
        record_error(sent_req, scheme, host, port, created_at, "client truncated request body")
        return false
      end
      # Match&Replace (request body) BEFORE the human sees it — mirroring the head, which is
      # already M&R'd into `sent_head`. A body rule re-frames to Content-Length, so re-parse
      # the (possibly rewritten) head for the hold metadata + capture.
      advisory = nil.as(String?)
      if (rw = @rewriter) && rw.rewrites_request_body?
        sent_head, buffered, advisory = apply_body_rewrite(sent_head, buffered, req_framing,
          host: host, response: false, live: true) { |e| rw.rewrite_request_body(e, host) }
        sent_req = Codec::Http1.parse_request_head(sent_head)
      end
      decision = ic.hold_request(build_message(sent_head, buffered),
        method: sent_req.method, target: sent_req.target,
        host: host, port: port, scheme: scheme)
      if decision.action.drop?
        record_dropped_request(sent_req, scheme, host, port, created_at, buffered)
        write_intercept_drop
        return false
      end
      # forward the decision bytes BYTE-EXACT (P7): re-parse the sent head for capture.
      # The intercept editor owns the "update Content-Length" decision (it knows what
      # was edited) — see InterceptView#forward_bytes; the proxy must not rewrite bytes
      # the human chose to send (e.g. a deliberately CL-mismatched smuggling probe).
      sent_head, edited_body = split_message(decision.bytes)
      sent_req = Codec::Http1.parse_request_head(sent_head)
      # Key repeater-safety on the EDITED request: if the human changed the method (e.g.
      # GET→POST), retryability must follow the method actually being sent, not the
      # original — else a now-non-idempotent request could be replayed on a stale-conn retry.
      retryable = retryable_request?(sent_req, edited_body.nil? || edited_body.empty?)
      upstream, reused, sent = acquire_and_send(host, port, retryable) { |up| write_request(up, sent_head, edited_body) }
      unless upstream && sent
        release_upstream
        record_error(sent_req, scheme, host, port, created_at, upstream_error_message(host, port, upstream))
        write_gateway_error
        return false
      end
      stored, trunc, size = capped(edited_body)
      flow_id = @sink.on_request(FlowMapper.request(sent_req,
        scheme: scheme, host: host, port: port, created_at: created_at,
        body: stored, body_truncated: trunc, body_size: size, advisory: advisory, source: FlowSource::Kind::Proxy))
      handle_response(upstream, req, flow_id, started, host, port, scheme,
        reused: reused, sent_head: sent_head, can_retry: retryable, sent_req: sent_req)
    end

    # Answer a request from a short-circuit rule and record the flow. No upstream is acquired
    # and `Upstream.dial` is never reached — that is the whole feature (#511).
    #
    # The connection survives: unlike every other canned answer here (sandbox block, intercept
    # drop, gateway error) a stub is a NORMAL response as far as the client is concerned, and
    # closing after each one would make a stubbed endpoint behave nothing like the origin it
    # stands in for. Paying for that means draining the request body first — it is still on
    # the socket, and an undrained body is read as the next request line.
    private def serve_short_circuit(stub : HeadRewriter::Stub, req : Codec::RawRequest,
                                    sent_req : Codec::RawRequest, record_req : Codec::RawRequest,
                                    host : String, port : Int32, scheme : String,
                                    created_at : Int64,
                                    req_framing : Codec::BodyFraming, req_len : Int64) : Bool
      # #728: draining the body is what lets a stubbed connection survive, and a client holding
      # its body back for a `100 Continue` never drains. Answer it here too — the stub's own
      # status still follows, and a 1xx before it is exactly what the client is waiting for.
      unless elicit_request_body(req, req_framing)
        record_error(sent_req, scheme, host, port, created_at,
          "connection closed while answering Expect: 100-continue")
        return false
      end
      buffered, body_complete = Codec::Body.read_complete(@io, req_framing, req_len)
      unless body_complete
        # Nothing was answered, so this is not a short-circuited flow — record it as the
        # truncation it is (mirrors the hold / body-rewrite paths).
        record_error(sent_req, scheme, host, port, created_at, "client truncated request body")
        return false
      end

      omit_length, send_body = stub_framing(stub, req.method)
      resp_head = build_stub_head(stub, omit_length)

      written = begin
        @io.write(resp_head)
        @io.write(stub.body) if send_body && !stub.body.empty?
        @io.flush
        true
      rescue
        false
      end

      stored, trunc, size = capped(buffered)
      flow_id = @sink.on_request(FlowMapper.request(record_req,
        scheme: scheme, host: host, port: port, created_at: created_at,
        body: stored, body_truncated: trunc, body_size: size, short_circuited: true, source: FlowSource::Kind::Proxy))
      resp = Codec::Http1.parse_response_head(resp_head)
      # ttfb/duration stay nil on purpose. There was no round trip to measure, and a `0`
      # would render in History as an impossibly fast origin — the exact misreading the
      # short-circuit marker exists to prevent. `—` is the truth.
      # Capped like every other capture path (`capped` eight lines above for the request,
      # `CaptureBuffer` on the streaming path, the h2 assembler). The stub's body is bounded
      # only by `RuleStub::MAX_BODY_FILE_BYTES` = 8 MiB, four times the default
      # `Settings.capture_max`, and it is written PER REQUEST — so a `body_file` stub on an
      # endpoint a page hits repeatedly grew `flows.response_body` by the whole file each
      # time, which the retention cap (counted in rows) cannot reclaim and lowering
      # `capture_max` did not shrink.
      resp_stored, resp_trunc, resp_size = capped(send_body ? stub.body : nil)
      # A 1xx stub answers nothing: 100/102/103 promise a final status that never follows, and
      # a 101 hands the connection to a protocol a stub has no relay for. Either way the client
      # sends no next request, so keeping the connection would only stall both sides until
      # CLIENT_IO_TIMEOUT. Deliberately the WHOLE 1xx range, unlike `interim_response?` — that
      # predicate excludes 101 because an ORIGIN's 101 is forwarded as an upgrade, and here
      # there is no upgrade to forward.
      non_final = resp.status < 200
      @sink.on_response(FlowMapper.response(resp,
        flow_id: flow_id, body: resp_stored,
        body_truncated: resp_trunc, body_size: resp_size,
        state: written && !non_final ? Store::FlowState::Complete : Store::FlowState::Aborted,
        error: if !written
          "client closed before the short-circuit response was written"
        elsif non_final
          "short-circuit stub answered with a non-final #{resp.status}; no final response follows"
        else
          stub.error
        end))
      return false unless written
      return false if non_final
      keep_alive?(req, resp, omit_length ? Codec::BodyFraming::None : Codec::BodyFraming::Length)
    end

    # {omit_length, send_body} for a stub answering `method`. Content-Length is prohibited on
    # a 1xx/204, so it is left off entirely there; a 304 and a HEAD response keep it — it
    # describes the entity that WOULD be sent — but carry no body of their own.
    private def stub_framing(stub : HeadRewriter::Stub, method : String) : {Bool, Bool}
      head_only = method.compare("HEAD", case_insensitive: true) == 0
      omit_length = stub.status == 204 || (100..199).includes?(stub.status)
      {omit_length, !head_only && !omit_length && stub.status != 304}
    end

    # The stub's head plus the terminating blank line, with Content-Length taken from the body
    # gori is about to write and NEVER from the rule (the rule's copy was dropped at parse
    # time). A stub whose declared length disagreed with its body would leave the client
    # mid-way through what it reads as the next response.
    private def build_stub_head(stub : HeadRewriter::Stub, omit_length : Bool) : Bytes
      io = IO::Memory.new(stub.head.size + 32)
      io.write(stub.head)
      io << "Content-Length: " << stub.body.size << "\r\n" unless omit_length
      io << "\r\n"
      io.to_slice
    end

    # The Match&Replace request-body path (no intercept): buffer the whole body,
    # rewrite the entity, re-frame the head (Content-Length), and forward. A body was
    # sent, so the request is never auto-retryable. Structurally this is the hold path
    # minus the human — same buffer + capped-capture + reused-upstream forwarding.
    private def forward_request_rewriting_body(rw : HeadRewriter, req : Codec::RawRequest,
                                               sent_req : Codec::RawRequest, sent_head : Bytes,
                                               host : String, port : Int32, scheme : String,
                                               created_at : Int64, started : Time::Instant,
                                               req_framing : Codec::BodyFraming, req_len : Int64) : Bool
      # #728: a body rule needs the whole entity before the head can be re-framed and sent, so
      # (as on the hold path) gori answers the client's `Expect: 100-continue` itself.
      unless elicit_request_body(req, req_framing)
        record_error(sent_req, scheme, host, port, created_at,
          "connection closed while answering Expect: 100-continue")
        return false
      end
      buffered, body_complete = Codec::Body.read_complete(@io, req_framing, req_len)
      unless body_complete
        # Client cut the body short — forwarding it under the original length would desync
        # the upstream (mirrors the streaming path's req_complete guard). Record + close.
        record_error(sent_req, scheme, host, port, created_at, "client truncated request body")
        return false
      end
      sent_head, fwd_body, advisory = apply_body_rewrite(sent_head, buffered, req_framing,
        host: host, response: false, live: true) { |e| rw.rewrite_request_body(e, host) }
      sent_req = Codec::Http1.parse_request_head(sent_head) # head may have been re-framed
      upstream, reused, sent = acquire_and_send(host, port, false) { |up| write_request(up, sent_head, fwd_body) }
      unless upstream && sent
        release_upstream
        record_error(sent_req, scheme, host, port, created_at, upstream_error_message(host, port, upstream))
        write_gateway_error
        return false
      end
      stored, trunc, size = capped(fwd_body)
      flow_id = @sink.on_request(FlowMapper.request(sent_req,
        scheme: scheme, host: host, port: port, created_at: created_at,
        body: stored, body_truncated: trunc, body_size: size, advisory: advisory, source: FlowSource::Kind::Proxy))
      handle_response(upstream, req, flow_id, started, host, port, scheme,
        reused: reused, sent_head: sent_head, can_retry: false, sent_req: sent_req)
    end

    # Acquires the (reused-or-fresh) upstream and runs `send` on it. If a REUSED
    # connection's send fails and the request is REPLAYABLE (a safe, body-less
    # method — nothing consumed from the client, harmless to resend), redials a
    # fresh origin and retries once — this is what makes per-connection keep-alive
    # reuse safe against a server that closed an idle connection. A non-replayable
    # request (any body, or a mutating method) is never auto-resent — the caller
    # fails it so the client decides. Returns {upstream, reused?, ok}.
    private def acquire_and_send(host : String, port : Int32, retryable : Bool, & : IO -> Bool) : {IO?, Bool, Bool}
      upstream, reused = acquire_upstream(host, port)
      return {nil, false, false} unless upstream
      # Re-arm the per-request upstream timeout: a REUSED socket may carry a relaxed (untimed)
      # state from a prior streamed (SSE/chunked) response. A freshly dialed one already has it
      # (direct_dial), so this is an idempotent set there.
      SocketTuning.arm(upstream, Settings.io_timeout)
      ok = send_guard { yield upstream }
      if !ok && reused && retryable
        release_upstream
        upstream, reused = acquire_upstream(host, port)
        SocketTuning.arm(upstream, Settings.io_timeout) if upstream
        ok = upstream ? send_guard { yield upstream } : false
      end
      {upstream, reused, ok}
    end

    private def send_guard(& : -> Bool) : Bool
      yield
    rescue
      false # write to a dead/half-closed reused socket, or client read error mid-body
    end

    # Writes a request head (+ optional body) to the upstream and flushes.
    # Returns false on any IO error (a dead/half-closed reused connection), so
    # the caller can decide whether a stale reuse is worth a redial+resend.
    private def write_request(upstream : IO, head : Bytes, body : Bytes?) : Bool
      upstream.write(head)
      upstream.write(body) if body && !body.empty?
      upstream.flush
      true
    rescue
      false
    end

    # Reads, (optionally holds), forwards, and captures the response. `req` is the
    # ORIGINAL request (framing/keep-alive/method come from it). Returns true to
    # keep the connection alive.
    #
    # `pre_read_head` is a response head the caller has ALREADY taken off the upstream socket
    # and must not be read again — the `Expect: 100-continue` settlement (#728), which has to
    # look at the origin's answer before it can decide whether to pump the client's body. It is
    # deliberately handed back UNPARSED so every gate below (interim handling, framing, M&R,
    # intercept) runs on it exactly as if `read_response_head` had produced it; the one thing it
    # skips is the stale-reuse redial, which cannot apply once a head has been read.
    private def handle_response(upstream : IO, req : Codec::RawRequest, flow_id : Int64,
                                started : Time::Instant, host : String, port : Int32, scheme : String,
                                *, reused : Bool, sent_head : Bytes, can_retry : Bool,
                                sent_req : Codec::RawRequest, pre_read_head : Bytes? = nil) : Bool
      if pre_read_head
        resp_head = pre_read_head
      else
        resp_head, upstream = read_response_head(upstream, host, port, reused, sent_head, can_retry)
      end
      if resp_head.nil?
        @sink.on_response(FlowMapper.error_response(flow_id, "no response from upstream"))
        release_upstream
        return false
      end
      resp = Codec::Http1.parse_response_head(resp_head)

      final = skip_interim_responses(upstream, req, flow_id, resp_head, resp)
      return false unless final
      resp_head, resp = final
      # Judged HERE — on the peer's final head, before Match&Replace or the Alt-Svc seam get
      # to it — because it is a fact about what the ORIGIN sent, not about what a rule made.
      @status_line_note = status_line_note(resp)
      ttfb = (Time.instant - started).total_microseconds.to_i64

      # The h3 `Alt-Svc` strip (settings `network.strip_alt_svc`), before the rules so a rule
      # can put the header back — see `settle_alt_svc`. A no-op returning the same slices when
      # the switch is off, which is the default.
      resp_head, resp, @alt_svc_note = settle_alt_svc(resp_head, resp, host)

      # Match&Replace (response head). Framing/keep-alive/upgrade stay on the
      # ORIGINAL response so the upstream body is read correctly.
      sent_resp_head, sent_resp = apply_response_rewrite(resp_head, resp, host)
      # A response head rule that changed Content-Length/Transfer-Encoding must not desync the
      # body streamed to the client from the head sent (#403): the body streams UNTOUCHED, framed
      # by the ORIGINAL response — restore that framing onto the rewritten head (byte-exact no-op
      # when the rule left CL/TE alone) and re-parse so capture/streaming agree with the wire.
      if sent_resp_head != resp_head
        resynced = restore_framing_headers(sent_resp_head, resp_head)
        unless resynced == sent_resp_head
          sent_resp_head = resynced
          sent_resp = Codec::Http1.parse_response_head(sent_resp_head)
        end
      end
      # The OFF half of the h3 `Alt-Svc` seam (#835), and the reason it sits HERE rather than
      # beside the strip: the sentence is about what the CLIENT is being invited onto, so it has
      # to be asked of the head the rules have finished with. An operator's response rule removing
      # `Alt-Svc` for one host is the documented per-host alternative to the global switch, and
      # warning "a client acting on it leaves the proxy" for a header that rule already took off
      # the wire is a false alarm on the one host they had handled.
      @alt_svc_note = note_alt_svc_kept(sent_resp_head, sent_resp, host) unless Settings.strip_alt_svc?
      # The `Sec-WebSocket-Extensions` half of a 101 (#518): removed when it answers an offer
      # gori itself removed, kept when it answers one the origin really received. Either way
      # the operator gets told, on the flow and not only in gori.log. Runs on the head that
      # goes to the CLIENT; framing below still keys off the original response.
      ws_notice = nil.as(String?)
      if websocket_upgrade?(resp)
        sent_resp_head, sent_resp, ws_notice =
          settle_ws_extensions(sent_resp_head, sent_resp, sent_req, sent_head, host)
      end
      # Body framing must reflect the method the ORIGIN actually received (HEAD/CONNECT
      # are bodyless per RFC 7230 §3.3.3). A Match&Replace / intercept edit can rewrite
      # the request-line method, so key off sent_req, not the client's original req.
      framing = response_framing_or_close(resp, sent_req.method, flow_id)
      return false unless framing
      resp_framing, resp_len = framing

      # Intercept (response): hold only in-scope, non-streaming responses. SSE /
      # close-delimited / WebSocket bodies would buffer forever, so they bypass.
      # The gate rebuilds the SAME precise scope URL the request hold uses (lazily, only
      # when intercept + Scope are on), so a string/regex-excluded flow whose request wasn't
      # held doesn't get its response held. The response gate also honours the catch direction
      # + can test `status:`. Match the CONDITION against `sent_req` (the rewritten/edited
      # request that was captured + scope-gated), not the original `req`, so a `method:`/`path:`
      # rule that holds the request also holds its response when M&R changed the request line.
      # A body whose DECLARED length is over the hold ceiling fails open the same way the
      # request hold does (see `holdable_body_size?`) and streams below, byte-exact.
      if (ic = @interceptor) && ic.intercepts_response?(
           method: sent_req.method, host: host, target: Codec::Http1.gate_target(sent_req),
           scheme: scheme, port: port, status: resp.status, head: sent_resp_head) &&
         !resp_framing.close_delimited? && !sse?(resp) && resp.status != 101 &&
         holdable_body_size?(resp_framing, resp_len, "response")
        return handle_held_response(ic, upstream, req, sent_req, flow_id, host, port, scheme,
          resp, sent_resp_head, resp_framing, resp_len, ttfb, started)
      end

      # What an extract rule's condition needs to know about this exchange (#501 slice 2), or
      # nil when no extract rule is live — one lock-free atomic read on the common path.
      extract_ref = extract_ref_for(sent_req, host, scheme, sent_resp.status, flow_id)

      # Buffer the response body when a Match&Replace body rule OR a body-scoped extract rule
      # needs the whole entity: a bounded (Length/chunked), non-streaming response. SSE /
      # close-delimited / 101-upgrade bodies would buffer forever, so they fall through to
      # streaming — the body rule no-ops on them (matching the intercept-hold exclusions above)
      # and a body-scoped extract rule records that it had no body to read. A body whose
      # declared length exceeds MAX_REWRITE_BODY is likewise left byte-exact (see the constant)
      # so one huge download can't grow the proxy heap while a rule is on.
      if buffer_response_body?(resp, resp_framing, resp_len)
        return forward_response_rewriting_body(upstream, req, sent_req, flow_id, host, port,
          scheme, resp, sent_resp_head, resp_framing, resp_len, ttfb, started, extract_ref)
      end

      relaxed = relax_for_streaming_response(resp, resp_framing, upstream)

      # Non-hold path: stream the response body byte-for-byte (P6) and record the
      # flow. `completed` is true only when the whole body was delivered cleanly; a
      # client abort or upstream truncation is recorded Aborted (see the helper).
      # `relaxed` streams also run a concurrent client-abort watcher (see the helper).
      resp_capture = Codec::CaptureBuffer.new(Settings.capture_max, capture_hint(resp_framing, resp_len))
      completed = stream_nonhold_response(upstream, sent_resp, sent_resp_head,
        resp_framing, resp_len, resp_capture, flow_id, ttfb, started, relaxed: relaxed,
        extract_ref: extract_ref)

      if completed && resp.status == 101
        # A 101 Switching Protocols turns the connection into a bidirectional tunnel of the
        # upgraded protocol — it is NOT more HTTP. Ownership of the upstream transfers to the
        # relay/tunnel (which cross-closes on teardown); detach it from the reuse slot so
        # `run`'s ensure won't also touch it. A WebSocket upgrade gets the frame-aware relay
        # (captures messages, P6/P7); any OTHER upgrade (h2c, or a proprietary protocol) gets
        # a blind byte tunnel. Either way we must NOT fall through to keep-alive/reuse:
        # parsing the post-upgrade bytes as the next HTTP response (upstream) or request
        # (client) would desync both directions and corrupt the tunnel.
        @upstream = nil
        @up_host = nil
        @up_port = 0
        # Entering a long-lived bidirectional tunnel: relax both legs' timeouts so an idle
        # WebSocket/tunnel isn't reaped by a wall-clock cutoff (the 30 s upstream io_timeout would
        # otherwise tear a quiet tunnel down). Keepalive (both legs) reaps a truly dead peer.
        SocketTuning.relax(@io)
        SocketTuning.relax(upstream)
        if websocket_upgrade?(resp)
          # `@rewriter` carries Match & Replace (#500 step 1) and `@interceptor` the message
          # hold (step 2) into the tunnel; `ctx` is the 101 handshake's identity, which both
          # scope on — a WebSocket message has no authority, scheme or path of its own. The
          # relay asks each lens ONCE, here, whether it can reach this host; a socket that
          # answers "no" to both keeps the byte-exact pump (P6/P7).
          # `target` here is what `Interceptor#intercepts_ws?` scopes every message on, so it
          # takes the same gate-side recovery as the two HTTP gates (see `gate_target`) —
          # otherwise a handshake with a malformed request line hands the WS message gate an
          # empty path and every frame on that socket escapes a path-scoped rule.
          ws_ctx = WS::Context.new(host: host, port: port, scheme: scheme,
            method: sent_req.method, target: Codec::Http1.gate_target(sent_req))
          # frames until close
          WS::Relay.run(@io, upstream, flow_id, @sink, @rewriter, ws_ctx, @interceptor, notice: ws_notice)
        else
          # A 101 that is NOT a WebSocket — kubectl exec/attach/port-forward speaks
          # `Upgrade: SPDY/3.1` and the Docker Engine API `Upgrade: tcp` — is relayed
          # byte-exact and deliberately NOT decoded (see `Pump`). That decision used to be
          # invisible: the WebSocket branch above carries `notice:` and this one said nothing
          # anywhere, so a `101 / complete / empty transcript` flow could not be told from one
          # gori simply failed to capture (#736). Recorded AFTER the tunnel returns, because
          # `blind_tunnel` only comes back when both directions are closed and the byte counts
          # are what make this a report rather than a guess. Exactly one per connection —
          # this branch `return false`s immediately below, so there is nothing to rate-limit.
          moved = Pump.blind_tunnel(@io, upstream) # non-WS upgrade: raw pipe until close
          record_opaque_upgrade(flow_id, resp, req, host, sent_req.target, moved)
        end
        return false
      end

      # A truncated/aborted body was forwarded short; close so the client sees
      # end-of-response instead of waiting for the missing bytes while we read its
      # next keep-alive request.
      unless completed
        release_upstream
        return false
      end
      # A relaxed (close-delimited/SSE) stream ran a concurrent client-abort watcher that
      # may still be parked on @io.read (see stream_response_body). Do NOT keep this client
      # connection alive: closing it (return false) is what lets `run`'s ensure unblock and
      # end that watcher, and it keeps a lingering @io read from colliding with a next reused
      # request. Close-delimited already never keep-alives; forcing the same for chunked/Length
      # SSE is the safe price of watching them (closing after a complete response is always
      # valid), and the upstream isn't parked for reuse since this connection is ending.
      if relaxed
        release_upstream
        return false
      end
      # Reuse this upstream for the next request iff the ORIGIN keeps its side
      # open; the return value is the CLIENT keep-alive decision (separate sides).
      # The origin side keys on sent_req (what it received); the client side on req.
      update_upstream_reuse(origin_keep_alive?(sent_req, resp, resp_framing))
      keep_alive?(req, resp, resp_framing)
    end

    # Interim 1xx (RFC 9110 §15.2): an informational response (100 Continue,
    # 103 Early Hints, …) is NOT the final response. A conformant proxy forwards it
    # to the client verbatim and keeps reading until the final (>=200) status;
    # otherwise the real response is stranded on the upstream socket — wrongly
    # recorded as THIS flow's response AND served to the next reused request
    # (response desync). 101 Switching Protocols is terminal (the upgrade) and falls
    # through. Returns the final {head, resp}, or nil when it recorded an error +
    # closed (malformed 1xx with a body, too many 1xx, or upstream closed).
    private def skip_interim_responses(upstream : IO, req : Codec::RawRequest, flow_id : Int64,
                                       resp_head : Bytes, resp : Codec::RawResponse) : {Bytes, Codec::RawResponse}?
      interim_seen = 0
      while interim_response?(resp)
        # RFC 9112 §6: a 1xx response MUST NOT carry content. An interim that declares
        # a body (Content-Length / Transfer-Encoding) is malformed AND a desync vector
        # — its "body" can embed a fake final response while the real one is stranded
        # for the next reused request. Refuse it: close the connection (don't parse a
        # body as the next response, don't reuse the upstream).
        if interim_has_body?(resp)
          @sink.on_response(FlowMapper.error_response(flow_id, "malformed interim 1xx response (declared a body)",
            head: resp.raw_head))
          release_upstream
          return nil
        end
        # Cap consecutive 1xx (like Burp/nginx) so a hostile upstream streaming endless
        # body-less 103s can't spin this fiber forever / flood the client (per-conn DoS).
        interim_seen += 1
        if interim_seen > MAX_INTERIM
          @sink.on_response(FlowMapper.error_response(flow_id, "too many interim 1xx responses (>#{MAX_INTERIM})"))
          release_upstream
          return nil
        end
        # RFC 9110 §15.2 / RFC 7231: a proxy MUST NOT forward a 1xx to an HTTP/1.0
        # client (it can't parse it). Read past it for everyone; forward only to 1.1.
        if req.version == "HTTP/1.1"
          begin
            @io.write(resp_head) # forward byte-exact (P6/P7); no rewrite on interim
            @io.flush
          rescue
            # Client gone mid-1xx (Stop / max-time / RST). Every other exit from this
            # method records on_response; an unguarded raise left the flow Pending forever.
            @sink.on_response(FlowMapper.error_response(flow_id, "connection closed while forwarding interim 1xx response"))
            release_upstream
            return nil
          end
        end
        resp_head = safe_read_head(upstream)
        if resp_head.nil?
          @sink.on_response(FlowMapper.error_response(flow_id, "upstream closed after interim 1xx response"))
          release_upstream
          return nil
        end
        resp = Codec::Http1.parse_response_head(resp_head)
      end
      {resp_head, resp}
    end

    # Does this request withhold its body until it is answered? RFC 9110 §10.1.1: `Expect` is a
    # comma-separated list of expectations and `100-continue` is the only one anyone defines, so
    # a case-insensitive containment test is both sufficient and deliberately lenient — the
    # answer only ever decides whether gori WAITS, never what it forwards (the header itself
    # goes upstream byte-exact like every other, P7).
    #
    # The version test belongs HERE, not at the call sites. RFC 9110 §10.1.1: a 100-continue
    # expectation on an HTTP/1.0 request MUST be ignored — such a client is not waiting for an
    # answer and could not parse one — so it is not withholding anything, which is the question
    # this predicate asks. Both the buffering paths (`elicit_request_body`) and the streaming one
    # ask it, and they must get the same answer: spelled only at the buffering site, a 1.0 client
    # on the streaming path paid a full EXPECT_CONTINUE_WAIT against a quiet origin before its
    # body could move, for an expectation it never made.
    private def expect_continue?(req : Codec::RawRequest) : Bool
      return false unless req.version == "HTTP/1.1"
      value = req.headers.get?("Expect")
      return false unless value
      value.downcase.includes?("100-continue")
    end

    # Settles an `Expect: 100-continue` on the STREAMING path, between the head going upstream
    # and the client's body being pumped (#728). Reached only through the caller's
    # `expects_continue` gate, so the client is HTTP/1.1, asked, and declared a body — this takes
    # no request: every 1xx it relays is one the client is entitled to and waiting for.
    # Returns `{early_head, send_body, client_gone}`:
    #
    #   - the origin sent `100 Continue` → relay it VERBATIM to the client (P6/P7: the origin's
    #     own bytes, never a reconstruction) and pump the body: `{nil, true, false}`.
    #   - the origin sent some OTHER well-formed 1xx first — 103 Early Hints, 102 Processing —
    #     which is relayed the same way but settles NOTHING. RFC 9110 §10.1.1 makes only the 100
    #     (or a final status) the permission to send a withheld body, so treating a 103 as the
    #     answer put gori back in the #728 deadlock one 1xx later: blocked reading a client that
    #     is still waiting, with the origin's real answer unread. So this loops, relaying each
    #     one and reading on. Bounded twice over — see the two guards in the body.
    #   - the origin answered something FINAL instead — 417 Expectation Failed, or a 401/403/30x
    #     it can decide without reading the body, both of which RFC 9110 §10.1.1 explicitly
    #     allows — then it does NOT want the body, and pumping one at a server that has stopped
    #     reading is how a request gets smuggled into the next response's framing. Hand the head
    #     back for relay and send nothing: `{head, false, false}`. A malformed 1xx (one declaring
    #     a body) takes this branch too, on purpose: `skip_interim_responses` already knows how
    #     to refuse it, and it gets a flow_id to record against, which this point does not have.
    #   - the origin closed / reset before answering → `{nil, false, false}`. Uploading a body
    #     into a dead socket buys nothing; `handle_response` reads the EOF and records
    #     "no response from upstream".
    #   - nothing arrived within EXPECT_CONTINUE_WAIT → gori writes the 100 ITSELF and pumps the
    #     body: `{nil, true, false}`. An origin that ignores the expectation is normal and
    #     conformant, and it is waiting for exactly the bytes the client is refusing to send, so
    #     SOMEONE has to move first. If that write fails the client is gone: `{nil, false, true}`.
    #     (Cost of the self-issued 100: a duplicate is possible when the origin's own 100 lands
    #     just after the deadline. RFC 9110 §15.2 requires a client to tolerate 1xx it did not
    #     even ask for, so a second one is harmless.)
    private def settle_expectation(upstream : IO) : {Bytes?, Bool, Bool}
      # ONE budget for the whole settlement, not one per read. A per-iteration timeout is no
      # timeout at all against an origin that emits a 103 every EXPECT_CONTINUE_WAIT - 1ms: it
      # never technically times out and the exchange never finishes. Each pass gets only what is
      # left. (The one overrun this cannot bound is the tail of a head already started — see
      # `read_head_within` for why finishing it is mandatory. It costs at most one HEAD_DEADLINE,
      # once, because that time is charged to the same budget and ends the loop.)
      deadline = Time.instant + EXPECT_CONTINUE_WAIT
      relayed = 0
      loop do
        left = deadline - Time.instant
        break if left <= Time::Span.zero
        answer = read_head_within(upstream, left)
        if answer.is_a?(NoAnswer)
          # Nothing will ever come: don't spend the client's body on a dead socket.
          return {nil, false, false} if answer.gone?
          break # Silent — the origin is ignoring the expectation; gori answers it below.
        end
        resp = Codec::Http1.parse_response_head(answer)
        return {answer, false, false} unless interim_response?(resp) && !interim_has_body?(resp)
        begin
          @io.write(answer)
          @io.flush
        rescue
          return {nil, false, true}
        end
        # THE settlement: only a 100 releases the body.
        return {nil, true, false} if resp.status == 100
        # Reuse the run cap `skip_interim_responses` enforces rather than inventing a second
        # ceiling. A peer that exceeds it gets its body withheld and the connection handed on
        # as-is: the remaining 1xx are still on the socket, and `skip_interim_responses` — which
        # holds a flow_id — refuses the run there and records "too many interim 1xx responses".
        # Across the two stages a hostile origin therefore buys at most 2 × MAX_INTERIM relays.
        relayed += 1
        return {nil, false, false} if relayed >= MAX_INTERIM
      end
      # The budget ran out, or the wait could not be bounded at all (a non-socket upstream —
      # specs, a future transport). Either way, blocking is the one thing that must not happen.
      write_own_continue ? {nil, true, false} : {nil, false, true}
    end

    # Why `read_head_within` came back without a head. The two are NOT interchangeable: an
    # origin that merely stayed quiet is still reading and still wants the body, while one that
    # closed or reset will never answer and there is nothing left to send a body to.
    enum NoAnswer
      Silent
      Gone
    end

    # Reads ONE response head, giving up if the first byte does not arrive within `wait`.
    # Returns the head, or which kind of non-answer ended the wait: `Gone` for EOF / reset / a
    # head that stopped mid-way, `Silent` for the timeout and for a non-socket IO whose read
    # cannot be bounded at all (the caller must never read `Silent` as "keep waiting").
    #
    # Only the FIRST byte is on the short clock. Once the origin has started to speak, the head
    # is finished under the connection's normal timeout via `safe_read_head` (with the peeked
    # byte pushed back through a `PrefixIO`, the same handoff `handle_connect` uses) — a short
    # deadline spanning the whole head would abandon a partially-consumed response on the socket,
    # which is a desync, not a timeout. That is the one part of `wait` this method cannot honour.
    private def read_head_within(upstream : IO, wait : Time::Span) : Bytes | NoAnswer
      sock = SocketTuning.underlying_socket(upstream)
      return NoAnswer::Silent unless sock
      saved = sock.read_timeout
      gone = false
      first = begin
        sock.read_timeout = wait
        byte = upstream.read_byte
        gone = true if byte.nil? # a clean EOF is knowable, and it is not a timeout
        byte
      rescue IO::TimeoutError
        nil # nothing came — the origin is ignoring the expectation, not dead
      rescue
        gone = true # reset, or a broken TLS session: this socket is finished
        nil
      ensure
        sock.read_timeout = saved
      end
      return (gone ? NoAnswer::Gone : NoAnswer::Silent) unless first
      # The origin started to speak and then stopped: a truncated head is no more an answer than
      # an EOF, and the socket it left behind cannot be written a body either.
      safe_read_head(PrefixIO.new(Bytes[first], upstream)) || NoAnswer::Gone
    end

    # gori's own `100 Continue` to the client. False when the client is gone.
    private def write_own_continue : Bool
      @io.write(CONTINUE_RESPONSE)
      @io.flush
      true
    rescue
      false
    end

    # The BUFFERING request paths — intercept hold, request-body Match&Replace, short circuit —
    # cannot ask the origin what it thinks of an `Expect: 100-continue`, because all three must
    # hold the COMPLETE body before anything goes upstream (the human has to see it, the rule has
    # to rewrite it, the stub has to drain it) and two of them may never dial an origin at all.
    # There is no one to relay, so gori answers the expectation itself — otherwise these paths
    # block on `read_complete` for a body the client is deliberately withholding, which is the
    # #728 deadlock with no origin even involved.
    #
    # The cost is stated plainly: gori commits to reading the body, so an origin that would have
    # answered 417 no longer gets the chance to refuse it before it is sent. That is the price of
    # buffering, it is paid only when the operator has switched on a hold/rewrite/stub rule for
    # this request, and it fails SAFE — a 100 promises nothing about the final status.
    #
    # A no-op (returns true, writes nothing) unless the client is actually withholding a body —
    # `expect_continue?` carries the HTTP/1.0 rule, and a declared body is the other half.
    # Returns false only when the write failed, i.e. the client is gone.
    private def elicit_request_body(req : Codec::RawRequest, framing : Codec::BodyFraming) : Bool
      return true unless expect_continue?(req) && !framing.none?
      write_own_continue
    end

    # Computes the response body framing, or records a visible error flow and
    # returns nil when the framing is illegal (CL+TE, non-final chunked, bad
    # Content-Length). We already hold a flow_id from on_request, so a raise here
    # used to leave the flow stuck Pending forever; record + close instead.
    #
    # The refused head goes ON the record. Refusing to FORWARD it is the security decision
    # (`Body.response_framing`); dropping the octets was an accident of reaching for the
    # "nothing arrived" mapper when something had. A head this rule rejects is a
    # response-desync primitive, so it is the finding an operator opened History for.
    private def response_framing_or_close(resp : Codec::RawResponse, method : String,
                                          flow_id : Int64) : {Codec::BodyFraming, Int64}?
      Codec::Body.response_framing(resp, method)
    rescue ex : Gori::Error
      @sink.on_response(FlowMapper.error_response(flow_id, "response framing rejected: #{ex.message}",
        head: resp.raw_head))
      release_upstream
      nil
    end

    # Streams the non-held response to the client while capturing it, then records
    # the flow. Returns true only if the whole body was delivered:
    #   - a raised write (the CLIENT aborted its read mid-response, e.g. an
    #     EventSource cancel) → record Aborted, return false;
    #   - `stream` returning false (the UPSTREAM cut a Content-Length/chunked body
    #     short) → record Aborted with a truncation note, return false;
    #   - otherwise → record Complete, return true.
    # Both failure modes previously either unwound to `run`'s blanket rescue
    # (leaving the flow Pending forever) or were recorded as a clean response.
    private def stream_nonhold_response(upstream : IO, sent_resp : Codec::RawResponse,
                                        sent_resp_head : Bytes, resp_framing : Codec::BodyFraming,
                                        resp_len : Int64, resp_capture : Codec::CaptureBuffer,
                                        flow_id : Int64, ttfb : Int64, started : Time::Instant,
                                        relaxed : Bool = false,
                                        extract_ref : ExtractRef? = nil) : Bool
      begin
        @io.write(sent_resp_head)
        @io.flush
        # The head is on the wire, so a head-scoped extract rule (cookie / header) may bind off
        # it — this is the streaming path, and P6 keeps it that way: no body is buffered here,
        # so a body-scoped rule is told it had nothing to read rather than silently missing.
        observe_delivered(extract_ref, sent_resp_head, nil)
        resp_complete = stream_response_body(upstream, resp_framing, resp_len, resp_capture, relaxed)
      rescue
        record_streamed_response(sent_resp, resp_framing, resp_capture, flow_id, ttfb, started,
          state: Store::FlowState::Aborted, error: "connection closed mid-response")
        return false
      end
      record_streamed_response(sent_resp, resp_framing, resp_capture, flow_id, ttfb, started,
        state: resp_complete ? Store::FlowState::Complete : Store::FlowState::Aborted,
        error: resp_complete ? nil : "upstream closed before response body complete")
      resp_complete
    end

    # Copies the response body upstream→@io. For a normal (timed) response this is just
    # `Codec::Body.stream`. For a RELAXED (close-delimited/SSE) stream both legs' timeouts
    # were cleared, so the copy can block on an idle-origin read indefinitely — and would
    # only notice the CLIENT already went away on its NEXT write to @io, which an idle origin
    # never triggers. That leaks this fiber + both sockets for every aborted SSE/long-poll
    # flow (and pins the flow Pending forever). So run a concurrent watcher on the client leg:
    # on a client FIN/reset it closes `upstream`, unblocking the copy's read; the copy then
    # raises and the caller records the flow Aborted (mirroring the failed-client-write abort).
    #
    # A one-shot `teardown` latch makes the copy and the watcher race to OWN the close, so a
    # normal completion isn't mistaken for an abort and neither double-closes. A legitimately-
    # idle-but-connected client keeps its write half open, so the watcher's @io.read simply
    # BLOCKS (no EOF) and the stream flows indefinitely — only a client that closed its side
    # trips teardown. A relaxed stream never keep-alives (handle_response closes it after), so a
    # watcher still parked on @io.read is safely ended when `run`'s ensure closes @io, with no
    # risk of colliding with a next reused request on this connection.
    private def stream_response_body(upstream : IO, resp_framing : Codec::BodyFraming,
                                     resp_len : Int64, resp_capture : Codec::CaptureBuffer,
                                     relaxed : Bool) : Bool
      return Codec::Body.stream(upstream, @io, resp_framing, resp_len, resp_capture, copy_buf) unless relaxed
      latch = TeardownLatch.new
      spawn watch_client_abort(upstream, latch)
      begin
        Codec::Body.stream(upstream, @io, resp_framing, resp_len, resp_capture, copy_buf)
      ensure
        # Claim teardown so a still-parked watcher can't close `upstream` after we hand it back.
        # Losing the claim means the watcher already fired (client gone, upstream closed under the
        # copy) — surface that as an abort so the caller records Aborted, not a clean/half read.
        # (claim? is non-blocking, so it can't interleave with the watcher's on the single thread.)
        raise IO::Error.new("client disconnected mid-stream") unless latch.claim?
      end
    end

    # The client-leg watcher for a relaxed streaming response (see stream_response_body). Blocks
    # reading @io: a 0-byte read (clean FIN) or any read error (reset) means the client closed
    # its side, so — if it wins the one-shot `latch` — it closes `upstream` to unblock the copy
    # loop. Bytes arriving from the client mid-stream are unusual for SSE/close-delimited (no
    # keep-alive follows) and are NOT proof the client left, so it just keeps watching.
    private def watch_client_abort(upstream : IO, latch : TeardownLatch) : Nil
      buf = Bytes.new(1)
      while @io.read(buf) > 0
      end
    rescue
      # client reset / read error → treat as gone (fall through to teardown)
    ensure
      upstream.close rescue nil if latch.claim?
    end

    private def record_streamed_response(sent_resp : Codec::RawResponse, resp_framing : Codec::BodyFraming,
                                         resp_capture : Codec::CaptureBuffer, flow_id : Int64,
                                         ttfb : Int64, started : Time::Instant, *,
                                         state : Store::FlowState, error : String?) : Nil
      duration = (Time.instant - started).total_microseconds.to_i64
      @sink.on_response(FlowMapper.response(sent_resp,
        flow_id: flow_id, body: resp_framing.none? ? nil : resp_capture.to_slice,
        ttfb_us: ttfb, duration_us: duration,
        body_truncated: resp_capture.truncated?, body_size: resp_capture.total,
        state: state, error: error, advisory: response_advisory(nil)))
    end

    # The buffered response-body path (no intercept): buffer the whole body, rewrite the entity,
    # re-frame the head (Content-Length), forward, capture, and offer the delivered bytes to the
    # extract rules. Returns the CLIENT keep-alive decision; the upstream is reused iff we read
    # the whole body cleanly AND the origin kept its side. Mirrors stream_nonhold_response + the
    # reuse tail of handle_response, minus the 101/close-delimited cases (excluded at the call
    # site so the buffer is always bounded).
    #
    # `@rewriter` may have no response-body rule at all here: since #501 slice 2 a body-scoped
    # EXTRACT rule brings a response down this path on its own, because it reads the entity.
    # The observer is handed the FORWARDED head + body — the pair `apply_body_rewrite` keeps
    # consistently framed — and lets `ContentDecode` de-chunk and inflate them, which is the
    # same code path `Repeater::Sender` extraction takes (slice 1). One decode implementation,
    # so the two surfaces cannot disagree about what a descriptor means.
    private def forward_response_rewriting_body(upstream : IO, req : Codec::RawRequest,
                                                sent_req : Codec::RawRequest, flow_id : Int64,
                                                host : String, port : Int32, scheme : String,
                                                resp : Codec::RawResponse, sent_resp_head : Bytes,
                                                resp_framing : Codec::BodyFraming, resp_len : Int64,
                                                ttfb : Int64, started : Time::Instant,
                                                extract_ref : ExtractRef? = nil) : Bool
      buf = IO::Memory.new
      resp_complete = Codec::Body.stream(upstream, buf, resp_framing, resp_len, Codec::DiscardIO.new, copy_buf)
      rw = @rewriter
      # `live` is false when only a body-scoped EXTRACT rule brought this response here: no
      # rewrite rule lost its chance, so there is nothing to say about one.
      sent_resp_head, fwd_body, advisory = apply_body_rewrite(sent_resp_head, buf.to_slice, resp_framing,
        host: host, response: true, live: !!rw.try(&.rewrites_response_body?)) do |e|
        rw && rw.rewrites_response_body? ? rw.rewrite_response_body(e, host) : e
      end
      sent_resp = Codec::Http1.parse_response_head(sent_resp_head) # head may have been re-framed
      stored, trunc, size = capped(fwd_body)
      state = resp_complete ? Store::FlowState::Complete : Store::FlowState::Aborted
      error = resp_complete ? nil : "upstream closed before response body complete"
      begin
        @io.write(sent_resp_head)
        @io.write(fwd_body) if fwd_body
        @io.flush
        # Delivered — head and body both, post-rewrite (P4: what the client received is what a
        # binding must agree with).
        observe_delivered(extract_ref, sent_resp_head, fwd_body || Bytes.empty, status: sent_resp.status)
      rescue
        # Client aborted its read mid-response — record what we have, then close.
        state = Store::FlowState::Aborted
        error = "connection closed mid-response"
        resp_complete = false
      end
      duration = (Time.instant - started).total_microseconds.to_i64
      @sink.on_response(FlowMapper.response(sent_resp,
        flow_id: flow_id, body: stored, ttfb_us: ttfb, duration_us: duration,
        body_truncated: trunc, body_size: size, state: state, error: error,
        advisory: response_advisory(advisory)))
      # Reuse iff the origin kept its side AND we read the whole body; a truncated body
      # was forwarded short, so close the client connection (return false) rather than
      # block its next keep-alive request on the missing bytes.
      update_upstream_reuse(resp_complete && origin_keep_alive?(sent_req, resp, resp_framing))
      return false unless resp_complete
      keep_alive?(req, resp, resp_framing)
    end

    # Reads the response head, transparently redialing + resending ONCE if a
    # REUSED idle keep-alive turned out stale (immediate EOF) and the request is
    # replayable (body-less). Returns {head, upstream} — `upstream` may be a fresh
    # connection after a retry, so callers must rebind their local.
    private def read_response_head(upstream : IO, host : String, port : Int32,
                                   reused : Bool, sent_head : Bytes, can_retry : Bool) : {Bytes?, IO}
      resp_head = safe_read_head(upstream)
      if resp_head.nil? && reused && can_retry
        release_upstream
        fresh, _ = acquire_upstream(host, port)
        if fresh
          upstream = fresh
          resp_head = safe_read_head(fresh) if write_request(fresh, sent_head, nil)
        end
      end
      {resp_head, upstream}
    end

    # `Codec::Http1.read_head` returns nil on a graceful EOF, but a RESET upstream
    # (RST, not FIN — e.g. a dead/killed backend) raises instead. Left uncaught, that
    # unwinds past the already-recorded Pending flow to `run`'s blanket rescue, which
    # closes the connection without ever marking the flow — it sits in History as
    # "waiting for response…" forever. Treat a reset the same as a graceful EOF (nil)
    # so the caller's existing "no response from upstream" handling covers it too.
    #
    # The read is bounded the same way the CLIENT head read is (`handle_request` above, and the
    # sibling `Repeater::Engine#read_response_head`): a slowloris ORIGIN dripping the response
    # head one byte at a time keeps resetting the per-read `io_timeout` armed in
    # `acquire_and_send`, so without a total head-assembly deadline this fiber, the client fd,
    # the upstream fd and one of `Server`'s MAX_CONNECTIONS permits are pinned for as long as
    # the origin cares to trickle (P6). `read_head_deadlined` restores the socket's baseline
    # read_timeout in its own ensure, so the body read that follows is untouched, and
    # `underlying_socket` returning nil (a non-socket IO) keeps the original loop. The
    # IO::TimeoutError it raises is caught below as a nil head — the caller's existing
    # "no response from upstream" path, so no new failure mode.
    private def safe_read_head(io : IO) : Bytes?
      Codec::Http1.read_head(io,
        deadline: SocketTuning::HEAD_DEADLINE, timeout_sock: SocketTuning.underlying_socket(io))
    rescue
      nil
    end

    # Apply response-head Match&Replace; returns the (possibly rewritten) head +
    # its parsed projection. Unchanged bytes keep the original (P7).
    private def apply_response_rewrite(resp_head : Bytes, resp : Codec::RawResponse, host : String) : {Bytes, Codec::RawResponse}
      rw = @rewriter
      return {resp_head, resp} unless rw
      rewritten = rw.rewrite_response(resp_head, host)
      return {resp_head, resp} if rewritten == resp_head
      {rewritten, Codec::Http1.parse_response_head(rewritten)}
    end

    # The intercept-hold response path: buffer the (non-streaming) body, let the
    # human edit/drop it, forward the result, and capture. Returns the CLIENT
    # keep-alive decision; the upstream is reused iff the ORIGIN kept its side.
    private def handle_held_response(ic : Gori::Interceptor, upstream : IO, req : Codec::RawRequest,
                                     sent_req : Codec::RawRequest,
                                     flow_id : Int64, host : String, port : Int32, scheme : String,
                                     resp : Codec::RawResponse, sent_resp_head : Bytes,
                                     resp_framing : Codec::BodyFraming, resp_len : Int64,
                                     ttfb : Int64, started : Time::Instant) : Bool
      # Buffer the body, tracking completeness (Codec::Body.read drops it). A
      # truncated/misframed body must NOT leave the upstream parked — its stray
      # unread bytes would become the next reused request's response (desync).
      buf = IO::Memory.new
      # tee into a discard sink, not a second IO::Memory — the body is already buffered in
      # `buf`; a throwaway IO::Memory would hold the whole response a second time.
      resp_complete = Codec::Body.stream(upstream, buf, resp_framing, resp_len, Codec::DiscardIO.new, copy_buf)
      # `buf` is filled once and never written again, and build_message copies head+body into
      # a fresh buffer, so `buf.to_slice` is a stable view — no defensive dup (which would hold
      # the whole body a second time). Mirrors the non-hold M&R path above.
      body = resp_framing.none? ? nil : buf.to_slice
      # Match&Replace (response body) BEFORE the human sees it, like the head. A body rule
      # re-frames the head to Content-Length; `resp` (status/version/Connection) is
      # untouched by that, so keep it as the origin's framing/keep-alive truth.
      advisory = nil.as(String?)
      if (rw = @rewriter) && rw.rewrites_response_body?
        sent_resp_head, body, advisory = apply_body_rewrite(sent_resp_head, body, resp_framing,
          host: host, response: true, live: true) { |e| rw.rewrite_response_body(e, host) }
      end
      decision = ic.hold_response(build_message(sent_resp_head, body),
        flow_id: flow_id, method: req.method, target: "#{resp.status} #{resp.reason}",
        host: host, port: port, scheme: scheme)
      duration = (Time.instant - started).total_microseconds.to_i64
      if decision.action.drop?
        @sink.on_response(FlowMapper.aborted_response(flow_id, "dropped by intercept",
          ttfb_us: ttfb, duration_us: duration))
        write_intercept_drop
        release_upstream
        return false
      end
      # Forward the decision bytes BYTE-EXACT (P7); the editor already synced
      # Content-Length for an edited body (InterceptView#forward_bytes). Keeping the
      # proxy byte-exact also preserves the head verbatim for a HEAD/304/204 response
      # forwarded unedited (whose Content-Length describes the entity, not the bytes).
      out_head, out_body = split_message(decision.bytes)
      sent_resp = Codec::Http1.parse_response_head(out_head)
      delivered = true
      begin
        @io.write(out_head)
        @io.write(out_body) if out_body
        @io.flush
      rescue
        # Client gone while we held the response (navigated away / Stop). The non-held
        # stream path already rescues this as Aborted; without the rescue the raise
        # unwound to run's blanket rescue and left the flow Pending forever — the
        # invariant this file states four times ("record + close, never unwind").
        delivered = false
      end
      stored, trunc, size = capped(out_body)
      if delivered
        # The operator's bytes are what the client got, so they are what a binding must agree
        # with (P4) — and a DROPPED response never reaches here at all, because the client never
        # received it. `decision.bytes` is a complete message, so its body half is already the
        # entity (the editor synced Content-Length); an empty one is a body we have, not a body
        # gori withheld, hence `Bytes.empty` rather than nil.
        observe_delivered(extract_ref_for(sent_req, host, scheme, sent_resp.status, flow_id),
          out_head, out_body || Bytes.empty)
        @sink.on_response(FlowMapper.response(sent_resp,
          flow_id: flow_id, body: stored, ttfb_us: ttfb, duration_us: duration,
          body_truncated: trunc, body_size: size, advisory: response_advisory(advisory)))
      else
        @sink.on_response(FlowMapper.response(sent_resp,
          flow_id: flow_id, body: stored, ttfb_us: ttfb, duration_us: duration,
          body_truncated: trunc, body_size: size, advisory: response_advisory(advisory),
          state: Store::FlowState::Aborted, error: "connection closed while forwarding held response"))
      end
      # Reuse the upstream iff we read the WHOLE body cleanly AND the origin kept its
      # side alive. Origin side keys on sent_req (what the origin received); the CLIENT
      # keep-alive (return value) uses the edited resp.
      update_upstream_reuse(resp_complete && origin_keep_alive?(sent_req, resp, resp_framing))
      return false unless delivered && resp_complete
      # The human may have edited the held response into conflicting framing (CL+TE); the
      # response was already forwarded + recorded above, so recompute the client-side framing
      # defensively — a raw response_framing raise here would unwind to run's blanket rescue
      # and drop the client connection abruptly instead of a clean keep-alive decision.
      client_framing =
        begin
          Codec::Body.response_framing(sent_resp, req.method)[0]
        rescue Gori::Error
          Codec::BodyFraming::CloseDelimited # unknowable framing → don't keep-alive
        end
      keep_alive?(req, sent_resp, client_framing)
    end

    # After a complete response, decide whether the live upstream can serve the
    # next request: keep it parked in the reuse slot, or close it now.
    private def update_upstream_reuse(origin_keep_alive : Bool) : Nil
      release_upstream unless origin_keep_alive
    end

    # A close-delimited or SSE (event-stream) response streams for an unbounded, idle-prone time;
    # relax BOTH legs' read/write timeouts so a legitimately-idle stream isn't torn down mid-flight
    # (keepalive reaps a genuinely dead peer). A normal Length/chunked response keeps the baseline
    # timeout, and the `run`/`acquire_and_send` re-arm restores it for any later keep-alive request.
    # Returns whether it relaxed — the caller then streams with a concurrent client-abort watcher
    # (an un-timed upstream read can't otherwise notice a gone client) and won't keep-alive after.
    private def relax_for_streaming_response(resp : Codec::RawResponse, resp_framing : Codec::BodyFraming, upstream : IO) : Bool
      # A 101 is not a stream, whatever Content-Type the ORIGIN put beside it: `handle_response`
      # hands @io to `WS::Relay.run` / `Pump.blind_tunnel` instead of closing it, so a relaxed
      # stream's client-abort watcher — which the guard below relies on `run`'s close to end
      # (see the comment at the `if relaxed` exit) — would stay parked on `@io.read` and eat the
      # tunnel's client→server bytes into its scratch buffer. The 101 branch relaxes both legs
      # itself. Mirrors the `status != 101` the two other `sse?` gates already carry.
      return false if resp.status == 101
      return false unless resp_framing.close_delimited? || sse?(resp)
      SocketTuning.relax(@io)
      SocketTuning.relax(upstream)
      true
    end

    # Why gori will not serve this h2c-in-CONNECT tunnel, or nil for one it will.
    #
    # `http2_disabled?` first, then `tls/tunnel.cr#h2_candidate?`'s three rule gates — a body
    # Match&Replace rule, a short-circuit stub, a body-scoped extract rule — all of which live
    # on `ClientConn`'s h1 path and are unreachable from the h2 relay. On the TLS path each
    # earns a downgrade to h1; here the client has already sent the preface, so the only honest
    # answers are refuse or lie.
    #
    # The SANDBOX is deliberately absent from this list (#731). It used to head it, because the
    # h2c relay really was wired with no gates at all — until #549 threaded `interceptor:` into
    # `intercept_h2c`'s relay call, which is what builds both `H2::StreamGate`s (`h2/relay.cr`),
    # and #492 step 4 had already put the per-STREAM blocking gate in them. So the sandbox now
    # reaches this tunnel exactly as it reaches the TLS h2 one, and the blanket refusal was
    # short-circuiting ahead of a gate that fails closed.
    private def h2c_refusal(host : String) : String?
      if Settings.http2_disabled?
        # Silently relaying would make "force HTTP/1.1" quietly untrue for this path, which is
        # worse than a visible refusal.
        "HTTP/2 is switched off (settings network.http2)"
      elsif @rewriter.try(&.rewrites_body_for_host?(host))
        "a Match&Replace BODY rule is live and body rewriting on HTTP/2 is not implemented yet"
      elsif @rewriter.try(&.short_circuits_for_host?(host))
        "a Match&Replace short-circuit rule is live and the h2 relay cannot answer a request locally"
      elsif @extractor.try(&.extracts_body_for_host?(host))
        "a body-scoped session-binding extract rule is live and the h2 relay never holds a body"
      end
    end

    # Refuse an h2c-in-CONNECT tunnel, VISIBLY (#731). Two of these refusals used to be a bare
    # `return false`: the client had already been told `200 Connection Established`, so the
    # tunnel appeared to open and then died with nothing in History and nothing in `gori.log`.
    #
    # ## What is deliverable here, and what is not
    #
    # NOT the h1 sandbox path's `403 + X-Gori-Sandbox: blocked`. The client committed to HTTP/2
    # the moment it sent the preface byte this branch peeked, and an h2 client cannot parse an
    # HTTP/1.1 response — the same reason the h2-preface-on-the-h1-path refusal above writes
    # nothing back, and the reason `write_framing_reject`'s precedent stops at record + close.
    #
    # Nor a synthesized SETTINGS + GOAWAY, which is the only thing this client COULD parse. gori
    # is not an h2 producer anywhere: `H2::StreamGate#refuse_locked` turns down exactly that
    # trade for the per-stream sandbox refusal, and gori has not read this client's preface at
    # all (one byte was peeked), so answering as an h2 endpoint would mean becoming one on a
    # path whose whole job is to relay. If that changes, it changes there first.
    #
    # So the refusal is delivered where an operator actually looks: a `gori.log` line, and an
    # error flow for the CONNECT itself. CONNECT is otherwise never a captured flow — the
    # reserved-host and self-loop refusals above record nothing — but those refuse BEFORE the
    # 200, where the client still gets an answer it can read. This one cannot, so the record is
    # the only thing left, and a row saying which rule or setting refused the tunnel is worth
    # more than a socket that closes for no stated reason.
    private def refuse_h2c(req : Codec::RawRequest, host : String, port : Int32,
                           reason : String) : Nil
      advice = "The client committed to HTTP/2 by sending the preface, so there is nothing to " \
               "downgrade — clear what refused it for this host, or reach it over TLS where " \
               "gori can downgrade the connection instead"
      ::Log.warn { "h2c CONNECT to #{host}: refused because #{reason}. #{advice}" }
      record_error(req, "http", host, port, now_us,
        "h2c CONNECT tunnel refused: #{reason}. #{advice}")
    end

    # Refuse a CONNECT tunnel whose first bytes are neither a TLS ClientHello nor the h2c
    # preface (#755) — `ssh -o ProxyCommand='nc -X connect …'` and every other non-TLS payload
    # a client tunnels through a proxy.
    #
    # NOT a blind tunnel, though the code to do one sits in `handle_connect`'s other branch (the
    # one a passthrough host or a CA-less proxy takes). #729 turned that
    # trade down on its own terms: a silent uncaptured relay is the anti-pattern
    # `settings/network.cr` names ("a bypassed host is otherwise INVISIBLE … so 'why is this
    # host missing from History?' has no answer anywhere"), and gori already HAS an explicit,
    # per-host spelling of exactly that relay. So the refusal names it. `Settings.tls_passthrough?`
    # is consulted one branch up, ahead of this peek, which is what makes the advice a
    # one-step fix rather than a description of some other mode.
    #
    # Nothing has been dialed at the point this is called, and that is the second half of the
    # fix: routing these bytes to `tls.intercept` meant `reflect_origin_h2` had already
    # completed a real TLS handshake against the target port before the client handshake failed.
    #
    # Written back to the client: nothing, for `refuse_h2c`'s reason — a peer speaking SSH (or
    # MQTT, or a database wire protocol) cannot parse an HTTP/1.1 response, so the record and
    # the log line are the whole delivery.
    #
    # A plaintext HTTP request tunnelled to port 80 lands here too, and is NOT served in the
    # clear even though `serve_self_page_connect` takes exactly that fallback and `ClientConn`
    # could be constructed over the stream. The difference is that this route has an ORIGIN.
    # `SSH-2.0-OpenSSH_9.6` is a well-formed-looking request line — `S` is a method-token char,
    # which is precisely why the #729 detector cannot judge it (`looks_like_http_request?`) —
    # so an h1 loop here would forward an SSH banner to port 22 AS A REQUEST. That trades a
    # clean refusal for a bogus forward, and it is the same reasoning that keeps text-banner
    # classification out of scope on the cleartext path. The self-page route has no origin to
    # forward to, so serving is a real answer there and not here.
    #
    # Uncapped, one log line and one flow per occurrence — deliberately the same discipline as
    # `refuse_h2c` directly above, whose population (a client that retries a refused tunnel) is
    # identical. If that becomes a flood the two should get a shared bound, not this one alone.
    private def refuse_non_tls_connect(req : Codec::RawRequest, host : String, port : Int32,
                                       peeked : Bytes) : Nil
      advice = "To carry this protocol, add #{host.inspect} to `network.tls_passthrough` — a " \
               "listed host skips this peek and gets an opaque byte-exact relay, which is how a " \
               "non-TLS tunnel (`ssh -o ProxyCommand='nc -X connect …'`) reaches its origin " \
               "through gori. Nothing was dialed for this connection"
      ::Log.warn { "CONNECT to #{host}:#{port}: refused, the tunnel opened with #{non_http_prefix(peeked)}, not TLS. #{advice}" }
      record_error(req, "http", host, port, now_us,
        "CONNECT tunnel refused: it opened with #{non_http_prefix(peeked)}, which can begin " \
        "neither a TLS handshake record (`0x16 0x03`) nor the HTTP/2 cleartext preface " \
        "(`PRI * HTTP/2.0`) — the only two things gori can decode here. #{advice}")
    end

    # A LISTENER's entry into the h2c relay (#737): a prior-knowledge preface that arrived
    # DIRECTLY on a reverse or transparent listener, with no CONNECT in front of it. Public
    # because `Proxy::Server` is the only caller; everything it delegates to is private here,
    # which is why the method lives beside them rather than in `server.cr`.
    #
    # It delegates, and that is the point. `intercept_h2c` — the dial, the two
    # `SocketTuning.relax` calls, the `H2::Relay.run` carrying all four lenses, the `ensure`
    # that frees the origin fd — already exists, and the wiring is already spelled twice (there
    # and `tls/tunnel.cr#relay_h2`). A third spelling in `Server` would be worse than the gap
    # #737 describes.
    #
    # The three RULE gates come with it rather than being re-tested by the caller: same
    # question, same answer, and with the preface already sent the only honest options are
    # refuse or lie. `http2_disabled?` — which `h2c_refusal` also reports — has already been
    # answered by `Server#serve_h2c`, which refuses it in the listener's own words before ever
    # reaching here; a second look costs one `Settings` read and cannot fire.
    #
    # Refusal is a log line and nothing else, unlike the CONNECT path's `refuse_h2c`. There is
    # no request to record against: `record_error` projects a flow from a `RawRequest`, and on
    # this path the connection opened with 24 preface octets, not a request. The h2 streams
    # that would have carried one are exactly what is being refused. Returns false so the
    # caller closes the socket — nothing else will, since ownership never passes to `run` here.
    def serve_h2c_prior_knowledge(host : String, port : Int32, client : IO) : Bool
      if reason = h2c_refusal(host)
        ::Log.warn do
          "h2c prior knowledge on a listener, for #{host}:#{port}: refused because #{reason}. " \
          "The client committed to HTTP/2 by sending the preface, so there is nothing to " \
          "downgrade — clear what refused it for this host, or reach it over TLS where gori " \
          "can downgrade the connection instead"
        end
        return false
      end
      intercept_h2c(host, port, client)
      true
    end

    # Cleartext HTTP/2 (h2c) tunnelled inside a CONNECT: the target is the CONNECT authority, so
    # we dial it plaintext and run the same h2 relay (no :authority routing / HPACK coupling
    # needed). The origin must speak h2c.
    private def intercept_h2c(host : String, port : Int32, client : IO) : Nil
      upstream = Upstream.dial(host, port, overrides: @host_overrides, pin: dial_pin)
      return unless upstream
      # Long-lived h2c relay: relax both legs so an idle h2 connection isn't reaped by the
      # baseline/io timeouts; keepalive (both legs) handles a dead peer.
      SocketTuning.relax(client)
      SocketTuning.relax(upstream)
      begin
        # The same four lenses the TLS h2 path wires in (`tls/tunnel.cr#relay_h2`). Only the
        # extractor was threaded here by #501 slice 2, and `HeadRewrite` is the ONLY producer
        # of the decoded projection an extract rule needs — so without a rewriter the
        # extractor was structurally inert on this path, and Match&Replace head rules and
        # intercept holds did not reach h2c-in-CONNECT at all. Nothing about this tunnel makes
        # those rules less applicable than on the TLS one; the asymmetry was a wiring gap, not
        # a decision (the surrounding comments enumerate the sandbox and `http2_disabled?`
        # gates and say nothing about rules or intercept).
        H2::Relay.run(client, upstream, host, port, @sink,
          rewriter: @rewriter, interceptor: @interceptor, extractor: @extractor)
      ensure
        upstream.close rescue nil
      end
    end

    # The h3 `Alt-Svc` seam (settings `network.strip_alt_svc`), HTTP/1.1's half. Returns the
    # head and projection the CLIENT should receive, plus the advisory for the flow.
    #
    # This is the ON half only. The OFF half — the advertisement got through and the flow has to
    # say so (#835) — is `note_alt_svc_kept`, and it deliberately runs LATER, after the rules.
    # See the comment there for why the two halves sit at different points.
    #
    # gori does not intercept HTTP/3: QUIC is UDP and every listener here is a TCP socket. A
    # client that acts on `Alt-Svc: h3=":443"` therefore leaves for a transport gori has no
    # way to read, and what the operator is left holding is a History that simply stops — the
    # one failure mode where "I found nothing" and "I could not see it" look identical. The
    # switch removes the invitation; this is where.
    #
    # Runs BEFORE Match&Replace, which is the OPPOSITE of where the 101's
    # `Sec-WebSocket-Extensions` strip below sits, and the two are not in disagreement. That
    # one prevents a protocol desync and so must have the last word over any rule; this one is
    # a blanket policy, and a response rule that puts the header back is the operator saying
    # so about THIS host, explicitly, which outranks a switch they threw for all of them (P4).
    #
    # The stripped head is CAPTURED as well as sent, exactly as a Match&Replace head rewrite
    # is: the stored response is the message gori delivered. What keeps the origin's
    # advertisement on the record is the advisory, which quotes the removed value — so the
    # switch costs the operator the bypass and not the evidence. One consequence worth knowing
    # rather than discovering: `Probe::Passive::Tech` reads the STORED head, so a CAPTURED
    # response stops fingerprinting `tech_http3` once the strip is on. The advisory is where
    # that fact moves to, and the `alt_svc_h3` event it would have raised was a warning about a
    # bypass that can no longer happen.
    #
    # The PROXY path only, and deliberately: a response gori itself elicited — Repeater, Fuzz,
    # Discover, MCP `send_request`, an import — is built by `Gori::Outbound` and never reaches
    # this seam, so it keeps the origin's `Alt-Svc` and still fingerprints. That asymmetry is
    # the right way round. The strip exists to keep a CLIENT on a transport gori can read, and
    # gori's own sender has no client to lose.
    private def settle_alt_svc(head : Bytes, resp : Codec::RawResponse,
                               host : String) : {Bytes, Codec::RawResponse, String?}
      return {head, resp, nil} unless Settings.strip_alt_svc?
      # Asked of the already-parsed projection: the overwhelming majority of responses carry
      # no `Alt-Svc` at all, and this keeps that case at one header-list lookup rather than a
      # walk over the head.
      return {head, resp, nil} unless resp.headers.has?(Gori::AltSvc::FIELD_NAME)
      stripped, removed = Gori::AltSvc.strip_h3(head)
      # An `Alt-Svc` that advertises no h3 — `clear`, or a plain `h2=` alternative — is left
      # byte-exact (P7). It costs gori no visibility, and `clear` is the spelling that tells a
      # client to FORGET an alternative it already cached.
      return {head, resp, nil} if removed.empty?
      note = Gori::AltSvc.removal_note(removed)
      if @alt_svc_logged.size < COMPRESSED_SKIP_LOG_CAP && @alt_svc_logged.add?(host)
        ::Log.info { "alt-svc #{host}: #{note}" }
      end
      {stripped, Codec::Http1.parse_response_head(stripped), note}
    end

    # The advisory for the switch's OTHER position: this response advertised h3, gori did not
    # remove it, and a client acting on it is about to leave for a transport gori cannot read
    # (#835). Returns nil when nothing in the head advertises h3.
    #
    # NOTHING is touched but the advisory. `head` is the slice already on its way to the client
    # and the return value is a string, so the origin's bytes reach it untouched (P7) — which is
    # the point: with the switch off the operator asked for the advertisement to be delivered.
    # What they were not getting is any record that it happened, and a gap in History that
    # nothing explains is indistinguishable from a target that had nothing more to say.
    #
    # Asked AFTER Match&Replace rather than beside the strip. The two halves are not symmetric:
    # over-stating a removal is harmless, but a "clients are leaving via this host" warning
    # raised for a response whose `Alt-Svc` an operator's own rule already removed is a false
    # alarm on the one host they had handled — and this file's own P4 note says a per-host rule
    # outranks the global switch. A rule is a STANDING policy, which is what makes it worth
    # asking after; an intercept edit that deletes the field by hand still gets the notice,
    # because it happens past this point on a path that returns from four places, and an
    # operator hand-editing that header is already looking straight at it.
    #
    # `AltSvc.strip_h3` and NOT `resp.headers`, discarding the bytes it builds. The parsed
    # projection is a DIFFERENT VIEW of the same head: `parse_headers` keeps only the first line
    # of an obs-folded field and drops the continuation, while `strip_header_lines` hands its
    # block the JOINED value on purpose (see its comment — what a lenient recipient acts on, not
    # what gori filed). Detecting on the projection therefore missed exactly what the strip
    # removes: an origin sending `Alt-Svc: h2=":8443"` folded onto ` , h3=":443"` got stripped
    # and reported with the switch ON, and passed in SILENCE with it off. Asking the strip's own
    # function makes the two answers equal by construction rather than by an audit.
    private def note_alt_svc_kept(head : Bytes, resp : Codec::RawResponse, host : String) : String?
      # Same cheap gate the strip uses, and correct here despite the view difference: an
      # obs-folded field still has its NAME on the first line, so the projection records the
      # entry — only its value is short. The gate asks whether the field is present at all.
      return nil unless resp.headers.has?(Gori::AltSvc::FIELD_NAME)
      _, kept = Gori::AltSvc.strip_h3(head)
      return nil if kept.empty?
      note = Gori::AltSvc.kept_note(kept)
      # Once per host per SESSION, not per connection: a browser opens several connections per
      # origin and churns them, and this notice — unlike the strip's, which is opt-in — fires in
      # the default configuration against origins that mostly advertise h3. See
      # `Settings.first_alt_svc_h3_notice?`.
      ::Log.info { "alt-svc #{host}: #{note}" } if Settings.first_alt_svc_h3_notice?(host)
      note
    end

    # The advisory a RESPONSE record carries: what the body seam had to say, what the proxy
    # did to the head on its own account, and what is wrong with the head the origin sent.
    # Newline-separated, which is the shape `Store::FlowRow#advisories` splits back apart.
    private def response_advisory(body : String?) : String?
      notes = [body, @alt_svc_note, @status_line_note].compact
      return nil if notes.empty?
      notes.join("\n")
    end

    # The sentence for a response whose start-line is not a status line, or nil for one that
    # is. `parse_response_head` still fills `status`/`reason` from whatever it found there —
    # it has to, a captured flow has to render — so History shows a plausible code for a line
    # that never was one, and the row reads as an ordinary exchange.
    #
    # The shape that produces it is worth naming in the sentence: an origin whose body ran
    # PAST its own Content-Length leaves that tail in gori's upstream buffer, and the next
    # request on that reused connection reads `<tail>HTTP/1.1 200 OK` as its status line. The
    # bytes are recorded exactly (P7) and forwarded exactly — response framing stays lenient
    # on purpose (`Body.response_framing`) — so the record is right and only the DERIVED
    # columns were lying. This is the one place that says so.
    private def status_line_note(resp : Codec::RawResponse) : String?
      return nil unless resp.malformed?
      raw = resp.raw_head
      eol = raw.index { |b| b == 0x0d_u8 || b == 0x0a_u8 } || raw.size
      # Clip the BYTES before building a String: the "line" here can be a body tail of any
      # length, and it is about to sit in a History row.
      line = String.new(raw[0, Math.min(eol, STATUS_LINE_QUOTE_MAX + 1)])
      quoted = line.size > STATUS_LINE_QUOTE_MAX ? "#{line[0, STATUS_LINE_QUOTE_MAX]}…" : line
      "the origin's start-line is not an HTTP status line (#{quoted.inspect}) — the status " \
      "and reason on this row are whatever gori could read out of it. Junk in front of a " \
      "version is what a body that over-ran its Content-Length leaves for the next request " \
      "on a reused connection"
    end

    # The `Sec-WebSocket-Extensions` half of a 101 (#518). Returns the head and projection
    # the CLIENT should receive, plus an advisory for the flow's WebSocket message stream —
    # a `gori.log` line is where an operator does not look, and this is a fact about the
    # socket they are about to read frames from.
    #
    # Two cases, and the code already knows which it is in:
    #
    #   * gori removed the offer and nothing put it back on the wire — then the origin was
    #     never offered anything, its acceptance answers a header it did not receive, and
    #     relaying it is what CREATES a desync: the client turns permessage-deflate on and
    #     sends RSV1 frames the origin must fail the connection over (RFC 6455 §5.2). Both
    #     halves go, and History stops reading as "the origin sent an unsolicited accept".
    #   * the origin really was offered it — an operator's Match&Replace rule put the offer
    #     back, or the origin accepted one nobody offered (§4.1). Here the two peers DO
    #     agree, so removing the accept is the manufactured desync the old policy warned
    #     about. The bytes are left alone and the store is what suffers, which is what the
    #     advisory says.
    private def settle_ws_extensions(head : Bytes, resp : Codec::RawResponse,
                                     sent_req : Codec::RawRequest, sent_head : Bytes,
                                     host : String) : {Bytes, Codec::RawResponse, String?}
      accepted = resp.headers.get?(WS::Handshake::EXTENSIONS_NAME)
      return {head, resp, nil} if accepted.nil? || accepted.blank?
      label = ws_log_label(host, sent_req.target)
      # `sent_head` and not `sent_req`: the strip runs before Match&Replace so a rule CAN put
      # the offer back, and when it does the origin really was offered the extension.
      if @ws_offer_stripped && !WS::Handshake.carries_extensions?(sent_head)
        stripped = WS::Handshake.strip_extensions(head)
        note = "removed the origin's #{accepted.inspect} acceptance from the 101 — gori had " \
               "already removed the client's Sec-WebSocket-Extensions offer, so the origin " \
               "negotiated no extension and a client acting on that accept would have sent " \
               "it frames it cannot read (#518)"
        ::Log.info { "ws #{label}: #{note}" }
        return {stripped, Codec::Http1.parse_response_head(stripped), note}
      end
      note = "origin accepted extension #{accepted.inspect} that gori did not remove — the " \
             "captured frames on this socket are that extension's encoded bytes, not the " \
             "messages (#518)"
      ::Log.warn { "ws #{label}: #{note}" }
      {head, resp, note}
    end

    # `host` + `target` for a log line. On the plaintext forward-proxy path `target` is
    # ABSOLUTE-form — that is how a proxy client writes a request line — so concatenating
    # produced `ws 127.0.0.1http://127.0.0.1:19251/ws`. An absolute-form target already
    # names the authority, leaving the host nothing to add.
    private def ws_log_label(host : String, target : String) : String
      # `Url.location` is that rule's one home, and it tests the scheme case-INSENSITIVELY
      # (RFC 3986 3.1) — the hand-rolled pair here missed `HTTP://`, so an uppercase-scheme
      # request line still produced the doubled label this method exists to prevent.
      Gori::Url.location(host, target)
    end

    private def websocket_upgrade?(resp : Codec::RawResponse) : Bool
      resp.status == 101 && WS::Handshake.upgrades_to_websocket?(resp.headers)
    end

    # What gori did with a 101 that is NOT a WebSocket, put on the record (#736).
    #
    # Same seam the WebSocket branch's handshake advisory uses (`WS::Relay.record_notice`): one
    # `NOTICE_PREFIX`-marked `ws_messages` row on the flow. That table is read for ANY status-101
    # flow and not only WebSocket ones — History's MESSAGES pane, `gori run show`, MCP
    # `get_flow`, a HAR export — so the sentence travels wherever the flow does, and
    # `NOTICE_PREFIX` is what keeps a repeater seed from replaying gori's own prose as traffic.
    # The `gori.log` line is the SECOND copy, not the only one: it reaches only an operator who
    # already knew to tail it.
    #
    # The protocol named is the ORIGIN's — a 101 echoes `Upgrade` (RFC 9110 §15.2.2) and that is
    # what the connection actually became — falling back to what the CLIENT offered when the
    # origin left it out. `.inspect` for the same reason `settle_ws_extensions` uses it: the
    # token is unvalidated wire bytes and must not be pasted raw into a stored sentence.
    # `NOTICE_DIRECTION` is one column that cannot say which way the bytes went, so the sentence
    # does (see the constant's own doc). Best-effort, like its WebSocket sibling: a capture write
    # that fails must never take down a connection that has already finished its work.
    private def record_opaque_upgrade(flow_id : Int64, resp : Codec::RawResponse,
                                      req : Codec::RawRequest, host : String, target : String,
                                      moved : {a_to_b: Int64, b_to_a: Int64}) : Nil
      token = resp.headers.get?("Upgrade").try(&.presence) || req.headers.get?("Upgrade").try(&.presence)
      named = token ? "protocol #{token.inspect}" : "a protocol neither the request nor the 101 named"
      note = "101 switched this connection to #{named}; gori does not decode it and relayed it " \
             "as an opaque byte tunnel, so nothing after this response is captured — " \
             "#{moved[:a_to_b]} bytes client→server, #{moved[:b_to_a]} bytes server→client"
      # `Url.location` and not `host + target`: on the plaintext forward-proxy path the target is
      # absolute-form and already names the authority — the one home for that rule, and the same
      # one `ws_log_label` exists to route its callers to.
      ::Log.info { "upgrade #{Gori::Url.location(host, target)}: #{note}" }
      @sink.on_ws_message(flow_id, WS::Relay::NOTICE_DIRECTION, WS::OP_TEXT.to_i,
        "#{WS::NOTICE_PREFIX}#{note}".to_slice)
    rescue
      nil
    end

    # An interim 1xx informational response (100 Continue / 102 / 103 Early Hints /
    # …) — forwarded to the client, then skipped to read the final status. 101
    # Switching Protocols is terminal (handled as an upgrade), so it is NOT interim.
    private def interim_response?(resp : Codec::RawResponse) : Bool
      resp.status >= 100 && resp.status < 200 && resp.status != 101
    end

    # A 1xx that illegally declares body framing (Content-Length / Transfer-Encoding)
    # — malformed per RFC 9112 §6 and a response-smuggling vector.
    private def interim_has_body?(resp : Codec::RawResponse) : Bool
      !!(resp.headers.get?("Content-Length") || resp.headers.get?("Transfer-Encoding"))
    end

    # CONNECT host:port -> 200, then TLS MITM (if configured) or blind tunnel.
    #
    # A host on the TLS passthrough list takes the blind-tunnel branch even when MITM IS
    # configured: no leaf is minted and the client validates the origin's own certificate,
    # which is the whole point (a pinning client would otherwise break). Deliberately AFTER
    # connect_answered_locally? — the reserved self-host, the self-loop refusal and the
    # sandbox gate must all keep winning, so a passthrough pattern can neither strand the CA
    # download nor open a tunnel the sandbox refuses. Reading Settings here (not in the
    # Tunnel) is what makes the bypass cover the h2c-in-CONNECT branch too: the byte peek
    # below never happens for a passthrough host.
    private def handle_connect(req : Codec::RawRequest) : Bool
      host, port = Upstream.split_host_port(req.target, 443)

      # A LISTENER-pinned connection is not a forward proxy. The destination was settled before
      # this request existed — a reverse listener's declared origin, or the client's own SOCKS5
      # CONNECT — and `resolve_forward` holds every ordinary request to it. `CONNECT` is the one
      # shape that never reaches `resolve_forward`, so without this it walks straight out of the
      # pin: a granted SOCKS5 tunnel to one host, then one line of HTTP, and gori opens a blind
      # byte tunnel somewhere else entirely with no flow to show for it. Refused whatever
      # authority it names, including the pinned one — the socket never advertised proxy
      # semantics, and answering at all is what makes the destination negotiable.
      #
      # `@listener_pinned`, not `@fixed_host`. The TLS MITM tunnel pins its inner `ClientConn`
      # the same way (`Tls::Tunnel#intercept`), and there the client DID negotiate a proxy hop —
      # gori answered its `CONNECT`. A second `CONNECT` inside that tunnel is a client testing an
      # upstream proxy through gori, which worked before this guard existed and still does.
      if @listener_pinned && (fixed = @fixed_host)
        return refuse_connect_on_pinned(req, fixed, host, port)
      end

      return false if connect_answered_locally?(host, port)

      if (tls = @tls) && !Settings.tls_passthrough?(host)
        intercept_tunnel(req, host, port, tls)
      else
        upstream = Upstream.dial(host, port, overrides: @host_overrides, pin: dial_pin)
        unless upstream
          write_gateway_error
          return false
        end
        # begin/ensure so the dialed origin fd is freed even if the 200 reply
        # write raises (client RST between CONNECT and our reply) or blind_tunnel
        # itself raises — otherwise one upstream fd leaks per CONNECT-then-reset.
        begin
          @io.write("HTTP/1.1 200 Connection Established\r\n\r\n".to_slice)
          @io.flush
          # Blind CONNECT tunnel: relax both legs so an idle tunnel (IMAP IDLE, long-poll, a quiet
          # TLS session) isn't reaped by the 30 s io_timeout; keepalive reaps a genuinely dead peer.
          SocketTuning.relax(@io)
          SocketTuning.relax(upstream)
          Pump.blind_tunnel(@io, upstream)
        ensure
          upstream.close rescue nil
        end
      end
      false # the connection has been consumed by the tunnel
    end

    # The MITM half of a CONNECT: answer 200, then peek to decide which of the three protocols
    # gori can carry is inside, and hand the stream to it. Every path here ENDS the connection —
    # the tunnel consumes it — which is why this returns Nil and `handle_connect` falls through
    # to its own `false`.
    private def intercept_tunnel(req : Codec::RawRequest, host : String, port : Int32,
                                 tls : TlsMitm) : Nil
      @io.write("HTTP/1.1 200 Connection Established\r\n\r\n".to_slice)
      @io.flush
      # Peek to route the tunnel. THREE outcomes, not two, and each one decided on enough
      # bytes to actually mean it: a TLS handshake record (`Tls::ClientHello.record_start?` —
      # `0x16` and a major version of 3), the HTTP/2 cleartext preface
      # (`H2::Frame.preface_prefix?` — four octets of `"PRI "`), and neither.
      #
      # That third arm is #755, and BOTH tests widened for it. This used to route `0x50` to
      # h2c and everything else to `tls.intercept`, on the stated assumption that the only two
      # things a client sends inside a tunnel are a ClientHello or a preface:
      #
      #   * `ssh -o ProxyCommand='nc -X connect …'` — a routine corporate-proxy pattern — fed
      #     `SSH-2.0-OpenSSH…` into an OpenSSL SERVER handshake, which raised into
      #     `Tunnel#intercept`'s rescue and closed with no flow and no log. And it closed having
      #     already touched the origin: `reflect_origin_h2` runs BEFORE the client handshake, so
      #     a real ClientHello advertising ALPN `h2` had been fired at the SSH server's port 22.
      #   * `0x50` is also `POST`, `PUT`, `PATCH` and `PROPFIND`. A plaintext request tunnelled
      #     to port 80 (`curl --proxytunnel -X POST`) was diverted into the h2 relay, which
      #     dials the origin and then dies at `Frame.read_preface` — while the same request
      #     spelled `GET` took the other branch. Behaviour split on the first letter of the
      #     method, which is why the floor lives in `H2::Frame` now and both callers share it.
      #
      # Only the two arms that COMMIT read past the first byte, so the common refusals (`S`,
      # `G`, `0x10`) still decide on one octet with nothing extra to wait for.
      #
      # The `read_byte`s themselves stay silent when they time out, and deliberately: a client
      # that opens a CONNECT and then holds the tunnel without sending a ClientHello is a
      # browser's speculative preconnect, which is ordinary and must not write a flow per
      # occurrence. It is not the #755 shape either — that one is a connection that sent ZERO
      # bytes, and this client sent a CONNECT (see `record_silent_client`). A client that
      # genuinely needs to speak first on the far side is served by listing the host in
      # `network.tls_passthrough`, which skips this peek entirely.
      first = @io.read_byte
      return false if first.nil?
      if first == 0x50_u8
        peeked = read_peek(first, H2::Frame::PREFACE_FLOOR)
        return false if peeked.nil?
        unless H2::Frame.preface_prefix?(peeked)
          refuse_non_tls_connect(req, host, port, peeked)
          return
        end
        # Cleartext h2 (h2c) tunnelled inside CONNECT. `h2c_refusal` is the whole gate:
        # the setting, and the three rule kinds the h2 relay structurally cannot apply — a
        # tunnel that looked like it honoured the rule table while a stub rule quietly let
        # the request reach the origin would be worse than a visible refusal. The SANDBOX is
        # not among them and no longer refuses this tunnel outright (#731): `intercept_h2c`
        # wires the interceptor into the relay, so `H2::StreamGate` blocks out-of-scope
        # streams here per stream, exactly as it does on the TLS h2 path.
        if reason = h2c_refusal(host)
          refuse_h2c(req, host, port, reason)
          return
        end
        intercept_h2c(host, port, PrefixIO.new(peeked, @io))
      elsif first == Tls::ClientHello::RECORD_HANDSHAKE
        peeked = read_peek(first, 2)
        return false if peeked.nil?
        unless Tls::ClientHello.record_start?(peeked)
          refuse_non_tls_connect(req, host, port, peeked)
          return
        end
        tls.intercept(host, port, PrefixIO.new(peeked, @io), @sink, dial_addr: dial_pin)
      else
        refuse_non_tls_connect(req, host, port, Bytes[first])
        return
      end
    end

    # `first` plus however many more bytes the routing decision needs, as one slice to compare
    # and then to hand back through a `PrefixIO` (P7: the tunnel's handler must see the complete
    # stream). nil when the client closed before `want` arrived — the caller's `return false`
    # then ends the connection, which is all there was to do with a half-sent preface anyway.
    #
    # Called only from the two arms that have already COMMITTED to a protocol, so the blocking
    # read is bounded by a client that has said it is about to send 24 (h2c) or 5+ (TLS record)
    # octets. A refusal never reaches here.
    private def read_peek(first : UInt8, want : Int32) : Bytes?
      buf = Bytes.new(want)
      buf[0] = first
      i = 1
      while i < want
        byte = @io.read_byte
        return nil if byte.nil?
        buf[i] = byte
        i += 1
      end
      buf
    end

    # Everything decided BEFORE answering 200 to a CONNECT: cases gori handles or refuses
    # itself rather than opening a tunnel. True when the connection has been dealt with.
    private def connect_answered_locally?(host : String, port : Int32) : Bool
      # A RESERVED host — a proxy-configured client that browsed to `https://gori.proxy/`
      # (or was upgraded there by HTTPS-First). Answered locally under gori's own leaf: the
      # client won't trust it yet, which is exactly what it came here to fix, so the warning
      # is expected and clicking through reaches the CA download. Terminal like the plaintext
      # branch — a reserved name is never dialed. Deliberately ahead of the sandbox gate
      # below: this reaches no origin and no network, so the safe-testing contract ("don't
      # handshake with an out-of-scope ORIGIN") is untouched, and a scope that happens not to
      # cover the setup page must not strand the CA download.
      if reserved_self_host?(host)
        serve_self_page_connect(host)
        return true
      end

      # A CONNECT whose (override-resolved) authority is gori's own listener would
      # loop the proxy into itself — refuse before answering 200 / starting MITM.
      if (sa = @self_addr) && Upstream.loops_to_self?(host, port, @host_overrides, sa, @local_host)
        write_gateway_error
        return true
      end

      # Sandbox: refuse to even open a tunnel to a host that CAN'T be in scope (safe-testing:
      # don't handshake with an out-of-scope origin at all). A host that MIGHT be in scope —
      # e.g. only url/path rules narrow it — IS tunnelled and MITM'd, and the precise per-request
      # block then happens inside: `handle_request` below on h1, `H2::StreamGate` on the h2 relay
      # (#492 step 4). Answered before the 200 so the client sees the CONNECT itself refused.
      if (ic = @interceptor) && ic.sandbox_blocks_host?(host)
        write_sandbox_block
        return true
      end

      false
    end

    # A hostname gori answers for ITSELF instead of proxying — the mitm.it-style entry point
    # for a client that already has gori configured as its proxy, and therefore sends
    # absolute-form (or CONNECT) and can never match the direct-hit test in
    # Upstream.addresses_self?. An explicit host override on the name is the escape hatch,
    # for the rare LAN that has a real box called "gori"; that mirrors why addresses_self?
    # skips override resolution — a mapping the user wrote down is a statement of intent.
    #
    # Asked through `Upstream.override_address`, which is the SAME chain the dial itself
    # resolves. This used to read the project table directly, and so disagreed with the dial
    # twice: it could not see a GLOBAL (settings.json) override at all, and it matched the
    # host byte-for-byte where `magic_host?` chomps a trailing root dot — so `gori.proxy.`
    # stayed reserved no matter what the operator wrote. Both spellings ended at the 502 in
    # `handle_reserved_host` with no way out.
    private def reserved_self_host?(host : String) : Bool
      SelfPage.magic_host?(host) && Upstream.override_address(host, @host_overrides).nil?
    end

    # The plaintext half of the reserved-host route. Returns true when the request was
    # dealt with here — which is EVERY reserved-host request, servable or not. That is the
    # point: we must never fall through to Upstream.dial, because bare "gori" resolves on
    # any network with a DNS search domain and the request would go to a stranger.
    private def handle_reserved_host(req : Codec::RawRequest, scheme : String, host : String,
                                     port : Int32, created_at : Int64) : Bool
      return false unless reserved_self_host?(host)
      if (sa = @self_addr) && (tls = @tls) && tls.serve_landing? && get_or_head?(req)
        serve_self_page(req, tls, sa)
      else
        record_error(req, scheme, host, port, created_at, "reserved host, not proxied: #{host}")
        write_gateway_error
      end
      true
    end

    # The CONNECT half of the reserved-host route (see handle_connect). Answers 200, then peeks
    # ONE byte: a TLS ClientHello (0x16) goes to the TlsMitm seam, anything else is a plaintext
    # CONNECT tunnel (`curl --proxytunnel` at port 80) and is served in the clear rather than
    # forced into a doomed handshake.
    #
    # Deliberately NOT `handle_connect`'s three-way peek (#755). The question here is different
    # and the fallback answers it: there is no origin on this route — it is gori's own page — so
    # "not TLS" means "serve the page in the clear", which is a real answer rather than a
    # refusal, and a second byte could block on a client that sent only the first.
    private def serve_self_page_connect(host : String) : Nil
      sa = @self_addr
      tls = @tls
      unless sa && tls && tls.serve_landing?
        # Same shape as the CONNECT self-loop refusal: refuse before the 200, record nothing
        # (CONNECT is never a captured flow), and above all never dial the reserved name.
        return write_gateway_error
      end

      @io.write("HTTP/1.1 200 Connection Established\r\n\r\n".to_slice)
      @io.flush
      first = @io.read_byte
      return if first.nil?
      stream = PrefixIO.new(Bytes[first], @io)
      listen = listen_display(sa)
      if first == 0x16_u8
        tls.intercept_self_page(host, stream, listen)
      else
        tls.serve_self_page_once(stream, listen)
      end
    end

    # Resolves {host, port, scheme, forward_head}. Absolute-form request targets
    # (forward-proxy plain HTTP, e.g. `GET http://h/p`) are rewritten to
    # origin-form for the upstream; the captured truth keeps the original bytes.
    private def open_upstream(host : String, port : Int32) : IO?
      if @tls_upstream
        sock, err = Upstream.dial_tls_result(host, port, verify: @verify_upstream,
          overrides: @host_overrides, pin: dial_pin)
        @last_dial_error = err
        sock
      else
        # A plaintext forward-proxy dial has no TLS leg to classify, but it DOES go through the
        # upstream proxy (gori CONNECT-tunnels even http:// targets), so it can be refused by
        # one — which is why this branch now asks for the reason too instead of clearing it.
        sock, err = Upstream.dial_result(host, port, overrides: @host_overrides, pin: dial_pin)
        @last_dial_error = err
        sock
      end
    end

    # The error text for a failed upstream acquire/send. A nil `upstream` is a DIAL failure,
    # split into unreachable (connect), a name that never resolved, a certificate rejection —
    # the #323 case, whose fix is --insecure-upstream, so the recorded flow points there
    # instead of at reachability — a handshake the origin refused for some other reason, an
    # origin that accepted the connection and then went silent, and a refusal by the
    # configured upstream proxy, where the origin was never contacted at all.
    # A non-nil `upstream` means the socket was live but the mid-request write failed.
    #
    # The branches key on `err.kind`, never on `@verify_upstream`: the dialer knows whether
    # verification is what rejected the origin, and guessing it from the flag is what made a
    # black hole and a plaintext port both read as an untrusted certificate.
    private def upstream_error_message(host : String, port : Int32, upstream : IO?) : String
      return "upstream write failed: #{host}:#{port}" unless upstream.nil?
      err = @last_dial_error
      if err
        case err.kind
        when .tls_verify?
          return "upstream TLS verification failed: #{host}:#{port} — origin certificate not trusted; " \
                 "retry with --insecure-upstream or set SSL_CERT_FILE#{err.because}"
        when .tls?
          return "upstream TLS handshake failed: #{host}:#{port} — the port may not be TLS, or the " \
                 "origin refused the protocol/cipher#{err.because}"
        when .timeout?
          return "upstream TLS handshake timed out: #{host}:#{port} — the origin accepted the " \
                 "connection and then sent nothing; no certificate was exchanged, so " \
                 "--insecure-upstream and SSL_CERT_FILE cannot help#{err.because}"
        when .dns?
          return "upstream DNS lookup failed: #{host} — the name did not resolve, so nothing was " \
                 "dialed#{err.because}"
        end
      end
      # A detail REPLACES the host-shaped sentence rather than decorating it. Every detail the
      # dialer sets is about a proxy — either one that refused the tunnel or one gori could not
      # reach — and in both cases the origin was never contacted, so naming it here is exactly
      # what used to send operators to debug DNS on a machine that was fine.
      if detail = err.try(&.detail)
        return "upstream connect failed: #{detail}"
      end
      "upstream connect failed: #{host}:#{port}"
    end

    private def resolve_forward(req : Codec::RawRequest) : {String, Int32, String, Bytes}
      # Post-CONNECT tunnel, a reverse listener, or a granted SOCKS5 CONNECT: all requests go
      # to the pinned origin, byte-exact. The declared Host rewrite is one exception, and only
      # when the operator asked for it; `pinned_origin_head` is the other.
      if fixed = @fixed_host
        head = pinned_origin_head(req)
        head = rewrite_host_header(head, fixed, @fixed_port) if @rewrite_fixed_host
        return {fixed, @fixed_port, @scheme, head}
      end

      target = req.target
      if target.starts_with?("http://") || target.starts_with?("https://")
        uri = URI.parse(target)
        scheme = uri.scheme || "http"
        host = uri.host || ""
        port = uri.port || (scheme == "https" ? 443 : 80)
        {host, port, scheme, rewrite_request_line(req, origin_form(uri))}
      else
        host, port = origin_form_destination(req)
        {host, port, @scheme, req.raw_head}
      end
    end

    # The head a PINNED connection puts on the wire: the client's own bytes, except that an
    # absolute-form request-target is normalised to origin-form exactly as the forward-proxy
    # branch below does it.
    #
    # This branch used to forward `req.raw_head` unconditionally, on a comment asserting that
    # requests here "arrive origin-form". That was true of the two surfaces it was written for —
    # a post-CONNECT tunnel and a reverse listener — and the SOCKS5 listener is the surface
    # where it stopped being true: the client speaks ordinary HTTP/1.1 down a granted tunnel and
    # nothing makes it use origin-form. Two things went wrong and neither needed the pin to
    # fail (the dial stayed pinned throughout, which is the part that held):
    #
    #   * gori MANUFACTURED a proxy-only request line at an origin server. RFC 9112 §3.2.2 has
    #     absolute-form for a request to a proxy; a lenient origin, CDN or gateway routes on the
    #     absolute URI's authority instead, so gori's own forward chose a destination inside a
    #     connection that was supposed to be pinned to one.
    #   * `Url.request_url` prefers the absolute form, so the URL every SCOPE, Sandbox and
    #     History lens read was a completely different authority from the one gori dialled —
    #     `http://evil.example.com/` for a connection pinned to `127.0.0.1:19090`.
    #
    # `Url.absolute_form?` rather than the branch below's `starts_with?("http://")`: RFC 3986
    # §3.1 makes the scheme case-insensitive, and a `HTTP://` target is the same instruction to
    # a lenient recipient.
    private def pinned_origin_head(req : Codec::RawRequest) : Bytes
      return req.raw_head unless Gori::Url.absolute_form?(req.target)
      # `URI::Error`/`OverflowError` here is the malformed-target case `handle_request` already
      # rescues around this whole call — it records the attempt and answers 502 rather than
      # letting it unwind.
      rewrite_request_line(req, origin_form(URI.parse(req.target)))
    end

    # What an ORIGIN-FORM request is ADDRESSED to: the `Host` header, with the kernel's original
    # destination layered over it where there is one (see `origin_dst`). The kernel's port is
    # definitive; its address only fills in for a request that named no host at all — where the
    # dial GOES is a separate question, answered by `dial_pin`.
    private def origin_form_destination(req : Codec::RawRequest) : {String, Int32}
      host, port = Upstream.split_host_port(req.host? || "", @default_port || (@scheme == "https" ? 443 : 80))
      if od = @origin_dst
        host = od[0] if host.empty?
        port = od[1]
      end
      {host, port}
    end

    private def origin_form(uri : URI) : String
      path = uri.path
      path = "/" if path.empty?
      uri.query ? "#{path}?#{uri.query}" : path
    end

    # New request-line + the original header block (everything from the first
    # CRLF onward), so only the request-target changes.
    # Replace the forwarded `Host` header with the pinned origin's authority (see
    # `rewrite_fixed_host`). Every other byte of the head is copied through verbatim, including
    # the request line, the header order, and any oddity in the client's spelling — this
    # rewrites ONE field, it does not normalise a head.
    #
    # Takes the HEAD and not the projection, so it composes on top of `pinned_origin_head`'s
    # request-line normalisation instead of reaching back to `req.raw_head` and undoing it.
    #
    # Only the FIRST Host header is replaced and any later duplicate is dropped: a head with two
    # Host values is a request-smuggling shape, and leaving a second one behind after declaring
    # the origin would hand the origin the ambiguity we were asked to remove. A head with none
    # gains one immediately after the request line (where a client would have put it).
    private def rewrite_host_header(raw : Bytes, host : String, port : Int32) : Bytes
      nl = raw.index(0x0a_u8) || return raw # no LF at all? leave as-is
      default_port = @scheme == "https" ? 443 : 80
      authority = port == default_port ? bracketed(host) : "#{bracketed(host)}:#{port}"
      io = IO::Memory.new(raw.size + authority.bytesize + 16)
      io.write(raw[0, nl + 1]) # request line, verbatim, including its LF
      seen = false
      pos = nl + 1
      while pos < raw.size
        eol = raw[pos..].index(0x0a_u8)
        line_end = eol ? pos + eol + 1 : raw.size
        line = raw[pos, line_end - pos]
        if host_header_line?(line)
          # First one becomes the declared authority; a duplicate is dropped entirely.
          unless seen
            seen = true
            io << "Host: " << authority << "\r\n"
          end
        else
          io.write(line)
        end
        pos = line_end
      end
      return io.to_slice if seen
      # No Host at all (a bare HTTP/1.0 client): insert one rather than forward a head the
      # origin will reject, since we know the authority by declaration.
      out = IO::Memory.new(raw.size + authority.bytesize + 16)
      out.write(raw[0, nl + 1])
      out << "Host: " << authority << "\r\n"
      out.write(raw[(nl + 1)..])
      out.to_slice
    end

    # A header line whose NAME is `Host`. Compared before the colon so a value containing
    # "host:" cannot match, and case-insensitively because the field name is.
    private def host_header_line?(line : Bytes) : Bool
      colon = line.index(0x3a_u8)
      return false unless colon == 4
      String.new(line[0, 4]).compare("Host", case_insensitive: true) == 0
    end

    private def bracketed(host : String) : String
      host.includes?(':') && !host.starts_with?('[') ? "[#{host}]" : host
    end

    private def rewrite_request_line(req : Codec::RawRequest, origin_target : String) : Bytes
      raw = req.raw_head
      nl = raw.index(0x0a_u8) || return raw # no LF at all? leave as-is
      header_block = raw[(nl + 1)..]        # everything after the first CRLF
      io = IO::Memory.new
      io << req.method << ' ' << origin_target << ' ' << req.version << "\r\n"
      io.write(header_block)
      io.to_slice
    end

    # Held bodies are buffered whole (the human may edit them) and forwarded in
    # full, but — like the streaming path — only the capture cap is STORED so an
    # in-scope giant body can't bloat its row. Returns {stored, truncated, size}.
    private def capped(body : Bytes?) : {Bytes?, Bool, Int64?}
      return {nil, false, nil} unless body
      return {body, false, nil} if body.size <= Settings.capture_max
      {body[0, Settings.capture_max].dup, true, body.size.to_i64}
    end

    private def record_error(req, scheme, host, port, created_at, message) : Nil
      flow_id = @sink.on_request(FlowMapper.request(req,
        scheme: scheme, host: host, port: port, created_at: created_at, body: nil, source: FlowSource::Kind::Proxy))
      @sink.on_response(FlowMapper.error_response(flow_id, message))
    end

    # A connection whose bytes are not HTTP (MQTT, AMQP, a raw TLS ClientHello, a binary RPC),
    # recorded as a visible error flow instead of the 30 s silent hang it used to be (#729).
    #
    # THE ERROR STRING IS THE WHOLE ROW. The detector stops on the first non-token octet, so
    # `head` is that one byte (see `non_http_prefix`), and `parse_request_head` over one byte
    # yields `target == ""` and `http_version == ""`; on a cleartext listener `@fixed_host` is
    # nil, so `host` is `""` too. History therefore shows a flow whose columns are empty and
    # whose message carries everything: the octet and the remedy. That is a deliberate trade —
    # reading further to populate the columns is the blocking wait #729 exists to remove — but
    # it is NOT what this comment used to claim ("stores the first line as the target … History
    # shows exactly what arrived"), which was written for a detector that read a whole head.
    private def record_non_http(head : Bytes, created_at : Int64) : Nil
      req = Codec::Http1.parse_request_head(head)
      host = @fixed_host || ""
      record_error(req, @scheme, host, @fixed_port, created_at,
        "not an HTTP request: the connection opened with #{non_http_prefix(head)}, which cannot begin an HTTP request line. #{non_http_remedy(host)}")
    end

    # A connection that was accepted, sent ZERO bytes, and was closed when the read timed out
    # (#755). The server-speaks-first case #729 left open: SMTP, IMAP, POP3, MySQL and friends
    # have the SERVER greet, so their client connects and waits for a banner gori's HTTP proxy
    # never sends. There is nothing to classify — `record_non_http` needs a byte and this
    # connection produced none — so the SILENCE is the whole defect: the `IO::TimeoutError`
    # unwound to `run`'s blanket rescue and no flow, no log and no chip said a connection had
    # opened at all.
    #
    # ## Why this predicate and not the timeout
    #
    # The timeout stays. A legitimately slow client is indistinguishable from a silent one, and
    # shortening the wait weakens the slowloris bound it exists for. What is narrowed instead is
    # what gets RECORDED, along two axes, because "a head read timed out" on its own is the
    # normal end of a healthy connection and a flow for each would be noise:
    #
    #   - ZERO bytes (`HeadTimeout#received`). A partial head that stalled is a slow or
    #     slowloris HTTP client; a flow per connection there would amplify the attack.
    #   - on a connection that never carried a request (`@saw_request`). After one has been
    #     served, the same zero-byte timeout is an idle keep-alive reaching its end.
    #
    # One shape does survive both filters innocently, and it is named in the message rather than
    # filtered out because it cannot be: a speculative preconnect — a browser opening a
    # connection ahead of a request it never makes — is byte-for-byte this. `tls/tunnel.cr`
    # already names it as an ordinary trigger of the same shape one layer down.
    #
    # Like `record_non_http`, THE ERROR STRING IS THE WHOLE ROW: there is no request, so
    # `parse_request_head` over zero bytes gives empty method/target/version. Inside a tunnel
    # `@fixed_host`/`@fixed_port` still name the origin the client asked for, which is the case
    # that matters — on a cleartext listener not even the host is known.
    private def record_silent_client : Nil
      ClientConn.record_silent_client(@sink, @scheme, @fixed_host || "", @fixed_port,
        client_tls: @client_tls)
    end

    # The same record, addressable WITHOUT a ClientConn — because on three listeners there isn't
    # one yet when this shape happens. `Server#serve_reverse`, `#serve_transparent` and
    # `#serve_socks5` route on `client.peek`, which blocks BEFORE any `ClientConn` is constructed,
    # so a peer that connects and says nothing times out there and never reaches
    # `read_client_head`. Those are also the only listeners a plaintext server-speaks-first
    # protocol can arrive on at all — SMTP/IMAP cannot traverse a forward proxy without CONNECT — so leaving them out would have put the
    # fix everywhere except where it is needed (#729 says the transparent listener "matters more
    # here than anywhere else"). One method, so the sentence cannot fork.
    # `opened` replaces the first clause for a caller whose client did NOT arrive in silence. The
    # SOCKS5 listener is the one: its peer completed a whole handshake — version, method list, a
    # CONNECT that gori gated and granted — before going quiet, so "opened this connection, sent
    # zero bytes" described a client that never connected and sent the operator looking for one.
    # The rest of the sentence is the same fact and stays one spelling.
    def self.record_silent_client(sink : FlowSink, scheme : String, host : String, port : Int32,
                                  *, client_tls : Bool, opened : String? = nil) : Nil
      flow_id = sink.on_request(FlowMapper.request(Codec::Http1.parse_request_head(Bytes.new(0)),
        scheme: scheme, host: host, port: port, created_at: now_us, body: nil, source: FlowSource::Kind::Proxy))
      sink.on_response(FlowMapper.error_response(flow_id,
        "no request: the client #{opened || "opened this connection, sent zero bytes"}, and was " \
        "closed when the " \
        "#{SocketTuning::CLIENT_IO_TIMEOUT.total_seconds.to_i} s client read timeout expired. A " \
        "SERVER-SPEAKS-FIRST protocol makes exactly this shape — SMTP, IMAP, POP3, MySQL and " \
        "friends have the SERVER greet first, so the client is waiting for a banner an HTTP proxy " \
        "never sends. #{non_http_remedy(host, client_tls)}. Harmless alternative: a speculative " \
        "preconnect, a connection a browser opened ahead of a request it never made, looks " \
        "identical and needs nothing done about it"))
    end

    # A `CONNECT` sent to a listener whose destination was already settled. Answered 403 — not
    # 502, which would read as "the origin is down", and not a dropped connection, which would
    # read as gori being broken — and recorded, because a client doing this is either misconfigured
    # or probing, and both are worth seeing.
    private def refuse_connect_on_pinned(req : Codec::RawRequest, fixed : String,
                                         host : String, port : Int32) : Bool
      message = "CONNECT refused: this listener serves a fixed destination " \
                "(#{Gori::BindAddress.authority(fixed, @fixed_port)}) and is not a forward proxy, " \
                "so it will not open a tunnel to #{Gori::BindAddress.authority(host, port)}. " \
                "Point the client at gori's proxy listener if it needs one"
      ::Log.warn { message }
      record_error(req, @scheme, host, port, now_us, message)
      @io.write("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_slice)
      @io.flush rescue nil
      false
    end

    # A connection a LISTENER refused before any request existed, on the record. Same shape and
    # the same reason as `record_silent_client` above: the refusal is a fact about a client that
    # tried to use gori, and `gori.log` is where an operator does not look. `host`/`port` are
    # whatever the refusal knew — empty and 0 when it was refused before naming a destination.
    def self.record_listener_refusal(sink : FlowSink, host : String, port : Int32,
                                     message : String) : Nil
      flow_id = sink.on_request(FlowMapper.request(Codec::Http1.parse_request_head(Bytes.new(0)),
        scheme: "http", host: host, port: port, created_at: now_us, body: nil,
        source: FlowSource::Kind::Proxy))
      sink.on_response(FlowMapper.error_response(flow_id, message))
    end

    # The remedy sentence shared by the two ways a connection can turn out not to be HTTP — bytes
    # that cannot start a request line (#729) and no bytes at all (#755).
    #
    # Keyed on `@client_tls`, the caller's claim about THIS connection's transport, and not on
    # `@tls`, which is what this used to ask and got exactly backwards: `@tls` is the CONNECT MITM
    # seam, passed only by the cleartext forward-proxy listener, so the "gori terminated TLS on
    # this connection" wording went to plaintext :8080 clients while the decrypted tunnel — the
    # one path where `network.tls_passthrough` really is the remedy — was told "this listener
    # expects HTTP". See the constructor.
    private def non_http_remedy(host : String) : String
      ClientConn.non_http_remedy(host, @client_tls)
    end

    # :ditto: — the form a LISTENER can reach, for `self.record_silent_client` above.
    def self.non_http_remedy(host : String, client_tls : Bool) : String
      if client_tls
        "gori terminated TLS on this connection and speaks HTTP to it — if #{host.empty? ? "this host" : host.inspect} " \
        "speaks a non-HTTP protocol, add it to `network.tls_passthrough` so gori tunnels it byte-exact instead of decoding it"
      else
        "this listener expects HTTP — a non-HTTP service should not be routed through gori's " \
        "HTTP proxy (use `network.tls_passthrough` for a TLS service, or keep gori off this port)"
      end
    end

    # A short, terminal-safe rendering of what gori actually saw, for the flow's error message.
    # Hex always; the ASCII gloss only when there is text in it to read. Never emits a raw
    # control byte.
    #
    # ONE BYTE is the normal case, and the message has to read well for it. `read_head`'s
    # detector decides on the FIRST non-blank octet and breaks THERE — not waiting for more is
    # the whole point of #729 — so from THAT caller `head` is any permitted empty line(s) plus
    # that one octet, and by construction it is a CTL/SP/DEL (`looks_like_http_request?`). There
    # is no `MQTT` or `SSH-2.0` string to show: those live at bytes 4-8 and 0-7 of a message it
    # never reads, and an SSH banner is not detected on the cleartext path at all (`S` is a
    # method-token char — the known gap #729 records). A gloss of `"."` would say nothing there.
    #
    # But `refuse_non_tls_connect` DOES hand over a printable single byte — that same `S`, or the
    # `G` of a `curl --proxytunnel` GET — so the gloss is decided by whether the bytes are
    # printable, never by how many there are. See the printable test below.
    #
    # More than one byte reaches this from two callers: the deadline-less fast path
    # (`SocketTuning.underlying_socket` nil ⇒ no detector), where `head` is whatever the client
    # finished sending, and `refuse_non_tls_connect`, which hands over the two bytes a TLS
    # ClientHello is judged on — hence the cap and the ASCII half are kept rather than deleted.
    private def non_http_prefix(head : Bytes, limit : Int32 = 12) : String
      slice = head[0, {head.size, limit}.min]
      hex = slice.map { |b| "0x#{b.to_s(16).rjust(2, '0')}" }.join(' ')
      more = head.size > limit ? " …" : ""
      noun = slice.size == 1 ? "the byte" : "the bytes"
      # The PRINTABLE test decides the gloss, and the arity only picks the noun. It used to be the
      # other way round, which was right for the one caller that existed: `record_non_http`'s byte
      # is a CTL/SP/DEL by construction, so a one-byte gloss would have read `"."` and said
      # nothing. `refuse_non_tls_connect` broke that invariant — `0x53` for SSH, `0x47` for
      # `curl --proxytunnel` — and those are exactly the bytes an operator should not have to
      # look up in an ASCII table (#755).
      return "#{noun} #{hex}#{more}" if slice.none? { |b| b >= 0x20_u8 && b < 0x7f_u8 }
      ascii = String.build do |s|
        slice.each { |b| s << (b >= 0x20_u8 && b < 0x7f_u8 ? b.unsafe_chr : '.') }
      end
      "#{noun} #{hex}#{more} (#{ascii.inspect})"
    end

    # A dropped request never reaches upstream; record it as an Aborted flow so
    # the human sees the attempt + decision (P4/P7).
    private def record_dropped_request(req, scheme, host, port, created_at, body) : Nil
      stored, trunc, size = capped(body)
      flow_id = @sink.on_request(FlowMapper.request(req,
        scheme: scheme, host: host, port: port, created_at: created_at,
        body: stored, body_truncated: trunc, body_size: size, source: FlowSource::Kind::Proxy))
      @sink.on_response(FlowMapper.aborted_response(flow_id, "dropped by intercept (request)"))
    end

    private def write_intercept_drop : Nil
      @io.write("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nX-Gori-Intercept: dropped\r\n\r\n".to_slice)
      @io.flush
    rescue
    end

    # A request the sandbox refused never reaches upstream; record it as an Aborted flow
    # (like an intercept drop) so the operator still sees the blocked attempt (P4/P7). Body
    # is nil — we block before reading it and close the connection right after.
    private def record_blocked_request(req, scheme, host, port, created_at) : Nil
      flow_id = @sink.on_request(FlowMapper.request(req,
        scheme: scheme, host: host, port: port, created_at: created_at, body: nil, source: FlowSource::Kind::Proxy))
      @sink.on_response(FlowMapper.aborted_response(flow_id, Gori::Outbound::SANDBOX_ERROR))
    end

    # Tell the client the sandbox refused this request — a distinct 403 + marker header so a
    # blocked flow reads differently from an upstream 502. The caller returns false, so @io
    # closes right after: no keep-alive on a blocked connection.
    private def write_sandbox_block : Nil
      @io.write("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\nX-Gori-Sandbox: blocked\r\n\r\n".to_slice)
      @io.flush
    rescue
    end

    # Answer a request whose framing gori refused to forward (CL+TE, non-final
    # chunked, obfuscated framing header, bad Content-Length). Self-framed and
    # `Connection: close`, because the body boundary is exactly what we could not
    # determine — whatever remains in the socket is unread on purpose.
    #
    # `reason` is one of `Codec::Body`'s static literals today, but a CR/LF reaching
    # a header value would turn gori's own diagnostic into the response split it is
    # refusing, so it is scrubbed at the boundary rather than trusted upstream.
    private def write_framing_reject(reason : String) : Nil
      safe = reason.gsub(/[\r\n]+/, " ").strip
      safe = "ambiguous request framing" if safe.empty?
      body = "gori refused to forward this request: #{safe}\n"
      @io.write(String.build do |s|
        s << "HTTP/1.1 400 Bad Request\r\n"
        s << "Content-Type: text/plain; charset=utf-8\r\n"
        s << "Content-Length: " << body.bytesize << "\r\n"
        s << "Connection: close\r\n"
        s << "X-Gori-Error: request-framing\r\n\r\n"
        s << body
      end.to_slice)
      @io.flush
    rescue
    end

    # Concatenate a head and optional body into one contiguous message buffer.
    private def build_message(head : Bytes, body : Bytes?) : Bytes
      return head if body.nil? || body.empty?
      io = IO::Memory.new(head.size + body.size)
      io.write(head)
      io.write(body)
      io.to_slice
    end

    # Split a forwarded message back into head (through CRLFCRLF) + body remainder.
    private def split_message(raw : Bytes) : {Bytes, Bytes?}
      idx = index_crlf_crlf(raw)
      return {raw, nil} unless idx
      head_end = idx + 4
      body = head_end < raw.size ? raw[head_end..].dup : nil
      {raw[0, head_end].dup, body}
    end

    private def index_crlf_crlf(raw : Bytes) : Int32?
      i = 0
      while i + 3 < raw.size
        return i if raw[i] == 0x0d_u8 && raw[i + 1] == 0x0a_u8 && raw[i + 2] == 0x0d_u8 && raw[i + 3] == 0x0a_u8
        i += 1
      end
      nil
    end

    # Ceiling on a body Match&Replace will buffer to rewrite. A body rule can't stream —
    # it must hold the whole entity to gsub + re-frame (Content-Length), and rewriting
    # allocates a few more full copies (dechunk, String round-trip, gsub). Left uncapped,
    # one large download/upload with a body rule live would grow the proxy heap without
    # bound (a per-connection OOM). Above this size the rule no-ops and the body is
    # forwarded byte-exact, exactly as it already does for SSE / compressed / 101 bodies —
    # correctness costs nothing but the rule not applying to a body too big to safely hold.
    # Only gates KNOWN-length (Content-Length) bodies; a chunked body has no declared size
    # to check here and still buffers (bounded only by the peer) — capping that streams a
    # follow-up.
    #
    # The intercept HOLD shares it (`holdable_body_size?`): it buffers a whole entity for the
    # same reason and with the same consequence if it is not bounded.
    MAX_REWRITE_BODY = 16 * 1024 * 1024 # 16 MiB

    # Whether a body of this framing/declared-length is small enough to buffer + rewrite.
    # Chunked/unknown-length has no size to gate on, so it isn't blocked here.
    private def rewritable_body_size?(framing : Codec::BodyFraming, len : Int64) : Bool
      !framing.length? || len <= MAX_REWRITE_BODY
    end

    # Whether an intercept HOLD may buffer a body of this framing/declared-length. A hold reads
    # the whole entity up front so the human can see and edit it (`Codec::Body.read_complete`,
    # no `max_bytes`), so without this a multi-GB declared upload/download grows the proxy heap
    # by its whole size — and does it BEFORE `@sink.on_request`, so the eventual raise loses the
    # flow from History entirely. Past the ceiling the hold FAILS OPEN: the message is not held
    # and takes the existing zero-buffer streaming path byte-exact (P6/P7). That is the same
    # disposition the h2 half of this feature already has (`H2::StreamGate#fail_open` past
    # `MAX_DEFERRED_BYTES`), and it is the right one — capping the READ instead would truncate
    # the very upload the operator wanted to edit. Reuses the M&R ceiling rather than inventing
    # a second one: both answer "is this entity small enough to hold in memory?".
    #
    # Only KNOWN-length bodies are gated, exactly as `MAX_REWRITE_BODY` documents — a chunked
    # body declares no size here and still buffers.
    private def holdable_body_size?(framing : Codec::BodyFraming, len : Int64, direction : String) : Bool
      return true if rewritable_body_size?(framing, len)
      warn_hold_oversize(direction, len)
      false
    end

    # Once per connection. Intercept is ON and this message never appeared in the queue, so the
    # operator has to be told why rather than left waiting on a hold that will not come
    # (modelled on `H2::StreamGate#warn_overflow`, which says the same thing for h2).
    private def warn_hold_oversize(direction : String, len : Int64) : Nil
      return if @warned_hold_oversize
      @warned_hold_oversize = true
      ::Log.warn do
        "intercept: #{direction} body declares #{len} bytes, over the #{MAX_REWRITE_BODY}-byte " \
        "hold ceiling — forwarding it unheld"
      end
    end

    # Whether the buffered response-body path applies: SOMETHING needs the whole entity, the
    # body is bounded (Length/chunked, not SSE / close-delimited / 101), and it is small enough
    # to buffer. Extracted from handle_response so the dispatch stays flat (it just tests +
    # branches).
    #
    # Two things can need it, and neither pays anything when it is not configured: a
    # Match&Replace body rule (which rewrites the entity) and a body-scoped extract rule
    # (which reads it). Both predicates are lock-free atomic counts, so the overwhelmingly
    # common no-rule response is one integer compare away from the streaming path (P6).
    private def buffer_response_body?(resp : Codec::RawResponse,
                                      framing : Codec::BodyFraming, len : Int64) : Bool
      return false unless @rewriter.try(&.rewrites_response_body?) ||
                          @extractor.try(&.extracts_body?)
      (framing.length? || framing.chunked?) && !sse?(resp) && resp.status != 101 &&
        rewritable_body_size?(framing, len)
    end

    # --- session-binding extraction (#501 slice 2) ----------------------------

    # What an extract rule's condition needs to know about an exchange. A response carries
    # neither a method nor a target, so both come from the request that was actually SENT
    # (post-rewrite, post-edit) — the same source the intercept response gate reads.
    private record ExtractRef,
      method : String,
      host : String,
      target : String,
      scheme : String,
      status : Int32,
      flow_id : Int64?

    # Built once per response, and only when an extract rule is live: `extracts?` is a lock-free
    # atomic read, so a proxy with no extract rule allocates nothing here.
    private def extract_ref_for(sent_req : Codec::RawRequest, host : String, scheme : String,
                                status : Int32, flow_id : Int64) : ExtractRef?
      ex = @extractor
      return nil unless ex && ex.extracts?
      ExtractRef.new(sent_req.method, host, sent_req.target, scheme, status, flow_id)
    end

    # Offer the bytes the client actually received to the extract rules. Called AFTER the head
    # (and body, where there is one) has been written and flushed — see `Proxy::ResponseExtract`
    # for why the delivered bytes and not the arrived ones.
    #
    # `status` overrides the ref's when the delivered head is not the one the ref was built
    # from: a body rewrite re-frames the head, and an intercept edit can change the status
    # outright. Everything else about the exchange is the request's and cannot move.
    private def observe_delivered(ref : ExtractRef?, head : Bytes, entity : Bytes?,
                                  status : Int32? = nil) : Nil
      return unless ref
      @extractor.try(&.observe_response(head, entity,
        method: ref.method, host: ref.host, target: ref.target, scheme: ref.scheme,
        status: status || ref.status, flow_id: ref.flow_id))
    end

    # Whether the request-body Match&Replace path applies: a body rule is live, there IS a
    # body, and it's small enough to buffer. Extracted from handle_request (see above).
    private def rewrite_request_body?(rw : HeadRewriter, framing : Codec::BodyFraming, len : Int64) : Bool
      rw.rewrites_request_body? && !framing.none? && rewritable_body_size?(framing, len)
    end

    # Apply a body Match&Replace to a buffered wire body and return {head, forward_body}.
    # `wire_body` is the on-the-wire form (chunk framing preserved for chunked bodies);
    # it is de-chunked to the entity before matching. `yield entity` runs the rule engine
    # (rewrite_request_body / rewrite_response_body), which returns the SAME bytes when
    # nothing matched. On no change we return the ORIGINAL head + wire body byte-exact
    # (P7) — so an unmatched flow is never re-framed. On a change we re-frame the head to
    # Content-Length (the new entity length, Transfer-Encoding dropped) and forward the
    # rewritten entity.
    #
    # A real (non-identity) Content-Encoding is refused BEFORE the rule ever sees the
    # entity: gzip/br/deflate/zstd are never inflated on this wire path (only for
    # DISPLAY — see `ContentDecode`), so a literal/regex match runs against opaque
    # compressed bytes. A short or common pattern (a single byte is enough) can
    # incidentally match INSIDE the compressed stream purely by chance and corrupt it —
    # silently: no error, no advisory, Content-Length still recalculated to look
    # consistent. Refusing keeps the response byte-exact (P7) instead of guessing wrong.
    # Since #740 a TRANSFER compression layer is refused on the same terms.
    #
    # The refusal is correct and it used to be MUTE, which was not (#745) — hence the third
    # element: the advisory the caller records on the flow, non-nil only where a body rule
    # really did lose its chance. See `compressed_skip_advisory`.
    #
    # `live` is the caller's own answer to "is a body rule live for this direction" — three of
    # the four call sites gate on exactly that before entering, and the fourth (a body-scoped
    # EXTRACT rule brings a response down this path with no rewrite rule at all, #501 slice 2)
    # knows it inside its block. Asking the rewriter again here would either duplicate that
    # test or, on that fourth path, get the wrong answer.
    #
    # The two returned halves are always FRAMED CONSISTENTLY with each other, and #501's
    # extract observer depends on that: it is handed the same pair and lets
    # `ContentDecode.decode` do the de-chunk + inflate, so it must never be given a de-chunked
    # body alongside a head that still declares `Transfer-Encoding: chunked`.
    private def apply_body_rewrite(head : Bytes, wire_body : Bytes?, framing : Codec::BodyFraming, *,
                                   host : String, response : Bool, live : Bool,
                                   & : Bytes -> Bytes) : {Bytes, Bytes?, String?}
      return {head, wire_body, nil} if wire_body.nil? || wire_body.empty?
      if Codec::ContentDecode.content_encoded?(head)
        return {head, wire_body, compressed_skip_advisory(head, host, response: response, live: live)}
      end
      entity = framing.chunked? ? Codec::ContentDecode.dechunk(wire_body) : wire_body
      rewritten = yield entity
      return {head, wire_body, nil} if rewritten == entity # nothing matched → byte-exact (P7)
      {reframe_to_length(head, rewritten.size), rewritten, nil}
    end

    # What to record on the flow when the gate above refused a compressed body, or nil when
    # there is nothing to say (#745).
    #
    # NOTHING TO SAY is the common case and the important one. A compressed response is most of
    # the web; a rule that was never going to touch this message did not lose anything, and an
    # advisory on every gzip flow would be noise the operator learns to scroll past. So two
    # conditions, and both are required:
    #
    #   - a body rule is LIVE for this direction — the caller's `live`, above;
    #   - a body rule MATCHES THIS HOST — `rewrites_body_for_host?`, the host-narrowed
    #     predicate #526 added for the h2 downgrade gate. Without it a rule scoped to
    #     `alpha.test` would annotate every compressed flow on every other host with a claim
    #     that it failed to fire there.
    #
    # That predicate folds the two directions into one question (it was written for a gate that
    # downgrades for either), so the pair can be satisfied by a REQUEST-side rule matching this
    # host while the live RESPONSE-side rule is scoped elsewhere. The sentence stays true under
    # that reading — a body rule matching this host did not run on this body — and the
    # alternative is a second host-scoped predicate per direction for a case that needs two
    # rules pointing in opposite directions to occur at all.
    #
    # It takes the rewriter's lock (once per refused body, never on the fast path): reached only
    # with a body rule live somewhere AND a compressed body in hand, which is the same bargain
    # `H2::HeadRewrite#notice_live_rule` makes per head.
    private def compressed_skip_advisory(head : Bytes, host : String, *,
                                         response : Bool, live : Bool) : String?
      return nil unless live
      return nil unless @rewriter.try(&.rewrites_body_for_host?(host))
      side = response ? "response" : "request"
      codings = Codec::ContentDecode.declared_codings(head)
      # `content_encoded?` also fails closed on an obs-folded encoding header, where the coding
      # is precisely what cannot be read — say that rather than name nothing.
      named = codings.empty? ? "an encoding header gori could not read (obs-folded)" : codings.join(", ")
      log_compressed_skip(side, host, named)
      "Match&Replace was NOT applied to this #{side} body: it arrived compressed (#{named}) and " \
      "gori never decompresses on the wire path, so a pattern would have run against the " \
      "compressed bytes and could have matched inside the stream by coincidence. The #{side} " \
      "was forwarded byte-exact; a Match&Replace BODY rule matching this host did not fire on " \
      "it. Read the decoded body in History (gori decompresses for DISPLAY), or have the " \
      "origin answer uncompressed (drop the request's Accept-Encoding with a head rule)."
    end

    # The same refusal in `gori.log`, LATCHED — the advisory above is per flow, which is the
    # right rate for "did my rule run on THIS response?", but one line per response would put
    # dozens of identical entries in the log for one page load.
    #
    # Keyed on {direction, host, coding} rather than on the connection alone, because a
    # connection is not one host: a cleartext forward-proxy `ClientConn` serves whatever hosts
    # the client's keep-alive requests name, and latching per connection would let the first
    # host silence every other. The coding is in the key for the same reason it is in the
    # message — `br` and `gzip` on one host are different facts (an operator may have turned one
    # off at the origin and not the other). Bounded by `COMPRESSED_SKIP_LOG_CAP`: a hostile
    # client cycling hosts must not grow this set for the life of the connection.
    private def log_compressed_skip(side : String, host : String, named : String) : Nil
      key = "#{side}\t#{host}\t#{named}"
      return if @compressed_skips.includes?(key) || @compressed_skips.size >= COMPRESSED_SKIP_LOG_CAP
      @compressed_skips << key
      ::Log.warn do
        "Match&Replace: a BODY rule matching #{host.inspect} was not applied to a #{side} body " \
        "compressed with #{named} — gori does not decompress on the wire path, so the #{side} " \
        "went through byte-exact. Said once per {direction, host, coding} on this connection; " \
        "every affected flow carries the same statement in History."
      end
    end

    # Rebuild a message head framed as `Content-Length: len`: drop any Transfer-Encoding
    # and Content-Length header (a rewritten body invalidates both), append the fresh
    # Content-Length, and keep every other header verbatim in order. Preserves the head's
    # own line ending (CRLF or bare LF) so the re-parsed head stays well-formed.
    private def reframe_to_length(head : Bytes, len : Int32) : Bytes
      text = String.new(head)
      eol = text.index("\r\n") ? "\r\n" : "\n"
      section = text.split(eol + eol, 2).first # headers up to the blank line
      lines = section.split(eol)
      io = IO::Memory.new(head.size + 32)
      io << lines.first << eol # request / status line, untouched
      lines[1..].each do |line|
        next if header_line_named?(line, "transfer-encoding") || header_line_named?(line, "content-length")
        io << line << eol
      end
      io << "Content-Length: " << len << eol << eol
      io.to_slice
    end

    # Force `sent_head`'s body-framing headers (Content-Length / Transfer-Encoding) to match
    # `orig_head`'s. A head-only Match&Replace rewrite streams the body UNTOUCHED (P6), so the
    # bytes forwarded are framed by the ORIGINAL head; if the rewrite changed CL/TE, the wire
    # head would then declare a different body length than gori actually forwards — a
    # self-inflicted request smuggle / response split (#403). The body-rewrite path already
    # re-frames to the real length (reframe_to_length); this is the head-only counterpart:
    # restore the original framing headers (in their original relative order) while keeping
    # every other rewrite. A no-op — returning `sent_head` byte-for-byte (P7) — when the
    # rewrite left CL/TE alone, which is the overwhelmingly common case.
    private def restore_framing_headers(sent_head : Bytes, orig_head : Bytes) : Bytes
      orig_framing = framing_header_lines(orig_head)
      sent_framing = framing_header_lines(sent_head)
      return sent_head if orig_framing == sent_framing # rewrite didn't touch framing → byte-exact

      text = String.new(sent_head)
      eol = text.index("\r\n") ? "\r\n" : "\n"
      section = text.split(eol + eol, 2).first # headers up to the blank line
      lines = section.split(eol)
      io = IO::Memory.new(sent_head.size + 32)
      io << lines.first << eol # request / status line, untouched
      lines[1..].each do |line|
        next if header_line_named?(line, "transfer-encoding") || header_line_named?(line, "content-length")
        io << line << eol
      end
      orig_framing.each { |line| io << line << eol } # the framing that matches the streamed body
      io << eol
      io.to_slice
    end

    # The Content-Length / Transfer-Encoding header lines of a head, in order — the ones that
    # decide the body boundary. Compared verbatim so an untouched rewrite stays byte-exact.
    private def framing_header_lines(head : Bytes) : Array(String)
      text = String.new(head)
      eol = text.index("\r\n") ? "\r\n" : "\n"
      section = text.split(eol + eol, 2).first
      section.split(eol)[1..]?.try(&.select { |line|
        header_line_named?(line, "content-length") || header_line_named?(line, "transfer-encoding")
      }) || [] of String
    end

    # True when a header line's field-name (case-insensitive, ignoring leading space) is
    # `name`. The request/status line has no ':' before its first space-token, so it never
    # matches a header name here.
    private def header_line_named?(line : String, name : String) : Bool
      colon = line.index(':')
      return false unless colon && colon > 0
      line[0...colon].strip.downcase == name
    end

    # Is this response an event stream? `Sse.sse?` and not a `downcase.includes?` scan, which
    # is the brittle test that module's own header says it exists to replace — and which every
    # OTHER surface had already left behind: `Proto.classify` asks `Sse.sse?`, `QL` compiles
    # `proto:sse` to `LIKE 'text/event-stream%'`, and History's EVENTS pane asks
    # `Sse.event_stream?`. A substring match makes this the only reader that says yes to a
    # `Content-Type` merely CARRYING the token in a parameter — and this is the reader with
    # side effects: `application/json; profile="urn:x:text/event-stream"` on a Content-Length
    # body took the streaming path, so the intercept response hold was skipped, a Match&Replace
    # body rule no-opped, and the client connection was closed instead of kept alive, while
    # every display and query surface reported an ordinary JSON flow.
    private def sse?(resp : Codec::RawResponse) : Bool
      Gori::Sse.sse?(resp.headers.get?("Content-Type"))
    end

    private def write_gateway_error : Nil
      @io.write("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n".to_slice)
      @io.flush
    rescue
    end

    private def get_or_head?(req : Codec::RawRequest) : Bool
      req.method.compare("GET", case_insensitive: true) == 0 ||
        req.method.compare("HEAD", case_insensitive: true) == 0
    end

    # Serve the welcome + CA-download page (see the two guards in handle_request: a direct
    # hit on the listener, or a request for the reserved host).
    # The CA bytes/fingerprint/path come through the TlsMitm seam so this stays decoupled
    # from the FFI cert code; a HEAD request gets headers only. Best-effort — a write error
    # just drops the connection like every other canned response here.
    private def serve_self_page(req : Codec::RawRequest, tls : TlsMitm, self_addr : {String, Int32}) : Nil
      @io.write(tls.self_page_reply(req.method, req.target, listen_display(self_addr)))
      @io.flush
    rescue
    end

    # The address to PRINT on the page: the concrete one the device actually reached us on
    # rather than a wildcard "0.0.0.0" — under a wildcard bind that's the friendlier,
    # truthful value.
    private def listen_display(self_addr : {String, Int32}) : {String, Int32}
      (lh = @local_host) ? {lh, self_addr[1]} : self_addr
    end

    private def keep_alive?(req : Codec::RawRequest, resp : Codec::RawResponse,
                            resp_framing : Codec::BodyFraming) : Bool
      return false if resp_framing.close_delimited? # body ends at close
      return false if connection_lists?(req.headers.get?("Connection"), "close")
      return false if connection_lists?(resp.headers.get?("Connection"), "close")
      req.version == "HTTP/1.1" || connection_lists?(req.headers.get?("Connection"), "keep-alive")
    end

    # Whether the ORIGIN will keep its connection open after this response, so its
    # upstream socket may be parked for the next request. Distinct from
    # `keep_alive?` (the CLIENT side, keyed on the request): persistence here is
    # the RESPONSE's — HTTP/1.1 persists unless `Connection: close`; HTTP/1.0 only
    # with explicit `Connection: keep-alive`. A close-delimited body, or a
    # `Connection: close` on the request we forwarded upstream OR on the response,
    # all mean the origin closes. Parking a connection the origin will close just
    # wastes one stale-retry on the next request, so err toward NOT reusing.
    # `sent_req` is the request ACTUALLY forwarded upstream (post Match&Replace /
    # intercept edit), not the client's original — a rule that adds `Connection: close`
    # to the upstream request means the origin closes, even if the client's request didn't.
    private def origin_keep_alive?(sent_req : Codec::RawRequest, resp : Codec::RawResponse,
                                   resp_framing : Codec::BodyFraming) : Bool
      return false if resp_framing.close_delimited?
      return false if connection_lists?(sent_req.headers.get?("Connection"), "close")
      return false if connection_lists?(resp.headers.get?("Connection"), "close")
      resp.version == "HTTP/1.1" || connection_lists?(resp.headers.get?("Connection"), "keep-alive")
    end

    # Whether a request may be transparently REPLAYED on a fresh connection after a
    # stale-reuse failure. Only SAFE methods (RFC 7231 §4.2.1: GET/HEAD/OPTIONS/
    # TRACE — no side effects, idempotent) with NO body qualify: repeater is then
    # harmless even if the origin had already processed the first attempt. A
    # mutating method (POST/PUT/PATCH/DELETE), even body-less, is never auto-resent
    # — a wire-inspection proxy must not silently double-submit; the request fails
    # and the client decides. A body request can't be replayed anyway (the bytes
    # were streamed from the client and not retained).
    private def retryable_request?(req : Codec::RawRequest, body_less : Bool) : Bool
      return false unless body_less
      case req.method.upcase
      when "GET", "HEAD", "OPTIONS", "TRACE" then true
      else                                        false
      end
    end

    # Presize hint for a body capture: a Content-Length body's length is known, so the
    # store is sized once. Chunked/close-delimited length is 0 (unknown → grow on demand);
    # a bodyless framing keeps the capture unallocated.
    private def capture_hint(framing : Codec::BodyFraming, length : Int64) : Int64
      framing.length? ? length : 0_i64
    end

    # True when a Connection header field lists `token` (case-insensitive) as one of its
    # comma-separated connection-options — e.g. `Connection: keep-alive, close` carries BOTH
    # `keep-alive` and `close`. Comparing the whole value (the old header_token) missed a
    # token embedded in such a list, so a peer signalling close would be parked as persistent.
    private def connection_lists?(value : String?, token : String) : Bool
      return false unless value
      value.downcase.split(',').any? { |t| t.strip == token }
    end

    private def now_us : Int64
      ClientConn.now_us
    end

    # :ditto: — reachable from `self.record_silent_client`, which has no instance.
    def self.now_us : Int64
      (Time.utc - Time::UNIX_EPOCH).total_microseconds.to_i64
    end
  end
end
