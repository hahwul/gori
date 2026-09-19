require "log"
require "../process_hook"
require "./operator_note"

module Gori::MCP
  # Codex's session queue, as seen from the `gori mcp` process it spawned (#1090 route three).
  #
  # Codex has no inbox socket, but its CLI carries one: `codex queue --thread <id> --message
  # <text>` hands a line to a session that already exists, and the session runs a turn on it —
  # immediately when it is idle, after the current turn when it is not. That is the same
  # promise the Claude inbox socket makes, through a different door, so it carries a message
  # the same way (`AgentDelivery::CARRIED`): the CLI either prints "Queued message …" and
  # exits 0, or it says why not.
  #
  # The hard part is naming the session, because Codex tells an MCP server nothing about
  # itself: the handshake carries only `clientInfo`, `tools/call` only a `progressToken`, and
  # the child's environment is scrubbed of every `CODEX_*` key — `CODEX_HOME` included. What
  # it does do is hold an exclusive writer lock on `<CODEX_HOME>/thread-writer-locks/
  # <thread>.lock` for the life of the thread, and the Codex process is this server's PARENT
  # (`Process.ppid`, verified for `codex exec` and for the interactive TUI). So the open file
  # IS the answer, and it answers both halves at once: the basename is the thread id, and its
  # grandparent directory is the CODEX_HOME to run the CLI against — which matters, because a
  # session started with a non-default `CODEX_HOME` would otherwise be queued into the wrong
  # store, or into nothing at all.
  #
  # A thread with no turn yet has a lock but no rollout, and `codex queue` refuses it ("no
  # rollout found for thread id …"). That is reported, not swallowed: the message stays in the
  # feed for `operator_messages`, which is where a session that has never spoken will read it
  # anyway.
  module CodexQueue
    # The client name Codex introduces itself with at the MCP handshake. Matched by PREFIX,
    # not equality: the route is chosen for a family of clients, and a renamed
    # `codex-mcp-client` should keep working rather than fall silently back to poll.
    CLIENT_PREFIX = "codex"

    # `codex queue` is a local CLI call against a lock this process can already see — it does
    # not wait on the model. Bounded all the same: a courier tick runs beside a live JSON-RPC
    # session, and a CLI that hangs on a stale daemon socket must cost one delivery, not the
    # session.
    TIMEOUT = 10.seconds

    # Listing a process's open files is a fork on macOS; keep it short.
    LSOF_TIMEOUT = 3.seconds

    # `<CODEX_HOME>/thread-writer-locks/<uuid>.lock`. The uuid shape is checked because the id
    # goes onto a command line: this is the one place the value crosses from "a path another
    # process happened to open" into gori's own argv, and a lock file is not a promise about
    # what is in its name.
    LOCK_PATH = %r{\A(?<home>/.+)/thread-writer-locks/(?<thread>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.lock\z}

    # One addressable Codex session: which thread, and the home whose store holds it.
    record Session, thread : String, home : String do
      def label : String
        "codex thread #{thread[0, 8]}"
      end
    end

    # Whether this client's route is the Codex one. Asked before `discover` so the common
    # case — every other client — never forks an `lsof`.
    def self.client?(name : String?) : Bool
      !!name.try(&.downcase.starts_with?(CLIENT_PREFIX))
    end

    # The parent's live thread, or nil when this process's parent is not a Codex session with
    # a thread open (another MCP client, a launcher in between, a Codex that has not opened
    # one yet). Never raises and never caches: a `/new` in the TUI swaps the lock under us,
    # and a remembered thread id would deliver the operator's line into an abandoned thread.
    def self.discover(pid : Int64 = Process.ppid.to_i64) : Session?
      session_in(open_files(pid))
    end

    # The first path that is a thread-writer lock. Split out so a spec can pin the parsing
    # without a Codex on the machine.
    def self.session_in(paths : Enumerable(String)) : Session?
      paths.each do |path|
        if m = LOCK_PATH.match(path)
          return Session.new(m["thread"], m["home"])
        end
      end
      nil
    end

    # Hand one line to the session. `nil` on success, else the reason the operator should
    # read. Never raises, for the courier's sake.
    def self.deliver(session : Session, text : String, *, timeout : Time::Span = TIMEOUT) : String?
      bin = Process.find_executable("codex")
      return "codex is not on this server's PATH" unless bin
      result = ProcessHook.run([bin, "queue", "--thread", session.thread, "--message", text],
        Bytes.empty, timeout: timeout, env: {"CODEX_HOME" => session.home})
      return nil if result.ok?
      # `failure` is "codex: exited 1 — <what codex said>". The child's own words are what
      # make it actionable ("no rollout found for thread id …" is the whole diagnosis), and
      # they are bounded the same way a hook's are.
      result.failure || "codex queue failed"
    rescue ex
      "codex queue failed: #{ex.message || ex.class.name}"
    end

    # Every path the process has open. `/proc` where there is one; `lsof -p … -Fn` elsewhere,
    # which prints one field per line with a leading `n` on the names.
    #
    # An empty list on any failure: not being able to look is the same answer as looking and
    # finding nothing — no Codex route — and the poll backstop is what both fall through to.
    def self.open_files(pid : Int64) : Array(String)
      {% if flag?(:linux) %}
        dir = "/proc/#{pid}/fd"
        return [] of String unless Dir.exists?(dir)
        Dir.children(dir).compact_map do |fd|
          File.readlink(File.join(dir, fd)) rescue nil
        end
      {% else %}
        bin = Process.find_executable("lsof")
        return [] of String unless bin
        result = ProcessHook.run([bin, "-p", pid.to_s, "-Fn"], Bytes.empty, timeout: LSOF_TIMEOUT)
        # NOT `ok?`: lsof exits non-zero when any one of the files it was asked about could not
        # be stat'd, which is ordinary for a process holding sockets and cryptex paths. What it
        # DID print is still the answer; only a spawn failure or a timeout leaves nothing.
        return [] of String if result.spawn_error || result.timed_out
        String.new(result.stdout).each_line.compact_map do |line|
          line.starts_with?("n/") ? line[1..] : nil
        end.to_a
      {% end %}
    rescue ex
      Log.debug(exception: ex) { "mcp: could not list the parent's open files" }
      [] of String
    end
  end
end
