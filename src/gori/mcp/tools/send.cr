require "json"
require "base64"
require "../../store"
require "../../host_overrides"
require "../../rules"
require "../../repeater/engine"
require "../../repeater/h2_engine"
require "../../repeater/flow_request"
require "../../flow_mapper"
require "../../proxy/codec/http1"
require "../../env"
require "../../scope"
require "../request_builder"
require "../serialize"
require "../../probe"

module Gori
  module MCP
    class Tools
      # --- action / write tools (gated) ---------------------------------------

      private def send_request(h) : Result
        save = bool_arg(h, "save_as_repeater", false)
        record_history = bool_arg(h, "record_history", true)
        include_sensitive_headers = bool_arg(h, "include_sensitive_headers", false)
        issue_id = send_issue_id(h, save)
        return issue_id if issue_id.is_a?(Result)

        built, http2, sni = build_send_request(h)
        # OPT-IN Match&Replace parity (before the scope gate + History write so the
        # recorded/effective request == the wire); byte-exact by default.
        built, applied_rules = maybe_apply_request_rules(h, built)
        # Scope gate BEFORE any outbound byte / History write: an out-of-scope
        # target is refused (nothing sent, nothing recorded) unless allow_unscoped.
        # request_target reads the target VERBATIM off the first line of `built.bytes` —
        # ABSOLUTE-FORM when the caller hand-wrote a `raw` template with a full-URL
        # request line, same as any plain-HTTP forward-proxy request — so this goes
        # through Scope.request_url rather than a naive concat (see its doc comment).
        sc = scope_check(Scope.request_url(built.scheme, built.host, request_target(built.bytes)),
          built.host, bool(h, "allow_unscoped") || false)
        return scope_blocked(sc) if sc.blocked
        recorded_flow_id = record_history ? record_outbound_request(built, http2) : nil
        verify = @verify_upstream && !(bool(h, "insecure") || false)
        result = send_built_request(built, http2, verify, sni, send_timeout(h))
        record_outbound_response(recorded_flow_id, result) if recorded_flow_id
        # Audit trail on STDERR — never STDOUT (reserved for JSON-RPC).
        Log.info { "send_request #{built.scheme}://#{built.host}:#{built.port} http2=#{http2} scope=#{sc.decision} flow_id=#{recorded_flow_id || "none"} -> #{result.ok? ? "ok" : result.error}" }

        repeater_id = persist_send_repeater(h, save, built, http2, result,
          issue_id, recorded_flow_id)

        body_cap, body_omit = body_return_opts(h)
        Result.new(send_result_json(result, recorded_flow_id, repeater_id,
          include_sensitive_headers, sc, built, http2, flow_precedence_ignored(h), body_cap, body_omit, applied_rules),
          is_error: !result.ok?)
      rescue ex : Gori::Error
        # Bad input (missing/invalid url, illegal header, …) — return a clean
        # actionable message instead of letting call()'s generic "tool error:"
        # wrapper swallow it, matching fuzz_start's FuzzArgError handling.
        Result.new(ex.message || "invalid request arguments", is_error: true)
      end

      # The request-shaping fields that a flow_id/repeater_id source overrode
      # (precedence: replaying a captured flow or a saved repeater ignores
      # url/method/headers/body/raw). Empty unless a source id is set alongside one
      # of them — so the caller can SEE what was dropped.
      private def flow_precedence_ignored(h) : Array(String)
        return [] of String unless present?(h, "flow_id") || present?(h, "repeater_id")
        {"url", "method", "headers", "body", "raw"}.select { |f| present?(h, f) }.to_a
      end

      # The request actually put on the wire, parsed back from the built bytes, so
      # a caller can confirm scheme/host/port/method/target/version independently
      # of which inputs it supplied (flow_id vs url/raw).
      private def emit_effective_request(j : JSON::Builder, built : RequestBuilder::Built, http2 : Bool) : Nil
        parts = (String.new(built.bytes).each_line.first? || "").split(' ')
        j.field "effective_request" do
          j.object do
            j.field "scheme", built.scheme
            j.field "host", built.host
            j.field "port", built.port
            j.field "method", parts[0]? || ""
            j.field "target", parts[1]? || "/"
            j.field "http_version", http2 ? "HTTP/2" : (parts[2]? || "HTTP/1.1")
          end
        end
      end

      # Resolve + validate the optional issue_id for a save-linked send. Returns
      # the id (or nil when absent), or an error Result the caller returns as-is.
      private def send_issue_id(h, save : Bool) : Int64? | Result
        issue_id = int(h, "issue_id")
        return err(id_error(h, "issue_id"), "INVALID_ARGUMENT", field: "issue_id") if issue_id.nil? && present?(h, "issue_id")
        if issue_id
          return err("issue_id requires save_as_repeater=true", "INVALID_ARGUMENT", field: "issue_id") unless save
          return not_found("no issue with id #{issue_id}") unless store.get_issue(issue_id)
        end
        issue_id
      end

      private def send_built_request(built : RequestBuilder::Built, http2 : Bool,
                                     verify_upstream : Bool, sni : String? = nil,
                                     timeout : Time::Span? = nil) : Repeater::Result
        # Honor the project's host overrides on the direct-dial path (parity with the
        # live proxy). nil/empty is behaviorally identical to no override.
        ov = HostOverrides.load(store)
        if http2
          Repeater::H2Engine.send(built.bytes, scheme: built.scheme, host: built.host,
            port: built.port, verify_upstream: verify_upstream, sni: sni, timeout: timeout, overrides: ov)
        else
          Repeater::Engine.send(built.bytes, scheme: built.scheme, host: built.host,
            port: built.port, verify_upstream: verify_upstream, sni: sni, timeout: timeout, overrides: ov)
        end
      end

      # Per-operation (connect + idle read/write) timeout for a one-shot send, from
      # timeout_ms; nil = the engine defaults. Mirrors fuzz_timeout's bounds.
      private def send_timeout(h) : Time::Span?
        int(h, "timeout_ms").try(&.clamp(1_i64, 600_000_i64).milliseconds)
      end

      # Coarse category for a send's network error, from the engine's error text
      # (gori's own controlled strings). "connect" (the dialer collapses DNS /
      # refused / connect-timeout / TLS-verify into one failure — finer split would
      # need dialer changes), "timeout" (idle read/write), "protocol" (framing /
      # malformed response), "no_response", else "other". Advisory.
      private def network_error_kind(message : String?) : String?
        return nil unless message
        m = message.downcase
        return "connect" if m.starts_with?("connect failed")
        return "timeout" if m.includes?("timed out") || m.includes?("timeout")
        return "protocol" if m.includes?("malformed") || m.includes?("framing") ||
                             m.includes?("interim") || m.includes?("chunk")
        return "no_response" if m.includes?("no response") || m.includes?("closed")
        "other"
      end

      private def persist_send_repeater(h, save : Bool, built : RequestBuilder::Built,
                                        http2 : Bool, result : Repeater::Result,
                                        issue_id : Int64?, recorded_flow_id : Int64?) : Int64?
        return nil unless save
        port_suffix = ((built.scheme == "https" && built.port == 443) ||
                       (built.scheme == "http" && built.port == 80)) ? "" : ":#{built.port}"
        target_url = "#{built.scheme}://#{built.host}#{port_suffix}"
        # Preserve the original source flow for a flow repeater; otherwise link
        # the Repeater tab to the newly recorded History evidence.
        flow_id = int(h, "flow_id") || recorded_flow_id
        masked_target = Env.mask_secrets(target_url)
        masked_req = Env.mask_secrets(String.new(built.bytes))
        repeater_id = store.insert_repeater(
          target: masked_target,
          request: masked_req.to_slice,
          http2: http2,
          auto_cl: true,
          flow_id: flow_id,
          position: store.repeaters_meta.size.to_i32,
          sni: nil
        )
        return nil unless repeater_id > 0

        store.add_link(Store::LinkOwnerKind::Issue, issue_id,
          Store::LinkRefKind::Repeater, repeater_id) if issue_id
        if (name = str(h, "name")) && !name.empty?
          store.set_repeater_name(repeater_id, Env.mask_secrets(name))
        end

        # Persist whatever was received even when framing failed after the
        # response head. This keeps partial evidence and enables paged reads.
        store.update_repeater_response(repeater_id, result.head, result.body,
          result.error, result.duration_us)
        if result.response
          probe_scan_saved_repeater(repeater_id, masked_target, masked_req, http2, flow_id,
            result.head, result.body, result.duration_us)
        end
        repeater_id
      end

      private def record_outbound_request(built : RequestBuilder::Built, http2 : Bool) : Int64
        head, body = split_wire_request(built.bytes)
        parsed = Proxy::Codec::Http1.parse_request_head(head)
        captured = Store::CapturedRequest.new(
          created_at: Time.utc.to_unix_ms * 1000_i64,
          scheme: built.scheme,
          host: built.host,
          port: built.port,
          method: parsed.method,
          target: parsed.target,
          http_version: http2 ? "HTTP/2" : parsed.version,
          head: head,
          body: body,
          body_size: body.try(&.size.to_i64),
        )
        id = store.insert_flow(captured)
        if id <= 0
          raise Gori::Error.new("could not record outbound request in History; pass record_history=false only if an unaudited send is intentional")
        end
        id
      end

      private def record_outbound_response(flow_id : Int64, result : Repeater::Result) : Nil
        if response = result.response
          error = result.error
          error ||= "upstream response body was incomplete" if result.incomplete?
          state = error ? Store::FlowState::Error : Store::FlowState::Complete
          store.update_response(FlowMapper.response(response,
            flow_id: flow_id,
            body: result.body,
            duration_us: result.duration_us,
            state: state,
            error: error,
            body_size: result.body.try(&.size.to_i64)))
        else
          store.update_response(FlowMapper.error_response(flow_id,
            result.error || "request failed before a response was received", result.duration_us))
        end
      rescue ex
        # The request already left the host. Keep its result usable, but surface
        # a failed evidence update on STDERR (never the JSON-RPC channel).
        Log.error(exception: ex) { "send_request: failed to finalize History flow #{flow_id}" }
      end

      # OPT-IN Match&Replace parity for a direct send: direct sends are byte-exact (P7) by
      # default — a repeater/fuzz caller wants exactly what it typed. apply_rules:true asks for
      # live-proxy parity, so run the project's enabled REQUEST-side rules over the built bytes
      # and re-sync Content-Length. Response-side rules are intentionally NOT applied. Returns
      # the (possibly rewritten) request and whether a rule actually changed the bytes.
      private def maybe_apply_request_rules(h, built : RequestBuilder::Built) : {RequestBuilder::Built, Bool}
        return {built, false} unless bool_arg(h, "apply_rules", false)
        rules = Gori::Rules.load(store)
        return {built, false} unless rules.active?
        rewritten = Repeater::FlowRequest.resync_content_length(
          rules.transform_message(String.new(built.bytes), Store::RuleTarget::Request, built.host).to_slice)
        return {built, false} if rewritten == built.bytes
        {RequestBuilder::Built.new(rewritten, built.scheme, built.host, built.port), true}
      end

      private def send_result_json(result : Repeater::Result, recorded_flow_id : Int64?,
                                   repeater_id : Int64?, include_sensitive_headers : Bool,
                                   sc : ScopeCheck, built : RequestBuilder::Built, http2 : Bool,
                                   ignored : Array(String), body_cap : Int32, body_omit : Bool,
                                   applied_rules : Bool = false) : String
        JSON.build do |j|
          j.object do
            emit_scope(j, sc)
            emit_effective_request(j, built, http2)
            j.field "match_replace_applied", true if applied_rules
            unless ignored.empty?
              j.field("ignored_fields") { j.array { ignored.each { |f| j.string f } } }
              j.field "precedence_warning",
                "flow_id takes precedence; #{ignored.join(", ")} #{ignored.size == 1 ? "was" : "were"} ignored"
            end
            j.field "recorded_flow_id", recorded_flow_id
            j.field "saved_repeater_id", repeater_id if repeater_id && repeater_id > 0
            unless result.ok?
              j.field "error", result.error
              j.field "error_kind", network_error_kind(result.error)
              # Structured-error contract inside the payload (the payload IS the
              # structuredContent): a network failure is coded + retryable so a
              # caller can apply policy without string-matching the message.
              j.field "error_code", "NETWORK_ERROR"
              j.field "retryable", true
            end
            if response = result.response
              j.field "status", response.status
              j.field "reason", response.reason
              j.field "http_version", response.version
              redacted = false
              j.field "headers" do
                j.array do
                  response.headers.each do |header|
                    sensitive = sensitive_header?(header.name) && !include_sensitive_headers
                    redacted ||= sensitive
                    j.object do
                      j.field "name", header.name
                      j.field "value", sensitive ? "[REDACTED]" : header.value
                    end
                  end
                end
              end
              j.field "sensitive_headers_redacted", redacted
            end
            j.field "duration_us", result.duration_us
            j.field "incomplete", true if result.incomplete?
            Serialize.emit_body(j, "body", result.head, result.body, false, body_cap, body_omit)
          end
        end
      end

      # One redaction policy across Flow, Repeater, and send_request responses.
      private def sensitive_header?(name : String) : Bool
        Serialize.sensitive_header?(name)
      end

      # Execute a stored WebSocket repeater from MCP. Unlike send_request, this uses
      # WsEngine's fresh Sec-WebSocket-Key + framed message exchange and therefore
      # returns the inbound transcript instead of stopping at the 101 response.
      private def send_websocket(h) : Result
        repeater_id = int(h, "repeater_id")
        return Result.new(id_error(h, "repeater_id"), is_error: true) unless repeater_id
        repeater = store.get_repeater(repeater_id)
        return not_found("no repeater with id #{repeater_id}") unless repeater
        repeater_request_text = String.new(repeater.request)
        unless Repeater::WsEngine.upgrade_request?(repeater_request_text)
          return Result.new("repeater #{repeater_id} is not a WebSocket upgrade request", is_error: true)
        end

        issue_id = int(h, "issue_id")
        return Result.new(id_error(h, "issue_id"), is_error: true) if issue_id.nil? && present?(h, "issue_id")
        # Validate the issue now, but DON'T create the link yet — it must not persist
        # if the scope gate below refuses the send. The link is created after the gate.
        return not_found("no issue with id #{issue_id}") if issue_id && !store.get_issue(issue_id)

        idle_ms = int(h, "idle_ms")
        return Result.new(id_error(h, "idle_ms"), is_error: true) if idle_ms.nil? && present?(h, "idle_ms")
        idle = (idle_ms || 3000_i64).clamp(100_i64, 60_000_i64).milliseconds

        out_messages = if present?(h, "messages")
                         arr = h["messages"]?.try(&.as_a?)
                         return Result.new("invalid 'messages' (expected an array of strings)", is_error: true) unless arr
                         parsed = [] of Repeater::WsEngine::OutMsg
                         arr.each do |item|
                           text = item.as_s?
                           return Result.new("invalid 'messages' (expected an array of strings)", is_error: true) unless text
                           parsed << Repeater::WsEngine::OutMsg.new(1, Env.expand(text).to_slice)
                         end
                         parsed
                       else
                         store.ws_messages_for_repeater(repeater_id).compact_map do |m|
                           next unless m.direction == "out"
                           payload = m.text? ? Env.expand(String.new(m.payload).scrub).to_slice : m.payload
                           Repeater::WsEngine::OutMsg.new(m.opcode, payload)
                         end
                       end

        target = Env.expand(repeater.target)
        scheme, host, port = Repeater::FlowRequest.parse_target(target)
        return Result.new("could not parse target for repeater #{repeater_id}", is_error: true) if host.empty? || port <= 0
        # Scope gate before the outbound handshake (same policy as send_request).
        sc = scope_check("#{scheme}://#{host}/", host, bool(h, "allow_unscoped") || false)
        return scope_blocked(sc) if sc.blocked
        # Scope passed — now it's safe to persist the issue link.
        if issue_id
          store.add_link(Store::LinkOwnerKind::Issue, issue_id,
            Store::LinkRefKind::Repeater, repeater_id)
        end
        verify = @verify_upstream && !(bool(h, "insecure") || false)
        request = Env.expand_wire(repeater_request_text)
        sni = repeater.sni.try { |value| Env.expand(value) }
        result = Repeater::WsEngine.send(request, out_messages,
          scheme: scheme, host: host, port: port, verify_upstream: verify, sni: sni, idle: idle,
          overrides: HostOverrides.load(store))

        store.update_repeater_response(repeater_id, result.handshake_head, Bytes.empty,
          result.error, result.duration_us)
        Log.info { "send_websocket #{scheme}://#{host}:#{port} repeater_id=#{repeater_id} -> #{result.ok? ? "ok" : result.error}" }

        payload = JSON.build do |j|
          j.object do
            emit_scope(j, sc)
            j.field "repeater_id", repeater_id
            j.field "upgraded", result.upgraded?
            j.field "duration_us", result.duration_us
            j.field "close_code", result.close_code if result.close_code
            j.field "note", Env.mask_secrets(result.note.not_nil!) if result.note
            if err = result.error
              j.field "error", Env.mask_secrets(err)
              j.field "error_kind", network_error_kind(err)
              j.field "error_code", "NETWORK_ERROR"
              j.field "retryable", true
            end
            unless result.handshake_head.empty?
              response = begin
                Proxy::Codec::Http1.parse_response_head(result.handshake_head)
              rescue
                nil
              end
              j.field "handshake_status", response.status if response
            end
            j.field "messages" do
              j.array do
                result.messages.each do |message|
                  j.object do
                    j.field "direction", message.direction
                    j.field "opcode", message.opcode
                    j.field "type", Serialize.ws_frame_type(message.opcode)
                    if message.opcode == 1
                      j.field "payload", Env.mask_secrets(String.new(message.payload).scrub)
                    else
                      j.field "binary", true
                      j.field "payload_base64", Base64.strict_encode(message.payload)
                    end
                  end
                end
              end
            end
          end
        end
        Result.new(payload, is_error: !result.ok?)
      rescue ex : Gori::Error
        Result.new(ex.message || "invalid WebSocket request arguments", is_error: true)
      end

      # Either replays a persisted repeater (repeater_id), repeaters a captured flow
      # (flow_id), or builds from url/raw/method args. Returns {request bytes +
      # target, use-h2, TLS SNI}.
      private def build_send_request(h) : {RequestBuilder::Built, Bool, String?}
        if present?(h, "flow_id") && present?(h, "repeater_id")
          raise Gori::Error.new("pass only one of flow_id or repeater_id")
        end
        if present?(h, "repeater_id")
          id = int(h, "repeater_id")
          raise Gori::Error.new(id_error(h, "repeater_id")) unless id
          rec = store.get_repeater(id)
          raise Gori::Error.new("no repeater with id #{id}") unless rec
          rec_request_text = String.new(rec.request)
          if Repeater::WsEngine.upgrade_request?(rec_request_text)
            raise Gori::Error.new("repeater #{id} is a WebSocket upgrade — use send_websocket")
          end
          expanded = Env.expand_wire(rec_request_text)
          # Respect the repeater's auto-Content-Length setting (the TUI Repeater does):
          # only recompute CL when it's on, so a deliberately hand-set CL is preserved.
          bytes = rec.auto_content_length? ? Repeater::FlowRequest.resync_content_length(expanded) : expanded
          target = Env.expand(rec.target)
          scheme, host, port = Repeater::FlowRequest.parse_target(target)
          raise Gori::Error.new("could not parse target for repeater #{id}") if host.empty?
          http2 = bool_arg(h, "http2", rec.http2?)
          sni = rec.sni.try { |v| Env.expand(v) }
          return {RequestBuilder::Built.new(bytes, scheme, host, port), http2, sni}
        end
        if present?(h, "flow_id")
          id = int(h, "flow_id")
          raise Gori::Error.new(id_error(h, "flow_id")) unless id
          detail = store.get_flow(id)
          raise Gori::Error.new("no flow with id #{id}") unless detail
          flow = Repeater::FlowRequest.build(detail)
          # Re-sync Content-Length after expansion (a body `$KEY` changes its length).
          bytes = Repeater::FlowRequest.resync_content_length(Env.expand_wire(String.new(flow.bytes)))
          target = Env.expand(flow.target)
          scheme, host, port = Repeater::FlowRequest.parse_target(target)
          raise Gori::Error.new("could not parse target from flow #{id}") if host.empty?
          # Default to how the flow was captured, but honor an EXPLICIT http2 either way —
          # `bool_arg` returns `flow.http2` only when the arg is absent, so `http2:false`
          # can now downgrade an h2 capture to h1 (it used to be silently ignored because
          # `false || flow.http2` kept h2). Carry the captured SNI so an origin where
          # SNI ≠ Host (domain fronting / multi-cert vhost) presents the right certificate,
          # matching `gori run repeater`.
          http2 = bool_arg(h, "http2", flow.http2)
          {RequestBuilder::Built.new(bytes, scheme, host, port), http2, flow.sni}
        else
          built = RequestBuilder.build(h)
          {built, bool_arg(h, "http2", false), nil}
        end
      end

      # Evaluate the project scope against an active request's target. Refused
      # (blocked) unless the caller passes allow_unscoped, in two cases:
      #   - out_of_scope: scope IS configured and the target doesn't match it
      #     (the Probe-Active `matches_url?` test — an INCLUDE must match, no
      #     exclude may, display-lens flag ignored).
      #   - unscoped: NO scope is configured — the most dangerous case (no
      #     guardrail at all), so an active request needs an explicit opt-in.
      # in_scope requests always proceed and carry the matched rule id.
      private def scope_check(url : String, host : String, allow_unscoped : Bool) : ScopeCheck
        scope = Scope.load(store)
        return ScopeCheck.new("unscoped", host, nil, !allow_unscoped) unless scope.configured?
        if scope.matches_url?(url, host)
          rid = scope.rules.find { |r| r.include? && r.matches?(url, host) }.try(&.id)
          ScopeCheck.new("in_scope", host, rid, false)
        else
          ScopeCheck.new("out_of_scope", host, nil, !allow_unscoped)
        end
      end

      # A refusal to send an active request outside (or without) scope.
      # SCOPE_BLOCKED is not retryable — the caller must add a scope include rule
      # or pass allow_unscoped:true.
      private def scope_blocked(sc : ScopeCheck) : Result
        reason = sc.decision == "unscoped" ? "no scope is configured for this project, so active requests are refused by default" : "target host #{sc.host} is outside the project's configured scope"
        err("#{reason}; add a scope include rule or pass allow_unscoped:true to override",
          "SCOPE_BLOCKED", field: "url",
          details: JSON.parse({"scope_decision" => sc.decision, "host" => sc.host}.to_json))
      end

      # The request-target (path) from the first line of a raw request, for
      # building the scheme://host/target URL the scope string/regex rules see.
      private def request_target(bytes : Bytes) : String
        line = String.new(bytes).each_line.first? || ""
        line.split(' ')[1]? || "/"
      end

      # Passive-scan a just-saved Repeater send into probe_issues when mode is Passive/Active.
      private def probe_scan_saved_repeater(repeater_id : Int64, target : String, request : String,
                                            http2 : Bool, flow_id : Int64?, head : Bytes, body : Bytes?,
                                            duration_us : Int64) : Nil
        return unless store.probe_mode.scanning?
        return if head.empty?
        rec = Store::RepeaterRecord.new(
          repeater_id, target, request.to_slice, http2, true, flow_id, 0,
          head, body, nil, duration_us, nil, nil)
        return unless detail = Probe.detail_from_repeater(rec)
        Probe::Passive.analyze(detail).each do |d|
          store.upsert_probe_issue(Probe.with_source(d, flow_id: flow_id, repeater_id: repeater_id))
        end
      rescue
        # Probe must never break send_request
      end
    end
  end
end
