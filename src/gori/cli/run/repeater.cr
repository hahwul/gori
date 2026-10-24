# `gori run repeater` — re-send a captured flow, or list/create repeater sessions.
require "../../repeater/timing"
require "../../plural"

module Gori
  module CLI
    module Run
      # The `--tls-preset` help text, written once. Four commands take the flag and the
      # honesty clause has to be on every one of them: #822 documents these presets as
      # APPROXIMATIONS, and a flag whose help implied "sends Chrome's ClientHello" would
      # upgrade that claim from a surface gori never audits.
      TLS_PRESET_HELP = "TLS fingerprint for this send: shape the ClientHello like " \
                        "#{Settings::TLS_PRESET_NAMES.join(" | ")} instead of gori's own, without touching " \
                        "the settings.json outbound_tls table. The destination's client certificate, " \
                        "protocol range and permissive flag still apply. An APPROXIMATION of that " \
                        "client's hello, not a byte-exact JA3 match — `gori settings tls-fingerprint " \
                        "HOST --preset NAME` prints what actually goes out. Empty value = no override"

      # The way out of the `§…§` refusal, written once for the one command that can hit it.
      # NOT `gori run fuzz --repeater`: that seed escapes a stored `§` to the `§§` literal on
      # purpose, so it would sweep auto-marked positions and silently un-mark the operator's.
      # See `Repeater::DraftMarkers.refusal`.
      MARKER_REMEDY = "Remove them from the session, write the marked request to a file and " \
                      "sweep it with `gori run fuzz --request=FILE` (which reads §…§ as " \
                      "positions, where `--repeater` escapes them), or pass --verbatim to say " \
                      "the stored bytes ARE the message and send them as they are."

      # `--path`, written once for the two commands that take it (#1116). The contract that
      # matters is the last sentence: the override edits THIS send, never the stored row.
      PATH_OVERRIDE_HELP = "Send to this request-target (path and query, e.g. '/api/v1/items/42?lang=en') " \
                           "instead of the stored one, for this send only — method, version, headers and " \
                           "body are unchanged, and the value goes on the request line as written. A session's " \
                           "stored request and last response are left as they were"

      # nil when `--path` is usable (or absent); the refusal otherwise. Empty is refused for the
      # reason `Plan` refuses a blank `--target`: `--path "$MAYBE_UNSET"` would otherwise put a
      # request line with no target on the wire, somewhere the operator did not name.
      def self.path_override_error(path : String?) : String?
        return nil if path.nil? || !path.empty?
        "--path must not be empty (to send the stored target, leave --path out)"
      end

      # nil unless the output flags and `--diff` disagree. `--max-body` cuts a body the diff
      # would still compare in full, so the two answers could not be read side by side;
      # `--headers-only` with `--diff` is the head-only comparison and is allowed.
      def self.output_diff_error(cap : BodyCap, diff : Bool) : String?
        return nil unless diff && cap.max
        "--max-body cannot be combined with --diff — the diff compares whole messages " \
        "(--headers-only --diff compares the heads alone)"
      end

      # The first line of a request, short and terminal-safe, for a refusal that has to show
      # which line it could not use.
      def self.request_line_preview(bytes : Bytes) : String
        nl = bytes.index(0x0A_u8)
        line = String.new(nl ? bytes[0, nl] : bytes).rstrip('\r')
        CLI::Output.term_safe(line.size > 60 ? "#{line[0, 60]}…" : line).inspect
      end

      # After a per-send edit (`--path`, `-H`, `-b`): the session's stored response was
      # deliberately NOT replaced (see the persist in `cmd_repeater_send`), and a later `repeater
      # send <id>` or the TUI tab would otherwise show the old answer with nothing saying why.
      # STDERR, so a piped JSON stays one object — whose `response_saved` is absent for the same
      # reason (no write was attempted). `edits` names the flags that edited this send.
      private def self.report_per_send_edit_unsaved(id : Int64, stored : Bytes, edits : Array(String), prefix : String) : Nil
        return if edits.empty?
        STDERR.puts "#{prefix}: #{edits.join(", ")}: session ##{id}'s stored request (#{request_line_preview(stored)}) " \
                    "and its last response were left unchanged"
      end

      # `gori run repeater <sub> …` (the `repeater …` rows below, which are also the usage
      # banner — `repeater_subcommand_rows`), or a bare flow id for the one-shot resend.
      #
      # Matched on argv[0] only, so a subcommand name is never confused with the flow id the
      # bare form takes.
      @[Subcommand("repeater", help: [
        {"repeater", "Re-send a captured flow by id (a `repeater <sub>` row below manages saved sessions)"},
        {"repeater list", "List the saved repeater sessions in the workbench"},
        {"repeater show", "Print a saved session's request and its last stored response, without sending"},
        {"repeater create", "Create a repeater session (--flow / --request-file / --request-raw / --request-stdin / --curl)"},
        {"repeater update", "Edit a saved session in place: target, request, name, tags, h1/h2, SNI, auto Content-Length"},
        {"repeater send", "Replay a saved repeater SESSION (not a flow id), HTTP or WebSocket"},
        {"repeater ws", "Open a persistent WebSocket session on a saved repeater; stream frames to/from stdin/stdout"},
        {"repeater h2", "Send a field-native HTTP/2 request from an ordered HPACK field list (--target URL --fields FILE)"},
        {"repeater race", "Fire several saved sessions as one synchronized race (h1 last-byte, h2 single-packet)"},
        {"repeater timing", "Differential timing analysis of two saved sessions (which is consistently slower, by response order and quartiles)"},
        {"repeater minimize", "Strip noise from a saved request, keeping the response the same"},
        {"repeater move", "Rearrange the sub-tab strip: move a session to a tab number (--to N) or one place (--up/--down)"},
        {"repeater delete", "Delete saved repeater sessions by id (needs --yes)"},
      ])]
      private def self.cmd_repeater(args : Array(String)) : Nil
        sub = args.first?
        if sub && (run = REPEATER_SUBCOMMANDS[sub]?)
          run.call(args[1..])
          return
        end
        # A word in subcommand position is a typo'd subcommand, not a flow id: `repeater bogus`
        # said "invalid flow id 'bogus'". A number (or `#5`) still reaches the flow-id parse.
        if sub && verb_word?(sub)
          abort unknown_verb_message("gori run repeater", sub, REPEATER_SUBCOMMANDS.keys)
        end

        cmd_repeater_single(args)
      end

      # `.scrub` is the match SUBJECT only: argv is unvalidated bytes, and PCRE2 raises on a
      # non-UTF-8 subject instead of failing to match (`gori run repeater $'\xff'`).
      private def self.verb_word?(sub : String) : Bool
        sub.scrub.matches?(/\A[a-z]/i)
      end

      # `cmd_repeater`'s dispatch. Every key has a `repeater <key>` row in the `@[Subcommand]`
      # help above, which is the usage banner (spec/cli/run/repeater_update_spec.cr checks).
      REPEATER_SUBCOMMANDS = {
        "list"     => ->(a : Array(String)) { cmd_repeater_list(a) },
        "show"     => ->(a : Array(String)) { cmd_repeater_show(a) },
        "create"   => ->(a : Array(String)) { cmd_repeater_create(a) },
        "update"   => ->(a : Array(String)) { cmd_repeater_update(a) },
        "send"     => ->(a : Array(String)) { cmd_repeater_send(a) },
        "ws"       => ->(a : Array(String)) { cmd_repeater_ws(a) },
        "race"     => ->(a : Array(String)) { cmd_repeater_race(a) },
        "timing"   => ->(a : Array(String)) { cmd_repeater_timing(a) },
        "minimize" => ->(a : Array(String)) { cmd_repeater_minimize(a) },
        "h2"       => ->(a : Array(String)) { cmd_repeater_h2fields(a) },
        "move"     => ->(a : Array(String)) { cmd_repeater_move(a) },
        "delete"   => ->(a : Array(String)) { cmd_repeater_delete(a) },
      }

      # The `repeater <sub>` rows of this command's `@[Subcommand]` help: the usage banner.
      def self.repeater_subcommand_rows : Array({String, String})
        SUBCOMMANDS.select(&.[0].starts_with?("repeater "))
      end

      # `gori run repeater h2 --target URL --fields FILE` — send a FIELD-NATIVE HTTP/2 request:
      # the exact HPACK field list, no HTTP/1.1 head text in between. That text structurally
      # cannot hold a duplicate pseudo-header, a pseudo after a regular field, a `:scheme` that
      # disagrees with the connection, `:protocol` (RFC 8441), an unknown pseudo, or a
      # leading-space value — `HeadCodec.h1_faithful?` is the loss set — so a conformance /
      # desync test made of those shapes had no scripted surface. Here they go on the wire
      # verbatim.
      #
      # The field list comes from a FILE, not a flag: it is long, and its colons and spaces are
      # painful to shell-quote correctly — the same reason `create` reads a request from `-f`.
      # The file is JSON: either a bare array `[[":method","GET"],…]`, or an object
      # `{"fields": […], "body": "…"}` / `{"fields": […], "body_base64": "…"}`.
      private def self.cmd_repeater_h2fields(args : Array(String)) : Nil
        proj = ProjectFlags.new
        target : String? = nil
        fields_file : String? = nil
        insecure = false
        allow_unscoped = false
        format = :text
        timeout : Time::Span? = nil
        sse = SseFlags.new
        tls_preset : String? = nil
        headers_only = false
        max_body : Int32? = nil

        # A stray word here is refused, not dropped — see `Run.parse_no_positionals`.
        parse_no_positionals(args, "gori run repeater h2",
          "pass the origin as --target URL and the field list as --fields FILE") do |p|
          p.banner = "Usage: gori run repeater h2 --target URL --fields FILE [options]\n\n" \
                     "Send a field-native HTTP/2 request (exact HPACK field list, no h1-text carrier).\n" \
                     "FILE is JSON: a [[name,value],…] array, or {\"fields\":[…],\"body\":\"…\"}."
          project_options(p, proj, "read")
          p.on("-tURL", "--target=URL", "Dial origin (scheme://host[:port]); :authority/:scheme in the fields may differ") { |v| target = v }
          p.on("--fields=FILE", "JSON file with the ordered HPACK field list (and optional body)") { |v| fields_file = v }
          p.on("-k", "--insecure-upstream", "Do not verify the upstream TLS certificate") { insecure = true }
          p.on("--timeout=SEC", "Per-operation connect + idle timeout (seconds)") { |v| timeout = parse_count(v, "--timeout").seconds }
          sse_options(p, sse, Repeater::StreamBound::SEND)
          p.on("--allow-unscoped", "Send even if the target is outside the project scope (the Sandbox still applies)") { allow_unscoped = true }
          p.on("--tls-preset=NAME", TLS_PRESET_HELP) { |v| tls_preset = v }
          p.on("--headers-only", HEADERS_ONLY_HELP) { headers_only = true }
          p.on("--max-body=BYTES", MAX_BODY_HELP) { |v| max_body = parse_count(v, "--max-body") }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end
        refresh_verify_upstream(!insecure)
        cap = body_cap(headers_only, max_body, "gori run repeater h2")

        tgt = target
        abort "gori run repeater h2: --target is required" if tgt.nil? || tgt.empty?
        file = fields_file
        abort "gori run repeater h2: --fields is required" if file.nil? || file.empty?
        fields, body = parse_h2_fields_file(read_input_file(file, "gori run repeater h2"))

        # Resolved ONCE: the scope that gates this send and the overrides that route it must
        # come from the same project, not two reads of "most recently active".
        project = resolve_read_project(proj.name, proj.db)
        overrides = with_store(project, read_only: true) { |store| Gori::HostOverrides.load(store) }
        outbound = project_outbound(project, allow_unscoped)
        plan = begin
          Repeater::Plan.build(Repeater::PlanOptions.new(
            h2_fields: fields, h2_body: body, target: tgt,
            http2: true, verify: !insecure, timeout: timeout, overrides: overrides,
            tls_preset: tls_preset, sse: sse.bound(Repeater::StreamBound::SEND)), outbound)
        rescue ex : Repeater::PlanError
          repeater_plan_abort("gori run repeater h2", ex)
        end
        abort_if_out_of_scope!(outbound, plan, "gori run repeater h2")
        abort_if_blocked!(plan, "gori run repeater h2")
        result = plan.send
        outbound.close

        new_body, _ = decode_body(result.head, result.body)
        emit_repeater_result(result, new_body, nil, format, tls_preset: sent_tls_preset(plan), cap: cap)
        exit 1 unless result.ok?
      end

      # Parse the `--fields` JSON into the ordered HPACK field list and optional body. Accepts a
      # bare `[[name,value],…]` array or an object `{"fields":[…],"body":"…"/"body_base64":"…"}`.
      # NOTHING is normalized — a leading colon, a leading-space value, an uppercase name are
      # the payload. `abort`s with a clean message on a shape that is not a pair list.
      private def self.parse_h2_fields_file(text : String) : {Array({String, String}), Bytes?}
        doc = begin
          JSON.parse(text)
        rescue ex : JSON::ParseException
          abort "gori run repeater h2: --fields is not valid JSON: #{ex.message}"
        end
        # The BARE-ARRAY form has no object to read `body`/`body_base64` from, and
        # `JSON::Any#[]?(String)` RAISES on an array rather than returning nil — so reading
        # the body keys unconditionally crashed the very form the help text advertises first.
        # Hold the object (if there is one) instead of re-indexing `doc`.
        obj = doc.as_h?
        arr = doc.as_a? || obj.try(&.["fields"]?).try(&.as_a?)
        abort "gori run repeater h2: --fields must be a [[name,value],…] array or {\"fields\":[…]}" unless arr
        fields = [] of {String, String}
        arr.each do |item|
          pair = item.as_a?
          abort "gori run repeater h2: each field must be a [name, value] pair" unless pair && pair.size == 2
          name = pair[0].as_s?
          value = pair[1].as_s?
          abort "gori run repeater h2: field names and values must both be strings" if name.nil? || value.nil?
          fields << {name, value}
        end
        abort "gori run repeater h2: the field list is empty" if fields.empty?
        body =
          if b64 = obj.try(&.["body_base64"]?).try(&.as_s?)
            begin
              Base64.decode(b64)
            rescue
              abort "gori run repeater h2: 'body_base64' is not valid base64"
            end
          else
            obj.try(&.["body"]?).try(&.as_s?).try(&.to_slice)
          end
        {fields, body}
      end

      private def self.cmd_repeater_list(args : Array(String)) : Nil
        proj = ProjectFlags.new
        format = :text

        parse_no_positionals(args, "gori run repeater list",
          "`repeater list` takes no positional arguments; to act on one session use " \
          "`gori run repeater send <id>`") do |p|
          p.banner = "Usage: gori run repeater list [options]"
          project_options(p, proj, "read")
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end

        project = resolve_read_project(proj.name, proj.db)
        with_store(project, read_only: true) do |store|
          repeaters = store.repeaters_mcp
          if format == :json
            puts(JSON.build do |j|
              j.array { repeaters.each_with_index { |r, i| j.object { repeater_row_fields(j, r, i + 1) } } }
            end)
          else
            if repeaters.empty?
              puts "No repeater sessions in the workbench."
            else
              # The chip number leads the line, so `6` here and `6:` on the TUI strip are the
              # same tab — the mapping #904 was filed about. The database id follows it,
              # because that is what every command and every MCP tool actually takes.
              width = repeaters.size.to_s.size
              repeaters.each_with_index do |r, i|
                name = r.name || "Untitled"
                h2 = r.http2? ? "H2" : "H1"
                # The fingerprint is APPENDED, and only when set, so a workbench with no
                # overrides prints exactly the line it always did. It has to be here at all
                # because `repeater create --tls-preset`'s refusal of an unknown name argues
                # that a stored preset is visible ("`repeater list` and the TUI chip both name
                # a browser") — a claim that was not true of this listing.
                tls = r.tls_preset.try { |t| "  tls:#{t}" } || ""
                # The one thing on this line that is not a setting but a DEFECT, so it is
                # appended last and only when it fires. `repeater send` prints the sentence;
                # here there is room for the fact alone, which is all this listing has to do —
                # say which tab is the odd one out. See `unterminated_head_note`.
                bad_head = unterminated_head?(r.request, ws_http_only: r.ws_http_only?, http2: r.http2?)
                head = bad_head ? "  !head-unterminated" : ""
                # The last send's outcome (#1665): the TUI filter's `status:` token (a code,
                # `error` or `unsent`) and the stored body's size, so a 401 reads apart from a 200
                # without re-sending.
                last = Repeater::SubtabFilter::Subject.status_token(r.response_error, r.response_head)
                r.response_body_size.try { |n| last += " #{CLI::Output.human_size(n)}" }
                puts "#{(i + 1).to_s.rjust(width)}  ##{r.id}  [#{h2}]  #{last.ljust(14)}  #{CLI::Output.pad(CLI::Output.term_safe(name), 20)}  → #{CLI::Output.term_safe(r.target)}#{tls}#{head}"
              end
            end
          end
        end
      end

      # One session's fields as `repeater list --format json` prints them — shared with
      # `repeater create --format json` (#1117), so a script sees the same object whether it
      # lists the session or has just created it.
      private def self.repeater_row_fields(j : JSON::Builder, r : Store::RepeaterRecord, tui_index : Int32) : Nil
        j.field "id", r.id
        # Both numbers, named. `position` is the ordering COLUMN; `tui_index` is what the TUI
        # paints on the sub-tab chip, which is the number the operator reads and the one MCP's
        # repeater replies carry.
        j.field "tui_index", tui_index
        j.field "position", r.position
        j.field "name", r.name || "Untitled"
        # What tells two unnamed sessions on one origin apart (`GET /`) — MCP's field.
        j.field "summary", Repeater::SubtabFilter::Subject.listing_summary(String.new(r.request))
        j.field "tags", r.tags
        j.field "target", r.target
        j.field "http2", r.http2?
        j.field "auto_content_length", r.auto_content_length?
        j.field "flow_id", r.flow_id
        j.field "sni", r.sni
        # The session's TLS fingerprint (#844) — null for a session with no override, which is
        # what every session meant before it existed.
        j.field "tls_preset", r.tls_preset
        # Only when it is TRUE, so a workbench of well-formed sessions prints the listing it
        # always did. It is here because the stored bytes of an unterminated request render
        # identically to a terminated one in every view gori has — the whole reason #1075 cost a
        # debugging session — and a listing is where an operator goes to find the odd tab out.
        if unterminated_head?(r.request, ws_http_only: r.ws_http_only?, http2: r.http2?)
          j.field "head_unterminated", true
        end
        j.field "last_error", r.response_error
        j.field "last_duration_us", r.response_duration_us
        # The last response's status and stored body size (#1665); null when never answered.
        j.field "last_status", last_status(r.response_head)
        j.field "last_size", r.response_body_size
      end

      # The status code of a stored response head, nil when there is none (never sent, or an
      # errored send saved as an EMPTY head) or it does not parse.
      private def self.last_status(head : Bytes?) : Int32?
        return nil if head.nil? || head.empty?
        Proxy::Codec::Http1.parse_response_head(head).status
      rescue
        nil
      end

      # `gori run repeater show <id>` (#1665): a saved session's request and its last stored
      # response, read back without sending — the read half of MCP
      # `get_repeater_context{include_content}`. `gori run show` takes a FLOW id, and a session
      # send writes no flow unless `--record-history` was passed.
      private def self.cmd_repeater_show(args : Array(String)) : Nil
        proj = ProjectFlags.new
        format = :text
        redaction = RedactFlags.new
        headers_only = false
        max_body : Int32? = nil

        positional = parse_args(args, "gori run repeater show") do |p|
          p.banner = "Usage: gori run repeater show <repeater-id> [options]\n\n" \
                     "Print a saved session's request and its last stored response, without sending."
          project_options(p, proj, "read")
          p.on("--headers-only", HEADERS_ONLY_HELP) { headers_only = true }
          p.on("--max-body=BYTES", MAX_BODY_HELP) { |v| max_body = parse_count(v, "--max-body") }
          redact_options(p, redaction)
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end
        id = take_id(positional, "gori run repeater show", "<repeater-id>", "repeater id")
        cap = body_cap(headers_only, max_body, "gori run repeater show")

        # The listing row (tab number, body size) and the full row (bodies), read before the
        # store closes; refusals come after it, because `abort` skips `ensure`.
        found, choice = with_store(resolve_read_project(proj.name, proj.db), read_only: true) do |store|
          rows = store.repeaters_mcp
          i = rows.index { |r| r.id == id }
          full = i && store.get_repeater_full(id)
          {i && full ? {rows[i], i + 1, full} : nil, redact_choice(store, redaction)}
        end
        row, tui_index, rec = found || abort "gori run repeater show: no repeater session ##{id} (ids from `gori run repeater list`)"
        abort "gori run repeater show: #{choice.error}" if choice.error
        preview_format_error(redaction, format).try { |err| abort "gori run repeater show: #{err}" }

        req_head, req_body, resp_head, resp_body, report = repeater_show_sides(rec, choice.matcher)
        if report && redaction.preview?
          print_redact_preview(redact_one(report), choice, "repeater show")
          return
        end

        if format == :json
          puts repeater_show_json(row, tui_index, req_head, req_body, resp_head, resp_body,
            Evidence.drifted?(rec), cap)
        else
          print_repeater_show_text(rec, req_head, req_body, resp_head, resp_body, cap)
        end
        # After the document, on STDERR: the pair no longer describes one exchange.
        if Evidence.drifted?(rec)
          STDERR.puts "gori run repeater show: session ##{id}'s request was edited after this response was " \
                      "received, so the two are not one exchange — `gori run repeater send #{id}` to refresh it"
        end
        redact_notes(redact_one(report), choice, "repeater show")
      end

      # The session's request split into head and body, and its last response (nil when never
      # answered: an errored send is saved as an EMPTY head) — sanitized when a redaction
      # profile is in play, with the report that says what it did.
      private def self.repeater_show_sides(rec : Store::RepeaterRecord, matcher : Redact::Matcher?) : {Bytes, Bytes?, Bytes?, Bytes?, Redact::Report?}
        req_head, req_body = Env.split_head_body(rec.request)
        resp_head = rec.response_head.try { |h| h.empty? ? nil : h }
        resp_body = resp_head ? rec.response_body : nil
        return {req_head, req_body, resp_head, resp_body, nil} unless matcher
        req = Redact::Wire.message(req_head, req_body, matcher)
        res = Redact::Wire.message(resp_head, resp_body, matcher)
        report = Redact::Report.new(matcher.profile, req, res, matcher.pattern_errors)
        {req.head, req.body, resp_head && res.head, res.body, report}
      end

      private def self.print_repeater_show_text(rec : Store::RepeaterRecord, req_head : Bytes, req_body : Bytes?,
                                                resp_head : Bytes?, resp_body : Bytes?, cap : BodyCap) : Nil
        puts "=== REQUEST ==="
        print_message_text(req_head, display_body(req_head, req_body), req_body, cap, SEND_EXACT_BYTES)
        puts ""
        took = rec.response_duration_us.try { |d| " (in #{CLI::Output.human_us(d)})" } || ""
        puts "=== LAST RESPONSE#{took} ==="
        if err = rec.response_error
          puts "send failed: #{CLI::Output.term_line(err)}"
        elsif resp_head.nil?
          puts "(never sent — `gori run repeater send #{rec.id}`)"
        end
        print_message_text(resp_head, display_body(resp_head, resp_body), resp_body, cap, SEND_EXACT_BYTES) if resp_head
      end

      # `repeater show --format json`: the listing row's fields, then the request and the last
      # response as `repeater send --format json` shapes them.
      def self.repeater_show_json(row : Store::RepeaterRecord, tui_index : Int32,
                                  req_head : Bytes, req_body : Bytes?,
                                  resp_head : Bytes?, resp_body : Bytes?,
                                  drifted : Bool, cap : BodyCap = BodyCap.new) : String
        JSON.build do |j|
          j.object do
            repeater_row_fields(j, row, tui_index)
            j.field "request_drifted", true if drifted
            j.field "request" do
              j.object do
                j.field "head", scrub(req_head)
                emit_lossy_head_json(j, req_head)
                emit_body_json(j, "body", req_head, req_body, false, cap)
              end
            end
            j.field "response" do
              if head = resp_head
                j.object do
                  resp = begin
                    Proxy::Codec::Http1.parse_response_head(head)
                  rescue
                    nil
                  end
                  if resp
                    j.field "status", resp.status
                    repeater_response_fields(j, resp)
                  end
                  j.field "head", scrub(head)
                  emit_lossy_head_json(j, head)
                  emit_body_json(j, "body", head, resp_body, false, cap)
                end
              else
                j.null
              end
            end
          end
        end
      end

      # `gori run repeater move <id> --to N | --up | --down` — rearrange the sub-tab strip.
      #
      # `--to` takes the 1-based TAB NUMBER, the same one `repeater list` prints and the TUI
      # paints on the chip; `<id>` is the database id, as everywhere else on this surface.
      # That split is deliberate: a destination that is stale merely misplaces this session,
      # while a stale SELECTOR would act on a different one.
      #
      # An open TUI picks the new order up on its own — its reconcile poll re-sorts by
      # {position, id} whenever a peer commits.
      private def self.cmd_repeater_move(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        to : Int32? = nil
        dir = 0
        format = :text
        positional = [] of String

        parser = option_parser("gori run repeater move") do |p|
          p.banner = "Usage: gori run repeater move <repeater-id> (--to N | --up | --down)"
          p.on("--to=N", "Move to this 1-based tab number (the number `repeater list` prints)") do |v|
            to = v.to_i32? || abort("gori run repeater move: invalid --to '#{v}' (expected a 1-based tab number)")
          end
          # `--up --down` is two answers like `--to` with either, refused rather than left to
          # flag order.
          p.on("--up", "Move one place toward tab 1") do
            abort "gori run repeater move: pass one of --up or --down" if dir == 1
            dir = -1
          end
          p.on("--down", "Move one place toward the end") do
            abort "gori run repeater move: pass one of --up or --down" if dir == -1
            dir = 1
          end
          p.on("--project=NAME", "Project to act on (#{DEFAULT_PROJECT_HELP})") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file") { |v| db_path = v }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
          # Through the helper IN the sink, not twenty lines below it: a bare
          # `positional = before + after` here reads fine and drops every token after the
          # first, which is the shape `list_leftovers_spec`'s source gate exists to catch.
          p.unknown_args do |before, after|
            positional = one_positional_list(before, after, "gori run repeater move", "<repeater-id>")
          end
        end
        parser.parse(args)

        id_s = positional.first? || abort("gori run repeater move: <repeater-id> is required\n#{parser}")
        id = id_s.to_i64? || abort("gori run repeater move: invalid repeater id '#{id_s}'")

        # Two answers to one question. Choosing one silently is how a tab lands somewhere
        # nobody asked for — the same refusal MCP's `move_repeater` makes.
        abort "gori run repeater move: pass --to or --up/--down, not both" if to && dir != 0
        abort "gori run repeater move: pass one of --to N, --up or --down\n#{parser}" if to.nil? && dir == 0

        with_store(resolve_read_project(project_name, db_path)) do |store|
          rows = store.repeaters_meta
          from = rows.index { |r| r.id == id }
          abort "gori run repeater move: no repeater session ##{id} (see `gori run repeater list`)" unless from
          from += 1

          target =
            if t = to
              # REFUSED, not clamped: a clamp would move the session somewhere other than
              # where the command named and still exit 0.
              abort "gori run repeater move: --to #{t} is outside this workbench (1-#{rows.size})" unless 1 <= t <= rows.size
              t
            else
              t2 = from + dir
              abort "gori run repeater move: session ##{id} is already at the #{dir < 0 ? "start" : "end"} " \
                    "of the workbench (tab #{from} of #{rows.size})" unless 1 <= t2 <= rows.size
              t2
            end

          moved = target != from
          if moved
            ids = rows.map(&.id)
            ids.delete_at(from - 1)
            ids.insert(target - 1, id)
            abort "gori run repeater move: NOT moved (project busy or unwritable); the order is unchanged" unless store.set_repeater_positions(ids)
          end

          if format == :json
            puts({"id" => id, "from_index" => from, "to_index" => target, "moved" => moved}.to_json)
          elsif moved
            puts "Repeater session ##{id} moved from tab #{from} to tab #{target}."
          else
            puts "Repeater session ##{id} is already tab #{target}."
          end
        end
      end

      # `gori run repeater delete <id> [<id>…] --yes` — close saved sessions headlessly.
      #
      # `--yes` is required because there is no undo: a session's request bytes, its stored
      # WebSocket frames and any issue link pointing at it go with it. Unknown ids refuse the
      # WHOLE command before the first delete, so a typo cannot destroy the eight that did
      # exist and report the ninth as skipped.
      private def self.cmd_repeater_delete(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        yes = false
        format = :text
        positional = [] of String

        parser = option_parser("gori run repeater delete") do |p|
          p.banner = "Usage: gori run repeater delete <repeater-id> [<repeater-id>…] --yes"
          p.on("-y", "--yes", "Confirm the deletion (required)") { yes = true }
          p.on("--project=NAME", "Project to act on (#{DEFAULT_PROJECT_HELP})") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file") { |v| db_path = v }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
          p.unknown_args { |before, after| positional = before + after }
        end
        parser.parse(args)

        abort "gori run repeater delete: at least one <repeater-id> is required\n#{parser}" if positional.empty?
        ids = positional.map do |tok|
          tok.to_i64? || abort("gori run repeater delete: invalid repeater id '#{tok}'")
        end
        ids = ids.uniq

        with_store(resolve_read_project(project_name, db_path)) do |store|
          rows = store.repeaters_mcp
          by_id = rows.index_by(&.id)
          missing = ids.reject { |i| by_id.has_key?(i) }
          abort "gori run repeater delete: no repeater session #{missing.join(", ")} — nothing was deleted " \
                "(see `gori run repeater list`)" unless missing.empty?

          unless yes
            abort "gori run repeater delete: refusing to delete #{Gori.plural(ids.size, "session")} " \
                  "without --yes; this cannot be undone"
          end

          # The tab number each id HAS, taken once before the first delete — every later tab
          # shifts down, so a number read mid-batch would be relative to a different strip.
          tab_of = {} of Int64 => Int32
          rows.each_with_index { |r, i| tab_of[r.id] = i + 1 }

          deleted = [] of {Int64, String, Int32}
          failed = [] of Int64
          ids.each do |i|
            was = tab_of[i]
            if store.delete_repeater(i)
              deleted << {i, by_id[i].name || "Untitled", was}
            else
              failed << i
            end
          end
          gone = deleted.map { |(i, _, _)| i }.to_set
          store.set_repeater_positions(rows.reject { |r| gone.includes?(r.id) }.map(&.id))

          if format == :json
            puts({
              "deleted"   => deleted.map { |(i, n, was)| {"id" => i, "name" => n, "was_tui_index" => was} },
              "failed"    => failed,
              "remaining" => rows.size - deleted.size,
            }.to_json)
          else
            deleted.each { |(i, n, was)| puts "Deleted repeater session ##{i} (tab #{was}, #{CLI::Output.term_safe(n)})." }
            STDERR.puts "NOT deleted (project busy or unwritable): #{failed.join(", ")}" unless failed.empty?
          end
          exit 1 unless failed.empty?
        end
      end

      # The optional post-insert labels (insert_repeater takes neither). Split out of
      # cmd_repeater_create, which is already over the cyclomatic-complexity bar.
      #
      # These two KEEP `mask_secrets`, unlike the target and the SNI beside them: a name and a
      # tag are the TUI's tab and subtab captions and never reach a socket, so masking them is
      # a display choice with no wire consequence. The rule is "does this field become bytes
      # the origin sees", not "did the operator type it".
      #
      # Tags go through `Repeater::Tags.stored`, as MCP's do: `#idor, x,,#IDOR` is stored
      # `idor x`, and a token-free `#` stores nothing. A blank name stores NULL ("Untitled"),
      # which on `update` is how a name is cleared.
      #
      # Returns whether every write it made COMMITTED — the caller prints a success line, and
      # both writes are `exec_task_ok`, so a rolled-back batch (a busy store, a TUI capturing
      # into the same project) would otherwise be reported as a labelled session.
      private def self.apply_repeater_metadata(store : Store, id : Int64,
                                               name : String?, tags : String?) : Bool
        ok = true
        ok = false if name && !store.set_repeater_name(id, Env.mask_secrets(name).strip.presence)
        ok = false if tags && !store.set_repeater_tags(id, Repeater::Tags.stored(tags))
        ok
      end

      # A repeater write can be refused after the store itself opened successfully: the TUI may
      # have taken SQLite's single writer slot between the migration and this operation. Keep the
      # retry advice in one sentence so create, metadata, WS frames and response persistence do
      # not fall back to the old silent/generic wording (#1118).
      #
      # The PATH, not `project.name`: for a `--db PATH` target that name is the path's parent
      # directory (`resolve_read_project`), and naming it as a project invented one. The path
      # is true for both target forms and is what the operator typed or the registry resolved.
      private def self.project_write_failure(prefix : String, project : Project) : String
        "#{prefix}: the project at #{project.db_path} is busy or unwritable — another gori " \
        "(a TUI, a capture, or an MCP server) may hold its writer slot; retry, or close it"
      end

      # The half of `project_write_warning` that is about the SEND, for a failure sentence that
      # already says what happened to the write (`persist_repeater_response`).
      private def self.project_write_warning_tail : String
        " — the send attempt is already complete; do not retry solely because of this write failure"
      end

      # What became of one write `repeater send` makes AFTER the origin answered — the stored
      # response, or the `--record-history` flow. `error` nil means it landed.
      #
      # These ride the ONE result object `--format json` prints, so a script can tell. They
      # used to be STDERR prose under exit 0: `gori run repeater send 7 --format json | jq`
      # under a busy project was byte-identical to a successful run while the row still held
      # the PREVIOUS response — so the next `send 7 --diff` diffed against a stale baseline and
      # reported "no differences". Exit 0 stays (the request reached the origin; a shell must
      # not resend it), which is exactly why the machine-readable half has to carry the answer:
      # a report emitted before the side effect cannot, so both writes now happen before the
      # emit (#1118).
      record WriteOutcome, error : String? do
        def ok? : Bool
          @error.nil?
        end
      end

      # The post-send writes for `--save-as-repeater`. The id is present once the session row
      # committed, even if the response write that follows it did not.
      record SendRepeaterOutcome, id : Int64?, save_write : WriteOutcome, response_write : WriteOutcome?

      # Persist a completed one-shot send without turning a project write failure into a retry
      # of a request that already reached its origin.
      private def self.save_send_as_repeater(plan : Repeater::Plan, request : Bytes,
                                             result : Repeater::Result, flow_id : Int64?,
                                             project : Project, prefix : String) : SendRepeaterOutcome
        store = begin
          open_store(project, abort_on_failure: false)
        rescue ex : Gori::Error | DB::Error | SQLite3::Exception
          message = "#{prefix}: Repeater session was NOT saved: #{open_failure_message(ex, project)}"
          return SendRepeaterOutcome.new(nil, WriteOutcome.new(message), nil)
        end

        begin
          saved = Repeater::SendPersistence.persist(store, plan.scheme, plan.host, plan.port,
            request, plan.http2?, false, flow_id, result, plan.h2_fields,
            sni: plan.sni, tls_preset: plan.tls_preset)
          id = saved.id
          unless id
            message = project_write_failure("#{prefix}: Repeater session was NOT saved", project)
            return SendRepeaterOutcome.new(nil, WriteOutcome.new(message), nil)
          end

          response_error = saved.response_saved? ? nil : project_write_failure(
            "#{prefix}: Repeater response was NOT saved", project)
          SendRepeaterOutcome.new(id, WriteOutcome.new(nil), WriteOutcome.new(response_error))
        rescue Gori::Error | DB::Error | SQLite3::Exception
          message = project_write_failure("#{prefix}: Repeater session was NOT saved", project)
          SendRepeaterOutcome.new(nil, WriteOutcome.new(message), nil)
        ensure
          store.close
        end
      end

      # `request_sources` / `request_source_error` / `request_content` are PUBLIC for the same
      # reason `two_targets_error` is: they are split from the `abort` so a spec can pin both
      # the condition and the wording, and `cmd_repeater_create` ends in `abort`, which a spec
      # cannot drive. Same precedent as `colormarker_rule_row` and `view_row`.
      #
      # The request sources `repeater create` accepts, in the parser's order, filtered to the
      # ones actually given. ONE list, built once by the caller and read by both the
      # mutual-exclusion gate and the `--flow` seeding test: the two questions are "how many
      # sources?" and "was there one at all?", and asking them of separately maintained
      # expressions is how a source gets refused in one place and silently overwritten in the
      # other. `--flow` is deliberately NOT on this list — it doubles as provenance for a
      # hand-authored request, so `--flow 42 --request-stdin` is a legitimate pair.
      def self.request_sources(*, file : String?, raw : String?, stdin : Bool,
                               curl : String? = nil) : Array(String)
        sources = [] of String
        sources << "--request-file" if file
        sources << "--request-raw" if raw
        sources << "--request-stdin" if stdin
        sources << "--curl" if curl
        sources
      end

      # nil when `sources` names exactly one request source (or none, with `--flow` standing in
      # for it); the sentence to `abort` with otherwise.
      #
      # The over-specified half is not new: the branch that reads the request is an `if/elsif`
      # chain, so `--request-file a.txt --request-raw 'GET / HTTP/1.1'` stored the FILE and
      # never mentioned the string. Two sources cannot both be the request, and picking one by
      # parser order is a guess made silently. The sentence hardcodes the command because
      # `repeater create` is the only site: `fuzz` already refuses every pair of its three
      # sources, and `mine`/`sequence` each refuse their one pair.
      def self.request_source_error(sources : Array(String), *, flow : Bool) : String?
        if sources.size > 1
          return "gori run repeater create: #{sources.join(", ")} cannot be combined — pick one request source"
        end
        if sources.empty? && !flow
          return "gori run repeater create: either --request-file, --request-raw, --request-stdin, --curl, or --flow is required"
        end
        nil
      end

      # nil when the content is usable; the sentence to `abort` with otherwise. Refused for
      # EVERY source, not just the pipe: a session whose request is empty cannot be sent
      # (`PlanError::NoRequest`) and MCP's `create_repeater` already refuses one, so
      # `--request-raw ''`, an empty file and a generator that died each used to buy a dead row
      # reported as a clean "session #N created successfully." `sources` names the culprit, and
      # an EMPTY `sources` is the `--flow` case, whose request is seeded from the capture after
      # this point. Same shape and reason as `intercept edit`'s empty-replacement refusal.
      def self.request_content_error(sources : Array(String), content : String,
                                     cmd : String = "gori run repeater create") : String?
        return nil if sources.empty? || !content.empty?
        "#{cmd}: the request must not be empty (#{sources.first} gave no bytes)"
      end

      # The request bytes from whichever single source the gate allowed through. `""` means no
      # source at all, which is only reachable with `--flow`, whose capture seeds the request
      # instead. The branch SELECTION lives here rather than inline in `cmd_repeater_create` so
      # a spec can prove each door hands back its own bytes — an inline chain is only reachable
      # through a command that opens a store and ends in `abort`, so deleting a branch from it
      # is a silent behavior change no spec sees.
      def self.request_content(*, file : String?, raw : String?, stdin : Bool,
                               io : IO, what : String) : String
        if f = file
          read_input_file(f, what, noun: "request")
        elsif r = raw
          r
        elsif stdin
          read_request_stdin(io, what)
        else
          ""
        end
      end

      # `--request-stdin`: the request bytes, verbatim — the terminal refusal, the byte
      # fidelity and the `IO::Error` rescue all live in `read_stdin_text`, which
      # `issues create/update`'s `--notes-stdin` reads through too. Public (and kept as its
      # own name) so the spec can drive THIS door rather than the shared reader: the noun is
      # half the contract.
      #
      # The hint is built HERE rather than in the shared reader because it is the half of the
      # refusal that only this flag can write: the pipe is the documented spelling, and
      # `--request-file` is the one alternative that reads the same bytes.
      def self.read_request_stdin(io : IO, what : String) : String
        read_stdin_text(io, what, "request",
          stdin_pipe_hint(what, flag: "--request-stdin", file_flag: "--request-file",
            producer: "generator"))
      end

      private def self.cmd_repeater_create(args : Array(String)) : Nil
        proj = ProjectFlags.new
        target : String? = nil
        request_file : String? = nil
        request_raw : String? = nil
        request_stdin = false
        curl_path : String? = nil
        name : String? = nil
        tags : String? = nil
        http2 = false
        http2_given = false
        auto_cl = true
        flow_id : Int64? = nil
        sni : String? = nil
        ws_keep_key = false
        ws_http_only = false
        keep_request_line = false
        tls_preset : String? = nil
        format = :text

        # A bare word here is almost always the request or the target the operator meant to
        # pass through a flag, and creating the session WITHOUT it left a row whose request
        # was not the one they typed — reported as a clean "session #N created".
        parse_no_positionals(args, "gori run repeater create",
          "pass the request via --request-file/--request-raw/--request-stdin/--curl/--flow and the origin via --target") do |p|
          p.banner = "Usage: gori run repeater create [options]\n\n#{EVIDENCE_LINK_HELP}\n"
          project_options(p, proj, "update")
          p.on("-tURL", "--target=URL", "Target URL (scheme://host[:port])") { |v| target = v }
          p.on("-fFILE", "--request-file=FILE", "Read raw HTTP request from FILE") { |v| request_file = v }
          p.on("-rRAW", "--request-raw=RAW", "Verbatim raw HTTP request string") { |v| request_raw = v }
          p.on("--request-stdin", "Read the raw HTTP request from stdin, byte-for-byte, as --request-file reads a file (`generator | gori run repeater create --target … --request-stdin`). Keeps a large or binary-derived request out of the argument vector, so it is not in the process listing and cannot hit the command-line length limit. Needs a pipe or a redirect (`< req.http`): a terminal is refused, because it would echo the request back") { request_stdin = true }
          p.on("--curl=PATH", "Build the request from the curl command in PATH (- reads stdin: `pbpaste | gori run repeater create --curl -`). It also supplies --target (the URL's origin) and --http2 (curl's --http2) unless those are given; curl's transport flags (-k, -x, -L…) are ignored and named") { |v| curl_path = v }
          p.on("--name=NAME", "Custom repeater tab name") { |v| name = v }
          p.on("--tags=TAGS", "Free-text tags for grouping tabs (the TUI subtab label)") { |v| tags = v }
          p.on("--http2", "Use HTTP/2 (default: false, how --flow was captured, or what --curl says)") { http2 = agree(http2_given ? http2 : nil, true, "--http1/--http2"); http2_given = true }
          # The other half of the toggle: without it a session cloned from an h2 flow
          # (`--flow=N`) inherited h2 and `repeater send` had no way to override it, so an
          # h2 capture could never be replayed as h1 from the CLI at all.
          p.on("--http1", "Use HTTP/1.1 — overrides an h2-captured --flow (alias: --no-http2)") { http2 = agree(http2_given ? http2 : nil, false, "--http1/--http2"); http2_given = true }
          p.on("--no-http2", "Alias for --http1") { http2 = agree(http2_given ? http2 : nil, false, "--http1/--http2"); http2_given = true }
          p.on("--no-auto-cl", "Do not auto-calculate Content-Length header") { auto_cl = false }
          p.on("--flow=ID", "Optional original flow ID this repeater stems from") { |v| flow_id = parse_flow_id(v, "gori run repeater create") }
          p.on("--keep-request-line", "With --flow: store the flow's request line as-is — do not rewrite an absolute-form line (\"GET http://h/p\") to origin-form") { keep_request_line = true }
          p.on("--sni=HOST", "TLS SNI override") { |v| sni = v }
          p.on("--tls-preset=NAME", "#{TLS_PRESET_HELP}. Stored on the session, so `repeater send` and a reopened TUI tab present it too") { |v| tls_preset = v }
          p.on("--ws-keep-key", "WebSocket: send the request's own Sec-WebSocket-Key instead of a fresh one (lets an absent/short/duplicate/non-base64 key be tested)") { ws_keep_key = true }
          p.on("--ws-http-only", "WebSocket: treat this session as plain HTTP — the handshake is sent as an ordinary request and its own answer (a 101, or the 2xx of an RFC 8441 extended CONNECT) read as the response, instead of the framed exchange. Stored on the session (the TUI's ^V); `repeater send --http` is the per-send form") { ws_http_only = true }
          format_flag(p, [:text, :json], "Output: text (default) | json — the new session as `repeater list --format json` prints it, plus websocket / ws_messages / request_line_rewritten") { |f| format = f }
        end

        # ONE build of the source list, shared by the gate below and the `--flow` seeding
        # further down, so the two can never disagree about whether a request was handed in.
        sources = request_sources(file: request_file, raw: request_raw, stdin: request_stdin, curl: curl_path)

        # EVERY argv-only refusal goes above the read, because `--request-stdin` blocks until
        # EOF: a conflict, or a missing --target, used to drain the pipe first — and hang
        # outright on a terminal — before reporting something knowable from the arguments
        # alone. `--target` pairs with `--flow` here only because a capture can supply it;
        # the later `tgt_str.empty?` check still catches a --flow whose own target is unusable.
        if err = request_source_error(sources, flow: !flow_id.nil?)
          abort err
        end
        abort "gori run repeater create: --target is required" if target.nil? && flow_id.nil? && curl_path.nil?
        # Argv-only too, and it used to sit below BOTH the read and `open_store`: a typo'd
        # preset drained the generator and took the project's open-lock before saying that a
        # word typed on the command line is not one of four. The normalize stays with it, so
        # the value the row is built from is still decided in one place.
        if err = Settings.tls_preset_error(tls_preset)
          abort "gori run repeater create: #{err}"
        end
        tls_preset = Settings.tls_preset_normalize(tls_preset)
        # An explicit --target is argv too. A seeded one (--flow, --curl) is asked again below.
        if (t = target) && (why = Repeater::Plan.target_error(t))
          abort "gori run repeater create: invalid --target: #{why}"
        end

        authored = !sources.empty?
        # Read here, before `open_store`: a pipe that never ends must not be holding the
        # project's shared open-lock while it waits (`Store.open` → `<db>.open.lock`).
        req_content = request_content(file: request_file, raw: request_raw,
          stdin: request_stdin, io: STDIN, what: "gori run repeater create")
        if path = curl_path
          curl = curl_request(path, "gori run repeater create")
          req_content = curl.text
          target ||= curl.origin
          http2 = curl.http2? unless http2_given
        end
        if err = request_content_error(sources, req_content)
          abort err
        end

        project = resolve_read_project(proj.name, proj.db)
        with_store(project) do |store|
          tgt_val = target
          tgt_str : String = tgt_val ? tgt_val : ""
          ws_messages = [] of Store::WsOutMessage
          is_ws = false
          rewrote_request_line = false

          if fid = flow_id
            detail = store.get_flow(fid)
            abort "gori run repeater create: no flow ##{fid} to clone" unless detail
            # The rewrite is PERSISTED here, so this is the one door where it cannot be
            # undone later: `repeater send --verbatim` sends the stored row, and by then the
            # absolute-form line is gone. `gori run repeater <flow-id>` grew
            # `--keep-request-line` for the direct replay; this is the same flag on the
            # workbench door, and the rewrite is reported either way (see `Built`).
            built = Repeater::FlowRequest.build(detail, rewrite_absolute_form: !keep_request_line)
            # Only seed the request from the flow when the user didn't hand one in: --flow
            # doubles as provenance (the flow_id column) for a custom --request-raw/-file/-stdin,
            # so an explicit request must NOT be silently overwritten by the flow's bytes.
            # `authored` and not a hand-written chain of `.nil?`s — the list of sources is one
            # thing, and the gate above and this test have to read the same one or a fourth
            # source arrives here already overwritten. The rewrite note and flag go with the
            # seed: beside an authored request nothing was rewritten.
            unless authored
              warn_request_line_rewrite(built, "gori run repeater create", now: true)
              rewrote_request_line = built.rewrote_request_line
              req_content = String.new(built.bytes)
            end
            if tgt_str.empty?
              bt = built.target
              tgt_str = bt ? bt : ""
              # The capture's SNI goes with the capture's origin, never onto an operator's
              # `--target`; an explicit `--sni` wins. MCP `create_repeater{flow_id}` does the same.
              sni ||= Repeater::FlowRequest.seed_sni(detail)
            end

            # A `--curl` request already said which protocol it speaks (`--http2` or not), and with
            # it `--flow` is provenance only — as MCP `create_repeater{curl, flow_id}` reads it.
            unless http2_given || curl_path
              http2 = built.http2
            end

            # `WsEngine.replayable?`, not `row.status == 101` (#742). What this session has to
            # be able to do is `repeater send` — and that runs `WsEngine`, which re-opens a
            # socket from either handshake: an HTTP/1.1 `Upgrade:` head, or an RFC 8441
            # extended CONNECT over h2 (#733: `CONNECT`, answered `200`). The status was the h1
            # handshake's, standing in for the handshake, so the h2 shape fell into the
            # plain-HTTP branch and its frames were never mentioned again.
            if Repeater::WsEngine.replayable?(String.new(detail.request_head))
              is_ws = true
              # Opcode AND bytes, straight across. This used to be
              # `select(&.text?).map { String.new(m.payload).scrub }`: a binary outbound frame
              # was dropped with a warning (protobuf/msgpack/CBOR/MQTT-over-WS, i.e. most
              # non-toy WS apps), and a TEXT frame carrying invalid UTF-8 — the §8.1/§5.6
              # validation payload — was silently rewritten to U+FFFD before it was even stored.
              # `ws_seed_rows`: a `[gori]` advisory in the capture is gori talking ABOUT
              # the socket, never a frame the client sent, so it must not become one — and
              # the drop is announced rather than shrinking the seed in silence.
              seed_rows, dropped = Run.ws_seed_rows(store.ws_messages(fid))
              STDERR.puts "gori run repeater create: #{Run.ws_notice_dropped_note(dropped)}" if dropped > 0
              ws_messages = seed_rows
                .map { |m| Store::WsOutMessage.new(m.opcode, m.payload, Run.seed_shape(m.shape)) }
            end
          end

          abort "gori run repeater create: --target is required" if tgt_str.empty?
          # Refused at write time, as MCP `create_repeater` refuses it: a `ftp://` session was
          # reported created and failed on every `repeater send` after.
          if why = Repeater::Plan.target_error(tgt_str)
            abort "gori run repeater create: invalid target: #{why}"
          end
          # A hand-authored handshake is a WebSocket session too: `repeater send` runs WsEngine
          # on it exactly as on a cloned one, and MCP `create_repeater` asks the same question
          # of every source. Only the flow path above seeds frames.
          is_ws ||= Repeater::WsEngine.replayable?(req_content)
          # The preset was refused and normalized ABOVE, before the request read — it is an
          # argv value, and nothing between here and there can change it. Refused at all (and
          # not left for the first send) because an unknown preset applies nothing: a session
          # stored with one dials with gori's bare OpenSSL hello on every later send while
          # `repeater list` and the TUI chip both name a browser, and unlike the destination
          # table there is no startup warning to catch it.

          pos = store.next_repeater_position

          # The REQUEST, the TARGET and the SNI are all stored as authored. Same seam and same
          # reason as `MCP::Tools#create_repeater`: `mask_secrets` here rewrote an author's live
          # value — or, on `--flow`, a CAPTURE's own bytes — to `$KEY` in the stored row, and
          # the TUI then read that row through `RepeaterView#evidence?`, which does not expand
          # `$NAME`. One row, `$KEY` on the wire from the TUI and the value from here.
          #
          # The target was the one field left masked, on the theory that it has "no wire
          # semantics of its own". It has: it is the dial tuple, and it supplies the TLS
          # ClientHello ServerName whenever `--sni` is absent. And masking resolves against
          # `Env.masking_vars` (env vars PLUS every session-binding value held) while the send
          # path resolves with `Env.effective_vars` and refuses a declared binding name
          # outright — so a binding value masked in here mints a `$NAME` no surface can ever
          # resolve, and the operator's string is gone. `--sni` was already stored verbatim;
          # this makes the two agree.
          id = store.insert_repeater(
            target: tgt_str,
            request: req_content.to_slice,
            http2: http2,
            auto_cl: auto_cl,
            flow_id: flow_id,
            position: pos.to_i32,
            sni: sni,
            ws_keep_key: ws_keep_key,
            ws_http_only: ws_http_only,
            tls_preset: tls_preset
          )

          abort project_write_failure("gori run repeater create: failed to create repeater session", project) if id == 0

          unless apply_repeater_metadata(store, id, name, tags)
            abort project_write_failure(
              "gori run repeater create: session ##{id} was created, but its name/tag metadata was NOT fully saved", project)
          end

          if is_ws && !ws_messages.empty?
            # A rollback here leaves the fresh session holding NO frames (the batch opens with
            # `DELETE FROM ws_messages`), so the success line below would name a WebSocket
            # session that cannot replay anything.
            unless store.update_repeater_ws_messages(id, ws_messages)
              abort project_write_failure(
                "gori run repeater create: session ##{id} was created, but its WebSocket messages were NOT saved", project)
            end
          end

          # Announced, not refused — see `unterminated_head_note`. On STDERR, beside the
          # `--flow` rewrite and dropped-advisory notices, so `--format`-less STDOUT stays the
          # one success line a script reads. Computed from `req_content`, the bytes this call
          # actually stored (the `--flow` seed included), and NOT re-read from the row: a
          # report taken after the write describes the write, not the row a peer may have
          # touched since.
          #
          # Through `unterminated_head?`, which owns the WebSocket exemption: a row that will
          # go out through `WsEngine` is re-framed by `build_handshake` on every send, so
          # saying gori sends it "exactly as given" would be a false accusation. A row later
          # switched to HTTP (`^V`, `repeater send --http`) is caught by the send-time notice,
          # which asks the same question of the bytes actually going out.
          if unterminated_head?(req_content.to_slice, ws_http_only: ws_http_only, http2: http2)
            STDERR.puts "gori run repeater create: #{unterminated_head_note}"
          end
          if format == :json
            puts repeater_created_json(store, id, is_ws, ws_messages.size, rewrote_request_line)
          else
            puts "Repeater session ##{id} created successfully."
          end
        end
      end

      # `gori run repeater update <id>` (#1681): edit a saved session IN PLACE, the headless
      # `update_repeater`. Delete + create was the only way before, and it changed the id —
      # orphaning every retest step and evidence link that pointed at it. A flag left out keeps
      # what the row holds; the target, name and tags take the write-time checks `create` runs.
      #
      # No slot disarm, unlike MCP: a slot whose refresh replays this session stops refreshing
      # on its own there because an AGENT changed what it sends. The operator re-arms it from
      # this surface, so the operator's own edit leaves it armed — as `repeater minimize --apply`
      # does.
      private def self.cmd_repeater_update(args : Array(String)) : Nil
        cmd = "gori run repeater update"
        proj = ProjectFlags.new
        f = RepeaterUpdateFlags.new
        format = :text

        raw_id = one_positional(args, cmd, "<repeater-id>") do |p|
          p.banner = "Usage: #{cmd} <repeater-id> [options]\n\n" \
                     "Edit a saved session in place (the id, its retest steps and links are kept).\n" \
                     "A flag left out keeps the stored value."
          project_options(p, proj, "update")
          p.on("-tURL", "--target=URL", "New target URL (scheme://host[:port])") { |v| f.target = v }
          p.on("-fFILE", "--request-file=FILE", "Replace the stored request with FILE's bytes") { |v| f.request_file = v }
          p.on("-rRAW", "--request-raw=RAW", "Replace the stored request with this string, verbatim") { |v| f.request_raw = v }
          p.on("--request-stdin", "Replace the stored request with stdin, byte-for-byte (a pipe or a redirect, as on `repeater create`)") { f.request_stdin = true }
          p.on("--name=NAME", "Tab name ('' resets it to Untitled)") { |v| f.name = v }
          p.on("--tags=TAGS", "Tags for grouping tabs, replacing the stored ones ('' clears them)") { |v| f.tags = v }
          p.on("--http2", "Use HTTP/2") { f.http2 = agree(f.http2, true, "--http1/--http2") }
          p.on("--http1", "Use HTTP/1.1 (alias: --no-http2)") { f.http2 = agree(f.http2, false, "--http1/--http2") }
          p.on("--no-http2", "Alias for --http1") { f.http2 = agree(f.http2, false, "--http1/--http2") }
          p.on("--sni=HOST", "TLS SNI override ('' clears it)") { |v| f.sni = v }
          p.on("--no-auto-cl", "Do not auto-calculate the Content-Length header") { f.auto_cl = agree(f.auto_cl, false, "--auto-cl/--no-auto-cl") }
          p.on("--auto-cl", "Auto-calculate the Content-Length header (the default a session is created with)") { f.auto_cl = agree(f.auto_cl, true, "--auto-cl/--no-auto-cl") }
          format_flag(p, [:text, :json], "Output: text (default) | json — the session as `repeater list --format json` prints it") { |v| format = v }
        end
        raw_id || abort "#{cmd}: missing <repeater-id>"
        id = raw_id.to_i64? || abort "#{cmd}: invalid repeater id '#{raw_id}'"

        # Every argv-only refusal above the read, as on `create`: `--request-stdin` blocks to EOF.
        sources = f.sources
        if err = repeater_update_error(f, sources)
          abort "#{cmd}: #{err}"
        end
        content = request_content(file: f.request_file, raw: f.request_raw,
          stdin: f.request_stdin?, io: STDIN, what: cmd)
        if err = request_content_error(sources, content, cmd)
          abort err
        end

        project = resolve_read_project(proj.name, proj.db)
        with_store(project) do |store|
          existing = store.get_repeater(id) || abort "#{cmd}: no repeater session ##{id}"
          write_repeater_update(store, project, existing, f, sources.empty? ? existing.request : content.to_slice, format, cmd)
        end
      end

      # `repeater update`'s flags. nil = the flag was not given, so the row keeps its value.
      class RepeaterUpdateFlags
        property target : String? = nil
        property request_file : String? = nil
        property request_raw : String? = nil
        property? request_stdin = false
        property name : String? = nil
        property tags : String? = nil
        property http2 : Bool? = nil
        property auto_cl : Bool? = nil
        property sni : String? = nil

        def sources : Array(String)
          Run.request_sources(file: request_file, raw: request_raw, stdin: request_stdin?)
        end
      end

      # nil when `repeater update`'s argv is usable; the refusal (without the prefix) otherwise.
      # Public so a spec can pin it: the command ends in `abort`.
      def self.repeater_update_error(f : RepeaterUpdateFlags, sources : Array(String)) : String?
        return "#{sources.join(", ")} cannot be combined — pick one request source" if sources.size > 1
        if sources.empty? && [f.target, f.name, f.tags, f.http2, f.auto_cl, f.sni].all?(Nil)
          return "nothing to change — pass --target, a request source, --name, --tags, " \
                 "--http1/--http2, --sni or --auto-cl/--no-auto-cl"
        end
        return nil unless t = f.target
        return "--target must not be empty" if t.empty?
        Repeater::Plan.target_error(t).try { |why| "invalid --target: #{why}" }
      end

      # The write half of `repeater update`: the row, then its labels, then the report. The
      # target, request and SNI are stored as authored, like `create`'s — see the insert there.
      private def self.write_repeater_update(store : Store, project : Project, existing : Store::RepeaterRecord,
                                             f : RepeaterUpdateFlags, request : Bytes, format : Symbol, cmd : String) : Nil
        id = existing.id
        http2 = f.http2.nil? ? existing.http2? : f.http2 == true
        sni = (given = f.sni) ? given.presence : existing.sni
        written = store.update_repeater(id: id, target: f.target || existing.target, request: request,
          http2: http2, auto_cl: f.auto_cl.nil? ? existing.auto_content_length? : f.auto_cl == true,
          sni: sni, ws_keep_key: existing.ws_keep_key?,
          ws_http_only: existing.ws_http_only?, tls_preset: existing.tls_preset)
        abort project_write_failure("#{cmd}: session ##{id} was NOT updated (it is unchanged)", project) unless written
        unless apply_repeater_metadata(store, id, f.name, f.tags)
          abort project_write_failure("#{cmd}: session ##{id}'s request was updated, but its name/tag metadata was NOT fully saved", project)
        end
        if unterminated_head?(request, ws_http_only: existing.ws_http_only?, http2: http2)
          STDERR.puts "#{cmd}: #{unterminated_head_note}"
        end
        unless format == :json
          puts "Repeater session ##{id} updated."
          return
        end
        rows = store.repeaters_mcp
        i = rows.index { |r| r.id == id } || abort_closing(store, "#{cmd}: session ##{id} was updated, but another gori deleted it before it could be read back")
        puts(JSON.build { |j| j.object { repeater_row_fields(j, rows[i], i + 1) } })
      end

      # `--curl PATH|-`: the one request the curl command describes (`Import::Curl.parse_one`),
      # its notes — the transport flags dropped, a path curl would have collapsed — on STDERR
      # beside the other create notices. A paste holding two requests, or a command that reads a
      # local file, is refused with the importer's own sentence.
      def self.curl_request(path : String, what : String) : Import::Curl::Request
        text = read_input_file(path, what, stdin: true, noun: "curl command", flag: "--curl -")
        req = begin
          Import::Curl.parse_one(text)
        rescue ex : Gori::Error
          abort "#{what}: --curl: #{ex.message}"
        end
        req.notes.each { |n| STDERR.puts "#{what}: note: #{n}" }
        req
      end

      # `repeater create --format json` (#1117): the row as `repeater list --format json` prints
      # it — READ BACK, because the list shape carries what the store made of the arguments (the
      # masked name, the tab number, the position the strip gave it) — plus the three facts only
      # the create knows. A script used to scrape the id out of "Repeater session #7 created
      # successfully.", which breaks on any rewording. `abort`s (the row committed a moment ago)
      # only if a peer deleted it before it could be read, which the object could not describe.
      private def self.repeater_created_json(store : Store, id : Int64, websocket : Bool,
                                             ws_messages : Int32, rewrote_request_line : Bool) : String
        rows = store.repeaters_mcp
        i = rows.index { |r| r.id == id }
        i || abort_closing(store, "gori run repeater create: session ##{id} was created, but another gori deleted it before it could be read back")
        JSON.build do |j|
          j.object do
            repeater_row_fields(j, rows[i], i + 1)
            j.field "websocket", websocket
            # How many frames were stored with it — the count MCP's `create_repeater` reports,
            # so a seeded WebSocket session's frames can be asserted rather than trusted.
            j.field "ws_messages", ws_messages if websocket
            # Only when it FIRED: a `--flow` seed's absolute-form line rewritten to origin-form
            # is persisted into the row, so this is the one record that it was ever there.
            j.field "request_line_rewritten", true if rewrote_request_line
          end
        end
      end

      # `abort`s with a uniform message when the Outbound gate refuses this request — a
      # one-line call at each send site so the branch lives here, not in the (already
      # complex) command handlers. `Repeater::Sender#send` re-checks internally, so a
      # missed call here still cannot put bytes on the wire; this exists only so the CLI
      # can refuse with its own message before printing anything.
      private def self.abort_if_blocked!(plan : Repeater::Plan, prefix : String) : Nil
        return unless reason = plan.refusal
        abort "#{prefix}: #{reason}"
      end

      # The Layer-1 (include-list) gate for the hand-authored repeater send paths. `abort_if_blocked!`
      # above (plan.refusal → Outbound#send_block) is Layer 2 (Sandbox/exclude) ONLY; without this the
      # configured project scope was silently inert for `gori run repeater` and there was no
      # --allow-unscoped waiver, unlike the sibling fuzz/mine/sequence/discover CLIs and MCP's
      # send_gate (#406). DESIGN.md §3 lists repeater as gated on BOTH layers.
      private def self.abort_if_out_of_scope!(outbound : Gori::Outbound, plan : Repeater::Plan, prefix : String) : Nil
        verdict = repeater_scope_verdict(outbound, plan)
        return unless verdict.blocked?
        outbound.close
        abort "#{prefix}: #{plan.host} is out of the project scope — " \
              "#{Gori::Outbound.remedy(verdict, "--allow-unscoped", waiver_passes_exclude: outbound.send_passes_exclude?)}"
      end

      # The Layer-1 verdict `abort_if_out_of_scope!` acts on, split out so it can be asserted
      # without the process-exiting `abort`. Returns the whole Verdict, not just `blocked?`,
      # because the REMEDY differs by why it was refused (an EXCLUDE match cannot be undone
      # by adding an include rule).
      #
      # Every request in the plan is asked, as Layer 2 already is: a race or timing group shares
      # one origin but not one path. The first blocked member's verdict wins, else the first's.
      private def self.repeater_scope_verdict(outbound : Gori::Outbound, plan : Repeater::Plan) : Gori::Outbound::Verdict
        requests = plan.scope_requests
        target = (bytes = requests.first?) ? Gori::Outbound.request_target(bytes) : "/"
        first = outbound.check_request(plan.scheme, plan.host, target, plan.port)
        return first if first.blocked?
        requests.each_with_index do |req, i|
          next if i == 0
          verdict = outbound.check_request(plan.scheme, plan.host, Gori::Outbound.request_target(req), plan.port)
          return verdict if verdict.blocked?
        end
        first
      end

      # A saved repeater SESSION row IS the option set: its target, http2 toggle, SNI and
      # auto-Content-Length switch, straight into the one builder every surface assembles
      # through. The builder classifies the request as a WebSocket upgrade too, so the
      # framed-exchange branch is taken off the SAME expanded bytes that go on the wire.
      #
      # PURE and separate from cmd_repeater_send so the row → options mapping is testable
      # without a store, an Outbound, or a socket. It is the half a spec that builds its own
      # `PlanOptions` cannot reach: dropping `auto_content_length: rec.auto_content_length?`
      # here silently overwrites a `repeater create --no-auto-cl` session's hand-set
      # Content-Length on every replay, and no `Plan`-level spec would notice.
      # `tls_preset` is the PER-SEND override of the session's stored fingerprint: nil keeps
      # what the tab was saved with (which is what makes a reopened session send the handshake
      # it sent before), and an explicit `--tls-preset=` (empty) clears it for this send only.
      private def self.session_plan_options(rec : Store::RepeaterRecord, insecure : Bool,
                                            overrides : Gori::HostOverrides?,
                                            verbatim : Bool = false,
                                            timeout : Time::Span? = nil,
                                            reframe_grpc : Bool = false,
                                            tls_preset : String? = nil,
                                            request : Bytes = rec.request,
                                            pinned_cl : Bool = false,
                                            sse : Repeater::StreamBound? = nil,
                                            evidence : Bool = false,
                                            evidence_literals : Set(String)? = nil) : Repeater::PlanOptions
        Repeater::PlanOptions.new([request],
          # `Repeater::DraftMarkers.evidence?`: an unedited flow seed is a capture, not a draft.
          # `evidence_literals` narrows that to the capture's own names, for a send that adds its own.
          evidence: evidence, evidence_literals: evidence_literals,
          reframe_grpc: reframe_grpc,
          default_target: rec.target, http2: rec.http2?, sni: rec.sni,
          timeout: timeout, sse: sse,
          expand_request: !verbatim,
          # The SEND-seam half of the same flag. `expand_request` stops the BUILDER's project
          # env var pass; a DECLARED session binding is deliberately deferred past the builder
          # (`Plan.expand_requests` says so) and was substituted anyway — so `--verbatim` on a
          # session whose stored request is `GET /api?$TOKEN=1` put `GET /api?SECRETTOKEN123=1`
          # on the wire under a flag whose help text is "no env expansion". Set here beside
          # its twin so the two cannot drift the way `verbatim` and `evidence` already did
          # between this file and MCP. See `PlanOptions#expand_bindings?`.
          expand_bindings: !verbatim,
          # …and on an h2 session it used to change NOTHING the encoder does: the flag
          # promised "the stored bytes EXACTLY" while `H2Engine` still lowercased every field
          # name. Field case is the one normalization left on that path, so this is what
          # `--verbatim` means for h2.
          preserve_field_case: verbatim,
          # `pinned_cl`: this send's own `-H 'Content-Length: N'`, honoured verbatim for
          # CL-mismatch testing exactly as a flow replay's `-H` is.
          auto_content_length: !verbatim && !pinned_cl && rec.auto_content_length?, verify: !insecure,
          overrides: overrides,
          tls_preset: tls_preset || rec.tls_preset)
      end

      # `gori run repeater`'s wording for a builder refusal. `Repeater::Plan` reports a
      # machine-readable `Reason` precisely so each surface can phrase it in its own idiom —
      # the CLI names its flags, where the TUI names its hotkeys and MCP names its JSON
      # fields. Exhaustive on `Reason` so a new builder failure cannot reach the operator as
      # a bare exception message.
      private def self.repeater_plan_abort(prefix : String, ex : Repeater::PlanError,
                                           context : String? = nil) : NoReturn
        abort repeater_plan_error(prefix, ex, context)
      end

      private def self.repeater_plan_error(prefix : String, ex : Repeater::PlanError,
                                           context : String? = nil) : String
        where = context ? " for #{context}" : ""
        detail = ex.detail
        case ex.reason
        in Repeater::PlanError::Reason::NoRequest
          "#{prefix}: the request is empty — nothing to send#{where}"
        in Repeater::PlanError::Reason::NoTarget
          # No flag named here: `repeater send` has no --target (only the single-flow replay
          # does), so a shared "pass --target=URL" would point at a flag that command rejects.
          "#{prefix}: no target#{where}"
        in Repeater::PlanError::Reason::BadTarget
          "#{prefix}: could not determine a target host#{where}#{detail ? " from #{detail.inspect}" : ""}"
        in Repeater::PlanError::Reason::UnsupportedScheme
          "#{prefix}: unsupported target scheme #{(detail || "").inspect} (use http:// or https://)"
        in Repeater::PlanError::Reason::UnresolvedEnv
          ex.mint_refusal.try { |note| "#{prefix}: #{note}#{where.empty? ? "" : " (#{where.strip})"} — set it with `gori run project env set KEY value` or as a global env var, or remove the token" } ||
            "#{prefix}: #{env_unresolved_error(detail, where)}"
        in Repeater::PlanError::Reason::TlsPreset
          "#{prefix}: #{ex.message}"
        end
      end

      # Persist a repeater SESSION's last response (V11) so it survives a reopen and a later
      # `repeater list` / `--diff` see it — parity with the TUI (repeater_controller.cr
      # #drain_results). Reopens the store because `send` closed it before the (slow) dial.
      # Callers gate on `result.ok?`: a failed resend must not wipe a good stored response.
      #
      # Answers nil when the row now holds the response, else the sentence that says why not.
      # Two things can go wrong in the window the dial opened, and they want different advice:
      # the project refused the write (busy, locked, unwritable — retry the WRITE, not the send),
      # or the session was deleted meanwhile (`gori run repeater delete`, the TUI closing the
      # tab, MCP `delete_repeater`) and there is nothing to write to. `update_repeater_response`
      # answers false for both, so this asks `repeater_exists?` to say which.
      private def self.persist_repeater_response(id : Int64, head : Bytes, body : Bytes?, error : String?,
                                                 duration_us : Int64, project : Project,
                                                 request_sha256 : String?) : String?
        store = begin
          open_store(project, abort_on_failure: false)
        rescue ex : Gori::Error | DB::Error | SQLite3::Exception
          # The accurate reason (`open_failure_message`), not the generic busy sentence: a
          # read-only file and a non-writable WAL directory reach here too, and "retry" is the
          # wrong advice for both.
          return "response was NOT saved: #{open_failure_message(ex, project)}"
        end
        begin
          return nil if store.update_repeater_response(id, head, body, error, duration_us, request_sha256: request_sha256)
          return "response was NOT saved: session ##{id} no longer exists (deleted by another gori while the send was in flight)" unless store.repeater_exists?(id)
          project_write_failure("response was NOT saved", project)
        rescue Gori::Error | DB::Error | SQLite3::Exception
          project_write_failure("response was NOT saved", project)
        ensure
          store.close
        end
      end

      # `gori run repeater send <repeater-id>` — replay a saved repeater SESSION (as
      # opposed to a bare id, which replays a History FLOW). Honors the session's
      # target / http2 / sni / auto_content_length toggle.
      # `gori run repeater race <id> <id> [<id>…]` — the headless multi-endpoint race (#1236).
      # Fires several saved sessions as one synchronized group: N distinct requests on the wire
      # in one narrow window (h1 last-byte-sync over N connections, h2 single-packet over one),
      # the primitive for a multi-endpoint TOCTOU. This is the FIRST multi-request path on the
      # headless surface — `send` is one session, `send-group` is TUI-only.
      #
      # Same origin, one transport: every session must resolve to one `scheme://host:port` and
      # share the h1/h2 setting (a mixed group is refused), because the h2 single-packet attack
      # is one connection = one host and the h1 form is held to the same shape for a legible
      # transcript. Cross-host h1 is a deliberate follow-up.
      private def self.cmd_repeater_race(args : Array(String)) : Nil
        proj = ProjectFlags.new
        insecure = false
        timeout : Time::Span? = nil
        allow_unscoped = false
        verbatim = false
        slot : String? = nil
        reframe_grpc = false
        tls_preset : String? = nil
        force_http2 : Bool? = nil
        max_requests : Int32? = nil
        max_body : Int32? = nil
        format = :text
        positional = [] of String

        parser = option_parser("gori run repeater race") do |p|
          p.banner = "Usage: gori run repeater race <id> <id> [<id>…] [options]\n\n" \
                     "Fire several saved repeater SESSIONS (ids from `gori run repeater list`) as ONE\n" \
                     "synchronized race — N distinct requests on the wire together to hit a\n" \
                     "multi-endpoint TOCTOU window. All sessions must share one origin and transport."
          project_options(p, proj, "read")
          p.on("-k", "--insecure-upstream", "Do not verify the upstream TLS certificate") { insecure = true }
          p.on("--timeout=SEC", "Per-operation connect + idle timeout (seconds)") { |v| timeout = parse_count(v, "--timeout").seconds }
          p.on("--http2", "Race over HTTP/2 (single-packet attack), overriding the sessions' stored setting") { force_http2 = agree(force_http2, true, "--http1/--http2") }
          p.on("--http1", "Race over HTTP/1.1 (last-byte sync), overriding the sessions' stored setting") { force_http2 = agree(force_http2, false, "--http1/--http2") }
          p.on("--allow-unscoped", "Send even if the target is outside the project scope (the Sandbox still applies)") { allow_unscoped = true }
          p.on("--verbatim", "Send the stored bytes EXACTLY: no token expansion, no Content-Length resync (see `repeater send --verbatim`)") { verbatim = true }
          p.on("--slot=NAME", "Send as this SESSION SLOT — its header overlay and $BIND table for every member") { |v| slot = v.strip }
          p.on("--reframe-grpc", "HTTP/2 only: recompute the gRPC length prefix over the body being sent") { reframe_grpc = true }
          p.on("--tls-preset=NAME", "#{TLS_PRESET_HELP}, overriding the sessions' stored one") { |v| tls_preset = v }
          p.on("--max-requests=N", "Refuse the race if it would exceed N members (a race is sent whole, never split)") { |v| max_requests = parse_count(v, "--max-requests") }
          p.on("--max-body=BYTES", "--format json: hold each member's decoded body to BYTES, as `repeater send --max-body` does (a race is not stored, so this is the only copy)") { |v| max_body = parse_count(v, "--max-body") }
          format_flag(p, [:text, :json], "Output: text (default) | json — each member adds its session id, head and body") { |f| format = f }
          p.unknown_args { |before, after| positional = before + after }
        end
        parser.parse(args)
        refresh_verify_upstream(!insecure)
        ids = race_member_ids(positional, max_requests, parser)
        cap = body_cap(false, max_body, "gori run repeater race")

        project = resolve_read_project(proj.name, proj.db)
        # The §…§ marker guard is asked inside `load_group_members`, with the store open
        # (`DraftMarkers.live?` may read the seed flow), exactly as `repeater send` asks it — the
        # race renders no markers, so a live one would put the literal § bytes on the wire;
        # `--verbatim` waives it, matching `repeater send`.
        loaded, host_overrides, mode, seeds = load_group_members(project, ids, verbatim, force_http2, "gori run repeater race")

        activate_slot(slot, "gori run repeater race")
        outbound = project_outbound(project, allow_unscoped)
        plan, labels = build_cli_race_plan(loaded, mode, outbound, insecure, host_overrides,
          verbatim, timeout, reframe_grpc, tls_preset, seeds)

        abort_if_out_of_scope!(outbound, plan, "gori run repeater race")
        abort_if_blocked!(plan, "gori run repeater race")

        results = plan.send_race
        outbound.close
        if format == :json
          puts race_json(ids, labels, results, plan, cap)
        else
          emit_race_text(labels, results, plan)
        end
        exit 1 unless results.any?(&.ok?)
      end

      private def self.cmd_repeater_timing(args : Array(String)) : Nil
        proj = ProjectFlags.new
        insecure = false
        timeout : Time::Span? = nil
        allow_unscoped = false
        verbatim = false
        slot : String? = nil
        reframe_grpc = false
        tls_preset : String? = nil
        force_http2 : Bool? = nil
        count = Repeater::Timing::Stats::DEFAULT_ITERATIONS
        warmup = Repeater::Timing::Stats::DEFAULT_WARMUP
        interleaved = false
        format = :text
        positional = [] of String

        parser = option_parser("gori run repeater timing") do |p|
          p.banner = "Usage: gori run repeater timing <idA> <idB> [options]\n\n" \
                     "Differential TIMING analysis of exactly TWO saved repeater sessions (A vs B):\n" \
                     "send the pair many times and decide which is CONSISTENTLY slower by response\n" \
                     "ORDER and quartiles, not eyeballed latency. Both must share one origin and\n" \
                     "transport. Each pair is released together (h2 single-packet / h1 last-byte-sync)\n" \
                     "unless --interleaved sends them sequentially."
          project_options(p, proj, "read")
          p.on("-k", "--insecure-upstream", "Do not verify the upstream TLS certificate") { insecure = true }
          p.on("--timeout=SEC", "Per-operation connect + idle timeout (seconds)") { |v| timeout = parse_count(v, "--timeout").seconds }
          p.on("--count=N", "How many A/B pairs to send after warm-up (1-#{Repeater::Timing::Stats::MAX_ITERATIONS}; default #{Repeater::Timing::Stats::DEFAULT_ITERATIONS})") { |v| count = parse_count(v, "--count") }
          p.on("--warmup=N", "Initial pairs discarded before measuring (default #{Repeater::Timing::Stats::DEFAULT_WARMUP})") { |v| warmup = parse_nonneg(v, "--warmup") }
          p.on("--interleaved", "Send A then B sequentially (alternating order) instead of the synchronized race") { interleaved = true }
          p.on("--http2", "Send over HTTP/2 (single-packet), overriding the sessions' stored setting") { force_http2 = agree(force_http2, true, "--http1/--http2") }
          p.on("--http1", "Send over HTTP/1.1 (last-byte sync), overriding the sessions' stored setting") { force_http2 = agree(force_http2, false, "--http1/--http2") }
          p.on("--allow-unscoped", "Send even if the target is outside the project scope (the Sandbox still applies)") { allow_unscoped = true }
          p.on("--verbatim", "Send the stored bytes EXACTLY: no token expansion, no Content-Length resync") { verbatim = true }
          p.on("--slot=NAME", "Send as this SESSION SLOT — its header overlay and $BIND table for both variants") { |v| slot = v.strip }
          p.on("--reframe-grpc", "HTTP/2 only: recompute the gRPC length prefix over the body being sent") { reframe_grpc = true }
          p.on("--tls-preset=NAME", "#{TLS_PRESET_HELP}, overriding the sessions' stored one") { |v| tls_preset = v }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
          p.unknown_args { |before, after| positional = before + after }
        end
        parser.parse(args)
        refresh_verify_upstream(!insecure)
        ids = timing_member_ids(positional, parser)
        count = count.clamp(1, Repeater::Timing::Stats::MAX_ITERATIONS)
        warmup = warmup.clamp(0, count - 1)

        project = resolve_read_project(proj.name, proj.db)
        loaded, host_overrides, mode, seeds = load_group_members(project, ids, verbatim, force_http2, "gori run repeater timing")

        activate_slot(slot, "gori run repeater timing")
        outbound = project_outbound(project, allow_unscoped)
        # Reuse the race's origin/transport unification — a differential pair rides one connection
        # shape too, so a mismatch is refused before any send.
        plan, labels = build_cli_race_plan(loaded, mode, outbound, insecure, host_overrides,
          verbatim, timeout, reframe_grpc, tls_preset, seeds, cmd_label: "gori run repeater timing")

        abort_if_out_of_scope!(outbound, plan, "gori run repeater timing")
        abort_if_blocked!(plan, "gori run repeater timing")

        run_mode = interleaved ? Repeater::Timing::Mode::Interleaved : Repeater::Timing::Mode::Auto
        rep = Repeater::Timing.run(plan, iterations: count, mode: run_mode, warmup: warmup)
        outbound.close
        transport = interleaved ? "interleaved" : (plan.http2? ? "single-packet h2" : "last-byte-sync h1")
        subject = Repeater::Timing::Present::Subject.new(
          a_label: labels[0]? || "A", b_label: labels[1]? || "B",
          origin: "#{plan.scheme}://#{plan.host}:#{plan.port}", transport: transport,
          mode: run_mode.to_s.underscore)
        if format == :json
          STDOUT.puts Repeater::Timing::Present.report_json(rep, subject)
        else
          STDOUT.print Repeater::Timing::Present.report_text(rep, subject)
        end
        # A run that never got a single usable pair (every send errored) is a failure, like a race
        # with no ok result.
        exit 1 if rep.pairs_valid == 0
      end

      # Timing analysis compares EXACTLY two variants (a differential oracle, not an N-way race).
      private def self.timing_member_ids(positional : Array(String), parser : OptionParser) : Array(Int64)
        unless positional.size == 2
          abort "gori run repeater timing: needs exactly two <repeater-id>s — timing analysis compares a pair (A vs B)\n#{parser}"
        end
        positional.map { |s| s.to_i64? || abort("gori run repeater timing: invalid repeater id '#{s}'") }
      end

      # Load a race or timing group (read-only), refusing a live §…§ marker unless verbatim, and
      # resolve the shared transport (forced by --http1/--http2, else the sessions' agreed setting).
      # Aborts, closing the store, on a missing session or a mixed-transport group; `cmd` prefixes
      # every message. `seeds` is the members still holding their flow seed's bytes (#1670).
      private def self.load_group_members(project, ids : Array(Int64), verbatim : Bool,
                                          force_http2 : Bool?, cmd : String) : {Array({Int64, Store::RepeaterRecord}), Gori::HostOverrides?, Bool, Set(Int64)}
        store = open_store(project, read_only: true)
        seeds = Set(Int64).new
        # `abort` inside the block still runs the `ensure` (the store closes), and it narrows
        # each row to a non-nil record.
        loaded, host_overrides = begin
          rows = ids.map do |id|
            rec = store.get_repeater_full(id)
            abort "#{cmd}: no repeater session ##{id}" unless rec
            if !verbatim && Repeater::DraftMarkers.live?(store, rec)
              abort "#{cmd}: #{Repeater::DraftMarkers.refusal(id, MARKER_REMEDY)}"
            end
            seeds << id if Repeater::DraftMarkers.evidence?(store, rec)
            {id, rec}
          end
          {rows, Gori::HostOverrides.load(store)}
        ensure
          store.close
        end

        mode = force_http2
        if mode.nil?
          modes = loaded.map { |(_, rec)| rec.http2? }.uniq!
          abort "#{cmd}: the sessions mix HTTP/1.1 and HTTP/2 — pass --http1 or --http2 to force one" if modes.size > 1
          mode = modes.first
        end
        {loaded, host_overrides, mode, seeds}
      end

      # The validated race member ids: at least two integers, within `--max-requests` and the
      # race ceiling. A race is sent whole (never split), so a group over a cap is refused here,
      # before any dial.
      private def self.race_member_ids(positional : Array(String), max_requests : Int32?,
                                       parser : OptionParser) : Array(Int64)
        if positional.size < 2
          abort "gori run repeater race: needs at least two <repeater-id>s (a race of one proves nothing)\n#{parser}"
        end
        ids = positional.map { |s| s.to_i64? || abort("gori run repeater race: invalid repeater id '#{s}'") }
        if (cap = max_requests) && ids.size > cap
          abort "gori run repeater race: #{ids.size} members exceeds --max-requests=#{cap} (a race is sent whole, never split)"
        end
        if ids.size > Repeater::MAX_RACE_MEMBERS
          abort "gori run repeater race: #{ids.size} members exceeds the #{Repeater::MAX_RACE_MEMBERS}-member ceiling"
        end
        ids
      end

      # Resolve every race member's origin (each via its own single-request plan, which also
      # validates its target / env), assert one origin across the group, and build ONE plan over
      # every member's request from the first session's send context. Aborts (closing `outbound`)
      # on a per-member builder refusal or a cross-origin group.
      # `cmd_label`'s refusal for a race or timing group mixing untouched seeds (`seeds`) and drafts,
      # or nil: one plan, one provenance (#1670, `DraftMarkers.mixed_group_refusal`).
      def self.race_provenance_refusal(loaded : Array({Int64, Store::RepeaterRecord}), seeds : Set(Int64),
                                       verbatim : Bool, cmd_label : String) : String?
        captured = loaded.map { |(id, _)| seeds.includes?(id) }
        what = cmd_label.ends_with?("timing") ? "a timing run" : "a race"
        Repeater::DraftMarkers.mixed_group_refusal(captured, verbatim, what).try { |why| "#{cmd_label}: #{why}" }
      end

      private def self.build_cli_race_plan(loaded : Array({Int64, Store::RepeaterRecord}), mode : Bool,
                                           outbound : Gori::Outbound, insecure : Bool,
                                           host_overrides : Gori::HostOverrides?, verbatim : Bool,
                                           timeout : Time::Span?, reframe_grpc : Bool,
                                           tls_preset : String?, seeds : Set(Int64),
                                           cmd_label : String = "gori run repeater race") : {Repeater::Plan, Array(String)}
        # The dial SIGNATURE every member must share: the group rides ONE Sender built from the
        # anchor, so a member whose origin, effective Content-Length policy, SNI or TLS preset
        # differs would be silently sent under the anchor's — refuse instead of flattening it.
        # The signature uses the EFFECTIVE values (the flags fold in: `--tls-preset` / `--verbatim`
        # make those columns uniform), so it only fires on a real stored difference.
        sigs = [] of {String, String, Int32, Bool, String?, String?}
        wires = [] of Bytes
        labels = [] of String
        loaded.each do |(id, rec)|
          probe = begin
            Repeater::Plan.build(session_plan_options(rec, insecure, host_overrides, verbatim, timeout,
              reframe_grpc, tls_preset, evidence: seeds.includes?(id)), outbound)
          rescue ex : Repeater::PlanError
            outbound.close
            repeater_plan_abort(cmd_label, ex, "session ##{id}")
          end
          sigs << {probe.scheme, probe.host, probe.port, !verbatim && rec.auto_content_length?,
                   rec.sni, tls_preset || rec.tls_preset}
          wires << rec.request
          labels << "##{id} #{race_request_line(rec.request)}"
        end
        first = sigs.first
        unless sigs.all? { |s| s == first }
          outbound.close
          abort "#{cmd_label}: the sessions differ in origin, Content-Length policy, SNI or " \
                "TLS preset — a race rides one connection shape (origins: " \
                "#{sigs.map { |(s, h, po, _, _, _)| "#{s}://#{h}:#{po}" }.uniq!.join(", ")})"
        end

        if why = race_provenance_refusal(loaded, seeds, verbatim, cmd_label)
          outbound.close
          abort why
        end
        anchor = loaded.first[1]
        plan = begin
          Repeater::Plan.build(Repeater::PlanOptions.new(wires,
            evidence: loaded.all? { |(id, _)| seeds.includes?(id) },
            reframe_grpc: reframe_grpc, default_target: anchor.target, http2: mode, sni: anchor.sni,
            timeout: timeout, expand_request: !verbatim, expand_bindings: !verbatim,
            preserve_field_case: verbatim, auto_content_length: !verbatim && anchor.auto_content_length?,
            verify: !insecure, overrides: host_overrides, tls_preset: tls_preset || anchor.tls_preset), outbound)
        rescue ex : Repeater::PlanError
          outbound.close
          repeater_plan_abort(cmd_label, ex)
        end
        {plan, labels}
      end

      # The request line (first line) of a member's stored request, for the race transcript.
      #
      # A display label, made printable once here for every writer that shows it: scrubbed (a
      # stored request line need not be UTF-8, and the JSON form printed the raw byte) and
      # term_safe (the text form printed control bytes straight to the terminal).
      private def self.race_request_line(request : Bytes) : String
        line = String.new(request[0, {request.size, 200}.min]).scrub.lines.first?.try(&.strip)
        line && !line.empty? ? Output.term_safe(line) : "(no request line)"
      end

      # One race's per-member results — status, size and RELEASE-RELATIVE timing (each member's
      # duration is measured from the synchronized release, so the spread is the arrival order),
      # plus MCP `race_requests`' neutral `responded` / `won_2xx` tally. Each member carries its
      # session `id`, `head` and `body` (#1678): in a limit-overrun race every side usually
      # answers 200, so the body is the only evidence of which request won — and a race is not
      # stored, so this object is the only copy. `head`/`body` take `repeater send`'s shapes.
      def self.race_json(ids : Array(Int64), labels : Array(String), results : Array(Repeater::Result),
                         plan : Repeater::Plan, cap : BodyCap = BodyCap.new) : String
        JSON.build do |j|
          j.object do
            j.field "target", "#{plan.scheme}://#{plan.host}:#{plan.port}"
            j.field "transport", plan.http2? ? "single-packet h2" : "last-byte-sync h1"
            j.field "responded", results.count(&.ok?)
            j.field "won_2xx", race_won_2xx(results)
            j.field "members" do
              j.array do
                labels.each_with_index do |label, i|
                  r = results[i]?
                  j.object do
                    j.field "id", ids[i]
                    j.field "label", label
                    j.field "ok", r.try(&.ok?) || false
                    j.field "status", r.try(&.response.try(&.status))
                    j.field "size", r.try { |x| (x.head.size + (x.body.try(&.size) || 0)) }
                    j.field "duration_us", r.try(&.duration_us)
                    j.field "incomplete", r.try(&.incomplete?) || false
                    j.field "error", r.try(&.error)
                    if r
                      j.field "head", scrub(r.head)
                      unless String.new(r.head).valid_encoding?
                        j.field "head_lossy", true
                        j.field "head_base64", Base64.strict_encode(r.head)
                      end
                      emit_body_json(j, "body", r.head, r.body, r.incomplete?, cap)
                    end
                  end
                end
              end
            end
          end
        end
      end

      # How many members answered 2xx — a count, not a verdict: whether N distinct 2xx is a
      # finding is the operator's call (a multi-endpoint race where each endpoint SHOULD answer
      # 2xx is the normal case).
      private def self.race_won_2xx(results : Array(Repeater::Result)) : Int32
        results.count { |r| r.ok? && (s = r.response.try(&.status)) && 200 <= s < 300 }
      end

      private def self.emit_race_text(labels : Array(String), results : Array(Repeater::Result),
                                      plan : Repeater::Plan) : Nil
        transport = plan.http2? ? "single-packet h2" : "last-byte-sync h1"
        ok2xx = race_won_2xx(results)
        puts "race → #{plan.scheme}://#{plan.host}:#{plan.port} · #{results.size} requests together (#{transport})"
        labels.each_with_index { |label, i| puts race_member_line(label, results[i]?) }
        puts "→ #{results.count(&.ok?)}/#{results.size} responded · #{ok2xx}×2xx"
      end

      # One member's line(s) in the text transcript: its label, then its status/size/timing or its
      # error (a member that never produced a result at all reads "(no result)").
      private def self.race_member_line(label : String, r : Repeater::Result?) : String
        return "  #{label}\n    (no result)" unless r
        if err = r.error
          head = r.head.empty? ? "" : "HTTP #{r.response.try(&.status)} · "
          "  #{label}\n    ✗ #{head}#{err}"
        else
          size = CLI::Output.human_size((r.head.size + (r.body.try(&.size) || 0)).to_i64)
          "  #{label}\n    HTTP #{r.response.try(&.status)} · #{size} · #{CLI::Output.human_us(r.duration_us)}#{r.incomplete? ? " ⚠ incomplete" : ""}"
        end
      end

      private def self.cmd_repeater_send(args : Array(String)) : Nil
        proj = ProjectFlags.new
        insecure = false
        do_diff = false
        format = :text
        timeout : Time::Span? = nil
        sse = SseFlags.new
        # `--message` and `--message-frame` share ONE list so their relative ORDER is the send
        # order. A WebSocket exchange is a sequence, and two lists merged afterwards would
        # silently reorder a fragment ahead of the CONT that finishes it.
        ws_messages = [] of Store::WsOutMessage
        idle_ms : Int64? = nil
        allow_unscoped = false
        verbatim = false
        slot : String? = nil
        reframe_grpc = false
        ws_keep_key = false
        record_history = false
        tls_preset : String? = nil
        # nil = use the session's stored setting; true = this send is plain HTTP whatever it says.
        # There is no `--websocket` counterpart: the stored default IS WebSocket unless the
        # operator turned it off, so the only direction that needs a per-send override is this one.
        http_only : Bool? = nil
        path_override : String? = nil
        headers = [] of String
        cookies = [] of String
        grpc_fields = [] of String
        apply_rules = false
        headers_only = false
        max_body : Int32? = nil
        positional = [] of String

        parser = option_parser("gori run repeater send") do |p|
          p.banner = "Usage: gori run repeater send <repeater-id> [options]\n\n" \
                     "Replay a saved repeater SESSION (ids from `gori run repeater list`).\n" \
                     "A WebSocket-upgrade session performs a real RFC 6455 framed exchange."
          project_options(p, proj, "read")
          p.on("-k", "--insecure-upstream", "Do not verify the upstream TLS certificate") { insecure = true }
          p.on("--timeout=SEC", "Per-operation connect + idle timeout (seconds). Ignored on the WebSocket path, which paces itself with --idle-ms") { |v| timeout = parse_count(v, "--timeout").seconds }
          sse_options(p, sse, Repeater::StreamBound::SEND)
          p.on("--diff", "Diff the new response against the session's last stored response") { do_diff = true }
          p.on("--allow-unscoped", "Send even if the target is outside the project scope (the Sandbox still applies)") { allow_unscoped = true }
          p.on("--verbatim", "Send the stored bytes EXACTLY: no token expansion (project env vars, session bindings, or generators — a $ENV.KEY, $BIND.NAME, or $GEN.UUID token stays literal on the wire; bare syntax: $KEY / $NAME), no bare-LF→CRLF promotion, no Content-Length resync, no HTTP/2→1.1 version fix, and on h2 no field-name lowercasing. Nothing interprets the token grammar, so an escape ($$ENV.KEY, or $$name in bare syntax) is not consumed either — write the literal token itself. A token the APP owns ($where, $filter, $IFS) needs this flag only under the bare syntax; namespaced, nothing but $ENV./$BIND./$GEN. is a reference. The active --slot's header overlay still applies: it answers a different question (send this AS WHOM) — pass no --slot to send the stored headers. It also waives the §…§ refusal: a stored § stays literal instead of being refused as an unrendered marker") { verbatim = true }
          p.on("--slot=NAME", "Send as this SESSION SLOT — its header overlay, and its binding table for $BIND.NAME tokens (bare syntax: $NAME)") { |v| slot = v.strip }
          # Opt-in, and off even under --verbatim's opposite: a stale prefix is the operator's
          # bytes by default (P7). See `Repeater::PlanOptions#reframe_grpc?`.
          p.on("--reframe-grpc", "HTTP/2 only: recompute the gRPC 5-byte length prefix over the body actually being sent, for a message an edit changed the length of (default: send it as written)") { reframe_grpc = true }
          p.on("--message=TEXT", "WebSocket: outbound text message (repeatable; replaces the session's stored messages)") { |v| ws_messages << Store::WsOutMessage.text(v) }
          p.on("--message-frame=SPEC", "WebSocket: one outbound frame with an explicit shape (repeatable; mixes with --message in order). SPEC is comma-separated key=value: opcode=text|bin|cont|close|ping|pong|<0-15>, fin=0|1, rsv=0-7, mask=0|1, mask_key=<hex>, len=<declared length>, and one of hex=|b64=|text= (text= runs to the end of SPEC). Example: opcode=close,hex=03ea6279650a") { |v| ws_messages << parse_message_frame(v) }
          p.on("--ws-keep-key", "WebSocket: send the request's own Sec-WebSocket-Key instead of a fresh one (overrides the session's stored setting for this send)") { ws_keep_key = true }
          p.on("--idle-ms=N", "WebSocket: server-silence timeout after the first inbound frame (100-60000, default 3000)") { |v| idle_ms = parse_count(v, "--idle-ms").to_i64 }
          p.on("--http", "WebSocket: send the handshake as an ordinary HTTP request and print the response, instead of performing the framed exchange (overrides the session's stored setting for this send). The bytes are unchanged — this selects the engine, not a rewrite") { http_only = true }
          p.on("--record-history", "Also write the outbound request + response to History as a captured flow, and print its flow id (default: off — a Repeater send leaves no flow). HTTP only") { record_history = true }
          p.on("--tls-preset=NAME", "#{TLS_PRESET_HELP}, overriding the session's stored one for this send") { |v| tls_preset = v }
          p.on("--path=TARGET", PATH_OVERRIDE_HELP) { |v| path_override = v }
          p.on("-HHEADER", "--header=HEADER", "Overwrite/add a header for THIS send (repeat a name for duplicate lines); the session keeps its own. $ENV.KEY tokens expand with the rest of the request (see --verbatim)") { |v| headers << v }
          p.on("-bCOOKIE", "--cookie=COOKIE", "Cookie 'name=value' for THIS send (curl's -b), replacing the stored Cookie header; repeat to join them into one. A value with no '=' is refused") { |v| cookies << v }
          p.on("--grpc-field PATH=VALUE", "gRPC: set or ADD a field on the session's unary message for THIS send (repeatable, applied in order). PATH is declared names with a loaded .proto (profile.role=ADMIN) or field numbers (4.1=30); an undeclared field the message lacks names its type (7:varint=1 — #{Protobuf::Edit::TYPE_HINT}). -PATH alone removes every occurrence (-profile.role, -7). Re-compressed and reframed") { |v| grpc_fields << v }
          p.on("--apply-rules", APPLY_RULES_HELP) { apply_rules = true }
          p.on("--headers-only", HEADERS_ONLY_HELP) { headers_only = true }
          p.on("--max-body=BYTES", MAX_BODY_HELP) { |v| max_body = parse_count(v, "--max-body") }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
          p.unknown_args { |before, after| positional = before + after }
        end
        parser.parse(args)
        refresh_verify_upstream(!insecure)
        abort "gori run repeater send: missing <repeater-id>\n#{parser}" if positional.empty?
        abort "gori run repeater send: too many arguments (expected one <repeater-id>, got: #{positional.join(" ")})" if positional.size > 1
        id = positional[0].to_i64? || abort "gori run repeater send: invalid repeater id '#{positional[0]}'"
        cap = body_cap(headers_only, max_body, "gori run repeater send")
        if err = output_diff_error(cap, do_diff)
          abort "gori run repeater send: #{err}"
        end
        if err = path_override_error(path_override)
          abort "gori run repeater send: #{err}"
        end
        # The flags that make THIS send differ from the stored session, so its answer is not
        # written back over the row's (see the persist below).
        per_send_edits = [] of String
        per_send_edits << "--path" if path_override
        per_send_edits << "-H/--header" unless headers.empty?
        per_send_edits << "-b/--cookie" unless cookies.empty?
        cookie = cookie_header_value(cookies, headers)
        abort "gori run repeater send: #{cookie.message}" if cookie.is_a?(SendArgError)
        headers += ["Cookie: #{cookie}"] if cookie

        # Resolved ONCE and reused by the response persist / History record after the send —
        # `resolve_read_project` with no --project/--db falls through to the project sorted
        # first by `Project#last_modified` (the newer of the db and its WAL mtime), so the
        # "most-recently-active" project can change identity WHILE a peer captures, and a send
        # is up to `--timeout` seconds long. Re-resolving at persist time therefore steered
        # `update_repeater_response` (and a `--record-history` flow) into a DIFFERENT project's
        # `repeaters` row #id. `cmd_repeater_minimize` resolves once for exactly this reason.
        project = resolve_read_project(proj.name, proj.db)
        # get_repeater_full loads the response BLOBs too (needed for --diff), so the
        # store can close before the send — same lifetime pattern as the flow path.
        store = open_store(project, read_only: true)
        # `markers_live` is read HERE, with the store still open: the predicate may have to
        # read the session's source flow (`DraftMarkers.operator_marked?`), and this store is
        # closed before the send like the flow path's. It is asked of the request THIS send
        # carries — the `--path` copy when there is one (it edits a COPY for this send; the row
        # keeps its own, see `FlowRequest.replace_request_target`) — so a `§id§` in the stored
        # target that `--path` replaced does not refuse a send that no longer carries it.
        rec, host_overrides, markers_live, request, seed_evidence = begin
          r = store.get_repeater_full(id)
          sent = begin
            r ? session_send_request(store, r, path_override, headers, grpc_fields, verbatim) : {nil, false, false}
          rescue ex : Repeater::PlanError
            repeater_plan_abort("gori run repeater send", ex, "session ##{id}")
          end
          abort "gori run repeater send: --grpc-field #{sent}" if sent.is_a?(String)
          req, pinned_cl, evidence = sent
          {r, Gori::HostOverrides.load(store), r && req ? Repeater::DraftMarkers.live?(store, r, req) : false, req, evidence}
        ensure
          store.close
        end
        abort "gori run repeater send: no repeater session ##{id}" unless rec
        unless request
          abort "gori run repeater send: session ##{id}'s stored request has no request line target to " \
                "replace (#{request_line_preview(rec.request)}) — edit the session instead"
        end
        per_send_edits << "--grpc-field" unless grpc_fields.empty?
        # After `open_store` (which installs `Env.layer`) and before the plan: `Repeater::Sender`
        # reads the active slot at the seam, so this has to be set before anything builds bytes.
        activate_slot(slot, "gori run repeater send")
        # The scope decision every active send passes through. `gori run repeater` dials
        # Repeater::Engine/H2Engine/WsEngine directly, bypassing the proxy's own gate, so
        # Sandbox mode's "blocks ALL out-of-scope traffic" promise lives here.
        outbound = project_outbound(project, allow_unscoped)

        plan = begin
          Repeater::Plan.build(session_plan_options(rec, insecure, host_overrides, verbatim, timeout, reframe_grpc,
            tls_preset, request: request, pinned_cl: pinned_cl, sse: sse.bound(Repeater::StreamBound::SEND),
            evidence: seed_evidence, evidence_literals: seed_send_literals(rec, seed_evidence)), outbound)
        rescue ex : Repeater::PlanError
          repeater_plan_abort("gori run repeater send", ex, "session ##{id}")
        end
        # Before the gate and the History write — see `gori run send`. A WebSocket exchange's
        # handshake is rewritten too: it is the one request the session sends.
        applied_rules = false
        plan, applied_rules = apply_request_rules(plan, project) if apply_rules
        # A request the rules rewrote is not the stored one, so its answer is not written back
        # over the row either — the same rule as `--path` / `-H` / `-b`.
        per_send_edits << "--apply-rules" if applied_rules

        # Layer 1 (include list) BEFORE Layer 2 — mirrors fuzz/mine/sequence and MCP send_gate.
        abort_if_out_of_scope!(outbound, plan, "gori run repeater send")

        # The session's stored `ws_http_only` (the TUI's `^V`) is the default, and `--http`
        # overrides it for this send. Both mean the same thing: dial the h1/h2 engine and read
        # the 101 as a response. `Engine` already treats 101 as terminal and bodyless, and
        # `ConnPool` already refuses to park an upgraded socket, so nothing else has to change.
        use_ws = plan.websocket? && !(http_only.nil? ? rec.ws_http_only? : http_only)
        if !use_ws && (!ws_messages.empty? || idle_ms)
          outbound.close
          abort "gori run repeater send: --message / --message-frame / --idle-ms apply to a WebSocket exchange — session ##{id} is being sent as HTTP"
        end
        # …and the other direction: a framed exchange prints a TRANSCRIPT, not a response body.
        if use_ws && do_diff
          outbound.close
          abort "gori run repeater send: --diff applies to an HTTP response — session ##{id} is a " \
                "WebSocket exchange (pass --http to send its handshake as an ordinary request)"
        end
        if use_ws && !cap.whole?
          outbound.close
          abort "gori run repeater send: #{cap.flag} applies to an HTTP response — session ##{id} is a " \
                "WebSocket exchange (pass --http to send its handshake as an ordinary request)"
        end
        # The HTTP path only, and AFTER `use_ws` for that reason: a framed WS exchange takes
        # `--message` markers as a documented sweep input (a different contract), while a
        # handshake sent as HTTP (`--http` / the stored `ws_http_only`) goes out through this
        # engine and diverges from the tab exactly like any other request would.
        #
        # `--verbatim` WAIVES it, and is named in the refusal. Not a hole: the one population
        # this gate can be wrong about is a session whose `§` really is data and that gori
        # cannot see a capture behind (`repeater create --request-raw` over a German legal
        # body — the module's own example), and `--verbatim` is already the spelling for "these
        # stored bytes ARE the message". Without it the refusal is a one-way door for that
        # request: removing the § destroys the payload under test and the Fuzzer route rewrites
        # it into sweep positions. With it the divergence is still never SILENT, which is the
        # whole complaint. See `Repeater::DraftMarkers`.
        if !use_ws && markers_live && !verbatim
          outbound.close
          abort "gori run repeater send: #{Repeater::DraftMarkers.refusal(id, MARKER_REMEDY)}"
        end
        if use_ws
          # `--record-history` records an HTTP request+response flow; a WebSocket send is a
          # framed transcript, a different shape History does not take from a repeater send yet.
          STDERR.puts "gori run repeater send: --record-history is HTTP-only — session ##{id} is a WebSocket exchange, not recorded" if record_history
          # `rec.flow_id` IS the provenance test, the same one the engine tabs and the h1
          # flow-replay path make: only a `--flow` / MCP `flow_id` seed sets it, and only a
          # seed puts CAPTURED frames in `ws_messages`. A session built from `--request-raw`
          # or MCP `ws_out_messages` leaves it nil and its rows stay the operator's draft.
          cmd_repeater_send_ws(id, plan, project, idle_ms, ws_messages, outbound, format,
            verbatim, ws_keep_key || rec.ws_keep_key?, !rec.flow_id.nil?,
            Evidence.request_digest(rec.request), persist: per_send_edits.empty?)
          report_per_send_edit_unsaved(id, rec.request, per_send_edits, "gori run repeater send")
          return
        end

        abort_if_blocked!(plan, "gori run repeater send")
        sent_at = Time.utc.to_unix_ms * 1000_i64
        # The bytes the socket gets, taken ONCE and sent as-is: `--record-history` writes this
        # exact slice, so the recorded flow is the request that went out — session-slot overlay
        # and send-seam `$NAME` values included — rather than the draft the seam started from.
        budget = plan.admit # the budget's slot before the mint, so a rate wait cannot age a `$GEN` value
        wire = budget_wire(plan, budget)
        # On the WIRE, not on `rec.request`: the notice must describe the bytes that go out,
        # so a session whose terminator arrives with a `$ENV.X` expansion is not accused, and
        # one stored terminated but truncated by an expansion is. BEFORE the send, so it is
        # on screen ahead of whatever the origin answers — the whole complaint in #1075 is
        # that an opaque `400` was the only thing that ever mentioned this.
        # `!plan.http2?` for the reason `unterminated_head?` gives at length: an h2 send
        # re-encodes this text as an HPACK field list and never puts a head terminator on the
        # wire, so the note would describe bytes the socket does not see.
        if !plan.http2? && !Env.head_terminated?(wire)
          STDERR.puts "gori run repeater send: #{unterminated_head_note}"
        end
        result = budget ? Repeater::Engine.error(budget, Time.instant) : plan.send_wire(wire, admitted: true)
        outbound.close

        new_body, _ = decode_body(result.head, result.body)
        diff = nil.as(Array(Repeater::DiffLine)?)
        diff_capped = false
        if do_diff && rec.response_head.nil?
          STDERR.puts "gori run repeater send: --diff: session ##{id} has no stored response to compare against yet"
        end
        if do_diff && (base_head = rec.response_head)
          # `--headers-only --diff` compares the two HEADS: status and headers, no body lines.
          orig = message_lines(base_head, cap.omit ? nil : display_body(base_head, rec.response_body))
          fresh = message_lines(result.head, cap.omit ? nil : new_body)
          diff_capped = Repeater::Diff.truncated?(orig, fresh)
          diff = Repeater::Diff.lines(orig, fresh)
        end
        # BOTH writes BEFORE the emit, so their outcome can go INSIDE the one result object
        # `--format json` has always printed (`WriteOutcome`). Printing a second top-level
        # object after it broke every consumer doing `… --format json | jq .status` (trailing
        # content), and in text mode appended a bare integer line to the response dump.
        #
        # History is recorded regardless of ok?: an error flow is evidence too (and matches MCP
        # send_request, which records the attempt).
        recorded_flow_id = nil.as(Int64?)
        history_write = nil.as(WriteOutcome?)
        if record_history && !budget # a send the budget refused never left gori (see `gori run send`)
          case recorded = record_repeater_send_to_history(plan, wire, result, sent_at, id, project)
          in Int64  then recorded_flow_id = recorded; history_write = WriteOutcome.new(nil)
          in String then history_write = WriteOutcome.new(recorded)
          end
        end
        # The digest of the request that produced this response (Schema V28). `rec.request` is
        # the SAVED row — this command sends what the row holds and never writes it back, so
        # the row's request at the moment of this write is still exactly these bytes. The
        # wire may differ (`--set`, `$NAME` expansion, the slot overlay) and deliberately does
        # not count: the drift check compares the ROW's request, not what went out.
        # Only on ok?: a failed resend must not wipe a good stored response.
        #
        # NOT under `--path`: the row's request still names its own target, so storing another
        # target's answer beside it would show the TUI tab a response to a request it does not
        # hold — and make the next `send --diff` compare against the wrong endpoint.
        response_write = nil.as(WriteOutcome?)
        if result.ok? && per_send_edits.empty?
          response_write = WriteOutcome.new(persist_repeater_response(id, result.head, result.body, result.error,
            result.duration_us, project, Evidence.request_digest(rec.request)))
        end
        emit_repeater_result(result, new_body, diff, format, diff_capped, recorded_flow_id,
          tls_preset: sent_tls_preset(plan), response_write: response_write, history_write: history_write,
          cap: cap, request_target: path_override && Gori::Outbound.request_target(wire),
          prefix: "gori run repeater send", applied_rules: applied_rules)
        report_per_send_edit_unsaved(id, rec.request, per_send_edits, "gori run repeater send") if result.ok?
        # The STDERR half of the same two answers, in both formats: a human at a terminal reads
        # this line, and a script's pipe still carries the JSON field.
        if (hw = history_write) && (why = hw.error)
          STDERR.puts "gori run repeater send: #{why}#{project_write_warning_tail}"
        end
        if (rw = response_write) && (why = rw.error)
          STDERR.puts "gori run repeater send: #{why}#{project_write_warning_tail}"
        end
        # The session slot's `$NAME` that went out LITERALLY, after the response and before the
        # exit code. A Repeater send under a slot is how an operator MINTS a binding, so this is
        # also the surface that has to say when the mint never happened: the origin answers 401
        # to a header carrying the reference itself, and that reads as a session that was sent
        # and rejected. See `Run.unbound_overlay_note`.
        report_unbound_slot_overlay("gori run repeater send")
        exit 1 unless result.ok?
      end

      # Write one repeater HTTP send to History and return the new flow id — the CLI half of
      # #749's opt-in punch-through. Re-opens the store (closed before the send, like
      # `persist_repeater_response`). A write failure is the sentence that says so, not an
      # abort: the send already happened, so aborting here would misreport a completed send as
      # a failure. The caller puts the id AND the failure on the OUTPUT (`recorded_flow_id` /
      # `history_saved` in JSON, a STDERR note in text) rather than this method printing — a
      # `recorded_flow_id: null` alone was indistinguishable from `--record-history` not passed.
      # `session_id` is nil for `gori run send`, which has no session for the row to point back at.
      private def self.record_repeater_send_to_history(plan : Repeater::Plan, wire : Bytes,
                                                       result : Repeater::Result,
                                                       created_at : Int64, session_id : Int64?,
                                                       project : Project) : Int64 | String
        store = begin
          open_store(project, abort_on_failure: false)
        rescue ex : Gori::Error | DB::Error | SQLite3::Exception
          return "History was NOT saved: #{open_failure_message(ex, project)}"
        end
        begin
          Repeater::HistoryRecord.record(store, plan, result, created_at, wire,
            surface: Gori::FlowSource::Surface::Cli, source_ref: session_id.try(&.to_s))
        rescue Gori::Error | DB::Error | SQLite3::Exception
          project_write_failure("History was NOT saved", project)
        ensure
          store.close
        end
      end

      # Execute a WebSocket repeater SESSION: a fresh RFC 6455 handshake, the
      # session's outbound messages (or `--message` overrides), and the inbound
      # transcript. Mirrors MCP send_websocket (src/gori/mcp/tools/send.cr) so a
      # script gets the same exchange whether it drives gori via CLI or MCP.
      private def self.cmd_repeater_send_ws(id : Int64, plan : Repeater::Plan, project : Project,
                                            idle_ms : Int64?,
                                            message_override : Array(Store::WsOutMessage),
                                            outbound : Gori::Outbound, format : Symbol,
                                            verbatim : Bool, keep_key : Bool,
                                            evidence : Bool = false,
                                            request_sha256 : String? = nil,
                                            persist : Bool = true) : Nil
        abort_if_blocked!(plan, "gori run repeater send")

        out_messages = begin
          with_store(project, read_only: true) do |store|
            ws_out_messages(store, id, message_override, verbatim, evidence)
          end
        rescue ex : Repeater::PlanError
          repeater_plan_abort("gori run repeater send", ex, "session ##{id}'s messages")
        end

        idle = (idle_ms || 3000_i64).clamp(100_i64, 60_000_i64).milliseconds
        result = plan.send_ws(out_messages, idle, keep_key)
        outbound.close

        # Persist ONLY when the ORIGIN ANSWERED — parity with the TUI
        # (repeater_controller#drain_results) and MCP `send_websocket`: a failed re-send must
        # not wipe a good stored handshake, and `ok?` alone was the other half of that mistake
        # (a 403/426 where the stored row holds a 101 IS the news, and it was being dropped).
        # See `WsEngine::Result#answered?`.
        response_write = nil.as(WriteOutcome?)
        if result.answered? && persist
          response_write = WriteOutcome.new(persist_repeater_response(id, result.handshake_head, Bytes.empty,
            result.error, result.duration_us, project, request_sha256))
        end

        emit_ws_result(id, result, format, response_write)
        if (rw = response_write) && (why = rw.error)
          STDERR.puts "gori run repeater send: WebSocket #{why}#{project_write_warning_tail}"
        end
        # `--slot NAME` on the handshake head, resolved to nothing — same reason as the HTTP
        # path below. Before the exit so a failed exchange says it too.
        report_unbound_slot_overlay("gori run repeater send")
        exit 1 unless result.ok?
      end

      # Parse one `--auto-reply MATCH=REPLY` argument into an `AutoReply` rule, or return the
      # refusal sentence. Splits on the first `=` so `REPLY` may itself contain `=` or be empty.
      def self.ws_parse_auto_reply(spec : String) : Repeater::WsSession::AutoReply | String
        match, sep, reply = spec.partition('=')
        if sep.empty? || match.empty?
          return "--auto-reply #{spec.inspect}: expected MATCH=REPLY with a non-empty MATCH (e.g. --auto-reply=PING=PONG)"
        end
        Repeater::WsSession::AutoReply.new(match, reply)
      end

      # Decode one `--binary` stdin line (hex digits, optional leading `0x`) into raw frame
      # bytes, or return the error sentence when the line is not valid even-length hex.
      def self.ws_parse_hex_line(line : String) : Bytes | String
        cleaned = line.strip
        cleaned = cleaned[2..] if cleaned.starts_with?("0x") || cleaned.starts_with?("0X")
        cleaned.hexbytes
      rescue ArgumentError
        "invalid hex line #{CLI::Output.term_line(line).inspect} (expected an even number of hex digits)"
      end

      # Shared state between `run_ws_session` and the `gori-ws-stdin` fiber.
      private class WsStdinState
        property? done = false
        property? failed = false
      end

      # `gori run repeater ws <repeater-id>` — the `gori run` surface for `Repeater::WsSession`
      # (#1660), matching the TUI's Connect (`c`) and MCP's `ws_session_open` / `ws_session_send`
      # / `get_job` / `stop_job` (#1630). Dials the saved repeater's HTTP/1.1 WebSocket upgrade,
      # sends each stdin line as a TEXT frame (or hex-decoded BINARY under `--binary`), and
      # streams inbound + outbound transcript entries to stdout until EOF, `--for`, or Ctrl-C.
      private def self.cmd_repeater_ws(args : Array(String)) : Nil
        proj = ProjectFlags.new
        insecure = false
        allow_unscoped = false
        verbatim = false
        slot : String? = nil
        ws_keep_key = false
        tls_preset : String? = nil
        binary = false
        format = :text
        duration : Time::Span? = nil
        auto_replies = [] of Repeater::WsSession::AutoReply
        engine_io = false
        positional = [] of String

        parser = option_parser("gori run repeater ws") do |p|
          p.banner = "Usage: gori run repeater ws <repeater-id> [options]\n\n" \
                     "Open a persistent WebSocket session on a saved repeater (ids from `gori run repeater list`).\n" \
                     "Each line on stdin is sent as a TEXT frame (or hex-decoded BINARY with --binary); every\n" \
                     "sent and received frame is printed to stdout as it arrives. EOF on stdin, --for, or Ctrl-C\n" \
                     "sends CLOSE and exits cleanly."
          project_options(p, proj, "read")
          p.on("-k", "--insecure-upstream", "Do not verify the upstream TLS certificate") { insecure = true }
          p.on("--allow-unscoped", "Connect even if the target is outside the project scope (the Sandbox still applies)") { allow_unscoped = true }
          p.on("--verbatim", "Send the handshake and stdin lines EXACTLY: no token expansion ($ENV.KEY, $BIND.NAME, $GEN.*)") { verbatim = true }
          p.on("--slot=NAME", "Connect as this SESSION SLOT — its header overlay, and its binding table for $BIND.NAME tokens") { |v| slot = v.strip }
          p.on("--ws-keep-key", "Send the request's own Sec-WebSocket-Key instead of a fresh one") { ws_keep_key = true }
          p.on("--tls-preset=NAME", "#{TLS_PRESET_HELP}, overriding the session's stored one for this connect") { |v| tls_preset = v }
          p.on("--auto-reply MATCH=REPLY", "Auto-reply to an exact inbound TEXT payload with a TEXT frame (repeatable, e.g. --auto-reply=PING=PONG)") do |v|
            parsed = ws_parse_auto_reply(v)
            abort "gori run repeater ws: #{parsed}" if parsed.is_a?(String)
            auto_replies << parsed
          end
          p.on("--engine-io", "Answer Engine.IO / Socket.IO '2' heartbeat pings with '3' (shorthand for --auto-reply=2=3)") { engine_io = true }
          p.on("--for=DURATION", "Close the session after DURATION (e.g. 30s, 5m, 1h) even if stdin is still open") do |v|
            duration = parse_duration(v)
          end
          p.on("--binary", "Read stdin lines as hex-encoded bytes and send each as a BINARY (opcode 2) frame") { binary = true }
          format_flag(p, [:text, :json], "Output: text (default) | json (one JSON object per frame, matching MCP get_job)") { |f| format = f }
          p.unknown_args { |before, after| positional = before + after }
        end
        parser.parse(args)
        refresh_verify_upstream(!insecure)
        abort "gori run repeater ws: missing <repeater-id>\n#{parser}" if positional.empty?
        abort "gori run repeater ws: too many arguments (expected one <repeater-id>, got: #{positional.join(" ")})" if positional.size > 1
        id = positional[0].to_i64? || abort "gori run repeater ws: invalid repeater id '#{positional[0]}'"
        auto_replies << Repeater::WsSession::ENGINE_IO_HEARTBEAT if engine_io

        project = resolve_read_project(proj.name, proj.db)
        interrupted = install_interrupt_trap("ws-interrupt", "interrupted — closing WebSocket session…") { }
        ok, err = open_and_run_ws_session(id, project,
          insecure: insecure, allow_unscoped: allow_unscoped, verbatim: verbatim,
          slot: slot, ws_keep_key: ws_keep_key, tls_preset: tls_preset,
          auto_replies: auto_replies, binary: binary, duration: duration,
          format: format, cancel: interrupted)
        report_unbound_slot_overlay("gori run repeater ws")
        Run.report_interrupted(1, "session", "closed") if interrupted.call
        if err
          STDERR.puts err
          exit 1
        end
        exit 1 unless ok
      end

      # Resolve the saved repeater session, run its handshake through the `Repeater::Plan` +
      # `Outbound` gate, and stream frames through `run_ws_session`. Returns `{ok, error_line}`
      # without calling `exit` on session/handshake failures so specs can drive the full path
      # with in-memory `stdin`/`stdout`/`stderr` buffers.
      def self.open_and_run_ws_session(id : Int64, project : Project, *,
                                       insecure : Bool = false,
                                       allow_unscoped : Bool = false,
                                       verbatim : Bool = false,
                                       slot : String? = nil,
                                       ws_keep_key : Bool = false,
                                       tls_preset : String? = nil,
                                       auto_replies : Array(Repeater::WsSession::AutoReply) = [] of Repeater::WsSession::AutoReply,
                                       binary : Bool = false,
                                       duration : Time::Span? = nil,
                                       format : Symbol = :text,
                                       stdin : IO = STDIN,
                                       stdout : IO = STDOUT,
                                       stderr : IO = STDERR,
                                       cancel : Proc(Bool)? = nil) : {Bool, String?}
        loaded = load_ws_session_repeater(id, project)
        return {false, loaded} if loaded.is_a?(String)
        rec, host_overrides, evidence = loaded

        activate_slot(slot, "gori run repeater ws")
        outbound = project_outbound(project, allow_unscoped)
        begin
          plan = build_ws_session_plan(id, rec, host_overrides, outbound,
            insecure: insecure, verbatim: verbatim, tls_preset: tls_preset, evidence: evidence)
          return {false, plan} if plan.is_a?(String)

          opened = plan.open_ws(ws_keep_key || rec.ws_keep_key?, auto_replies, cancel,
            gate: -> { plan.refusal })
          session = opened.session
          unless session
            return {false, ws_handshake_failure_line(opened.result, stderr)}
          end
          stderr.puts "→ WebSocket upgraded=true in #{CLI::Output.human_us(opened.result.duration_us)}" if format != :json
          stderr.puts "note: #{CLI::Output.term_line(opened.result.note.to_s)}" if opened.result.note
          stderr.flush
          ok = run_ws_session(session, stdin: stdin, stdout: stdout, stderr: stderr,
            format: format, binary: binary, duration: duration, verbatim: verbatim, cancel: cancel)
          {ok, nil}
        ensure
          outbound.close
        end
      end

      private def self.ws_handshake_failure_line(result : Repeater::WsEngine::Result, stderr : IO) : String
        if note = result.note
          stderr.puts "note: #{CLI::Output.term_line(note)}"
          stderr.flush
        end
        msg = result.error || "the handshake was not upgraded; no session was opened"
        "gori run repeater ws: #{CLI::Output.term_line(msg)}"
      end

      private def self.load_ws_session_repeater(id : Int64,
                                                project : Project) : {Store::RepeaterRecord, Gori::HostOverrides, Bool} | String
        store = open_store(project, read_only: true)
        rec, host_overrides, evidence = begin
          r = store.get_repeater_full(id)
          {r, Gori::HostOverrides.load(store), r ? Repeater::DraftMarkers.evidence?(store, r) : false}
        ensure
          store.close
        end
        return "gori run repeater ws: no repeater session ##{id}" unless rec
        unless Repeater::WsEngine.replayable?(String.new(rec.request))
          return "gori run repeater ws: session ##{id} is not a WebSocket handshake " \
                 "(neither an RFC 6455 `Upgrade:` request nor an RFC 8441 extended CONNECT)"
        end
        if rec.ws_http_only?
          return "gori run repeater ws: session ##{id} is stored as HTTP-only (ws_http_only) — " \
                 "use `gori run repeater send #{id}` to send its handshake as an ordinary HTTP request"
        end
        if reason = Repeater::WsSession.refusal(rec.request)
          return "gori run repeater ws: #{reason}"
        end
        {rec, host_overrides, evidence}
      end

      private def self.build_ws_session_plan(id : Int64, rec : Store::RepeaterRecord,
                                             host_overrides : Gori::HostOverrides,
                                             outbound : Gori::Outbound, *,
                                             insecure : Bool, verbatim : Bool,
                                             tls_preset : String?, evidence : Bool = false) : Repeater::Plan | String
        plan = begin
          Repeater::Plan.build(session_plan_options(rec, insecure, host_overrides, verbatim, nil, false,
            tls_preset, evidence: evidence), outbound)
        rescue ex : Repeater::PlanError
          return repeater_plan_error("gori run repeater ws", ex, "session ##{id}")
        end
        verdict = repeater_scope_verdict(outbound, plan)
        if verdict.blocked?
          return "gori run repeater ws: #{plan.host} is out of the project scope — " \
                 "#{Gori::Outbound.remedy(verdict, "--allow-unscoped", waiver_passes_exclude: outbound.send_passes_exclude?)}"
        end
        if reason = plan.refusal
          return "gori run repeater ws: #{reason}"
        end
        plan
      end

      # Drive an open `Repeater::WsSession`: read lines from `stdin` on a worker fiber and
      # write each as a WebSocket frame; drain the transcript in order on the calling fiber
      # (`WsSession#wait` has a single waiter slot) until `stdin` reaches EOF (when `--for` is
      # absent), `duration` (`--for`) elapses, `cancel` fires, or the peer closes the connection.
      def self.run_ws_session(session : Repeater::WsSession, *,
                              stdin : IO = STDIN,
                              stdout : IO = STDOUT,
                              stderr : IO = STDERR,
                              format : Symbol = :text,
                              binary : Bool = false,
                              duration : Time::Span? = nil,
                              verbatim : Bool = false,
                              cancel : Proc(Bool)? = nil) : Bool
        state = WsStdinState.new
        spawn(name: "gori-ws-stdin") do
          pump_ws_stdin(session, stdin, stderr, state,
            binary: binary, verbatim: verbatim, cancel: cancel)
        end
        cursor = drain_ws_session_until_done(session, state, stdout, format, duration, cancel)
        session.close unless session.closed?
        drain_ws_session_transcript(session, cursor, stdout, format)
        if session.close_abnormal?
          stderr.puts "gori run repeater ws: #{CLI::Output.term_line(session.close_reason.to_s)}" unless state.failed?
          stderr.flush
          return false
        end
        !state.failed?
      end

      private def self.drain_ws_session_until_done(session : Repeater::WsSession, state : WsStdinState,
                                                   stdout : IO, format : Symbol,
                                                   duration : Time::Span?,
                                                   cancel : Proc(Bool)?) : Int64
        cursor = 0_i64
        deadline = duration.try { |d| Time.instant + d }

        loop do
          cursor = drain_ws_session_transcript(session, cursor, stdout, format)
          break if session.closed? || cancel.try(&.call)
          break if state.done? && deadline.nil?
          step = ws_session_wait_step(deadline, Time.instant)
          break unless step
          session.wait(step)
        end
        cursor
      end

      private def self.ws_session_wait_step(deadline : Time::Instant?,
                                            now : Time::Instant) : Time::Span?
        step = 50.milliseconds
        return step unless dl = deadline
        rem = dl - now
        return nil if rem <= Time::Span.zero
        rem < step ? rem : step
      end

      private def self.pump_ws_stdin(session : Repeater::WsSession, stdin : IO, stderr : IO,
                                     state : WsStdinState, *, binary : Bool, verbatim : Bool,
                                     cancel : Proc(Bool)?) : Nil
        while !session.closed? && !cancel.try(&.call)
          line = stdin.gets(chomp: true) rescue nil
          break unless line
          msg = ws_stdin_out_msg(line, binary: binary, verbatim: verbatim, stderr: stderr)
          unless msg
            state.failed = true
            next
          end
          if err = session.send(msg, cancel)
            unless session.closing? || cancel.try(&.call)
              stderr.puts "gori run repeater ws: send failed: #{CLI::Output.term_line(err)}"
              stderr.flush
              state.failed = true
            end
            break
          end
        end
      ensure
        state.done = true
      end

      # Convert one line from `stdin` into the `WsEngine::OutMsg` to send, or print the error to
      # `stderr` and return nil.
      private def self.ws_stdin_out_msg(line : String, *, binary : Bool, verbatim : Bool,
                                        stderr : IO) : Repeater::WsEngine::OutMsg?
        if binary
          parsed = ws_parse_hex_line(line)
          if parsed.is_a?(String)
            stderr.puts "gori run repeater ws: #{parsed}"
            stderr.flush
            return nil
          end
          Repeater::WsEngine::OutMsg.new(Proxy::WS::OP_BIN.to_i, parsed)
        else
          payload = begin
            (verbatim ? line : Repeater::UrlRequest.expand(line)).to_slice
          rescue ex : Repeater::PlanError
            stderr.puts repeater_plan_error("gori run repeater ws", ex, "this line (not sent)")
            stderr.flush
            return nil
          end
          Repeater::WsEngine::OutMsg.new(Proxy::WS::OP_TEXT.to_i, payload)
        end
      end

      # Emit any transcript rows past `cursor` to `stdout`. Returns the updated `cursor`.
      private def self.drain_ws_session_transcript(session : Repeater::WsSession, cursor : Int64,
                                                   stdout : IO, format : Symbol) : Int64
        entries = session.transcript(after: cursor)
        return cursor if entries.empty?
        entries.each do |entry|
          cursor = entry.seq
          line = if format == :json
                   JSON.build { |j| entry.to_json(j) }
                 else
                   CLI::Output.term_safe(ws_transcript_line(entry.message))
                 end
          stdout.puts line
        end
        stdout.flush
        cursor
      end

      # The session's outbound messages: `--message` overrides when given (each
      # sent as a text frame), else the WS messages stored on the repeater (the
      # ones with direction "out"), env-expanded like MCP send_websocket.
      #
      # Each frame is expanded on its own, AFTER `Repeater::Plan` built the handshake, so
      # the builder's unresolved-token check (#519) never sees a message payload — this is
      # the second half of that gate and it lives here (#524).
      #
      # `--verbatim` reaches this at all now: it was threaded into `session_plan_options`
      # (the handshake head) but was not a parameter of `cmd_repeater_send_ws`, so a WS
      # message was expanded on the wire despite the flag's own help text saying "no $VAR
      # expansion". Under verbatim a literal `$TOKEN` IS the payload.
      #
      # No `.scrub` anywhere on this path. `Env.expand` scans BYTES and copies every span
      # that is not a matched token through unchanged (its own header says so), so a TEXT
      # frame carrying invalid UTF-8 survives to the wire; scrubbing it turned 9 bytes into
      # 13 and sent those instead, with no warning.
      #
      # `evidence` — the session was seeded from a CAPTURED flow — turns the expansion off
      # for its stored rows. The rationale this used to carry, "a text frame is UTF-8 the
      # operator typed, the same provenance as a header value", is simply false for a seeded
      # session: those rows are the client's frames, recorded by the WS relay. So a capture of
      # `{"$where":"this.a==1"}` was unreplayable without project env vars, and setting them
      # the way the old refusal advised sent `{"WHEREVAL":"this.a==1"}`. There is no refusal
      # left to pair with it — an unresolved name is literal on every path now — but the
      # expansion split still matters: `--message` / `--message-frame` stay a DRAFT and DO
      # resolve a `$KEY` the operator set.
      private def self.ws_out_messages(store : Store, id : Int64,
                                       override : Array(Store::WsOutMessage),
                                       verbatim : Bool = false,
                                       evidence : Bool = false) : Array(Repeater::WsEngine::OutMsg)
        stored = override.empty?
        source = if stored
                   rows, dropped = Run.ws_seed_rows(store.ws_messages_for_repeater(id))
                   STDERR.puts "gori run repeater send: #{Run.ws_notice_dropped_note(dropped)}" if dropped > 0
                   rows.map { |m| Store::WsOutMessage.new(m.opcode, m.payload, m.shape) }
                 else
                   override
                 end
        seeded = stored && evidence
        source.map do |m|
          payload = m.text? && !verbatim && !seeded ? Repeater::UrlRequest.expand(String.new(m.payload)).to_slice : m.payload
          Repeater::WsEngine::OutMsg.new(m.opcode, payload, m.shape, seeded)
        end
      end

      # The `out` frames of a captured flow, minus gori's own advisory rows, and HOW MANY
      # were dropped. Every seed reader goes through this rather than repeating the filter,
      # and none of them may go quiet about it: a seed that silently holds fewer frames than
      # the capture is the same class of problem as one that holds an extra.
      def self.ws_seed_rows(rows : Array(Store::WsMessage)) : {Array(Store::WsMessage), Int32}
        out = rows.select { |m| m.direction == "out" }
        # The prefix is the whole test, NOT the opcode: the ping-flood marker keeps its PING
        # opcode (9), so an opcode filter would replay it as a real control frame.
        kept = out.reject { |m| Gori::Proxy::WS.notice?(m.payload) }
        {kept, out.size - kept.size}
      end

      # Is this STORED session's head one an operator should be told about? (#1075)
      #
      # Three questions, in this order for a reason. The head terminator is the cheap one and
      # it answers `false` for every well-formed row, so neither of the two exemptions below
      # costs anything on a healthy workbench — in particular the `String.new` the WebSocket
      # test needs is built only for the rare row that is actually malformed, and a 500-tab
      # listing never copies a stored request to ask.
      #
      # BOTH exemptions exist because a blank-line terminator is an HTTP/1.1 wire fact and
      # two of gori's engines do not put this head on a socket as text:
      #
      #   * HTTP/2 has no head terminator AT ALL. `H2Engine.parse_request` splits the buffer
      #     into lines, drops the empty one and emits an HPACK field list — measured: the
      #     fields from `…Accept: */*\r\n\r` are byte-identical to those from `…\r\n\r\n`.
      #     So every send from an h2 session is a well-formed request, and saying otherwise
      #     would put a permanent `!head-unterminated` on a tab that has nothing wrong with it.
      #   * `WsEngine.build_handshake` re-emits the head line by line and writes its own
      #     `\r\n` terminator, so a framed handshake is framed whatever the row holds.
      #
      # Either way the note's claim — "gori sends it exactly as given" — would be FALSE, which
      # is the one thing a notice about byte fidelity may not be. `ws_http_only` is the row
      # that opts OUT of the WebSocket engine: those bytes go through the HTTP engine
      # untouched, so they are back in.
      #
      # KEYWORD-ONLY, and that is load-bearing rather than style: these are same-typed Bools
      # about the same row, and a positional pair is how a call site written against the
      # previous arity keeps compiling while writing its `true` into the flag beside the one
      # it meant. `Repeater::Result`'s constructor carries the same tail for the same reason.
      #
      # Shared by every surface that reports on a STORED row (`repeater create`'s notice,
      # `repeater list`, MCP's session emitter). The SEND surfaces do not call it: they hold
      # the wire and have already chosen an engine, so they ask `Env.head_terminated?` of the
      # bytes themselves — under the same h1-only guard, for the same reason.
      def self.unterminated_head?(request : Bytes, *, ws_http_only : Bool, http2 : Bool) : Bool
        return false if http2 || Env.head_terminated?(request)
        ws_http_only || !Repeater::WsEngine.replayable?(String.new(request))
      end

      # The one sentence every surface says about an unterminated head (#1075).
      #
      # It is a NOTICE, never a refusal, and the wording has to carry that: gori stores and
      # sends these bytes exactly as given, because a head that never terminates is a
      # legitimate thing to put on a socket (a desync primitive, a slowloris probe) and
      # `repeater` exists to send non-standard HTTP. The sentence therefore states the fact,
      # says gori did NOT touch it, and names the way an operator acquires one by accident —
      # `$(…)`, which strips the trailing newlines a file or a here-doc keeps. That last
      # clause is the useful half: the accidental population is almost entirely shell
      # command substitution, and a request WITH a body survives it (the terminator is
      # followed by the body), so the GET tab breaks while the POST tab beside it works.
      #
      # Shared with MCP the way `ws_notice_dropped_note` is: one sentence, so an agent and an
      # operator reading two surfaces are told the same thing about one request. A surface
      # with no room for it says `unterminated_head_chip` instead — the short spelling lives
      # beside this one rather than as a literal at its call site, so an edit to the wording
      # reaches both.
      def self.unterminated_head_note : String
        "the request head is NOT terminated (no blank line), so this is not a complete HTTP " \
        "message — gori sends it exactly as given and never repairs it, because a truncated " \
        "head is itself a test. If that was not the intent, end the head with a blank line: " \
        "shell $(…) strips the trailing newlines that a file or a here-doc keeps"
      end

      # The same fact at toast width, for a surface that appends it to a line it does not own.
      # The TUI's send status already carries a status, a duration and up to two other
      # clauses, and the full sentence would push all of them off a narrow terminal — so this
      # keeps the two halves that cannot be dropped (WHAT is wrong, and that gori sent it
      # anyway) and leaves the remedy to `repeater list`, which has a line to spare.
      def self.unterminated_head_chip : String
        "head NOT terminated (no blank line) — sent as given"
      end

      # The one sentence every surface uses for that drop, so the CLI, MCP and the TUI
      # cannot describe it differently.
      def self.ws_notice_dropped_note(n : Int32) : String
        "#{n} gori advisory row#{n == 1 ? "" : "s"} in this capture #{n == 1 ? "was" : "were"} " \
        "not seeded — they are diagnostics gori wrote about the socket, not frames the client sent"
      end

      # `--message-frame`. The grammar is shared with MCP (`Repeater::WsFrameSpec`) so a
      # script gets the same frame whichever surface it drives.
      private def self.parse_message_frame(spec : String) : Store::WsOutMessage
        msg, err = Repeater::WsFrameSpec.parse(spec)
        return msg if msg
        abort "gori run repeater send: #{err || "could not read --message-frame #{spec.inspect}"}"
      end

      # The shape a CAPTURED out-frame seeds a repeater session with.
      #
      # `rsv` and `fin` carry across — replaying an RSV1 frame as RSV1 is the whole point of
      # recording it. The MASK KEY deliberately does not: a masking key is a nonce (§5.3
      # wants it unpredictable), so pinning the captured one onto every future send of this
      # session would be a fixed nonce nobody asked for. `frames` is capture-only — the
      # repeater sends one frame per message, and claiming otherwise would be a lie the send
      # path cannot honour.
      #
      # `masked` carries across ONLY when it is false. `masked: true` is the encoder's own
      # default for a client frame, so seeding it states nothing — but it is not `nil`, so a
      # `Shape#default?` reader (the TUI's "can this be one editable line?" test) called every
      # ordinary captured TEXT frame unusual and pushed it out of the message pane. The built
      # TUI is what showed that: `+7 not shown: TEXT, TEXT rsv=4, …` over an empty pane. A
      # client frame that arrived UNMASKED is a real §5.1 violation and replaying it IS the
      # test, so that one is stated.
      def self.seed_shape(shape : Store::WsShape) : Store::WsShape
        Store::WsShape.new(fin: shape.fin, rsv: shape.rsv,
          masked: shape.masked == false ? false : nil)
      end

      # Refuse a WS send whose TEXT payloads still name a var that resolves to nothing,
      # before the handshake is dialed. Same fact as the builder's refusal, checked where
      # the expansion actually happens (#524).
      #
      # One transcript row. An ordinary masked TEXT frame prints as bare text, exactly as it
      # always did; anything else names its shape first, because the whole point of being able
      # to send a PING or an unmasked frame is being able to read back that you did.
      private def self.ws_transcript_line(m : Repeater::WsEngine::Message) : String
        to_server = m.direction == "out"
        arrow = to_server ? "→" : "←"
        return "#{arrow} #{scrub(m.payload)}" if m.opcode == 1 && m.shape.default?(to_server)
        label = Store::WsOutMessage.new(m.opcode, m.payload, m.shape).shape_label(to_server)
        body =
          case m.opcode
          when 1 then scrub(m.payload)
          when 2 then "#{m.payload.size} bytes 0x#{m.payload[0, {m.payload.size, 32}.min].hexstring}"
          else
            # A control frame. Until this round none of these reached a transcript at all, so
            # the payload — a CLOSE's code and reason above all — is printed, not counted.
            ws_control_payload_text(m.opcode, m.payload)
          end
        "#{arrow} [#{label}] #{body}"
      end

      # A control frame's payload for the text transcript: a CLOSE's 2-byte code plus its
      # reason, else the bytes.
      private def self.ws_control_payload_text(opcode : Int32, payload : Bytes) : String
        return "(no payload)" if payload.empty?
        # Only a CLOSE has a status code. Reading the first two bytes of a PING as one is how
        # `PING "hi there"` would be reported as `close 26728`.
        if opcode == 8 && payload.size >= 2
          code = (payload[0].to_i << 8) | payload[1].to_i
          rest = payload.size > 2 ? String.new(payload[2, payload.size - 2]).scrub : ""
          return rest.empty? ? "code #{code}" : "code #{code} #{CLI::Output.term_safe(rest)}"
        end
        s = String.new(payload)
        s.valid_encoding? ? CLI::Output.term_safe(s) : "0x#{payload.hexstring}"
      end

      private def self.emit_ws_result(id : Int64, result : Repeater::WsEngine::Result, format : Symbol,
                                      response_write : WriteOutcome? = nil) : Nil
        if format == :json
          puts ws_result_json(id, result, response_write)
        elsif result.ok?
          STDERR.puts "→ WebSocket upgraded=#{result.upgraded?} in #{CLI::Output.human_us(result.duration_us)}#{result.close_code ? " (close #{result.close_code})" : ""}"
          STDERR.puts "note: #{result.note}" if result.note
          STDERR.puts "truncated: #{result.truncated}" if result.truncated
          # A server frame's text is the remote's choice of bytes: named, never replayed raw.
          result.messages.each { |m| puts CLI::Output.term_safe(ws_transcript_line(m)) }
        else
          STDERR.puts "gori run repeater send: send failed: #{CLI::Output.term_line(result.error.to_s)}"
        end
      end

      # Whether the stored handshake was written, beside the exchange it came from. Present only
      # when a write was attempted (`answered?`), like `response_saved` on the HTTP object.
      private def self.emit_write_outcome_json(j : JSON::Builder, saved_field : String,
                                               error_field : String, outcome : WriteOutcome?) : Nil
        return unless o = outcome
        j.field saved_field, o.ok?
        j.field error_field, o.error unless o.ok?
      end

      # Save reporting stays on STDERR in text mode so the response alone remains pipeable.
      private def self.emit_send_repeater_status(saved_repeater_id : Int64?,
                                                 repeater_write : WriteOutcome?,
                                                 response_write : WriteOutcome?,
                                                 format : Symbol) : Nil
        return if format == :json
        STDERR.puts "saved as Repeater session ##{saved_repeater_id}" if saved_repeater_id
        if write = repeater_write
          STDERR.puts "#{write.error}#{project_write_warning_tail}" unless write.ok?
        end
        if write = response_write
          STDERR.puts "#{write.error}#{project_write_warning_tail}" unless write.ok?
        end
      end

      private def self.ws_result_json(id : Int64, result : Repeater::WsEngine::Result,
                                      response_write : WriteOutcome? = nil) : String
        JSON.build do |j|
          j.object do
            j.field "repeater_id", id
            j.field "upgraded", result.upgraded?
            j.field "duration_us", result.duration_us
            j.field "close_code", result.close_code
            CLI::Output.json_captured(j, "error", result.error)
            j.field "note", result.note
            emit_write_outcome_json(j, "response_saved", "response_save_error", response_write)
            # The inbound transcript stopped SHORT of the server at a cap. A synthetic row
            # already sits in `messages` below; this is the summary half so a script reading
            # the envelope (not walking the array) still sees the transcript is incomplete.
            j.field "truncated", result.truncated
            j.field "messages" do
              j.array do
                result.messages.each do |m|
                  j.object do
                    j.field "direction", m.direction
                    j.field "opcode", m.opcode
                    j.field "frame", Store::WsOutMessage.new(m.opcode, m.payload, m.shape).shape_label(m.direction == "out")
                    # A CLOSE's §5.5.1 code and reason as FIELDS, not only inside the base64
                    # below. The text transcript beside this has printed them all along
                    # (`ws_control_payload_text`), `gori run show --format json` emits them on
                    # a captured row (`WsMessage#emit_shape_json`) and MCP `send_websocket`
                    # emits them on this very transcript — so a script driving the CLI was the
                    # one reader left decoding base64 to learn WHY the socket closed, which is
                    # the single most diagnostic thing a failed WebSocket test produces.
                    if m.opcode == 8 && m.payload.size >= 2
                      j.field "close_code", (m.payload[0].to_i << 8) | m.payload[1].to_i
                      reason = m.payload[2, m.payload.size - 2]
                      j.field "close_reason", String.new(reason).scrub unless reason.empty?
                    end
                    if m.opcode == 1
                      j.field "text", scrub(m.payload)
                      # JSON has no way to carry a byte that is not valid UTF-8, so `text`
                      # above is U+FFFD-substituted for exactly the payload an §8.1/§5.6
                      # test is about. Emit the real bytes beside it rather than leaving a
                      # script no way to read them back.
                      j.field "payload_base64", Base64.strict_encode(m.payload) unless String.new(m.payload).valid_encoding?
                    else
                      j.field "binary", true
                      j.field "size", m.payload.size
                      j.field "payload_base64", Base64.strict_encode(m.payload)
                    end
                  end
                end
              end
            end
          end
        end
      end

      # Render a replay Result (text or json, optional diff), shared by the flow-id
      # replay and the session-send paths so the two render identically. Caller has
      # already decoded `new_body` and built `diff` (the diff baseline differs per
      # path); caller owns the exit code.
      # The fingerprint this send ACTUALLY presented, for the surfaces that report it — nil on
      # a plaintext leg even when `--tls-preset` was passed, because an `http://` send makes no
      # ClientHello and naming one would report a handshake that did not happen. The MCP twin
      # (`send.cr`) and the fuzz banner guard the same way and for the same reason; the doc
      # says so out loud ("gori will not report one it did not send").
      #
      # Only the REPORT is guarded. What the plan carries, and what a `repeater create` row
      # stores, stay as the operator set them — an override on an http:// target is inert, not
      # withdrawn (P4).
      private def self.sent_tls_preset(plan : Repeater::Plan) : String?
        plan.scheme == "https" ? plan.tls_preset : nil
      end

      # The binary-body marker's route to exact bytes: a send has no `--format raw` (#1708).
      SEND_EXACT_BYTES = "--format json for exact bytes (body.base64, or body.text when it is UTF-8)"

      private def self.emit_repeater_result(result : Repeater::Result, new_body : Bytes?,
                                            diff : Array(Repeater::DiffLine)?, format : Symbol,
                                            diff_capped : Bool = false,
                                            recorded_flow_id : Int64? = nil,
                                            tls_preset : String? = nil,
                                            response_write : WriteOutcome? = nil,
                                            history_write : WriteOutcome? = nil,
                                            cap : BodyCap = BodyCap.new,
                                            request_target : String? = nil,
                                            prefix : String = "gori run repeater",
                                            applied_rules : Bool = false,
                                            saved_repeater_id : Int64? = nil,
                                            repeater_write : WriteOutcome? = nil,
                                            repeater_response_write : WriteOutcome? = nil,
                                            via : String? = nil) : Nil
        # Text mode: the id goes to STDERR beside the other status lines, so a `> resp.txt`
        # redirect still captures exactly the response and nothing else.
        STDERR.puts "recorded to History as flow ##{recorded_flow_id}" if recorded_flow_id && format != :json
        emit_send_repeater_status(saved_repeater_id, repeater_write, repeater_response_write, format)
        # A `--path` send names its target on the status line: a loop over forty paths reads
        # forty `→ 200` lines otherwise, with nothing tying each to the request it answered.
        at = request_target.try { |t| " · #{CLI::Output.term_safe(t)}" } || ""
        if format == :json
          puts repeater_json(result, diff, diff_capped, recorded_flow_id, tls_preset,
            response_write: response_write, history_write: history_write, cap: cap,
            request_target: request_target, applied_rules: applied_rules,
            saved_repeater_id: saved_repeater_id, repeater_write: repeater_write,
            repeater_response_write: repeater_response_write, via: via)
        elsif result.ok?
          STDERR.puts "→ #{result.response.try(&.status) || "?"} in #{CLI::Output.human_us(result.duration_us)}#{at}#{result.incomplete? ? " (#{incomplete_reason(result, result.timed_out?)})" : ""}"
          if d = diff
            print_diff(d)
            n = Repeater::Diff.change_count(d)
            # Never a bare "no differences" over a CUT diff: `Diff.lines` caps both sides at
            # MAX_LINES, so a change past the cut is absent from the diff AND from the count
            # — and a longer new response (an appended payload, a stack trace) puts its extra
            # lines exactly there. "no differences" is the answer an operator acts on, so the
            # verdict line itself says when it only covers the compared part (`compare_verdict`).
            STDERR.puts compare_verdict(n, diff_capped)
            STDERR.puts "(diff truncated to #{Repeater::Diff::MAX_LINES} lines/side — lines past the cut were not compared)" if diff_capped
          else
            print_message_text(result.head, new_body, result.body, cap, SEND_EXACT_BYTES)
          end
        else
          # Named after the command that sent it: `gori run send` said "repeater failed:", a
          # surface the operator never invoked (#1389).
          STDERR.puts "#{prefix}: send failed: #{CLI::Output.term_line(result.error.to_s)}"
          # An error and a RESPONSE are not exclusive. The engine deliberately keeps the head
          # for exactly this case (`engine.cr` — "must NOT throw the head away as a bare error
          # string"), and two shapes reach here with both: a framing error over a head gori
          # read fine (conflicting Content-Lengths), and an h2 stream RST after a partial
          # response — status 200, real head, real body, plus a named RST code. `--format json`
          # and MCP render both halves; the default text view printed one sentence and dropped
          # the head, so the answer that IS the finding was visible on every rendering except
          # the default one.
          unless result.head.empty?
            STDERR.puts "→ #{result.response.try(&.status) || "?"} in #{CLI::Output.human_us(result.duration_us)}#{at}#{result.incomplete? ? " (#{incomplete_reason(result, result.timed_out?)})" : ""}"
            print_message_text(result.head, new_body, result.body, cap, SEND_EXACT_BYTES)
          end
        end
      end

      # `incomplete`, its reason, and which event-stream bound stopped the read (#1631) — one
      # emitter for `--format json` and MCP `send_request`, so the keys stay in lockstep.
      def self.emit_incomplete_json(j : JSON::Builder, result : Repeater::Result) : Nil
        return unless result.incomplete?
        j.field "incomplete", true
        j.field "incomplete_reason", incomplete_reason(result, result.timed_out?)
        j.field("bounded", result.bounded) if result.bounded
      end

      # WHY the captured response is short. `Result#incomplete?` conflates THREE causes and
      # this sentence used to name only one of them, so gori blamed the target for something
      # gori did:
      #
      #   * gori's own capture ceiling stopped the read. Told apart by the only evidence
      #     available here — a body sitting exactly at the ceiling was cut by the ceiling.
      #   * the read ended on an IDLE TIMEOUT. The socket is still open and the origin
      #     never closed anything; saying it did points the operator at the wrong end of the
      #     wire and at the wrong fix (the fix is a longer deadline).
      #   * the origin really did close before the framed body finished.
      #
      # An event stream gori stopped at its bound (#1631) is named before all three: the read
      # ended on gori's choice, and its body is short of no limit above.
      #
      # `self.` and public so MCP renders the identical three sentences: two copies of a
      # three-way classification is how two surfaces come to disagree about one flow.
      def self.incomplete_reason(result : Repeater::Result, timed_out : Bool = false) : String
        cap = Proxy::Codec::Body::CAPTURE_READ_MAX
        case result.bounded
        when "events"
          return "incomplete — gori stopped the event stream at its event bound (--sse-events / sse_max_events)"
        when "time"
          return "incomplete — gori stopped the event stream at its time bound (--sse-time / sse_max_ms)"
        when "cancelled"
          return "incomplete — the send was cancelled while the event stream was open"
        when "budget"
          return "incomplete — the body was still arriving when gori stopped reading at its " \
                 "whole-read budget (three times the timeout; raise the timeout to read the rest)"
        end
        if (b = result.body) && b.size >= cap
          "incomplete — gori stopped reading at its #{cap // (1024 * 1024)} MiB capture ceiling"
        elsif timed_out
          "incomplete — the origin stopped sending and the read deadline expired; " \
          "it did not close the connection (raise the timeout to read the rest)"
        else
          "incomplete — origin closed before the framed body finished"
        end
      end

      # Build the final single-flow replay request wire from the captured head + body and the CLI
      # overrides (-H headers, -b body, --target Host sync). PURE: no store, no network, no exit —
      # the testable core of cmd_repeater_single's request mutation.
      #
      # Edits the head as RAW LINES so the request line and every header stay byte-exact except
      # where a flag overrides them. The old path rebuilt the request line from split
      # method/target/version tokens, which corrupted any line with a raw space in the target
      # (fuzzer/smuggling captures split into >3 tokens: the version was dropped and the path
      # truncated); it also re-emitted only parse_headers' output, silently dropping any colon-less
      # header line. Both are exactly the payloads this tool exists to replay faithfully, so we
      # never reconstruct them from parsed tokens.
      #
      # An explicit `-H "Content-Length: N"` is honored VERBATIM: a deliberately-wrong CL is the
      # whole point of CL-mismatch / request-smuggling testing, so neither the auto-resync nor the
      # post-expansion resync overwrites it (parity with `repeater create --no-auto-cl` + `send`,
      # the only other path that could do this before).
      #
      # `$KEY` EXPANSION HAPPENS HERE, on the operator's overrides ALONE. `Repeater::Plan`
      # used to run it over the whole merged wire, which meant a project var whose name
      # collided with a token in the CAPTURE (`$filter`, `$top`, `$where`, `$token`, `$user`
      # — ordinary names) rewrote the stored request and re-framed its Content-Length to
      # match, silently. The captured bytes are evidence and are now passed through untouched
      # (`PlanOptions#evidence?`), so the only place left that still knows which bytes the
      # operator typed is this merge — hence the expansion moved here with them. An
      # UNRESOLVED token in an override is refused before this runs
      # (`refuse_unresolved_overrides`), so nothing reaches `Env.expand` that it would leave
      # literal — except a DECLARED session binding, which `Env.expand` deliberately leaves
      # for `Env.expand_bindings` at the send seam. An `$ENV.X` with no value is refused by the
      # expansion itself (`UrlRequest.expand`, #1666), raised as the plan's `PlanError`.
      #
      # Returns the wire plus whether an explicit CL was pinned. `explicit_cl` is exactly the
      # session store's `auto_content_length` toggle inverted, so both ways of pinning a CL
      # reach the builder as one knob instead of two open-coded branches.
      private def self.build_single_flow_request(head_bytes : Bytes, body_bytes : Bytes,
                                                 headers : Array(String), body_override : String?,
                                                 target_override : String?,
                                                 removed_headers : Array(String) = [] of String,
                                                 *, expand : Bool = true) : {Bytes, Bool}
        # No flag edits the message: hand back the stored bytes untouched rather than take
        # them apart and put them back. A captured head is EVIDENCE — it may be terminated
        # with bare LFs (a front-end/back-end desync primitive gori stores byte-exact) or
        # carry no terminating blank line at all, and a rebuild would quietly re-terminate it
        # into a different request. Reassembly is only owed where an override asked for it.
        if headers.empty? && removed_headers.empty? && body_override.nil? && target_override.nil?
          return {combine_head_body(head_bytes, body_bytes), false}
        end

        head_str = String.new(head_bytes)
        entries = head_lines(head_str)
        request_line, request_eol = entries.first? || {head_str, "\r\n"}
        # A line the head just ENDS on carries no terminator, and every line here is followed by
        # another (at least the head terminator), so it takes the request line's spelling, or
        # CRLF when the request line is itself unterminated. Left "", the next line was glued
        # onto it: `Host: h` + `-H 'X: 1'` sent `Host: hX: 1`.
        request_eol = "\r\n" if request_eol.empty?
        # Header lines between the request line and the terminating blank line, each verbatim
        # and each carrying the terminator IT arrived with.
        raw_lines = entries[1..]?.try(&.reject { |(l, _)| l.empty? }.map { |(l, e)| {l, e.empty? ? request_eol : e} }) || [] of {String, String}
        # The blank line that ends the head, with the terminator it arrived with. Falls back
        # to the request line's spelling for a head that never had one.
        head_terminator = entries.last?.try { |(l, e)| l.empty? ? e : nil } || request_eol

        # -H overrides: lower-name → the values given for it, IN FLAG ORDER, plus the
        # flag-cased name in flag order for appends.
        #
        # A LIST, not one value: repeating `-H "X: a" -H "X: b"` used to have the second
        # silently overwrite the first, so `-H` could never produce two same-named header
        # lines — and duplicate-header handling is itself a thing operators come here to
        # test. Now n flags for one name emit n lines. A single `-H` still replaces (the
        # common case is unchanged); only repeating it adds.
        #
        # The stored value is the operator's spelling of everything AFTER the first colon,
        # verbatim. `--header`'s own help advertises an explicit Content-Length as honored
        # verbatim for CL-mismatch testing, but `Content-Length:\t5`, `Content-Length: 5 ` and
        # `Content-Length:0011` are the OWS-obfuscation half of that same probe class (RFC
        # 9112 §5.1) — stripping the whitespace and re-inserting exactly one space after the
        # colon made all three unreachable. Only the KEY is folded, so dedup/override still
        # matches the captured header regardless of how either side spelled it.
        custom_headers = {} of String => Array(String)
        custom_order = [] of {String, String}
        headers.each do |h_str|
          name, sep, val = h_str.partition(':')
          abort "gori run repeater: header #{h_str.inspect} rejected — write it as 'Name: value'" if sep.empty? || name.strip.empty?
          lname = name.strip.downcase
          custom_order << {lname, name} unless custom_headers.has_key?(lname)
          # The VALUE is the operator's draft, so it expands; the NAME is not (a `$` is not
          # a tchar, so a token there could only ever be a typo, and folding it into the
          # dedup key would make `-H '$H: a' -H 'X: b'` collide once `$H` resolved to `X`).
          # `expand: false` is `--verbatim`: the operator's value goes out as typed.
          (custom_headers[lname] ||= [] of String) << (expand ? Repeater::UrlRequest.expand(val) : val)
        end
        # --rm-header: drop every line with this name. Distinct from `-H "X:"`, which sends
        # X with an EMPTY value — both are real tests and neither can express the other.
        dropped = removed_headers.map(&.strip.downcase).reject(&.empty?).to_set

        # The header NAME of a raw line (bytes before the first colon), or "" for a
        # colon-less line — those are kept verbatim, never treated as a header to edit.
        line_name = ->(line : String) do
          c = line.index(':')
          c && c > 0 ? line[0, c] : ""
        end

        # Replace the FIRST occurrence of an overridden header (DROP later duplicates so an
        # h2 request's repeated cookie:/set-cookie: lines aren't left half-overridden), and
        # keep every other line — including colon-less ones — byte-exact.
        applied = Set(String).new
        new_lines = [] of {String, String}
        raw_lines.each do |(line, eol)|
          name = line_name.call(line)
          lname = name.strip.downcase
          if !lname.empty? && dropped.includes?(lname)
            next
          elsif !lname.empty? && (vals = custom_headers[lname]?)
            next if applied.includes?(lname)
            applied << lname
            # The operator's own spelling, on the terminator the captured line used.
            orig = custom_order.find { |(k, _)| k == lname }.try(&.[1]) || name
            vals.each { |v| new_lines << {"#{orig}:#{v}", eol} }
          else
            new_lines << {line, eol}
          end
        end
        custom_order.each do |(lname, orig)|
          next if applied.includes?(lname)
          custom_headers[lname].each { |v| new_lines << {"#{orig}:#{v}", request_eol} }
        end

        # `-d` is a draft too, and it expands BEFORE the Content-Length below is framed over
        # it — which is why `Repeater::Plan`'s post-expansion resync is now a no-op on this
        # path rather than the thing that quietly re-lengthed the CAPTURED body.
        final_body = if b_over = body_override
                       (expand ? Repeater::UrlRequest.expand(b_over) : b_over).to_slice
                     else
                       body_bytes
                     end

        has_te = new_lines.any? { |(l, _)| line_name.call(l).compare("Transfer-Encoding", case_insensitive: true) == 0 }
        # RFC 7230 §3.3.3 forbids sending Transfer-Encoding and Content-Length together.
        # When the original request was chunked (TE present, no override), keep its wire
        # framing byte-exact and don't inject a Content-Length. When the body is replaced
        # via -d, drop Transfer-Encoding and self-frame the new bytes with Content-Length.
        if has_te && body_override
          new_lines.reject! { |(l, _)| line_name.call(l).compare("Transfer-Encoding", case_insensitive: true) == 0 }
          has_te = false
        end
        # An explicit `-H "Content-Length: N"` is an intentional CL, so it is honored VERBATIM.
        # When present, skip BOTH the auto-resync below and the post-expansion resync so neither
        # overwrites the user's value — the header the override loop already wrote into new_lines
        # stands.
        # `--rm-header Content-Length` counts as an intentional pin too: an operator asking for
        # a body with NO Content-Length is testing exactly the framing gori would otherwise
        # restore under them. Same for Host below — re-adding a header the operator just
        # deleted makes the flag look like it did nothing.
        explicit_cl = custom_headers.has_key?("content-length") || dropped.includes?("content-length")
        # Re-frame ONLY the body the operator replaced. This used to fire on `has_cl ||
        # final_body.size > 0` too, i.e. on every replay carrying a body — so a captured
        # `Content-Length: 99` over 2 bytes, or a `Content-Length:  0004  ` written with
        # obfuscating OWS, was rewritten to the "correct" value and the operator scored a
        # verdict on a request gori never sent. A capture is evidence; only `-d` makes it a
        # draft. (A capture TRUNCATED mid-body is re-framed earlier, by
        # `FlowRequest.resync_truncated_head` — not here.)
        if !explicit_cl && !has_te && body_override
          cl_idx = new_lines.index { |(l, _)| line_name.call(l).compare("Content-Length", case_insensitive: true) == 0 }
          if cl_idx
            line, eol = new_lines[cl_idx]
            new_lines[cl_idx] = {"#{line_name.call(line)}: #{final_body.size}", eol}
          else
            new_lines << {"Content-Length: #{final_body.size}", request_eol}
          end
        end

        # Sync Host from --target, UNLESS the user set an explicit `-H "Host: …"` — a
        # host-header-confusion / vhost test deliberately pairs --target (where to connect)
        # with a different claimed Host, so that override must win.
        if (override = target_override) && !custom_headers.has_key?("host") && !dropped.includes?("host")
          # Expanded, like every other override here: `Repeater::Plan` expands `--target` for
          # the DIAL, so a `$HOST` left literal in the derived `Host:` header would send a
          # request whose claimed authority disagreed with the socket it went down.
          scheme_part, host_part, port_part = Repeater::FlowRequest.parse_target(Env.expand(override))
          # FlowRequest.authority, not a local formula: the two it replaced were both wrong.
          # This one omitted `wss` from the default-port test, so a `wss://h` target — which
          # parse_target resolves to port 443 — got `Host: h:443` while the TUI wrote `Host: h`
          # for the same session. It also never re-bracketed an IPv6 literal (parse_target
          # returns it bracket-free), emitting the malformed `Host: ::1:8443`.
          host_hdr_val = Repeater::FlowRequest.authority(scheme_part, host_part, port_part)
          host_idx = new_lines.index { |(l, _)| line_name.call(l).compare("Host", case_insensitive: true) == 0 }
          if host_idx
            line, eol = new_lines[host_idx]
            new_lines[host_idx] = {"#{line_name.call(line)}: #{host_hdr_val}", eol}
          else
            new_lines << {"Host: #{host_hdr_val}", request_eol}
          end
        end

        # Re-emit each line with ITS OWN terminator. Re-terminating everything as CRLF would
        # promote a captured bare-LF head — the front-end/back-end desync primitive the store
        # keeps byte-exact — into an ordinary conformant request, i.e. quietly stop being the
        # test the operator asked to replay, on a path whose whole point is faithfulness.
        new_head_str = String.build do |io|
          io << request_line << request_eol
          new_lines.each { |(l, eol)| io << l << eol }
          io << head_terminator
        end

        # The post-expansion Content-Length resync (a `$KEY` in the body changes its length, and
        # the CL above was framed over the pre-expansion bytes) happens in `Repeater::Plan`,
        # gated by the `explicit_cl` flag returned here.
        {new_head_str.to_slice + final_body, explicit_cl}
      end

      # A head split into {line, the terminator that followed it} pairs, so a rebuild can put
      # every line back on the ending it arrived with. The captured head may be CRLF, bare-LF
      # or MIXED (each is a real request-smuggling shape), and `String#split("\r\n")` — what
      # this replaced — could see only the first of the three.
      private def self.head_lines(head : String) : Array({String, String})
        out = [] of {String, String}
        pos = 0
        while pos < head.size
          nl = head.index('\n', pos)
          unless nl
            out << {head[pos..], ""} # no terminator at all — the head just ends
            break
          end
          line = head[pos, nl - pos]
          out << (line.ends_with?('\r') ? {line.rchop, "\r\n"} : {line, "\n"})
          pos = nl + 1
        end
        out
      end

      # Refuse a flow replay whose DIAL TUPLE still names a variable that resolves to nothing.
      #
      # `-H` and `-b` are no longer checked: they are WIRE BYTES, and a `$NAME` with no value
      # is a literal string on the wire everywhere now (see `Env::Escape`) — `-H 'X-Filter:
      # $where'` is a Mongo operator the operator meant to send. `--target` and `--sni` keep
      # the refusal for the reason `Repeater::Plan#refuse_unresolved` gives: `$` is not a legal
      # byte in a hostname, and a literal one there comes back as an OUT-OF-SCOPE refusal
      # naming a gate that was never the problem.
      private def self.refuse_unresolved_overrides(target_override : String?,
                                                   sni_override : String?) : Nil
        names = [] of String
        target_override.try { |t| names.concat(Env.unresolved(t, deferred: nil)) }
        sni_override.try { |s| names.concat(Env.unresolved(s, deferred: nil)) }
        names.uniq!
        return if names.empty?
        abort "gori run repeater: unresolved env #{Env.token_list(names)} in --target/--sni — " \
              "set it with `gori run project env set KEY value`, or remove the token. " \
              "(A token in the request bytes, in -H or in -b is sent literally; only the dial " \
              "target is checked.)"
      end

      # Say that `FlowRequest.build` turned the capture's absolute-form request line into
      # origin-form. ONE line, because on a plaintext-HTTP capture it fires on EVERY use of
      # that flow (a proxy client always sends absolute-form) and a paragraph there is noise
      # the operator learns to skip. It still has to be said: the same rewrite silently
      # defuses a routing / cache-poisoning / SSRF probe recorded from a DIRECT send, and
      # nothing on the row tells the two apart.
      #
      # Shared because `Built#rewrote_request_line` was computed at all thirteen call sites
      # and read at exactly one — the classic "a guard wired at one call site" shape. Every
      # `gori run` command that seeds itself from a flow now reports it; `--keep-request-line`
      # exists on the two doors where the stored line is the whole message (`gori run repeater
      # <flow-id>` and `repeater create`, which persists the rewrite into the session row so
      # no later flag can recover it).
      #
      # DEFERRED, since #1389: this only STASHES the line, and `say_request_line_rewrite` prints
      # it at the moment the run first puts the rewritten request on the wire. Printed as soon
      # as the flow was read, it sat in front of every refusal the command then made (a scope
      # gate, a fuzz template with no positions, a dead target) — about bytes that never went
      # out, on every run of every script replaying a proxy capture. A run that aborts first now
      # never says it; one that sends always does, once. `repeater create` says it at once
      # (`now: true`): it WRITES the rewrite into the session row, so the fact is final there.
      protected def self.warn_request_line_rewrite(built : Repeater::FlowRequest::Built,
                                                   prefix : String,
                                                   remedy : String = "--keep-request-line keeps it",
                                                   *, now : Bool = false) : Nil
        return unless built.rewrote_request_line
        @@request_line_note = "#{prefix}: note: request line rewritten to origin-form " \
                              "(absolute-form is a proxy artifact; #{remedy})"
        say_request_line_rewrite if now
      end

      @@request_line_note : String? = nil

      # Print the stashed rewrite note, once per process. Called where each command starts
      # sending; a no-op when nothing was rewritten.
      protected def self.say_request_line_rewrite : Nil
        return unless note = @@request_line_note
        @@request_line_note = nil
        STDERR.puts note
      end

      # `repeater send -H/-b` (#1384): the stored request with this send's header edits merged in,
      # by the flow replay's merge (`build_single_flow_request`) — first same-named line replaced,
      # later duplicates dropped, every other byte kept. NOT expanded here: a session is a draft
      # and `Plan` expands the whole request once (or not at all under `--verbatim`), so an
      # expansion here would run twice over a value that itself looks like a token.
      # Answers whether one of the edits pinned Content-Length, which the plan then leaves alone.
      # The request one `repeater send` carries, and whether `-H` pinned its Content-Length:
      # `--grpc-field` first, then `-H`. The field set resyncs a Content-Length the edit outdated,
      # so running it after `-H` overwrote a deliberately-wrong `-H "Content-Length: 999"` (P7).
      # Called with the store open: it published the `.proto` schema the field names resolve by.
      # The same `Protobuf::Edit.set` the TUI's add-field prompt and MCP `grpc_fields` call.
      def self.per_send_request(request : Bytes, headers : Array(String),
                                grpc_fields : Array(String), expand : Bool = false) : {Bytes, Bool} | String
        unless grpc_fields.empty?
          edited = Repeater::GrpcFields.apply(request, grpc_fields)
          return edited if edited.is_a?(String)
          request = edited
        end
        session_header_overrides(request, headers, expand)
      end

      GRPC_FIELD_HELP = "gRPC: set or ADD a field on the unary request message for this send, or remove one with -PATH (repeatable, applied in order; " \
                        "the spec `repeater send --grpc-field` takes). Re-compressed and reframed"

      # `--grpc-field` on a one-shot send (`gori run send`, `gori run repeater <flow-id>`): the
      # same `Repeater::GrpcFields.apply` as `repeater send` and MCP `send_request{grpc_fields}`.
      # After `open_store`, which published the `.proto` schema the names resolve by.
      private def self.grpc_fields_or_abort(request : Bytes, specs : Array(String), prefix : String) : Bytes
        edited = Repeater::GrpcFields.apply(request, specs)
        abort "#{prefix}: --grpc-field #{edited}" if edited.is_a?(String)
        edited
      end

      # The bytes `repeater send` carries for session `row`, whether a `-H` pinned their CL, and
      # whether the row is evidence (#1670) — or the `--grpc-field` refusal. Raises `PlanError`
      # for an operator value naming an `$ENV` var with no value.
      #
      # Evidence is asked of the STORED row: an unedited flow seed replays its captured tokens
      # literally, as the tab does, and this send's own `--path`/`-H`/`-b` are then the only
      # operator bytes in it, so their `$ENV` expands here, as on a flow replay.
      def self.session_send_request(store : Store, row : Store::RepeaterRecord, path_override : String?,
                                    headers : Array(String), grpc_fields : Array(String),
                                    verbatim : Bool) : {Bytes?, Bool, Bool} | String
        evidence = Repeater::DraftMarkers.evidence?(store, row)
        own = evidence && !verbatim
        req = if p = path_override
                Repeater::FlowRequest.replace_request_target(row.request, own ? Repeater::UrlRequest.expand(p) : p)
              else
                row.request
              end
        return {nil, false, evidence} unless req
        built = per_send_request(req, headers, grpc_fields, expand: own)
        return built if built.is_a?(String)
        {built[0], built[1], evidence}
      end

      # The names an evidence session's send keeps literal at the send seam: the capture's own,
      # the TUI's per-name rule (`RepeaterView#evidence_send_literals`), so a `$BIND`/`$GEN` this
      # send's `-H`/`-b`/`--path` added resolves like any draft's. nil for a draft.
      def self.seed_send_literals(rec : Store::RepeaterRecord, evidence : Bool) : Set(String)?
        evidence ? Env.literal_keys(String.new(rec.request)) : nil
      end

      # `expand`: the session is evidence, so the plan will not expand it and the operator's own
      # `-H` values expand here (`build_single_flow_request`). A draft leaves them to the plan.
      private def self.session_header_overrides(request : Bytes, headers : Array(String),
                                                expand : Bool = false) : {Bytes, Bool}
        return {request, false} if headers.empty?
        boundary = Env.head_body_boundary(request)
        build_single_flow_request(request[0, boundary], request[boundary..], headers, nil, nil, expand: expand)
      end

      # `UrlRequest.expand` over one operator-typed per-send value, aborting with the plan's
      # sentence when it names an `$ENV.X` with no value (#1666).
      private def self.expand_override(text : String, prefix : String) : String
        Repeater::UrlRequest.expand(text)
      rescue ex : Repeater::PlanError
        repeater_plan_abort(prefix, ex)
      end

      # nil when `-X METHOD` is a method the request line can carry; the refusal otherwise. The
      # builder's own check (`UrlRequest.check_method`), so a flow replay refuses exactly what
      # `gori run send -X` refuses: an empty method, or one that would split the request line.
      def self.replay_method_error(method : String) : String?
        Repeater::UrlRequest.check_method(method)
        nil
      rescue ex : Gori::Error
        "-X/--method: #{ex.message}"
      end

      private def self.combine_head_body(head : Bytes, body : Bytes) : Bytes
        body.empty? ? head : head + body
      end

      private def self.cmd_repeater_single(args : Array(String)) : Nil
        proj = ProjectFlags.new
        target_override : String? = nil
        sni_override : String? = nil
        # nil = follow the capture. `--http2` was the ONLY version flag, so an h2-captured
        # flow was pinned to h2 forever here — `--target http://…` still sent the h2 preface
        # at a cleartext origin and reported "unexpected EOF mid-frame" rather than a missing
        # flag. MCP has done the downgrade since `http2:false` landed and the TUI has ^V;
        # this was the one surface that could not run the h1-vs-h2 back-end comparison.
        http2_override : Bool? = nil
        insecure = false
        do_diff = false
        format = :text
        headers = [] of String
        removed_headers = [] of String
        # `-d` pieces, joined with `&` as curl joins them; nil-when-empty below.
        data = [] of String
        cookies = [] of String
        method_override : String? = nil
        verbatim = false
        record_history = false
        save_as_repeater = false
        apply_rules = false
        allow_unscoped = false
        keep_request_line = false
        slot : String? = nil
        timeout : Time::Span? = nil
        sse = SseFlags.new
        tls_preset : String? = nil
        path_override : String? = nil
        headers_only = false
        max_body : Int32? = nil
        grpc_fields = [] of String

        positional = parse_args(args, "gori run repeater") do |p|
          p.banner = "Usage: gori run repeater <flow-id> [options]\n\n" \
                     "Re-send a captured flow. Or manage repeater sessions:\n" \
                     "#{repeater_subcommand_rows.join { |(n, d)| "  gori run #{n.ljust(18)} #{d}\n" }}\n" \
                     "#{EVIDENCE_LINK_HELP}\n\n" \
                     "Options (single-flow replay):"
          project_options(p, proj, "read")
          p.on("--target=URL", "Send to this origin (scheme://host[:port]) instead of the captured one; path/query kept (see --path)") { |v| target_override = v }
          p.on("--path=TARGET", PATH_OVERRIDE_HELP) { |v| path_override = v }
          p.on("--http2", "Force HTTP/2 (default follows how the flow was captured)") { http2_override = agree(http2_override, true, "--http1/--http2") }
          p.on("--http1", "Force HTTP/1.1 — downgrades an h2-captured flow (default follows how the flow was captured)") { http2_override = agree(http2_override, false, "--http1/--http2") }
          p.on("--no-http2", "Alias for --http1") { http2_override = agree(http2_override, false, "--http1/--http2") }
          p.on("--sni=HOST", "TLS SNI override") { |v| sni_override = v }
          p.on("--tls-preset=NAME", TLS_PRESET_HELP) { |v| tls_preset = v }
          p.on("--timeout=SEC", "Per-operation connect + idle timeout (seconds)") { |v| timeout = parse_count(v, "--timeout").seconds }
          sse_options(p, sse, Repeater::StreamBound::SEND)
          p.on("-k", "--insecure-upstream", "Do not verify the upstream TLS certificate") { insecure = true }
          p.on("--diff", "Diff the new response against the captured one") { do_diff = true }
          p.on("-XMETHOD", "--method=METHOD", "Replace the captured request's method (the rest of the request line is kept)") { |v| method_override = v }
          p.on("-HHEADER", "--header=HEADER", "Custom header to overwrite/add. Repeat the SAME name to send duplicate header lines. An explicit Content-Length is honored verbatim (no auto-resync) for CL-mismatch testing") { |v| headers << v }
          p.on("--rm-header=NAME", "Delete every header with this name (repeatable). Removing Content-Length suppresses the auto-resync; removing Host suppresses the --target sync") { |v| removed_headers << v }
          p.on("-dDATA", "--data=DATA", REPLAY_DATA_HELP) { |v| data << v }
          p.on("--body=BODY", "Alias for -d/--data") { |v| data << v }
          p.on("-bCOOKIE", "--cookie=COOKIE", REPLAY_COOKIE_HELP) { |v| cookies << v }
          p.on("--verbatim", "Send your overrides EXACTLY: no token expansion ($ENV.KEY, $BIND.NAME, $GEN.*) in -H/-d/-b/--path, and on HTTP/2 no field-name lowercasing. The captured bytes are never expanded either way; --target is still expanded (it names where to dial)") { verbatim = true }
          p.on("--record-history", "Also write the request + response to History as a new flow, and print its id (default: off)") { record_history = true }
          p.on("--save-as-repeater", "Also save this request + response as a new Repeater session, and print its id") { save_as_repeater = true }
          p.on("--apply-rules", APPLY_RULES_HELP) { apply_rules = true }
          p.on("--keep-request-line", "Send the stored request line as-is — do not rewrite an absolute-form line (\"GET http://h/p\") to origin-form") { keep_request_line = true }
          p.on("--slot=NAME", "Send as this SESSION SLOT — its header overlay, and its binding table for $BIND.NAME tokens (bare syntax: $NAME)") { |v| slot = v.strip }
          p.on("--allow-unscoped", "Send even if the target is outside the project scope (the Sandbox still applies)") { allow_unscoped = true }
          p.on("--headers-only", HEADERS_ONLY_HELP) { headers_only = true }
          p.on("--max-body=BYTES", MAX_BODY_HELP) { |v| max_body = parse_count(v, "--max-body") }
          p.on("--grpc-field PATH=VALUE", GRPC_FIELD_HELP) { |v| grpc_fields << v }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end
        refresh_verify_upstream(!insecure)
        id = take_flow_id(positional, "repeater")
        cap = body_cap(headers_only, max_body, "gori run repeater")
        if err = output_diff_error(cap, do_diff) || path_override_error(path_override)
          abort "gori run repeater: #{err}"
        end
        body_override = data.empty? ? nil : data.join('&')
        # `-b` is sugar for a `-H 'Cookie: …'` that replaces the captured one — refused beside
        # an explicit `-H Cookie`, like `gori run send` does.
        cookie = cookie_header_value(cookies, headers)
        abort "gori run repeater: #{cookie.message}" if cookie.is_a?(SendArgError)
        headers += ["Cookie: #{cookie}"] if cookie
        if (m = method_override) && (err = replay_method_error(m))
          abort "gori run repeater: #{err}"
        end

        # get_flow loads all the BLOBs, so the store can close before the send. Also
        # cheaply probe whether a repeater SESSION shares this id (get_repeater reads
        # no response BLOBs) — only when the flow exists — to warn about the ambiguity.
        project = resolve_read_project(proj.name, proj.db)
        store = open_store(project, read_only: true)
        # HostOverrides.load snapshots rows into memory (connect_address never re-touches the
        # store), so it's safe to load here and use after the store closes.
        detail, session_collision, host_overrides = begin
          d = store.get_flow(id)
          {d, d ? !store.get_repeater(id).nil? : false, Gori::HostOverrides.load(store)}
        ensure
          store.close
        end
        abort "gori run repeater: no flow ##{id}" unless detail
        # Judged by the method that will go out: a replay rarely passes `-X`, and an old
        # `-b BODY` script replaying a captured POST would otherwise swap its Cookie unsaid.
        if note = cookie_as_body_note(cookies, method_override || detail.row.method, !body_override.nil?)
          STDERR.puts "gori run repeater: #{note.sub("with no body", "(the captured body is unchanged)")}"
        end
        # After `open_store` (which installs `Env.layer`) and before the plan: `Repeater::Sender`
        # reads the active slot at the seam, so this has to be set before anything builds bytes.
        activate_slot(slot, "gori run repeater")

        # `repeater list` prints session ids in the same bare `#N` form as flow ids
        # (separate 1-based counters), so a bare id here is ambiguous — we always mean
        # the FLOW. Point at `repeater send` for the saved session.
        if session_collision
          STDERR.puts "gori run repeater: a saved repeater session also has id #{id}; " \
                      "`gori run repeater #{id}` replays FLOW ##{id}. To replay the session instead, use `gori run repeater send #{id}`."
        end

        # A WebSocket flow can't be replayed by a one-shot HTTP send: this path would only
        # re-issue the handshake and report the answer to it, exchanging zero frames (a
        # silently misleading "success"). Refuse with an actionable pointer rather than
        # handing it to the plain h1/h2 engines, which don't do the RFC 6455 framed exchange.
        #
        # The test is `Store::FlowDetail#websocket?` — "did this flow OPEN a socket" — and not
        # the `status == 101 && upgrade_request?` pair it replaced (#742). That pair asked the
        # right question with only the HTTP/1.1 vocabulary for it: an RFC 8441 extended CONNECT
        # has no `Upgrade:` header to find and is answered `200`, so a WebSocket captured over
        # h2 (#733) fell through both halves and got exactly the handshake-only replay this
        # refusal exists to prevent. `websocket?` covers both handshakes and, because it still
        # requires the ANSWER (101 / 2xx), it keeps letting through the two cases that must not
        # be refused: a handshake the origin rejected, and a non-WebSocket 101 (#736) whose
        # transcript holds only gori's own `[gori] …` notice about the opaque upgrade.
        if detail.websocket?
          # ONE piece of advice for both transports now: `WsEngine` re-opens an RFC 8441
          # extended CONNECT as readily as an RFC 6455 upgrade (#733), so the session route
          # leads somewhere for either. It used to fork here and tell an h2 operator there was
          # nothing to replay their socket with.
          abort "gori run repeater: flow ##{id} is a WebSocket session — `gori run repeater` only " \
                "re-sends the handshake and captures the answer to it, not the framed messages. " \
                "Create a repeater from it (`gori run repeater create --flow=#{id}`) and replay it " \
                "with `gori run repeater send <id>` for a real framed exchange."
        end

        # The captured request body was capped at CAPTURE_MAX; FlowRequest.build re-syncs the
        # Content-Length to the stored bytes so the request stays well-formed, but warn that
        # the resent body differs from what the origin originally received.
        if detail.request_body_truncated?
          cap_mib = Settings.effective_capture_max_mib
          STDERR.puts "gori run repeater: request body was truncated at the #{cap_mib} MiB capture cap — resending the stored (shorter) body with a corrected Content-Length"
        elsif Repeater::FlowRequest.request_short_of_framing?(detail.request_head, detail.request_body)
          # A capture that never completed can hold a Content-Length larger than the body it
          # actually stored — the client hung up mid-upload. Replay is byte-exact now (a
          # stored CL is evidence, not a draft), which is right when that mismatch IS the
          # probe and a trap when it is just a dead client: the origin will sit waiting for
          # bytes that no longer exist. The truncation branch above cannot cover this — it
          # keys on the CAPTURE CAP column, which a mid-upload abort never sets. So say it,
          # rather than quietly picking one of the two intentions.
          #
          # The trigger is the REQUEST being short of the framing IT declares, computed from
          # the stored head and body. It used to be `row.state.error? || row.state.aborted?`,
          # which is the whole FLOW's state and is set by response-side failures too — so the
          # warning fired on essentially every flow whose response failed (the exact
          # population an operator replays), on bodyless GETs with no Content-Length at all,
          # and its advice would have destroyed the test case if followed. The state is worth
          # saying; it just is not the fact.
          STDERR.puts "gori run repeater: flow ##{id}'s stored request body is shorter than the framing " \
                      "its head declares (flow state: #{detail.row.state}) — the Content-Length / chunked " \
                      "framing is resent verbatim, so the origin may wait for bytes that no longer exist. " \
                      "Use -d/--data to reframe, or --rm-header Content-Length to send without one."
        end

        # A stored absolute-form request line is a PROXY artifact on a proxy capture and the
        # PAYLOAD on a flow recorded from a direct send (routing / cache-poisoning / SSRF
        # probes are written that way), and nothing on the row tells the two apart. So the
        # rewrite stays the default — every plaintext-HTTP capture needs it — but it is now
        # reported, and `--keep-request-line` turns it off.
        built = begin
          Repeater::FlowRequest.build(detail, rewrite_absolute_form: !keep_request_line)
        rescue ex : Repeater::FlowRequest::PseudoHeaderHead
          abort "gori run repeater: flow ##{id} cannot be replayed over HTTP/1.1 — #{ex.message}"
        end
        warn_request_line_rewrite(built, "gori run repeater")

        # `--grpc-field` before `-H`, as `repeater send` orders them (`per_send_request`).
        raw_bytes = grpc_fields_or_abort(built.bytes, grpc_fields, "gori run repeater")
        # `Env.head_body_boundary`, not a hand-rolled CRLFCRLF scan: a captured head may be
        # terminated with bare LFs, which is a front-end/back-end desync primitive gori can
        # already produce and stores byte-exact. Scanning for CRLFCRLF alone made replaying
        # one impossible and blamed the capture for it ("malformed request bytes in captured
        # flow") — a refusal that names the evidence rather than the cause (P7). The shared
        # helper answers the same question for every other surface.
        boundary = Env.head_body_boundary(raw_bytes)
        head_bytes = raw_bytes[0, boundary]
        body_bytes = raw_bytes[boundary..]

        # An unresolved `$KEY` in an operator-typed OVERRIDE is still a typo worth refusing —
        # but one in the CAPTURED bytes is evidence. OData (`$filter`/`$top`), MongoDB
        # (`$where`), `$IFS` shell probes and `$user.name` SSTI payloads all live in stored
        # heads, and the builder's blanket refusal made every one of them unreplayable while
        # offering a "remedy" (`project env set filter …`) that would have SUBSTITUTED a value
        # and sent a different request. So the check moves here, onto the drafts alone.
        refuse_unresolved_overrides(target_override, sni_override)

        wire, explicit_cl = begin
          build_single_flow_request(head_bytes, body_bytes, headers, body_override,
            target_override, removed_headers, expand: !verbatim)
        rescue ex : Repeater::PlanError
          repeater_plan_abort("gori run repeater", ex, "flow ##{id}")
        end
        # `--path` and `-X` last, over the merged wire: no other override touches the request
        # line, and the values are the operator's, so they expand like `-H`/`-d` do (the capture
        # around them does not — see `build_single_flow_request`).
        if p = path_override
          wire = Repeater::FlowRequest.replace_request_target(wire, verbatim ? p : expand_override(p, "gori run repeater")) ||
                 abort("gori run repeater: flow ##{id}'s request has no request line target to replace " \
                       "(#{request_line_preview(wire)})")
        end
        if m = method_override
          # Checked again AFTER expansion: `-X '$ENV.M'` passes the argv check above, and it is
          # the expanded value that is spliced into the request line.
          m = expand_override(m, "gori run repeater") unless verbatim
          if err = replay_method_error(m)
            abort "gori run repeater: #{err}"
          end
          wire = Repeater::FlowRequest.replace_method(wire, m) ||
                 abort("gori run repeater: flow ##{id}'s request has no request line method to replace " \
                       "(#{request_line_preview(wire)})")
        end
        outbound = project_outbound(project, allow_unscoped)
        # Copied out of the closure-captured var first — Crystal keeps that one `Bool?`.
        forced = http2_override
        use_http2 = forced.nil? ? built.http2 : forced
        plan = begin
          Repeater::Plan.build(Repeater::PlanOptions.new([wire],
            target: target_override, default_target: built.target,
            http2: use_http2, sni: sni_override.presence || built.sni,
            auto_content_length: false, resync_cl_after_expansion: !explicit_cl,
            # These bytes are stored EVIDENCE, not a draft — see `PlanOptions#evidence?`.
            # That now includes `$KEY` expansion: `build_single_flow_request` expanded the
            # operator's OWN `-H`/`-b`/`--target` above, so nothing downstream needs to (and
            # nothing downstream can still tell the operator's bytes from the capture's).
            evidence: true,
            # …and at the send seam, per NAME (`seed_send_literals`): the capture's own `$BIND`/`$GEN`
            # stay literal while one an operator `-H` added resolves. `--verbatim` resolves none.
            evidence_literals: verbatim ? nil : Env.literal_keys(String.new(raw_bytes)),
            # `--verbatim`: the h2 encoder keeps the field-name case the operator typed.
            preserve_field_case: verbatim,
            verify: !insecure, timeout: timeout, overrides: host_overrides,
            tls_preset: tls_preset, sse: sse.bound(Repeater::StreamBound::SEND)), outbound)
        rescue ex : Repeater::PlanError
          repeater_plan_abort("gori run repeater", ex)
        end
        # Before the gate and the History write — see `gori run send`.
        applied_rules = false
        plan, applied_rules = apply_request_rules(plan, project) if apply_rules
        # Layer 1 (include list) BEFORE Layer 2 — mirrors fuzz/mine/sequence and MCP send_gate.
        abort_if_out_of_scope!(outbound, plan, "gori run repeater")
        abort_if_blocked!(plan, "gori run repeater")
        say_request_line_rewrite
        sent_at = Time.utc.to_unix_ms * 1000_i64
        # Taken ONCE and sent as-is, so a `--record-history` flow holds the bytes that went out.
        budget = plan.admit # the budget's slot before the mint, so a rate wait cannot age a `$GEN` value
        wire_sent = budget_wire(plan, budget)
        result = budget ? Repeater::Engine.error(budget, Time.instant) : plan.send_wire(wire_sent, admitted: true)
        outbound.close

        # Decode the response body once for TEXT display (--diff / plain print); only
        # build the diff lines when --diff asked for them (decoding the captured
        # baseline isn't free for large bodies). The JSON path decodes independently
        # inside emit_body_json, from the raw head+body, to match MCP's contract.
        new_body, _ = decode_body(result.head, result.body)
        diff = nil.as(Array(Repeater::DiffLine)?)
        diff_capped = false
        if do_diff
          # `--headers-only --diff` compares the two HEADS: status and headers, no body lines.
          orig = message_lines(detail.response_head, cap.omit ? nil : display_body(detail.response_head, detail.response_body))
          fresh = message_lines(result.head, cap.omit ? nil : new_body)
          diff_capped = Repeater::Diff.truncated?(orig, fresh)
          diff = Repeater::Diff.lines(orig, fresh)
        end

        # A NEW flow, like `gori run send --record-history` (#1384): the replay is its own
        # exchange, and the captured flow it came from stays the evidence it was.
        recorded = record_history && !budget ? record_repeater_send_to_history(plan, wire_sent, result, sent_at, nil, project) : nil
        history_write = recorded.nil? ? nil : WriteOutcome.new(recorded.as?(String))
        repeater_write = nil.as(WriteOutcome?)
        repeater_response_write = nil.as(WriteOutcome?)
        saved_repeater_id = nil.as(Int64?)
        if save_as_repeater
          saved = save_send_as_repeater(plan, plan.bytes, result, id, project, "gori run repeater")
          saved_repeater_id = saved.id
          repeater_write = saved.save_write
          repeater_response_write = saved.response_write
        end
        # The target as it went out (after `Env.expand`), read the way the scope gate read it —
        # not the `--path` argument, whose `$ENV.ID` the wire no longer carries.
        emit_repeater_result(result, new_body, diff, format, diff_capped, recorded.as?(Int64),
          tls_preset: sent_tls_preset(plan), history_write: history_write,
          cap: cap, request_target: path_override && Gori::Outbound.request_target(plan.bytes),
          applied_rules: applied_rules, saved_repeater_id: saved_repeater_id,
          repeater_write: repeater_write, repeater_response_write: repeater_response_write)
        if why = history_write.try(&.error)
          STDERR.puts "gori run repeater: #{why}#{project_write_warning_tail}"
        end
        # `--slot NAME` on a single-flow replay: the same drain the session-send path takes,
        # because it is the same overlay seam and a notice fixed on one of the two would drift.
        report_unbound_slot_overlay("gori run repeater")
        exit 1 unless result.ok?
      end

      # `--apply-rules` (#1384): the project's REQUEST-side Match & Replace rules over the built
      # plan, through the one implementation MCP's `apply_rules` uses. Its own WRITABLE open,
      # because a rule that fails (a hook, a refused binding) records an event row, and the
      # store the plan was read from is already closed by the time a plan exists.
      private def self.apply_request_rules(plan : Repeater::Plan, project : Project) : {Repeater::Plan, Bool}
        with_store(project) do |store|
          Repeater::RequestRules.apply(plan, Gori::Rules.load(store))
        end
      end

      # The parsed status line and headers, beside the raw `head` a script would otherwise have
      # to parse itself (#1384). Unredacted, like `head`: this is the operator's own send, not
      # an inventory listing. A header value is REMOTE bytes, so an 8-bit octet gets the same
      # `_lossy` + `_base64` pair `head` carries rather than a silent U+FFFD.
      private def self.repeater_response_fields(j : JSON::Builder, response : Proxy::Codec::RawResponse) : Nil
        j.field "reason", response.reason.scrub
        j.field "http_version", response.version.scrub
        j.field "headers" do
          j.array do
            response.headers.each do |header|
              j.object do
                j.field "name", header.name.scrub
                j.field "value", header.value.scrub
                unless header.value.valid_encoding?
                  j.field "value_lossy", true
                  j.field "value_base64", Base64.strict_encode(header.value.to_slice)
                end
              end
            end
          end
        end
      end

      private def self.repeater_json(result : Repeater::Result, diff : Array(Repeater::DiffLine)?,
                                     diff_capped : Bool = false, recorded_flow_id : Int64? = nil,
                                     tls_preset : String? = nil, *,
                                     response_write : WriteOutcome? = nil,
                                     history_write : WriteOutcome? = nil,
                                     cap : BodyCap = BodyCap.new,
                                     request_target : String? = nil,
                                     applied_rules : Bool = false,
                                     saved_repeater_id : Int64? = nil,
                                     repeater_write : WriteOutcome? = nil,
                                     repeater_response_write : WriteOutcome? = nil,
                                     via : String? = nil) : String
        JSON.build do |j|
          j.object do
            j.field "ok", result.ok?
            # `gori run send` only: the egress the request took (`Proxy::Upstream.via`, #1625).
            j.field("via", via) if via
            # `--path` only: the request-target this send put on the wire (expanded), so a
            # script looping over paths can key each object by the one it reached.
            j.field("path", request_target) if request_target
            # WHICH HANDSHAKE produced this response (#844) — absent when no override was in
            # play, so two sends differing only in `--tls-preset` are told apart from the JSON
            # alone. The name gori APPLIED, not a JA3 it can prove: see `--tls-preset`'s help.
            j.field("tls_preset", tls_preset) if tls_preset
            # `--apply-rules` only, and only when a rule CHANGED the bytes — MCP's field.
            j.field("match_replace_applied", true) if applied_rules
            # `--record-history` only. Present ⇒ the send is on the record under this id; absent
            # ⇒ it was not recorded. Inside THIS object, never a second one: `--format json` has
            # always emitted exactly one, and a trailing object breaks every `jq` consumer.
            j.field("recorded_flow_id", recorded_flow_id) if recorded_flow_id
            # …and WHY it is absent when `--record-history` WAS passed: `history_saved: false`
            # plus the sentence. Without it a null id read the same as the flag not given.
            emit_write_outcome_json(j, "history_saved", "history_error", history_write)
            j.field("saved_repeater_id", saved_repeater_id) if saved_repeater_id
            emit_write_outcome_json(j, "repeater_saved", "repeater_save_error", repeater_write)
            emit_write_outcome_json(j, "repeater_response_saved", "repeater_response_error", repeater_response_write)
            # Whether the SESSION ROW now holds this response (present only when a write was
            # attempted, i.e. `ok`). `false` means the next `send --diff` would diff against
            # the PREVIOUS response — see `WriteOutcome`.
            emit_write_outcome_json(j, "response_saved", "response_save_error", response_write)
            j.field "status", result.response.try(&.status)
            j.field "duration_us", result.duration_us
            # A send failure quotes origin bytes — see `Output.json_captured`. The WS sibling
            # above takes the same treatment.
            CLI::Output.json_captured(j, "error", result.error)
            # The MCP `send_request` error contract (#1384): the coarse kind, the code and
            # the flag a retry policy branches on, so a script tells a timeout from a refused
            # connection without matching the sentence above. One classifier for both surfaces
            # (`Repeater::SendError`).
            unless result.ok?
              kind = Repeater::SendError.kind(result.error)
              code = Repeater::SendError.code(kind)
              j.field "error_kind", kind
              j.field "error_code", code
              j.field "retryable", Repeater::SendError.retryable?(code, result.delivered?)
              j.field "delivered", result.delivered?
            end
            if response = result.response
              repeater_response_fields(j, response)
            end
            # …and WHY it is incomplete. `incomplete` alone conflates an origin that closed
            # early with gori's own capture ceiling; a reader that assumed the first blamed
            # the target for something gori did.
            emit_incomplete_json(j, result)
            # The head is REMOTE bytes: an 8-bit octet in a header value (the standard
            # header-parsing probe) does not survive `scrub`, which replaces it with U+FFFD.
            # `gori run repeater` writes no History row and has no `--format raw`, so those
            # octets were unrecoverable from this surface entirely. Same shape MCP uses for a
            # lossy value (`<field>_lossy` + `<field>_base64`) so the two agree.
            j.field "head", scrub(result.head)
            unless String.new(result.head).valid_encoding?
              j.field "head_lossy", true
              j.field "head_base64", Base64.strict_encode(result.head)
            end
            emit_body_json(j, "body", result.head, result.body, result.incomplete?, cap)
            if d = diff
              j.field "changed_lines", Repeater::Diff.change_count(d)
              # Sibling to changed_lines, exactly as `cmd_compare`'s JSON carries it: a
              # consumer reading changed_lines: 0 has to be able to tell "identical" from
              # "compared only the first MAX_LINES lines".
              j.field "truncated", diff_capped
              # The diff itself, in `compare --format json`'s row shape: the text mode prints
              # it, and the JSON used to carry only the count.
              j.field "diff" do
                j.array { d.each { |dl| j.object { j.field "kind", dl.kind.to_s.downcase; j.field "text", dl.text } } }
              end
            end
          end
        end
      end
    end
  end
end
