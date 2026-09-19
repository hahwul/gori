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
  #      operator has said their Claude is launched with channels (`Settings.mcp_channels`),
  #      because a push to a session that did not register the channel is dropped without a
  #      word, and combined with the socket it would say the same thing twice;
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
      @cursor_store = nil.as(UInt64?)
      @delivered = 0
      @stop = Channel(Nil).new(1)
      @running = false
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
      rows = store.agent_messages_after(@cursor, @pid, PAGE)
      # The cursor is the max SCANNED id, not the last delivered: a page can be empty because
      # nothing was addressed here, and the next tick must not rescan those rows.
      @cursor = {@cursor, store.last_event_id}.max if rows.empty?
      rows.each do |m|
        @cursor = m.id
        deliver(store, m)
        @delivered += 1
      end
      rows.size
    end

    private def deliver(store : Store, m : AgentMessage) : Nil
      label = "#{@client.call || "agent"} pid #{@pid}"
      if @channels.call && @client.call == "claude-code"
        @emit.call(Courier.channel_frame(m))
        store.record_agent_delivery(m.id, "channel", label, true)
      elsif path = @inbox.call
        reason = ClaudeInbox.deliver(path, ClaudeInbox.frame(m.text, m.from_tab))
        store.record_agent_delivery(m.id, "socket", label, reason.nil?, reason)
      else
        store.record_agent_delivery(m.id, "poll", label, false, "no live route; left for operator_messages")
      end
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
              j.field "content", m.text
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
      key = store.object_id
      return if @cursor_store == key
      @cursor_store = key
      @cursor = store.last_event_id
    end
  end
end
