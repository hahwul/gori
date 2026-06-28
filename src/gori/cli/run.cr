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
require "../fuzz"
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
        when "fuzz"          then cmd_fuzz(rest)
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
          fuzz [<id>]        Fuzz/intrude a request: mark §…§ positions, sweep payloads
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
          p.missing_option { |f| abort "gori run capture: missing value for #{f}" }
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
          p.missing_option { |f| abort "gori run history: missing value for #{f}" }
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
          p.missing_option { |f| abort "gori run show: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run show: --request-only and --response-only are mutually exclusive" if req_only && resp_only
        id = take_flow_id(positional, "show")

        # Close the store before any abort (abort/exit skip ensure blocks); get_flow
        # has already loaded the BLOBs we need. A WebSocket flow (101) also carries a
        # ws_messages log — fetch it now while the store is open.
        store = open_store(resolve_read_project(project_name, db_path))
        detail, ws_msgs = begin
          d = store.get_flow(id)
          msgs = d && d.row.status == 101 ? store.ws_messages(id) : [] of Store::WsMessage
          {d, msgs}
        ensure
          store.close
        end
        abort "gori run show: no flow ##{id}" unless detail

        show_request = !resp_only
        show_response = !req_only
        case format
        when :raw  then show_raw(detail, show_request, show_response)
        when :json then puts show_json(detail, show_request, show_response, ws_msgs)
        else            show_text(detail, show_request, show_response, ws_msgs)
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

      private def self.show_text(detail : Store::FlowDetail, req : Bool, resp : Bool,
                                 ws_msgs : Array(Store::WsMessage)) : Nil
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
          unless ws_msgs.empty?
            puts ""
            puts "=== WEBSOCKET MESSAGES (#{ws_msgs.size}) ==="
            ws_msgs.each { |m| puts ws_message_text(m) }
          end
          if (events = sse_events_of(detail)) && !events.empty?
            puts ""
            puts "=== SSE EVENTS (#{events.size}) ==="
            events.each_with_index { |e, i| puts sse_event_text(e, i) }
          end
        end
      end

      # Parsed SSE events when the response is a text/event-stream, else nil. Like
      # the TUI EVENTS pane, this is a derived view over the decoded response body.
      private def self.sse_events_of(detail : Store::FlowDetail) : Array(Sse::Event)
        Sse.from_response(detail.response_head, detail.response_body)
      end

      private def self.sse_event_text(e : Sse::Event, idx : Int32) : String
        String.build do |io|
          io << "#" << (idx + 1)
          io << " type=" << e.type if e.type
          io << " id=" << e.id if e.id
          io << " retry=" << e.retry if e.retry
          e.data.each_line { |l| io << "\n  " << l.scrub }
        end
      end

      # "→ out" (client→server) / "← in" (server→client). Text frames print their
      # (scrubbed) payload; binary frames print a size + short hex preview.
      private def self.ws_message_text(m : Store::WsMessage) : String
        arrow = m.direction == "out" ? "→" : "←"
        if m.text?
          "#{arrow} #{String.new(m.payload).scrub}"
        else
          preview = m.payload[0, {m.payload.size, 16}.min].hexstring
          "#{arrow} [binary #{m.payload.size}B] #{preview}#{m.payload.size > 16 ? "…" : ""}"
        end
      end

      private def self.show_json(detail : Store::FlowDetail, req : Bool, resp : Bool,
                                 ws_msgs : Array(Store::WsMessage)) : String
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
              unless ws_msgs.empty?
                j.field "ws_messages" do
                  j.array do
                    ws_msgs.each do |m|
                      j.object do
                        j.field "direction", m.direction
                        j.field "opcode", m.opcode
                        j.field "text", m.text?
                        j.field "payload", m.text? ? String.new(m.payload).scrub : nil
                        j.field "size", m.payload.size
                      end
                    end
                  end
                end
              end
              if (events = sse_events_of(detail)) && !events.empty?
                j.field "sse_events" do
                  j.array do
                    events.each do |e|
                      j.object do
                        j.field "type", e.type
                        j.field "data", e.data.scrub
                        j.field "id", e.id
                        j.field "retry", e.retry
                      end
                    end
                  end
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
          p.missing_option { |f| abort "gori run replay: missing value for #{f}" }
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
        abort "gori run replay: unsupported target scheme #{scheme.inspect} (use http:// or https://)" unless scheme.in?("http", "https")
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

      # --- fuzz --------------------------------------------------------------

      FUZZ_AUTO_CAP = 100_000_i64 # above this (or unknown), require --force

      private def self.cmd_fuzz(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        flow_id : Int64? = nil
        request_file : String? = nil
        target_override : String? = nil
        sni : String? = nil
        force_h2 = false
        insecure = false
        auto = false
        marks = [] of String
        mode = Fuzz::Mode::Sniper
        sources = [] of Fuzz::PayloadSource
        processors = [] of Fuzz::Processor
        concurrency = 20
        rate : Float64? = nil
        throttle : Int32? = nil
        timeout : Time::Span? = nil
        retries = 0
        follow = false
        auto_cal = false
        format = :text
        force = false
        fail_if_no_matches = false
        matcher = Fuzz::Matcher.new(keep_bodies: :none)
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run fuzz [<flow-id>] [options]   (mark positions with §…§)"
          p.on("--flow=ID", "Seed the template from a captured flow") { |v| flow_id = parse_flow_id(v) }
          p.on("--request=FILE", "Read a raw HTTP request (may contain §…§) as the template") { |v| request_file = v }
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--target=URL", "Send to this origin (scheme://host[:port]); required for --request/stdin") { |v| target_override = v }
          p.on("--http2", "Force HTTP/2") { force_h2 = true }
          p.on("--sni=HOST", "TLS SNI override") { |v| sni = v }
          p.on("-k", "--insecure-upstream", "Do not verify upstream TLS certificates") { insecure = true }
          p.on("--auto", "Auto-mark every query / cookie / body parameter value") { auto = true }
          p.on("--mark=TOKEN", "Mark each literal TOKEN occurrence as a position (repeatable)") { |v| marks << v }
          p.on("--mode=MODE", "sniper (default) | batteringram | pitchfork | clusterbomb") { |v| mode = parse_mode(v) }
          p.on("-wPATH", "--wordlist=PATH", "Payload set: a wordlist file (repeatable; order → positions)") { |v| sources << Fuzz::WordlistFile.new(v) }
          p.on("--payloads=LIST", "Payload set: inline comma list (a,b,c)") { |v| sources << Fuzz::InlineList.new(v.split(',')) }
          p.on("--numbers=SPEC", "Payload set: FROM-TO[:STEP] (e.g. 1-100 or 0-255:5)") { |v| sources << parse_numbers(v) }
          p.on("--null=N", "Payload set: N empty payloads") { |v| sources << Fuzz::NullPayloads.new(parse_count(v)) }
          p.on("--brute=SPEC", "Payload set: CHARSET:MIN-MAX (e.g. abc:1-3)") { |v| sources << parse_brute(v) }
          p.on("--prefix=STR", "Processing: prepend STR to each payload") { |v| processors << Fuzz::Prefix.new(v) }
          p.on("--suffix=STR", "Processing: append STR to each payload") { |v| processors << Fuzz::Suffix.new(v) }
          p.on("--encode=KIND", "Processing: url | urlall | base64 | hex") { |v| processors << Fuzz::Encode.new(parse_encode(v)) }
          p.on("--case=KIND", "Processing: upper | lower") { |v| processors << Fuzz::Case.new(parse_case(v)) }
          p.on("--hash=ALGO", "Processing: md5 | sha1 | sha256") { |v| processors << Fuzz::Hasher.new(parse_hash(v)) }
          p.on("--regex-replace=SPEC", "Processing: /pattern/replacement/") { |v| processors << parse_regex_replace(v) }
          p.on("--concurrency=N", "Parallel requests (default 20)") { |v| concurrency = parse_count(v) }
          p.on("--rate=RPS", "Cap requests/sec (0 = unlimited)") { |v| rate = parse_rate(v) }
          p.on("--throttle=MS", "Fixed delay between requests (ms)") { |v| throttle = parse_nonneg(v) }
          p.on("--timeout=SEC", "Per-request connect + idle timeout (seconds)") { |v| timeout = parse_count(v).seconds }
          p.on("--retries=N", "Retries on a network error") { |v| retries = parse_nonneg(v) }
          p.on("--follow-redirects", "Follow same-origin redirects") { follow = true }
          p.on("--mc=SPEC", "Match status (e.g. 200,302,500-599,2xx)") { |v| matcher.match_status = v }
          p.on("--fc=SPEC", "Filter out status") { |v| matcher.filter_status = v }
          p.on("--ms=SPEC", "Match response size (e.g. 1500,>1000)") { |v| matcher.match_size = v }
          p.on("--fs=SPEC", "Filter out response size") { |v| matcher.filter_size = v }
          p.on("--mw=SPEC", "Match word count") { |v| matcher.match_words = v }
          p.on("--fw=SPEC", "Filter out word count") { |v| matcher.filter_words = v }
          p.on("--ml=SPEC", "Match line count") { |v| matcher.match_lines = v }
          p.on("--fl=SPEC", "Filter out line count") { |v| matcher.filter_lines = v }
          p.on("--mr=REGEX", "Match response-body regex") { |v| matcher.match_regex = parse_regex(v) }
          p.on("--fr=REGEX", "Filter out response-body regex") { |v| matcher.filter_regex = parse_regex(v) }
          p.on("--extract=REGEX", "Grep-extract a value from each response (capture group 1)") { |v| matcher.extract = parse_regex(v) }
          p.on("--ac", "Auto-calibrate: drop responses identical to the baseline") { auto_cal = true }
          p.on("--format=FMT", "Output: text (default) | json | jsonl") { |v| format = parse_format(v, [:text, :json, :jsonl]) }
          p.on("--force", "Run even when the request count is huge or unknown") { force = true }
          p.on("--fail-if-no-matches", "Exit 3 when no result matched") { fail_if_no_matches = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run fuzz: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run fuzz: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run fuzz: too many arguments (expected at most one <flow-id>)" if positional.size > 1
        flow_id ||= positional.first?.try { |s| parse_flow_id(s) }

        text, default_target, src_h2 = fuzz_source(flow_id, request_file, project_name, db_path)
        template = build_fuzz_template(text, auto, marks, force_h2 || src_h2)
        scheme, host, port = resolve_fuzz_target(target_override, default_target)

        sets = sources.map { |src| Fuzz::PayloadSet.new(src, processors) }
        abort "gori run fuzz: no payloads — add -w/--payloads/--numbers/--null/--brute" if sets.empty?
        matcher.auto_calibrate = auto_cal

        config = Fuzz::Config.new(mode: mode, concurrency: concurrency, rps: rate, throttle_ms: throttle,
          retries: retries, timeout: timeout, follow_redirects: follow, auto_calibrate: auto_cal, keep_bodies: :none)
        gen_sets = mode.per_position? ? sets : [sets.first]
        generator = Fuzz::Generator.new(template, gen_sets, config)
        sender = Fuzz::Sender.new(Fuzz::Origin.new(scheme, host, port),
          http2: force_h2 || src_h2, verify: !insecure, sni: sni, timeout: timeout)
        engine = Fuzz::Engine.new(generator, matcher, sender, config)
        engine.calibrate_baseline if auto_cal

        run_fuzz_stream(engine, mode, scheme, host, port, format, force, fail_if_no_matches)
      end

      # {template text, default target (nil for file/stdin), http2} from the chosen source.
      private def self.fuzz_source(flow_id : Int64?, request_file : String?,
                                   project_name : String?, db_path : String?) : {String, String?, Bool}
        if file = request_file
          abort "gori run fuzz: not a readable file: #{file}" unless File.file?(file)
          {File.read(file), nil, false}
        elsif id = flow_id
          store = open_store(resolve_read_project(project_name, db_path))
          detail = begin
            store.get_flow(id)
          ensure
            store.close
          end
          abort "gori run fuzz: no flow ##{id}" unless detail
          built = Replay::FlowRequest.build(detail)
          {String.new(built.bytes).scrub, built.target, built.http2}
        elsif !STDIN.tty?
          {STDIN.gets_to_end, nil, false}
        else
          abort "gori run fuzz: no source — give a <flow-id>, --request FILE, or pipe a request on stdin"
        end
      end

      private def self.build_fuzz_template(text : String, auto : Bool, marks : Array(String), http2 : Bool) : Fuzz::Template
        text = Fuzz::Template.auto_mark(text) if auto
        m = Fuzz::Template::MARKER
        marks.each { |tok| text = text.gsub(tok, "#{m}#{tok}#{m}") }
        template = Fuzz::Template.parse(text, http2)
        abort "gori run fuzz: no positions — add §…§ markers, --auto, or --mark TOKEN" if template.position_count == 0
        template
      end

      private def self.run_fuzz_stream(engine : Fuzz::Engine, mode : Fuzz::Mode, scheme : String,
                                       host : String, port : Int32, format : Symbol, force : Bool,
                                       fail_if_no_matches : Bool) : Nil
        total = fuzz_preflight(engine, mode, scheme, host, port, force)
        emitted = 0
        had_error = false
        buffer = [] of Fuzz::Result
        engine.run do |ev|
          case ev
          when Fuzz::ProgressEvent then fuzz_progress(ev, total)
          when Fuzz::ResultEvent   then emitted += 1 if emit_fuzz_result(ev.result, format, buffer)
          when Fuzz::DoneEvent     then fuzz_done(ev, emitted)
          when Fuzz::ErrorEvent    then had_error = true; STDERR.puts "fuzz error: #{ev.message}"
          end
        end
        puts CLI::Output.fuzz_array_json(buffer) if format == :json
        exit 1 if had_error
        exit 3 if fail_if_no_matches && emitted == 0
      end

      # Resolve + announce the request count; gate huge/unknown runs behind --force.
      private def self.fuzz_preflight(engine : Fuzz::Engine, mode : Fuzz::Mode, scheme : String,
                                      host : String, port : Int32, force : Bool) : Int64?
        total = begin
          engine.total
        rescue ex
          abort "gori run fuzz: #{ex.message}"
        end
        STDERR.puts "fuzzing #{scheme}://#{host}:#{port} · #{total || "?"} requests · #{mode.label}"
        if (total.nil? || total > FUZZ_AUTO_CAP) && !force
          abort "gori run fuzz: refusing to send #{total ? total.to_s : "an unbounded number of"} requests without --force (narrow positions/payloads or pass --force)"
        end
        total
      end

      private def self.fuzz_progress(ev : Fuzz::ProgressEvent, total : Int64?) : Nil
        STDERR.print "\r[fuzz] #{ev.progress.sent}/#{total || "?"} · #{ev.progress.matched} hits"
        STDERR.flush
      end

      private def self.fuzz_done(ev : Fuzz::DoneEvent, emitted : Int32) : Nil
        STDERR.print "\r"
        STDERR.puts "done · #{ev.progress.sent} sent · #{emitted} shown · #{ev.progress.errors} errors#{ev.stopped ? " (stopped)" : ""}"
      end

      # Prints/buffers a matched result; returns true when it was emitted.
      private def self.emit_fuzz_result(r : Fuzz::Result, format : Symbol, buffer : Array(Fuzz::Result)) : Bool
        return false unless r.matched?
        case format
        when :jsonl then puts CLI::Output.fuzz_row_json(r)
        when :json  then buffer << r
        else             puts CLI::Output.fuzz_row_text(r)
        end
        true
      end

      private def self.parse_flow_id(v : String) : Int64
        v.to_i64? || abort "gori run fuzz: invalid flow id '#{v}'"
      end

      private def self.parse_mode(v : String) : Fuzz::Mode
        Fuzz::Mode.parse?(v) || abort "gori run fuzz: invalid --mode '#{v}' (sniper|batteringram|pitchfork|clusterbomb)"
      end

      private def self.resolve_fuzz_target(override : String?, default_target : String?) : {String, String, Int32}
        target = override || default_target || abort("gori run fuzz: --target is required for --request/stdin")
        scheme, host, port = Replay::FlowRequest.parse_target(target)
        abort "gori run fuzz: could not determine a target host" if host.empty?
        abort "gori run fuzz: unsupported target scheme #{scheme.inspect} (use http:// or https://)" unless scheme.in?("http", "https")
        {scheme, host, port}
      end

      private def self.parse_numbers(v : String) : Fuzz::NumberRange
        range_part, _, step_part = v.partition(':')
        from_s, _, to_s = range_part.partition('-')
        from = from_s.to_i64?
        to = to_s.to_i64?
        abort "gori run fuzz: invalid --numbers '#{v}' (use FROM-TO[:STEP])" unless from && to
        step = step_part.empty? ? 1_i64 : (step_part.to_i64? || abort("gori run fuzz: invalid --numbers step '#{step_part}'"))
        Fuzz::NumberRange.new(from, to, step)
      end

      private def self.parse_brute(v : String) : Fuzz::BruteForce
        charset, _, lens = v.rpartition(':')
        abort "gori run fuzz: invalid --brute '#{v}' (use CHARSET:MIN-MAX)" if charset.empty? || lens.empty?
        min_s, _, max_s = lens.partition('-')
        min = min_s.to_i?
        max = max_s.empty? ? min : max_s.to_i?
        abort "gori run fuzz: invalid --brute lengths '#{lens}' (use MIN-MAX)" unless min && max
        Fuzz::BruteForce.new(charset, min, max)
      end

      private def self.parse_encode(v : String) : Symbol
        case v.downcase
        when "url"    then :url
        when "urlall" then :url_all
        when "base64" then :base64
        when "hex"    then :hex
        else               abort "gori run fuzz: invalid --encode '#{v}' (url|urlall|base64|hex)"
        end
      end

      private def self.parse_case(v : String) : Symbol
        case v.downcase
        when "upper" then :upper
        when "lower" then :lower
        else              abort "gori run fuzz: invalid --case '#{v}' (upper|lower)"
        end
      end

      private def self.parse_hash(v : String) : Symbol
        case v.downcase
        when "md5"    then :md5
        when "sha1"   then :sha1
        when "sha256" then :sha256
        else               abort "gori run fuzz: invalid --hash '#{v}' (md5|sha1|sha256)"
        end
      end

      private def self.parse_regex(v : String) : Regex
        Regex.new(v)
      rescue ex
        abort "gori run fuzz: invalid regex '#{v}': #{ex.message}"
      end

      private def self.parse_rate(v : String) : Float64?
        n = v.to_f?
        abort "gori run fuzz: invalid --rate '#{v}' (a non-negative number)" unless n && n >= 0
        n == 0 ? nil : n
      end

      private def self.parse_nonneg(v : String) : Int32
        n = v.to_i?
        abort "gori run: invalid count '#{v}' (expected a non-negative integer)" unless n && n >= 0
        n
      end

      private def self.parse_regex_replace(v : String) : Fuzz::RegexReplace
        abort "gori run fuzz: --regex-replace needs /pattern/replacement/" if v.size < 3
        delim = v[0]
        parts = v[1..].split(delim)
        abort "gori run fuzz: --regex-replace must be #{delim}pattern#{delim}replacement#{delim}" if parts.size < 2
        Fuzz::RegexReplace.new(parse_regex(parts[0]), parts[1])
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
          p.missing_option { |f| abort "gori run findings: missing value for #{f}" }
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
            io << '#' << f.id << "  [" << f.severity.label << '/' << f.status.label << "]  " << Findings::Export.one_line(f.title)
            if h = f.host
              io << "  (" << Findings::Export.one_line(h) << ')'
            end
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
          p.missing_option { |f| abort "gori run projects: missing value for #{f}" }
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
              when "jsonl"          then :jsonl
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
