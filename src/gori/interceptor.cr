require "./scope"

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
      getter reply : Channel(Decision)

      def initialize(@id, @kind, @method, @host, @target, @port, @scheme, @raw, @held_at, @flow_id = nil)
        @reply = Channel(Decision).new(1)
      end
    end

    def initialize(@scope : Scope)
      @mutex = Mutex.new
      @enabled = false
      @items = {} of Int64 => Item
      @next_id = 0_i64
      @shutting_down = false
    end

    def enabled? : Bool
      @mutex.synchronize { @enabled }
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
      released.each { |it| it.reply.send(Decision.new(Action::Forward, it.raw)) }
      now_on
    end

    # The single gating predicate: hold this host's traffic? Used by ClientConn
    # (whether to hold) AND by Tunnel (whether to downgrade h2→h1), so the held
    # set and the downgraded set are identical.
    def intercepts_host?(host : String) : Bool
      active = @mutex.synchronize { @enabled && !@shutting_down }
      return false unless active
      @scope.active? ? @scope.matches?(host) : true
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
      item.reply.receive
    end

    # --- TUI side ------------------------------------------------------------

    def pending : Array(Item)
      @mutex.synchronize { @items.values }
    end

    def pending_count : Int32
      @mutex.synchronize { @items.size }
    end

    def forward(id : Int64, bytes : Bytes? = nil) : Nil
      item = @mutex.synchronize { @items.delete(id) }
      return unless item
      item.reply.send(Decision.new(Action::Forward, bytes || item.raw))
    end

    def drop(id : Int64) : Nil
      item = @mutex.synchronize { @items.delete(id) }
      return unless item
      item.reply.send(Decision.new(Action::Drop, Bytes.empty))
    end

    def forward_all : Nil
      items = @mutex.synchronize { vals = @items.values; @items.clear; vals }
      items.each { |it| it.reply.send(Decision.new(Action::Forward, it.raw)) }
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
