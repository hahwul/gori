require "uuid"
require "./event"
require "./backend"
require "./transcript"
require "./mcp_config"
require "../stderr_tail"
require "../store"

module Gori::Agent
  # One hosted agent process and everything gori knows about it (#1093): the child, the
  # fibers that pump it, the conversation, and the store rows that mirror it.
  #
  # STATE. `Starting` for the instant between `Process.new` and the first `Idle` (there is
  # no handshake to wait for — `-p --input-format stream-json` says nothing until it is sent
  # a turn); `Idle` between turns; `Running` from `send` until the `result` frame; `Dead`
  # once the child is gone or refused to start. "Awaiting permission" is NOT a state: it is
  # `running? && !pending.empty?`, derived from the queue, because the CLI can hold several
  # tool calls at once (parallel `tool_use` blocks) and a single flag would lose one.
  #
  # FIBERS, and who owns what — the invariant `StatuslineController` states for itself:
  #   - the MAIN fiber owns every readable field (`state`, `transcript`, `pending`, cost,
  #     the store id) and every store write. It touches them only inside `drain`, `send`,
  #     `answer_permission`, `interrupt`, `stop` and `restart`, all of which the tick or a
  #     verb calls. Nothing below reads them.
  #   - the WRITER fiber is the only writer of `process.input`, fed by a bounded channel of
  #     complete frames. The main fiber enqueues WITHOUT blocking: a child that stopped
  #     reading fills the channel and the session goes Dead, rather than the UI parking on
  #     a full pipe.
  #   - the READER fiber is the only reader of `process.output`: a bounded byte loop
  #     (never `each_line`, which has no ceiling) that hands `Event`s to a bounded channel.
  #     Blocking there when the UI is behind is correct backpressure on the child. What
  #     matters is that it is UNBLOCKABLE at teardown, two ways: closing `process.output`
  #     releases a parked `read`, closing the event channel releases a parked `send`.
  #   - the STDERR fiber drains `process.error` into a capped tail, read once for the dead
  #     band's reason.
  #   - the TEARDOWN fiber is detached and owns the kill ladder (`stop`), so the caller
  #     never waits on a child. Exactly one `Process#wait` per process, ever, and it is the
  #     reader's, after EOF — `wait`'s own `ensure` closes `process.output`, so it must come
  #     after the reader is done with it.
  #
  # PERSISTENCE is write-through on message boundaries. Streamed deltas are never stored
  # (the `assistant` frame that follows is the durable record), and the in-memory transcript
  # is authoritative: the tab must not reload it from the store on a peer's `data_version`
  # bump, because same-process writer visibility through that pragma is flaky and a reload
  # could truncate the in-flight turn.
  class Session
    enum State
      Starting
      Idle
      Running
      Dead
    end

    # Bytes one stdout line may carry before it is cut and surfaced as `Event::Raw`. A
    # base64 `tool_result` can be enormous; the transcript row it would become is capped
    # anyway (`Transcript::MAX_MESSAGE_BYTES`), so reading a megabyte and keeping a quarter
    # of it is already generous.
    MAX_LINE = 1024 * 1024

    # Stderr kept for the dead band. Small: it is a reason, not a log.
    STDERR_CAP = 4096

    # Outbound frames waiting on the writer fiber. A user turn, a permission answer and an
    # interrupt are each one frame; sixty-four unread means the child is not reading.
    OUT_QUEUE = 64

    # Events waiting on the main fiber. Deltas arrive many per second; a tick drains at
    # most `DRAIN_CAP` so a chatty turn cannot starve the render.
    EVENT_QUEUE = 1024
    DRAIN_CAP   =  512

    # `stop`: how long the child gets to exit on its own after stdin closes (the documented
    # clean end of a stream-json session), then after SIGTERM, before the next rung.
    EXIT_GRACE = 1.second
    TERM_GRACE = 300.milliseconds

    # `interrupt`: how long to wait for the `result` the CLI owes an interrupt before
    # treating the child as wedged and stopping it.
    INTERRUPT_GRACE = 5.seconds

    getter state : State
    getter transcript : Transcript
    # `PermissionAsked` events not yet answered, oldest first.
    getter pending : Array(Event::PermissionAsked)
    # Tools the operator allowed for the life of this session. See `Decision::AllowForSession`.
    getter session_allow : Set(String)
    getter session_uuid : String
    getter model : String
    getter capabilities : Array(String)
    getter dead_reason : String
    getter cost_usd : Float64
    getter turns : Int32
    # The `agent_sessions` row this conversation lives in, once the first turn created it.
    getter store_id : Int64?
    getter stderr : StderrTail

    def initialize(@backend : Backend, @config : Config, @store : Store?,
                   *, resume_uuid : String? = nil, store_id : Int64? = nil)
      @state = State::Dead
      @transcript = Transcript.new
      @pending = [] of Event::PermissionAsked
      @session_allow = Set(String).new
      @session_uuid = UUID.random.to_s
      @resume_uuid = resume_uuid
      @store_id = store_id
      @model = ""
      @capabilities = [] of String
      @dead_reason = "not started"
      @cost_usd = 0.0
      @turns = 0
      @stderr = StderrTail.new(STDERR_CAP)
      @process = nil.as(Process?)
      @events = Channel(Event::Any).new(EVENT_QUEUE)
      @outbox = Channel(String).new(OUT_QUEUE)
      @turn_seen_init = false
      @interrupt_deadline = nil.as(Time::Instant?)
      @stopping = false
    end

    # ---- predicates ------------------------------------------------------------------

    def running? : Bool
      @state.running?
    end

    def idle? : Bool
      @state.idle?
    end

    def dead? : Bool
      @state.dead?
    end

    def alive? : Bool
      @state.idle? || @state.running? || @state.starting?
    end

    def awaiting_permission? : Bool
      running? && !@pending.empty?
    end

    # Whether the child advertised the receipt an `interrupt` frame depends on.
    def can_interrupt? : Bool
      @capabilities.includes?("interrupt_receipt_v1")
    end

    # ---- lifecycle -------------------------------------------------------------------

    # Spawn the child. false when it could not start; `dead_reason` says why (the common
    # case is `claude` not on PATH), and the tab draws guidance rather than a crash. The
    # raise is caught HERE, at the spawn site, so it never reaches the tick's own rescue.
    def start : Bool
      mcp = McpConfig.write(@config.db_path, @config.mcp_read_only)
      argv = @backend.argv(@config, @session_uuid, @resume_uuid, mcp)
      process =
        begin
          Process.new(argv[0], argv[1..], shell: false, chdir: @config.cwd,
            input: Process::Redirect::Pipe, output: Process::Redirect::Pipe,
            error: Process::Redirect::Pipe)
        rescue ex : Exception
          die(spawn_message(argv[0], ex))
          return false
        end
      @process = process
      @state = State::Starting
      @dead_reason = ""
      @stopping = false
      @events = Channel(Event::Any).new(EVENT_QUEUE)
      @outbox = Channel(String).new(OUT_QUEUE)
      @stderr = StderrTail.new(STDERR_CAP)
      spawn_writer(process, @outbox)
      spawn_reader(process, @events)
      spawn_stderr(process, @stderr)
      @state = State::Idle
      true
    end

    # Start over with a fresh child. `resume` continues the conversation the previous child
    # held (`--resume <its uuid>`) — a fresh `--session-id` every spawn, because the CLI
    # refuses a reused one — and keeps this session's store row; otherwise a new
    # conversation begins in a new row.
    def restart(resume : Bool) : Bool
      stop unless dead?
      previous = @session_uuid
      @resume_uuid = resume ? previous : nil
      @session_uuid = UUID.random.to_s
      unless resume
        @store_id = nil
        @transcript = Transcript.new
        @cost_usd = 0.0
        @turns = 0
      end
      @pending.clear
      @turn_seen_init = false
      @interrupt_deadline = nil
      ok = start
      if ok && resume && (id = @store_id) && (store = @store)
        store.update_agent_session(id, session_uuid: @session_uuid, resumed_from: previous)
      end
      ok
    end

    # A user turn. false when the session cannot take one (dead, or a turn is running —
    # the CLI serialises turns, and queueing a second one silently would surprise).
    def send(text : String) : Bool
      return false unless idle?
      return false if text.strip.empty?
      ensure_store_row(text)
      persist(@transcript.append("user", "text", text, created_at: now_us))
      @state = State::Running
      @turn_seen_init = false
      enqueue(@backend.user_turn(text))
    end

    # Answer a held tool call. Unknown ids are ignored (already answered, or the child died
    # with it — `drain` wrote the error row).
    def answer_permission(request_id : String, decision : Decision) : Nil
      idx = @pending.index { |p| p.request_id == request_id }
      return unless idx
      req = @pending.delete_at(idx)
      allow = !decision.deny?
      @session_allow << req.tool if decision.allow_for_session?
      note =
        case decision
        in .allow?             then "allowed #{req.tool}"
        in .allow_for_session? then "allowed #{req.tool} for this session"
        in .deny?              then "denied #{req.tool}"
        end
      persist(@transcript.append("system", "permission", note, created_at: now_us,
        tool_name: req.tool, tool_use_id: req.tool_use_id))
      enqueue(@backend.permission_response(req.request_id, allow, req.input_json,
        allow ? nil : "denied by the operator in gori"))
    end

    # Cancel the running turn. The CLI answers with an error `result` (an ordinary
    # `TurnDone`); a child that never does is stopped at `INTERRUPT_GRACE`. false when there
    # is nothing to interrupt or the child cannot take the frame.
    def interrupt : Bool
      return false unless running?
      return false unless can_interrupt?
      @interrupt_deadline = Time.instant + INTERRUPT_GRACE
      enqueue(@backend.interrupt("gori-#{UUID.random}"))
    end

    # Tear the child down without ever blocking the caller. Marks the session dead at once;
    # the ladder runs on its own fiber: stdin EOF (the clean end) → EXIT_GRACE → SIGTERM →
    # TERM_GRACE → SIGKILL → close stdout so a parked reader wakes.
    def stop : Nil
      process = @process
      return unless process
      @stopping = true
      die("stopped") unless dead?
      @process = nil
      outbox = @outbox
      events = @events
      outbox.close rescue nil
      spawn(name: "gori-agent-stop") do
        process.input.close rescue nil
        exited = wait_exit(process, EXIT_GRACE)
        unless exited
          signal_live(process, graceful: true)
          exited = wait_exit(process, TERM_GRACE)
          signal_live(process, graceful: false) unless exited
        end
        process.output.close rescue nil
        process.error.close rescue nil
        events.close rescue nil
      end
    end

    # ---- the tick -------------------------------------------------------------------

    # Apply what the child said since the last tick. MAIN FIBER ONLY. true when anything
    # the tab draws changed. Bounded by DRAIN_CAP; the rest waits for the next tick.
    def drain : Bool
      changed = false
      n = 0
      while n < DRAIN_CAP
        ev = @events.receive?
        break if ev.nil?
        apply(ev)
        changed = true
        n += 1
      end
      # `Channel#receive?` returns nil on a CLOSED channel too, and a closed channel means
      # the reader is gone — but the reader closes it only after sending Exited, so the
      # Exited was applied above. Nothing to do here.
      if (deadline = @interrupt_deadline) && Time.instant >= deadline
        @interrupt_deadline = nil
        if running?
          die("interrupt ignored; child stopped")
          stop
          changed = true
        end
      end
      changed
    end

    # ---- internals: applying events --------------------------------------------------

    private def apply(ev : Event::Any) : Nil
      case ev
      in Event::TurnStarted
        # Every turn repeats it; only the first of a turn is news, and never a reset.
        @model = ev.model unless ev.model.empty?
        @capabilities = ev.capabilities unless ev.capabilities.empty?
        return if @turn_seen_init
        @turn_seen_init = true
        if (id = @store_id) && (store = @store) && !ev.model.empty?
          store.update_agent_session(id, model: ev.model)
        end
      in Event::TextDelta
        @transcript.push_delta(ev.text)
      in Event::ThinkingDelta
        # nothing to show; the tail already reads as "working"
      in Event::AssistantText
        persist(@transcript.append("assistant", "text", ev.text, created_at: now_us))
      in Event::ToolUse
        @transcript.clear_tail
        persist(@transcript.append("assistant", "tool_use", ev.name, payload: ev.input_json,
          created_at: now_us, tool_name: ev.name, tool_use_id: ev.id))
      in Event::ToolResult
        persist(@transcript.append("tool", "tool_result", ev.content, created_at: now_us,
          tool_use_id: ev.tool_use_id, is_error: ev.is_error))
      in Event::PermissionAsked
        if @session_allow.includes?(ev.tool)
          # Answered here, not by the controller: the grant is this session's own memory.
          persist(@transcript.append("system", "permission", "allowed #{ev.tool} (session grant)",
            created_at: now_us, tool_name: ev.tool, tool_use_id: ev.tool_use_id))
          enqueue(@backend.permission_response(ev.request_id, true, ev.input_json, nil))
        elsif @config.permission_policy == "deny"
          persist(@transcript.append("system", "permission", "denied #{ev.tool} (policy)",
            created_at: now_us, tool_name: ev.tool, tool_use_id: ev.tool_use_id))
          enqueue(@backend.permission_response(ev.request_id, false, nil, "denied by gori's permission policy"))
        else
          @pending << ev
        end
      in Event::TurnDone
        @transcript.clear_tail
        @interrupt_deadline = nil
        @cost_usd = ev.cost_usd if ev.cost_usd > 0
        @turns += 1
        if ev.subtype != "success" && !ev.text.empty?
          persist(@transcript.append("system", "error", "#{ev.subtype}: #{ev.text}", created_at: now_us))
        elsif ev.subtype != "success"
          persist(@transcript.append("system", "error", ev.subtype, created_at: now_us))
        end
        persist(@transcript.append("system", "result", "", created_at: now_us))
        if (id = @store_id) && (store = @store)
          store.update_agent_session(id, cost_usd: @cost_usd, turns: @turns)
        end
        @state = State::Idle if running?
      in Event::Raw
        persist(@transcript.append("system", "raw", ev.line, created_at: now_us, truncated: ev.truncated))
      in Event::Exited
        die(ev.reason) unless dead? && @stopping
        @dead_reason = ev.reason if @dead_reason.empty?
      end
    end

    # Go Dead: the reason, the orphaned permission requests (a `control_request` nobody
    # answers wedges the CLI forever, so each gets a row that says why the tool never ran),
    # and the store row's end time.
    private def die(reason : String) : Nil
      @state = State::Dead
      @dead_reason = reason
      @transcript.clear_tail
      unless @pending.empty?
        @pending.each do |p|
          persist(@transcript.append("system", "error",
            "#{p.tool} was waiting for permission when the agent exited", created_at: now_us,
            tool_name: p.tool, tool_use_id: p.tool_use_id))
        end
        @pending.clear
      end
      persist(@transcript.append("system", "error", "agent exited: #{reason}", created_at: now_us)) unless reason == "stopped"
      if (id = @store_id) && (store = @store)
        store.finish_agent_session(id)
      end
    end

    # ---- internals: the pipes ---------------------------------------------------------

    # Non-blocking. A full outbox means the child stopped reading its stdin; that is a dead
    # child from the operator's point of view, and the UI must not wait to find out.
    private def enqueue(frame : String) : Bool
      return false if dead?
      select
      when @outbox.send(frame)
        true
      else
        die("child not reading its input")
        stop
        false
      end
    rescue Channel::ClosedError
      false
    end

    private def spawn_writer(process : Process, outbox : Channel(String)) : Nil
      spawn(name: "gori-agent-writer") do
        while frame = outbox.receive?
          process.input << frame << '\n'
          process.input.flush
        end
      rescue IO::Error
        # EPIPE: the child is gone; the reader's EOF carries the Exited that reports it.
      end
    end

    # Bounded byte loop: split on 0x0a, cap a line at MAX_LINE (the excess is discarded and
    # the head surfaced as a truncated Raw), scrub every decode so a cut multi-byte sequence
    # never raises. EOF → the one `wait` → Exited → close the channel.
    private def spawn_reader(process : Process, events : Channel(Event::Any)) : Nil
      stderr = @stderr
      spawn(name: "gori-agent-reader") do
        io = process.output
        buf = Bytes.new(65536)
        line = IO::Memory.new
        overflow = false
        begin
          while (n = io.read(buf)) > 0
            chunk = buf[0, n]
            while (idx = chunk.index(0x0a_u8))
              take = chunk[0, idx]
              chunk = chunk + (idx + 1)
              if overflow
                overflow = false
                emit(events, Event::Raw.new(String.new(line.to_slice).scrub, true))
                line.clear
                next
              end
              line.write(take)
              text = String.new(line.to_slice).scrub
              line.clear
              @backend.parse(text).each { |ev| emit(events, ev) }
            end
            next if chunk.empty? || overflow
            room = MAX_LINE - line.bytesize
            if chunk.bytesize > room
              line.write(chunk[0, {room, 0}.max])
              overflow = true
            else
              line.write(chunk)
            end
          end
          if line.bytesize > 0
            emit(events, Event::Raw.new(String.new(line.to_slice).scrub, overflow))
          end
        rescue IO::Error
          # stdout closed under us by `stop`; the wait below still reports the exit
        end
        status = process.wait rescue nil
        emit(events, Event::Exited.new(status, exit_reason(status, stderr)))
        events.close rescue nil
      end
    end

    private def spawn_stderr(process : Process, tail : StderrTail) : Nil
      spawn(name: "gori-agent-stderr") do
        buf = Bytes.new(4096)
        while (n = process.error.read(buf)) > 0
          tail << buf[0, n]
        end
      rescue IO::Error
      end
    end

    private def emit(events : Channel(Event::Any), ev : Event::Any) : Nil
      events.send(ev)
    rescue Channel::ClosedError
      # torn down while parked; nothing is listening
    end

    # Spawned by `stop` only. One wait per process — the READER owns it — so this waits on
    # `terminated?` instead, which reads the SIGCHLD bookkeeping rather than probing the pid.
    private def wait_exit(process : Process, grace : Time::Span) : Bool
      deadline = Time.instant + grace
      until process.terminated?
        return false if Time.instant >= deadline
        sleep 20.milliseconds
      end
      true
    end

    # `terminate`, but only at a pid we still own — see `Statusline.signal_live` for why an
    # unguarded late signal is a signal to whoever now holds the number.
    private def signal_live(process : Process, *, graceful : Bool) : Nil
      process.terminate(graceful: graceful) unless process.terminated?
    rescue
    end

    private def exit_reason(status : Process::Status?, stderr : StderrTail) : String
      tail = Transcript.first_line(stderr.text.strip)
      return tail unless tail.empty?
      return "exited" unless status
      if status.normal_exit?
        code = status.exit_code
        code == 0 ? "exited" : "exit #{code}"
      else
        "killed by #{status.exit_signal}"
      end
    end

    private def spawn_message(command : String, ex : Exception) : String
      case ex
      when File::NotFoundError     then "#{command}: not found"
      when File::AccessDeniedError then "#{command}: permission denied"
      else                              "#{command}: #{ex.message || ex.class.name}"
      end
    end

    # ---- internals: the store ---------------------------------------------------------

    private def ensure_store_row(first_text : String) : Nil
      return if @store_id
      store = @store
      return unless store
      title = Transcript.first_line(first_text)[0, 120]
      id = store.insert_agent_session(@session_uuid, @backend.name, @model.presence, title,
        resumed_from: @resume_uuid)
      @store_id = id if id > 0
    end

    private def persist(m : Message) : Nil
      id = @store_id
      store = @store
      return unless id && store
      store.insert_agent_message(id, m.seq, m.role, m.kind, m.text, payload: m.payload,
        truncated: m.truncated?)
    end

    private def now_us : Int64
      (Time.utc - Time::UNIX_EPOCH).total_microseconds.to_i64
    end
  end
end
