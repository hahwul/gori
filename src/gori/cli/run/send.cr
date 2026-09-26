# `gori run send` — one request, without a Repeater session (#1116).
#
# Before this, a one-off request from a script was `repeater create` + `repeater send` + a temp
# file per URL, and every probe left a session behind in the TUI's sub-tab strip — a sweep of
# forty paths meant forty throwaway tabs. MCP has had the sessionless form all along
# (`send_request{url, method, headers, body}` / `{url, raw}`); this is the same send for a shell,
# built by the same code (`Repeater::UrlRequest`), dialled through the same `Repeater::Plan`, the
# project's upstream proxy, host overrides, scope and Sandbox.
module Gori
  module CLI
    module Run
      @[Subcommand("send", help: [
        {"send", "Send one request from a URL (curl-shaped) or a raw request — no Repeater session is created"},
      ])]
      private def self.cmd_send(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        url : String? = nil
        method : String? = nil
        headers = [] of String
        body : String? = nil
        body_file : String? = nil
        request_file : String? = nil
        request_raw : String? = nil
        request_stdin = false
        http2 = false
        sni : String? = nil
        tls_preset : String? = nil
        insecure = false
        timeout : Time::Span? = nil
        allow_unscoped = false
        verbatim = false
        slot : String? = nil
        record_history = false
        headers_only = false
        max_body : Int32? = nil
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run send --url URL [options]\n" \
                     "       gori run send URL [options]\n\n" \
                     "Send ONE request and print the response, without creating a Repeater session. The\n" \
                     "request is built from the URL (-X/-H/-b), or read whole from --request-file/-raw/-stdin\n" \
                     "(the URL then only names where to dial). It goes out through this project's upstream\n" \
                     "proxy, host overrides, scope and Sandbox, like every other gori send.\n\n" \
                     "  gori run send https://api.example.com/v1/items/42 -H 'Accept: application/json'\n" \
                     "  gori run send --url https://api.example.com/v1/items -X POST -b '{\"a\":1}' --record-history\n" \
                     "  gori run send --url https://api.example.com --request-file req.http --headers-only\n"
          p.on("--project=NAME", "Project whose network settings, scope and History to use (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file") { |v| db_path = v }
          p.on("--url=URL", "Absolute URL: scheme://host[:port]/path?query. With --request-*, only the origin is used") { |v| url = v }
          p.on("-XMETHOD", "--method=METHOD", "HTTP method (default GET)") { |v| method = v }
          p.on("-HHEADER", "--header=HEADER", "Request header 'Name: value' (repeatable, sent in order). Host and Content-Length are added when you leave them out") { |v| headers << v }
          p.on("-bBODY", "--body=BODY", "Request body; $ENV.KEY tokens expand (see --verbatim)") { |v| body = v }
          p.on("--body-file=FILE", "Request body read byte-for-byte from FILE, never expanded") { |v| body_file = v }
          p.on("-fFILE", "--request-file=FILE", "Send the raw HTTP request in FILE instead of building one (the URL names only where to dial)") { |v| request_file = v }
          p.on("-rRAW", "--request-raw=RAW", "Send this raw HTTP request string instead of building one") { |v| request_raw = v }
          p.on("--request-stdin", "Read the raw HTTP request from stdin (a pipe or a redirect, never a terminal)") { request_stdin = true }
          p.on("--http2", "Send over HTTP/2") { http2 = true }
          p.on("--sni=HOST", "TLS SNI override") { |v| sni = v }
          p.on("--tls-preset=NAME", TLS_PRESET_HELP) { |v| tls_preset = v }
          p.on("-k", "--insecure-upstream", "Do not verify the upstream TLS certificate") { insecure = true }
          p.on("--timeout=SEC", "Per-operation connect + idle timeout (seconds)") { |v| timeout = parse_count(v, "--timeout").seconds }
          p.on("--allow-unscoped", "Send even if the target is outside the project scope (Sandbox/exclude still apply)") { allow_unscoped = true }
          p.on("--verbatim", "Send what you typed EXACTLY: no token expansion ($ENV.KEY, $BIND.NAME, $GEN.*) in -H/-b or a raw request, no bare-LF→CRLF promotion of a raw request's head, and on HTTP/2 no field-name lowercasing. The URL is still expanded: it names where to dial") { verbatim = true }
          p.on("--slot=NAME", "Send as this SESSION SLOT — its header overlay, and its binding table for $BIND.NAME tokens") { |v| slot = v.strip }
          p.on("--record-history", "Also write the request + response to History as a flow, and print its id (default: off)") { record_history = true }
          p.on("--headers-only", HEADERS_ONLY_HELP) { headers_only = true }
          p.on("--max-body=BYTES", MAX_BODY_HELP) { |v| max_body = parse_count(v, "--max-body") }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run send: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run send: missing value for #{f}" }
        end
        parser.parse(args)
        refresh_verify_upstream(!insecure)

        # Every refusal knowable from argv alone goes ABOVE the reads: `--request-stdin` blocks
        # until EOF, and a mistake in the flags must not first drain a pipe (or hang on one).
        sources = request_sources(file: request_file, raw: request_raw, stdin: request_stdin)
        dial_url, header_pairs = send_checked_argv(url, positional, sources, method, headers,
          body, body_file, tls_preset)
        cap = body_cap(headers_only, max_body, "gori run send")
        raw_content = sources.empty? ? nil : send_raw_content(sources, request_file, request_raw, request_stdin)
        body_file_bytes = body_file.try { |f| read_input_file(f, "gori run send", noun: "body").to_slice }

        # Read before the send and closed before it, like every repeater path: the store is
        # only needed for what `open_store` installs (env, bindings, the project's network pin)
        # and for the host overrides, which are a snapshot.
        project = resolve_read_project(project_name, db_path)
        store = open_store(project, read_only: true)
        host_overrides = begin
          Gori::HostOverrides.load(store)
        ensure
          store.close
        end
        activate_slot(slot, "gori run send")

        # `-b` expands HERE, after `open_store` installed the project's env layer — before it, a
        # `$ENV.KEY` the project defines would have gone out literally. `--body-file` never
        # expands: those bytes are the body, the way MCP's `body_base64` is.
        body_bytes = body_file_bytes || body.try { |b| (verbatim ? b : Env.expand(b)).to_slice }
        built = send_built(dial_url, raw_content, method, header_pairs, body_bytes, verbatim)
        outbound = project_outbound(project_name, db_path, allow_unscoped)
        plan = begin
          # The shape MCP's `send_request{url}` hands the builder, for the reason it gives: the
          # request was expanded and framed above, so a second expansion pass would expand a
          # value that itself looks like a token, and a Content-Length resync would reframe a
          # raw request the operator framed by hand. `expand_bindings` is the one pass left for
          # the send seam, and `--verbatim` turns it off there too.
          Repeater::Plan.build(Repeater::PlanOptions.new([built.bytes],
            expand_request: false, expand_bindings: !verbatim, auto_content_length: false,
            preserve_field_case: verbatim,
            origin: Repeater::Origin.new(built.scheme, built.host, built.port),
            sni: sni, tls_preset: tls_preset, http2: http2, verify: !insecure,
            timeout: timeout, overrides: host_overrides), outbound)
        rescue ex : Repeater::PlanError
          repeater_plan_abort("gori run send", ex)
        end
        abort_if_out_of_scope!(outbound, plan, "gori run send")
        abort_if_blocked!(plan, "gori run send")
        send_and_report(plan, outbound, project, raw: !raw_content.nil?,
          record_history: record_history, format: format, cap: cap)
      end

      # The argv-only checks, in one place so every one of them runs before anything reads
      # stdin or a file: the URL, the request sources against the building flags, the preset
      # name and the `-H` lines. Returns the URL and the parsed headers, or aborts.
      private def self.send_checked_argv(url : String?, positional : Array(String), sources : Array(String),
                                         method : String?, headers : Array(String), body : String?,
                                         body_file : String?, tls_preset : String?) : {String, Array({String, String})}
        dial_url = send_url_arg(url, positional)
        abort "gori run send: #{dial_url.message}" if dial_url.is_a?(SendArgError)
        if err = send_source_error(sources, method: method, headers: headers, body: body, body_file: body_file)
          abort "gori run send: #{err}"
        end
        if err = Settings.tls_preset_error(tls_preset)
          abort "gori run send: #{err}"
        end
        pairs = send_header_pairs(headers)
        abort "gori run send: #{pairs.message}" if pairs.is_a?(SendArgError)
        {dial_url, pairs}
      end

      # The one raw request source the argv checks let through, refused when it gave no bytes —
      # an empty request cannot be sent, and an empty pipe is usually a generator that died.
      private def self.send_raw_content(sources : Array(String), file : String?, raw : String?,
                                        stdin : Bool) : String
        content = request_content(file: file, raw: raw, stdin: stdin, io: STDIN, what: "gori run send")
        abort "gori run send: the request must not be empty (#{sources.first} gave no bytes)" if content.empty?
        content
      end

      # The request, built by the builder MCP's `send_request{url}` uses. After `open_store`,
      # because the URL, the headers and a raw request expand against the project's env.
      private def self.send_built(url : String, raw : String?, method : String?,
                                  headers : Array({String, String}), body : Bytes?,
                                  verbatim : Bool) : Repeater::UrlRequest::Built
        target = Repeater::UrlRequest.target(url)
        if r = raw
          Repeater::UrlRequest.raw(target, r, verbatim)
        else
          Repeater::UrlRequest.structured(target, method, headers, body, expand: !verbatim)
        end
      rescue ex : Gori::Error
        abort "gori run send: #{ex.message}"
      end

      # Send `plan` and print what came back — the tail every repeater send shares: the History
      # record (opt-in) BEFORE the one emit, so its outcome rides inside the JSON object.
      private def self.send_and_report(plan : Repeater::Plan, outbound : Gori::Outbound, project : Project, *,
                                       raw : Bool, record_history : Bool, format : Symbol, cap : BodyCap) : Nil
        # A handshake authored here goes out as an ORDINARY request: there is no session to hold
        # the frames a real exchange would send, so its 101 (or its refusal) is the answer. Said,
        # because a 101 with nothing after it reads like an exchange that happened.
        if plan.websocket?
          STDERR.puts "gori run send: note: this request is a WebSocket handshake — sent as a plain request, " \
                      "so no frames are exchanged; for a framed exchange create a session " \
                      "(`gori run repeater create … --request-file`) and use `gori run repeater send <id>`"
        end
        sent_at = Time.utc.to_unix_ms * 1000_i64
        wire = plan.wire_bytes
        # A raw request's head the operator did not terminate — said before the origin answers,
        # like `repeater send`. A built one is always terminated.
        STDERR.puts "gori run send: #{unterminated_head_note}" if raw && !plan.http2? && !Env.head_terminated?(wire)
        result = plan.send_wire(wire)
        outbound.close

        new_body, _ = decode_body(result.head, result.body)
        recorded = record_history ? record_repeater_send_to_history(plan, wire, result, sent_at, nil, project) : nil
        recorded_flow_id = recorded.as?(Int64)
        history_write = recorded.nil? ? nil : WriteOutcome.new(recorded.as?(String))
        emit_repeater_result(result, new_body, nil, format, recorded_flow_id: recorded_flow_id,
          tls_preset: sent_tls_preset(plan), history_write: history_write, cap: cap)
        if why = history_write.try(&.error)
          STDERR.puts "gori run send: #{why}#{project_write_warning_tail}"
        end
        report_unbound_slot_overlay("gori run send")
        exit 1 unless result.ok?
      end

      # A `gori run send` argument mistake, as a value rather than an `abort`, so the argument
      # half of this command is spec-able.
      record SendArgError, message : String

      # The one URL: `--url`, or a single bare word. Two answers to "where to" are refused rather
      # than resolved by position, the same rule `--project` + `--db` follows.
      def self.send_url_arg(url : String?, positional : Array(String)) : String | SendArgError
        if positional.size > 1
          return SendArgError.new("expected one URL, got: #{positional.join(" ")} " \
                                  "(quote a URL that contains spaces or shell characters)")
        end
        if (u = url) && (bare = positional.first?)
          return SendArgError.new("--url #{u.inspect} and #{bare.inspect} both name the URL — pass one")
        end
        chosen = url || positional.first?
        return SendArgError.new("a URL is required (--url URL, or the URL as the only argument)") if chosen.nil? || chosen.empty?
        chosen
      end

      # nil when the request sources make sense together; the refusal otherwise. A raw request
      # IS the method, headers and body, so a `-X`/`-H`/`-b` beside one would have to be either
      # silently dropped or spliced into bytes the operator said to send as written.
      def self.send_source_error(sources : Array(String), *, method : String?, headers : Array(String),
                                 body : String?, body_file : String?) : String?
        if sources.size > 1
          return "#{sources.join(", ")} cannot be combined — pick one request source"
        end
        if body && body_file
          return "-b/--body and --body-file cannot be combined — pick one body"
        end
        unless sources.empty?
          built = [] of String
          built << "-X/--method" if method
          built << "-H/--header" unless headers.empty?
          built << "-b/--body" if body
          built << "--body-file" if body_file
          unless built.empty?
            return "#{sources.first} sends the request as written, so #{built.join(", ")} would be ignored — " \
                   "put them in the request, or drop #{sources.first} to have gori build it"
          end
        end
        nil
      end

      # `-H 'Name: value'` → {name, value}. The value loses its LEADING whitespace (the OWS after
      # the colon, which the builder writes back as one space) and nothing else. A line that is
      # not `Name: value` is refused here; everything the builder refuses (a non-token name, a
      # CR/LF in a value) it refuses with its own words.
      def self.send_header_pairs(headers : Array(String)) : Array({String, String}) | SendArgError
        pairs = [] of {String, String}
        headers.each do |h|
          name, sep, value = h.partition(':')
          return SendArgError.new("header #{h.inspect} rejected — write it as 'Name: value'") if sep.empty? || name.empty?
          pairs << {name, value.lstrip(" \t")}
        end
        pairs
      end
    end
  end
end
