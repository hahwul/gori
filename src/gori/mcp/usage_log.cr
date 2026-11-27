require "json"
require "log"
require "../paths"

module Gori
  module MCP
    # What `gori mcp` records about its OWN use, when the operator has switched it on
    # (`Settings.mcp_usage_log?`, off by default): one JSON line per tool call, appended to a
    # single file under `$GORI_HOME`, and read back by `gori mcp --usage`.
    #
    # It exists because nothing else answers "which tools does an agent actually call, where
    # does it go wrong, and how big are the answers". The project's `events` feed logs only
    # the calls that send or write (`Tools#log_agent_action`), cannot be written by a
    # `--read-only` server and is pruned; the presence marker is gone when the process is;
    # the eval harness measures tasks somebody made up.
    #
    # WHAT A LINE MAY HOLD is the whole design. A summary of this file has to be safe to paste
    # into a public issue, so a line carries only text gori itself wrote, plus three strings a
    # peer chose that are cleaned and capped before they land (`client`, `token`):
    #
    #   * a tool's name, and the NAMES of the declared arguments that were passed
    #   * the outcome code gori answered with, and the declared argument it blamed
    #   * the reply's size in bytes and the call's duration
    #
    # Never an argument's VALUE, a reply, a host, a URL, a header or a project's name — and an
    # argument name the tool does not declare is counted, not written, because that slot is
    # the model's free text. Nothing here is ever sent anywhere.
    #
    # Best effort throughout, the presence marker's stance: a line that cannot be written
    # costs one warning and switches the log off for the session. It never fails a tool call.
    class UsageLog
      Log = ::Log.for("mcp")

      # The file is renamed to `<path>.1` (replacing the previous one) once it passes this, so
      # the two together are the bound. At ~150 bytes a line that is some 50,000 calls.
      MAX_BYTES = 4_i64 * 1024 * 1024

      NAME_MAX   =   64 # a tool name nobody declared (`token`)
      CLIENT_MAX =   48 # the handshake's `clientInfo.name` / `.version`
      SPEC_MAX   = 2048 # the operator's own `--tools` spec

      # Written in place of a `--tools` spec longer than `SPEC_MAX`. A spec cut short can
      # still parse, as a SMALLER catalogue than the one that was served, and the report
      # would then count tools as never offered; this parses as nothing, and says why.
      SPEC_TOO_LONG = "(too long)"

      # The `result` written for a call gori refused because the tool is real but this server
      # was started without it (`--tools`). On the wire that is the same -32602 a made-up name
      # gets; here the two are told apart, because "the profile hid a tool the agent wanted"
      # and "the agent invented a tool" are different findings.
      NOT_SERVED   = "NOT_SERVED"
      UNKNOWN_TOOL = "UNKNOWN_TOOL"

      # What the session line says. Built by the server at the first recorded event, by which
      # time a handshake (or the modern revision's per-request `_meta`) has named the client.
      #
      # `denied` is the Preferences permission groups switched off on this server
      # (`Settings::MCP_PERMISSIONS` keys, gori's own words): with `tools` and `read_only` it
      # is everything that decides which tools were in `tools/list`, which is what the report
      # needs to say which of them were never called.
      record Session, client : String?, client_version : String?, tools : String?,
        advertised : Int32, read_only : Bool, denied : Array(String) = [] of String,
        disabled_features : Array(String) = [] of String

      getter path : String

      def initialize(@path : String = Paths.mcp_usage_log, @sid : String = Random::Secure.hex(4),
                     @clock : Proc(Time) = -> { Time.utc })
        @started = false
        @dead = false
        @session = nil.as(Session?)
        @rotation_warned = false
        @written = nil.as(File::Info?)
        @written_end = 0_i64
      end

      # Whether the session line is out. The server asks before each event so the line is
      # written once, lazily: a server that is spawned and never spoken to leaves nothing.
      getter? started : Bool

      def session(s : Session) : Nil
        return if @started
        @started = true
        @session = s
        rotate
        session_line(s)
      end

      private def session_line(s : Session) : Nil
        write("s") { |j| session_fields(j, s) }
      end

      private def session_fields(j : JSON::Builder, s : Session) : Nil
        j.field "gori", Gori::VERSION
        if client = UsageLog.clean(s.client, CLIENT_MAX)
          j.field "client", client
        end
        if version = UsageLog.clean(s.client_version, CLIENT_MAX)
          j.field "client_version", version
        end
        if tools = UsageLog.clean(s.tools, SPEC_MAX + 1)
          j.field "tools", tools.size > SPEC_MAX ? SPEC_TOO_LONG : tools
        end
        j.field "advertised", s.advertised
        j.field "read_only", s.read_only
        j.field "denied", s.denied unless s.denied.empty?
        j.field "disabled_features", s.disabled_features unless s.disabled_features.empty?
      end

      # A `tools/list` answer: what the catalogue cost this session before a question was asked.
      def list(bytes : Int32, tools : Int32) : Nil
        roll
        write("l") do |j|
          j.field "bytes", bytes
          j.field "tools", tools
        end
      end

      # A call that reached a tool. `args` are declared names only and `extra` the number of
      # undeclared ones (see `Tools#usage_args`); `field` is nil unless it is a declared name.
      def call(tool : String, args : Array(String), extra : Int32, result : String,
               field : String?, bytes : Int32, ms : Int64, delivered : Bool) : Nil
        roll
        write("c") do |j|
          j.field "tool", tool
          j.field "args", args
          j.field "extra", extra if extra > 0
          j.field "result", result
          j.field "field", field if field
          j.field "bytes", bytes
          j.field "ms", ms
          j.field "undelivered", true unless delivered
        end
      end

      # A call gori refused before any tool ran, because the name is not one this server
      # serves. `known` is whether it is a real tool the `--tools` filter left out: that name
      # is gori's own and is written as it is, while a name nobody declared is the model's
      # text and is reduced to a `token` first.
      def refused(name : String, known : Bool) : Nil
        roll
        write("c") do |j|
          if known
            j.field "tool", name
            j.field "result", NOT_SERVED
          else
            j.field "unknown", UsageLog.token(name)
            j.field "result", UNKNOWN_TOOL
          end
        end
      end

      # The shape of every code gori answers with. Checked, not assumed, for the one code
      # that is read back out of a reply (`outcome`).
      CODE = /\A[A-Z][A-Z0-9_]{0,47}\z/

      # What a call's line says happened: "ok", or the code it was refused with. The send
      # tools answer a failed send with their own JSON envelope and no `Result#error_code`
      # (`Tools#classify` leaves it be), so for those the code is the envelope's top-level
      # `error_code` — a field gori writes from `Repeater::SendError.code`, and one that is
      # kept only when it has a code's shape. Anything else is the bare "error".
      def self.outcome(is_error : Bool, code : String?, text : String) : String
        return "ok" unless is_error
        code || envelope_code(text) || "error"
      end

      private def self.envelope_code(text : String) : String?
        return nil unless text.starts_with?('{')
        code = JSON.parse(text).as_h?.try(&.["error_code"]?).try(&.as_s?)
        code if code && CODE.matches?(code)
      rescue
        nil
      end

      # A name the model made up, reduced to the alphabet a tool name is spelled in. Whatever
      # else was in it — a path, a sentence, a control character — does not reach the file.
      def self.token(name : String) : String
        kept = name.scrub.downcase.gsub(/[^a-z0-9_]/, "")
        kept.empty? ? "?" : kept[0, NAME_MAX]
      end

      # A string a peer or the operator chose, for a line a human may paste elsewhere: no
      # control characters, single spaces, capped. nil when nothing printable is left.
      def self.clean(text : String?, max : Int32) : String?
        return nil unless text
        kept = text.scrub.gsub(/\p{C}/, "").gsub(/\s+/, " ").strip
        kept.empty? ? nil : kept[0, max]
      end

      # Opened, appended to and closed per line: no descriptor outlives the write, so another
      # server's rotation never leaves this one appending to a file that has been renamed
      # away, and a line is on disk before the next call starts. One `write(2)` under
      # `O_APPEND` per line, which is what keeps several servers' lines whole in one file.
      #
      # The session line goes again in front of this session's first line in a file it has
      # not written to before: one rotated by this server or by ANY other sharing the path,
      # or removed by hand. Only one server wins a rotation, so a session that left it to the
      # rotator would keep appending lines that name no client, and lose its client and
      # profile once the NEXT rotation replaced the only file that named it. The check is on
      # the descriptor being written, so a rename between a `stat` and this `open` cannot
      # slip past it.
      private def write(kind : String, & : JSON::Builder ->) : Nil
        return if @dead
        line = entry(kind) { |j| yield j }
        Dir.mkdir_p(File.dirname(@path))
        File.open(@path, "a", perm: 0o600) do |file|
          now = file.info
          session = @session
          if kind != "s" && session && moved?(now)
            line = "#{entry("s") { |j| session_fields(j, session) }}\n#{line}"
          end
          file.print("#{line}\n")
          file.flush
          @written = now
          @written_end = now.size + line.bytesize + 1
        end
      rescue ex
        # Everything, not `IO::Error` alone: this runs inside a tool call's handler, and an
        # exception that escaped it would cost the client the answer to a call that succeeded.
        @dead = true
        Log.warn { "usage log switched off for this session: cannot write #{@path} (#{ex.message})" }
      end

      private def entry(kind : String, & : JSON::Builder ->) : String
        JSON.build do |j|
          j.object do
            j.field "t", kind
            j.field "at", @clock.call.to_unix
            j.field "sid", @sid
            yield j
          end
        end
      end

      # Whether `now`, the file about to be appended to, is not the one this session last
      # wrote: a different file, or the same identity SMALLER than this session left it (a
      # fresh file that reused a freed inode two rotations on, or one truncated in place).
      # Not caught: a reused inode other servers already grew past this session's offset. That
      # takes two rotations with no line from this session between them, and costs only that
      # file's lines their client name.
      private def moved?(now : File::Info) : Bool
        return false unless last = @written
        !now.same_file?(last) || now.size < @written_end
      end

      # A session that outlives the bound. Asked before every line, at the price of one
      # `stat`: a server an agent keeps for days would otherwise grow the file without limit,
      # since nothing else looks at its size once the session line is out. The fresh file
      # names this session again at its next line (`write`).
      private def roll : Nil
        rotate unless @dead
      end

      # Whether the file was moved aside. The size is read again UNDER the lock: a second
      # server that got here late finds the file already rotated and leaves the fresh one
      # alone, where a check-then-rename would have moved it over the history just saved.
      # The lock is a sidecar, not the log itself, so the file being renamed is one this
      # process does not hold open — and it is never WAITED for: this runs inside a request,
      # and a lock another server holds means that server is doing the rotation.
      private def rotate : Bool
        return false unless oversized?
        File.open("#{@path}.lock", "w", perm: 0o600) do |lock|
          begin
            lock.flock_exclusive(blocking: false)
          rescue IO::Error
            return false
          end
          return false unless oversized?
          File.rename(@path, "#{@path}.1")
          true
        end
      rescue ex
        # Once: the size is asked again before every line, and a rename that cannot happen
        # (a read-only directory) would otherwise say so on every tool call.
        Log.warn { "usage log not rotated: #{ex.message}" } unless @rotation_warned
        @rotation_warned = true
        false
      end

      private def oversized? : Bool
        (File.info?(@path).try(&.size) || 0_i64) > MAX_BYTES
      end

      # The file read back and added up — what `gori mcp --usage` prints. Pure: it takes
      # paths and a cutoff and opens nothing else.
      class Summary
        # One tool's calls inside the window.
        class ToolStat
          property calls = 0
          property errors = 0
          property undelivered = 0
          property extra_args = 0_i64
          # "CODE" or "CODE:argument" => how often.
          getter error_codes = Hash(String, Int32).new(0)
          # A declared argument's name => the calls that passed it.
          getter args = Hash(String, Int32).new(0)
          getter bytes = [] of Int64
          getter ms = [] of Int64
        end

        # A served catalogue as a session described it: the `--tools` spec (nil for the whole
        # catalogue), whether the server was `--read-only`, the permission groups switched off
        # (sorted), and the tab features turned off (sorted).
        alias Profile = {String?, Bool, Array(String), Array(String)}

        getter sessions = 0
        # Sessions in the window that never called a tool.
        getter idle_sessions = 0
        getter clients = Hash(String, Int32).new(0)
        getter profiles = Hash(Profile, Int32).new(0)
        # One `tools/list` answer's size per listing.
        getter catalogue_bytes = [] of Int64
        getter tools = Hash(String, ToolStat).new { |h, k| h[k] = ToolStat.new }
        # A made-up tool name's `token` => how often it was called.
        getter unknown = Hash(String, Int32).new(0)
        # Real tools a server was started without, and how often they were asked for anyway.
        getter not_served = Hash(String, Int32).new(0)

        def empty? : Bool
          sessions == 0
        end

        def calls : Int32
          tools.each_value.sum(&.calls)
        end

        # `<path>.1` first, so the lines stay in the order they were written. A line that will
        # not parse — the tail of a write a kill cut short, a file somebody edited — is
        # skipped, never fatal: this is a report, and the rest of the file is still true.
        def self.read(path : String, since : Time? = nil) : Summary
          summary = new
          cutoff = since.try(&.to_unix)
          {"#{path}.1", path}.each do |file|
            next unless File.file?(file)
            File.each_line(file) { |line| summary.add(line, cutoff) }
          end
          summary.finish
          summary
        rescue ex : IO::Error
          raise Gori::Error.new("cannot read #{path}: #{ex.message}")
        end

        @meta = {} of String => Hash(String, JSON::Any)
        @active = Set(String).new
        @called = Set(String).new

        protected def add(line : String, cutoff : Int64?) : Nil
          row = (JSON.parse(line) rescue nil).try(&.as_h?)
          return unless row
          kind = row["t"]?.try(&.as_s?)
          sid = row["sid"]?.try(&.as_s?)
          return unless kind && sid
          # A session's own line names it for every later line, so it is kept even when it
          # falls before the cutoff: a long session is still that client's session.
          @meta[sid] = row if kind == "s"
          at = row["at"]?.try(&.raw.as?(Int64))
          return if cutoff && (at.nil? || at < cutoff)
          @active << sid
          case kind
          when "l" then int(row, "bytes").try { |b| @catalogue_bytes << b }
          when "c" then add_call(row, sid)
          end
        end

        private def add_call(row : Hash(String, JSON::Any), sid : String) : Nil
          @called << sid
          result = row["result"]?.try(&.as_s?) || "ok"
          if name = row["unknown"]?.try(&.as_s?)
            @unknown[name] += 1
            return
          end
          return unless tool = row["tool"]?.try(&.as_s?)
          if result == NOT_SERVED
            @not_served[tool] += 1
            return
          end
          stat = @tools[tool]
          stat.calls += 1
          stat.undelivered += 1 if row["undelivered"]?.try(&.as_bool?)
          stat.extra_args += int(row, "extra") || 0_i64
          row["args"]?.try(&.as_a?).try(&.each { |a| a.as_s?.try { |n| stat.args[n] += 1 } })
          int(row, "bytes").try { |b| stat.bytes << b }
          int(row, "ms").try { |m| stat.ms << m }
          return if result == "ok"
          stat.errors += 1
          field = row["field"]?.try(&.as_s?)
          stat.error_codes[field ? "#{result}:#{field}" : result] += 1
        end

        protected def finish : Nil
          @sessions = @active.size
          @idle_sessions = (@active - @called).size
          @active.each do |sid|
            meta = @meta[sid]?
            @clients[meta.try(&.["client"]?).try(&.as_s?) || "(unnamed)"] += 1
            next unless meta
            denied = meta["denied"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
            disabled_features = meta["disabled_features"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
            profile = {meta["tools"]?.try(&.as_s?), meta["read_only"]?.try(&.as_bool?) || false,
                       denied.sort!.uniq!, disabled_features.sort!.uniq!}
            @profiles[profile] += 1
          end
        end

        # A count or a size as gori would have written it: an integer from 0 to `Int32::MAX`,
        # or nil. `as_i64?` RAISES on a number that does not fit, and a line in this file is
        # not trusted to be one gori wrote — which is also why the range is checked: these are
        # added up, and a sum that overflows raises too.
        private def int(row : Hash(String, JSON::Any), key : String) : Int64?
          row[key]?.try(&.raw.as?(Int64)).try { |v| v if 0 <= v <= Int32::MAX }
        end

        # The upper median, or nil for no samples.
        def self.median(values : Array(Int64)) : Int64?
          values.empty? ? nil : values.sort[values.size // 2]
        end
      end
    end
  end
end
