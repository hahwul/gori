require "json"
require "../store"
require "./inbox"
require "./codex_queue"

module Gori::MCP
  # Carries operator messages from the project's event feed to THIS server's client session
  # (#1090). One per `gori mcp` process, started once the client says `initialized`, stopped
  # when the reader hits EOF.
  #
  # Four routes, tried in order of what can be CONFIRMED, and only a confirmed one retires a
  # message from the poll backstop (`AgentDelivery::CARRIED`): the socket write either lands or
  # reports why, so it carries the message; the channel push cannot be confirmed, so it does
  # NOT — a session that was not launched with channels drops the frame without a word, and the
  # message must stay readable through `operator_messages` rather than vanish. The cost of that
  # safety is that a channel which DOES work may be read a second time by a polling agent; the
  # silent-loss it prevents is the worse outcome, and channels are an opt-in preview besides.
  #   1. the session's inbox socket (`ClaudeInbox`) — GA, no flags, framed as a peer's note; a
  #      write that lands carries the message and retires it.
  #   2. `codex queue` against the parent Codex session's own thread (`CodexQueue`) — the same
  #      bargain as the socket through a different door: the CLI accepts the line or says why
  #      not, so an accepted hand-off carries the message.
  #   3. a `notifications/claude/channel` frame on this JSON-RPC stream — only when the
  #      capability was DECLARED at this session's handshake (the operator's
  #      `Settings.mcp_channels` as it stood then, latched by the server), and only when neither
  #      door above answered. A best-effort nudge: the delivery row reads "got it (channel)",
  #      but the message is left for poll all the same.
  #   4. nothing — the row stays in the feed for `operator_messages` and the tool-result carry
  #      (`Tools#pending_operator_note`), and a poll deposit row says so.
  # Never two for one message: `deliver` returns on the first route that takes it, and the
  # other two readers of the same feed — the tool-result carry and `operator_messages`, both on
  # `Tools` — stand down while a hand-off is in flight (`claim`/`release`). The durable
  # delivery row is what answers once the hand-off returns; the claim is what answers before it
  # does, which for a `codex queue` is ten seconds of `Process.run`.
  # Each recipient gets its own delivery row (a broadcast has one per session), which is what
  # the TUI turns into "→ claude-code got it (socket)" in the notification ring.
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

    # `claim`/`release` bracket a hand-off for the OTHER readers in this process (the
    # tool-result carry and `operator_messages`, both on `Tools`). They default to "always
    # mine, nothing to give back" so a spec can drive a courier without the rest of the server.
    def initialize(*, @pid : Int64, @store : Proc(Store?), @client : Proc(String?),
                   @channels : Proc(Bool), @emit : Proc(String, Nil),
                   @inbox : Proc(String?) = -> { ClaudeInbox.discover },
                   @codex : Proc(CodexQueue::Session?) = -> { CodexQueue.discover },
                   @claim : Proc(Int64, Bool) = ->(_id : Int64) { true },
                   @release : Proc(Int64, Nil) = ->(_id : Int64) { nil })
      @cursor = 0_i64
      # The store the cursor was taken against — a REFERENCE, never its object_id: a bare id
      # can be reused by the next store the GC hands out at the same address, and a cursor
      # from one feed applied to another either replays or skips (the bare-id cache trap).
      @cursor_store = nil.as(Store?)
      @delivered = 0
      @stop = Channel(Nil).new(1)
      @running = false
      @warned_read_only = false
      @codex_memo = nil.as(CodexQueue::Session?)
      @codex_asked = false
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
      # One discovery per TICK, not per message: on a broadcast every row in this page goes to
      # the same parent, and the Codex lookup is a fork. Cleared HERE rather than remembered,
      # so it never outlives the pass — the thread under us can change between ticks, which is
      # the whole reason the route refuses to cache.
      @codex_memo = nil
      @codex_asked = false
      # What a confirmed route already carried to THIS session is not ours to deliver again.
      # The courier used to skip this test because it was the only route that ran on its own
      # clock — but `operator_messages` has always been able to pick a message up inside the
      # 500ms before a tick, and the tool-result carry (#1090 layer four) now does so on every
      # call the agent makes. Without the test, a message the agent already has is written to
      # its inbox socket or queued into its Codex thread a second time, which for Codex is a
      # whole extra turn spent on an instruction it already acted on.
      already = claimed(store, page)
      before = @cursor
      held = nil.as(Int64?)
      page.rows.each do |m|
        next if already.includes?(m.id)
        # …and the delivery ROW only answers for a hand-off that has already finished. A
        # `codex queue` parks this fiber in `Process.run` for up to ten seconds, and the tool
        # call the agent makes during that window reads the same feed: it would find the
        # message unclaimed and attach it to its own result, which is the duplicate this test
        # exists to prevent, arriving through the other door. So the in-flight id is announced
        # to the rest of the process for as long as the hand-off lasts — `ensure`, because a
        # claim that leaks is a message this process would never carry again.
        unless @claim.call(m.id)
          held ||= m.id
          next
        end
        begin
          deliver(store, m)
          @delivered += 1
        ensure
          @release.call(m.id)
        end
      end
      # A full page may hide more behind it: advance only to what was scanned. A short page
      # has shown everything up to `high`.
      @cursor = page.full ? {@cursor, page.scanned_max}.max : {@cursor, page.scanned_max, high}.max
      # …except past a row somebody else was mid-way through. That claim is TEMPORARY and the
      # holder may fail, so unlike an `already` row it is not finished with: stop just below it
      # and read it again next tick. `held` is always above the cursor this tick started from,
      # so this can only ever hold the cursor back, never move it backwards.
      @cursor = {before, {@cursor, held - 1}.min}.max if held
      page.rows.size
    end

    # The ids on this page a confirmed route has already delivered to this session. Scanned
    # from just below the oldest row on the page: a delivery is written after the message it
    # reports, so nothing older can answer for one of these.
    private def claimed(store : Store, page : Store::MessagePage) : Set(Int64)
      return Set(Int64).new if page.rows.empty?
      store.delivered_agent_message_ids(page.rows.min_of(&.id) - 1, @pid, page.rows.map(&.id).to_set)
    end

    # One message, down the chain until a route takes it. Two rules hold this together, and
    # both of them were learned the hard way:
    #
    #   - A route that can be CONFIRMED comes before one that cannot. The channel push used to
    #     be first, so an operator who turned the preview on got it INSTEAD of the inbox socket
    #     — and a Claude Code session that was not launched with the development-channels flag
    #     then had its one waking route taken away by a setting whose own description says the
    #     push rides "on top of" it. The channel is what answers when no confirmed door is open,
    #     which is the only case where an unverifiable push beats nothing at all. Nothing is
    #     lost for a session that DOES hold a channel: the socket reaches the same session, and
    #     unlike the push it retires the message instead of leaving it for a second reading.
    #   - A route that FAILS falls through instead of ending the chain. A socket path that
    #     exists is not a session that is listening — `/tmp/cc-socks/<pid>.sock` outlives the
    #     process that bound it, and pids are reused — so a `gori mcp` under some other client
    #     can find a dead Claude socket at its parent's pid. Committing to it cost the hand-off
    #     that would have worked; now the failure is carried into the row of whatever route
    #     did answer, or into the poll deposit when none did.
    private def deliver(store : Store, m : AgentMessage) : Nil
      label = session_label
      note = OperatorNote.frame(m.text, m.from_tab, m.flow_ids, m.id)
      # `route` is assigned BEFORE each hand-off, never after: the rescue below can only name
      # the route it was trying if the route is already on the local when the trying starts.
      # What an earlier route SAID on its way past goes here — the operator gets one row per
      # message, so a refusal the chain walked away from is visible only if the row that lands
      # carries it.
      tried = [] of String
      if path = @inbox.call
        route = AgentDelivery::VIA_SOCKET
        reason = ClaudeInbox.deliver(path, note)
        return record(store, m, route, label, true) unless reason
        tried << "socket: #{reason}"
      end
      if session = codex_session
        route = AgentDelivery::VIA_CODEX_QUEUE
        reason = CodexQueue.deliver(session, note)
        return record(store, m, route, label, true) unless reason
        tried << reason
      end
      if channel_route?
        route = AgentDelivery::VIA_CHANNEL
        @emit.call(Courier.channel_frame(m))
        return record(store, m, route, label, true)
      end
      deposit(store, m, label, tried)
    rescue ex
      # The cursor has already passed this row; a raise here would lose it silently. A row
      # that names the route it was trying is the only honest outcome. Locals assigned inside
      # the body are nilable in here, and `poll` is what "we never got to a route" means.
      record(store, m, route || AgentDelivery::VIA_POLL, label || session_label, false,
        "delivery raised: #{ex.message || ex.class.name}") rescue nil
    end

    # This session as the operator would recognise it on a delivery row.
    private def session_label : String
      "#{@client.call || "agent"} pid #{@pid}"
    end

    # Is the unconfirmable push the thing to reach for? Only for the client it exists on, and
    # only once the confirmable doors have been tried and did not answer.
    private def channel_route? : Bool
      @channels.call && @client.call == "claude-code"
    end

    # Nothing live took it: the row waits in the feed for `operator_messages` and the
    # tool-result carry. A deposit is not a failure — except when the chain TRIED and was
    # refused, which the operator has to be able to tell apart from a client that simply has
    # no door.
    private def deposit(store : Store, m : AgentMessage, label : String, tried : Array(String)) : Nil
      if tried.empty?
        record(store, m, AgentDelivery::VIA_POLL, label, true, "no live route; left for operator_messages")
      else
        record(store, m, AgentDelivery::VIA_POLL, label, false, "#{tried.join("; ")}; left for operator_messages")
      end
    end

    # This session's Codex thread, asked once per tick. The two tests are in this order on
    # purpose — `client?` is a string comparison and `discover` forks an `lsof`, so every
    # other client pays nothing for this route.
    private def codex_session : CodexQueue::Session?
      return @codex_memo if @codex_asked
      @codex_asked = true
      @codex_memo = CodexQueue.client?(@client.call) ? @codex.call : nil
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
              j.field "content", m.text + OperatorNote::REPLY_HINT
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
