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
require "../repeater/minimize"
require "../repeater/message_lines"
require "../fuzz"
require "../decoder"
require "../miner"
require "../sequencer"
require "../discover"
require "../discover/adapters"
require "../oast/provider_config"
require "../probe/passive"
require "../probe/group"
require "../notes"
require "../issues_export"
require "../links"
require "../import"
require "./output"
require "./run/capture"
require "./run/history"
require "./run/repeater"
require "./run/repeater_minimize"
require "./run/compare"
require "./run/intercept"
require "./run/fuzz_args"
require "./run/fuzz"
require "./run/mine"
require "./run/sequence"
require "./run/discover"
require "./run/oast"
require "./run/probe"
require "./run/notes"
require "./run/sitemap"
require "./run/import"
require "./run/issues"
require "./run/links"
require "./run/jwt"
require "./run/decoder"
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
        when "import"   then cmd_import(rest)
        when "notes"    then cmd_notes(rest)
        when "issues"   then cmd_issues(rest)
        when "jwt"      then cmd_jwt(rest)
        when "decoder"  then cmd_decoder(rest)
        when "rewriter" then cmd_rewriter(rest)
        when "project"  then cmd_project(rest)
        else                 dispatch_subcommand3(sub, rest)
        end
      end

      # The third slice of the subcommand `case` (same complexity-bar reason as
      # dispatch_subcommand2). `sub` is still non-nil here.
      private def self.dispatch_subcommand3(sub : String?, rest : Array(String)) : Nil
        case sub
        when "compare"   then cmd_compare(rest)
        when "intercept" then cmd_intercept(rest)
        when "links"     then cmd_links(rest)
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
        {"history delete", "Hard-delete one captured flow by id"},
        {"history clear", "Delete ALL captured flows in the project (needs --yes)"},
        {"show <id>", "Print a flow's request/response (text, json, or raw bytes)"},
        {"repeater", "Re-send a captured flow; list/create/send (replay, incl. WebSocket) repeater sessions"},
        {"repeater minimize", "Strip noise from a saved request, keeping the response the same"},
        {"compare <a> <b>", "Diff two flows' request or response (unified diff)"},
        {"intercept", "Inspect/drive a live TUI's paused intercept queue (list, forward, drop, edit, …)"},
        {"fuzz [<id>]", "Fuzz/intrude a request: mark §…§ positions, sweep payloads"},
        {"mine [<id>]", "Discover hidden parameters (query/form/multipart/json/header/cookie)"},
        {"sequence (seq)", "Analyze token randomness (collect via replay, or --tokens FILE)"},
        {"discover", "Spider + directory brute-force a target; findings feed the Sitemap"},
        {"oast", "Listen for out-of-band callbacks (interactsh & friends); print payload + hits"},
        {"oast providers", "Manage saved OAST providers (list, add, update, enable/disable, delete)"},
        {"sitemap", "Print the host → path endpoint tree (text, json, paths)"},
        {"sitemap tag", "Pin/clear/list a free-text memo on a sitemap path"},
        {"import", "Import flows from a HAR, URL list, or OpenAPI spec into History"},
        {"probe [QL]", "Passively scan captured flows for issues (zero requests)"},
        {"probe issues", "List persisted probe findings (the TUI Probe tab's list)"},
        {"probe dismiss", "Mute a finding by id, or bulk by --code / --host"},
        {"probe promote", "Promote a finding to a human-confirmed Issue"},
        {"probe delete", "Hard-delete a finding (or --all)"},
        {"probe rules", "List/enable/disable scan rules; add or delete custom ones"},
        {"probe mode", "Get/set the scan mode (off, passive, active, aggressive)"},
        {"notes [<n>]", "Read or write the project's notes (list, <n>, --all, create, delete)"},
        {"issues", "List, export, create, update, or delete issues (text, json, markdown)"},
        {"links", "List/add/delete an issue's or note's evidence links"},
        {"jwt [<token>]", "Decode, re-sign, or generate testing payloads for a JWT"},
        {"decoder <chain>", "Encode/decode/hash via the Decoder engine (base64, hex, url, gzip …)"},
        {"rewriter", "Manage Match & Replace rules (list, add, rm, enable/disable, preview, extract, bindings)"},
        {"project [list]", "List known projects"},
        {"project create", "Create (or reopen) a project by name"},
        {"project delete", "Delete a project and everything captured in it"},
        {"project scope", "Manage scope rules (list, add, update, delete, enable/disable)"},
        {"project sandbox", "Get/set the hard-containment sandbox gate (status, on, off)"},
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

      # Is a subcommand's first token a VERB, as opposed to a flag or nothing at all?
      #
      # A `case args.first?` that ends in `else <the read command>` treats an unrecognized verb
      # as the default read, which is how `gori run issues remove 1` printed the issue list and
      # exited 0 having deleted nothing, and how `gori run links remove …` listed instead of
      # unlinking. Both are mutations that silently no-op with a SUCCESS status — the worst
      # failure mode for a surface scripts consume. So the `else` branch asks this first and
      # rejects a verb it does not know, while a leading flag (`--project x`, meaning "list")
      # and an empty argv still fall through to the read command.
      #
      # Only applicable to the verb-ONLY subcommands. The ones taking a bare positional —
      # `history`/`probe`/`sitemap` (a QL query), `notes` (`<n>`), `decoder` (a chain),
      # `repeater`/`show`/`fuzz` (an id) — legitimately receive a non-flag first token as DATA,
      # and reject a bad verb downstream when validating it.
      #
      # `rewriter`, `project` and `intercept` still hand-roll this same `starts_with?('-')` test
      # beside their own `case` (7 sites). Routing them through here is worth doing, but it
      # changes how they treat an empty-string token, so it wants its own change rather than
      # riding along with a bug fix.
      private def self.verb_token?(sub : String?) : Bool
        !sub.nil? && !sub.empty? && !sub.starts_with?('-')
      end

      # --db wins → else --project resolved via ProjectRegistry#find (exact short id
      # → exact dir slug → exact display name → unique id-prefix, all
      # case-insensitive) → else the most-recently-active project. Aborts when
      # nothing resolves. Routing through #find is what lets a read command finally
      # select by slug/id, not display name alone (parity with MCP --project).
      private def self.resolve_read_project(project_name : String?, db_path : String?) : Project
        if path = db_path
          abort "gori run: --db is not a readable file: #{path}" unless File.exists?(path) && !File.directory?(path)
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
      # existing one). --db targets an explicit database file instead of a project.
      private def self.resolve_capture_project(project_name : String?, db_path : String?) : Project
        if path = db_path
          # Catch the unopenable cases up front with a clean message — otherwise
          # SQLite raises a raw DB::ConnectionRefused backtrace deep in Session.open.
          abort "gori run capture: --db is a directory, not a file: #{path}" if Dir.exists?(path)
          parent = File.dirname(path)
          abort "gori run capture: --db parent directory does not exist: #{parent}" unless Dir.exists?(parent)
          return Project.new(File.basename(parent), path)
        end
        # create() rejects a name that slugifies to nothing (blank / punctuation-only)
        # with a Gori::Error, and Dir.mkdir_p raises a File::Error for an unusable slug
        # (e.g. longer than the filesystem's name limit). Surface both as a clean
        # `gori run capture:` message, like every other resolve_* path, instead of a raw
        # backtrace. (Non-ASCII names like "日本語" now get a hashed fallback slug in
        # ProjectRegistry#slugify, so they no longer land here.)
        name = project_name || "default"
        begin
          ProjectRegistry.new(Paths.projects_dir).create(name)
        rescue ex : Gori::Error
          abort "gori run capture: #{ex.message} (#{name.inspect})"
        rescue ex : File::Error
          abort "gori run capture: could not create project #{name.inspect}: #{ex.message}"
        end
      end

      # Opening a non-SQLite file (or a path we can't read) raises deep in the driver;
      # turn that into a clean CLI error instead of an unhandled backtrace.
      private def self.open_store(project : Project) : Store
        store = Store.open(project.db_path, retention_flows: Settings.retention_flows)
        Env.load_project(store)
        # The project's extract rules become `Env`'s send-time layer here too (#501) — with
        # NO values, because a binding lives in the memory of the gori that observed it and
        # nothing writes one to disk. That is not a gap to paper over: it is what makes a
        # headless send refuse with "unbound session binding $SESSION" instead of the much
        # less useful "unresolved env $SESSION" that an undeclared name would earn. One
        # syntax, one rule, and a refusal that names its gate on every surface.
        Env.layer = Bindings.load(store)
        store
      rescue ex : DB::Error | SQLite3::Exception
        abort "gori run: cannot open database #{project.db_path}: #{ex.message.presence || "not a valid SQLite database (or unreadable)"}"
      end

      # Project host overrides for a CLI direct-dial command (fuzz/mine/sequence), loaded when
      # a project is in play — a flow-id reads from one, or --project/--db names one. Returns
      # nil for --request/stdin with no project (nothing to load; global Settings overrides
      # still apply inside Upstream.dial). Snapshots into memory, so the store can close.
      private def self.cli_host_overrides(project_name : String?, db_path : String?, flow_id : Int64?) : Gori::HostOverrides?
        return nil unless flow_id || project_name || db_path
        store = open_store(resolve_read_project(project_name, db_path))
        begin
          Gori::HostOverrides.load(store)
        ensure
          store.close
        end
      rescue
        nil
      end

      # The `Gori::Outbound` decision for a CLI direct-dial command (fuzz/mine/sequence/
      # repeater) — the one seam every active send on every surface passes through, and the
      # gate whose absence once let those tools fire at any host regardless of scope/Sandbox.
      # Loaded on the same trigger as cli_host_overrides (a project is in play).
      #
      # The read connection is handed to the Outbound rather than closed, so the rules keep
      # RELOADING for the length of the run: a mid-run EXCLUDE or Sandbox toggle (from the
      # TUI, or another `gori run project scope add`) stops an in-flight sweep, which the
      # previous start-time snapshot could never do. The caller releases it with
      # `outbound.close` once the command is done.
      #
      # With no project at all (--request/stdin), the result is an explicit
      # Unscoped(NoProject): permissive exactly as before, but a NAMED state instead of the
      # `scope ? ScopedBackend.new(sender, scope) : sender` nil that silently skipped the
      # gate entirely. A scope that fails to load must NOT fail OPEN (unlike overrides'
      # rescue-to-nil): a raise here becomes a clean fail-CLOSED abort — never a raw
      # backtrace, never a silently-unscoped run. (open_store already aborts on a bad DB.)
      private def self.optional_project_outbound(project_name : String?, db_path : String?, flow_id : Int64?,
                                                 allow_unscoped : Bool) : Gori::Outbound
        # ONLY fuzz/mine/sequence can genuinely run project-less (--request/stdin). Every
        # other caller reads its subject (a repeater session, a flow) out of a project and
        # must use project_outbound, or an omitted --project would silently drop the gate.
        return project_outbound(project_name, db_path, allow_unscoped) if flow_id || project_name || db_path
        # Standalone run: no project context at all, the same condition on which
        # cli_host_overrides skips loading overrides. `resolve_read_project` WOULD still
        # resolve a default project here, so this is the one `gori run` active path where the
        # active project's Sandbox and exclude rules do not apply. Say so on STDERR rather
        # than letting an ungated run look gated — binding a standalone run to the ambient
        # project instead is a product call, tracked as a follow-up on #354.
        STDERR.puts "gori run: no project in play (--request/stdin without --project/--db) — sending UNSCOPED; " \
                    "the active project's scope and Sandbox rules do NOT apply to this run"
        Gori::Outbound.cli(nil, allow_unscoped)
      end

      # The Outbound for a command that ALWAYS has a project in play — `gori run repeater`
      # resolves the most-recently-active project when --project/--db are omitted, so the
      # scope must be loaded from it either way (that default is exactly the case where
      # short-circuiting on "no --project given" would drop Sandbox containment).
      private def self.project_outbound(project_name : String?, db_path : String?,
                                        allow_unscoped : Bool) : Gori::Outbound
        store = open_store(resolve_read_project(project_name, db_path))
        scope = begin
          Gori::Scope.load(store)
        rescue ex
          store.close
          abort "gori run: could not load project scope (refusing to send unscoped): #{ex.message}"
        end
        Gori::Outbound.cli(scope, allow_unscoped, owns_store: store)
      end

      # Up-front (Layer-1) scope gate for the CLI direct-dial tools, with the policy owned
      # by the seam: an unconfigured project stays permissive, a configured one refuses an
      # out-of-scope target unless --allow-unscoped. This is only the soft include boundary;
      # Sandbox mode + explicit exclude rules are still enforced per-request by
      # `Fuzz::Sender`/`Repeater::Sender` regardless of --allow-unscoped.
      private def self.guard_outbound(outbound : Gori::Outbound, scheme : String, host : String,
                                      target : String, cmd : String) : Nil
        return unless outbound.check_request(scheme, host, target).blocked?
        outbound.close
        abort "#{cmd}: #{host} is out of the project scope — add a scope include rule or pass --allow-unscoped"
      end

      # One sentence for every `gori run` tool whose builder refused an env token that
      # resolves to nothing (#519). Shared rather than written per command because, unlike
      # the other plan reasons, this one names no flag of the command's own — the token is
      # the whole fact and the remedy is the same everywhere. `detail` is the builder's
      # prefixed, comma-joined token list (`$SESSION, $TOKEN`).
      # `where` names the thing that carried the token (e.g. " for session #3") and belongs
      # on the FACT, not after the remedy — "...or remove the token for session #3" reads as
      # if the token were the session's.
      private def self.env_unresolved_error(detail : String?, where : String = "") : String
        "unresolved env #{detail}#{where} — set it with `gori run project env set KEY value`, " \
        "or remove the token"
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
        parse_flow_id(rest[0], "gori run #{sub}")
      end

      private def self.parse_flow_id(v : String, cmd : String = "gori run") : Int64
        v.to_i64? || abort "#{cmd}: invalid flow id '#{v}'"
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
              when "har"            then :har
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
