require "json"
require "../ansi"
require "../../bind_address"
require "../../settings"

module Gori::Tui
  # Runs the user's statusline command and turns its stdout into a safe display
  # string. The genuinely new bit here is capturing stdout WITH a timeout — Crystal's
  # `Process.run` has none — so a hung script can never wedge the statusline (or, since
  # this runs on a worker fiber, the UI). Errors map to a short marker, never an
  # exception. Modeled on browser.cr's detached-reap + external_editor.cr's error mapping.
  module Statusline
    # Cap on stdout bytes read from the script. We only render the first line, so we
    # stop at the first newline anyway; this bound also protects against a runaway
    # command (`yes`, `cat /dev/zero`) ballooning memory before the timeout fires.
    MAX_CAPTURE = 64 * 1024

    # How long the empty-output path may wait for the child's exit status before giving
    # up on it. Only reached once stdout has already hit EOF, so in practice the status
    # is there already; the bound just means the pathological child (stdout closed, still
    # alive) costs one short pause rather than wedging the worker.
    STATUS_GRACE = 200.milliseconds

    # Run `command` via `/bin/sh -c`, feeding `stdin_json` on stdin, and return the
    # FIRST line of its stdout (styling still embedded). On timeout, failure or spawn
    # error, return a short marker instead of raising.
    #
    # Every path converges on one teardown: close stdout (so a reader fiber blocked in
    # `read` unblocks — critical when the command backgrounds a descendant that keeps the
    # pipe open), kill the child unless it has already been reaped, and reap it on a
    # detached fiber. This fiber never blocks on a bare `process.wait`, so a child still
    # writing more output can never wedge us.
    def self.run(command : String, stdin_json : String, timeout_span : Time::Span) : String
      process = Process.new("/bin/sh", ["-c", command],
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Close) # discard stderr (browser.cr pattern)
      begin
        process.input.print(stdin_json)
        process.input.flush
      rescue IO::Error
        # child may have exited / closed stdin before reading — ignore
      end
      process.input.close rescue nil

      done = Channel(String).new(1)
      output = process.output
      spawn(name: "gori-statusline-read") do
        done.send(read_first_line(output))
      rescue
        done.send("")
      end

      timed_out = false
      result =
        select
        when line = done.receive
          line
        when timeout(timeout_span)
          timed_out = true
          "⋯ (timed out)"
        end

      line = first_line(result)
      # Empty stdout, and the script ran to completion: ask the exit status what happened.
      # `sh` itself always spawns successfully, so a typo'd command exits 127 having
      # printed nothing — byte-identical on screen to a script that deliberately prints
      # nothing. stderr is discarded (draining a second pipe would need its own reader
      # fiber and its own cap), which leaves the status as the only evidence to show.
      #
      # The wait is spawned HERE, not up front, and that ordering is load-bearing twice
      # over: `Process#wait`'s own `ensure` closes `process.output` and releases the pid,
      # so a wait racing the reader could swallow output that had no trailing newline, and
      # a wait that won the race left the `terminate` below signalling a pid we no longer
      # own. By this point the reader is finished with `output`, and `reaped` tells the
      # teardown to keep its hands off an already-reaped child.
      reaped = false
      status_ch = nil.as(Channel(Process::Status)?)
      if !timed_out && line.empty?
        ch = Channel(Process::Status).new(1)
        status_ch = ch
        spawn(name: "gori-statusline-reap") { ch.send(process.wait) rescue nil }
        select
        when st = ch.receive
          reaped = true
          line = exit_marker(st) unless st.success?
        when timeout(STATUS_GRACE)
          # status not in yet — the fiber above is still in `wait` and will reap it
        end
      end

      output.close rescue nil # unblock the reader fiber if still in read()
      unless reaped
        process.terminate(graceful: false) rescue nil
        # Exactly one `wait` per process, ever: only spawn one when the branch above did not.
        spawn(name: "gori-statusline-reap") { process.wait rescue nil } if status_ch.nil?
      end
      line
    rescue File::NotFoundError | RuntimeError | IO::Error
      "⋯ (statusline failed)"
    end

    # The row shown for a run that produced nothing and failed. Short by necessity — it
    # shares one terminal row with whatever the script would have printed.
    private def self.exit_marker(status : Process::Status) : String
      if code = status.exit_code?
        "⋯ (exit #{code})"
      else
        "⋯ (killed)"
      end
    end

    # Read stdout up to the first newline, bounded by MAX_CAPTURE. Stops early on the
    # newline so a multi-line / streaming command isn't drained in full, and never
    # accumulates more than the cap.
    private def self.read_first_line(io : IO) : String
      mem = IO::Memory.new
      buf = Bytes.new(4096)
      while (n = io.read(buf)) > 0
        chunk = buf[0, n]
        if idx = chunk.index(0x0a_u8) # newline → first line complete
          mem.write(chunk[0, idx])
          break
        end
        room = MAX_CAPTURE - mem.bytesize
        break if room <= 0
        mem.write(room >= n ? chunk : chunk[0, room])
      end
      String.new(mem.to_slice)
    end

    # First line of `s`, without a trailing CR (the statusline is one row). `s` is
    # already at most one line via read_first_line; this also trims the timeout marker.
    private def self.first_line(s : String) : String
      nl = s.index('\n')
      line = nl ? s[0, nl] : s
      line.rchop('\r')
    end
  end

  # Drives the optional bottom statusline. NOT a TabController (no tab) — a plain
  # Runner-owned helper like Jobs/Notifications. The main loop calls `tick(now)` every
  # frame; a single worker fiber does the blocking process I/O and pushes the result
  # back through a latest-wins channel. Everything that touches Session/Store/Settings
  # happens on the main fiber (in `tick`); the worker only touches Process + channels.
  #
  # INVARIANT (mirrors Jobs): @segments / @running / @last_run are mutated ONLY on the
  # main fiber, from `tick`. The worker never touches them.
  class StatuslineController
    getter segments : Array(Ansi::Segment)
    @last_spec : {String, Time::Span, Time::Span}

    def initialize(@session : Gori::Session)
      @work_ch = Channel({String, String, Time::Span}).new(1) # {command, ctx_json, timeout}
      @result_ch = Channel(String).new(1)                     # latest-wins raw first line
      @segments = [] of Ansi::Segment
      @rendered = nil.as(String?) # raw line the row currently shows (nil = nothing painted)
      @running = false            # a run is in flight (guards against overlapping launches)
      @started = false            # the worker fiber has been spawned (lazy — only once active)
      @was_active = false         # last-seen Settings.statusline_active? (for the off edge)
      @discard = false            # drop the in-flight result: it belongs to a superseded run
      @last_run = nil.as(Time::Instant?)
      @last_spec = current_spec # the {command, interval, timeout} the last launch used
    end

    # Called every main-loop tick. Drains a finished result and (re-)launches the
    # command when its interval has elapsed. Returns true if the row changed (→ dirty).
    # Self-gated on Settings.statusline_active? so it's a cheap no-op while off.
    def tick(now : Time::Instant) : Bool
      active = Settings.statusline_active?
      # 1. Drain a finished script result (non-blocking). While off we still drain
      #    (to clear @running for an in-flight run) but do NOT paint it — so a result
      #    produced after the user disabled can't flash on the next re-enable.
      changed = drain_result(apply: active)

      # 2. On→off edge: drop the row immediately. We leave @running as-is — an
      #    in-flight run clears it via drain above when it finishes; resetting it here
      #    would let a re-enable launch a second overlapping run.
      if @was_active && !active
        changed = true unless @segments.empty?
        @segments = [] of Ansi::Segment
        @rendered = nil # so a re-enable repaints even if the output is unchanged
        @last_run = nil
        @discard = true if @running
      end
      @was_active = active
      return changed unless active

      # 3. A settings edit takes effect NOW, not at the end of the current interval. The
      #    row used to keep showing the PREVIOUS command's output for up to a full
      #    interval after the operator saved a new one, with nothing on screen saying so.
      #    An in-flight run belongs to the superseded command, so it is dropped rather
      #    than painted for one interval under the new one.
      spec = current_spec
      if spec != @last_spec
        @last_spec = spec
        @last_run = nil
        @discard = true if @running
      end

      # 4. (Re-)launch when idle and the interval has elapsed.
      return changed if @running
      cmd, interval, timeout_span = spec
      last = @last_run
      return changed unless last.nil? || now - last >= interval

      ensure_started
      ctx = build_context_json
      # The run is capped by its OWN timeout, not by the interval: runs cannot pile up
      # regardless (the @running guard launches one at a time), so a script slower than
      # the refresh rate now renders late instead of never. Advance @last_run / mark
      # running ONLY on a successful send, so a full channel just retries next tick.
      select
      when @work_ch.send({cmd, ctx, timeout_span})
        @last_run = now
        @running = true
      else
        # worker busy — try again next tick (do not advance @last_run)
      end
      changed
    end

    # The live {command, interval, timeout} triple a launch is configured from. Compared
    # against the last launch's to notice a settings edit.
    private def current_spec : {String, Time::Span, Time::Span}
      {Settings.statusline_command.strip,
       {Settings.statusline_interval, 1}.max.seconds,
       {Settings.statusline_timeout, 1}.max.seconds}
    end

    # Apply a finished script result if one is waiting (non-blocking). Always clears
    # @running so the next run can launch; paints @segments only when `apply` (active).
    # Returns true if the row changed. Runs on the main fiber — the only @segments writer.
    private def drain_result(apply : Bool) : Bool
      select
      when line = @result_ch.receive
        @running = false
        if @discard # superseded command / turned off mid-run — this output is stale
          @discard = false
          return false
        end
        return false unless apply
        # Byte-identical to what the row already shows ⇒ NOT dirty. The render loop only
        # repaints when something reports dirty, so returning true unconditionally bought
        # a whole frame that painted not one different cell, once per interval, forever —
        # the exact thing ResourceMeter's idle-zero-CPU invariant exists to prevent.
        return false if @rendered == line
        @rendered = line
        @segments = Ansi.parse(line)
        true
      else
        false
      end
    end

    # Wind down the worker fiber: closing the work channel makes its `receive?` return
    # nil so the loop exits. Safe to call when the fiber was never started.
    def stop : Nil
      @work_ch.close
    rescue Channel::ClosedError
    end

    private def ensure_started : Nil
      return if @started
      @started = true
      spawn(name: "gori-statusline") { worker_loop }
    end

    private def worker_loop : Nil
      loop do
        msg = @work_ch.receive?
        break if msg.nil? # channel closed (stop) → exit
        cmd, ctx, to = msg
        line = Statusline.run(cmd, ctx, to)
        select
        when @result_ch.send(line) # latest-wins
        else
          # main fiber hasn't drained the previous result yet — drop (never happens
          # while runs are serialized, but keeps the worker from ever blocking).
        end
      end
    rescue Channel::ClosedError
    end

    # The JSON context handed to the script on stdin. Built on the MAIN fiber (reads
    # Session/Store), then passed to the worker as an opaque string.
    private def build_context_json : String
      proxy = @session.proxy
      host = proxy.host
      port = proxy.port
      JSON.build do |j|
        j.object do
          j.field "version", 1
          j.field "project", @session.project.name
          j.field "capturing", @session.capturing?
          j.field "flows", @session.store.count
          j.field "proxy" do
            j.object do
              j.field "host", host
              j.field "port", port
              # `authority`, NOT `display`: this is a machine contract a user's script
              # parses, so it keeps the RAW bind semantics (no wildcard→loopback collapse,
              # which would hide a fact the script may want) and only gains the IPv6
              # bracketing an authority string requires — bare interpolation rendered a
              # `::1` bind as the unparseable "::1:8070".
              j.field "addr", BindAddress.authority(host, port)
            end
          end
          # The CATCH-ALL upstream — what a destination matching no rule gets. It cannot be
          # "the upstream" any more: since upstream rules exist, routing is per-destination
          # and there is no single address to report. A script that only read this field
          # would say "direct" for a session sending everything through a SOCKS5 jump host,
          # so the rule count goes out beside it as the signal that per-host routing is live.
          # Additive on purpose — `upstream` keeps its exact v1 meaning for existing scripts.
          j.field "upstream", Settings.effective_upstream_proxy
          j.field "upstream_rules", Settings.upstream_rules.size
        end
      end
    end
  end
end
