require "option_parser"
require "json"
require "base64"
require "../config"
require "../paths"
require "../settings"
require "../env"
require "../app"
require "../store"
require "../project"
require "../project_registry"
require "../ql"
require "../scope"
require "../host_overrides"
require "../sitemap"
require "../proxy/codec/content_decode"
require "../repeater/engine"
require "../repeater/h2_engine"
require "../repeater/ws_engine"
require "../repeater/flow_request"
require "../repeater/diff"
require "../fuzz"
require "../decoder"
require "../miner"
require "../sequencer"
require "../discover"
require "../discover/adapters"
require "../probe/passive"
require "../probe/group"
require "../notes"
require "../issues_export"
require "./output"
require "./run/capture"
require "./run/history"
require "./run/repeater"
require "./run/fuzz_args"
require "./run/fuzz"
require "./run/mine"
require "./run/sequence"
require "./run/discover"
require "./run/oast"
require "./run/probe"
require "./run/notes"
require "./run/sitemap"
require "./run/issues"
require "./run/jwt"
require "./run/rewriter"
require "./run/project"

module Gori
  module CLI
    # `gori run <subcommand>` — the non-interactive CLI. Scripts the same project
    # data the TUI works on, built directly on the Store / Repeater / Session APIs
    # (NOT the verb system, whose ExecContext is ~60 UI-action methods that only
    # make sense in front of a terminal). Read subcommands open the store directly
    # and never take the capture lock, so they're safe to run alongside a live
    # capturing instance (SQLite WAL).
    module Run
      def self.dispatch(args : Array(String)) : Nil
        dispatch_subcommand(args)
      rescue ex : IO::Error
        # `gori run … | head` (or any reader that closes early) breaks the STDOUT
        # pipe; a well-behaved Unix filter exits quietly on EPIPE rather than
        # dumping an IO::Error backtrace. Re-raise anything that isn't a broken pipe.
        # (Kept as a thin wrapper so the subcommand `case` stays under the
        # cyclomatic-complexity bar — see dispatch_subcommand.)
        raise ex unless ex.os_error == Errno::EPIPE
        exit 0
      end

      private def self.dispatch_subcommand(args : Array(String)) : Nil
        Settings.load # global env vars (and other persisted defaults) for all subcommands
        # No args / -h / --help all print help. `args[1..]` is only reached in the named
        # branches, where args[0] matched a subcommand string (so args is non-empty and the
        # tail slice is safe). Folding the empty case into this `when` keeps the dispatch
        # under the cyclomatic-complexity bar; the rest of the subcommands live in
        # dispatch_subcommand2 for the same reason (one `case` would overflow the bar).
        case sub = args.first?
        when nil, "-h", "--help" then print_help
        when "capture"           then cmd_capture(args[1..])
        when "history", "ls"     then cmd_history(args[1..])
        when "show"              then cmd_show(args[1..])
        when "repeater"          then cmd_repeater(args[1..])
        when "fuzz"              then cmd_fuzz(args[1..])
        when "mine"              then cmd_mine(args[1..])
        when "sequence", "seq"   then cmd_sequence(args[1..])
        else                          dispatch_subcommand2(sub, args[1..])
        end
      end

      # The second half of the subcommand `case` (split from dispatch_subcommand so each
      # method stays under the cyclomatic-complexity bar). `sub` is non-nil here — the
      # empty/-h/--help case is handled above.
      private def self.dispatch_subcommand2(sub : String?, rest : Array(String)) : Nil
        case sub
        when "probe"    then cmd_probe(rest)
        when "discover" then cmd_discover(rest)
        when "oast"     then cmd_oast(rest)
        when "sitemap"  then cmd_sitemap(rest)
        when "notes"    then cmd_notes(rest)
        when "issues"   then cmd_issues(rest)
        when "jwt"      then cmd_jwt(rest)
        when "rewriter" then cmd_rewriter(rest)
        when "project"  then cmd_project(rest)
        else
          STDERR.puts "gori run: unknown subcommand '#{sub}'"
          print_help
          exit 1
        end
      end

      # Left column width for `gori run -h` subcommand names (longest: "project host-override").
      SUBCMD_COL_W = 22

      SUBCOMMANDS = [
        {"capture", "Start the proxy and stream captured flows to STDOUT"},
        {"history (ls)", "List / QL-query captured flows"},
        {"show <id>", "Print a flow's request/response (text, json, or raw bytes)"},
        {"repeater", "Re-send a captured flow, or list/create repeater sessions"},
        {"fuzz [<id>]", "Fuzz/intrude a request: mark §…§ positions, sweep payloads"},
        {"mine [<id>]", "Discover hidden parameters (query/form/multipart/json/header/cookie)"},
        {"sequence (seq)", "Analyze token randomness (collect via replay, or --tokens FILE)"},
        {"discover", "Spider + directory brute-force a target; findings feed the Sitemap"},
        {"oast", "Listen for out-of-band callbacks (interactsh & friends); print payload + hits"},
        {"sitemap", "Print the host → path endpoint tree (text, json, paths)"},
        {"probe [QL]", "Passively scan captured flows for issues (zero requests)"},
        {"notes [<n>]", "Read or write the project's notes (list, show, --all, create, delete)"},
        {"issues", "List, export, create, or update issues (text, json, markdown)"},
        {"jwt [<token>]", "Decode, re-sign, or generate testing payloads for a JWT"},
        {"rewriter", "Manage Match & Replace rules (list, add, rm, enable/disable, preview)"},
        {"project [list]", "List known projects"},
        {"project scope", "Manage scope rules (list, add, delete, enable/disable)"},
        {"project env", "Manage project env vars ($KEY substitution)"},
        {"project host-override", "Manage host overrides (list, add, update, delete)"},
      ]

      private def self.print_help : Nil
        puts "gori run — non-interactive CLI (script the proxy / history / repeater)"
        puts ""
        puts "Usage: gori run <subcommand> [options]"
        puts ""
        puts "Subcommands:"
        SUBCOMMANDS.each do |name, desc|
          gap = SUBCMD_COL_W - name.size
          gap = 1 if gap < 1
          puts "  #{name}#{" " * gap}#{desc}"
        end
        puts ""
        puts "Most read subcommands accept --project NAME or --db PATH; with neither they"
        puts "use the most-recently-active project. See 'gori run <subcommand> --help'."
      end

      # --- shared helpers ----------------------------------------------------

      # --db wins → else --project resolved via ProjectRegistry#find (exact short id
      # → exact dir slug → exact display name → unique id-prefix, all
      # case-insensitive) → else the most-recently-active project. Aborts when
      # nothing resolves. Routing through #find is what lets a read command finally
      # select by slug/id, not display name alone (parity with MCP --project).
      private def self.resolve_read_project(project_name : String?, db_path : String?) : Project
        if path = db_path
          abort "gori run: --db is not a readable file: #{path}" unless File.file?(path)
          return Project.new(File.basename(File.dirname(path)), path)
        end
        registry = ProjectRegistry.new(Paths.projects_dir)
        if name = project_name
          if found = registry.find(name)
            return found
          end
          projects = registry.list
          abort "gori run: no project matching '#{name}'#{projects.empty? ? "" : " (have: #{projects.map(&.name).join(", ")})"}"
        end
        projects = registry.list
        abort "gori run: no projects yet — capture some traffic first, or pass --db PATH" if projects.empty?
        projects.first
      end

      # Capture creates-or-reopens its target (unlike reads, which require an
      # existing one). --db keeps the explicit-file behaviour of legacy --headless.
      private def self.resolve_capture_project(project_name : String?, db_path : String?) : Project
        if path = db_path
          # Catch the unopenable cases up front with a clean message — otherwise
          # SQLite raises a raw DB::ConnectionRefused backtrace deep in Session.open.
          abort "gori run capture: --db is a directory, not a file: #{path}" if Dir.exists?(path)
          parent = File.dirname(path)
          abort "gori run capture: --db parent directory does not exist: #{parent}" unless Dir.exists?(parent)
          return Project.new(File.basename(parent), path)
        end
        ProjectRegistry.new(Paths.projects_dir).create(project_name || "default")
      end

      # Opening a non-SQLite file (or a path we can't read) raises deep in the driver;
      # turn that into a clean CLI error instead of an unhandled backtrace.
      private def self.open_store(project : Project) : Store
        store = Store.open(project.db_path)
        Env.load_project(store)
        store
      rescue ex : DB::Error | SQLite3::Exception
        abort "gori run: cannot open database #{project.db_path}: #{ex.message.presence || "not a valid SQLite database (or unreadable)"}"
      end

      # QL negation terms ("-field:value" / "-field~rx") begin with '-', so OptionParser
      # aborts them as unknown options before the positional-query join ever runs. Pull
      # them out first so they join the query like any other positional term. A single-
      # letter short flag ("-n50", "-k") has no ':'/'~' after the name, so it's untouched.
      private def self.split_ql_negations(args : Array(String)) : {Array(String), Array(String)}
        neg = [] of String
        rest = [] of String
        args.each { |a| a.matches?(/\A-[A-Za-z]+[:~]/) ? (neg << a) : (rest << a) }
        {neg, rest}
      end

      # A short `-q` value that itself starts with '-' (e.g. `-q '-method:POST'`)
      # confuses OptionParser: it reads "-method:POST" as another flag rather than
      # -q's value, and the query is silently dropped. `--query=VALUE` doesn't have
      # this problem (OptionParser only splits on the first '='), so rewrite every
      # `-q`/`-qVALUE`/`-q=VALUE`/`-q VALUE` form into `--query=VALUE` up front.
      private def self.normalize_query_flag(args : Array(String)) : Array(String)
        out = [] of String
        i = 0
        while i < args.size
          a = args[i]
          if a == "-q" || a == "--query"
            if v = args[i + 1]?
              out << "--query=#{v}"; i += 2
            else
              out << a; i += 1
            end
          elsif a.starts_with?("-q=")
            out << "--query=#{a[3..]}"; i += 1
          elsif a.starts_with?("-q") && a.size > 2
            out << "--query=#{a[2..]}"; i += 1
          else
            out << a; i += 1
          end
        end
        out
      end

      private def self.take_flow_id(rest : Array(String), sub : String) : Int64
        abort "gori run #{sub}: missing <flow-id>" if rest.empty?
        abort "gori run #{sub}: too many arguments (expected one <flow-id>, got: #{rest.join(" ")})" if rest.size > 1
        rest[0].to_i64? || abort "gori run #{sub}: invalid flow id '#{rest[0]}'"
      end

      private def self.parse_port(v : String) : Int32
        n = v.to_i?
        abort "gori run: invalid --port '#{v}' (expected 0-65535)" unless n && 0 <= n <= 65535
        n
      end

      private def self.parse_count(v : String, flag : String? = nil) : Int32
        n = v.to_i?
        abort "gori run: invalid #{flag || "count"} '#{v}' (expected a positive integer)" unless n && n > 0
        n
      end

      # "30s" / "5m" / "1h" / bare seconds → a Time::Span.
      private def self.parse_duration(v : String) : Time::Span
        m = v.match(/\A(\d+)(s|m|h)?\z/)
        abort "gori run: invalid duration '#{v}' (use e.g. 30s, 5m, 1h)" unless m
        # .to_i? (not .to_i): the regex permits arbitrarily many digits, so a value
        # like 99999999999999999999 would overflow Int32 and crash with an unhandled
        # ArgumentError. Treat an out-of-range duration as a clean usage error.
        n = m[1].to_i? || abort("gori run: --for '#{v}' is out of range")
        abort "gori run: --for must be greater than 0 (got '#{v}')" if n == 0
        case m[2]?
        when "m" then n.minutes
        when "h" then n.hours
        else          n.seconds
        end
      end

      private def self.parse_format(v : String, allowed : Array(Symbol)) : Symbol
        sym = case v.downcase
              when "text"           then :text
              when "json"           then :json
              when "jsonl"          then :jsonl
              when "raw"            then :raw
              when "paths"          then :paths
              when "markdown", "md" then :markdown
              else                       abort "gori run: unknown --format '#{v}'"
              end
        abort "gori run: --format #{v} not valid here (use #{allowed.join("|")})" unless allowed.includes?(sym)
        sym
      end

      private def self.display_body(head : Bytes?, body : Bytes?) : Bytes?
        decode_body(head, body)[0]
      end

      # Decode a Content-Encoding/Transfer-Encoding body for display, returning the
      # bytes plus whether any decoding actually happened. When `true`, the bytes no
      # longer match the message's Content-Encoding/Content-Length headers — the JSON
      # output surfaces this as `body_decoded` so scripts aren't misled. (`--format
      # raw` still emits the exact wire bytes.)
      private def self.decode_body(head : Bytes?, body : Bytes?) : {Bytes?, Bool}
        decoded, _ = Proxy::Codec::ContentDecode.decode(head, body)
        decoded ? {decoded, true} : {body, false}
      end

      private def self.scrub(bytes : Bytes?) : String?
        bytes ? String.new(bytes).scrub : nil
      end

      # The CLI counterpart of MCP's Serialize.emit_body (src/gori/mcp/serialize.cr)
      # — same object shape ({encoding, size, truncated, text|base64, binary?,
      # wire_truncated?, note?}) so a script gets a consistent contract whether it
      # reads `gori mcp` or `gori run … --format json`. UNCLIPPED: unlike MCP (which
      # caps at MAX_TEXT/MAX_B64 for an LLM's context window), the CLI is read by a
      # script that expects the whole value, so no size cap is applied here.
      private def self.emit_body_json(j : JSON::Builder, field_name : String, head : Bytes?, body : Bytes?, wire_truncated : Bool) : Nil
        if body.nil? || body.empty?
          j.field field_name, nil
          return
        end
        decoded, note = Proxy::Codec::ContentDecode.decode(head, body)
        bytes = decoded || body
        s = String.new(bytes)
        j.field field_name do
          j.object do
            if s.valid_encoding?
              j.field "encoding", "text"
              j.field "size", bytes.size
              j.field "truncated", wire_truncated
              j.field "text", s
            else
              j.field "encoding", "base64"
              j.field "binary", true
              j.field "size", bytes.size
              j.field "truncated", wire_truncated
              j.field "base64", Base64.strict_encode(bytes)
            end
            j.field "wire_truncated", true if wire_truncated
            j.field "note", note if note
          end
        end
      end

      private def self.print_message_text(head : Bytes?, body : Bytes?) : Nil
        # Neutralize ANSI/OSC/CSI escapes in captured (attacker-controlled) head/body
        # before writing to the live terminal; `binary_body?` only sniffs for NUL, so an
        # escape-only payload would otherwise pass through. `--format raw` stays exact.
        STDOUT.puts(CLI::Output.term_safe_multiline(String.new(head || Bytes.empty).scrub).rstrip)
        if body && !body.empty?
          STDOUT.puts ""
          if binary_body?(body)
            STDOUT.puts "[binary body, #{body.size} bytes — use --format raw for exact bytes, or view hex]"
          else
            STDOUT.puts(CLI::Output.term_safe_multiline(String.new(body).scrub))
          end
        end
      end

      # `.scrub` only fixes invalid UTF-8 byte sequences — it does NOT strip control
      # bytes, so a binary body (e.g. a PNG/NUL-laden blob) would otherwise dump raw
      # control bytes (NUL/SUB/ESC/…) straight to the terminal and corrupt it. Sniff
      # for a NUL in the first 8KB, mirroring the TUI's binary-body guard.
      private def self.binary_body?(bytes : Bytes) : Bool
        n = {bytes.size, 8192}.min
        n.times { |i| return true if bytes[i] == 0u8 }
        false
      end

      # head lines + blank + body lines (scrubbed), for the --diff line comparison.
      private def self.message_lines(head : Bytes?, body : Bytes?) : Array(String)
        lines = bytes_to_lines(head)
        # The head BLOB ends with the CRLF CRLF that terminates the header block,
        # so splitting it leaves trailing empty lines; drop them and add exactly one
        # blank separator before the body (matches the non-diff text view).
        while !lines.empty? && lines.last.empty?
          lines.pop
        end
        if body && !body.empty?
          lines << ""
          lines.concat(bytes_to_lines(body))
        end
        lines
      end

      private def self.bytes_to_lines(bytes : Bytes?) : Array(String)
        return [] of String unless bytes
        String.new(bytes).scrub.split('\n').map(&.rstrip('\r'))
      end

      private def self.print_diff(diff : Array(Repeater::DiffLine)) : Nil
        diff.each do |dl|
          prefix = case dl.kind
                   in Repeater::DiffKind::Same then " "
                   in Repeater::DiffKind::Add  then "+"
                   in Repeater::DiffKind::Del  then "-"
                   end
          puts "#{prefix}#{dl.text}"
        end
      end
    end
  end
end
