# `gori run history` (alias ls) and `gori run show <id>` — list / QL-query captured
# flows, and print one flow's request/response (text, json, raw bytes, or HAR).
module Gori
  module CLI
    module Run
      # `delete`/`clear`/`show` are reserved as the first positional (same convention as
      # `gori run probe`); a QL query starting with one goes through --query. `history show
      # <id>` is the top-level `gori run show <id>`, spelled the way the History tab reads.
      private def self.cmd_history(args : Array(String)) : Nil
        case args.first?
        when "delete", "rm" then cmd_history_delete(args[1..])
        when "clear"        then cmd_history_clear(args[1..])
        when "show"         then cmd_show(args[1..])
        else                     cmd_history_list(args)
        end
      end

      # Hard-delete ONE captured flow. Single and explicit, so no extra confirmation —
      # unlike `clear`, which needs --yes.
      private def self.cmd_history_delete(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run history delete <id>\n\nHard-delete one captured flow. This can't be undone."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run history delete: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run history delete: missing value for #{f}" }
        end
        parser.parse(args)

        # `take_flow_id`, not a hand-rolled `first?`: it supplies the too-many-arguments abort
        # this one path was missing, so `history delete 1 2 3` no longer deletes ONLY flow #1
        # and exits 0 with nothing said about #2 and #3. The TUI has multi-select delete and the
        # store exposes `delete_flows`, so trying the list form is natural — and an operator who
        # believes three captures are gone when two are still on disk has been told a lie by a
        # destructive command. Every sibling id-taking delete (project, scope, env,
        # host-override, `history show`) already goes through this helper.
        id = take_flow_id(positional, "history delete")

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          # flow_row is the row-only read; get_flow would materialize both BLOBs to answer
          # "does this exist?" — a 40 MB response would be read and discarded.
          abort "gori run history delete: no flow with id #{id}" unless store.flow_row(id)
          abort "gori run history delete: flow ##{id} NOT deleted (project busy) — try again" unless store.delete_flow(id)
          puts "Flow ##{id} deleted."
        ensure
          store.close
        end
      end

      # Wipe EVERY captured flow in the project. The TUI puts a danger confirm in front of
      # this; headless, --yes is that confirm — without it we print the count and refuse, so
      # a mistyped command can't empty a capture session.
      private def self.cmd_history_clear(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        yes = false

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run history clear --yes\n\n" \
                     "Delete ALL captured flows in the project. This can't be undone."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--yes", "Actually do it (required — there is no interactive prompt here)") { yes = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run history clear: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run history clear: missing value for #{f}" }
        end
        parser.parse(args)

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          n = store.count
          unless yes
            abort "gori run history clear: refusing to delete #{n} flow#{n == 1 ? "" : "s"} without --yes"
          end
          abort "gori run history clear: NOT cleared (project busy) — every flow is still there" unless store.clear_flows
          puts "Deleted #{n} flow#{n == 1 ? "" : "s"}."
        ensure
          store.close
        end
      end

      private def self.cmd_history_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        query : String? = nil
        limit = 50
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run history [QL query] [options]   (alias: ls)\n\n" \
                     "Subcommands: history show <id> · history delete <id> · history clear --yes"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("-qQL", "--query=QL", "Filter with a QL query (host: status:>=500 size:>10000 dur:>500 header: body~rx …)") { |v| query = v }
          p.on("-nN", "--limit=N", "Max rows, newest first (default 50)") { |v| limit = parse_count(v, "--limit") }
          p.on("--format=FMT", "Output: text (default) | json | jsonl (both emit JSON-Lines) | har (one HAR 1.2 log)") do |v|
            format = parse_format(v, [:text, :json, :jsonl, :har])
            format = :json if format == :jsonl # this listing's json IS JSON-Lines; accept the standard name too
          end
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
        # and EVERY flow dumped.
        query, dropped = Run.compose_history_query(query, positional, neg_terms)
        Run.warn_dropped_query_terms("history", dropped)

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          rows =
            if q = query
              filter = QL.parse(q)
              Run.warn_query_terms("history", q)
              # A query that fails to compile to ANY clause (e.g. `status:>=foo`)
              # yields the match-all EMPTY filter — silently dumping every flow,
              # the opposite of what the user asked. Refuse it instead.
              if !q.strip.empty? && filter == QL::EMPTY
                store.close
                abort "gori run history: query #{q.inspect} did not match any field (check syntax, e.g. status:>=500 host:example.com method:POST)"
              end
              # Trigram indexing is off-commit (Store V4), so a `body:`/free-text query run
              # right after a capture — or against a db a killed process left behind — would
              # under-report until the backlog drains. A one-shot answer must be exact, so
              # wait for it here rather than silently returning fewer rows.
              store.index_pending! if filter.uses_fts?
              begin
                store.search(filter, limit, raise_on_error: true)
              rescue ex
                store.close
                abort "gori run history: query #{q.inspect} failed: #{ex.message}"
              end
            else
              store.recent_flows(limit)
            end
          if format == :har
            emit_har(store, rows, query, limit)
          elsif format == :json
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

      # The whole QL result set as ONE HAR 1.2 log (#495).
      #
      # Flows are materialized one at a time — a HAR needs the head/body BLOBs an `ls` row
      # deliberately doesn't carry — so a large `-n` streams instead of holding every body in
      # memory at once. OLDEST first: the listing is newest-first for reading, but a HAR log's
      # entries are chronological, which is what every reader assumes when it renders a
      # waterfall.
      #
      # STDOUT stays a pure HAR document (pipe it straight to a file); every caveat — flows
      # skipped, bodies capped — goes to STDERR, because a silently short export is exactly
      # the failure this file keeps having to fix.
      private def self.emit_har(store : Store, rows : Array(Store::FlowRow), query : String?,
                                limit : Int32) : Nil
        details = rows.reverse.each.compact_map { |r| store.get_flow(r.id) }
        report = Export::Har.log(STDOUT, details)
        STDOUT.puts
        report.notes.each { |n| STDERR.puts "gori run history: #{n}" }
        if report.written == 0
          STDERR.puts "gori run history: no flows written to the HAR#{query ? " (query #{query.inspect})" : ""}"
        elsif rows.size >= limit
          # A file handed to someone else must not quietly be the newest 50 of 5000. The
          # listing formats share this default, but there a short page is obvious on screen
          # and in a HAR it is not, so say it out loud.
          STDERR.puts "gori run history: stopped at the --limit of #{limit} flow#{limit == 1 ? "" : "s"}; raise -n to export more"
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
          p.on("--format=FMT", "Output: text (default) | json | raw (exact bytes) | har (a one-entry HAR 1.2 log)") { |v| format = parse_format(v, [:text, :json, :raw, :har]) }
          p.on("--request-only", "Only the request side") { req_only = true }
          p.on("--response-only", "Only the response side") { resp_only = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run show: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run show: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run show: --request-only and --response-only are mutually exclusive" if req_only && resp_only
        # A HAR entry is a request AND its response; there is no half-entry shape to emit,
        # so the one-sided flags are a usage error here rather than a silently ignored option.
        if format == :har && (req_only || resp_only)
          abort "gori run show: --format har writes a whole entry — --request-only/--response-only don't apply"
        end
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
        when :har  then show_har(detail)
        when :json then puts show_json(detail, show_request, show_response, ws_msgs)
        else            show_text(detail, show_request, show_response, ws_msgs)
        end
      end

      # One flow as a one-entry HAR 1.2 log. A flow HAR cannot represent is an ERROR here,
      # not an empty log: the listing can skip and count, but `show <id> --format har` named
      # this flow, so silently handing back `entries: []` would answer a different question.
      private def self.show_har(detail : Store::FlowDetail) : Nil
        # The refusal names the REAL cause where the store has one: a flow gori itself
        # refused to send carries it in `error` ("request framing rejected: …"), and
        # "has no captured response" alone reads like the origin's fault.
        because = detail.error.presence.try { |e| " (#{e})" } || ""
        case Export::Har.skip_reason(detail)
        in Export::Har::Skip::WebSocket
          abort "gori run show: flow ##{detail.row.id} is a WebSocket flow — HAR has no representation for its messages (use --format json or raw)"
        in Export::Har::Skip::NoResponse
          abort "gori run show: flow ##{detail.row.id} has no captured response — a HAR entry requires one#{because}"
        in Export::Har::Skip::Incomplete
          abort "gori run show: flow ##{detail.row.id} did not complete — HAR cannot record a partial response, " \
                "so the entry would read as a successful exchange#{because} (use --format json or raw)"
        in Nil
          # exportable
        end
        report = Export::Har.log(STDOUT, [detail])
        STDOUT.puts
        report.notes.each { |n| STDERR.puts "gori run show: #{n}" }
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
        # FIRST, above the bytes it is about: what gori DID to this exchange that the bytes
        # cannot show — a Match&Replace rule it could not run, a request the origin invented.
        # The WebSocket half of this has been readable here since #518 (`[gori] …` rows in the
        # message list); an HTTP flow now carries the same statement on the row itself.
        advisories = detail.row.advisories
        unless advisories.empty?
          puts "=== GORI ADVISORY ==="
          advisories.each { |a| puts "! #{CLI::Output.term_safe_multiline(a)}" }
          puts ""
        end
        if req
          puts "=== REQUEST (#{detail.http_version}) ==="
          print_message_text(detail.request_head, display_body(detail.request_head, detail.request_body), detail.request_body)
          puts "  [request body truncated]" if detail.request_body_truncated?
        end
        if resp
          puts "" if req
          puts "=== RESPONSE ==="
          if err = detail.error
            puts "error: #{err}"
          end
          if h = detail.response_head
            print_message_text(h, display_body(h, detail.response_body), detail.response_body)
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
          # The parse-failure heading also names the capture cap when that is what cut the
          # body — `detail` knows it and `Graphql` (which sees only bytes) cannot.
          if note = op.note
            capped = detail.request_body_truncated? ? "; body truncated at the capture cap" : ""
            puts CLI::Output.term_safe("=== GRAPHQL (parse failed: #{note}#{capped}) ===")
          else
            puts "=== GRAPHQL ==="
          end
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

      # Schema-less protobuf tree for an application/grpc body. Framed by
      # `Proxy::H2::Grpc.messages`, then each non-trailer / non-compressed payload
      # is decoded by `Gori::Protobuf`. Compressed payloads stay opaque (not
      # protobuf until inflated); grpc-web trailer frames become header maps.
      # Omitted entirely when the head is not gRPC — so ordinary HTTP flows stay free of an
      # empty shell. A gRPC head whose body does NOT frame is a different thing and is now
      # reported: the guard used to be `msgs.empty?`, so a deliberately-wrong length prefix
      # (one of the standard gRPC parser tests) made the whole object VANISH, which reads
      # identically to "this flow is not gRPC". A trailing partial frame went the same way,
      # with no count of what was left over. The raw body was stored correctly either way
      # (P7) — this was only the report the operator reads.
      private def self.emit_grpc_messages_json(j : JSON::Builder, head : Bytes?, body : Bytes?) : Nil
        return if head.nil? || body.nil? || body.empty?
        return unless Proxy::H2::Grpc.grpc?(content_type_of(head))
        msgs, residual = Proxy::H2::Grpc.scan(body)
        return if msgs.empty? && residual == 0
        j.field "grpc_messages" do
          j.object do
            j.field "count", msgs.size
            if residual > 0
              j.field "residual_bytes", residual
              j.field "framing_error",
                "the last #{residual} byte#{residual == 1 ? "" : "s"} are not a complete gRPC frame — " \
                "a length prefix claiming more than arrived, or a body cut short"
            end
            j.field "messages" do
              j.array do
                msgs.each_with_index do |m, i|
                  j.object do
                    j.field "index", i
                    j.field "compressed", m.compressed
                    j.field "trailer", m.trailer
                    j.field "size", m.data.size
                    if m.trailer
                      # grpc-web TRAILER frame: ASCII headers, not protobuf.
                      j.field "headers" do
                        j.object do
                          Proxy::H2::Grpc.trailer_headers(m.data).each do |k, v|
                            j.field k, v.scrub
                          end
                        end
                      end
                    elsif m.compressed
                      # Honour the 0x01 flag: compressed bytes are not a protobuf
                      # message until the caller inflates them (encoding is named
                      # by grpc-encoding, not by us).
                      j.field "note", "compressed payload — not decoded as protobuf"
                      j.field "bytes", Base64.strict_encode(m.data)
                    else
                      j.field "protobuf" do
                        Protobuf.decode(m.data).to_json(j)
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      # Content-Type value from a message head (case-insensitive name, any spacing
      # after the colon). Nil when the head has no Content-Type line.
      private def self.content_type_of(head : Bytes) : String?
        String.new(head).each_line do |line|
          colon = line.index(':') || next
          next unless line[0, colon].strip.downcase == "content-type"
          return line[(colon + 1)..].strip
        end
        nil
      end

      # "→ out" (client→server) / "← in" (server→client). Text frames print their
      # (scrubbed) payload; binary frames print a size + short hex preview.
      private def self.ws_message_text(m : Store::WsMessage) : String
        arrow = m.direction == "out" ? "→" : "←"
        shape = Output.ws_shape_note(m)
        if m.control?
          "#{arrow} #{shape} #{Output.ws_control_detail(m)}"
        elsif m.text?
          "#{arrow}#{shape.empty? ? "" : " #{shape}"} #{CLI::Output.term_safe_multiline(String.new(m.payload).scrub)}"
        else
          preview = m.payload[0, {m.payload.size, 16}.min].hexstring
          "#{arrow}#{shape.empty? ? "" : " #{shape}"} [binary #{m.payload.size}B] #{preview}#{m.payload.size > 16 ? "…" : ""}"
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
            # `Serialize.flow_detail` wraps this same field in `text()`; here it was raw. A
            # capture failure's text quotes bytes the origin sent (a malformed status line, a
            # header the codec refused), so it is captured data — see `Output.json_captured`.
            CLI::Output.json_captured(j, "error", detail.error)
            emit_decoded_json(j, detail, req, resp)
            if req
              j.field "request" do
                j.object do
                  j.field "head", scrub(detail.request_head)
                  emit_body_json(j, "body", detail.request_head, detail.request_body, detail.request_body_truncated?)
                  emit_grpc_messages_json(j, detail.request_head, detail.request_body)
                end
              end
            end
            if resp
              j.field "response" do
                j.object do
                  j.field "head", scrub(detail.response_head)
                  emit_body_json(j, "body", detail.response_head, detail.response_body, detail.response_body_truncated?)
                  emit_grpc_messages_json(j, detail.response_head, detail.response_body)
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
                            m.emit_shape_json(j)
                            if m.text?
                              j.field "text", String.new(m.payload).scrub
                              # See emit_ws_result: JSON cannot carry a byte that is not valid
                              # UTF-8, and those bytes are the §8.1/§5.6 test case.
                              j.field "base64", Base64.strict_encode(m.payload) unless String.new(m.payload).valid_encoding?
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
                    # Same cap/expression as the MCP serializer (mcp/serialize.cr
                    # `emit_sse_events`) — was hardcoded `false` here, so a caller
                    # reading only `sse_events` (the point of --format json) had no
                    # signal the array was clipped.
                    j.field "truncated", events.size > MCP::Serialize::SSE_EVENTS_MAX
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
    end
  end
end
