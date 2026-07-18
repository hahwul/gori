# `gori run history` (alias ls) and `gori run show <id>` — list / QL-query captured
# flows, and print one flow's request/response (text, json, or raw bytes).
module Gori
  module CLI
    module Run
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
          p.on("--format=FMT", "Output: text (default) | json | jsonl (both emit JSON-Lines)") do |v|
            format = parse_format(v, [:text, :json, :jsonl])
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
    end
  end
end
