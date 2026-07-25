# `gori run repeater` — re-send a captured flow, or list/create repeater sessions.
module Gori
  module CLI
    module Run
      private def self.cmd_repeater(args : Array(String)) : Nil
        sub = args.first?
        if sub == "list"
          cmd_repeater_list(args[1..])
          return
        elsif sub == "create"
          cmd_repeater_create(args[1..])
          return
        elsif sub == "send"
          cmd_repeater_send(args[1..])
          return
        elsif sub == "minimize"
          cmd_repeater_minimize(args[1..])
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
                    j.field "tags", r.tags
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

      # The optional post-insert labels (insert_repeater takes neither). Split out of
      # cmd_repeater_create, which is already over the cyclomatic-complexity bar.
      private def self.apply_repeater_metadata(store : Store, id : Int64,
                                               name : String?, tags : String?) : Nil
        store.set_repeater_name(id, Env.mask_secrets(name)) if name
        store.set_repeater_tags(id, Env.mask_secrets(tags).strip.presence) if tags
      end

      private def self.cmd_repeater_create(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        target : String? = nil
        request_file : String? = nil
        request_raw : String? = nil
        name : String? = nil
        tags : String? = nil
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
          p.on("--tags=TAGS", "Free-text tags for grouping tabs (the TUI subtab label)") { |v| tags = v }
          p.on("--http2", "Use HTTP/2 (default: false)") { http2 = true; http2_given = true }
          p.on("--no-auto-cl", "Do not auto-calculate Content-Length header") { auto_cl = false }
          p.on("--flow=ID", "Optional original flow ID this repeater stems from") { |v| flow_id = parse_flow_id(v, "gori run repeater create") }
          p.on("--sni=HOST", "TLS SNI override") { |v| sni = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run repeater create: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run repeater create: missing value for #{f}" }
        end
        parser.parse(args)

        req_content = ""
        if file = request_file
          abort "gori run repeater create: request-file '#{file}' is not readable" unless File.exists?(file) && !File.directory?(file)
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
            # Only seed the request from the flow when the user didn't hand one in: --flow
            # doubles as provenance (the flow_id column) for a custom --request-raw/-file,
            # so an explicit request must NOT be silently overwritten by the flow's bytes.
            req_content = String.new(built.bytes) if request_file.nil? && request_raw.nil?
            if tgt_str.empty?
              bt = built.target
              tgt_str = bt ? bt : ""
            end

            unless http2_given
              http2 = built.http2
            end

            if detail.row.status == 101
              is_ws = true
              out_frames = store.ws_messages(fid).select { |m| m.direction == "out" }
              ws_messages = out_frames.select(&.text?).map { |m| String.new(m.payload).scrub }
              # A repeater SESSION persists outbound messages as editable text lines
              # (update_repeater_ws_messages stores Array(String) as opcode 1), so a binary
              # outbound frame can't round-trip through the session store and would vanish from
              # every later `repeater send` replay — warn instead of dropping it silently.
              if (dropped = out_frames.size - ws_messages.size) > 0
                STDERR.puts "gori run repeater create: #{dropped} binary outbound WebSocket frame#{dropped == 1 ? "" : "s"} dropped — the repeater session store keeps text messages only, so #{dropped == 1 ? "it is" : "they are"} not replayable"
              end
            end
          end

          abort "gori run repeater create: --target is required" if tgt_str.empty?

          pos = store.repeaters_meta.size

          id = store.insert_repeater(
            target: Env.mask_secrets(tgt_str),
            request: Env.mask_secrets(req_content).to_slice,
            http2: http2,
            auto_cl: auto_cl,
            flow_id: flow_id,
            position: pos.to_i32,
            sni: sni
          )

          abort "gori run repeater create: failed to create repeater session" if id == 0

          apply_repeater_metadata(store, id, name, tags)

          if is_ws && !ws_messages.empty?
            store.update_repeater_ws_messages(id, ws_messages)
          end

          puts "Repeater session ##{id} created successfully."
        ensure
          store.close
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
      private def self.session_plan_options(rec : Store::RepeaterRecord, insecure : Bool,
                                            overrides : Gori::HostOverrides?) : Repeater::PlanOptions
        Repeater::PlanOptions.new([rec.request],
          default_target: rec.target, http2: rec.http2?, sni: rec.sni,
          auto_content_length: rec.auto_content_length?, verify: !insecure,
          overrides: overrides)
      end

      # `gori run repeater`'s wording for a builder refusal. `Repeater::Plan` reports a
      # machine-readable `Reason` precisely so each surface can phrase it in its own idiom —
      # the CLI names its flags, where the TUI names its hotkeys and MCP names its JSON
      # fields. Exhaustive on `Reason` so a new builder failure cannot reach the operator as
      # a bare exception message.
      private def self.repeater_plan_abort(prefix : String, ex : Repeater::PlanError,
                                           context : String? = nil) : NoReturn
        where = context ? " for #{context}" : ""
        detail = ex.detail
        abort(case ex.reason
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
        end)
      end

      # Persist a repeater SESSION's last response (V11) so it survives a reopen and a later
      # `repeater list` / `--diff` see it — parity with the TUI (repeater_controller.cr
      # #drain_results). Reopens the store because `send` closed it before the (slow) dial.
      # Callers gate on `result.ok?`: a failed resend must not wipe a good stored response.
      private def self.persist_repeater_response(id : Int64, head : Bytes, body : Bytes?, error : String?,
                                                 duration_us : Int64, project_name : String?, db_path : String?) : Nil
        store = open_store(resolve_read_project(project_name, db_path))
        begin
          store.update_repeater_response(id, head, body, error, duration_us)
        ensure
          store.close
        end
      end

      # `gori run repeater send <repeater-id>` — replay a saved repeater SESSION (as
      # opposed to a bare id, which replays a History FLOW). Honors the session's
      # target / http2 / sni / auto_content_length toggle.
      private def self.cmd_repeater_send(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        insecure = false
        do_diff = false
        format = :text
        ws_messages = [] of String
        idle_ms : Int64? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run repeater send <repeater-id> [options]\n\n" \
                     "Replay a saved repeater SESSION (ids from `gori run repeater list`).\n" \
                     "A WebSocket-upgrade session performs a real RFC 6455 framed exchange."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("-k", "--insecure-upstream", "Do not verify the upstream TLS certificate") { insecure = true }
          p.on("--diff", "Diff the new response against the session's last stored response") { do_diff = true }
          p.on("--message=TEXT", "WebSocket: outbound text message (repeatable; replaces the session's stored messages)") { |v| ws_messages << v }
          p.on("--idle-ms=N", "WebSocket: server-silence timeout after the first inbound frame (100-60000, default 3000)") { |v| idle_ms = parse_count(v, "--idle-ms").to_i64 }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run repeater send: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run repeater send: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run repeater send: missing <repeater-id>\n#{parser}" if positional.empty?
        abort "gori run repeater send: too many arguments (expected one <repeater-id>, got: #{positional.join(" ")})" if positional.size > 1
        id = positional[0].to_i64? || abort "gori run repeater send: invalid repeater id '#{positional[0]}'"

        # get_repeater_full loads the response BLOBs too (needed for --diff), so the
        # store can close before the send — same lifetime pattern as the flow path.
        store = open_store(resolve_read_project(project_name, db_path))
        rec, host_overrides = begin
          {store.get_repeater_full(id), Gori::HostOverrides.load(store)}
        ensure
          store.close
        end
        abort "gori run repeater send: no repeater session ##{id}" unless rec
        # The scope decision every active send passes through. `gori run repeater` dials
        # Repeater::Engine/H2Engine/WsEngine directly, bypassing the proxy's own gate, so
        # Sandbox mode's "blocks ALL out-of-scope traffic" promise lives here.
        outbound = project_outbound(project_name, db_path, false)

        plan = begin
          Repeater::Plan.build(session_plan_options(rec, insecure, host_overrides), outbound)
        rescue ex : Repeater::PlanError
          repeater_plan_abort("gori run repeater send", ex, "session ##{id}")
        end

        if plan.websocket?
          cmd_repeater_send_ws(id, plan, project_name, db_path, idle_ms, ws_messages, outbound, format)
          return
        end

        abort_if_blocked!(plan, "gori run repeater send")
        result = plan.send
        outbound.close

        new_body, _ = decode_body(result.head, result.body)
        diff =
          if do_diff && (base_head = rec.response_head)
            orig = message_lines(base_head, display_body(base_head, rec.response_body))
            Repeater::Diff.lines(orig, message_lines(result.head, new_body))
          end
        emit_repeater_result(result, new_body, diff, format)
        persist_repeater_response(id, result.head, result.body, result.error, result.duration_us, project_name, db_path) if result.ok?
        exit 1 unless result.ok?
      end

      # Execute a WebSocket repeater SESSION: a fresh RFC 6455 handshake, the
      # session's outbound messages (or `--message` overrides), and the inbound
      # transcript. Mirrors MCP send_websocket (src/gori/mcp/tools/send.cr) so a
      # script gets the same exchange whether it drives gori via CLI or MCP.
      private def self.cmd_repeater_send_ws(id : Int64, plan : Repeater::Plan, project_name : String?,
                                            db_path : String?, idle_ms : Int64?,
                                            message_override : Array(String),
                                            outbound : Gori::Outbound, format : Symbol) : Nil
        abort_if_blocked!(plan, "gori run repeater send")

        store = open_store(resolve_read_project(project_name, db_path))
        out_messages = begin
          ws_out_messages(store, id, message_override)
        ensure
          store.close
        end

        idle = (idle_ms || 3000_i64).clamp(100_i64, 60_000_i64).milliseconds
        result = plan.send_ws(out_messages, idle)
        outbound.close

        # Persist ONLY on success — parity with the TUI (repeater_controller#drain_results):
        # a later failed resend must not wipe a good stored handshake/response.
        if result.ok?
          store2 = open_store(resolve_read_project(project_name, db_path))
          begin
            store2.update_repeater_response(id, result.handshake_head, Bytes.empty, result.error, result.duration_us)
          ensure
            store2.close
          end
        end

        emit_ws_result(id, result, format)
        exit 1 unless result.ok?
      end

      # The session's outbound messages: `--message` overrides when given (each
      # sent as a text frame), else the WS messages stored on the repeater (the
      # ones with direction "out"), env-expanded like MCP send_websocket.
      private def self.ws_out_messages(store : Store, id : Int64, override : Array(String)) : Array(Repeater::WsEngine::OutMsg)
        return override.map { |t| Repeater::WsEngine::OutMsg.new(1, Env.expand(t).to_slice) } unless override.empty?
        store.ws_messages_for_repeater(id).compact_map do |m|
          next nil unless m.direction == "out"
          payload = m.text? ? Env.expand(String.new(m.payload).scrub).to_slice : m.payload
          Repeater::WsEngine::OutMsg.new(m.opcode, payload)
        end
      end

      private def self.emit_ws_result(id : Int64, result : Repeater::WsEngine::Result, format : Symbol) : Nil
        if format == :json
          puts(JSON.build do |j|
            j.object do
              j.field "repeater_id", id
              j.field "upgraded", result.upgraded?
              j.field "duration_us", result.duration_us
              j.field "close_code", result.close_code
              j.field "error", result.error
              j.field "note", result.note
              j.field "messages" do
                j.array do
                  result.messages.each do |m|
                    j.object do
                      j.field "direction", m.direction
                      j.field "opcode", m.opcode
                      if m.opcode == 1
                        j.field "text", scrub(m.payload)
                      else
                        j.field "binary", true
                        j.field "size", m.payload.size
                      end
                    end
                  end
                end
              end
            end
          end)
        elsif result.ok?
          STDERR.puts "→ WebSocket upgraded=#{result.upgraded?} in #{CLI::Output.human_us(result.duration_us)}#{result.close_code ? " (close #{result.close_code})" : ""}"
          STDERR.puts "note: #{result.note}" if result.note
          result.messages.each do |m|
            arrow = m.direction == "out" ? "→" : "←"
            if m.opcode == 1
              puts "#{arrow} #{scrub(m.payload)}"
            else
              puts "#{arrow} [binary frame, #{m.payload.size} bytes]"
            end
          end
        else
          STDERR.puts "repeater failed: #{result.error}"
        end
      end

      # Render a replay Result (text or json, optional diff), shared by the flow-id
      # replay and the session-send paths so the two render identically. Caller has
      # already decoded `new_body` and built `diff` (the diff baseline differs per
      # path); caller owns the exit code.
      private def self.emit_repeater_result(result : Repeater::Result, new_body : Bytes?,
                                            diff : Array(Repeater::DiffLine)?, format : Symbol) : Nil
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
      # Returns the PRE-expansion wire plus whether an explicit CL was pinned. Env expansion and
      # the post-expansion Content-Length resync are `Repeater::Plan`'s job — `explicit_cl` is
      # exactly the session store's `auto_content_length` toggle inverted, so both ways of
      # pinning a CL reach the builder as one knob instead of two open-coded branches.
      private def self.build_single_flow_request(head_bytes : Bytes, body_bytes : Bytes,
                                                 headers : Array(String), body_override : String?,
                                                 target_override : String?) : {Bytes, Bool}
        head_str = String.new(head_bytes)
        first_crlf = head_str.index("\r\n") || head_str.size
        request_line = head_str[0, first_crlf]
        # Header lines between the request line and the terminating blank line, each verbatim.
        raw_lines = head_str[first_crlf..].split("\r\n").reject(&.empty?)

        # -H overrides: lower-name → value, plus the flag-cased name in flag order for appends.
        custom_headers = {} of String => String
        custom_order = [] of {String, String}
        headers.each do |h_str|
          next unless h_str.includes?(':')
          name, _, val = h_str.partition(':')
          next if name.strip.empty?
          lname = name.strip.downcase
          custom_order << {lname, name.strip} unless custom_headers.has_key?(lname)
          custom_headers[lname] = val.strip
        end

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
        new_lines = [] of String
        raw_lines.each do |line|
          name = line_name.call(line)
          lname = name.strip.downcase
          if !lname.empty? && custom_headers.has_key?(lname)
            next if applied.includes?(lname)
            applied << lname
            new_lines << "#{name}: #{custom_headers[lname]}"
          else
            new_lines << line
          end
        end
        custom_order.each do |(lname, orig)|
          next if applied.includes?(lname)
          new_lines << "#{orig}: #{custom_headers[lname]}"
        end

        final_body = if b_over = body_override
                       b_over.to_slice
                     else
                       body_bytes
                     end

        has_te = new_lines.any? { |l| line_name.call(l).compare("Transfer-Encoding", case_insensitive: true) == 0 }
        # RFC 7230 §3.3.3 forbids sending Transfer-Encoding and Content-Length together.
        # When the original request was chunked (TE present, no override), keep its wire
        # framing byte-exact and don't inject a Content-Length. When the body is replaced
        # via -b, drop Transfer-Encoding and self-frame the new bytes with Content-Length.
        if has_te && body_override
          new_lines.reject! { |l| line_name.call(l).compare("Transfer-Encoding", case_insensitive: true) == 0 }
          has_te = false
        end
        # An explicit `-H "Content-Length: N"` is an intentional CL, so it is honored VERBATIM.
        # When present, skip BOTH the auto-resync below and the post-expansion resync so neither
        # overwrites the user's value — the header the override loop already wrote into new_lines
        # stands.
        explicit_cl = custom_headers.has_key?("content-length")
        has_cl = new_lines.any? { |l| line_name.call(l).compare("Content-Length", case_insensitive: true) == 0 }
        if !explicit_cl && !has_te && (body_override || has_cl || final_body.size > 0)
          cl_idx = new_lines.index { |l| line_name.call(l).compare("Content-Length", case_insensitive: true) == 0 }
          if cl_idx
            new_lines[cl_idx] = "#{line_name.call(new_lines[cl_idx])}: #{final_body.size}"
          else
            new_lines << "Content-Length: #{final_body.size}"
          end
        end

        # Sync Host from --target, UNLESS the user set an explicit `-H "Host: …"` — a
        # host-header-confusion / vhost test deliberately pairs --target (where to connect)
        # with a different claimed Host, so that override must win.
        if (override = target_override) && !custom_headers.has_key?("host")
          scheme_part, host_part, port_part = Repeater::FlowRequest.parse_target(override)
          default_port = scheme_part == "https" ? 443 : 80
          host_hdr_val = port_part == default_port ? host_part : "#{host_part}:#{port_part}"
          host_idx = new_lines.index { |l| line_name.call(l).compare("Host", case_insensitive: true) == 0 }
          if host_idx
            new_lines[host_idx] = "#{line_name.call(new_lines[host_idx])}: #{host_hdr_val}"
          else
            new_lines << "Host: #{host_hdr_val}"
          end
        end

        new_head_str = String.build do |io|
          io << request_line << "\r\n"
          new_lines.each { |l| io << l << "\r\n" }
          io << "\r\n"
        end

        # The post-expansion Content-Length resync (a `$KEY` in the body changes its length, and
        # the CL above was framed over the pre-expansion bytes) happens in `Repeater::Plan`,
        # gated by the `explicit_cl` flag returned here.
        {new_head_str.to_slice + final_body, explicit_cl}
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
          p.banner = "Usage: gori run repeater <flow-id> [options]\n\n" \
                     "Re-send a captured flow. Or manage repeater sessions:\n" \
                     "  gori run repeater list                List repeater sessions in the workbench\n" \
                     "  gori run repeater create [options]    Create a repeater session (--flow/--request-file/--request-raw)\n" \
                     "  gori run repeater send <id> [opts]    Replay a saved repeater SESSION (not a flow id)\n\n" \
                     "Options (single-flow replay):"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--target=URL", "Send to this origin (scheme://host[:port]) instead of the captured one; path/query kept") { |v| target_override = v }
          p.on("--http2", "Force HTTP/2 (default follows how the flow was captured)") { force_h2 = true }
          p.on("--sni=HOST", "TLS SNI override") { |v| sni_override = v }
          p.on("-k", "--insecure-upstream", "Do not verify the upstream TLS certificate") { insecure = true }
          p.on("--diff", "Diff the new response against the captured one") { do_diff = true }
          p.on("-HHEADER", "--header=HEADER", "Custom header to overwrite/add (repeatable). An explicit Content-Length is honored verbatim (no auto-resync) for CL-mismatch testing") { |v| headers << v }
          p.on("-bBODY", "--body=BODY", "Request body override") { |v| body_override = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run repeater: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run repeater: missing value for #{f}" }
        end
        parser.parse(args)
        id = take_flow_id(positional, "repeater")

        # get_flow loads all the BLOBs, so the store can close before the send. Also
        # cheaply probe whether a repeater SESSION shares this id (get_repeater reads
        # no response BLOBs) — only when the flow exists — to warn about the ambiguity.
        store = open_store(resolve_read_project(project_name, db_path))
        # HostOverrides.load snapshots rows into memory (connect_ip never re-touches the
        # store), so it's safe to load here and use after the store closes.
        detail, session_collision, host_overrides = begin
          d = store.get_flow(id)
          {d, d ? !store.get_repeater(id).nil? : false, Gori::HostOverrides.load(store)}
        ensure
          store.close
        end
        abort "gori run repeater: no flow ##{id}" unless detail

        # `repeater list` prints session ids in the same bare `#N` form as flow ids
        # (separate 1-based counters), so a bare id here is ambiguous — we always mean
        # the FLOW. Point at `repeater send` for the saved session.
        if session_collision
          STDERR.puts "gori run repeater: a saved repeater session also has id #{id}; " \
                      "`gori run repeater #{id}` replays FLOW ##{id}. To replay the session instead, use `gori run repeater send #{id}`."
        end

        # A WebSocket flow can't be replayed by a one-shot HTTP send: this path would only
        # re-issue the upgrade request and report the 101 handshake, exchanging zero frames
        # (a silently misleading "success"). Detect an upgrade that actually completed
        # (status 101 + a WebSocket upgrade request) and refuse with an actionable pointer,
        # rather than the plain h1/h2 engines that don't do the RFC 6455 framed exchange.
        if detail.row.status == 101 && Repeater::WsEngine.upgrade_request?(String.new(detail.request_head))
          abort "gori run repeater: flow ##{id} is a WebSocket session — `gori run repeater` only re-sends the HTTP upgrade and captures the 101 handshake, not the framed messages. Create a repeater from it (`gori run repeater create --flow=#{id}`) and replay it with `gori run repeater send <id>` for a real framed exchange."
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

        wire, explicit_cl = build_single_flow_request(head_bytes, body_bytes, headers, body_override, target_override)
        outbound = project_outbound(project_name, db_path, false)
        plan = begin
          Repeater::Plan.build(Repeater::PlanOptions.new([wire],
            target: target_override, default_target: built.target,
            http2: force_h2 || built.http2, sni: sni_override.presence || built.sni,
            auto_content_length: !explicit_cl, verify: !insecure,
            overrides: host_overrides), outbound)
        rescue ex : Repeater::PlanError
          repeater_plan_abort("gori run repeater", ex)
        end
        abort_if_blocked!(plan, "gori run repeater")
        result = plan.send
        outbound.close

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

        emit_repeater_result(result, new_body, diff, format)
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
    end
  end
end
