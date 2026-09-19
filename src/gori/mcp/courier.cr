require "json"
require "../store"
require "./inbox"

module Gori::MCP
  # Carries operator messages from the project's event feed to THIS server's client session
  # (#1090). One per `gori mcp` process, started once the client says `initialized`, stopped
  # when the reader hits EOF.
  #
  # Three routes, best available first, and never two for one message:
  #   1. a `notifications/claude/channel` frame on this JSON-RPC stream — only when the
  #      capability was DECLARED at this session's handshake (the operator's
  #      `Settings.mcp_channels` as it stood then, latched by the server), because a push to a
  #      session that did not register the channel is dropped without a word, and combined
  #      with the socket it would say the same thing twice;
  #   2. the session's inbox socket (`ClaudeInbox`) — GA, no flags, framed as a peer's note;
  #   3. nothing — the row stays in the feed for `operator_messages`, and a delivery row says so.
  # Every message gets exactly one delivery row, which is what the TUI turns into
  # "→ claude-code got it (socket)" in the notification ring.
  #
  # The cursor starts at the feed's high-water mark when the courier starts: a client that
  # attaches later is not handed what the operator said before it arrived. The store is
  # re-read on every tick through `store` (a `switch_project` swaps it), and a swap resets
  # the cursor to the new feed's end for the same reason.
  #
  # Runs on its own fiber and never touches the reader's: a store error or a refused socket
  # costs one tick, not the session (`work_loop`'s rule).
  class Courier
    INTERVAL = 500.milliseconds
    PAGE     = 50

    getter cursor : Int64
    getter delivered : Int32

    def initialize(*, @pid : Int64, @store : Proc(Store?), @client : Proc(String?),
                   @channels : Proc(Bool), @emit : Proc(String, Nil),
                   @inbox : Proc(String?) = -> { ClaudeInbox.discover })
      @cursor = 0_i64
      # The store the cursor was taken against — a REFERENCE, never its object_id: a bare id
      # can be reused by the next store the GC hands out at the same address, and a cursor
      # from one feed applied to another either replays or skips (the bare-id cache trap).
      @cursor_store = nil.as(Store?)
      @delivered = 0
      @stop = Channel(Nil).new(1)
      @running = false
      @warned_read_only = false
      # Anchor the cursor NOW, when the presence marker that makes this process a target is
      # already up — not at the first tick, half a second after `initialized`. A message the
      # operator sends in between is owed a delivery, not a silent skip.
      @store.call.try { |st| rebase(st) }
    end

    def start : Nil
      return if @running
      @running = true
      spawn(name: "mcp-courier") do
        loop do
          select
          when @stop.receive?
            break
          when timeout(INTERVAL)
            begin
              tick
            rescue ex
              Log.warn(exception: ex) { "mcp: courier tick failed; keeping the session" }
            end
          end
        end
      end
    end

    def stop : Nil
      return unless @running
      @running = false
      @stop.send(nil) rescue nil
    end

    # One pass: deliver every message addressed here since the cursor. Returns how many rows
    # it handled. Public so a spec can drive it without the fiber.
    def tick : Int32
      store = @store.call
      return 0 unless store
      rebase(store)
      # The high-water mark is read BEFORE the page: the TUI is another process, and a row it
      # commits between the two queries must land inside the next page, not behind the cursor.
      # It is also the idle gate: one `MAX(id)` off the rowid index per tick, and the page
      # query only when the feed grew — a host full of idle servers costs a scalar each.
      # (Not `PRAGMA data_version`: it does not reliably move for a write from this process's
      # own writer connection, which the courier's delivery rows are.)
      high = store.last_event_id
      return 0 if high <= @cursor
      page = store.agent_messages_after(@cursor, @pid, PAGE)
      page.rows.each do |m|
        deliver(store, m)
        @delivered += 1
      end
      # A full page may hide more behind it: advance only to what was scanned. A short page
      # has shown everything up to `high`.
      @cursor = page.full ? {@cursor, page.scanned_max}.max : {@cursor, page.scanned_max, high}.max
      page.rows.size
    end

    private def deliver(store : Store, m : AgentMessage) : Nil
      label = "#{@client.call || "agent"} pid #{@pid}"
      route = "poll"
      if @channels.call && @client.call == "claude-code"
        route = "channel"
        @emit.call(Courier.channel_frame(m))
        record(store, m, route, label, true)
      elsif path = @inbox.call
        route = "socket"
        reason = ClaudeInbox.deliver(path, ClaudeInbox.frame(m.text, m.from_tab))
        record(store, m, route, label, reason.nil?, reason)
      else
        record(store, m, AgentDelivery::VIA_POLL, label, true, "no live route; left for operator_messages")
      end
    rescue ex
      # The cursor has already passed this row; a raise here would lose it silently. A row
      # that names the route it was trying is the only honest outcome.
      # Locals assigned before a raise are nilable inside the rescue; the fallbacks are the
      # values the method starts with.
      record(store, m, route || "poll", label || "#{@client.call || "agent"} pid #{@pid}", false,
        "delivery raised: #{ex.message || ex.class.name}") rescue nil
    end

    # A `--read-only` server has no writer fiber: the message still goes out, but no row can
    # say so, and the operator's ring stays silent. Said once, in the log, rather than never.
    private def record(store : Store, m : AgentMessage, via : String, label : String, ok : Bool,
                       reason : String? = nil) : Nil
      if store.read_only?
        unless @warned_read_only
          @warned_read_only = true
          Log.warn { "mcp: read-only server delivered an operator message but cannot record it; the ring will not show it" }
        end
        return
      end
      store.record_agent_delivery(m.id, via, label, ok, reason, pid: @pid)
    end

    # The channel event. `meta` keys must be `[A-Za-z0-9_]` — a hyphen is silently dropped by
    # the client — and values are strings.
    def self.channel_frame(m : AgentMessage) : String
      JSON.build do |j|
        j.object do
          j.field "jsonrpc", "2.0"
          j.field "method", "notifications/claude/channel"
          j.field "params" do
            j.object do
              j.field "content", m.text + ClaudeInbox::REPLY_HINT
              j.field "meta" do
                j.object do
                  j.field "message_id", m.id.to_s
                  j.field "from_tab", m.from_tab || ""
                  j.field "flow_ids", m.flow_ids.join(",") unless m.flow_ids.empty?
                end
              end
            end
          end
        end
      end
    end

    # A different store object than the cursor was taken against → start from its end.
    private def rebase(store : Store) : Nil
      return if @cursor_store.same?(store)
      @cursor_store = store
      @cursor = store.last_event_id
    end
  end
end
