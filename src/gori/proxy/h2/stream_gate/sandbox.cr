# The h2 sandbox: the BLOCKING gate in front of one direction's writer, and the refused-stream
# set that keeps a refusal in force for the rest of the connection — reopens
# `Gori::Proxy::H2::StreamGate` (see `proxy/h2/stream_gate.cr` for the class, its state, and the
# `*_locked` lock invariant every method here is bound by).
#
# Everything in this file FAILS CLOSED, which is what separates it from the intercept hold in the
# same class: where the hold gives up and forwards (`fail_open`, `release_all`, the #123 reaper,
# `MAX_DEFERRED_BYTES`), a gate that can no longer tell which streams must not reach the far end
# ends the connection instead of guessing. The class header's "Three things about it are NOT the
# intercept hold's shape" is the long version. Do not symmetrize the two.
class Gori::Proxy::H2::StreamGate
  # Ceiling on the refused-stream set (see `@refused`). The set is the only thing standing
  # between a refused request's later DATA and the origin, so past the ceiling the CONNECTION
  # goes — not the memory bound, and not the guarantee. Generous on purpose: it is per
  # connection and only refusals count, so reaching it means thousands of refused streams on
  # one connection, i.e. a client that has ignored thousands of RST_STREAMs.
  MAX_REFUSED_STREAMS = 4096

  # The URL test both refusal gates below make, and the only place the stream's own
  # `:authority` and the connection's host are reconciled. Returns the blocked request's
  # `{scheme, host, target}` — the promise gate needs them for its log line — or nil when the
  # sandbox allows it.
  #
  # ## Why two URLs are tested, not one
  #
  # h1 inside a tunnel tests `scheme://<CONNECT host><target>`: `resolve_forward`
  # short-circuits on the pinned host, so the name in the request and the socket's
  # destination cannot disagree. On h2 they can. RFC 9113 §9.1.1 lets a client REUSE one
  # connection for any origin the certificate covers, so a single relay carries streams whose
  # `:authority` is not the CONNECT host — which is exactly why the head pipeline already
  # scopes rules and holds on the stream's own authority (`head_rewrite.cr`).
  #
  # For a blocking gate, choosing one of the two names is choosing which half to leak. Take a
  # scope of `https://acme.test/*` — a URL rule, so `sandbox_blocks_host?` lets EVERY host
  # past the CONNECT gate and every per-request decision is this one:
  #
  #   * authority only would pass a stream claiming `:authority: acme.test` on a connection
  #     to `evil.test`, i.e. the request goes to a host the scope never allowed.
  #   * connection host only would pass a coalesced stream to `evil.test` riding an
  #     `acme.test` connection, because the URL it tested was the connection's, not the
  #     request's.
  #
  # So both are tested and either refusal is a refusal. On an ordinary connection the two
  # names are equal and the second test is skipped, so the common path costs one evaluation.
  private def sandbox_blocked_url(block : HeadRewrite::Block) : {String, String, String}?
    fields = block.fields
    authority = HeadCodec.pseudo_of(fields, ":authority") || @host
    host, _ = Upstream.split_host_port(authority, @port)
    scheme = HeadCodec.pseudo_of(fields, ":scheme") || "https"
    target = HeadCodec.pseudo_of(fields, ":path") || "/"
    blocked = @interceptor.sandbox_blocks?(scheme, host, target) ||
              (host != @host && @interceptor.sandbox_blocks?(scheme, @host, target))
    blocked ? {scheme, host, target} : nil
  end

  # The hard containment gate, per stream (#492 step 4). True when this head was REFUSED —
  # its frames are then accounted for and nothing is ever written for the stream again. Which
  # URL(s) it tests, and why there are two, is `sandbox_blocked_url` above.
  private def sandbox_refuses_locked(block : HeadRewrite::Block) : Bool
    return false unless @ordered   # a response exists only for a request already allowed
    return false unless block.head # trailers/PUSH_PROMISE carry no request URL to test
    return false unless sandbox_blocked_url(block)
    refuse_locked(block)
    true
  end

  # The same containment gate for a request the ORIGIN invented (RFC 9113 §8.4 server push).
  #
  # `sandbox_refuses_locked` cannot reach it: PUSH_PROMISE arrives on the RESPONSE leg, where
  # `@ordered` is false, and `HeadRewrite#head_text` returns nil for it (rules are correctly
  # never run over a promised head), so `block.head` is nil too. A promised request therefore
  # walked past a gate that refuses the identical authority on a real request, and
  # `Assembler#handle_push_promise` projected it into History as an ordinary row — a flow the
  # origin authored, indistinguishable from one the client made, inside the evidence the
  # operator came to read. "Hard containment" is what the sandbox advertises.
  #
  # Refusing a promise means three things, and they are the client's own §8.4 disposition:
  #   * the PUSH_PROMISE never reaches the client (suppressed, hence `@heads.latch` — the
  #     third route into the §6.2.1 HPACK asymmetry, exactly as `refuse_locked` describes);
  #   * RST_STREAM(CANCEL) goes to the ORIGIN on the PROMISED id, which is how a client
  #     declines a push, so the origin stops before it sends the pushed response;
  #   * the promised id joins `@refused` on THIS leg, so a pushed response already in flight
  #     is swallowed rather than written to a client that never learned the stream exists.
  #
  # Both URLs are tested for the reason `sandbox_blocked_url` gives: the promised
  # `:authority` may be any origin the certificate covers (§9.1.1), which is the whole point
  # of the finding — an origin that names `evil.test` in a promise.
  private def push_refuses_locked(block : HeadRewrite::Block) : Bool
    return false if @ordered # promises are server-initiated; the request leg never sees one
    return false unless block.first.frame_type == Frame::Type::PushPromise
    return false unless @interceptor.sandbox_enabled?
    promised = promised_stream_id(block)
    return false if promised == 0 || promised.odd? # §5.1.1 — the assembler rejects these too
    blocked = sandbox_blocked_url(block)
    return false unless blocked
    scheme, host, target = blocked
    ::Log.warn do
      "h2 in: refused a server PUSH_PROMISE for #{scheme}://#{host}#{target} (promised " \
      "stream #{promised}, promised on stream #{block.stream_id}) — the sandbox does not " \
      "allow that URL, and a promise is the origin's request, not the client's"
    end
    @heads.latch
    project(block)
    @assembler.drop_stream(promised, SANDBOX_REASON)
    remember_refused(promised)
    @deferred_cross << promised
    true
  end

  # The promised stream id out of a PUSH_PROMISE's carried-over prefix (R + 31 bits), which
  # `HeadRewrite#split_block` preserved verbatim for exactly this frame type. 0 when the
  # prefix is not there — a malformed promise the caller then leaves alone.
  private def promised_stream_id(block : HeadRewrite::Block) : UInt32
    prefix = block.prefix
    return 0_u32 if prefix.size < 4
    ((prefix[0].to_u32 & 0x7f) << 24) | (prefix[1].to_u32 << 16) |
      (prefix[2].to_u32 << 8) | prefix[3].to_u32
  end

  # Refuse one stream. The head never goes on the wire, so it is fed to the assembler for the
  # PROJECTION ONLY — `write` is what logs a frame, and P7 logs what gori actually wrote — and
  # the flow is finalized with h1's own sandbox reason, so a blocked attempt stays visible in
  # History exactly as `ClientConn#record_blocked_request` keeps it (P4/P7).
  #
  # Then RST_STREAM(CANCEL) to the CLIENT only. The origin never saw this stream open, and
  # RST_STREAM on an idle stream is itself a connection error (§6.4), so telling it would take
  # down every other stream on the connection — the same per-leg reasoning `drop_locked`
  # spells out. The client leg belongs to the peer gate, hence the cross list.
  #
  # h1 answers a blocked request with `403 + X-Gori-Sandbox: blocked`, and h2 deliberately
  # does not, for the reason step 3 rejected a synthesized 502: encoding a response head into
  # the client-bound direction makes gori a SECOND producer of HPACK-bearing frames there,
  # correct only while dynamic-table insertion stays off. A refusal is the last place to spend
  # that, since it would be spent on every out-of-scope subresource of every page.
  private def refuse_locked(block : HeadRewrite::Block) : Nil
    @heads.latch # suppressing a block desyncs HPACK exactly as reordering one does
    project(block)
    @assembler.drop_stream(block.stream_id, SANDBOX_REASON)
    remember_refused(block.stream_id)
    @deferred_cross << block.stream_id
  end

  # Past the ceiling the connection goes. Everywhere else in this file an overflow fails OPEN
  # (`fail_open`, `close`, the #123 reaper) because the thing being lost is a human's chance
  # to look at a message. Here it is the record of which streams must never reach the origin,
  # and a blocking gate that has forgotten what it blocked is not a gate.
  private def remember_refused(stream_id : UInt32) : Nil
    @refused << stream_id
    return if @refused.size <= MAX_REFUSED_STREAMS
    ::Log.warn do
      "h2 #{@direction}: over #{MAX_REFUSED_STREAMS} streams refused on one connection " \
      "(sandbox or intercept drop) — closing it, because gori can no longer keep track of " \
      "which streams must not reach the far end"
    end
    raise Gori::Error.new("h2: refused-stream ceiling reached")
  end

  # `HeadRewrite::Deferrer`. A header block this direction could not read.
  #
  # With the sandbox OFF this is a no-op and the frames go out verbatim — step 2's behaviour
  # and P7's, since the raw log is the truth and the peer is entitled to gori's honest relay
  # of what it received. With the sandbox ON the same forward is a hole: an unreadable head
  # has no URL to scope-test, so it would be the one request shape that walks past a blocking
  # gate, and it is the shape most likely to be hostile. Both causes (§6.1 padding, §4.3
  # HPACK) are CONNECTION errors by spec, so the far end would end the connection over this
  # block anyway — gori doing it first costs nothing and is the only answer that does not
  # guess. Response-direction blocks are left alone: they bypass no request gate.
  def undecodable(stream_id : UInt32) : Nil
    return unless @ordered && @interceptor.sandbox_enabled?
    ::Log.warn do
      "h2 out: stream #{stream_id} carries a header block gori cannot decode (RFC 9113 " \
      "§6.1/§4.3) — the sandbox is on and an unreadable head has no URL to scope-test, " \
      "so the connection is closed rather than forwarded unexamined"
    end
    raise Gori::Error.new("h2 sandbox: undecodable header block on stream #{stream_id}")
  end
end
