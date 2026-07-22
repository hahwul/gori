require "./scope"
require "./intercept_filter"

module Gori
  # The Intercept lens (P4 — the human decides): when enabled, an in-flight HTTP
  # message is HELD and a person chooses to Forward (possibly edited) or Drop it.
  # The proxy fiber blocks at the hold point until the TUI sends a decision —
  # exactly the `Store#insert_flow` "block on a reply channel" pattern.
  #
  # One shared instance (Mutex-guarded, like `Rules`): proxy fibers call
  # `hold_*`, the TUI calls `pending`/`forward`/`drop`/`toggle`. Gating reuses the
  # Scope lens via `intercepts_host?`, which ALSO drives the h2→h1 ALPN downgrade
  # so the same hosts that get held are the ones forced onto the interceptable
  # h1 path. Held items are ephemeral (never persisted).
  class Interceptor
    enum Kind
      Request
      Response
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

      def initialize(@id, @kind, @method, @host, @target, @port, @scheme, @raw, @held_at, @flow_id = nil)
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

    # Conservative HOST-level gate, used by the Tunnel to decide whether to downgrade
    # h2→h1 BEFORE any request exists (so only the host is known). Scope rules that
    # match on path/URL can't be evaluated yet, so this is permissive: downgrade if the
    # host COULD be in scope, then let ClientConn make the precise per-request call via
    # intercepts_request?. Keeping the connection on h1 is what lets a request be held.
    # Direction-agnostic on purpose: holding EITHER a request or a response needs h1.
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

    # Is the sandbox on? Drives the Tunnel's force-to-h1 (so every MITM'd request reaches the
    # per-request block below) and the CONNECT h2c refusal.
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
      hold(Kind::Request, raw, method, target, host, port, scheme, nil)
    end

    def hold_response(raw : Bytes, *, flow_id : Int64, method : String, target : String,
                      host : String, port : Int32, scheme : String) : Decision
      hold(Kind::Response, raw, method, target, host, port, scheme, flow_id)
    end

    private def hold(kind, raw, method, target, host, port, scheme, flow_id) : Decision
      return Decision.new(Action::Forward, raw) unless intercepts_host?(host)
      item = @mutex.synchronize do
        return Decision.new(Action::Forward, raw) if @shutting_down || !@enabled
        id = (@next_id += 1)
        it = Item.new(id, kind, method, host, target, port, scheme, raw, Time.instant, flow_id)
        @items[id] = it
        it
      end
      @revision.add(1) # a request/response was held (async, from a proxy fiber)
      item.reply.receive
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
