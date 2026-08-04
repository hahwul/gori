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
        elsif sub == "h2"
          cmd_repeater_h2fields(args[1..])
          return
        end

        cmd_repeater_single(args)
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
        db_path : String? = nil
        project_name : String? = nil
        target : String? = nil
        fields_file : String? = nil
        insecure = false
        allow_unscoped = false
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run repeater h2 --target URL --fields FILE [options]\n\n" \
                     "Send a field-native HTTP/2 request (exact HPACK field list, no h1-text carrier).\n" \
                     "FILE is JSON: a [[name,value],…] array, or {\"fields\":[…],\"body\":\"…\"}."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("-tURL", "--target=URL", "Dial origin (scheme://host[:port]); :authority/:scheme in the fields may differ") { |v| target = v }
          p.on("--fields=FILE", "JSON file with the ordered HPACK field list (and optional body)") { |v| fields_file = v }
          p.on("-k", "--insecure-upstream", "Do not verify the upstream TLS certificate") { insecure = true }
          p.on("--allow-unscoped", "Send even if the target is outside the project scope (Sandbox/exclude still apply)") { allow_unscoped = true }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run repeater h2: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run repeater h2: missing value for #{f}" }
        end
        parser.parse(args)

        tgt = target
        abort "gori run repeater h2: --target is required" if tgt.nil? || tgt.empty?
        file = fields_file
        abort "gori run repeater h2: --fields is required" if file.nil? || file.empty?
        abort "gori run repeater h2: --fields file '#{file}' is not readable" unless File.exists?(file) && !File.directory?(file)
        fields, body = parse_h2_fields_file(File.read(file))

        overrides = begin
          store = open_store(resolve_read_project(project_name, db_path))
          begin
            Gori::HostOverrides.load(store)
          ensure
            store.close
          end
        end
        outbound = project_outbound(project_name, db_path, allow_unscoped)
        plan = begin
          Repeater::Plan.build(Repeater::PlanOptions.new(
            h2_fields: fields, h2_body: body, target: tgt,
            http2: true, verify: !insecure, overrides: overrides), outbound)
        rescue ex : Repeater::PlanError
          repeater_plan_abort("gori run repeater h2", ex)
        end
        abort_if_out_of_scope!(outbound, plan, "gori run repeater h2")
        abort_if_blocked!(plan, "gori run repeater h2")
        result = plan.send
        outbound.close

        new_body, _ = decode_body(result.head, result.body)
        emit_repeater_result(result, new_body, nil, format)
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
      #
      # These two KEEP `mask_secrets`, unlike the target and the SNI beside them: a name and a
      # tag are the TUI's tab and subtab captions and never reach a socket, so masking them is
      # a display choice with no wire consequence. The rule is "does this field become bytes
      # the origin sees", not "did the operator type it".
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
        ws_keep_key = false
        ws_http_only = false
        keep_request_line = false

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run repeater create [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-tURL", "--target=URL", "Target URL (scheme://host[:port])") { |v| target = v }
          p.on("-fFILE", "--request-file=FILE", "Read raw HTTP request from FILE") { |v| request_file = v }
          p.on("-rRAW", "--request-raw=RAW", "Verbatim raw HTTP request string") { |v| request_raw = v }
          p.on("--name=NAME", "Custom repeater tab name") { |v| name = v }
          p.on("--tags=TAGS", "Free-text tags for grouping tabs (the TUI subtab label)") { |v| tags = v }
          p.on("--http2", "Use HTTP/2 (default: false, or how --flow was captured)") { http2 = true; http2_given = true }
          # The other half of the toggle: without it a session cloned from an h2 flow
          # (`--flow=N`) inherited h2 and `repeater send` had no way to override it, so an
          # h2 capture could never be replayed as h1 from the CLI at all.
          p.on("--http1", "Use HTTP/1.1 — overrides an h2-captured --flow (alias: --no-http2)") { http2 = false; http2_given = true }
          p.on("--no-http2", "Alias for --http1") { http2 = false; http2_given = true }
          p.on("--no-auto-cl", "Do not auto-calculate Content-Length header") { auto_cl = false }
          p.on("--flow=ID", "Optional original flow ID this repeater stems from") { |v| flow_id = parse_flow_id(v, "gori run repeater create") }
          p.on("--keep-request-line", "With --flow: store the flow's request line as-is — do not rewrite an absolute-form line (\"GET http://h/p\") to origin-form") { keep_request_line = true }
          p.on("--sni=HOST", "TLS SNI override") { |v| sni = v }
          p.on("--ws-keep-key", "WebSocket: send the request's own Sec-WebSocket-Key instead of a fresh one (lets an absent/short/duplicate/non-base64 key be tested)") { ws_keep_key = true }
          p.on("--ws-http-only", "WebSocket: treat this session as plain HTTP — the upgrade handshake is sent as an ordinary request and the 101 read as a response, instead of the framed exchange. Stored on the session (the TUI's ^V); `repeater send --http` is the per-send form") { ws_http_only = true }
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
          ws_messages = [] of Store::WsOutMessage
          is_ws = false

          if fid = flow_id
            detail = store.get_flow(fid)
            abort "gori run repeater create: no flow ##{fid} to clone" unless detail
            # The rewrite is PERSISTED here, so this is the one door where it cannot be
            # undone later: `repeater send --verbatim` sends the stored row, and by then the
            # absolute-form line is gone. `gori run repeater <flow-id>` grew
            # `--keep-request-line` for the direct replay; this is the same flag on the
            # workbench door, and the rewrite is reported either way (see `Built`).
            built = Repeater::FlowRequest.build(detail, rewrite_absolute_form: !keep_request_line)
            warn_request_line_rewrite(built, "gori run repeater create")
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

          pos = store.repeaters_meta.size

          # The REQUEST, the TARGET and the SNI are all stored as authored. Same seam and same
          # reason as `MCP::Tools#stored_request`: `mask_secrets` here rewrote an author's live
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
          # this makes the two agree. See `MCP::Tools#wire_field`, which argues it at length.
          id = store.insert_repeater(
            target: tgt_str,
            request: req_content.to_slice,
            http2: http2,
            auto_cl: auto_cl,
            flow_id: flow_id,
            position: pos.to_i32,
            sni: sni,
            ws_keep_key: ws_keep_key,
            ws_http_only: ws_http_only
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

      # The Layer-1 (include-list) gate for the hand-authored repeater send paths. `abort_if_blocked!`
      # above (plan.refusal → Outbound#send_block) is Layer 2 (Sandbox/exclude) ONLY; without this the
      # configured project scope was silently inert for `gori run repeater` and there was no
      # --allow-unscoped waiver, unlike the sibling fuzz/mine/sequence/discover CLIs and MCP's
      # send_gate (#406). DESIGN.md §3 lists repeater as gated on BOTH layers.
      private def self.abort_if_out_of_scope!(outbound : Gori::Outbound, plan : Repeater::Plan, prefix : String) : Nil
        verdict = repeater_scope_verdict(outbound, plan)
        return unless verdict.blocked?
        outbound.close
        abort "#{prefix}: #{plan.host} is out of the project scope — #{Gori::Outbound.remedy(verdict, "--allow-unscoped")}"
      end

      # The Layer-1 verdict `abort_if_out_of_scope!` acts on, split out so it can be asserted
      # without the process-exiting `abort`. Returns the whole Verdict, not just `blocked?`,
      # because the REMEDY differs by why it was refused (an EXCLUDE match cannot be undone
      # by adding an include rule).
      private def self.repeater_scope_verdict(outbound : Gori::Outbound, plan : Repeater::Plan) : Gori::Outbound::Verdict
        target = (bytes = plan.requests.first?) ? Gori::Outbound.request_target(bytes) : "/"
        outbound.check_request(plan.scheme, plan.host, target)
      end

      private def self.repeater_out_of_scope?(outbound : Gori::Outbound, plan : Repeater::Plan) : Bool
        repeater_scope_verdict(outbound, plan).blocked?
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
                                            overrides : Gori::HostOverrides?,
                                            verbatim : Bool = false) : Repeater::PlanOptions
        Repeater::PlanOptions.new([rec.request],
          default_target: rec.target, http2: rec.http2?, sni: rec.sni,
          expand_request: !verbatim,
          # …and on an h2 session it used to change NOTHING the encoder does: the flag
          # promised "the stored bytes EXACTLY" while `H2Engine` still lowercased every field
          # name. Field case is the one normalization left on that path, so this is what
          # `--verbatim` means for h2.
          preserve_field_case: verbatim,
          auto_content_length: !verbatim && rec.auto_content_length?, verify: !insecure,
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
        in Repeater::PlanError::Reason::UnresolvedEnv
          "#{prefix}: #{env_unresolved_error(detail, where)}"
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
        # `--message` and `--message-frame` share ONE list so their relative ORDER is the send
        # order. A WebSocket exchange is a sequence, and two lists merged afterwards would
        # silently reorder a fragment ahead of the CONT that finishes it.
        ws_messages = [] of Store::WsOutMessage
        idle_ms : Int64? = nil
        allow_unscoped = false
        verbatim = false
        ws_keep_key = false
        # nil = use the session's stored setting; true = this send is plain HTTP whatever it says.
        # There is no `--websocket` counterpart: the stored default IS WebSocket unless the
        # operator turned it off, so the only direction that needs a per-send override is this one.
        http_only : Bool? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run repeater send <repeater-id> [options]\n\n" \
                     "Replay a saved repeater SESSION (ids from `gori run repeater list`).\n" \
                     "A WebSocket-upgrade session performs a real RFC 6455 framed exchange."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("-k", "--insecure-upstream", "Do not verify the upstream TLS certificate") { insecure = true }
          p.on("--diff", "Diff the new response against the session's last stored response") { do_diff = true }
          p.on("--allow-unscoped", "Send even if the target is outside the project scope (Sandbox/exclude still apply)") { allow_unscoped = true }
          p.on("--verbatim", "Send the stored bytes EXACTLY: no $VAR expansion, no bare-LF→CRLF promotion, no Content-Length resync, no HTTP/2→1.1 version fix, and on h2 no field-name lowercasing") { verbatim = true }
          p.on("--message=TEXT", "WebSocket: outbound text message (repeatable; replaces the session's stored messages)") { |v| ws_messages << Store::WsOutMessage.text(v) }
          p.on("--message-frame=SPEC", "WebSocket: one outbound frame with an explicit shape (repeatable; mixes with --message in order). SPEC is comma-separated key=value: opcode=text|bin|cont|close|ping|pong|<0-15>, fin=0|1, rsv=0-7, mask=0|1, mask_key=<hex>, len=<declared length>, and one of hex=|b64=|text= (text= runs to the end of SPEC). Example: opcode=close,hex=03ea6279650a") { |v| ws_messages << parse_message_frame(v) }
          p.on("--ws-keep-key", "WebSocket: send the request's own Sec-WebSocket-Key instead of a fresh one (overrides the session's stored setting for this send)") { ws_keep_key = true }
          p.on("--idle-ms=N", "WebSocket: server-silence timeout after the first inbound frame (100-60000, default 3000)") { |v| idle_ms = parse_count(v, "--idle-ms").to_i64 }
          p.on("--http", "WebSocket: send the upgrade handshake as an ordinary HTTP request and print the response, instead of performing the framed exchange (overrides the session's stored setting for this send). The bytes are unchanged — this selects the engine, not a rewrite") { http_only = true }
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
        outbound = project_outbound(project_name, db_path, allow_unscoped)

        plan = begin
          Repeater::Plan.build(session_plan_options(rec, insecure, host_overrides, verbatim), outbound)
        rescue ex : Repeater::PlanError
          repeater_plan_abort("gori run repeater send", ex, "session ##{id}")
        end

        # Layer 1 (include list) BEFORE Layer 2 — mirrors fuzz/mine/sequence and MCP send_gate.
        abort_if_out_of_scope!(outbound, plan, "gori run repeater send")

        # The session's stored `ws_http_only` (the TUI's `^V`) is the default, and `--http`
        # overrides it for this send. Both mean the same thing: dial the h1/h2 engine and read
        # the 101 as a response. `Engine` already treats 101 as terminal and bodyless, and
        # `ConnPool` already refuses to park an upgraded socket, so nothing else has to change.
        if plan.websocket? && !(http_only.nil? ? rec.ws_http_only? : http_only)
          # `rec.flow_id` IS the provenance test, the same one the engine tabs and the h1
          # flow-replay path make: only a `--flow` / MCP `flow_id` seed sets it, and only a
          # seed puts CAPTURED frames in `ws_messages`. A session built from `--request-raw`
          # or MCP `ws_out_messages` leaves it nil and its rows stay the operator's draft.
          cmd_repeater_send_ws(id, plan, project_name, db_path, idle_ms, ws_messages, outbound, format,
            verbatim, ws_keep_key || rec.ws_keep_key?, !rec.flow_id.nil?)
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
                                            message_override : Array(Store::WsOutMessage),
                                            outbound : Gori::Outbound, format : Symbol,
                                            verbatim : Bool, keep_key : Bool,
                                            evidence : Bool = false) : Nil
        abort_if_blocked!(plan, "gori run repeater send")

        store = open_store(resolve_read_project(project_name, db_path))
        out_messages = begin
          ws_out_messages(store, id, message_override, verbatim, evidence)
        ensure
          store.close
        end

        idle = (idle_ms || 3000_i64).clamp(100_i64, 60_000_i64).milliseconds
        result = plan.send_ws(out_messages, idle, keep_key)
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
          payload = m.text? && !verbatim && !seeded ? Env.expand(String.new(m.payload)).to_slice : m.payload
          Repeater::WsEngine::OutMsg.new(m.opcode, payload, m.shape, seeded)
        end
      end

      # Whether a stored WebSocket row is a gori ADVISORY rather than a frame the socket
      # carried. A diagnostic is not traffic: round 3's parked-control notice was written on
      # the `out` direction, which is exactly what a repeater seed reads, so replaying a
      # flow captured by that build put gori's own 242-byte sentence on the wire as a TEXT
      # message the client never sent. The row is fixed at the source; this is the seed-side
      # guard, so an older capture already in a project cannot replay one either — and two
      # PRE-EXISTING markers are seedable today regardless of that fix, because they stand in
      # for a real frame at its position and legitimately keep its opcode and direction: the
      # ping-flood marker (opcode 9, and under §5.5's 125-byte cap, so it would replay as a
      # real PING) and `forward_oversized_frame`'s. Hence NO opcode filter here — the prefix
      # is the whole test, and an opcode-1 test would have let the PING through.
      #
      # Byte-level: a notice row is compared, never decoded. `scrub` on a payload that is not
      # valid UTF-8 would rewrite the bytes being tested.
      def self.ws_notice_row?(opcode : Int32, payload : Bytes) : Bool
        Gori::Proxy::WS.notice?(payload)
      end

      # The `out` frames of a captured flow, minus gori's own advisory rows, and HOW MANY
      # were dropped. Every seed reader goes through this rather than repeating the filter,
      # and none of them may go quiet about it: a seed that silently holds fewer frames than
      # the capture is the same class of problem as one that holds an extra.
      def self.ws_seed_rows(rows : Array(Store::WsMessage)) : {Array(Store::WsMessage), Int32}
        out = rows.select { |m| m.direction == "out" }
        kept = out.reject { |m| ws_notice_row?(m.opcode, m.payload) }
        {kept, out.size - kept.size}
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
          end)
        elsif result.ok?
          STDERR.puts "→ WebSocket upgraded=#{result.upgraded?} in #{CLI::Output.human_us(result.duration_us)}#{result.close_code ? " (close #{result.close_code})" : ""}"
          STDERR.puts "note: #{result.note}" if result.note
          STDERR.puts "truncated: #{result.truncated}" if result.truncated
          result.messages.each { |m| puts ws_transcript_line(m) }
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
          STDERR.puts "→ #{result.response.try(&.status) || "?"} in #{CLI::Output.human_us(result.duration_us)}#{result.incomplete? ? " (#{incomplete_reason(result, result.timed_out?)})" : ""}"
          if d = diff
            print_diff(d)
            n = Repeater::Diff.change_count(d)
            STDERR.puts(n == 0 ? "no differences" : "#{n} line#{n == 1 ? "" : "s"} changed")
          else
            print_message_text(result.head, new_body, result.body)
          end
        else
          STDERR.puts "repeater failed: #{result.error}"
          # An error and a RESPONSE are not exclusive. The engine deliberately keeps the head
          # for exactly this case (`engine.cr` — "must NOT throw the head away as a bare error
          # string"), and two shapes reach here with both: a framing error over a head gori
          # read fine (conflicting Content-Lengths), and an h2 stream RST after a partial
          # response — status 200, real head, real body, plus a named RST code. `--format json`
          # and MCP render both halves; the default text view printed one sentence and dropped
          # the head, so the answer that IS the finding was visible on every rendering except
          # the default one.
          unless result.head.empty?
            STDERR.puts "→ #{result.response.try(&.status) || "?"} in #{CLI::Output.human_us(result.duration_us)}#{result.incomplete? ? " (#{incomplete_reason(result, result.timed_out?)})" : ""}"
            print_message_text(result.head, new_body, result.body)
          end
        end
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
      # `self.` and public so MCP renders the identical three sentences: two copies of a
      # three-way classification is how two surfaces come to disagree about one flow.
      def self.incomplete_reason(result : Repeater::Result, timed_out : Bool = false) : String
        cap = Proxy::Codec::Body::CAPTURE_READ_MAX
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
      # for `Env.expand_bindings` at the send seam.
      #
      # Returns the wire plus whether an explicit CL was pinned. `explicit_cl` is exactly the
      # session store's `auto_content_length` toggle inverted, so both ways of pinning a CL
      # reach the builder as one knob instead of two open-coded branches.
      private def self.build_single_flow_request(head_bytes : Bytes, body_bytes : Bytes,
                                                 headers : Array(String), body_override : String?,
                                                 target_override : String?,
                                                 removed_headers : Array(String) = [] of String) : {Bytes, Bool}
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
        # Header lines between the request line and the terminating blank line, each verbatim
        # and each carrying the terminator IT arrived with.
        raw_lines = entries[1..]?.try(&.reject { |(l, _)| l.empty? }) || [] of {String, String}
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
          next unless h_str.includes?(':')
          name, _, val = h_str.partition(':')
          next if name.strip.empty?
          lname = name.strip.downcase
          custom_order << {lname, name} unless custom_headers.has_key?(lname)
          # The VALUE is the operator's draft, so it expands; the NAME is not (a `$` is not
          # a tchar, so a token there could only ever be a typo, and folding it into the
          # dedup key would make `-H '$H: a' -H 'X: b'` collide once `$H` resolved to `X`).
          (custom_headers[lname] ||= [] of String) << Env.expand(val)
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

        # `-b` is a draft too, and it expands BEFORE the Content-Length below is framed over
        # it — which is why `Repeater::Plan`'s post-expansion resync is now a no-op on this
        # path rather than the thing that quietly re-lengthed the CAPTURED body.
        final_body = if b_over = body_override
                       Env.expand(b_over).to_slice
                     else
                       body_bytes
                     end

        has_te = new_lines.any? { |(l, _)| line_name.call(l).compare("Transfer-Encoding", case_insensitive: true) == 0 }
        # RFC 7230 §3.3.3 forbids sending Transfer-Encoding and Content-Length together.
        # When the original request was chunked (TE present, no override), keep its wire
        # framing byte-exact and don't inject a Content-Length. When the body is replaced
        # via -b, drop Transfer-Encoding and self-frame the new bytes with Content-Length.
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
        # verdict on a request gori never sent. A capture is evidence; only `-b` makes it a
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
      protected def self.warn_request_line_rewrite(built : Repeater::FlowRequest::Built,
                                                   prefix : String,
                                                   remedy : String = "--keep-request-line keeps it") : Nil
        return unless built.rewrote_request_line
        STDERR.puts "#{prefix}: request line rewritten to origin-form " \
                    "(absolute-form is a proxy artifact; #{remedy})"
      end

      private def self.combine_head_body(head : Bytes, body : Bytes) : Bytes
        return head if body.empty?
        io = IO::Memory.new(head.size + body.size)
        io.write(head)
        io.write(body)
        io.to_slice
      end

      private def self.cmd_repeater_single(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
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
        body_override : String? = nil
        allow_unscoped = false
        keep_request_line = false
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run repeater <flow-id> [options]\n\n" \
                     "Re-send a captured flow. Or manage repeater sessions:\n" \
                     "  gori run repeater list                List repeater sessions in the workbench\n" \
                     "  gori run repeater create [options]    Create a repeater session (--flow/--request-file/--request-raw)\n" \
                     "  gori run repeater send <id> [opts]    Replay a saved repeater SESSION (not a flow id)\n" \
                     "  gori run repeater h2 [options]        Send a field-native HTTP/2 request (--target/--fields)\n\n" \
                     "Options (single-flow replay):"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--target=URL", "Send to this origin (scheme://host[:port]) instead of the captured one; path/query kept") { |v| target_override = v }
          p.on("--http2", "Force HTTP/2 (default follows how the flow was captured)") { http2_override = true }
          p.on("--http1", "Force HTTP/1.1 — downgrades an h2-captured flow (default follows how the flow was captured)") { http2_override = false }
          p.on("--no-http2", "Alias for --http1") { http2_override = false }
          p.on("--sni=HOST", "TLS SNI override") { |v| sni_override = v }
          p.on("-k", "--insecure-upstream", "Do not verify the upstream TLS certificate") { insecure = true }
          p.on("--diff", "Diff the new response against the captured one") { do_diff = true }
          p.on("-HHEADER", "--header=HEADER", "Custom header to overwrite/add. Repeat the SAME name to send duplicate header lines. An explicit Content-Length is honored verbatim (no auto-resync) for CL-mismatch testing") { |v| headers << v }
          p.on("--rm-header=NAME", "Delete every header with this name (repeatable). Removing Content-Length suppresses the auto-resync; removing Host suppresses the --target sync") { |v| removed_headers << v }
          p.on("-bBODY", "--body=BODY", "Request body override") { |v| body_override = v }
          p.on("--keep-request-line", "Send the stored request line as-is — do not rewrite an absolute-form line (\"GET http://h/p\") to origin-form") { keep_request_line = true }
          p.on("--allow-unscoped", "Send even if the target is outside the project scope (Sandbox/exclude still apply)") { allow_unscoped = true }
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
        # HostOverrides.load snapshots rows into memory (connect_address never re-touches the
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
                      "Use -b/--body to reframe, or --rm-header Content-Length to send without one."
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

        raw_bytes = built.bytes
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

        wire, explicit_cl = build_single_flow_request(head_bytes, body_bytes, headers, body_override, target_override, removed_headers)
        outbound = project_outbound(project_name, db_path, allow_unscoped)
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
            verify: !insecure, overrides: host_overrides), outbound)
        rescue ex : Repeater::PlanError
          repeater_plan_abort("gori run repeater", ex)
        end
        # Layer 1 (include list) BEFORE Layer 2 — mirrors fuzz/mine/sequence and MCP send_gate.
        abort_if_out_of_scope!(outbound, plan, "gori run repeater")
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
            # …and WHY it is incomplete. `incomplete` alone conflates an origin that closed
            # early with gori's own capture ceiling; a reader that assumed the first blamed
            # the target for something gori did.
            if result.incomplete?
              j.field "incomplete", true
              j.field "incomplete_reason", incomplete_reason(result, result.timed_out?)
            end
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
