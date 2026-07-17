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
        when "notes"   then cmd_notes(rest)
        when "issues"  then cmd_issues(rest)
        when "jwt"     then cmd_jwt(rest)
        when "rewriter" then cmd_rewriter(rest)
        when "project" then cmd_project(rest)
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
        {"notes [<n>]", "Read the project's notes (list, show one, or --all)"},
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
          p.banner = "Usage: gori run capture [options]\n\nRun the proxy and stream captured flows to STDOUT until Ctrl-C (or --for / --max)."
          p.on("-lHOST", "--listen=HOST", "Listen address (default #{listen})") { |v| listen = v }
          p.on("-pPORT", "--port=PORT", "Listen port (default #{port})") { |v| port = parse_port(v) }
          p.on("--project=NAME", "Capture into project NAME (created if missing; default 'default')") { |v| project_name = v }
          p.on("--db=PATH", "Capture into an explicit SQLite db file") { |v| db_path = v }
          p.on("-k", "--insecure-upstream", "Do not verify upstream TLS certificates") { insecure = true }
          p.on("--format=FMT", "Output: text (default) | json (JSON-Lines)") { |v| format = parse_format(v, [:text, :json]) }
          p.on("--for=DURATION", "Stop after DURATION (e.g. 30s, 5m, 1h)") { |v| every = parse_duration(v) }
          p.on("--max=N", "Stop after N completed flows") { |v| max = parse_count(v, "--max") }
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
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run history [QL query] [options]   (alias: ls)"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("-qQL", "--query=QL", "Filter with a QL query (host: status:>=500 size:>10000 dur:>500 header: body~rx …)") { |v| query = v }
          p.on("-nN", "--limit=N", "Max rows, newest first (default 50)") { |v| limit = parse_count(v, "--limit") }
          p.on("--format=FMT", "Output: text (default) | json (JSON-Lines)") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run history: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run history: missing value for #{f}" }
        end
        args = normalize_query_flag(args)
        neg_terms, opt_args = split_ql_negations(args)
        parser.parse(opt_args)
        # Accept a positional QL too ("gori run history status:404" / "-status:404"),
        # mirroring the TUI's `/` bar — otherwise a positional query was silently dropped
        # and EVERY flow dumped. An explicit --query wins. Terms join with spaces (QL ANDs).
        positional_query = (positional + neg_terms).join(' ')
        query ||= positional_query unless positional_query.empty?

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          rows =
            if q = query
              filter = QL.parse(q)
              QL.invalid_regex_terms(q).each do |t|
                STDERR.puts "gori run history: warning: invalid regex in #{t.inspect} — that term matches nothing"
              end
              # A query that fails to compile to ANY clause (e.g. `status:>=foo`)
              # yields the match-all EMPTY filter — silently dumping every flow,
              # the opposite of what the user asked. Refuse it instead.
              if !q.strip.empty? && filter == QL::EMPTY
                store.close
                abort "gori run history: query #{q.inspect} did not match any field (check syntax, e.g. status:>=500 host:example.com method:POST)"
              end
              begin
                store.search(filter, limit, raise_on_error: true)
              rescue ex
                store.close
                abort "gori run history: query #{q.inspect} failed: #{ex.message}"
              end
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
        print_decoded_text(detail, req, resp)
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
          e.data.each_line { |l| io << "\n  " << CLI::Output.term_safe_multiline(l.scrub) }
        end
      end

      # Decoded-protocol sections (SAML / JWT / GraphQL / form params) — derived views
      # over the stored bytes, mirroring the History decoded panes. Printed after the
      # request/response so `gori run show` surfaces the same decodes as the TUI. Scans
      # only the side(s) the `req`/`resp` flags include (so --request-only doesn't leak
      # a response-side token); the query is request-side, so it's gated under `req`.
      private def self.print_decoded_text(detail : Store::FlowDetail, req : Bool, resp : Bool) : Nil
        tgt = req ? detail.row.target : ""
        rh, rb = req ? detail.request_head : nil, req ? detail.request_body : nil
        sh, sb = resp ? detail.response_head : nil, resp ? detail.response_body : nil
        if doc = Saml.from_flow(tgt, rh, rb, sh, sb)
          puts ""
          puts "=== SAML (#{Saml.summary(doc)}) ==="
          puts CLI::Output.term_safe_multiline(Saml.pretty_xml(doc.xml).scrub)
        end
        jwts = Jwt.from_flow(tgt, rh, rb, sh, sb)
        unless jwts.empty?
          puts ""
          puts "=== JWT (#{jwts.size}) ==="
          jwts.each do |f|
            puts "▸ #{f.location}#{(b = f.brief) ? " · #{b}" : ""}"
            puts CLI::Output.term_safe_multiline(f.decoded.scrub)
          end
        end
        if op = Graphql.from_flow(tgt, rh, rb)
          puts ""
          puts "=== GRAPHQL ==="
          puts CLI::Output.term_safe_multiline(Graphql.display(op).scrub)
        end
        if fields = FormData.from_flow(tgt, rh, rb)
          puts ""
          puts "=== PARAMS (#{fields.size}) ==="
          fields.each { |f| puts CLI::Output.term_safe_multiline("#{f.source == :query ? "?" : " "} #{f.name} = #{(n = f.note) ? "(#{n})" : f.value}".scrub) }
        end
      end

      # The JSON counterpart of print_decoded_text — emits `saml` / `jwt` / `graphql` /
      # `form_params` onto the open flow object via the shared DecodedView emitter (so
      # CLI and MCP stay in lockstep). Scans only the req/resp-included side(s); unclipped
      # (a script can read whole values, unlike the LLM-bounded MCP path).
      private def self.emit_decoded_json(j : JSON::Builder, detail : Store::FlowDetail, req : Bool, resp : Bool) : Nil
        DecodedView.emit_json(j, target: req ? detail.row.target : "",
          req_head: req ? detail.request_head : nil, req_body: req ? detail.request_body : nil,
          resp_head: resp ? detail.response_head : nil, resp_body: resp ? detail.response_body : nil)
      end

      # "→ out" (client→server) / "← in" (server→client). Text frames print their
      # (scrubbed) payload; binary frames print a size + short hex preview.
      private def self.ws_message_text(m : Store::WsMessage) : String
        arrow = m.direction == "out" ? "→" : "←"
        if m.text?
          "#{arrow} #{CLI::Output.term_safe_multiline(String.new(m.payload).scrub)}"
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
            emit_decoded_json(j, detail, req, resp)
            if req
              j.field "request" do
                j.object do
                  j.field "head", scrub(detail.request_head)
                  emit_body_json(j, "body", detail.request_head, detail.request_body, detail.request_body_truncated?)
                end
              end
            end
            if resp
              j.field "response" do
                j.object do
                  j.field "head", scrub(detail.response_head)
                  emit_body_json(j, "body", detail.response_head, detail.response_body, detail.response_body_truncated?)
                end
              end
              unless ws_msgs.empty?
                j.field "ws_messages" do
                  j.object do
                    j.field "count", ws_msgs.size
                    j.field "truncated", false
                    j.field "messages" do
                      j.array do
                        ws_msgs.each do |m|
                          j.object do
                            j.field "direction", m.direction
                            j.field "opcode", m.opcode
                            if m.text?
                              j.field "text", String.new(m.payload).scrub
                            else
                              j.field "binary", true
                              j.field "size", m.payload.size
                              j.field "base64", Base64.strict_encode(m.payload)
                            end
                          end
                        end
                      end
                    end
                  end
                end
              end
              if (events = sse_events_of(detail)) && !events.empty?
                j.field "sse_events" do
                  j.object do
                    j.field "count", events.size
                    j.field "truncated", false
                    j.field "events" do
                      j.array do
                        events.each do |e|
                          j.object do
                            j.field "type", e.type
                            j.field "id", e.id
                            j.field "retry", e.retry
                            j.field "data", e.data.scrub
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      # --- repeater ------------------------------------------------------------

      private def self.cmd_repeater(args : Array(String)) : Nil
        sub = args.first?
        if sub == "list"
          cmd_repeater_list(args[1..])
          return
        elsif sub == "create"
          cmd_repeater_create(args[1..])
          return
        end

        cmd_repeater_single(args)
      end

      private def self.cmd_repeater_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run repeater list [options]"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run repeater list: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run repeater list: missing value for #{f}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          repeaters = store.repeaters_mcp
          if format == :json
            puts(JSON.build do |j|
              j.array do
                repeaters.each do |r|
                  j.object do
                    j.field "id", r.id
                    j.field "position", r.position
                    j.field "name", r.name || "Untitled"
                    j.field "target", r.target
                    j.field "http2", r.http2?
                    j.field "auto_content_length", r.auto_content_length?
                    j.field "flow_id", r.flow_id
                    j.field "sni", r.sni
                    j.field "last_error", r.response_error
                    j.field "last_duration_us", r.response_duration_us
                  end
                end
              end
            end)
          else
            if repeaters.empty?
              puts "No repeater sessions in the workbench."
            else
              repeaters.each do |r|
                name = r.name || "Untitled"
                h2 = r.http2? ? "H2" : "H1"
                puts "##{r.id}  [#{h2}]  #{name.ljust(20)}  → #{r.target}"
              end
            end
          end
        ensure
          store.close
        end
      end

      private def self.cmd_repeater_create(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        target : String? = nil
        request_file : String? = nil
        request_raw : String? = nil
        name : String? = nil
        http2 = false
        http2_given = false
        auto_cl = true
        flow_id : Int64? = nil
        sni : String? = nil

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run repeater create [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-tURL", "--target=URL", "Target URL (scheme://host[:port])") { |v| target = v }
          p.on("-fFILE", "--request-file=FILE", "Read raw HTTP request from FILE") { |v| request_file = v }
          p.on("-rRAW", "--request-raw=RAW", "Verbatim raw HTTP request string") { |v| request_raw = v }
          p.on("--name=NAME", "Custom repeater tab name") { |v| name = v }
          p.on("--http2", "Use HTTP/2 (default: false)") { http2 = true; http2_given = true }
          p.on("--no-auto-cl", "Do not auto-calculate Content-Length header") { auto_cl = false }
          p.on("--flow=ID", "Optional original flow ID this repeater stems from") { |v| flow_id = parse_flow_id(v) }
          p.on("--sni=HOST", "TLS SNI override") { |v| sni = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run repeater create: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run repeater create: missing value for #{f}" }
        end
        parser.parse(args)

        req_content = ""
        if file = request_file
          abort "gori run repeater create: request-file '#{file}' is not readable" unless File.file?(file)
          req_content = File.read(file)
        elsif raw = request_raw
          req_content = raw
        else
          if flow_id.nil?
            abort "gori run repeater create: either --request-file, --request-raw, or --flow is required"
          end
        end

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          tgt_val = target
          tgt_str : String = tgt_val ? tgt_val : ""
          ws_messages = [] of String
          is_ws = false

          if fid = flow_id
            detail = store.get_flow(fid)
            abort "gori run repeater create: no flow ##{fid} to clone" unless detail
            built = Repeater::FlowRequest.build(detail)
            req_content = String.new(built.bytes)
            if tgt_str.empty?
              bt = built.target
              tgt_str = bt ? bt : ""
            end

            unless http2_given
              http2 = built.http2
            end

            if detail.row.status == 101
              is_ws = true
              ws_messages = store.ws_messages(fid).select { |m| m.direction == "out" && m.text? }.map { |m| String.new(m.payload).scrub }
            end
          end

          abort "gori run repeater create: --target is required" if tgt_str.empty?

          pos = store.repeaters_meta.size

          id = store.insert_repeater(
            target: Env.mask_secrets(tgt_str),
            request: Env.mask_secrets(req_content),
            http2: http2,
            auto_cl: auto_cl,
            flow_id: flow_id,
            position: pos.to_i32,
            sni: sni
          )

          abort "gori run repeater create: failed to create repeater session" if id == 0

          if n = name
            store.set_repeater_name(id, Env.mask_secrets(n))
          end

          if is_ws && !ws_messages.empty?
            store.update_repeater_ws_messages(id, ws_messages)
          end

          puts "Repeater session ##{id} created successfully."
        ensure
          store.close
        end
      end

      private def self.cmd_repeater_single(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        target_override : String? = nil
        sni_override : String? = nil
        force_h2 = false
        insecure = false
        do_diff = false
        format = :text
        headers = [] of String
        body_override : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run repeater <flow-id> [options]"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--target=URL", "Send to this origin (scheme://host[:port]) instead of the captured one; path/query kept") { |v| target_override = v }
          p.on("--http2", "Force HTTP/2 (default follows how the flow was captured)") { force_h2 = true }
          p.on("--sni=HOST", "TLS SNI override") { |v| sni_override = v }
          p.on("-k", "--insecure-upstream", "Do not verify the upstream TLS certificate") { insecure = true }
          p.on("--diff", "Diff the new response against the captured one") { do_diff = true }
          p.on("-HHEADER", "--header=HEADER", "Custom header to overwrite/add (repeatable)") { |v| headers << v }
          p.on("-bBODY", "--body=BODY", "Request body override") { |v| body_override = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run repeater: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run repeater: missing value for #{f}" }
        end
        parser.parse(args)
        id = take_flow_id(positional, "repeater")

        # get_flow loads all the BLOBs, so the store can close before the send.
        store = open_store(resolve_read_project(project_name, db_path))
        detail = begin
          store.get_flow(id)
        ensure
          store.close
        end
        abort "gori run repeater: no flow ##{id}" unless detail

        # A WebSocket flow can't be replayed by a one-shot HTTP send: this path would only
        # re-issue the upgrade request and report the 101 handshake, exchanging zero frames
        # (a silently misleading "success"). Detect an upgrade that actually completed
        # (status 101 + a WebSocket upgrade request) and refuse with an actionable pointer,
        # rather than the plain h1/h2 engines that don't do the RFC 6455 framed exchange.
        if detail.row.status == 101 && Repeater::WsEngine.upgrade_request?(String.new(detail.request_head))
          abort "gori run repeater: flow ##{id} is a WebSocket session — `gori run repeater` only re-sends the HTTP upgrade and captures the 101 handshake, not the framed messages. Repeater it from the TUI Repeater tab, or create a repeater from it and use the MCP `send_websocket` tool for a real framed exchange."
        end

        # The captured request body was capped at CAPTURE_MAX; FlowRequest.build re-syncs the
        # Content-Length to the stored bytes so the request stays well-formed, but warn that
        # the resent body differs from what the origin originally received.
        if detail.request_body_truncated?
          cap_mib = Settings.capture_max_mib
          STDERR.puts "gori run repeater: request body was truncated at the #{cap_mib} MiB capture cap — resending the stored (shorter) body with a corrected Content-Length"
        end

        built = Repeater::FlowRequest.build(detail)

        raw_bytes = built.bytes
        crlf_crlf_idx = -1
        limit = raw_bytes.size - 4
        (0..limit).each do |i|
          if raw_bytes[i] == 0x0d_u8 && raw_bytes[i + 1] == 0x0a_u8 && raw_bytes[i + 2] == 0x0d_u8 && raw_bytes[i + 3] == 0x0a_u8
            crlf_crlf_idx = i
            break
          end
        end

        abort "gori run repeater: malformed request bytes in captured flow" if crlf_crlf_idx == -1

        head_bytes = raw_bytes[0, crlf_crlf_idx + 4]
        body_bytes = raw_bytes[crlf_crlf_idx + 4..]

        raw_req = Proxy::Codec::Http1.parse_request_head(head_bytes)

        custom_headers = {} of String => String
        headers.each do |h_str|
          next unless h_str.includes?(':')
          name, _, val = h_str.partition(':')
          next if name.strip.empty?
          custom_headers[name.strip.downcase] = val.strip
        end

        new_headers = [] of Proxy::Codec::Header
        applied = Set(String).new # custom names whose FIRST occurrence was already replaced
        raw_req.headers.each do |hdr|
          lower_name = hdr.name.downcase
          if custom_headers.has_key?(lower_name)
            # Replace the first matching line; DROP later duplicates (a captured h2 request
            # can carry several `cookie:`/`set-cookie:` lines) so the override isn't left
            # half-applied with a stale second occurrence.
            next if applied.includes?(lower_name)
            new_headers << Proxy::Codec::Header.new(hdr.name, custom_headers[lower_name])
            applied << lower_name
          else
            new_headers << hdr
          end
        end

        custom_headers.each do |lower_name, val|
          next if applied.includes?(lower_name) # already replaced an existing line
          orig_name = ""
          headers.each do |h_str|
            name, _, _ = h_str.partition(':')
            if name.strip.downcase == lower_name
              orig_name = name.strip
              break
            end
          end
          orig_name = lower_name if orig_name.empty?
          new_headers << Proxy::Codec::Header.new(orig_name, val)
        end

        final_body = if b_over = body_override
                       b_over.to_slice
                     else
                       body_bytes
                     end

        has_cl = new_headers.any? { |h| h.name.compare("Content-Length", case_insensitive: true) == 0 }
        has_te = new_headers.any? { |h| h.name.compare("Transfer-Encoding", case_insensitive: true) == 0 }
        # RFC 7230 §3.3.3 forbids sending Transfer-Encoding and Content-Length together.
        # When the original request was chunked (TE present, no override), keep its wire
        # framing byte-exact and don't inject a Content-Length. When the body is replaced
        # via -b, drop Transfer-Encoding and self-frame the new bytes with Content-Length.
        if has_te && body_override
          new_headers.reject! { |h| h.name.compare("Transfer-Encoding", case_insensitive: true) == 0 }
          has_te = false
        end
        if !has_te && (body_override || has_cl || final_body.size > 0)
          cl_idx = new_headers.index { |h| h.name.compare("Content-Length", case_insensitive: true) == 0 }
          if cl_idx
            new_headers[cl_idx] = Proxy::Codec::Header.new(new_headers[cl_idx].name, final_body.size.to_s)
          else
            new_headers << Proxy::Codec::Header.new("Content-Length", final_body.size.to_s)
          end
        end

        # Sync Host from --target, UNLESS the user set an explicit `-H "Host: …"` — a
        # host-header-confusion / vhost test deliberately pairs --target (where to connect)
        # with a different claimed Host, so that override must win.
        if (override = target_override) && !custom_headers.has_key?("host")
          scheme_part, host_part, port_part = Repeater::FlowRequest.parse_target(override)
          default_port = scheme_part == "https" ? 443 : 80
          host_hdr_val = port_part == default_port ? host_part : "#{host_part}:#{port_part}"
          host_idx = new_headers.index { |h| h.name.compare("Host", case_insensitive: true) == 0 }
          if host_idx
            new_headers[host_idx] = Proxy::Codec::Header.new(new_headers[host_idx].name, host_hdr_val)
          else
            new_headers << Proxy::Codec::Header.new("Host", host_hdr_val)
          end
        end

        new_head_str = String.build do |io|
          io << raw_req.method << " " << raw_req.target << " " << raw_req.version << "\r\n"
          new_headers.each do |hdr|
            io << hdr.name << ": " << hdr.value << "\r\n"
          end
          io << "\r\n"
        end

        final_request_bytes = new_head_str.to_slice + final_body

        override = target_override # copy the closured flag into a plain local so || narrows
        # Re-sync Content-Length after expansion — a `$KEY` in the body changes its length,
        # and `build` framed CL over the pre-expansion bytes.
        bytes = Repeater::FlowRequest.resync_content_length(Env.expand_wire(String.new(final_request_bytes)))
        target = Env.expand(override || built.target)
        scheme, host, port = Repeater::FlowRequest.parse_target(target)
        abort "gori run repeater: could not determine a target host" if host.empty?
        abort "gori run repeater: unsupported target scheme #{scheme.inspect} (use http:// or https://)" unless scheme.in?("http", "https")
        use_h2 = force_h2 || built.http2
        verify = !insecure
        sni_val = sni_override.presence || built.sni
        result = use_h2 ? Repeater::H2Engine.send(bytes, scheme: scheme, host: host, port: port, verify_upstream: verify, sni: sni_val) : Repeater::Engine.send(bytes, scheme: scheme, host: host, port: port, verify_upstream: verify, sni: sni_val)

        # Decode the response body once for TEXT display (--diff / plain print); only
        # build the diff lines when --diff asked for them (decoding the captured
        # baseline isn't free for large bodies). The JSON path decodes independently
        # inside emit_body_json, from the raw head+body, to match MCP's contract.
        new_body, _ = decode_body(result.head, result.body)
        diff =
          if do_diff
            orig = message_lines(detail.response_head, display_body(detail.response_head, detail.response_body))
            Repeater::Diff.lines(orig, message_lines(result.head, new_body))
          end

        if format == :json
          puts repeater_json(result, diff)
        elsif result.ok?
          STDERR.puts "→ #{result.response.try(&.status) || "?"} in #{CLI::Output.human_us(result.duration_us)}#{result.incomplete? ? " (incomplete — origin closed before the framed body finished)" : ""}"
          if d = diff
            print_diff(d)
            n = Repeater::Diff.change_count(d)
            STDERR.puts(n == 0 ? "no differences" : "#{n} line#{n == 1 ? "" : "s"} changed")
          else
            print_message_text(result.head, new_body)
          end
        else
          STDERR.puts "repeater failed: #{result.error}"
        end
        exit 1 unless result.ok?
      end

      private def self.repeater_json(result : Repeater::Result, diff : Array(Repeater::DiffLine)?) : String
        JSON.build do |j|
          j.object do
            j.field "ok", result.ok?
            j.field "status", result.response.try(&.status)
            j.field "duration_us", result.duration_us
            j.field "error", result.error
            j.field "incomplete", true if result.incomplete? # origin closed before the framed body finished
            j.field "head", scrub(result.head)
            emit_body_json(j, "body", result.head, result.body, false)
            if d = diff
              j.field "changed_lines", Repeater::Diff.change_count(d)
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
          p.on("--null=N", "Payload set: N empty payloads") { |v| sources << Fuzz::NullPayloads.new(parse_count(v, "--null")) }
          p.on("--brute=SPEC", "Payload set: CHARSET:MIN-MAX (e.g. abc:1-3)") { |v| sources << parse_brute(v) }
          p.on("--prefix=STR", "Processing: prepend STR to each payload") { |v| processors << Fuzz::Prefix.new(v) }
          p.on("--suffix=STR", "Processing: append STR to each payload") { |v| processors << Fuzz::Suffix.new(v) }
          p.on("--encode=KIND", "Processing: url | urlall | base64 | hex") { |v| processors << Fuzz::Encode.new(parse_encode(v)) }
          p.on("--case=KIND", "Processing: upper | lower") { |v| processors << Fuzz::Case.new(parse_case(v)) }
          p.on("--hash=ALGO", "Processing: md5 | sha1 | sha256") { |v| processors << Fuzz::Hasher.new(parse_hash(v)) }
          p.on("--regex-replace=SPEC", "Processing: /pattern/replacement/") { |v| processors << parse_regex_replace(v) }
          p.on("--concurrency=N", "Parallel requests (default 20)") { |v| concurrency = parse_count(v, "--concurrency") }
          p.on("--rate=RPS", "Cap requests/sec (0 = unlimited)") { |v| rate = parse_rate(v) }
          p.on("--throttle=MS", "Fixed delay between requests (ms)") { |v| throttle = parse_nonneg(v, "--throttle") }
          p.on("--timeout=SEC", "Per-request connect + idle timeout (seconds)") { |v| timeout = parse_count(v, "--timeout").seconds }
          p.on("--retries=N", "Retries on a network error") { |v| retries = parse_nonneg(v, "--retries") }
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

        hydrate_project_env(project_name, db_path) if (project_name || db_path) && flow_id.nil?
        text, default_target, src_h2 = fuzz_source(flow_id, request_file, project_name, db_path)
        text = Env.expand(text)
        default_target = default_target.try { |t| Env.expand(t) }
        template = build_fuzz_template(text, auto, marks, force_h2 || src_h2)
        scheme, host, port = resolve_fuzz_target(target_override, default_target)

        sets = sources.map { |src| Fuzz::PayloadSet.new(src, processors) }
        abort "gori run fuzz: no payloads — add -w/--payloads/--numbers/--null/--brute" if sets.empty?
        matcher.auto_calibrate = auto_cal

        config = Fuzz::Config.new(mode: mode, concurrency: concurrency, rps: rate, throttle_ms: throttle,
          retries: retries, timeout: timeout, follow_redirects: follow, auto_calibrate: auto_cal, keep_bodies: :none)
        gen_sets = mode.per_position? ? sets : [sets.first]
        generator = Fuzz::Generator.new(template, gen_sets, config, registry: Decoder.shared_registry)
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
          built = Repeater::FlowRequest.build(detail)
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
        marks.each do |tok|
          occ = mark_occurrences(text, tok)
          STDERR.puts "gori run fuzz: note: --mark #{tok.inspect} matches #{occ} positions (including any in headers)" if occ > 1
          text = text.gsub(tok, "#{m}#{tok}#{m}")
        end
        template = Fuzz::Template.parse(text, http2)
        abort "gori run fuzz: no positions — add §…§ markers, --auto, or --mark TOKEN" if template.position_count == 0
        template
      end

      # How many times a literal --mark TOKEN occurs in the template text — a
      # short/common token (e.g. "A") can match many spots including request
      # headers, silently exploding the position count. Non-overlapping count
      # (mirrors String#gsub's own scan), so it matches exactly what gets marked.
      private def self.mark_occurrences(text : String, tok : String) : Int32
        return 0 if tok.empty?
        count = 0
        idx = 0
        while found = text.index(tok, idx)
          count += 1
          idx = found + tok.size
        end
        count
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
        return unless STDERR.tty? # the \r-redrawn meter only makes sense on a terminal
        STDERR.print "\r[fuzz] #{ev.progress.sent}/#{total || "?"} · #{ev.progress.matched} hits"
        STDERR.flush
      end

      private def self.fuzz_done(ev : Fuzz::DoneEvent, emitted : Int32) : Nil
        STDERR.print "\r" if STDERR.tty? # clear the in-place meter (none was drawn when piped)
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

      private def self.hydrate_project_env(project_name : String?, db_path : String?) : Nil
        store = open_store(resolve_read_project(project_name, db_path))
        store.close
      end

      private def self.resolve_fuzz_target(override : String?, default_target : String?) : {String, String, Int32}
        target = Env.expand(override || default_target || abort("gori run fuzz: --target is required for --request/stdin"))
        scheme, host, port = Repeater::FlowRequest.parse_target(target)
        abort "gori run fuzz: could not determine a target host" if host.empty?
        abort "gori run fuzz: unsupported target scheme #{scheme.inspect} (use http:// or https://)" unless scheme.in?("http", "https")
        {scheme, host, port}
      end

      # --- mine (param discovery) --------------------------------------------

      private def self.cmd_mine(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        flow_id : Int64? = nil
        request_file : String? = nil
        target_override : String? = nil
        sni : String? = nil
        force_h2 = false
        insecure = false
        locations = [] of Miner::Location
        wordlist : String? = nil
        bucket : Int32? = nil
        concurrency = 10
        rate : Float64? = nil
        throttle : Int32? = nil
        timeout : Time::Span? = nil
        retries = 1
        max_requests : Int64? = nil
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run mine [<flow-id>] [options]"
          p.on("--flow=ID", "Seed the request from a captured flow") { |v| flow_id = parse_flow_id(v) }
          p.on("--request=FILE", "Read a raw HTTP request to mine") { |v| request_file = v }
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--target=URL", "Origin (scheme://host[:port]); required for --request/stdin") { |v| target_override = v }
          p.on("--http2", "Force HTTP/2") { force_h2 = true }
          p.on("--sni=HOST", "TLS SNI override") { |v| sni = v }
          p.on("-k", "--insecure-upstream", "Do not verify upstream TLS certificates") { insecure = true }
          p.on("--locations=LIST", "Where to mine: query,form,multipart,json,headers,cookies (default: auto-detect)") { |v| locations = parse_mine_locations(v) }
          p.on("--wordlist=PATH", "Extra param-name wordlist (merged with the built-in list)") { |v| wordlist = v }
          p.on("--bucket=N", "Names stuffed per request before bisection (per location)") { |v| bucket = parse_count(v, "--bucket") }
          p.on("--concurrency=N", "Parallel requests (default 10)") { |v| concurrency = parse_count(v, "--concurrency") }
          p.on("--rate=RPS", "Cap requests/sec (0 = unlimited)") { |v| rate = parse_rate(v) }
          p.on("--throttle=MS", "Fixed delay between requests (ms)") { |v| throttle = parse_nonneg(v, "--throttle") }
          p.on("--timeout=SEC", "Per-request connect + idle timeout (seconds)") { |v| timeout = parse_count(v, "--timeout").seconds }
          p.on("--retries=N", "Retries on a network error") { |v| retries = parse_nonneg(v, "--retries") }
          p.on("--max-requests=N", "Hard cap on total requests sent") { |v| max_requests = parse_count(v, "--max-requests").to_i64 }
          p.on("--format=FMT", "Output: text (default) | json | jsonl") { |v| format = parse_format(v, [:text, :json, :jsonl]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run mine: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run mine: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run mine: too many arguments (expected at most one <flow-id>)" if positional.size > 1
        flow_id ||= positional.first?.try { |s| parse_flow_id(s) }

        bytes, default_target, src_h2 = mine_source(flow_id, request_file, project_name, db_path)
        scheme, host, port = resolve_mine_target(target_override, default_target)
        http2 = force_h2 || src_h2

        config = Miner::Config.new
        config.locations = locations.empty? ? Miner::Detect.detect(bytes).default : locations
        abort "gori run mine: no applicable locations for this request" if config.locations.empty?
        config.concurrency = concurrency
        config.rps = rate
        config.throttle_ms = throttle
        config.timeout = timeout
        config.retries = retries
        config.max_requests = max_requests
        config.user_wordlist = wordlist
        if b = bucket
          config.locations.each { |loc| config.bucket_size[loc] = b }
        end

        names = begin
          Miner::Wordlist.load(wordlist)
        rescue ex
          abort "gori run mine: wordlist error: #{ex.message}"
        end
        sender = Fuzz::Sender.new(Fuzz::Origin.new(scheme, host, port),
          http2: http2, verify: !insecure, sni: sni, timeout: timeout)
        engine = Miner::Engine.new(bytes, http2, names, sender, config)
        run_mine_stream(engine, scheme, host, port, config, format)
      end

      # {request bytes (byte-exact), default target, http2} from the chosen source.
      private def self.mine_source(flow_id : Int64?, request_file : String?,
                                   project_name : String?, db_path : String?) : {Bytes, String?, Bool}
        if file = request_file
          abort "gori run mine: not a readable file: #{file}" unless File.file?(file)
          {Env.expand_wire(File.read(file)), nil, false}
        elsif id = flow_id
          store = open_store(resolve_read_project(project_name, db_path))
          detail = begin
            store.get_flow(id)
          ensure
            store.close
          end
          abort "gori run mine: no flow ##{id}" unless detail
          built = Repeater::FlowRequest.build(detail)
          {Env.expand_wire(String.new(built.bytes)), built.target, built.http2}
        elsif !STDIN.tty?
          {Env.expand_wire(STDIN.gets_to_end), nil, false}
        else
          abort "gori run mine: no source — give a <flow-id>, --request FILE, or pipe a request on stdin"
        end
      end

      private def self.resolve_mine_target(override : String?, default_target : String?) : {String, String, Int32}
        target = Env.expand(override || default_target || abort("gori run mine: --target is required for --request/stdin"))
        scheme, host, port = Repeater::FlowRequest.parse_target(target)
        abort "gori run mine: could not determine a target host" if host.empty?
        abort "gori run mine: unsupported target scheme #{scheme.inspect} (use http:// or https://)" unless scheme.in?("http", "https")
        {scheme, host, port}
      end

      private def self.parse_mine_locations(v : String) : Array(Miner::Location)
        v.split(',').compact_map do |tok|
          next if tok.strip.empty?
          Miner::Location.parse?(tok) || abort("gori run mine: unknown location '#{tok}' (query|form|multipart|json|headers|cookies)")
        end
      end

      private def self.run_mine_stream(engine : Miner::Engine, scheme : String, host : String,
                                       port : Int32, config : Miner::Config, format : Symbol) : Nil
        total = engine.total_names
        STDERR.puts "mining #{scheme}://#{host}:#{port} · #{config.locations.map(&.label).join("/")} · #{total} names"
        findings = [] of Miner::Finding
        had_error = false
        engine.run do |ev|
          case ev
          when Miner::BaselineEvent then mine_baseline(ev)
          when Miner::FindingEvent  then findings << ev.finding; emit_mine_finding(ev.finding, format)
          when Miner::ProgressEvent then mine_progress(ev, total)
          when Miner::DoneEvent     then mine_done(ev, findings.size)
          when Miner::ErrorEvent    then had_error = true; STDERR.puts "mine error: #{ev.message}"
          end
        end
        puts CLI::Output.mine_array_json(findings) if format == :json
        exit 1 if had_error
      end

      private def self.mine_baseline(ev : Miner::BaselineEvent) : Nil
        note = ev.stable ? "stable" : "UNSTABLE"
        note += " — #{ev.warning}" if ev.warning
        STDERR.puts "baseline: #{note}"
      end

      private def self.emit_mine_finding(f : Miner::Finding, format : Symbol) : Nil
        case format
        when :jsonl then puts CLI::Output.mine_row_json(f)
        when :json  then nil # buffered, printed once at the end
        else             puts CLI::Output.mine_row_text(f)
        end
      end

      private def self.mine_progress(ev : Miner::ProgressEvent, total : Int64) : Nil
        return unless STDERR.tty? # the \r-redrawn meter only makes sense on a terminal
        p = ev.progress
        STDERR.print "\r[mine] #{p.names_done}/#{total} names · #{p.found} found · #{p.sent} sent"
        STDERR.flush
      end

      private def self.mine_done(ev : Miner::DoneEvent, found : Int32) : Nil
        STDERR.print "\r" if STDERR.tty? # clear the in-place meter (none was drawn when piped)
        STDERR.puts "done · #{found} found · #{ev.progress.sent} sent · #{ev.progress.errors} errors#{ev.stopped ? " (stopped)" : ""}"
      end

      # --- sequence (token randomness analysis) ------------------------------

      private def self.cmd_sequence(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        flow_id : Int64? = nil
        request_file : String? = nil
        tokens_file : String? = nil
        target_override : String? = nil
        sni : String? = nil
        force_h2 = false
        insecure = false
        kind : Sequencer::ExtractKind? = nil
        selector = ""
        pos_a = 0
        pos_b = 0
        count = 500
        concurrency = 1
        rate : Float64? = nil
        throttle : Int32? = nil
        timeout : Time::Span? = nil
        retries = 1
        max_requests : Int64? = nil
        format = :text
        positional = [] of String

        set_loc = ->(k : Sequencer::ExtractKind, v : String) {
          abort "gori run sequence: pick ONE token location (--cookie/--header/--regex/--position/--jsonpath)" if kind
          kind = k
          selector = v
        }

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run sequence [<flow-id>] [options]"
          p.on("--flow=ID", "Seed the request from a captured flow (live replay)") { |v| flow_id = parse_flow_id(v) }
          p.on("--request=FILE", "Read a raw HTTP request to replay (live)") { |v| request_file = v }
          p.on("--tokens=FILE", "Analyze pasted tokens (one per line; '-' = stdin) — no network") { |v| tokens_file = v }
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--target=URL", "Origin (scheme://host[:port]); required for --request/stdin") { |v| target_override = v }
          p.on("--http2", "Force HTTP/2") { force_h2 = true }
          p.on("--sni=HOST", "TLS SNI override") { |v| sni = v }
          p.on("-k", "--insecure-upstream", "Do not verify upstream TLS certificates") { insecure = true }
          p.on("--cookie=NAME", "Extract the token from a Set-Cookie value by name") { |v| set_loc.call(Sequencer::ExtractKind::Cookie, v) }
          p.on("--header=NAME", "Extract the token from a response header") { |v| set_loc.call(Sequencer::ExtractKind::Header, v) }
          p.on("--regex=RE", "Extract the token via regex capture group 1 over the body") { |v| set_loc.call(Sequencer::ExtractKind::Regex, v) }
          p.on("--position=A:B", "Extract a fixed byte range of the body") { |v| set_loc.call(Sequencer::ExtractKind::Position, v) }
          p.on("--jsonpath=EXPR", "Extract the token from a JSON body path ($.a.b[0])") { |v| set_loc.call(Sequencer::ExtractKind::JsonPath, v) }
          p.on("--count=N", "Target number of tokens to collect (default 500)") { |v| count = parse_count(v, "--count") }
          p.on("--concurrency=N", "Parallel requests (default 1 — session tokens are often stateful)") { |v| concurrency = parse_count(v, "--concurrency") }
          p.on("--rate=RPS", "Cap requests/sec (0 = unlimited)") { |v| rate = parse_rate(v) }
          p.on("--throttle=MS", "Fixed delay between requests (ms)") { |v| throttle = parse_nonneg(v, "--throttle") }
          p.on("--timeout=SEC", "Per-request connect + idle timeout (seconds)") { |v| timeout = parse_count(v, "--timeout").seconds }
          p.on("--retries=N", "Retries on a network error") { |v| retries = parse_nonneg(v, "--retries") }
          p.on("--max-requests=N", "Hard cap on total requests sent") { |v| max_requests = parse_count(v, "--max-requests").to_i64 }
          p.on("--format=FMT", "Output: text (default) | json | jsonl") { |v| format = parse_format(v, [:text, :json, :jsonl]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run sequence: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run sequence: missing value for #{f}" }
        end
        parser.parse(args)

        # Manual mode — analyze a token list, no network.
        if tf = tokens_file
          tokens = read_token_list(tf)
          abort "gori run sequence: no tokens to analyze" if tokens.empty?
          emit_sequence_report(Sequencer::Stats.analyze(tokens), format)
          return
        end

        abort "gori run sequence: too many arguments (expected at most one <flow-id>)" if positional.size > 1
        flow_id ||= positional.first?.try { |s| parse_flow_id(s) }
        k = kind
        abort "gori run sequence: specify a token location (--cookie/--header/--regex/--position/--jsonpath) or use --tokens" unless k

        bytes, default_target, src_h2 = mine_source_for("sequence", flow_id, request_file, project_name, db_path)
        scheme, host, port = resolve_target_for("sequence", target_override, default_target)
        http2 = force_h2 || src_h2
        token_loc = build_token_loc(k, selector, "sequence")

        config = Sequencer::Config.new(mode: Sequencer::Mode::LiveReplay, token_loc: token_loc, goal: count, concurrency: concurrency)
        config.rps = rate
        config.throttle_ms = throttle
        config.timeout = timeout
        config.retries = retries
        config.max_requests = max_requests
        sender = Fuzz::Sender.new(Fuzz::Origin.new(scheme, host, port),
          http2: http2, verify: !insecure, sni: sni, timeout: timeout)
        engine = Sequencer::Engine.new(bytes, http2, sender, config)
        run_sequence_stream(engine, scheme, host, port, token_loc, count, format)
      end

      private def self.read_token_list(file : String) : Array(String)
        raw = file == "-" ? STDIN.gets_to_end : (File.file?(file) ? File.read(file) : abort("gori run sequence: not a readable file: #{file}"))
        raw.split(/\r?\n/).map(&.strip).reject(&.empty?)
      end

      private def self.build_token_loc(kind : Sequencer::ExtractKind, selector : String, cmd : String) : Sequencer::TokenLoc
        if kind.position?
          a, _, b = selector.partition(':')
          ai = a.to_i? || abort("gori run #{cmd}: --position needs A:B byte offsets")
          bi = b.to_i? || abort("gori run #{cmd}: --position needs A:B byte offsets")
          Sequencer::TokenLoc.new(kind, "", ai, bi)
        else
          abort "gori run #{cmd}: token location selector is empty" if selector.strip.empty?
          Sequencer::TokenLoc.new(kind, selector)
        end
      end

      # Shared with cmd_sequence (same shape as mine_source/resolve_mine_target but with a
      # subcommand-name prefix on the abort messages).
      private def self.mine_source_for(cmd : String, flow_id : Int64?, request_file : String?,
                                       project_name : String?, db_path : String?) : {Bytes, String?, Bool}
        if file = request_file
          abort "gori run #{cmd}: not a readable file: #{file}" unless File.file?(file)
          {Env.expand_wire(File.read(file)), nil, false}
        elsif id = flow_id
          store = open_store(resolve_read_project(project_name, db_path))
          detail = begin
            store.get_flow(id)
          ensure
            store.close
          end
          abort "gori run #{cmd}: no flow ##{id}" unless detail
          built = Repeater::FlowRequest.build(detail)
          {Env.expand_wire(String.new(built.bytes)), built.target, built.http2}
        elsif !STDIN.tty?
          {Env.expand_wire(STDIN.gets_to_end), nil, false}
        else
          abort "gori run #{cmd}: no source — give a <flow-id>, --request FILE, or pipe a request on stdin"
        end
      end

      private def self.resolve_target_for(cmd : String, override : String?, default_target : String?) : {String, String, Int32}
        target = Env.expand(override || default_target || abort("gori run #{cmd}: --target is required for --request/stdin"))
        scheme, host, port = Repeater::FlowRequest.parse_target(target)
        abort "gori run #{cmd}: could not determine a target host" if host.empty?
        abort "gori run #{cmd}: unsupported target scheme #{scheme.inspect} (use http:// or https://)" unless scheme.in?("http", "https")
        {scheme, host, port}
      end

      private def self.run_sequence_stream(engine : Sequencer::Engine, scheme : String, host : String,
                                           port : Int32, loc : Sequencer::TokenLoc, goal : Int32, format : Symbol) : Nil
        STDERR.puts "sequencing #{scheme}://#{host}:#{port} · #{loc.label} · goal #{goal}"
        tokens = [] of String
        had_error = false
        engine.run do |ev|
          case ev
          when Sequencer::SampleEvent
            s = ev.sample
            s.token.try { |t| tokens << t }
            puts CLI::Output.sequence_sample_json(s) if format == :jsonl
          when Sequencer::ProgressEvent then sequence_progress(ev, goal)
          when Sequencer::DoneEvent     then sequence_done(ev, tokens.size)
          when Sequencer::ErrorEvent    then had_error = true; STDERR.puts "sequence error: #{ev.message}"
          end
        end
        emit_sequence_report(Sequencer::Stats.analyze(tokens), format)
        exit 1 if had_error
      end

      private def self.sequence_progress(ev : Sequencer::ProgressEvent, goal : Int32) : Nil
        return unless STDERR.tty?
        STDERR.print "\r[seq] #{ev.collected}/#{goal} collected · #{ev.sent} sent · #{ev.errors} err"
        STDERR.flush
      end

      private def self.sequence_done(ev : Sequencer::DoneEvent, collected : Int32) : Nil
        STDERR.print "\r" if STDERR.tty?
        STDERR.puts "done · #{collected} collected · #{ev.sent} sent#{ev.stopped ? " (stopped)" : ""}"
      end

      # In jsonl mode the samples already streamed, so append the final report as a JSON
      # line; text prints the human table, json prints the report object.
      private def self.emit_sequence_report(rep : Sequencer::Stats::Report, format : Symbol) : Nil
        case format
        when :json, :jsonl then puts Sequencer::Present.report_json(rep)
        else                    puts Sequencer::Present.report_text(rep)
        end
      end

      # --- discover (spider + directory brute-force) -------------------------

      # `gori run oast` — headless out-of-band listener (interactsh & friends). Store-free
      # and ad-hoc: register a payload, print it, then stream decrypted callbacks.
      private def self.cmd_oast(args : Array(String)) : Nil
        case sub = args.first?
        when "presets"           then oast_presets
        when "listen"            then oast_listen(args[1..])
        when nil, "-h", "--help" then oast_help
        else
          STDERR.puts "gori run oast: unknown subcommand '#{sub}'"
          oast_help
          exit 1
        end
      end

      private def self.oast_help : Nil
        puts <<-HELP
        Usage: gori run oast <subcommand>
          listen    Register an OAST payload and stream incoming callbacks
          presets   List the built-in public providers

        Run `gori run oast listen -h` for listen options.
        HELP
      end

      private def self.oast_presets : Nil
        Oast::Presets.all.each do |p|
          puts "#{p.kind.label.ljust(13)} #{p.name.ljust(34)} #{p.host}"
        end
      end

      private def self.oast_listen(args : Array(String)) : Nil
        provider = "interactsh"
        server : String? = nil
        token : String? = nil
        interval = 5
        json = false
        once = false
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run oast listen [options]"
          p.on("--provider=KIND", "interactsh (default) | custom-http | webhook.site | BOAST | postbin") { |v| provider = v }
          p.on("--server=URL", "Provider server/base URL (default: the provider's public preset)") { |v| server = v }
          p.on("--token=TOK", "Optional provider auth token") { |v| token = v }
          p.on("--interval=SEC", "Poll interval seconds (default 5)") { |v| interval = parse_count(v, "--interval") }
          p.on("--once", "Poll once and exit (no loop)") { once = true }
          p.on("--json", "Emit each callback as a JSON line (same shape as MCP)") { json = true }
          p.on("-h", "--help") { puts p; exit 0 }
        end
        parser.parse(args)

        kind = Oast::ProviderKind.parse?(provider)
        unless kind
          STDERR.puts "gori run oast: unknown provider '#{provider}'"
          exit 1
        end
        host = server || Oast::Presets.all.find { |pr| pr.kind == kind }.try(&.host)
        unless host
          STDERR.puts "gori run oast: --server is required for #{kind.label}"
          exit 1
        end
        prov = Oast::Provider.build(kind, host, token)
        http = Oast::HttpClient.new
        session = begin
          prov.register(http)
        rescue ex
          STDERR.puts "gori run oast: register failed: #{ex.message}"
          exit 1
        end
        payload = prov.generate_payload(session)
        STDERR.puts "listening on #{host} (#{kind.label}) — payload:"
        puts payload
        STDERR.puts "waiting for callbacks (Ctrl-C to stop)…" unless once
        seen = Set(String).new
        loop do
          interactions = begin
            prov.poll(http, session)
          rescue ex
            STDERR.puts "poll error: #{ex.message}"
            [] of Oast::Interaction
          end
          interactions.each do |i|
            next if seen.includes?(i.unique_id)
            seen << i.unique_id
            if json
              puts Oast::Present.interaction(i, kind.label).to_json
            else
              puts "#{i.at.to_rfc3339}  #{i.protocol}\t#{i.method || "-"}\t#{i.source_ip || "-"}\t#{i.full_id}"
            end
            STDOUT.flush
          end
          break if once
          sleep interval.seconds
        end
        prov.deregister(http, session) if once
      end

      private def self.cmd_discover(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        target_override : String? = nil
        max_depth = 4
        spider = true
        bruteforce = true
        containment = Discover::Containment::ScopeAware
        wordlist : String? = nil
        extensions = [] of String
        concurrency = 20
        rate : Float64? = nil
        throttle : Int32? = nil
        timeout : Time::Span? = nil
        retries = 1
        max_requests : Int64? = nil
        insecure = false
        allow_unscoped = false
        force = false
        no_store = false
        format = :text
        headers = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run discover --target URL [options]"
          p.on("--target=URL", "Seed origin or path subtree to explore (required)") { |v| target_override = v }
          p.on("--project=NAME", "Project for scope rules + storing findings") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file") { |v| db_path = v }
          p.on("--max-depth=N", "Spider depth from the seed (default 4)") { |v| max_depth = parse_nonneg(v, "--max-depth") }
          p.on("--no-spider", "Disable link crawling (brute-force only)") { spider = false }
          p.on("--no-bruteforce", "Disable directory brute-forcing (crawl only)") { bruteforce = false }
          p.on("--wordlist=PATH", "Extra path wordlist (merged with the built-in list)") { |v| wordlist = v }
          p.on("--extensions=LIST", "Also probe these extensions (e.g. php,json,bak)") { |v| extensions = parse_extensions(v) }
          p.on("-HHEADER", "--header=HEADER", "Custom request header on every probe, e.g. \"Authorization: Bearer …\" (repeatable)") { |v| headers << v }
          p.on("--containment=MODE", "same-origin | scope-aware (default) | host+subdomains") { |v| containment = parse_containment(v) }
          p.on("--concurrency=N", "Parallel requests (default 20)") { |v| concurrency = parse_count(v, "--concurrency") }
          p.on("--rate=RPS", "Cap requests/sec (0 = unlimited)") { |v| rate = parse_rate(v) }
          p.on("--throttle=MS", "Fixed delay between requests (ms)") { |v| throttle = parse_nonneg(v, "--throttle") }
          p.on("--timeout=SEC", "Per-request connect + idle timeout (seconds)") { |v| timeout = parse_count(v, "--timeout").seconds }
          p.on("--retries=N", "Retries on a network error") { |v| retries = parse_nonneg(v, "--retries") }
          p.on("--max-requests=N", "Hard cap on total requests sent") { |v| max_requests = parse_count(v, "--max-requests").to_i64 }
          p.on("-k", "--insecure-upstream", "Do not verify upstream TLS certificates") { insecure = true }
          p.on("--allow-unscoped", "Run even if the target is outside the project scope") { allow_unscoped = true }
          p.on("--force", "Bypass the unbounded-run safety gate") { force = true }
          p.on("--no-store", "Do not write findings into the project (Sitemap)") { no_store = true }
          p.on("--format=FMT", "Output: text (default) | json | jsonl") { |v| format = parse_format(v, [:text, :json, :jsonl]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run discover: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run discover: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run discover: --no-spider and --no-bruteforce can't both be set" unless spider || bruteforce
        seed_url = resolve_discover_seed(target_override)

        project = resolve_discover_project(project_name, db_path)
        store = open_store(project)
        begin
          scope = Scope.load(store)
          guard_discover_scope(seed_url, scope, allow_unscoped)

          config = Discover::Config.new(
            concurrency: concurrency, rps: rate, throttle_ms: throttle, timeout: timeout,
            retries: retries, max_requests: max_requests, spider: spider, bruteforce: bruteforce,
            max_depth: max_depth, extensions: extensions, containment: containment,
            headers: Discover::Headers.parse_lines(headers))
          words = begin
            Discover::Wordlist.load(wordlist)
          rescue ex
            abort "gori run discover: wordlist error: #{ex.message}"
          end
          policy : Discover::ScopePolicy = scope.configured? ? Discover::StoreScope.new(scope) : Discover::OpenScope.new
          sender = Discover::Sender.new(verify: !insecure, timeout: timeout, headers: config.headers)
          engine = Discover::Engine.new(seed_url, words, sender, config, policy)
          discover_preflight(seed_url, config, words.size, force)
          run_discover_stream(engine, store, format, no_store)
        ensure
          store.close
        end
      end

      # Discover WRITES findings, so an explicit --db is create-or-reopened (like capture);
      # without one it writes into an existing project (never silently creates a default).
      private def self.resolve_discover_project(project_name : String?, db_path : String?) : Project
        if path = db_path
          abort "gori run discover: --db is a directory, not a file: #{path}" if Dir.exists?(path)
          parent = File.dirname(path)
          abort "gori run discover: --db parent directory does not exist: #{parent}" unless Dir.exists?(parent)
          return Project.new(File.basename(parent), path)
        end
        resolve_read_project(project_name, nil)
      end

      private def self.resolve_discover_seed(target : String?) : String
        raw = Env.expand(target || abort("gori run discover: --target URL is required"))
        seed = raw.matches?(/\Ahttps?:\/\//i) ? raw : "https://#{raw}"
        abort "gori run discover: invalid --target #{raw.inspect} (use http:// or https://)" unless Discover::Url.parse(seed)
        seed
      end

      private def self.guard_discover_scope(seed_url : String, scope : Scope, allow_unscoped : Bool) : Nil
        return if allow_unscoped || !scope.configured?
        p = Discover::Url.parse(seed_url)
        return unless p
        return if scope.matches_url?(seed_url, p.host)
        abort "gori run discover: #{seed_url} is out of the project scope — add a scope include rule or pass --allow-unscoped"
      end

      private def self.parse_extensions(v : String) : Array(String)
        v.split(',').compact_map do |tok|
          t = tok.strip.lchop('.')
          t.empty? ? nil : t
        end
      end

      private def self.parse_containment(v : String) : Discover::Containment
        Discover::Containment.parse?(v) || abort("gori run discover: invalid --containment '#{v}' (same-origin|scope-aware|host+subdomains)")
      end

      private def self.discover_preflight(seed_url : String, config : Discover::Config, words : Int32, force : Bool) : Nil
        techniques = [] of String
        techniques << "spider(d#{config.max_depth})" if config.spider?
        techniques << "brute(#{words}w)" if config.bruteforce?
        STDERR.puts "discovering #{seed_url} · #{techniques.join("+")} · #{config.containment.label}"
        if config.max_requests.nil? && config.spider? && config.max_depth >= 8 && !force
          abort "gori run discover: a depth-#{config.max_depth} crawl with no --max-requests could send a lot; pass --max-requests / a lower --max-depth, or --force"
        end
      end

      private def self.run_discover_stream(engine : Discover::Engine, store : Store,
                                           format : Symbol, no_store : Bool) : Nil
        findings = [] of Discover::Finding
        pending = [] of {Store::CapturedRequest, Store::CapturedResponse?}
        base_ts = Time.utc.to_unix * 1_000_000
        had_error = false
        engine.run do |ev|
          case ev
          when Discover::FindingEvent
            f = ev.finding
            findings << f
            emit_discover_finding(f, format)
            unless no_store
              pair = Discover::Persist.flow_pair(f, base_ts + findings.size)
              pending << {pair.request, pair.response}
              flush_discover(store, pending) if pending.size >= 200
            end
          when Discover::ProgressEvent then discover_progress(ev)
          when Discover::DoneEvent     then discover_done(ev)
          when Discover::ErrorEvent    then had_error = true; STDERR.puts "discover error: #{ev.message}"
          end
        end
        # Flush after the loop (not in the Done branch): an error terminates with an ErrorEvent
        # and no DoneEvent, but findings discovered before it should still reach the Sitemap.
        flush_discover(store, pending) unless no_store
        puts CLI::Output.discover_array_json(findings) if format == :json
        exit 1 if had_error
      end

      private def self.flush_discover(store : Store,
                                      pending : Array({Store::CapturedRequest, Store::CapturedResponse?})) : Nil
        return if pending.empty?
        store.insert_import_batch(pending)
        pending.clear
      end

      private def self.emit_discover_finding(f : Discover::Finding, format : Symbol) : Nil
        case format
        when :jsonl then puts CLI::Output.discover_row_json(f)
        when :json  then nil # buffered, printed once at the end
        else             puts CLI::Output.discover_row_text(f)
        end
      end

      private def self.discover_progress(ev : Discover::ProgressEvent) : Nil
        return unless STDERR.tty?
        p = ev.progress
        STDERR.print "\r[discover] #{p.found} found · #{p.sent} sent · #{p.queued} queued"
        STDERR.flush
      end

      private def self.discover_done(ev : Discover::DoneEvent) : Nil
        STDERR.print "\r" if STDERR.tty?
        s = ev.stats
        STDERR.puts "done · #{s.found} found · #{s.sent} sent · #{ev.progress.errors} errors" \
                    " · calibrated-out #{s.calibrated_out} · dedup #{s.dedup_suppressed}" \
                    " · template #{s.template_suppressed} · cluster #{s.cluster_suppressed}#{ev.stopped ? " (stopped)" : ""}"
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

      private def self.parse_nonneg(v : String, flag : String? = nil) : Int32
        n = v.to_i?
        abort "gori run: invalid #{flag || "count"} '#{v}' (expected a non-negative integer)" unless n && n >= 0
        n
      end

      private def self.parse_regex_replace(v : String) : Fuzz::RegexReplace
        abort "gori run fuzz: --regex-replace needs /pattern/replacement/" if v.size < 3
        delim = v[0]
        parts = v[1..].split(delim)
        abort "gori run fuzz: --regex-replace must be #{delim}pattern#{delim}replacement#{delim}" if parts.size < 2
        Fuzz::RegexReplace.new(parse_regex(parts[0]), parts[1])
      end

      # --- probe (passive scan) ----------------------------------------------

      # The categories a PASSIVE scan can emit. Probe::Category::ACTIVE is intentionally absent —
      # active/reflected-param detections come only from the request-sending Active scanner, which
      # this command doesn't run, so accepting `--category active` would be a guaranteed-empty filter.
      PROBE_CATEGORIES = [
        Probe::Category::HEADERS, Probe::Category::COOKIES, Probe::Category::TECH,
        Probe::Category::INFOLEAK, Probe::Category::CORS, Probe::Category::CLIENT,
      ]

      private def self.cmd_probe(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        query : String? = nil
        min_sev : Store::Severity? = nil
        category : String? = nil
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run probe [QL query] [options]\n\n" \
                     "Passively scan captured History flows AND Repeater responses (zero outbound\n" \
                     "requests) and report grouped issues — the headless equivalent of the TUI Probe\n" \
                     "tab. QL filters apply to History only; all Repeater tabs with a stored response\n" \
                     "are scanned. The light-touch active checks (reflected params, …) send requests,\n" \
                     "so they are intentionally excluded here — arm active mode in the TUI, or reach\n" \
                     "for fuzz/mine."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("-qQL", "--query=QL", "Only scan flows matching this QL query (host: status:>=500 size: …)") { |v| query = v }
          p.on("--severity=LEVEL", "Only show issues at/above LEVEL (info|low|medium|high|critical)") { |v| min_sev = parse_severity(v) }
          p.on("--category=CAT", "Only show issues in CAT (#{PROBE_CATEGORIES.join("|")})") { |v| category = parse_probe_category(v) }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run probe: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run probe: missing value for #{f}" }
        end
        args = normalize_query_flag(args)
        neg_terms, opt_args = split_ql_negations(args)
        parser.parse(opt_args)
        # A positional QL is accepted too ("gori run probe status:>=500" / "-status:200"),
        # mirroring history; an explicit --query wins. Terms join with spaces (QL ANDs them).
        positional_query = (positional + neg_terms).join(' ')
        query ||= positional_query unless positional_query.empty?

        filter : QL::Filter? = nil
        if q = query
          parsed = QL.parse(q)
          QL.invalid_regex_terms(q).each do |t|
            STDERR.puts "gori run probe: warning: invalid regex in #{t.inspect} — that term matches nothing"
          end
          # A query that compiles to NOTHING (e.g. `status:>=foo`) becomes the match-all EMPTY
          # filter — here that would scan every flow, the opposite of what was asked. Refuse it.
          if !q.strip.empty? && parsed == QL::EMPTY
            abort "gori run probe: query #{q.inspect} did not match any field (check syntax, e.g. status:>=500 host:example.com method:POST)"
          end
          filter = parsed
        end

        store = open_store(resolve_read_project(project_name, db_path))
        groups, flow_n, repeater_n = begin
          ids = begin
            probe_scan_ids(store, filter)
          rescue ex
            abort "gori run probe: query #{query.inspect} failed: #{ex.message}"
          end
          dets, rn = scan_all(store, ids)
          {Probe.group(dets), ids.size, rn}
        ensure
          store.close
        end

        if ms = min_sev
          groups = groups.select { |g| g.severity.value >= ms.value }
        end
        if cat = category
          groups = groups.select { |g| g.category == cat }
        end
        report_probe(groups, flow_n, repeater_n, format, query, min_sev, category)
      end

      private def self.report_probe(groups : Array(Probe::Group), flow_n : Int32, repeater_n : Int32,
                                    format : Symbol, query : String?, min_sev : Store::Severity?,
                                    category : String?) : Nil
        parts = [] of String
        parts << "#{flow_n} flow#{flow_n == 1 ? "" : "s"}"
        parts << "#{repeater_n} repeater#{repeater_n == 1 ? "" : "s"}" if repeater_n > 0 || query.nil?
        STDERR.puts "scanned #{parts.join(" + ")} · #{groups.size} issue#{groups.size == 1 ? "" : "s"}"
        if format == :json
          puts CLI::Output.probe_array_json(groups)
        elsif groups.empty?
          scope = query ? " in flows matching #{query.inspect}" : ""
          # Distinguish "nothing found" from "filters removed everything" — else an empty result
          # under --severity/--category looks like the QL query itself matched no flows.
          STDERR.puts((min_sev || category) ? "no issues match the --severity/--category filter#{scope}" : "no issues#{scope}")
        else
          groups.each { |g| puts CLI::Output.probe_group_text(g) }
        end
      end

      # Flow IDs to scan, oldest-first (ascending id) — a stable, deterministic grouping order.
      # Reuses the proven search/recent_flows query paths.
      private def self.probe_scan_ids(store : Store, filter : QL::Filter?) : Array(Int64)
        rows = filter ? store.search(filter, Int32::MAX, raise_on_error: true) : store.recent_flows(Int32::MAX)
        rows.map(&.id).reverse! # search/recent_flows are newest-first; reverse → ascending id
      end

      # Passively analyze History flows (with responses) + every Repeater tab that has a stored
      # response. Returns {detections, repeater_count_scanned}. QL filters apply to History only.
      private def self.scan_all(store : Store, ids : Array(Int64)) : {Array(Probe::Detection), Int32}
        detections = scan_flows(store, ids)
        repeater_dets, repeater_n = scan_repeaters(store)
        detections.concat(repeater_dets)
        {detections, repeater_n}
      end

      # Passively analyze each flow THAT HAS A CAPTURED RESPONSE — mirroring the live analyzer,
      # which only scans on the `:updated` event (a response or WS upgrade exists), never on a
      # bare request. Skipping response-less flows (connect/TLS failures, still-pending) keeps
      # headless counts equal to the TUI Probe tab; otherwise request-only rules (secret_in_url,
      # some tech) would flag flows the live path never sees. Passive detections already carry
      # their source flow_id (ctx.fid). Streams one FlowDetail at a time (full BLOBs); tty meter.
      private def self.scan_flows(store : Store, ids : Array(Int64)) : Array(Probe::Detection)
        detections = [] of Probe::Detection
        progress = STDERR.tty?
        ids.each_with_index do |id, i|
          detail = store.get_flow(id)
          if detail && detail.response_head
            ws = detail.row.status == 101 ? store.ws_messages(id, 200) : [] of Store::WsMessage
            detections.concat(Probe::Passive.analyze(detail, ws))
          end
          if progress && (i & 0x3F) == 0
            STDERR.print "\r[probe] scanned #{i + 1}/#{ids.size} flows"
            STDERR.flush
          end
        end
        STDERR.print "\r\e[K" if progress # clear the in-place meter before the summary line
        detections
      end

      # Scan Repeater tabs that have a persisted response head (V11). Stamps sample_repeater_id.
      private def self.scan_repeaters(store : Store) : {Array(Probe::Detection), Int32}
        detections = [] of Probe::Detection
        n = 0
        store.repeaters.each do |rec|
          next unless detail = Probe.detail_from_repeater(rec)
          n += 1
          ws = store.ws_messages_for_repeater(rec.id, 200)
          Probe::Passive.analyze(detail, ws).each do |d|
            detections << Probe.with_source(d, flow_id: rec.flow_id, repeater_id: rec.id)
          end
        end
        {detections, n}
      end

      private def self.parse_severity(v : String) : Store::Severity
        Store::Severity.parse?(v) || abort "gori run probe: invalid --severity '#{v}' (info|low|medium|high|critical)"
      end

      private def self.parse_probe_category(v : String) : String
        d = v.downcase
        PROBE_CATEGORIES.includes?(d) ? d : abort("gori run probe: invalid --category '#{v}' (#{PROBE_CATEGORIES.join("|")})")
      end

      # --- notes -------------------------------------------------------------

      private def self.cmd_notes(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        all = false
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run notes [<n>] [options]\n\nList the project's notes; with <n> (1-based) print that note in full, or --all to print them all."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--all", "Print every note in full instead of the one-line list") { all = true }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run notes: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run notes: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run notes: too many arguments (expected at most one note number)" if positional.size > 1
        index = parse_note_index(positional.first?)
        abort "gori run notes: <n> and --all are mutually exclusive" if index && all

        store = open_store(resolve_read_project(project_name, db_path))
        doc = begin
          Notes.load(store)
        ensure
          store.close
        end

        if n = index
          abort "gori run notes: no note ##{n} (this project has #{doc.size} note#{doc.size == 1 ? "" : "s"})" unless n <= doc.size
          show_note(doc, n - 1, format)
        elsif all
          show_all_notes(doc, format)
        else
          list_notes(doc, format)
        end
      end

      private def self.parse_note_index(arg : String?) : Int32?
        return nil unless arg
        n = arg.to_i?
        abort "gori run notes: invalid note number '#{arg}' (expected a positive integer)" unless n && n > 0
        n
      end

      # Print one note (`idx` 0-based) in full: its exact text, or a full JSON object.
      private def self.show_note(doc : Notes::Doc, idx : Int32, format : Symbol) : Nil
        entry = doc.notes[idx]
        text = entry.text
        if format == :json
          puts CLI::Output.note_object_json(idx, entry, current: doc.cur == idx, with_text: true)
        else
          STDOUT.puts text
        end
      end

      private def self.show_all_notes(doc : Notes::Doc, format : Symbol) : Nil
        if format == :json
          puts CLI::Output.notes_array_json(doc, with_text: true)
        elsif doc.empty?
          STDERR.puts "no notes"
        else
          doc.texts.each_with_index do |text, i|
            puts "" if i > 0
            puts "=== note #{i + 1}: #{CLI::Output.note_label(i, text)}#{doc.cur == i ? " *" : ""} ==="
            STDOUT.puts text
          end
        end
      end

      private def self.list_notes(doc : Notes::Doc, format : Symbol) : Nil
        if format == :json
          puts CLI::Output.notes_array_json(doc, with_text: false)
        elsif doc.empty?
          STDERR.puts "no notes"
        else
          doc.texts.each_with_index { |text, i| puts CLI::Output.note_row_text(i, text, current: doc.cur == i) }
        end
      end

      # --- sitemap -----------------------------------------------------------

      private def self.cmd_sitemap(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        query : String? = nil
        limit = Store::SITEMAP_MAX
        in_scope = false
        group = true
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run sitemap [QL query] [options]\n\nPrint the deduplicated host → path endpoint tree built from the captured flows."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("-qQL", "--query=QL", "Filter endpoints with a QL query (host: method: path: status: scheme: …)") { |v| query = v }
          p.on("-nN", "--limit=N", "Max distinct endpoints to scan (default #{Store::SITEMAP_MAX})") { |v| limit = parse_count(v, "--limit") }
          p.on("--in-scope", "Only hosts in the project's configured scope") { in_scope = true }
          p.on("--no-group", "Don't fold long numeric path-segment runs (/users/1,2,3…)") { group = false }
          p.on("--format=FMT", "Output: text (default tree) | json | paths") { |v| format = parse_format(v, [:text, :json, :paths]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run sitemap: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run sitemap: missing value for #{f}" }
        end
        args = normalize_query_flag(args)
        neg_terms, opt_args = split_ql_negations(args)
        parser.parse(opt_args)
        # Accept a positional QL too ("gori run sitemap host:api" / "-status:404"), mirroring
        # history's `/` bar; an explicit --query wins. Terms join with spaces (QL ANDs).
        positional_query = (positional + neg_terms).join(' ')
        query ||= positional_query unless positional_query.empty?

        # Parse/validate the QL BEFORE opening the store: abort skips ensure blocks, so a
        # bad query must not leave a store handle open.
        filter = sitemap_filter(query)

        store = open_store(resolve_read_project(project_name, db_path))
        hosts = begin
          collect_sitemap(store, filter, limit, in_scope, group)
        rescue ex
          abort "gori run sitemap: query #{query.inspect} failed: #{ex.message}"
        ensure
          store.close
        end

        emit_sitemap(hosts, format)
      end

      # QL.parse + the same un-compilable-query rejection as history (a non-blank query
      # collapsing to EMPTY would silently dump every endpoint).
      private def self.sitemap_filter(query : String?) : QL::Filter
        return QL::EMPTY unless q = query
        filter = QL.parse(q)
        QL.invalid_regex_terms(q).each do |t|
          STDERR.puts "gori run sitemap: warning: invalid regex in #{t.inspect} — that term matches nothing"
        end
        if !q.strip.empty? && filter == QL::EMPTY
          abort "gori run sitemap: query #{q.inspect} did not match any field (check syntax, e.g. host:example.com method:POST path:/api status:>=500)"
        end
        filter
      end

      # Build + post-process the tree from the open store in the SAME ORDER as
      # SitemapView#reload (build → tags → scope → fold → counts). The scope step
      # differs by design: --in-scope filters whole hosts via Scope#host_in_scope?,
      # which evaluates the rules regardless of the TUI's persisted ⇧S enabled flag
      # (an explicit --in-scope is the opt-in). That host-level gate is coarser than
      # the TUI lens's per-flow SQL filter and conservative on url-level includes.
      private def self.collect_sitemap(store : Store, filter : QL::Filter, limit : Int32,
                                       in_scope : Bool, group : Bool) : Array(Sitemap::Node)
        hosts = Sitemap.build(store.sitemap_entries(filter, limit, raise_on_error: true))
        Sitemap.stamp_tags!(hosts, store.sitemap_tags)
        if in_scope
          scope = Scope.load(store)
          STDERR.puts "gori run sitemap: --in-scope, but no scope rules are configured — nothing is in scope" unless scope.configured?
          hosts.select! { |h| scope.host_in_scope?(h.label) }
        end
        hosts.each { |h| Sitemap.group_sequences!(h) } if group
        hosts.each { |h| h.endpoints = Sitemap.endpoint_count(h) }
        hosts
      end

      # Results → STDOUT; the empty-state note → STDERR (STDOUT-purity). JSON always
      # emits a (possibly empty) array so scripts get valid JSON either way.
      private def self.emit_sitemap(hosts : Array(Sitemap::Node), format : Symbol) : Nil
        if format == :json
          puts CLI::Output.sitemap_json(hosts)
        elsif hosts.empty?
          STDERR.puts "no endpoints (capture some traffic, or relax --in-scope / the query)"
        elsif format == :paths
          print CLI::Output.sitemap_paths(hosts)
        else
          print CLI::Output.sitemap_text(hosts)
        end
      end

      # --- issues ----------------------------------------------------------

      private def self.cmd_issues(args : Array(String)) : Nil
        if args.first? == "create"
          cmd_issues_create(args[1..])
          return
        elsif args.first? == "update"
          cmd_issues_update(args[1..])
          return
        end

        db_path : String? = nil
        project_name : String? = nil
        format = :text
        export_path : String? = nil

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run issues [options]\n\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run issues create [options]\n" \
                     "  gori run issues update <issue-id> [options]"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json | markdown") { |v| format = parse_format(v, [:text, :json, :markdown]) }
          p.on("--export=PATH", "Write to PATH instead of STDOUT") { |v| export_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run issues: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run issues: missing value for #{f}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        # Build the report while the store is open (markdown resolves linked-flow
        # evidence), then close BEFORE any file I/O so a write failure can't leak the
        # connection — and so the abort below runs after a clean close.
        result = begin
          issues = store.issues
          if issues.empty? && format == :text && export_path.nil?
            STDERR.puts "no issues"
            return
          end
          content =
            case format
            when :json     then Issues::Export.json(issues, store)
            when :markdown then Issues::Export.markdown(issues, store, project.name)
            else                issues_text(issues)
            end
          {content, issues.size}
        ensure
          store.close
        end
        content, count = result

        if path = export_path
          begin
            File.write(path, content.ends_with?('\n') ? content : "#{content}\n")
          rescue ex : File::Error
            abort "gori run issues: cannot write to #{path}: #{ex.message}"
          end
          STDERR.puts "exported #{count} issue#{count == 1 ? "" : "s"} → #{path}"
        else
          puts content
        end
      end

      private def self.cmd_issues_create(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        title : String? = nil
        sev_s = "info"
        host : String? = nil
        flow_id : Int64? = nil

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run issues create [options]"
          p.on("--project=NAME", "Project to write (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to write") { |v| db_path = v }
          p.on("-tTITLE", "--title=TITLE", "Issue title (required)") { |v| title = v }
          p.on("-sSEVERITY", "--severity=SEVERITY", "Severity: info|low|medium|high|critical (default: info)") { |v| sev_s = v }
          p.on("--host=HOST", "Host concerning the issue") { |v| host = v }
          p.on("--flow=ID", "Associated flow ID") { |v| flow_id = parse_flow_id(v) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run issues create: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run issues create: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run issues create: --title is required" if (t = title).nil? || t.empty?

        severity = Store::Severity.parse?(sev_s.strip) || abort("gori run issues create: invalid severity '#{sev_s}' (info|low|medium|high|critical)")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          masked_title = Env.mask_secrets(t)
          masked_host = host.try { |h| Env.mask_secrets(h) }
          id = store.insert_issue(masked_title, severity, masked_host, flow_id)
          abort "gori run issues create: failed to persist issue (store busy or unwritable)" if id == 0
          puts "Issue ##{id} created successfully."
        ensure
          store.close
        end
      end

      private def self.cmd_issues_update(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        id : Int64? = nil
        title : String? = nil
        sev_s : String? = nil
        notes : String? = nil
        stat_s : String? = nil

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run issues update <issue-id> [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-tTITLE", "--title=TITLE", "New issue title") { |v| title = v }
          p.on("-sSEVERITY", "--severity=SEVERITY", "Severity: info|low|medium|high|critical") { |v| sev_s = v }
          p.on("-nNOTES", "--notes=NOTES", "Free-form notes") { |v| notes = v }
          p.on("--status=STATUS", "Status: open|confirmed|false-positive|resolved") { |v| stat_s = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run issues update: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run issues update: missing value for #{f}" }
        end

        positional = [] of String
        parser.unknown_args { |rest, _| positional = rest }
        parser.parse(args)

        abort "gori run issues update: missing <issue-id>" if positional.empty?
        abort "gori run issues update: too many arguments (expected one <issue-id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run issues update: invalid issue id '#{positional[0]}'")

        severity = sev_s.try { |s| Store::Severity.parse?(s.strip) || abort("gori run issues update: invalid severity '#{s}'") }
        status = stat_s.try do |s|
          case s.strip.downcase
          when "open"                                              then Store::Status::Open
          when "confirmed"                                         then Store::Status::Confirmed
          when "false-positive", "false_positive", "falsepositive" then Store::Status::FalsePositive
          when "resolved"                                          then Store::Status::Resolved
          else                                                          abort("gori run issues update: invalid status '#{s}' (open|confirmed|false-positive|resolved)")
          end
        end

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          abort "gori run issues update: no issue with id #{id}" unless store.get_issue(id)

          if title.nil? && severity.nil? && notes.nil? && status.nil?
            abort "gori run issues update: no fields to update (provide at least one of --title/--severity/--notes/--status)"
          end

          masked_title = title.try { |t| Env.mask_secrets(t) }
          masked_notes = notes.try { |n| Env.mask_secrets(n) }

          store.update_issue(id, title: masked_title, severity: severity, notes: masked_notes, status: status)
          puts "Issue ##{id} updated successfully."
        ensure
          store.close
        end
      end

      private def self.issues_text(issues : Array(Store::Issue)) : String
        String.build do |io|
          issues.each do |f|
            io << '#' << f.id << "  [" << f.severity.label << '/' << f.status.label << "]  " << Issues::Export.one_line(f.title)
            if h = f.host
              io << "  (" << Issues::Export.one_line(h) << ')'
            end
            io << "  flow#" << f.flow_id if f.flow_id
            io << '\n'
          end
        end.rstrip('\n')
      end

      # --- jwt (decode / re-sign / attack payloads) ---------------------------
      # A store-free compute command: it operates on a token string (argument or STDIN),
      # not a captured flow — so no project/db resolution. Mirrors the TUI JWT tab + the
      # MCP jwt_* tools (all three drive the pure Gori::Jwt engine).

      private def self.cmd_jwt(args : Array(String)) : Nil
        action = :decode
        alg = "HS256"
        secret = ""
        format = :text
        positional = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run jwt [<token>] [options]\n\n" \
                     "Decode, re-sign, or generate testing payloads for a JWT. The token is read\n" \
                     "from the <token> argument, or from STDIN when none is given."
          p.on("--decode", "Decode header / payload / signature (default)") { action = :decode }
          p.on("--encode", "Re-sign the token's claims with --alg / --secret") { action = :encode }
          p.on("--attacks", "Generate testing payloads (alg:none, weak-secret, header injection)") { action = :attacks }
          p.on("--alg=ALG", "Signing alg for --encode: HS256 (default) | HS384 | HS512 | none") { |v| alg = v }
          p.on("--secret=SECRET", "HMAC secret for --encode with an HS algorithm") { |v| secret = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run jwt: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run jwt: missing value for #{f}" }
        end
        parser.parse(args)

        token = jwt_token_input(positional)
        abort "gori run jwt: no token — pass it as an argument or pipe it on STDIN" if token.empty?
        case action
        when :encode  then emit_jwt_encode(token, alg, secret, format)
        when :attacks then emit_jwt_attacks(token, format)
        else               emit_jwt_decode(token, format)
        end
      end

      private def self.jwt_token_input(positional : Array(String)) : String
        if (s = positional.first?)
          abort "gori run jwt: too many arguments (one token)" if positional.size > 1
          s.strip
        elsif !STDIN.tty?
          STDIN.gets_to_end.strip
        else
          ""
        end
      end

      private def self.emit_jwt_decode(token : String, format : Symbol) : Nil
        if format == :json
          puts Jwt.decode_json(token)
        else
          puts Decoder::Codecs.jwt_decode(token.to_slice)
        end
      rescue ex : Gori::Error
        abort "gori run jwt: #{ex.message}"
      end

      private def self.emit_jwt_encode(token : String, alg : String, secret : String, format : Symbol) : Nil
        header = Jwt.header_json(token)
        payload = Jwt.payload_json(token)
        abort "gori run jwt: not a decodable JWT (need header.payload)" if header.empty? && payload.empty?
        signed = Jwt.encode(header, payload, alg, secret)
        if format == :json
          puts JSON.build { |j| j.object { j.field "token", signed; j.field "alg", alg } }
        else
          puts signed
        end
      rescue ex : Jwt::ForgeError
        abort "gori run jwt: #{ex.message}"
      end

      private def self.emit_jwt_attacks(token : String, format : Symbol) : Nil
        attacks = Jwt.attacks(token)
        abort "gori run jwt: not a decodable JWT — no payloads generated" if attacks.empty?
        if format == :json
          puts Jwt.attacks_json(attacks)
        else
          attacks.each { |a| puts CLI::Output.jwt_attack_text(a) }
        end
      end

      # --- project (list / scope / env / host-override) -----------------------

      private def self.cmd_project(args : Array(String)) : Nil
        sub = args.first?
        case sub
        when nil
          cmd_project_list(args)
        when "-h", "--help"
          print_project_help
        when "list"
          cmd_project_list(args[1..])
        when "scope"
          cmd_project_scope(args[1..])
        when "env"
          cmd_project_env(args[1..])
        when "host-override", "host-overrides"
          cmd_project_host_override(args[1..])
        else
          # Flags only (e.g. --format json) → list projects
          if (s = sub) && s.starts_with?('-')
            cmd_project_list(args)
          else
            STDERR.puts "gori run project: unknown subcommand '#{sub}'"
            print_project_help
            exit 1
          end
        end
      end

      private def self.print_project_help : Nil
        puts <<-HELP
        gori run project — list projects, or manage project-scoped config

        Usage: gori run project [<subcommand>] [options]

        Subcommands:
          list               List known projects (default when no subcommand)
          scope              Manage scope rules (list, add, delete, enable/disable)
          env                Manage project env vars ($KEY substitution)
          host-override      Manage host overrides (list, add, update, delete)

        Examples:
          gori run project --format json
          gori run project scope add --kind=include --type=host --pattern=api.example.com
          gori run project env set TOKEN=secret
          gori run project host-override add --host=api.example.com --ip=10.0.0.1

        See 'gori run project <subcommand> --help' for more.
        HELP
      end

      private def self.cmd_project_list(args : Array(String)) : Nil
        format = :text
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project [list] [options]"
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project: missing value for #{f}" }
        end
        parser.parse(args)

        registry = ProjectRegistry.new(Paths.projects_dir)
        projects = registry.list
        if format == :json
          puts(JSON.build do |j|
            j.array do
              projects.each do |pr|
                j.object do
                  j.field "name", pr.name
                  j.field "id", registry.id_of(pr)
                  j.field "slug", registry.slug_of(pr)
                  j.field "db_path", pr.db_path
                  j.field "db_size", pr.db_size
                  j.field "last_modified", pr.last_modified.try(&.to_unix)
                  j.field "time", pr.last_modified.try(&.to_local.to_s("%Y-%m-%dT%H:%M:%S%:z"))
                end
              end
            end
          end)
        elsif projects.empty?
          STDERR.puts "no projects yet — capture some traffic (gori run capture / the TUI) first"
        else
          projects.each do |pr|
            ts = pr.last_modified.try(&.to_local.to_s("%Y-%m-%d %H:%M")) || "—"
            id = registry.id_of(pr) || "—"
            puts "#{pr.name.ljust(24)}  #{id.ljust(8)}  #{ts}  #{CLI::Output.human_size(pr.db_size)}"
          end
        end
      end

      # --- project scope -----------------------------------------------------

      private def self.cmd_project_scope(args : Array(String)) : Nil
        sub = args.first?
        case sub
        when "add"
          cmd_scope_add(args[1..])
        when "delete"
          cmd_scope_delete(args[1..])
        when "enable"
          cmd_scope_set_enabled(true, args[1..])
        when "disable"
          cmd_scope_set_enabled(false, args[1..])
        when nil
          cmd_scope_list(args)
        else
          if (s = sub) && s.starts_with?('-')
            cmd_scope_list(args)
          else
            STDERR.puts "gori run project scope: unknown subcommand '#{sub}'"
            STDERR.puts "Usage: gori run project scope [list options] | add | delete | enable | disable"
            exit 1
          end
        end
      end

      private def self.cmd_scope_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project scope [options]\n\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run project scope add --kind=include/exclude --type=host/string/regex --pattern=...\n" \
                     "  gori run project scope delete <rule-id>\n" \
                     "  gori run project scope enable\n" \
                     "  gori run project scope disable"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project scope: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project scope: missing value for #{f}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          scope = Scope.load(store)
          if format == :json
            puts(JSON.build do |j|
              j.object do
                j.field "enabled", scope.enabled?
                j.field "rules" do
                  j.array do
                    scope.rules.each do |r|
                      j.object do
                        j.field "id", r.id
                        j.field "kind", r.kind
                        j.field "type", r.match_type
                        j.field "pattern", r.pattern
                      end
                    end
                  end
                end
              end
            end)
          else
            puts "Scope filtering: #{scope.enabled? ? "ENABLED" : "DISABLED"}"
            if scope.rules.empty?
              puts "No scope rules configured."
            else
              scope.rules.each do |r|
                puts "##{r.id}  #{r.kind.ljust(8)}  #{r.match_type.ljust(6)}  #{r.pattern}"
              end
            end
          end
        ensure
          store.close
        end
      end

      private def self.cmd_scope_add(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        kind = "include"
        match_type = "host"
        pattern : String? = nil

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project scope add [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-kKIND", "--kind=KIND", "Rule kind: include|exclude (default: include)") { |v| kind = v }
          p.on("-tTYPE", "--type=TYPE", "Match type: host|string|regex (default: host)") { |v| match_type = v }
          p.on("-pPATTERN", "--pattern=PATTERN", "Pattern to match (required)") { |v| pattern = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project scope add: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project scope add: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run project scope add: --pattern is required" if (pat = pattern).nil? || pat.empty?
        abort "gori run project scope add: invalid kind '#{kind}' (must be include or exclude)" unless kind.in?(Scope::KINDS)
        abort "gori run project scope add: invalid type '#{match_type}' (must be host, string, or regex)" unless match_type.in?(Scope::TYPES)
        abort "gori run project scope add: invalid pattern for regex (failed to compile)" if match_type == "regex" && !Scope.valid?(match_type, pat)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          scope = Scope.load(store)
          unless scope.add(kind, match_type, pat)
            store.close
            abort "gori run project scope add: failed to add rule (duplicate, empty, or invalid)"
          end
          puts "Scope rule added successfully."
        ensure
          store.close
        end
      end

      private def self.cmd_scope_delete(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project scope delete <rule-id> [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project scope delete: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project scope delete: missing value for #{f}" }
        end

        positional = [] of String
        parser.unknown_args { |rest, _| positional = rest }
        parser.parse(args)

        abort "gori run project scope delete: missing <rule-id>" if positional.empty?
        abort "gori run project scope delete: too many arguments (expected one <rule-id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run project scope delete: invalid rule id '#{positional[0]}'")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          scope = Scope.load(store)
          unless scope.rules.any? { |r| r.id == id }
            store.close
            abort "gori run project scope delete: no scope rule with id #{id}"
          end
          scope.remove(id)
          puts "Scope rule ##{id} deleted successfully."
        ensure
          store.close
        end
      end

      private def self.cmd_scope_set_enabled(enable : Bool, args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        action = enable ? "enable" : "disable"

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project scope #{action} [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project scope #{action}: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project scope #{action}: missing value for #{f}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          scope = Scope.load(store)
          if enable
            scope.enable
            puts "Scope filtering enabled."
          else
            scope.disable
            puts "Scope filtering disabled."
          end
        ensure
          store.close
        end
      end

      # --- rewriter (Match & Replace rules) ----------------------------------

      private def self.cmd_rewriter(args : Array(String)) : Nil
        case sub = args.first?
        when "add"          then cmd_rewriter_add(args[1..])
        when "rm", "delete" then cmd_rewriter_rm(args[1..])
        when "enable"       then cmd_rewriter_set_enabled(true, args[1..])
        when "disable"      then cmd_rewriter_set_enabled(false, args[1..])
        when "preview"      then cmd_rewriter_preview(args[1..])
        when nil            then cmd_rewriter_list(args)
        else
          if (s = sub) && s.starts_with?('-')
            cmd_rewriter_list(args)
          else
            STDERR.puts "gori run rewriter: unknown subcommand '#{sub}'"
            STDERR.puts "Usage: gori run rewriter [list options] | add | rm <id> | enable <id> | disable <id> | preview"
            exit 1
          end
        end
      end

      # One text row for a rule: `#3 [x] REQ sub/H @host  pattern -> value`.
      private def self.rewriter_rule_row(r : Store::MatchRule) : String
        mark = r.enabled? ? "x" : " "
        side = r.target.request? ? "REQ" : "RES"
        tag = case r.op
              when .replace? then "#{r.match_kind.regex? ? "re" : "sub"}/#{r.part.body? ? 'B' : 'H'}"
              when .add_header? then "+hdr"
              when .set_header? then "~hdr"
              else                   "-hdr"
              end
        body = r.op.remove_header? ? r.pattern : "#{r.pattern} -> #{r.replacement}"
        name = r.name.empty? ? "" : " [#{r.name}]"
        host = r.host.empty? ? "" : " @#{r.host}"
        "##{r.id} [#{mark}] #{side} #{tag.ljust(5)}#{name}#{host}  #{body}"
      end

      private def self.cmd_rewriter_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run rewriter [options]\n\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run rewriter add --op=replace --target=request --find=OLD --value=NEW\n" \
                     "  gori run rewriter add --op=add_header --find=X-Trace --value=on\n" \
                     "  gori run rewriter rm <id> | enable <id> | disable <id> | preview ..."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run rewriter: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run rewriter: missing value for #{f}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          rules = store.match_rules
          if format == :json
            puts(JSON.build do |j|
              j.array do
                rules.each do |r|
                  j.object do
                    j.field "id", r.id
                    j.field "enabled", r.enabled?
                    j.field "name", r.name
                    j.field "target", r.target.label
                    j.field "part", r.part.label
                    j.field "op", r.op.label
                    j.field "match", r.match_kind.label
                    j.field "host", r.host
                    j.field "pattern", r.pattern
                    j.field "replacement", r.replacement
                  end
                end
              end
            end)
          elsif rules.empty?
            puts "No Match & Replace rules configured."
          else
            rules.each { |r| puts rewriter_rule_row(r) }
          end
        ensure
          store.close
        end
      end

      # Parse the shared rule-shape flags into store enums, aborting on a bad value.
      private def self.parse_rewriter_op(s : String) : Store::RuleOp
        case s.downcase
        when "replace"       then Store::RuleOp::Replace
        when "add_header"    then Store::RuleOp::AddHeader
        when "set_header"    then Store::RuleOp::SetHeader
        when "remove_header" then Store::RuleOp::RemoveHeader
        else                      abort "gori run rewriter: invalid --op '#{s}' (replace|add_header|set_header|remove_header)"
        end
      end

      private def self.cmd_rewriter_add(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        target_s = "request"
        part_s = "head"
        op_s = "replace"
        match_s = "literal"
        host = ""
        name = ""
        find : String? = nil
        value = ""
        disabled = false

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run rewriter add [options]\n\n" \
                     "For replace: --find is the substring/regex, --value the replacement.\n" \
                     "For a header op: --find is the header NAME, --value the value."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--target=SIDE", "request|response (default request)") { |v| target_s = v }
          p.on("--op=OP", "replace|add_header|set_header|remove_header (default replace)") { |v| op_s = v }
          p.on("--match=KIND", "literal|regex (default literal; replace only)") { |v| match_s = v }
          p.on("--part=PART", "head|body (default head; replace only)") { |v| part_s = v }
          p.on("--host=GLOB", "Scope to a host glob ('' = all; '*.example.com')") { |v| host = v }
          p.on("--name=NAME", "Optional rule label") { |v| name = v }
          p.on("-fFIND", "--find=FIND", "Match substring/regex, or header name (required)") { |v| find = v }
          p.on("-vVALUE", "--value=VALUE", "Replacement, or header value (default empty)") { |v| value = v }
          p.on("--disabled", "Create the rule disabled") { disabled = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run rewriter add: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run rewriter add: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run rewriter add: --find is required" if (f = find).nil? || f.empty?
        op = parse_rewriter_op(op_s)
        target = Store::RuleTarget.parse?(target_s) || abort("gori run rewriter add: invalid --target '#{target_s}'")
        part = Store::RulePart.parse?(part_s) || abort("gori run rewriter add: invalid --part '#{part_s}'")
        match = Store::MatchKind.parse?(match_s) || abort("gori run rewriter add: invalid --match '#{match_s}' (literal|regex)")
        if op.replace? && match.regex? && !valid_regex?(f)
          abort "gori run rewriter add: invalid regex --find (failed to compile)"
        end
        part = Store::RulePart::Head if op.header?

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          id = store.insert_rule(target, part, f, value, op, match, name, host, !disabled)
          abort "gori run rewriter add: failed to persist rule (store busy or unwritable)" if id == 0
          puts "Rule ##{id} added."
        ensure
          store.close
        end
      end

      private def self.valid_regex?(pattern : String) : Bool
        SafeRegexp.compile(pattern)
        true
      rescue
        false
      end

      private def self.cmd_rewriter_rm(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run rewriter rm <id> [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run rewriter rm: unknown option: #{f}\n#{p}" }
        end
        positional = [] of String
        parser.unknown_args { |rest, _| positional = rest }
        parser.parse(args)
        abort "gori run rewriter rm: missing <id>" if positional.empty?
        id = positional[0].to_i64? || abort("gori run rewriter rm: invalid rule id '#{positional[0]}'")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          unless store.match_rules.any? { |r| r.id == id }
            store.close
            abort "gori run rewriter rm: no rule with id #{id}"
          end
          store.delete_rule(id)
          puts "Rule ##{id} deleted."
        ensure
          store.close
        end
      end

      private def self.cmd_rewriter_set_enabled(enable : Bool, args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        action = enable ? "enable" : "disable"
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run rewriter #{action} <id> [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run rewriter #{action}: unknown option: #{f}\n#{p}" }
        end
        positional = [] of String
        parser.unknown_args { |rest, _| positional = rest }
        parser.parse(args)
        abort "gori run rewriter #{action}: missing <id>" if positional.empty?
        id = positional[0].to_i64? || abort("gori run rewriter #{action}: invalid rule id '#{positional[0]}'")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          unless store.match_rules.any? { |r| r.id == id }
            store.close
            abort "gori run rewriter #{action}: no rule with id #{id}"
          end
          store.set_rule_enabled(id, enable)
          puts "Rule ##{id} #{enable ? "enabled" : "disabled"}."
        ensure
          store.close
        end
      end

      private def self.cmd_rewriter_preview(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        target_s = "request"
        part_s = "head"
        op_s = "replace"
        match_s = "literal"
        host = ""
        find : String? = nil
        value = ""
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run rewriter preview [options]\n\n" \
                     "Estimate how many recent flows a rule WOULD affect, without creating it."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--target=SIDE", "request|response (default request)") { |v| target_s = v }
          p.on("--op=OP", "replace|add_header|set_header|remove_header (default replace)") { |v| op_s = v }
          p.on("--match=KIND", "literal|regex (default literal)") { |v| match_s = v }
          p.on("--part=PART", "head|body (default head)") { |v| part_s = v }
          p.on("--host=GLOB", "Scope to a host glob") { |v| host = v }
          p.on("-fFIND", "--find=FIND", "Match substring/regex, or header name (required)") { |v| find = v }
          p.on("-vVALUE", "--value=VALUE", "Replacement, or header value") { |v| value = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run rewriter preview: unknown option: #{f}\n#{p}" }
        end
        parser.parse(args)

        abort "gori run rewriter preview: --find is required" if (f = find).nil? || f.empty?
        op = parse_rewriter_op(op_s)
        target = Store::RuleTarget.parse?(target_s) || abort("gori run rewriter preview: invalid --target '#{target_s}'")
        part = Store::RulePart.parse?(part_s) || abort("gori run rewriter preview: invalid --part '#{part_s}'")
        match = Store::MatchKind.parse?(match_s) || abort("gori run rewriter preview: invalid --match '#{match_s}' (literal|regex)")
        part = Store::RulePart::Head if op.header?

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          candidate = Store::MatchRule.new(0_i64, true, target, part, f, value, op, match, "", host)
          pv = Gori::Rules.new(store, [] of Store::MatchRule).preview(candidate)
          if format == :json
            puts(JSON.build do |j|
              j.object do
                j.field "would_match", pv.matched
                j.field "scanned", pv.scanned
                j.field "total_flows", pv.total
                j.field "scan_capped", pv.total > pv.scanned
              end
            end)
          else
            capped = pv.total > pv.scanned ? " (of #{pv.total} total; scan capped)" : ""
            puts "Would affect #{pv.matched} of #{pv.scanned} recent flows#{capped}."
          end
        ensure
          store.close
        end
      end

      # --- project env -------------------------------------------------------

      private def self.cmd_project_env(args : Array(String)) : Nil
        sub = args.first?
        case sub
        when "set"
          cmd_env_set(args[1..])
        when "delete"
          cmd_env_delete(args[1..])
        when nil
          cmd_env_list(args)
        else
          if (s = sub) && s.starts_with?('-')
            cmd_env_list(args)
          else
            STDERR.puts "gori run project env: unknown subcommand '#{sub}'"
            STDERR.puts "Usage: gori run project env [list options] | set KEY=value | delete KEY"
            exit 1
          end
        end
      end

      private def self.cmd_env_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project env [options]\n\n" \
                     "List project env vars used for $KEY substitution in outbound requests.\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run project env set KEY=value\n" \
                     "  gori run project env set KEY value\n" \
                     "  gori run project env delete KEY"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project env: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project env: missing value for #{f}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          vars = Settings.project_env_vars
          if format == :json
            puts(JSON.build do |j|
              j.array do
                vars.each do |(key, val)|
                  j.object do
                    j.field "key", key
                    j.field "value", val
                  end
                end
              end
            end)
          elsif vars.empty?
            STDERR.puts "no project env vars configured"
          else
            vars.each { |(key, val)| puts "#{key}=#{val}" }
          end
        ensure
          store.close
        end
      end

      private def self.cmd_env_set(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project env set KEY=value [options]\n" \
                     "       gori run project env set KEY value [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run project env set: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project env set: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run project env set: missing KEY=value (or KEY value)" if positional.empty?
        line = positional.join(' ')
        parsed = Env.parse_line(line)
        abort "gori run project env set: invalid KEY (use [A-Za-z_][A-Za-z0-9_]*)" unless parsed
        key, val = parsed

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          vars = Settings.project_env_vars.dup
          if idx = vars.index { |(k, _)| k == key }
            vars[idx] = {key, val}
          else
            vars << {key, val}
          end
          Env.save_project(store, vars)
          puts "Env var #{key} set."
        ensure
          store.close
        end
      end

      private def self.cmd_env_delete(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project env delete KEY [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run project env delete: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project env delete: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run project env delete: missing KEY" if positional.empty?
        abort "gori run project env delete: too many arguments (expected one KEY)" if positional.size > 1
        key = positional[0]
        abort "gori run project env delete: invalid KEY '#{key}'" unless Env.valid_key?(key)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          vars = Settings.project_env_vars.dup
          before = vars.size
          vars.reject! { |(k, _)| k == key }
          if vars.size == before
            store.close
            abort "gori run project env delete: no env var named '#{key}'"
          end
          Env.save_project(store, vars)
          puts "Env var #{key} deleted."
        ensure
          store.close
        end
      end

      # --- project host-override ---------------------------------------------

      private def self.cmd_project_host_override(args : Array(String)) : Nil
        sub = args.first?
        case sub
        when "add"
          cmd_host_override_add(args[1..])
        when "update"
          cmd_host_override_update(args[1..])
        when "delete"
          cmd_host_override_delete(args[1..])
        when nil
          cmd_host_override_list(args)
        else
          if (s = sub) && s.starts_with?('-')
            cmd_host_override_list(args)
          else
            STDERR.puts "gori run project host-override: unknown subcommand '#{sub}'"
            STDERR.puts "Usage: gori run project host-override [list options] | add | update | delete"
            exit 1
          end
        end
      end

      private def self.cmd_host_override_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project host-override [options]\n\n" \
                     "List project host overrides (/etc/hosts-style: dial IP for hostname).\n" \
                     "Project overrides win over global Settings: Hostnames on collision.\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run project host-override add --host=api.example.com --ip=10.0.0.1\n" \
                     "  gori run project host-override add 10.0.0.1 api.example.com\n" \
                     "  gori run project host-override update <id> --host=... --ip=...\n" \
                     "  gori run project host-override delete <id>"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run project host-override: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project host-override: missing value for #{f}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          ov = HostOverrides.load(store)
          if format == :json
            puts(JSON.build do |j|
              j.array do
                ov.entries.each do |e|
                  j.object do
                    j.field "id", e.id
                    j.field "host", e.host
                    j.field "ip", e.ip
                  end
                end
              end
            end)
          elsif ov.entries.empty?
            STDERR.puts "no host overrides configured"
          else
            ov.entries.each do |e|
              puts "##{e.id}  #{e.ip.ljust(15)}  #{e.host}"
            end
          end
        ensure
          store.close
        end
      end

      private def self.cmd_host_override_add(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        host : String? = nil
        ip : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project host-override add --host=HOST --ip=IP [options]\n" \
                     "       gori run project host-override add IP HOST [options]\n\n" \
                     "Add a project host override (dial IP for HOST; SNI/Host header unchanged)."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--host=HOST", "Hostname to override (case-insensitive)") { |v| host = v }
          p.on("--ip=IP", "IPv4/IPv6 literal to dial") { |v| ip = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run project host-override add: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project host-override add: missing value for #{f}" }
        end
        parser.parse(args)

        # Flags win when both are given; otherwise accept /etc/hosts-style "IP HOST".
        pair =
          if (h_flag = host) && (i_flag = ip)
            {h_flag, i_flag}
          else
            abort "gori run project host-override add: need --host and --ip, or positional IP HOST" if positional.empty?
            parsed = HostOverrides.parse_line(positional.join(' '))
            abort "gori run project host-override add: invalid entry (expected IP HOST; IP must be a literal)" unless parsed
            parsed
          end
        h, i = pair
        abort "gori run project host-override add: invalid host/ip (host hostname-shaped, ip an IPv4/IPv6 literal)" unless HostOverrides.valid?(h, i)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          ov = HostOverrides.load(store)
          unless ov.add(h, i)
            store.close
            abort "gori run project host-override add: failed to add override (duplicate host, empty, or invalid)"
          end
          entry = ov.entries.find { |e| e.host == h.strip.downcase }
          if e = entry
            puts "Host override ##{e.id} added: #{e.ip} → #{e.host}"
          else
            puts "Host override added: #{i} → #{h.strip.downcase}"
          end
        ensure
          store.close
        end
      end

      private def self.cmd_host_override_update(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        host : String? = nil
        ip : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project host-override update <id> --host=HOST --ip=IP [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--host=HOST", "New hostname (case-insensitive)") { |v| host = v }
          p.on("--ip=IP", "New IPv4/IPv6 literal to dial") { |v| ip = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run project host-override update: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project host-override update: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run project host-override update: missing <id>" if positional.empty?
        abort "gori run project host-override update: too many arguments (expected one <id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run project host-override update: invalid id '#{positional[0]}'")
        h = host
        i = ip
        abort "gori run project host-override update: --host and --ip are both required" unless h && i
        abort "gori run project host-override update: invalid host/ip (host hostname-shaped, ip an IPv4/IPv6 literal)" unless HostOverrides.valid?(h, i)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          ov = HostOverrides.load(store)
          unless ov.entries.any? { |e| e.id == id }
            store.close
            abort "gori run project host-override update: no override with id #{id}"
          end
          unless ov.update(id, h, i)
            store.close
            abort "gori run project host-override update: failed (duplicate host, empty, or invalid)"
          end
          puts "Host override ##{id} updated: #{i} → #{h.strip.downcase}"
        ensure
          store.close
        end
      end

      private def self.cmd_host_override_delete(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project host-override delete <id> [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run project host-override delete: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project host-override delete: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run project host-override delete: missing <id>" if positional.empty?
        abort "gori run project host-override delete: too many arguments (expected one <id>)" if positional.size > 1
        id = positional[0].to_i64? || abort("gori run project host-override delete: invalid id '#{positional[0]}'")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          ov = HostOverrides.load(store)
          unless ov.entries.any? { |e| e.id == id }
            store.close
            abort "gori run project host-override delete: no override with id #{id}"
          end
          ov.remove(id)
          puts "Host override ##{id} deleted."
        ensure
          store.close
        end
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
