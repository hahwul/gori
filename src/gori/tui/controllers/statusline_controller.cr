require "json"
require "../ansi"
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

    # Run `command` via `/bin/sh -c`, feeding `stdin_json` on stdin, and return the
    # FIRST line of its stdout (styling still embedded). On timeout or spawn failure,
    # return a short marker instead of raising.
    #
    # Both the success and timeout paths converge on a single teardown: close stdout
    # (so a reader fiber blocked in `read` unblocks — critical when the command
    # backgrounds a descendant that keeps the pipe open), kill the child, and reap it
    # on a detached fiber. We deliberately do NOT block this fiber on `process.wait`,
    # so a child still writing more output can never wedge us.
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
        begin
          done.send(read_first_line(output))
        rescue
          done.send("")
        end
      end

      result =
        select
        when line = done.receive
          line
        when timeout(timeout_span)
          "⋯ (timed out)"
        end

      output.close rescue nil # unblock the reader fiber if still in read()
      process.terminate(graceful: false) rescue nil
      spawn(name: "gori-statusline-reap") { process.wait rescue nil } # reap; never zombie
      first_line(result)
    rescue File::NotFoundError | RuntimeError | IO::Error
      "⋯ (statusline failed)"
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

    def initialize(@session : Gori::Session)
      @work_ch = Channel({String, String, Time::Span}).new(1) # {command, ctx_json, timeout}
      @result_ch = Channel(String).new(1)                     # latest-wins raw first line
      @segments = [] of Ansi::Segment
      @running = false     # a run is in flight (guards against overlapping launches)
      @started = false     # the worker fiber has been spawned (lazy — only once enabled)
      @was_enabled = false # last-seen Settings.statusline_enabled? (for the disable edge)
      @last_run = nil.as(Time::Instant?)
    end

    # Called every main-loop tick. Drains a finished result and (re-)launches the
    # command when its interval has elapsed. Returns true if the row changed (→ dirty).
    # Self-gated on Settings.statusline_enabled? so it's a cheap no-op while disabled.
    def tick(now : Time::Instant) : Bool
      enabled = Settings.statusline_enabled?
      # 1. Drain a finished script result (non-blocking). While disabled we still drain
      #    (to clear @running for an in-flight run) but do NOT paint it — so a result
      #    produced after the user disabled can't flash on the next re-enable.
      changed = drain_result(apply: enabled)

      # 2. Enable→disable edge: drop the row immediately. We leave @running as-is — an
      #    in-flight run clears it via drain above when it finishes; resetting it here
      #    would let a re-enable launch a second overlapping run.
      if @was_enabled && !enabled
        changed = true unless @segments.empty?
        @segments = [] of Ansi::Segment
        @last_run = nil
      end
      @was_enabled = enabled
      return changed unless enabled

      # 3. (Re-)launch when idle and the interval has elapsed.
      return changed if @running
      cmd = Settings.statusline_command.strip
      return changed if cmd.empty?
      interval = {Settings.statusline_interval, 1}.max.seconds
      last = @last_run
      return changed unless last.nil? || now - last >= interval

      ensure_started
      ctx = build_context_json
      # Cap the run at the interval so a slow script is killed before the next launch
      # (backs the @running guard so runs can never pile up). Advance @last_run / mark
      # running ONLY on a successful send, so a full channel just retries next tick.
      select
      when @work_ch.send({cmd, ctx, interval})
        @last_run = now
        @running = true
      else
        # worker busy — try again next tick (do not advance @last_run)
      end
      changed
    end

    # Apply a finished script result if one is waiting (non-blocking). Always clears
    # @running so the next run can launch; paints @segments only when `apply` (enabled).
    # Returns true if the row changed. Runs on the main fiber — the only @segments writer.
    private def drain_result(apply : Bool) : Bool
      select
      when line = @result_ch.receive
        @running = false
        if apply
          @segments = Ansi.parse(line)
          return true
        end
        false
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
              j.field "addr", "#{host}:#{port}"
            end
          end
          j.field "upstream", Settings.effective_upstream_proxy
        end
      end
    end
  end
end
