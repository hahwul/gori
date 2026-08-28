module Gori
  # An external process as a byte transform: bytes in on stdin, replacement bytes out on
  # stdout (#818).
  #
  # This is gori's whole extension axis. Burp answers "run MY code over these bytes" with
  # BApps/Bambdas, Caido with a JS plugin SDK; gori answers with the UNIX process boundary —
  # language-agnostic, reuses every script the operator already owns, and needs no in-process
  # runtime, no stable ABI and no recompile (P0). Three seams call it and NONE re-implement it
  # (P1/§2): the Rewriter `pipe` op (`rules.cr`), the Decoder chain `exec:` step
  # (`decoder/chain.cr`), and the Probe `exec` custom rule (`probe/custom_rule.cr`).
  #
  # TRUST: a hook runs with the OPERATOR'S OWN privileges. It is not sandboxed, jailed or
  # confined in any way, deliberately — the same trust level a `--config` file, a Rewriter
  # rule or a `body_file` path already has. gori never invents a hook; every one of them is
  # configuration a human wrote and every surface lists it plainly (P4).
  #
  # The four load-bearing invariants, in the order they matter:
  #
  #   1. P6 — NEVER STALL THE DATA PATH. A hard wall-clock timeout is mandatory and is
  #      enforced HERE, not by the caller's good intentions. `run` returns within
  #      `timeout + KILL_GRACE + COLLECT_GRACE` no matter what the child does: it SIGKILLs a
  #      child that overruns, and abandons a pipe that will not close rather than waiting on
  #      it. On timeout, non-zero exit, oversized output or spawn failure the result is NOT
  #      ok?, and every proxy-path caller is contractually required to pass the ORIGINAL bytes
  #      through unchanged and surface `Result#failure` as a non-fatal notice. A wedged hook
  #      costs one message one timeout; it can never cost the proxy a flow.
  #   2. BOUNDED OUTPUT. stdout is capped at MAX_OUTPUT (32 MiB, the same order as
  #      `Decoder::MAX_OUT` and `Codec::ContentDecode::MAX_OUT`) so a runaway child cannot
  #      exhaust memory. Overrunning it is a FAILURE, not a truncation: half a body is
  #      corruption, and P7 says the original octets win over a mangled derivative.
  #   3. NO SHELL. `argv` is exec'd directly (`Process.new(cmd, args, shell: false)`). There is
  #      no `sh -c` anywhere on this path, so operator payloads flowing through a hook's
  #      arguments are never shell-interpreted — no globbing, no word splitting, no `$(…)`, no
  #      `;`/`&&`/redirection. `parse_argv` below is the tokenizer, and it is deliberately NOT
  #      a shell.
  #   4. P7 — the hook sees the raw captured octets and its stdout is taken as raw octets.
  #      gori does not decode, re-encode, scrub or validate UTF-8 around it.
  module ProcessHook
    # stdout ceiling for one hook run. See invariant 2.
    MAX_OUTPUT = 32 * 1024 * 1024

    # stderr ceiling. Small on purpose: stderr is only ever read to put a REASON in a notice,
    # never to produce data, so a child that scribbles megabytes there gets its diagnostic
    # truncated rather than gori's memory.
    MAX_STDERR = 4096

    # How much of the child's stderr a notice is allowed to carry.
    STDERR_IN_NOTICE = 200

    # The default wall-clock budget for one run. Five seconds is long enough for a JWT
    # re-signer or a recompressor and short enough that a wedged hook is an annoyance rather
    # than an outage. Overridable per call, and per install through
    # `Settings.hook_timeout_secs`.
    DEFAULT_TIMEOUT = 5.seconds

    # The ceiling an operator-supplied timeout is clamped to. P6 is not negotiable by
    # configuration: whatever settings.json says, a hook cannot hold a message longer than
    # this.
    MAX_TIMEOUT = 60.seconds

    # After SIGKILL, how long `wait` is given to reap. SIGKILL cannot be blocked, so this only
    # ever expires when the child has forked something that inherited the process group — and
    # even then `run` returns instead of waiting.
    KILL_GRACE = 2.seconds

    # After the child is gone, how long the stdout/stderr pumps are given to hand over what
    # they read. Same reasoning as KILL_GRACE: a grandchild holding the write end open must
    # not become gori's problem.
    COLLECT_GRACE = 2.seconds

    # What one run produced. `command` rides along so `failure` can NAME the hook without
    # every caller re-deriving the sentence — the notice the Rewriter writes to the event
    # feed, the one the Decoder puts in a PIPELINE row and the one the Probe reports are the
    # same words about the same fact (P1).
    record Result,
      command : String,
      status : Int32,
      stdout : Bytes,
      stderr : String,
      timed_out : Bool,
      truncated : Bool,
      spawn_error : String? do
      # Whether `stdout` may be used. Every other answer means the caller passes the ORIGINAL
      # bytes through — see invariant 1. Note that a non-zero exit is NOT ok? here; the Probe
      # `exec` rule reads the exit code as a verdict and therefore looks at `status` directly
      # rather than at this.
      def ok? : Bool
        @spawn_error.nil? && !@timed_out && !@truncated && @status == 0
      end

      # Why it is not ok?, as the one sentence every surface shows — or nil when it is.
      def failure : String?
        return nil if ok?
        reason =
          if e = @spawn_error
            e
          elsif @timed_out
            "timed out"
          elsif @truncated
            "wrote more than #{MAX_OUTPUT} bytes to stdout"
          else
            "exited #{@status}"
          end
        tail = @stderr.presence
        tail ? "#{@command}: #{reason} — #{tail}" : "#{@command}: #{reason}"
      end

      # A run that never started. Kept as a constructor so the failure sentence for "could not
      # spawn" is built in exactly one place.
      def self.spawn_failed(command : String, message : String) : Result
        new(command, -1, Bytes.empty, "", false, false, message)
      end
    end

    # Tokenize an operator's command line into argv. NOT a shell, and the difference is the
    # whole security property (invariant 3): whitespace splits, `'…'` is literal, `"…"` honours
    # `\"` and `\\`, and a bare `\` escapes the next character. Nothing else means anything —
    # `$FOO`, `*`, `` ` ``, `;`, `&&`, `>` and `|` are ordinary characters that land in an argv
    # element verbatim and are handed to `execvp` as data.
    #
    # Returns the argv, or a String naming what is wrong with the spec. The union is the shape
    # `DisplayColumns.parse_spec` already uses for "parse or say why", and the reason both
    # exist: every write surface validates BEFORE persisting, so a rule that could never run is
    # refused at the editor rather than silently doing nothing on the wire.
    def self.parse_argv(spec : String) : Array(String) | String
      argv = [] of String
      cur = String::Builder.new
      has_cur = false
      quote = nil.as(Char?)
      escape = false
      spec.each_char do |c|
        if escape
          cur << c
          has_cur = true
          escape = false
          next
        end
        case quote
        when '\''
          c == '\'' ? (quote = nil) : (cur << c)
          has_cur = true
        when '"'
          if c == '"'
            quote = nil
          elsif c == '\\'
            escape = true
          else
            cur << c
          end
          has_cur = true
        else
          case c
          when '\'', '"'
            quote = c
            has_cur = true
          when '\\'
            escape = true
          when ' ', '\t', '\n', '\r'
            if has_cur
              argv << cur.to_s
              cur = String::Builder.new
              has_cur = false
            end
          else
            cur << c
            has_cur = true
          end
        end
      end
      argv << cur.to_s if has_cur
      argv_problem(argv, quote, escape) || argv
    end

    # What is wrong with a finished tokenization, or nil when nothing is. Split out of
    # `parse_argv` so the state machine above reads as a state machine.
    private def self.argv_problem(argv : Array(String), quote : Char?, escape : Bool) : String?
      return "unterminated #{quote == '\'' ? "single" : "double"} quote" if quote
      return "trailing backslash" if escape
      return "no command" if argv.empty?
      return "the command is empty" if argv[0].empty?
      # A NUL cannot survive `execvp` (the C string ends there), so an argv element carrying
      # one would reach the child TRUNCATED — a different command than the one the operator
      # read back in the editor. Refuse it here rather than run something else.
      return "argument contains a NUL byte" if argv.any?(&.includes?('\0'))
      nil
    end

    # The argv, or nil when the spec cannot be tokenized. For the run paths, which have already
    # been validated at the write surface and only need the happy answer.
    def self.argv?(spec : String) : Array(String)?
      out = parse_argv(spec)
      out.is_a?(Array) ? out : nil
    end

    def self.valid_argv?(spec : String) : Bool
      parse_argv(spec).is_a?(Array)
    end

    # How a command is NAMED in a notice: argv[0] alone, so a rule whose arguments carry a
    # captured token does not put that token in an event row the operator's next `list_events`
    # hands to an agent.
    def self.command_label(argv : Array(String)) : String
      argv.first? || "(empty)"
    end

    # Run `argv` with `stdin` on its standard input and collect its standard output.
    #
    # Returns within `timeout + KILL_GRACE + 2 × COLLECT_GRACE` under every failure mode this
    # can reach — that bound IS the P6 contract (see invariant 1). Never raises: a spawn failure
    # (ENOENT, EACCES, a path that is a directory) comes back as `Result#spawn_error`, because
    # a raise on the proxy path would drop the operator's flow over a typo in a rule.
    #
    # `env` is MERGED over the inherited environment (`clear_env: false`) — a hook is the
    # operator's own script and expects its own PATH, HOME and terminal settings; the GORI_*
    # keys the seams add are context on top of that, not a replacement for it.
    def self.run(argv : Array(String), stdin : Bytes,
                 timeout : Time::Span = DEFAULT_TIMEOUT,
                 env : Hash(String, String)? = nil) : Result
      label = command_label(argv)
      return Result.spawn_failed(label, "no command") if argv.empty?
      timeout = DEFAULT_TIMEOUT if timeout <= Time::Span.zero
      timeout = MAX_TIMEOUT if timeout > MAX_TIMEOUT

      process =
        begin
          Process.new(argv[0], argv[1..], env: env, clear_env: false, shell: false,
            input: Process::Redirect::Pipe,
            output: Process::Redirect::Pipe,
            error: Process::Redirect::Pipe)
        rescue ex : Exception
          # `Process.new` raises for ENOENT/EACCES/EISDIR and for a fork that fails outright.
          return Result.spawn_failed(label, spawn_message(ex))
        end

      out_ch, err_ch, wait_ch = start_pumps(process, stdin)
      status, timed_out = await(process, wait_ch, timeout)
      captured, truncated = collect(out_ch, {Bytes.empty, false})
      err = collect(err_ch, "")

      process.close rescue nil

      code = timed_out ? -1 : (status.try(&.exit_code?) || -1)
      err = err[0, STDERR_IN_NOTICE] if err.size > STDERR_IN_NOTICE
      Result.new(label, code, captured, err, timed_out, truncated, nil)
    end

    # The three fibers that keep the child from deadlocking on a full pipe: one writing stdin,
    # one draining stdout, one draining stderr — plus the one that reaps. Every channel is
    # BUFFERED to capacity 1, which is what lets `run` walk away from a pump that has not
    # finished: its `send` completes into the buffer and the fiber ends, instead of parking
    # forever on a receiver that already returned.
    private def self.start_pumps(process : Process,
                                 stdin : Bytes) : {Channel({Bytes, Bool}), Channel(String), Channel(Process::Status)}
      out_ch = Channel({Bytes, Bool}).new(1)
      err_ch = Channel(String).new(1)
      wait_ch = Channel(Process::Status).new(1)

      # stdin. A hook that ignores its input closes the pipe and this write gets EPIPE — which
      # is ORDINARY, not an error worth reporting, so it is swallowed. `ensure` closes so a
      # child blocked on reading to EOF is released even when the write fails halfway.
      spawn(name: "hook-stdin") do
        process.input.write(stdin) unless stdin.empty?
      rescue
        # child closed stdin / already gone
      ensure
        process.input.close rescue nil
      end

      # stdout, capped. Overrunning the cap KILLS the child: continuing to drain a runaway
      # producer for the rest of the timeout would hold the message hostage for output that is
      # going to be discarded anyway.
      spawn(name: "hook-stdout") do
        out_ch.send(drain(process.output, MAX_OUTPUT) { process.terminate(graceful: false) rescue nil })
      end

      spawn(name: "hook-stderr") do
        bytes, _ = drain(process.error, MAX_STDERR) { }
        err_ch.send(String.new(bytes).scrub.gsub(/\s+/, " ").strip)
      end

      spawn(name: "hook-wait") { wait_ch.send(process.wait) }
      {out_ch, err_ch, wait_ch}
    end

    # Wait for the child, killing it at `timeout`. Answers {status, timed out?} — a nil status
    # means even the reap after SIGKILL did not land inside KILL_GRACE, which only a grandchild
    # holding the process group can cause. `run` returns anyway; the data path is not the place
    # to wait for someone else's orphan.
    private def self.await(process : Process, wait_ch : Channel(Process::Status),
                           timeout : Time::Span) : {Process::Status?, Bool}
      select
      when st = wait_ch.receive
        return {st, false}
      when timeout(timeout)
        process.terminate(graceful: false) rescue nil
      end
      select
      when st = wait_ch.receive
        {st, true}
      when timeout(KILL_GRACE)
        {nil, true}
      end
    end

    # Take what a pump read, or `fallback` if it cannot hand it over inside COLLECT_GRACE.
    private def self.collect(ch : Channel(T), fallback : T) : T forall T
      select
      when v = ch.receive
        v
      when timeout(COLLECT_GRACE)
        fallback
      end
    end

    # Read at most `cap` bytes, answering {bytes, overran?}. Reads one byte past the cap on
    # purpose: that is how "exactly at the cap" is told from "more was coming". `on_overrun`
    # fires once, before the drain stops.
    private def self.drain(io : IO, cap : Int32, &on_overrun : -> _) : {Bytes, Bool}
      buf = IO::Memory.new
      chunk = Bytes.new(64 * 1024)
      overran = false
      begin
        loop do
          n = io.read(chunk)
          break if n == 0
          buf.write(chunk[0, n])
          if buf.bytesize > cap
            overran = true
            on_overrun.call
            break
          end
        end
      rescue
        # The pipe was closed under us (a kill, or `process.close` after a grace expiry). What
        # was read so far is still what was read.
      end
      {buf.to_slice[0, {buf.bytesize, cap}.min], overran}
    end

    # `Process.new`'s exception, phrased for an operator rather than for a stack trace. The
    # common ones by far are "the path is wrong" and "it is not executable", and the raw
    # `Error initializing process: …` prefix buries both.
    private def self.spawn_message(ex : Exception) : String
      msg = (ex.message || ex.class.name).gsub(/\s+/, " ").strip
      msg = msg.sub(/\AError (initializing|executing) process:?\s*/i, "")
      "could not run it (#{msg})"
    end
  end
end
