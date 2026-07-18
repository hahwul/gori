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
          p.banner = "Usage: gori run repeater <flow-id> [options]\n\n" \
                     "Re-send a captured flow. Or manage repeater sessions:\n" \
                     "  gori run repeater list                List repeater sessions in the workbench\n" \
                     "  gori run repeater create [options]    Create a repeater session (--flow/--request-file/--request-raw)\n\n" \
                     "Options (single-flow replay):"
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
    end
  end
end
