require "./scope"
require "./intercept_filter"

module Gori
  # The Intercept lens (P4 — the human decides): when enabled, an in-flight HTTP
  # message is HELD and a person chooses to Forward (possibly edited) or Drop it.
  # The proxy fiber blocks at the hold point until the TUI sends a decision —
  # exactly the `Store#insert_flow` "block on a reply channel" pattern.
  #
  # One shared instance (Mutex-guarded, like `Rules`): proxy fibers call `hold_*` (h1) or
  # `enqueue_*` (the h2 relay, which cannot block its pump fiber — see `enqueue_request`), and
  # the TUI calls `pending`/`forward`/`drop`/`toggle`. Gating reuses the Scope lens via
  # `intercepts_host?`. Held items are ephemeral (never persisted).
  class Interceptor
    # What a queue row IS. The two WebSocket members (#500 step 2) carry their direction in
    # the member rather than reusing `Request`/`Response`, because a WS message is neither:
    # it has no start line, no headers and no status, and every render site that treats
    # "not a request" as "a response" would otherwise paint it as one.
    #
    # Adding a member here is NOT free — the seven `kind.request?` ternaries this enum used
    # to be branched on all compiled clean and rendered a new member as `RES`. They are
    # exhaustive `case ... in` now (the shape #533 gave `RulePart#badge`), so a member added
    # later fails the build at each site that has to decide what it looks like.
    enum Kind
      Request
      Response
      WsOut # a WebSocket message travelling client → server
      WsIn  # a WebSocket message travelling server → client

      def ws? : Bool
        ws_out? || ws_in?
      end
    end

    enum Action
      Forward # send `bytes` onward (edited or original)
      Drop    # discard; the proxy answers the client with a canned 502
    end

    # Which leg of a flow to hold: both, requests only, or responses only. Lets a
    # user who only cares about outgoing requests (the common case) skip the
    # response round-trip without disabling intercept. Does NOT relax the h2→h1
    # downgrade gate — a response can only be held on the interceptable h1 path, so
    # the connection must stay h1 for either direction.
    enum Direction
      Both
      RequestOnly
      ResponseOnly
    end

    # The Subject struct the conditional-intercept filter matches against.
    alias Subject = InterceptFilter::Subject

    # The decision the TUI hands back over an Item's reply channel.
    record Decision, action : Action, bytes : Bytes

    # One held message awaiting a human decision. `raw` is the full head(+body)
    # that would otherwise go on the wire (truth, P7). `reply` is buffered(1) so
    # a release never blocks even if the held fiber already died (client gone).
    class Item
      getter id : Int64
      getter kind : Kind
      getter method : String
      getter host : String
      getter target : String
      getter port : Int32
      getter scheme : String
      getter flow_id : Int64?
      getter raw : Bytes
      getter held_at : Time::Instant
      # Wall-clock (unix ms) captured ONCE at hold time. `held_at` is a monotonic Instant
      # (meaningless across processes); the #123 store snapshot needs a stable wall-clock so
      # the MCP process can render a correct age that does NOT reset on every republish.
      getter held_at_ms : Int64
      getter reply : Channel(Decision)
      # A WebSocket BINARY message (opcode 2). Holdable, forwardable and droppable, but
      # read-only in the editor: the TextArea round trip is `String.new(raw)` → char ops →
      # `.to_slice`, which is lossy on non-UTF-8 — a pre-existing sharp edge on an HTTP body
      # that WS makes the DEFAULT case, since opcode 2 is protobuf/msgpack/CBOR.
      getter? binary : Bool

      def initialize(@id, @kind, @method, @host, @target, @port, @scheme, @raw, @held_at,
                     @flow_id = nil, @binary = false)
        @reply = Channel(Decision).new(1)
        @held_at_ms = Time.utc.to_unix_ms
      end
    end

    @direction : Direction
    @filter : InterceptFilter

    def initialize(@scope : Scope)
      @mutex = Mutex.new
      @enabled = false
      @items = {} of Int64 => Item
      @next_id = 0_i64
      @shutting_down = false
      # Which leg(s) to hold + an optional in-memory condition that NARROWS holding
      # (vs Scope, the global lens). Both default permissive (hold every in-scope
      # message). Mutated by the TUI fiber, read on the proxy hot path → @mutex.
      @direction = Direction::Both
      @filter = InterceptFilter::EMPTY
      # Monotonic counter bumped on every queue/enabled change (incl. async holds
      # from proxy fibers). The TUI compares it to know when to re-render, since
      # the queue mutates without any flow event. Atomic → lock-free read.
      @revision = Atomic(Int32).new(0)
    end

    # Lock-free snapshot of the change counter (see @revision).
    def revision : Int32
      @revision.get
    end

    def enabled? : Bool
      @mutex.synchronize { @enabled }
    end

    # Which leg(s) are currently held (TUI reads it to render the catch chip).
    def direction : Direction
      @mutex.synchronize { @direction }
    end

    # The raw condition source (TUI reads it to render the filter bar). The query
    # itself lives in the TUI's edit buffer; this is the committed copy.
    def filter_source : String
      @mutex.synchronize { @filter.source }
    end

    # Cycle the catch direction Both → RequestOnly → ResponseOnly → Both. Returns
    # the new value; bumps revision so the TUI redraws the chip.
    def cycle_direction : Direction
      now = @mutex.synchronize do
        @direction = case @direction
                     when .both?         then Direction::RequestOnly
                     when .request_only? then Direction::ResponseOnly
                     else                     Direction::Both
                     end
      end
      @revision.add(1)
      now
    end

    # Set the catch direction to an explicit value (idempotent — no-op if already there).
    # Unlike cycle_direction, this lets a remote MCP agent request a DESIRED state without
    # blind-cycling; the #123 drain applies it exactly once via the command watermark.
    def set_direction(dir : Direction) : Nil
      changed = @mutex.synchronize do
        if @direction != dir
          @direction = dir
          true
        else
          false
        end
      end
      @revision.add(1) if changed
    end

    # Replace the conditional-intercept filter (parsed from a QL-like query). Cheap
    # to rebuild, so the TUI can call it live on every keystroke. Bumps revision.
    def set_filter(query : String) : Nil
      @mutex.synchronize { @filter = InterceptFilter.new(query) }
      @revision.add(1)
    end

    # Toggle on/off. Turning OFF auto-forwards everything currently held (so
    # traffic never wedges). Returns the new state.
    def toggle : Bool
      released = [] of Item
      now_on = @mutex.synchronize do
        @enabled = !@enabled
        unless @enabled
          released = @items.values
          @items.clear
        end
        @enabled
      end
      @revision.add(1) # enabled flipped (and possibly the queue cleared)
      released.each { |it| it.reply.send(Decision.new(Action::Forward, it.raw)) }
      now_on
    end

    # Conservative HOST-level gate: is holding even possible for this host? Scope rules that
    # match on path/URL can't be evaluated without a request, so this is permissive — true if
    # the host COULD be in scope — and the precise per-message call is `intercepts_request?` /
    # `intercepts_response?`, which do NOT consult this. Direction-agnostic on purpose.
    #
    # It used to also drive the h2→h1 ALPN downgrade (`tls/tunnel.cr`), forcing held hosts onto
    # the h1 path because that was the only interceptable one. #492 step 3 made the hold work
    # per stream on h2 and removed that gate, so this now has one caller: the `enqueue` below.
    def intercepts_host?(host : String) : Bool
      active = @mutex.synchronize { @enabled && !@shutting_down }
      return false unless active
      @scope.active? ? @scope.may_match_host?(host) : true
    end

    # --- Sandbox (proxy containment gate) ------------------------------------
    # Delegates to the shared Scope (which the Interceptor already owns for hold-gating), so
    # the proxy path reaches the sandbox policy through the object it already threads. FULLY
    # INDEPENDENT of the interceptor's own `@enabled`: the sandbox blocks whether or not
    # intercept is on.

    # Is the sandbox on? Two callers, and neither is the Tunnel any more: it used to force every
    # sandboxed connection to h1 so that `sandbox_blocks?` below would run per request, and #492
    # step 4 replaced that with a per-stream refusal in `H2::StreamGate` (which is the other
    # caller — it refuses a header block it cannot decode, since an unreadable head has no URL
    # to test). The first is the CONNECT h2c refusal (`client_conn.cr`), where the raw h2c relay
    # is wired with no gates at all, so there is nothing to gate per request and the whole tunnel
    # is refused instead.
    def sandbox_enabled? : Bool
      @scope.sandbox?
    end

    # Precise per-request block (ClientConn). Builds the scope URL only when the sandbox is on
    # — an off sandbox never inspects the URL — mirroring scope_allows?.
    def sandbox_blocks?(scheme : String, host : String, target : String) : Bool
      return false unless @scope.sandbox?
      @scope.sandbox_blocks?(Scope.request_url(scheme, host, target), host)
    end

    # Coarse HOST-level block for the CONNECT gate, made before any request exists.
    def sandbox_blocks_host?(host : String) : Bool
      @scope.sandbox_blocks_host?(host)
    end

    # Precise per-REQUEST gate, used by ClientConn (which has the full request): hold
    # this exact request? The scope URL (`scheme://host/target` — the same value the
    # Scope SQL filter builds, so a held request is exactly an in-scope History row) is
    # built LAZILY here, only after the enabled/direction gates pass AND only when Scope
    # is active, so the common capture-only (intercept-off) path never allocates it.
    # Folds in the catch direction (skip when responses-only) and the conditional filter.
    def intercepts_request?(*, method : String, host : String,
                            target : String, scheme : String) : Bool
      enabled, dir, filter = gate_snapshot
      return false unless enabled
      return false if dir.response_only?
      return false unless scope_allows?(scheme, host, target)
      filter.matches?(Subject.new(method: method, host: host, target: target, scheme: scheme))
    end

    # Precise per-RESPONSE gate (same shape as the request gate). Skips when
    # requests-only; the condition can also test `status:` here (a response has one).
    def intercepts_response?(*, method : String, host : String,
                             target : String, scheme : String, status : Int32) : Bool
      enabled, dir, filter = gate_snapshot
      return false unless enabled
      return false if dir.request_only?
      return false unless scope_allows?(scheme, host, target)
      filter.matches?(Subject.new(method: method, host: host, target: target, scheme: scheme, status: status))
    end

    # Precise per-MESSAGE gate for a reassembled WebSocket message (#500 step 2). `out` is
    # client→server, matching `Direction::RequestOnly`, exactly as `in` matches responses —
    # `Direction` already means "which leg", so no enum member was added there.
    #
    # Three things differ from the two HTTP gates above:
    #
    #   1. **`mentions_ws?` is a hard precondition.** Without an explicit `proto:ws` term
    #      nothing is held, whatever else the condition says and however permissive the
    #      direction is — the inverse of the HTTP default, and the reason is in
    #      `InterceptFilter`'s header: a socket frozen whole is not a recoverable state.
    #   2. **Scope is the HANDSHAKE's.** A WS message has no authority, scheme or path of its
    #      own; scoping it on the 101's is the same answer #492 step 3 gave a held h2 response
    #      ("inventing one is how a hold escapes scope").
    #   3. **The payload is in hand**, so `body:` can match — the one place it can.
    def intercepts_ws?(*, to_server : Bool, method : String, host : String, target : String,
                       scheme : String, payload : Bytes) : Bool
      enabled, dir, filter = gate_snapshot
      return false unless enabled
      return false if to_server ? dir.response_only? : dir.request_only?
      return false unless filter.mentions_ws?
      return false unless scope_allows?(scheme, host, target)
      filter.matches?(Subject.new(method: method, host: host, target: target, scheme: scheme,
        proto: Proto::Kind::Ws, payload: payload))
    end

    # Coarse per-SOCKET arming, asked once right after the 101 (`WS::Relay.run`), the way
    # step 1 asks the rewriter once: a "no" runs the pre-existing byte-exact pump and pays
    # nothing per message. A "yes" only means messages will be OFFERED to `intercepts_ws?`.
    #
    # Consequence, and it is in the docs: enabling catch on an ALREADY-OPEN socket does
    # nothing — it applies to the next handshake. The condition itself stays live, because
    # the per-message gate re-reads it; only the arming is one-shot.
    def arms_ws_hold?(host : String, *, to_server : Bool) : Bool
      enabled, dir, filter = gate_snapshot
      return false unless enabled
      return false if to_server ? dir.response_only? : dir.request_only?
      return false unless filter.mentions_ws?
      @scope.active? ? @scope.may_match_host?(host) : true
    end

    # One locked read of the enabled/direction/filter trio, so a single hot-path
    # call takes @mutex once. Scope has its OWN mutex, so scope_allows? runs after.
    private def gate_snapshot : {Bool, Direction, InterceptFilter}
      @mutex.synchronize { {@enabled && !@shutting_down, @direction, @filter} }
    end

    # Build the scope URL only when Scope is active (an inactive scope allows everything
    # without inspecting the URL), so a passing gate on an intercept-enabled/scope-off
    # setup still skips the interpolation.
    private def scope_allows?(scheme : String, host : String, target : String) : Bool
      return true unless @scope.active?
      @scope.in_scope_url?(Scope.request_url(scheme, host, target), host)
    end

    # --- proxy fiber side (BLOCKS until a decision) --------------------------

    def hold_request(raw : Bytes, *, method : String, target : String,
                     host : String, port : Int32, scheme : String) : Decision
      item = enqueue_request(raw, method: method, target: target, host: host, port: port, scheme: scheme)
      item ? item.reply.receive : Decision.new(Action::Forward, raw)
    end

    # `flow_id` is nilable for the h2 path only: the h2 assembler emits the request flow when
    # the request half-closes, so an origin that answers a still-streaming upload has no flow
    # row yet. `Item#flow_id` was already `Int64?` and the TUI already falls back to the
    # intercept tab when it is nil, so nothing else moves. h1 keeps passing an Int64.
    def hold_response(raw : Bytes, *, flow_id : Int64?, method : String, target : String,
                      host : String, port : Int32, scheme : String) : Decision
      item = enqueue_response(raw, flow_id: flow_id, method: method, target: target,
        host: host, port: port, scheme: scheme)
      item ? item.reply.receive : Decision.new(Action::Forward, raw)
    end

    # Queue a message WITHOUT waiting for the decision, handing back the Item to wait on (nil
    # = not held, forward as-is). h1 has no use for this: its hold IS the connection fiber, so
    # blocking there costs exactly the one request it is holding. The h2 relay runs ONE pump
    # fiber per direction for every stream on the connection, so the fiber that waits for a
    # human cannot be the one reading frames (#492 step 3, D1) — it enqueues here and blocks
    # on `Item#reply` elsewhere. `hold_request`/`hold_response` are this plus the receive, so
    # the two paths cannot drift.
    def enqueue_request(raw : Bytes, *, method : String, target : String,
                        host : String, port : Int32, scheme : String) : Item?
      enqueue(Kind::Request, raw, method, target, host, port, scheme, nil)
    end

    def enqueue_response(raw : Bytes, *, flow_id : Int64?, method : String, target : String,
                         host : String, port : Int32, scheme : String) : Item?
      enqueue(Kind::Response, raw, method, target, host, port, scheme, flow_id)
    end

    # Queue one reassembled WebSocket message (#500 step 2). `raw` is the payload as it would
    # go on the wire — post-Match&Replace, since the hold is a stage INSIDE step 1's rewrite
    # path rather than a second pipeline beside it — and `method`/`target`/`host`/`scheme`
    # are the HANDSHAKE's, so the queue row identifies the socket the message rides on.
    #
    # Like the h2 gate this never waits: `WS::MessageGate` owns the release order and blocks
    # a fiber of its own, because a blocked pump stops relaying PING/PONG and a server's
    # 20-30 s ping timer would close the socket out from under the operator.
    def enqueue_ws(raw : Bytes, *, to_server : Bool, method : String, target : String,
                   host : String, port : Int32, scheme : String, flow_id : Int64?,
                   binary : Bool) : Item?
      enqueue(to_server ? Kind::WsOut : Kind::WsIn, raw, method, target, host, port, scheme,
        flow_id, binary)
    end

    private def enqueue(kind, raw, method, target, host, port, scheme, flow_id,
                        binary = false) : Item?
      return nil unless intercepts_host?(host)
      item = @mutex.synchronize do
        return nil if @shutting_down || !@enabled
        id = (@next_id += 1)
        it = Item.new(id, kind, method, host, target, port, scheme, raw, Time.instant, flow_id, binary)
        @items[id] = it
        it
      end
      @revision.add(1) # a request/response/message was held (async, from a proxy fiber)
      item
    end

    # --- TUI side ------------------------------------------------------------

    def pending : Array(Item)
      @mutex.synchronize { @items.values }
    end

    # One held item by id (nil if already forwarded/dropped). Used by the #123 apply-loop to
    # describe an agent action + touch recency before forwarding/dropping cross-process.
    def get(id : Int64) : Item?
      @mutex.synchronize { @items[id]? }
    end

    def pending_count : Int32
      @mutex.synchronize { @items.size }
    end

    def forward(id : Int64, bytes : Bytes? = nil) : Nil
      item = @mutex.synchronize { @items.delete(id) }
      return unless item
      @revision.add(1)
      item.reply.send(Decision.new(Action::Forward, bytes || item.raw))
    end

    def drop(id : Int64) : Nil
      item = @mutex.synchronize { @items.delete(id) }
      return unless item
      @revision.add(1)
      item.reply.send(Decision.new(Action::Drop, Bytes.empty))
    end

    # `overrides` lets the caller supply edited bytes for specific held items (keyed by
    # id) — e.g. an in-progress editor edit that would otherwise be lost when the whole
    # queue is released at once. Items without an override forward their original bytes.
    def forward_all(overrides : Hash(Int64, Bytes)? = nil) : Nil
      items = @mutex.synchronize { vals = @items.values; @items.clear; vals }
      @revision.add(1) unless items.empty?
      items.each do |it|
        bytes = overrides.try(&.[it.id]?) || it.raw
        it.reply.send(Decision.new(Action::Forward, bytes))
      end
    end

    # Shutdown: latch so nothing re-enqueues, then auto-forward every held item
    # (original bytes) so no proxy fiber stays blocked when the Session closes.
    def release_all : Nil
      items = @mutex.synchronize do
        @shutting_down = true
        vals = @items.values
        @items.clear
        vals
      end
      items.each { |it| it.reply.send(Decision.new(Action::Forward, it.raw)) }
    end
  end
end
