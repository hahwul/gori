require "option_parser"
require "json"
require "../config"
require "../paths"
require "../settings"
require "../app"
require "../store"
require "../project"
require "../project_registry"
require "../ql"
require "../proxy/codec/content_decode"
require "../replay/engine"
require "../replay/h2_engine"
require "../replay/flow_request"
require "../replay/diff"
require "../findings_export"
require "./output"

module Gori
  module CLI
    # `gori run <subcommand>` — the non-interactive CLI. Scripts the same project
    # data the TUI works on, built directly on the Store / Replay / Session APIs
    # (NOT the verb system, whose ExecContext is ~60 UI-action methods that only
    # make sense in front of a terminal). Read subcommands open the store directly
    # and never take the capture lock, so they're safe to run alongside a live
    # capturing instance (SQLite WAL).
    module Run
      def self.dispatch(args : Array(String)) : Nil
        if args.empty?
          print_help
          return
        end

        rest = args[1..]
        case args[0]
        when "capture"       then cmd_capture(rest)
        when "history", "ls" then cmd_history(rest)
        when "show"          then cmd_show(rest)
        when "replay"        then cmd_replay(rest)
        when "findings"      then cmd_findings(rest)
        when "projects"      then cmd_projects(rest)
        when "-h", "--help"  then print_help
        else
          STDERR.puts "gori run: unknown subcommand '#{args[0]}'"
          print_help
          exit 1
        end
      rescue ex : IO::Error
        # `gori run … | head` (or any reader that closes early) breaks the STDOUT
        # pipe; a well-behaved Unix filter exits quietly on EPIPE rather than
        # dumping an IO::Error backtrace. Re-raise anything that isn't a broken pipe.
        raise ex unless ex.os_error == Errno::EPIPE
        exit 0
      end

      private def self.print_help : Nil
        puts <<-HELP
        gori run — non-interactive CLI (script the proxy / history / replay)

        Usage: gori run <subcommand> [options]

        Subcommands:
          capture            Start the proxy and stream captured flows to STDOUT
          history (ls)       List / QL-query captured flows
          show <id>          Print a flow's request/response (text, json, or raw bytes)
          replay <id>        Re-send a captured flow to its origin (optionally diff it)
          findings           List or export findings (text, json, markdown)
          projects           List known projects

        Most read subcommands accept --project NAME or --db PATH; with neither they
        use the most-recently-active project. See 'gori run <subcommand> --help'.
        HELP
      end

      # --- capture -----------------------------------------------------------

      private def self.cmd_capture(args : Array(String)) : Nil
        Settings.load # persisted bind is the default; flags override
        listen = Settings.bind_host
        port = Settings.bind_port
        db_path : String? = nil
        project_name : String? = nil
        insecure = false
        format = :text
        every : Time::Span? = nil
        max : Int32? = nil

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run capture [options]"
          p.on("-lHOST", "--listen=HOST", "Listen address (default #{listen})") { |v| listen = v }
          p.on("-pPORT", "--port=PORT", "Listen port (default #{port})") { |v| port = parse_port(v) }
          p.on("--project=NAME", "Capture into project NAME (created if missing; default 'default')") { |v| project_name = v }
          p.on("--db=PATH", "Capture into an explicit SQLite db file") { |v| db_path = v }
          p.on("--insecure-upstream", "Do not verify upstream TLS certificates") { insecure = true }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("--for=DURATION", "Stop after DURATION (e.g. 30s, 5m, 1h)") { |v| every = parse_duration(v) }
          p.on("--max=N", "Stop after N completed flows") { |v| max = parse_count(v) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run capture: unknown option: #{f}\n#{p}" }
        end
        parser.parse(args)

        Paths.ensure_dirs
        Settings.bind_host = listen
        Settings.bind_port = port
        project = resolve_capture_project(project_name, db_path)
        config = Config.new(listen, port, project.db_path, Paths.default_ca_dir,
          headless: true, insecure_upstream: insecure)
        App.new(config).run_capture(project, format: format, max: max, every: every)
      end

      # --- history -----------------------------------------------------------

      private def self.cmd_history(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        query : String? = nil
        limit = 50
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run history [options]   (alias: ls)"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("-qQL", "--query=QL", "Filter with a QL query (host: status:>=500 size:>10000 dur:>500 header: body~rx …)") { |v| query = v }
          p.on("-nN", "--limit=N", "Max rows, newest first (default 50)") { |v| limit = parse_count(v) }
          p.on("--format=FMT", "Output: text (default) | json (JSON-Lines)") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run history: unknown option: #{f}\n#{p}" }
        end
        parser.parse(args)

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          rows =
            if q = query
              filter = QL.parse(q)
              # A query that fails to compile to ANY clause (e.g. `status:>=foo`)
              # yields the match-all EMPTY filter — silently dumping every flow,
              # the opposite of what the user asked. Refuse it instead.
              if !q.strip.empty? && filter == QL::EMPTY
                store.close
                abort "gori run history: query #{q.inspect} did not match any field (check syntax, e.g. status:>=500 host:example.com method:POST)"
              end
              store.search(filter, limit)
            else
              store.recent_flows(limit)
            end
          if format == :json
            rows.each { |r| puts CLI::Output.flow_row_json(r) }
          elsif rows.empty?
            STDERR.puts "no flows#{query ? " match #{query.inspect}" : ""}"
          else
            rows.each { |r| puts CLI::Output.flow_row_text(r) }
          end
        ensure
          store.close
        end
      end

      # --- show --------------------------------------------------------------

      private def self.cmd_show(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        req_only = false
        resp_only = false
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run show <flow-id> [options]"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json | raw (exact bytes)") { |v| format = parse_format(v, [:text, :json, :raw]) }
          p.on("--request-only", "Only the request side") { req_only = true }
          p.on("--response-only", "Only the response side") { resp_only = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run show: unknown option: #{f}\n#{p}" }
        end
        parser.parse(args)
        abort "gori run show: --request-only and --response-only are mutually exclusive" if req_only && resp_only
        id = take_flow_id(positional, "show")

        # Close the store before any abort (abort/exit skip ensure blocks); get_flow
        # has already loaded the BLOBs we need.
        store = open_store(resolve_read_project(project_name, db_path))
        detail = begin
          store.get_flow(id)
        ensure
          store.close
        end
        abort "gori run show: no flow ##{id}" unless detail

        show_request = !resp_only
        show_response = !req_only
        case format
        when :raw  then show_raw(detail, show_request, show_response)
        when :json then puts show_json(detail, show_request, show_response)
        else            show_text(detail, show_request, show_response)
        end
      end

      private def self.show_raw(detail : Store::FlowDetail, req : Bool, resp : Bool) : Nil
        if req
          STDOUT.write(detail.request_head)
          if b = detail.request_body
            STDOUT.write(b)
          end
        end
        if resp
          if h = detail.response_head
            STDOUT.write(h)
          end
          if b = detail.response_body
            STDOUT.write(b)
          end
        end
        STDOUT.flush
      end

      private def self.show_text(detail : Store::FlowDetail, req : Bool, resp : Bool) : Nil
        if req
          puts "=== REQUEST (#{detail.http_version}) ==="
          print_message_text(detail.request_head, display_body(detail.request_head, detail.request_body))
          puts "  [request body truncated]" if detail.request_body_truncated?
        end
        if resp
          puts "" if req
          puts "=== RESPONSE ==="
          if err = detail.error
            puts "error: #{err}"
          end
          if h = detail.response_head
            print_message_text(h, display_body(h, detail.response_body))
            puts "  [response body truncated]" if detail.response_body_truncated?
          elsif detail.error.nil?
            puts "(no response captured)"
          end
        end
      end

      private def self.show_json(detail : Store::FlowDetail, req : Bool, resp : Bool) : String
        JSON.build do |j|
          j.object do
            j.field "flow" do
              CLI::Output.flow_row_fields(j, detail.row)
            end
            j.field "http_version", detail.http_version
            j.field "error", detail.error
            if req
              req_body, req_decoded = decode_body(detail.request_head, detail.request_body)
              j.field "request" do
                j.object do
                  j.field "head", scrub(detail.request_head)
                  j.field "body", scrub(req_body)
                  j.field "body_decoded", req_decoded
                  j.field "body_truncated", detail.request_body_truncated?
                end
              end
            end
            if resp
              resp_body, resp_decoded = decode_body(detail.response_head, detail.response_body)
              j.field "response" do
                j.object do
                  j.field "head", scrub(detail.response_head)
                  j.field "body", scrub(resp_body)
                  j.field "body_decoded", resp_decoded
                  j.field "body_truncated", detail.response_body_truncated?
                end
              end
            end
          end
        end
      end

      # --- replay ------------------------------------------------------------

      private def self.cmd_replay(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        target_override : String? = nil
        force_h2 = false
        insecure = false
        do_diff = false
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run replay <flow-id> [options]"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--target=URL", "Send to this origin (scheme://host[:port]) instead of the captured one; path/query kept") { |v| target_override = v }
          p.on("--http2", "Force HTTP/2 (default follows how the flow was captured)") { force_h2 = true }
          p.on("--insecure-upstream", "Do not verify the upstream TLS certificate") { insecure = true }
          p.on("--diff", "Diff the new response against the captured one") { do_diff = true }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run replay: unknown option: #{f}\n#{p}" }
        end
        parser.parse(args)
        id = take_flow_id(positional, "replay")

        # get_flow loads all the BLOBs, so the store can close before the send.
        store = open_store(resolve_read_project(project_name, db_path))
        detail = begin
          store.get_flow(id)
        ensure
          store.close
        end
        abort "gori run replay: no flow ##{id}" unless detail

        built = Replay::FlowRequest.build(detail)
        override = target_override # copy the closured flag into a plain local so || narrows
        scheme, host, port = Replay::FlowRequest.parse_target(override || built.target)
        abort "gori run replay: could not determine a target host" if host.empty?
        use_h2 = force_h2 || built.http2
        verify = !insecure
        result = use_h2 ? Replay::H2Engine.send(built.bytes, scheme: scheme, host: host, port: port, verify_upstream: verify) : Replay::Engine.send(built.bytes, scheme: scheme, host: host, port: port, verify_upstream: verify)

        # Decode the response body once; only build the diff lines when --diff asked
        # for them (decoding the captured baseline isn't free for large bodies).
        new_body, body_decoded = decode_body(result.head, result.body)
        diff =
          if do_diff
            orig = message_lines(detail.response_head, display_body(detail.response_head, detail.response_body))
            Replay::Diff.lines(orig, message_lines(result.head, new_body))
          end

        if format == :json
          puts replay_json(result, new_body, body_decoded, diff)
        elsif result.ok?
          STDERR.puts "→ #{result.response.try(&.status) || "?"} in #{CLI::Output.human_us(result.duration_us)}"
          if d = diff
            print_diff(d)
          else
            print_message_text(result.head, new_body)
          end
        else
          STDERR.puts "replay failed: #{result.error}"
        end
        exit 1 unless result.ok?
      end

      private def self.replay_json(result : Replay::Result, body : Bytes?, body_decoded : Bool, diff : Array(Replay::DiffLine)?) : String
        JSON.build do |j|
          j.object do
            j.field "ok", result.ok?
            j.field "status", result.response.try(&.status)
            j.field "duration_us", result.duration_us
            j.field "error", result.error
            j.field "head", scrub(result.head)
            j.field "body", scrub(body)
            j.field "body_decoded", body_decoded
            if d = diff
              j.field "changed_lines", Replay::Diff.change_count(d)
            end
          end
        end
      end

      # --- findings ----------------------------------------------------------

      private def self.cmd_findings(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        export_path : String? = nil

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run findings [options]"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json | markdown") { |v| format = parse_format(v, [:text, :json, :markdown]) }
          p.on("--export=PATH", "Write to PATH instead of STDOUT") { |v| export_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run findings: unknown option: #{f}\n#{p}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        # Build the report while the store is open (markdown resolves linked-flow
        # evidence), then close BEFORE any file I/O so a write failure can't leak the
        # connection — and so the abort below runs after a clean close.
        result = begin
          findings = store.findings
          if findings.empty? && format == :text && export_path.nil?
            STDERR.puts "no findings"
            return
          end
          content =
            case format
            when :json     then Findings::Export.json(findings)
            when :markdown then Findings::Export.markdown(findings, store, project.name)
            else                findings_text(findings)
            end
          {content, findings.size}
        ensure
          store.close
        end
        content, count = result

        if path = export_path
          begin
            File.write(path, content.ends_with?('\n') ? content : "#{content}\n")
          rescue ex : File::Error
            abort "gori run findings: cannot write to #{path}: #{ex.message}"
          end
          STDERR.puts "exported #{count} finding#{count == 1 ? "" : "s"} → #{path}"
        else
          puts content
        end
      end

      private def self.findings_text(findings : Array(Store::Finding)) : String
        String.build do |io|
          findings.each do |f|
            io << '#' << f.id << "  [" << f.severity.label << '/' << f.status.label << "]  " << f.title
            io << "  (" << f.host << ')' if f.host
            io << "  flow#" << f.flow_id if f.flow_id
            io << '\n'
          end
        end.rstrip('\n')
      end

      # --- projects ----------------------------------------------------------

      private def self.cmd_projects(args : Array(String)) : Nil
        format = :text
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run projects [options]"
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run projects: unknown option: #{f}\n#{p}" }
        end
        parser.parse(args)

        projects = ProjectRegistry.new(Paths.projects_dir).list
        if format == :json
          puts(JSON.build do |j|
            j.array do
              projects.each do |pr|
                j.object do
                  j.field "name", pr.name
                  j.field "db_path", pr.db_path
                  j.field "db_size", pr.db_size
                  j.field "last_modified", pr.last_modified.try(&.to_unix)
                end
              end
            end
          end)
        elsif projects.empty?
          STDERR.puts "no projects yet — capture some traffic (gori run capture / the TUI) first"
        else
          projects.each do |pr|
            ts = pr.last_modified.try(&.to_local.to_s("%Y-%m-%d %H:%M")) || "—"
            puts "#{pr.name.ljust(24)}  #{ts}  #{CLI::Output.human_size(pr.db_size)}"
          end
        end
      end

      # --- shared helpers ----------------------------------------------------

      # --db wins → else --project (matched case-insensitively on the dir slug) →
      # else the most-recently-active project. Aborts when nothing resolves.
      private def self.resolve_read_project(project_name : String?, db_path : String?) : Project
        if path = db_path
          abort "gori run: --db is not a readable file: #{path}" unless File.file?(path)
          return Project.new(File.basename(File.dirname(path)), path)
        end
        projects = ProjectRegistry.new(Paths.projects_dir).list
        if name = project_name
          found = projects.find { |pr| pr.name.downcase == name.downcase }
          abort "gori run: no project named '#{name}'#{projects.empty? ? "" : " (have: #{projects.map(&.name).join(", ")})"}" unless found
          return found
        end
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
        Store.open(project.db_path)
      rescue ex : DB::Error | SQLite3::Exception
        abort "gori run: cannot open database #{project.db_path}: #{ex.message.presence || "not a valid SQLite database (or unreadable)"}"
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

      private def self.parse_count(v : String) : Int32
        n = v.to_i?
        abort "gori run: invalid count '#{v}' (expected a positive integer)" unless n && n > 0
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
              when "raw"            then :raw
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

      private def self.print_message_text(head : Bytes?, body : Bytes?) : Nil
        STDOUT.puts(String.new(head || Bytes.empty).scrub.rstrip)
        if body && !body.empty?
          STDOUT.puts ""
          STDOUT.puts(String.new(body).scrub)
        end
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

      private def self.print_diff(diff : Array(Replay::DiffLine)) : Nil
        diff.each do |dl|
          prefix = case dl.kind
                   in Replay::DiffKind::Same then " "
                   in Replay::DiffKind::Add  then "+"
                   in Replay::DiffKind::Del  then "-"
                   end
          puts "#{prefix}#{dl.text}"
        end
      end
    end
  end
end
