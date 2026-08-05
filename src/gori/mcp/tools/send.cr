require "json"
require "base64"
require "../../store"
require "../../host_overrides"
require "../../rules"
require "../../repeater/engine"
require "../../repeater/h2_engine"
require "../../repeater/flow_request"
require "../../repeater/plan"
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

        # Layer 1's policy is chosen here (`Outbound.agent`) and handed to the builder — the
        # builder must never pick it, or MCP's strict "no scope ⇒ refuse" default would
        # silently become whichever policy got hard-coded there (DESIGN.md §7).
        ob = outbound(bool_arg(h, "allow_unscoped", false))
        built_plan = build_send_plan(h, ob)
        return built_plan if built_plan.is_a?(Result)
        plan, request_line_rewritten = built_plan
        # OPT-IN Match&Replace parity (before the scope gate + History write so the
        # recorded/effective request == the wire); byte-exact by default.
        plan, applied_rules = maybe_apply_request_rules(h, plan)
        gate = send_gate(ob, plan)
        return gate if gate.is_a?(Result)
        sc = gate
        # A field-native send has no h1-text source: its `built.bytes` is the FAITHFUL
        # pseudo-explicit dump (`H2Engine.field_dump`), so the recorded/reported request shows
        # `:scheme` and every duplicate pseudo the h1 projection drops (F11). The byte path is
        # untouched — `plan.bytes` is still the operator's text there.
        built =
          if fields = plan.h2_fields
            RequestBuilder::Built.new(Repeater::H2Engine.field_dump(fields, plan.h2_body),
              plan.scheme, plan.host, plan.port)
          else
            RequestBuilder::Built.new(plan.bytes, plan.scheme, plan.host, plan.port)
          end
        http2 = plan.http2?
        wire = wire_request(plan, built)
        recorded_flow_id = record_history ? record_outbound_request(built, wire, http2, plan.h2_fields) : nil
        result = plan.send
        record_outbound_response(recorded_flow_id, result) if recorded_flow_id
        # Audit trail on STDERR — never STDOUT (reserved for JSON-RPC).
        Log.info { "send_request #{built.scheme}://#{built.host}:#{built.port} http2=#{http2} scope=#{sc.decision} flow_id=#{recorded_flow_id || "none"} -> #{result.ok? ? "ok" : result.error}" }

        repeater_id = persist_send_repeater(h, save, built, http2, result,
          issue_id, recorded_flow_id, plan.h2_fields)

        body_cap, body_omit = body_return_opts(h)
        Result.new(send_result_json(result, recorded_flow_id, repeater_id,
          include_sensitive_headers, sc, built, wire, http2, flow_precedence_ignored(h), body_cap, body_omit, applied_rules, plan.h2_fields,
          request_line_rewritten, plan.websocket?),
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
        {"url", "method", "headers", "body", "body_base64", "raw", "raw_base64"}.select { |f| present?(h, f) }.to_a
      end

      # The bytes that actually reach the origin, as head text.
      #
      # On h1 they ARE `built.bytes` — `Engine` writes them byte-exact (P7). On h2 the bytes
      # are only the SOURCE: `H2Engine` resolves `:path` from the request line, folds `Host:`
      # into `:authority` and (unless `verbatim`) lowercases field names. Deriving the report
      # and the History row from the source therefore described a request gori never sent —
      # MCP answered `target: "/mcp-noversion"` with `Transfer-Encoding` in the recorded head
      # while `GET /` went out, and `run show <id> --format raw` printed those bytes back. An
      # agent-driven scan reads exactly this.
      #
      # Falls back to the source when the encoding raises: `plan.send` hits the same refusal
      # and reports it as the error, and a report is not the place to raise a second time.
      private def wire_request(plan : Repeater::Plan, built : RequestBuilder::Built) : Bytes
        # Field-native: `built.bytes` is already the faithful field dump — the fields go on the
        # wire verbatim, so there is no h1-text to re-encode and nothing to project away.
        return built.bytes if plan.h2_fields
        return built.bytes unless plan.http2?
        Repeater::H2Engine.encoded_request(built.bytes, scheme: built.scheme, host: built.host,
          port: built.port, preserve_field_case: plan.preserve_field_case?)
      rescue Gori::Error
        built.bytes
      end

      # The request actually put on the wire, parsed back from the encoded bytes, so
      # a caller can confirm scheme/host/port/method/target/version independently
      # of which inputs it supplied (flow_id vs url/raw).
      private def emit_effective_request(j : JSON::Builder, built : RequestBuilder::Built,
                                         wire : Bytes, http2 : Bool,
                                         h2_fields : Array({String, String})? = nil) : Nil
        # Field-native: the wire is a pseudo-explicit dump whose first line is `:method: …`,
        # not a request line — derive method/target from the FIELDS a receiver routes on (the
        # first `:method`/`:path`), so `effective_request` describes the shape actually sent
        # rather than mis-reading the dump's leading pseudo line.
        # `split` (no arg) collapses whitespace runs so a malformed request line with a
        # doubled space still reports the real method/target/version (see Outbound.request_target).
        parts = (String.new(wire).each_line.first? || "").split
        if fields = h2_fields
          method = Repeater::H2Engine.pseudo_field(fields, ":method") || ""
          target = Repeater::H2Engine.pseudo_field(fields, ":path") || "/"
        else
          method = parts[0]? || ""
          target = parts[1]? || "/"
        end
        j.field "effective_request" do
          j.object do
            j.field "scheme", built.scheme
            j.field "host", Serialize.text(built.host)
            j.field "port", built.port
            # A `raw` send is byte-exact by contract (P7), so the request line here can hold
            # any octet the caller typed — scrub the ECHO without touching the wire bytes.
            j.field "method", Serialize.text(method)
            j.field "target", Serialize.text(target)
            # NULL, not a substituted "HTTP/1.1", when the request line carried no version.
            # This field's contract is "what actually went out": a `verbatim` send of
            # `GET /old09\r\n\r\n` is the HTTP/0.9 handling probe, and answering it with a
            # version that was never on the wire tells the agent its own test did not happen.
            j.field "http_version", http2 ? "HTTP/2" : parts[2]?.try { |v| Serialize.text(v) }
          end
        end
      end

      # The FAITHFUL field list a field-native send put on the wire, in order, pseudo-headers
      # and duplicates included — the report `H2Engine.field_dump` used to carry by being the
      # stored head. It moved here because History and the Repeater have to hold a REPLAYABLE
      # projection (see `replayable_field_head`), and that projection cannot show a duplicate
      # `:method` or a `:scheme` disagreeing with the connection. `history_head_projected`
      # says so out loud, so an agent reading the recorded flow back never mistakes the
      # projection for the wire.
      private def emit_sent_h2_fields(j : JSON::Builder, h2_fields : Array({String, String})?) : Nil
        return unless fields = h2_fields
        j.field "sent_h2_fields" do
          j.array do
            fields.each do |(n, v)|
              j.array { j.string Serialize.text(n); j.string Serialize.text(v) }
            end
          end
        end
        j.field "history_head_projected", true
        j.field "history_head_note",
          "the recorded flow / saved repeater holds the HTTP/1.1 projection of these fields " \
          "(so it can be replayed); `sent_h2_fields` above is what went on the wire"
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

      # BOTH gate layers for a one-shot send, resolved before any outbound byte or History
      # write — a refused send records nothing. Returns the gated dialer plus the verdict to
      # report, or the refusal Result.
      #
      # Layer 1 (`Outbound#check`) is the scope allowlist, waivable with allow_unscoped. The
      # scope URL is anchored on the DIAL target (built.host — what the engine connects to),
      # see request_scope_url: deliberately spoofing the request-line/Host to a DIFFERENT
      # host (Host-header attacks, cache poisoning, SSRF via absolute-form) is a legitimate
      # test and is NOT blocked — the bytes still go out verbatim; we just scope on the host
      # we dial, so a send can't reach an out-of-scope host while the gate matched the
      # (spoofed) request-line host instead.
      #
      # Layer 2 (`Repeater::Sender#refusal`) is Sandbox mode, a hard containment gate that
      # allow_unscoped does NOT lift — the TUI and `gori run repeater` have always enforced
      # it that way, and MCP used to let allow_unscoped:true walk straight past it. It used to
      # carry the unbound-binding rule too; that rule is gone (see `Env.unbound`), so every
      # refusal reaching here is a Sandbox one again.
      private def send_gate(ob : Outbound, plan : Repeater::Plan) : ScopeCheck | Result
        sc = ob.check(request_scope_url(plan), plan.host)
        return scope_blocked(sc) if sc.blocked?
        if reason = plan.refusal
          return sandbox_blocked(reason, plan.host, "url")
        end
        sc
      end

      # Per-operation (connect + idle read/write) timeout for a one-shot send, from
      # timeout_ms; nil = the engine defaults. Mirrors fuzz_timeout's bounds.
      private def send_timeout(h) : Time::Span?
        int(h, "timeout_ms").try(&.clamp(1_i64, 600_000_i64).milliseconds)
      end

      # Substrings that identify a DETERMINISTIC protocol refusal in gori's own error text —
      # a message gori (or the origin) will produce identically on every retry.
      #
      # The list used to stop at malformed/framing/interim/chunk, which left the sharpest
      # finding a tester can get filed as an "other" transient error: two conflicting
      # `Content-Length` headers — a response-splitting/desync condition — came back as
      # `error_kind:"other", error_code:"NETWORK_ERROR", retryable:true`, so an agent LOOPS on
      # it instead of reporting it. Every phrase here is raised by gori's own framing guards
      # (`Codec::Body`, `Codec::Http1`, the h2 assembler/engine), never by a socket.
      PROTOCOL_ERROR_PHRASES = {
        "malformed", "framing", "interim", "chunk",
        "conflicting content-length", "ambiguous framing", "obfuscated",
        "transfer-encoding", "content-length", "invalid header", "invalid status",
        "http/2", "h2 ", "hpack", "response head", "status line",
      }

      # h2/RFC 9113 §7 conditions that are TRANSIENT even though the sentence naming them
      # trips PROTOCOL_ERROR_PHRASES (every one of them says "h2 "). Keyed on the SPEC
      # ERROR-CODE NAMES, not on gori's sentence: the names are fixed by the RFC and the
      # engine renders them straight out of `H2Engine::GOAWAY_ERRORS`, so matching
      # `refused_stream` survives any rewording of the sentence carrying it — which is the
      # failure mode a whole-sentence literal would have.
      #
      # §8.7 makes REFUSED_STREAM an explicit RETRY instruction ("the request was not
      # processed") and ENHANCE_YOUR_CALM is a rate signal, not a malformed message. Coding
      # either as a non-retryable PROTOCOL_ERROR tells an agent to stop and file a finding
      # where the correct action is to send the request again on a fresh connection.
      RETRYABLE_H2_PHRASES = {"refused_stream", "enhance_your_calm"}

      # "gori got no response frame at all" — the category `no_response` exists for. These
      # also say "h2 ", so PROTOCOL_ERROR_PHRASES used to claim them and report an origin
      # that simply closed the connection as a non-retryable framing refusal. A protocol
      # verdict means gori can PROVE the message malformed; silence is not that.
      NO_RESPONSE_PHRASES = {"no h2 response", "no response"}

      # RFC 9113 §8.1 lets an origin answer while the request body is still going out — a 413
      # after N bytes is exactly what an upload / body-size probe is looking for. The send has
      # a REAL response (status, head, body); what it does not have is the whole request. That
      # is neither a network fault nor gori proving the message malformed:
      #   * retrying re-sends the entire body to a server that already rejected it, which for a
      #     body-size probe is the wrong move and, at scale, is the probe becoming the attack;
      #   * `PROTOCOL_ERROR` would blame someone for behaviour the RFC explicitly permits.
      # So it gets its own kind and its own non-retryable code.
      #
      # Keyed on "truncated at" and NOT on "NOT fully sent", deliberately: the flow-control
      # stall sentence (`H2Engine.flow_stalled`) ALREADY ends with "The request was NOT fully
      # sent." and is a genuine stall that must stay `protocol`. The two conditions differ in
      # whether a response arrived, and only the truncation sentence counts bytes with
      # "truncated at".
      TRUNCATED_REQUEST_PHRASE = "truncated at"

      # The one `flow_stalled` variant that is a DEADLINE, not origin misbehaviour: gori's own
      # budget for the whole exchange expired while the origin was still granting window in
      # increments too small to finish the body. Its siblings — "the origin closed the
      # connection before granting window", "the origin never granted flow-control window" —
      # are the origin refusing to make progress, and `protocol` / non-retryable is right for
      # those: retrying reproduces them and the refusal IS the finding.
      #
      # This one is different in the one way that matters to an agent: nothing about the
      # target changed, only the clock ran out, and the correct next move is to raise
      # `timeout_ms` — which `retryable: false` tells a caller not to attempt. It is the same
      # shape as gori's ordinary idle timeout, which is already `timeout` / NETWORK_ERROR, so
      # it is folded into that kind rather than given a fourth code: a deadline is a deadline.
      #
      # Keyed on this PHRASE and not on the whole sentence, and not on "NOT fully sent" —
      # which every flow_stalled variant ends with, so matching that would sweep the siblings
      # in with it. The phrase must stay in step with `H2Engine.flow_stalled`; the spec pins
      # both it and a sibling sentence as DATA so a reword there cannot silently flip a
      # verdict here.
      EXCHANGE_BUDGET_PHRASE = "budget for the whole exchange"

      # Coarse category for a send's network error, from the engine's error text
      # (gori's own controlled strings). "connect" (the TCP layer: refused, unreachable,
      # a connect timeout, or a name that did not resolve — the dialer now separates a
      # certificate rejection, a refused handshake and an origin that accepts and then goes
      # silent into their own sentences, which land on "other"/"timeout" as they should),
      # "timeout" (idle read/write, and a TLS handshake that never got an answer), "protocol" (a deterministic
      # framing/protocol refusal — see PROTOCOL_ERROR_PHRASES), "no_response", else "other".
      #
      # A pure function of the engine's sentence, so it is `self.` and directly testable: the
      # retry policy an agent applies hangs off it, and the sentences it reads are written in
      # another module. Pinning them in a spec is what keeps a reword there from silently
      # flipping a retryable condition into "stop and report a finding".
      private def network_error_kind(message : String?) : String?
        Tools.network_error_kind(message)
      end

      def self.network_error_kind(message : String?) : String?
        return nil unless message
        m = message.downcase
        return "connect" if m.starts_with?("connect failed")
        return "timeout" if m.includes?("timed out") || m.includes?("timeout")
        # Ahead of PROTOCOL_ERROR_PHRASES (the sentence says "h2 ") — see the constant.
        return "timeout" if m.includes?(EXCHANGE_BUDGET_PHRASE)
        # Both ahead of PROTOCOL_ERROR_PHRASES on purpose — see their own comments.
        return "other" if RETRYABLE_H2_PHRASES.any? { |p| m.includes?(p) }
        return "no_response" if NO_RESPONSE_PHRASES.any? { |p| m.includes?(p) }
        return "protocol" if PROTOCOL_ERROR_PHRASES.any? { |p| m.includes?(p) }
        # AFTER the three lists above, on purpose. A GOAWAY/RST_STREAM reason APPENDS the
        # truncation clause rather than replacing it, so those sentences must keep the verdict
        # their error code already earns them (REFUSED_STREAM stays retryable, CANCEL stays
        # protocol) — every one of them says "h2 " and is matched strictly earlier.
        return "truncated_request" if m.includes?(TRUNCATED_REQUEST_PHRASE)
        return "no_response" if m.includes?("closed")
        "other"
      end

      # The structured-error pair for a failed send.
      #
      # "protocol" is gori refusing a message it can prove is malformed: NOT retryable and not
      # a network fault — retrying reproduces it exactly, and the refusal itself is the
      # finding. "truncated_request" is the origin answering early (RFC 9113 §8.1): also not
      # retryable, but for the opposite reason — the answer is real and complete, it is the
      # REQUEST that is partial, and re-sending would put the whole body back on the wire.
      # Everything else keeps the transient NETWORK_ERROR contract callers already apply
      # policy against. `retryable` is the field to branch on; the code names the cause.
      #
      # `delivered` is the SECOND term, and it is the one the error CODE cannot carry. The
      # code is a pure function of gori's own sentence, and two failures with the same
      # sentence shape — "the origin said nothing" vs "the origin answered an interim 1xx
      # and THEN said nothing" — differ in the only fact a retry policy needs. gori writes a
      # request in full before it reads, so ANY response byte (even a 100/103) proves the
      # origin has the whole request and has had its chance to act on it. Both engines
      # compute exactly that (`H2Engine.exchange`'s `delivered: reply.status != 0`,
      # `Engine.exchange`'s rescue `delivered: !head.nil?`) and it reached NO surface, so MCP
      # answered `retryable: true` for the very failures round 4 documented as "the origin
      # already has the whole request … re-sending would double a side effect". Emitted
      # alongside `retryable` so an agent sees WHY it may not retry, not only that it may not.
      private def emit_send_error_code(j : JSON::Builder, kind : String?, delivered : Bool) : Nil
        code = Tools.send_error_code(kind)
        j.field "error_code", code
        j.field "retryable", Tools.send_retryable?(code, delivered)
        j.field "delivered", delivered
      end

      # Split out and `self.` for the same reason `network_error_kind` is: the retry policy an
      # agent applies hangs off this mapping, and pinning it in a spec is what stops a new kind
      # from silently landing in the retryable bucket by falling through the `else`.
      def self.send_error_code(kind : String?) : String
        case kind
        when "protocol"          then "PROTOCOL_ERROR"
        when "truncated_request" then "REQUEST_TRUNCATED"
        else                          "NETWORK_ERROR"
        end
      end

      # `self.` and separate from `send_error_code` for the same reason: this is the field an
      # agent branches on, so a spec pins the PAIR rather than the code mapping alone.
      def self.send_retryable?(code : String, delivered : Bool) : Bool
        code == "NETWORK_ERROR" && !delivered
      end

      private def persist_send_repeater(h, save : Bool, built : RequestBuilder::Built,
                                        http2 : Bool, result : Repeater::Result,
                                        issue_id : Int64?, recorded_flow_id : Int64?,
                                        h2_fields : Array({String, String})? = nil) : Int64?
        return nil unless save
        port_suffix = ((built.scheme == "https" && built.port == 443) ||
                       (built.scheme == "http" && built.port == 80)) ? "" : ":#{built.port}"
        target_url = "#{built.scheme}://#{built.host}#{port_suffix}"
        # Preserve the original source flow for a flow repeater; otherwise link
        # the Repeater tab to the newly recorded History evidence.
        flow_id = int(h, "flow_id") || recorded_flow_id
        # Masked for the PROBE SCAN only, exactly like `masked_req` below — never for the row.
        # `target` is a WIRE field: it is the dial tuple, and it supplies the TLS ClientHello
        # ServerName whenever `sni` is absent (which it always is on this save-from-send path,
        # `sni: nil`). See `stored_request` for the seam; the two extra facts that make masking
        # it destructive rather than merely cosmetic:
        #
        #   * The two ends do not share a vocabulary. `mask_secrets` resolves against
        #     `Env.masking_vars` — env vars PLUS every session-binding value currently held —
        #     while the send path resolves with `Env.effective_vars` (env vars only) and
        #     `Repeater::Plan` additionally runs `refuse_unresolved(Env.unresolved(s,
        #     deferred: nil))`, which refuses a DECLARED binding name outright. So a binding
        #     value masked in here mints a `$NAME` that can never resolve on any send path,
        #     from any surface.
        #   * The author's string is then unrecoverable. An author who sent
        #     `http://prod-edge-07.internal.example.com:19752/vhost` while an extract rule had
        #     bound `$edge` to `prod-edge-07` got `http://$edge.internal.example.com:19752` in
        #     the row, every re-send refused with "unresolved env $edge", and a prescription
        #     ("set the env var") that would put a GUESSED hostname in the ClientHello of a
        #     vhost test. A one-way door, and this projection existed for the store alone —
        #     the reply below never carried a target field at all.
        #
        # `name` keeps its mask (further down): a session name is a TUI tab caption and never
        # becomes bytes an origin sees. The rule is "does this field reach the wire", not "did
        # the operator type it". Same resolution as the sibling seam in `Tools#create_repeater`.
        masked_target = Env.mask_secrets(target_url)
        # Same reason as `record_outbound_request`: a saved session is a REPLAY source before
        # it is a display, and no surface can send `H2Engine.field_dump` back. Saving the dump
        # produced a session (`#5 [H2] fieldnative`) that could never be sent again from any
        # surface — the CLI refused it with the pseudo-header message and MCP read its method
        # back as `":method:"`. See `replayable_field_head`.
        saved_bytes = replayable_field_head(h2_fields, built, built.bytes)
        # Masked for the PROBE scan and the reply, NOT for the row. The saved session is a
        # REPLAY SOURCE (the sentence just above), and storing the masked projection made it
        # a replay of different bytes: `flow_id` is set here, the TUI reads that as evidence,
        # and `RepeaterView#evidence?` sends `$NAME` literally — so this row went out one way
        # from the TUI and another from MCP. Same seam as `Tools#stored_request`.
        masked_req = Env.mask_secrets(String.new(saved_bytes))
        repeater_id = store.insert_repeater(
          target: target_url,
          request: saved_bytes,
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

      # The bytes to PERSIST for a field-native h2 send: `HeadCodec.synth_request`'s h1
      # projection plus the body, not `H2Engine.field_dump`.
      #
      # The dump is the faithful REPORT of the fields and it stays that, in `sent_h2_fields`
      # on this call's own result. It must not be the stored head, because History and the
      # Repeater are not only a display — they are a REPLAY SOURCE, and the dump's first line
      # is `:method: POST`, not a request line. Replaying such a row over h2 was refused with
      # gori blaming the operator for bytes gori itself wrote; over `--http1` it put a request
      # with NO REQUEST LINE on the wire (every header shifted by one) and reported `200`; and
      # MCP's own echo read the row back as `method: ":method:", target: "POST"`.
      #
      # The projection is lossy — a duplicate pseudo and `:scheme` do not survive it, which is
      # exactly what `field_dump` exists to show — but it is lossy in the one direction that
      # keeps the evidence usable, and it is the same projection the h2 CAPTURE path stores
      # for every intercepted h2 request. Evidence gori writes must be replayable by gori.
      # Nil `fields` means this was never a field-native send, so the bytes are already the
      # operator's own text and pass through — that way no caller needs a branch of its own.
      private def replayable_field_head(fields : Array({String, String})?,
                                        built : RequestBuilder::Built, wire : Bytes) : Bytes
        return wire unless fields
        authority = Proxy::H2::HeadCodec.pseudo(fields, ":authority") ||
                    "#{built.host}:#{built.port}"
        head = Proxy::H2::HeadCodec.synth_request(fields, authority)
        _, body = split_wire_request(wire)
        return head if body.nil? || body.empty?
        joined = Bytes.new(head.size + body.size)
        head.copy_to(joined)
        body.copy_to(joined + head.size)
        joined
      end

      # `wire` — not `built.bytes` — is the evidence: History is what `run show --format raw`
      # and `get_flow` replay from, and on h2 the source text is not what went out. See
      # `wire_request`.
      private def record_outbound_request(built : RequestBuilder::Built, wire : Bytes, http2 : Bool,
                                          h2_fields : Array({String, String})? = nil) : Int64
        head, body = split_wire_request(replayable_field_head(h2_fields, built, wire))
        # Field-native: `head` is the h1 PROJECTION, not the pseudo-explicit dump, so the
        # method/target COLUMNS (list_history / QL / sitemap read them) come off the FIELDS a
        # receiver routes on and agree with the head text. See `replayable_field_head`.
        if fields = h2_fields
          method = Repeater::H2Engine.pseudo_field(fields, ":method") || ""
          target = Repeater::H2Engine.pseudo_field(fields, ":path") || "/"
          version = "HTTP/2"
        else
          # `authored_start_line`, not `parse_request_head`: these bytes are the caller's, and
          # under `verbatim` a bare-LF terminator is the payload. See its comment for why the
          # shared parser must stay strict.
          method, target, version = Proxy::Codec::Http1.authored_start_line(head)
        end
        captured = Store::CapturedRequest.new(
          created_at: Time.utc.to_unix_ms * 1000_i64,
          scheme: built.scheme,
          host: built.host,
          port: built.port,
          method: method,
          target: target,
          http_version: http2 ? "HTTP/2" : version,
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
      private def maybe_apply_request_rules(h, plan : Repeater::Plan) : {Repeater::Plan, Bool}
        # Match&Replace parity operates on h1 head TEXT; a field-native plan has none (its
        # `bytes` is only the synthetic scope line), so applying rules would rewrite that line
        # and never the fields on the wire. A field list is byte-exact by construction — the
        # reason apply_rules is opt-in at all — so it is simply not offered here.
        return {plan, false} if plan.h2_fields
        return {plan, false} unless bool_arg(h, "apply_rules", false)
        rules = Gori::Rules.load(store)
        return {plan, false} unless rules.active?
        # `add_if_missing: false` — this runs AFTER `Plan.build`, so it is past the point where
        # `auto_content_length` was honoured, and the two plan shapes that reach here with that
        # flag deliberately OFF (a `flow_id` capture and a `raw`/verbatim request, both built
        # below with `auto_content_length: false`) are the ones this must not re-frame. A
        # capture that carried no Content-Length is evidence — an h2/gRPC streamed POST is
        # stored exactly that way — and inventing framing for it here would undo the very
        # thing those call sites turned the flag off for. Rules may still CHANGE the body, so
        # an EXISTING Content-Length is still re-synced; only the ADD is withheld.
        rewritten = Repeater::FlowRequest.resync_content_length(
          rules.transform_message(String.new(plan.bytes), Store::RuleTarget::Request, plan.host).to_slice,
          add_if_missing: false)
        return {plan, false} if rewritten == plan.bytes
        {plan.with_requests([rewritten]), true}
      end

      private def send_result_json(result : Repeater::Result, recorded_flow_id : Int64?,
                                   repeater_id : Int64?, include_sensitive_headers : Bool,
                                   sc : ScopeCheck, built : RequestBuilder::Built, wire : Bytes,
                                   http2 : Bool,
                                   ignored : Array(String), body_cap : Int32, body_omit : Bool,
                                   applied_rules : Bool = false,
                                   h2_fields : Array({String, String})? = nil,
                                   request_line_rewritten : Bool = false,
                                   websocket_handshake : Bool = false) : String
        JSON.build do |j|
          j.object do
            emit_scope(j, sc)
            emit_effective_request(j, built, wire, http2, h2_fields)
            emit_sent_h2_fields(j, h2_fields)
            # Only when it FIRED: gori changed the operator's stored bytes, so the surface
            # that reports the send has to say so (`effective_request.target` then shows the
            # origin-form line that actually went out). Absent means nothing was rewritten.
            j.field "request_line_rewritten", true if request_line_rewritten
            j.field "match_replace_applied", true if applied_rules
            # `send_request` has always sent an RFC 6455 upgrade as an ordinary HTTP request —
            # it dials `Engine`/`H2Engine` and reads the 101 as a response, where the TUI and
            # `gori run repeater send` would perform the framed exchange. That is a useful
            # thing to be able to do (it is what the TUI's `^V` now exposes), but it was
            # unnamed: a caller expecting frames got a bodyless 101 and nothing said why.
            if websocket_handshake
              j.field "websocket_handshake", true
              j.field "websocket_note",
                "this request is a WebSocket upgrade; send_request performed the HTTP round-trip only " \
                "(the response is the handshake). Use send_websocket with a repeater_id for the framed exchange."
            end
            unless ignored.empty?
              j.field("ignored_fields") { j.array { ignored.each { |f| j.string f } } }
              j.field "precedence_warning",
                "flow_id takes precedence; #{ignored.join(", ")} #{ignored.size == 1 ? "was" : "were"} ignored"
            end
            j.field "recorded_flow_id", recorded_flow_id
            j.field "saved_repeater_id", repeater_id if repeater_id && repeater_id > 0
            unless result.ok?
              kind = network_error_kind(result.error)
              j.field "error", result.error
              j.field "error_kind", kind
              # Structured-error contract inside the payload (the payload IS the
              # structuredContent) so a caller can apply policy without string-matching the
              # message — including "do not retry this, report it" (see emit_send_error_code).
              emit_send_error_code(j, kind, result.delivered?)
            end
            if response = result.response
              j.field "status", response.status
              # The status line and every header come straight off the REMOTE socket —
              # the least trustworthy source on this surface for JSON-RPC UTF-8 validity.
              j.field "reason", Serialize.text(response.reason)
              j.field "http_version", Serialize.text(response.version)
              redacted = false
              j.field "headers" do
                j.array do
                  response.headers.each do |header|
                    sensitive = sensitive_header?(header.name) && !include_sensitive_headers
                    redacted ||= sensitive
                    j.object do
                      j.field "name", Serialize.text(header.name)
                      if sensitive
                        j.field "value", "[REDACTED]"
                      else
                        # The BODY already had a base64 fallback for bytes JSON cannot carry;
                        # a header value did not, so an 8-bit byte here came back as `�` and
                        # was unrecoverable through MCP entirely — two different invalid bytes
                        # rendered identically. Header values are remote bytes too.
                        Serialize.emit_lossy_text(j, "value", header.value)
                      end
                    end
                  end
                end
              end
              j.field "sensitive_headers_redacted", redacted
            end
            j.field "duration_us", result.duration_us
            if result.incomplete?
              j.field "incomplete", true
              # `incomplete: true` alone said only THAT the body was short, never why, so an
              # agent could not tell gori's own capture ceiling from an origin that closed
              # from a read deadline that expired — three different next moves. The CLI has
              # named them since round 3; this is the same classifier, not a second one.
              j.field "incomplete_reason", CLI::Run.incomplete_reason(result, result.timed_out?)
            end
            Serialize.emit_body(j, "body", result.head, result.body, false, body_cap, body_omit)
          end
        end
      end

      # A CLOSE frame's status code (RFC 6455 §5.5.1), or nil for any other frame. Not
      # `WsMessage#close_code` because a transcript row is a `WsEngine::Message`, which never
      # went through the store.
      private def ws_close_code(m : Repeater::WsEngine::Message) : Int32?
        return nil unless m.opcode == 8 && m.payload.size >= 2
        (m.payload[0].to_i << 8) | m.payload[1].to_i
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

        # ONE list, whether it came from the call or from the session, so the shape handling
        # below cannot diverge between them. `messages` now accepts every form
        # `ws_out_messages` does — a bare string is still a plain TEXT frame, and the object /
        # `WsFrameSpec` forms are what make a PING, a CLOSE with a chosen code, an unmasked
        # client frame or a lying length header expressible from MCP at all. Until now every
        # entry became `OutMsg.new(1, …)`, so this tool could send exactly one frame shape.
        source = [] of Store::WsOutMessage
        field = "repeater_id"
        notice_dropped = 0
        if present?(h, "messages")
          arr = h["messages"]?.try(&.as_a?)
          return Result.new("invalid 'messages' (expected an array of strings or objects)", is_error: true) unless arr
          arr.each do |item|
            msg, perr = ws_out_message_item(item)
            return Result.new(ws_entry_error("messages", item, perr), is_error: true) unless msg
            source << msg
          end
          field = "messages"
        else
          # A `[gori]` advisory captured on the out direction is gori talking about the
          # socket, not a frame the client sent — and the drop is reported, not silent.
          rows, notice_dropped = CLI::Run.ws_seed_rows(store.ws_messages_for_repeater(repeater_id))
          source = rows.map { |m| Store::WsOutMessage.new(m.opcode, m.payload, m.shape) }
        end
        # PROVENANCE, keyed on the session's `flow_id` exactly as `gori run repeater send`
        # keys it: stored rows of a flow-seeded session are the CLIENT's captured frames, so
        # a `$where` / `$ref` / `$filter` in one is a byte the origin saw. Expanding them
        # made a MongoDB-injection capture unreplayable from here at all — the refusal fired
        # with no `verbatim` to escape it, and setting the env vars it recommends sent
        # `{"WHEREVAL":…}`. A `messages` argument is the agent's draft and is unaffected.
        seeded = field == "repeater_id" && !repeater.flow_id.nil?
        verbatim = bool_arg(h, "verbatim", false)
        # No `.scrub`: `Env.expand` scans BYTES and copies every span that is not a matched
        # token through unchanged, so an invalid-UTF-8 TEXT payload — the §8.1/§5.6 validation
        # test case — reaches the wire as the operator captured it. Scrubbing rewrote it to
        # U+FFFD, changing 9 bytes into 13, and sent that with no warning.
        out_messages = source.map do |m|
          payload = m.text? && !seeded && !verbatim ? Env.expand(String.new(m.payload)).to_slice : m.payload
          Repeater::WsEngine::OutMsg.new(m.opcode, payload, m.shape, seeded)
        end

        # Scope gate before the outbound handshake (same policy as send_request).
        ob = outbound(bool_arg(h, "allow_unscoped", false))
        verify = !bool_arg(h, "insecure", false) && @verify_upstream
        # The session's stored setting, overridable per call — a handshake test wants to run
        # it both ways against the same session without editing the session. Read up here with
        # the other flags so an unintelligible value refuses before the issue link is written.
        keep_key = bool_arg(h, "keep_sec_websocket_key", repeater.ws_keep_key?)
        plan = begin
          Repeater::Plan.build(Repeater::PlanOptions.new([repeater.request],
            default_target: repeater.target, sni: repeater.sni, verify: verify,
            # `verbatim` reaches the handshake HEAD, exactly as `gori run repeater send`
            # threads it through `session_plan_options`. (The head deliberately does NOT take
            # the `seeded` provenance the MESSAGES take: `repeaters.request` is rewritable by
            # `update_repeater` while `flow_id` persists, so a flow id is not evidence that
            # THOSE bytes are still the capture's — while nothing but a flow seed ever writes
            # a captured `ws_messages` row's payload.)
            expand_request: !verbatim,
            overrides: HostOverrides.load(store)), ob)
        rescue ex : Repeater::PlanError
          return send_plan_error(ex, "repeater_id")
        end
        host = plan.host
        # Anchor on the same scheme://host/TARGET url send_request uses (Outbound.scope_url).
        # Checking a bare "/" made a path-scoped include (e.g. string:/chat) refuse the very
        # WS repeater it was written to allow, while the identical send_request passed.
        sc = ob.check(request_scope_url(plan), host)
        return scope_blocked(sc) if sc.blocked?
        # Layer 2 (Sandbox) — allow_unscoped does not lift it; refuse before the link write.
        if reason = plan.refusal
          return sandbox_blocked(reason, host, "repeater_id")
        end
        # Scope passed — now it's safe to persist the issue link.
        if issue_id
          store.add_link(Store::LinkOwnerKind::Issue, issue_id,
            Store::LinkRefKind::Repeater, repeater_id)
        end
        result = plan.send_ws(out_messages, idle, keep_key)

        store.update_repeater_response(repeater_id, result.handshake_head, Bytes.empty,
          result.error, result.duration_us)
        Log.info { "send_websocket #{plan.scheme}://#{host}:#{plan.port} repeater_id=#{repeater_id} -> #{result.ok? ? "ok" : result.error}" }

        payload = JSON.build do |j|
          j.object do
            emit_scope(j, sc)
            j.field "repeater_id", repeater_id
            j.field "upgraded", result.upgraded?
            j.field "duration_us", result.duration_us
            j.field "close_code", result.close_code if result.close_code
            j.field "note", Env.mask_secrets(result.note.not_nil!) if result.note
            # A cap truncated the inbound transcript: the `messages` array below also carries a
            # synthetic NOTICE_PREFIX row, but an agent reading only the envelope needs the fact
            # too. The sentence is gori-authored (no operator bytes), but mask it anyway for the
            # same one-rule reason the payloads are masked — this surface never emits raw.
            j.field "truncated", Env.mask_secrets(result.truncated.not_nil!) if result.truncated
            # Only when it FIRED: the session's stored list held gori's own advisory rows and
            # this send is one frame per row short of the capture. See `CLI::Run.ws_seed_rows`.
            if notice_dropped > 0
              j.field "ws_notice_rows_dropped", notice_dropped
              j.field "ws_notice_note", CLI::Run.ws_notice_dropped_note(notice_dropped)
            end
            if err = result.error
              kind = network_error_kind(err)
              j.field "error", Env.mask_secrets(err)
              j.field "error_kind", kind
              # A completed upgrade IS delivery on this surface: the origin answered the
              # handshake, so it has that request and every frame gori wrote after it. The
              # WS engine carries no `delivered?` of its own and `upgraded?` is the same
              # fact — any response byte at all.
              emit_send_error_code(j, kind, result.upgraded?)
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
                # `WsEngine.send` frames every outbound message before it reads a single
                # inbound frame, so the "out" rows appear here in `out_messages` order and
                # this counter is a safe index back into what was HANDED to the engine.
                out_seen = 0
                result.messages.each do |message|
                  authored = if message.direction == "out"
                               src = source[out_seen]?
                               out_seen += 1
                               src
                             end
                  j.object do
                    j.field "direction", message.direction
                    j.field "opcode", message.opcode
                    j.field "type", Serialize.ws_frame_type(message.opcode)
                    # What was actually FRAMED, not just what was meant. An agent driving a
                    # §5.1/§5.2/§5.4 test has to be able to read back that the unmasked frame,
                    # the RSV1 bit or the lying length header really went out — a transcript
                    # that only echoes the payload is asking to be taken on trust.
                    j.field "frame", Store::WsOutMessage.new(message.opcode, message.payload, message.shape).shape_label(message.direction == "out")
                    if code = ws_close_code(message)
                      j.field "close_code", code
                      reason = message.payload[2, message.payload.size - 2]
                      j.field "close_reason", Serialize.text(String.new(reason).scrub) unless reason.empty?
                    end
                    # ONE masked buffer feeds both renderings, so they cannot disagree.
                    # They did: `payload` ran through `mask_secrets` while `payload_base64`
                    # beside it was a bare encode of the raw bytes — and since masking is
                    # the exact inverse of the expansion, the same object reported the
                    # STORED spelling in one field and printed the substituted value in the
                    # clear in the next (`bad\xff\xfeWHEREVAL`, base64, unmasked). Masking a
                    # value in one rendering and not another is not masking it.
                    masked = Env.mask_secrets(String.new(message.payload)).to_slice
                    if message.opcode == 1
                      j.field "payload", String.new(masked).scrub
                      # JSON-RPC has no way to carry a byte that is not valid UTF-8, so
                      # `payload` above is U+FFFD-substituted for exactly the payload an
                      # §8.1/§5.6 test is about. The real bytes go beside it instead of
                      # being unreadable on every surface (they are in the BLOB column).
                      unless String.new(masked).valid_encoding?
                        j.field "payload_base64", Base64.strict_encode(masked)
                      end
                    else
                      j.field "binary", true
                      j.field "payload_base64", Base64.strict_encode(masked)
                    end
                    # Only when it FIRED — the same rule `request_line_rewritten` follows
                    # (`send_request`): gori changed the operator's bytes, so the surface
                    # reporting the send has to say so. Masking makes the change invisible
                    # in `payload` on its own, because it maps the substituted value back to
                    # the `$NAME` that produced it, and the result then reads exactly like a
                    # byte-exact replay. The AUTHORED form goes beside it so an agent can see
                    # both ends of the substitution rather than infer one.
                    if authored && authored.payload != message.payload
                      j.field "payload_expanded", true
                      j.field "payload_authored",
                        Serialize.text(Env.mask_secrets(String.new(authored.payload)).scrub)
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

      # The refusal for a `send_websocket` whose TEXT payloads still name a var that resolves
      # to nothing, or nil when they all resolve. Each frame is expanded on its own AFTER
      # `Repeater::Plan` built the handshake, so the builder's check (#519) never sees a
      # message payload — this is that gate for the payloads (#524), run before the dial.
      #
      # The ready-to-send plan for one `send_request`, or the error Result to return as-is.
      # `Repeater::Plan` owns the assembly (env expansion, the Content-Length policy, target
      # parsing, SNI, host overrides, the gated dialer); everything left here is MCP's own
      # argument parsing.
      private def build_send_plan(h, ob : Outbound) : {Repeater::Plan, Bool} | Result
        opts, rewrote = present?(h, "h2_fields") ? {field_native_plan_options(h), false} : send_plan_options(h)
        {Repeater::Plan.build(opts, ob), rewrote}
      rescue ex : Repeater::PlanError
        send_plan_error(ex, "url")
      end

      # MCP's wording for a builder refusal. Exhaustive on `Reason` so a new builder failure
      # reaches the agent as a coded INVALID_ARGUMENT rather than a bare exception string.
      private def send_plan_error(ex : Repeater::PlanError, field : String) : Result
        detail = ex.detail
        message =
          case ex.reason
          in Repeater::PlanError::Reason::NoRequest         then "the request is empty"
          in Repeater::PlanError::Reason::NoTarget          then "'url' is required"
          in Repeater::PlanError::Reason::BadTarget         then "could not parse a target host from #{detail.inspect}"
          in Repeater::PlanError::Reason::UnsupportedScheme then "unsupported scheme: #{detail} (only http/https)"
          in Repeater::PlanError::Reason::UnresolvedEnv     then env_unresolved_error(detail)
          end
        err(message, "INVALID_ARGUMENT", field: field)
      end

      # Either replays a persisted repeater (repeater_id), repeaters a captured flow
      # (flow_id), or builds from url/raw/method args — normalized to the one option set
      # `Repeater::Plan` consumes. Raises `Gori::Error` on bad arguments (`send_request`
      # turns that into a clean message).
      # Parse the `h2_fields` argument into the exact HPACK field list to encode. Accepts a
      # JSON array of two-element `[name, value]` arrays (or a JSON-encoded string of the same,
      # since LLM clients vary). NOTHING is normalized — a leading colon (`:scheme`), a leading
      # space in a value, an uppercase name, a repeated pseudo are all kept verbatim: they are
      # the payload. Raises `Gori::Error` (a clean message) on a shape that is not a pair list.
      private def parse_h2_fields(h) : Array({String, String})
        raw = h["h2_fields"]?
        arr = raw.try(&.as_a?)
        if arr.nil? && (s = raw.try(&.as_s?))
          arr = (JSON.parse(s).as_a? rescue nil)
        end
        raise Gori::Error.new("'h2_fields' must be an array of [name, value] pairs") unless arr
        fields = [] of {String, String}
        arr.each do |item|
          pair = item.as_a?
          raise Gori::Error.new("each 'h2_fields' entry must be a [name, value] pair") unless pair && pair.size == 2
          name = pair[0].as_s?
          value = pair[1].as_s?
          raise Gori::Error.new("'h2_fields' names and values must both be strings") if name.nil? || value.nil?
          fields << {name, value}
        end
        raise Gori::Error.new("'h2_fields' must not be empty") if fields.empty?
        fields
      end

      # The request body for a field-native send: `body` as UTF-8, or `body_base64` for raw
      # bytes (a body an operator wants to send exactly, e.g. a protobuf/gRPC frame). Verbatim
      # — no `$VAR` expansion, matching the "the fields ARE the message" contract of this path.
      private def h2_body_arg(h) : Bytes?
        if b64 = str(h, "body_base64")
          return Base64.decode(b64) rescue raise Gori::Error.new("'body_base64' is not valid base64")
        end
        str(h, "body").try(&.to_slice)
      end

      # The option set for a field-native h2 send — dispatched from `build_send_plan` so it is
      # NOT another branch inside `send_plan_options`. `url` still resolves the DIAL origin
      # (host/port/scheme), but every pseudo-header and field goes on the wire as given — so a
      # `:scheme` that disagrees with the connection, a duplicate `:method`, an out-of-order or
      # unknown pseudo, `:protocol` and a leading-space value are all sendable, none of which
      # the h1-text carrier can hold (F7/F8/F11). It cannot ride with a stored source
      # (flow_id/repeater_id replay their own bytes).
      private def field_native_plan_options(h) : Repeater::PlanOptions
        if present?(h, "flow_id") || present?(h, "repeater_id")
          raise Gori::Error.new("h2_fields cannot be combined with flow_id or repeater_id")
        end
        fields = parse_h2_fields(h)
        scheme, host, port = RequestBuilder.origin(h)
        Repeater::PlanOptions.new(
          h2_fields: fields, h2_body: h2_body_arg(h),
          origin: Repeater::Origin.new(scheme, host, port),
          http2: true, verify: !bool_arg(h, "insecure", false) && @verify_upstream,
          timeout: send_timeout(h), overrides: HostOverrides.load(store))
      end

      # The option set plus "did gori rewrite the stored request line?" — the second half is
      # not derivable from `PlanOptions`, and `send_request` has to report it (see the
      # `flow_id` branch below).
      private def send_plan_options(h) : {Repeater::PlanOptions, Bool}
        if present?(h, "flow_id") && present?(h, "repeater_id")
          raise Gori::Error.new("pass only one of flow_id or repeater_id")
        end
        verify = !bool_arg(h, "insecure", false) && @verify_upstream
        timeout = send_timeout(h)
        # Read up front, not inside the `flow_id` branch that uses it: an argument validated in
        # one branch and ignored in another is the same silent-substitution trap one level up.
        keep_request_line = bool_arg(h, "keep_request_line", false)
        # Honor the project's host overrides on the direct-dial path (parity with the live
        # proxy). nil/empty is behaviorally identical to no override.
        overrides = HostOverrides.load(store)

        if present?(h, "repeater_id")
          id = int(h, "repeater_id")
          raise Gori::Error.new(id_error(h, "repeater_id")) unless id
          rec = store.get_repeater(id)
          raise Gori::Error.new("no repeater with id #{id}") unless rec
          if Repeater::WsEngine.upgrade_request?(String.new(rec.request))
            raise Gori::Error.new("repeater #{id} is a WebSocket upgrade — use send_websocket")
          end
          # Respect the repeater's auto-Content-Length setting (the TUI Repeater does):
          # only recompute CL when it's on, so a deliberately hand-set CL is preserved.
          return {Repeater::PlanOptions.new([rec.request], default_target: rec.target,
            http2: bool_arg(h, "http2", rec.http2?), sni: rec.sni,
            auto_content_length: rec.auto_content_length?, verify: verify,
            timeout: timeout, overrides: overrides), false}
        end
        if present?(h, "flow_id")
          id = int(h, "flow_id")
          raise Gori::Error.new(id_error(h, "flow_id")) unless id
          detail = store.get_flow(id)
          raise Gori::Error.new("no flow with id #{id}") unless detail
          # A stored ABSOLUTE-form request line is a proxy artifact on a proxy capture and the
          # PAYLOAD on a flow gori recorded from a direct send — routing / cache-poisoning /
          # SSRF probes are written that way, and MCP's own `send_request{raw, verbatim}` can
          # produce one. So the rewrite stays the default (every plaintext-HTTP capture needs
          # it), but it is now REPORTED (`request_line_rewritten`) and `keep_request_line`
          # turns it off — the same pair `gori run repeater --keep-request-line` has. Without
          # it an agent had no route to the probe at all: the rewrite was silent and there was
          # no argument to prevent it.
          flow = Repeater::FlowRequest.build(detail, rewrite_absolute_form: !keep_request_line)
          # Default to how the flow was captured, but honor an EXPLICIT http2 either way —
          # `bool_arg` returns `flow.http2` only when the arg is absent, so `http2:false`
          # can now downgrade an h2 capture to h1 (it used to be silently ignored because
          # `false || flow.http2` kept h2). Carry the captured SNI so an origin where
          # SNI ≠ Host (domain fronting / multi-cert vhost) presents the right certificate,
          # matching `gori run repeater`.
          # `auto_content_length` is deliberately OFF here (it used to default ON, silently):
          # this tool documents a flow replay as byte-exact, and a captured
          # `Content-Length: 99` over a 2-byte body is the CL-desync probe the operator
          # wants re-sent, not a mistake to correct. `resync_cl_after_expansion` keeps the
          # one case that must still recompute — a `$KEY` in the body changing its length.
          #
          # `expand_request` is off here for the one reason `auto_content_length` already was:
          # a captured flow's bytes are EVIDENCE, and the operator authored none of them. It
          # ran `Env.expand_wire`, whose head pass PROMOTES a bare LF to
          #     CRLF. A bare-LF header terminator is a front-end/back-end desync primitive gori
          #     can already produce (`verbatim`) and stores byte-exact; replay silently
          #     destroyed it and still reported a clean send.
          # With expansion off there is no expansion to resync a Content-Length after, so
          # `resync_cl_after_expansion` goes with it: the stored framing ships exactly as
          # captured, which is what a CL/TE desync capture is for.
          # `evidence: true` ALONGSIDE the two flags, not instead of them, and this is the
          # second time that distinction has cost a round. The flags reach the BUILDER;
          # `evidence` is what reaches the SENDER, where a DECLARED session binding is
          # deliberately deferred to (`expand_requests`' own comment says so). Without it an
          # extract rule named `TOKEN`/`filter`/`where` rewrote a stored `GET /api?$TOKEN=1`
          # into `GET /api?SECRETTOKEN123=1` on the wire while this tool still reported the
          # stored target — the exact thing `expand_request: false` was added to stop, one
          # layer further down. `gori run repeater <flow-id>` already passed `evidence: true`,
          # so the two surfaces reached "the same end state" by different mechanisms and only
          # one of them was actually byte-exact.
          #
          # The flags stay because they are NOT implied: `expand_request: false` is also what
          # keeps `downgrade_request_line` off this path, and an `HTTP/2` version line in a
          # capture is the operator's to replay.
          {Repeater::PlanOptions.new([flow.bytes], default_target: flow.target,
            expand_request: false, evidence: true,
            auto_content_length: false,
            http2: bool_arg(h, "http2", flow.http2), sni: flow.sni, verify: verify,
            timeout: timeout, overrides: overrides), flow.rewrote_request_line}
        else
          # `RequestBuilder` already expanded, framed and range-checked this one, with
          # sharper messages than a re-parse could give — so the origin is handed over
          # pre-resolved and the bytes are taken verbatim (a second `Env.expand_wire` would
          # double-expand a `$KEY` whose value itself looks like a token).
          built = RequestBuilder.build(h)
          # ONE reading of "these bytes are literal", `RequestBuilder`'s — which also treats
          # `raw_base64` as verbatim, since encoding octets IS saying they are the message.
          # Reading `verbatim` again through `bool_arg` here let the builder and this gate
          # disagree about the same call.
          verbatim = RequestBuilder.verbatim?(h)
          {Repeater::PlanOptions.new([built.bytes], expand_request: false,
            auto_content_length: false,
            # The h2 half of the verbatim promise: `verbatim` means the bytes ARE the message, so
            # an uppercase field name is the RFC 9113 §8.2.1 conformance probe and not a
            # copy-paste artifact to repair. See `PlanOptions#preserve_field_case?`.
            preserve_field_case: verbatim,
            origin: Repeater::Origin.new(built.scheme, built.host, built.port),
            http2: bool_arg(h, "http2", false), verify: verify,
            timeout: timeout, overrides: overrides), false}
        end
      end

      # The scope decision for one active MCP request, built through the ONE seam every
      # surface shares. `Outbound.agent` is the strict Layer-1 policy an agent-driven
      # surface needs: a target the scope doesn't INCLUDE — or a project with no scope at
      # all, the most dangerous case since there is no guardrail — is refused unless the
      # caller passed allow_unscoped:true, which becomes a NAMED Unscoped(Operator) decision
      # that still leaves Layer 2 (Sandbox / exclude) in force.
      #
      # Every caller reads the flag through `bool_arg`, not `bool(…) || false`. The `|| false`
      # form erased the difference between "absent" and "unintelligible", so `allow_unscoped: 1`
      # came back as a SCOPE_BLOCKED whose remedy was the flag the caller had just passed, and
      # `insecure: 1` came back as a retryable NETWORK_ERROR — sending an agent into a retry
      # loop over an argument mistake. Same reasoning as `RequestBuilder.verbatim?`.
      private def outbound(allow_unscoped : Bool) : Outbound
        Outbound.agent(Scope.load(store), allow_unscoped)
      end

      # A refusal to send an active request outside (or without) scope.
      # SCOPE_BLOCKED is not retryable — the caller must add a scope include rule
      # or pass allow_unscoped:true.
      private def scope_blocked(sc : ScopeCheck) : Result
        reason = sc.unscoped? ? "no scope is configured for this project, so active requests are refused by default" : "target host #{sc.host} is outside the project's configured scope"
        err("#{reason}; #{Outbound.remedy(sc, "allow_unscoped:true")}",
          "SCOPE_BLOCKED", field: "url",
          details: JSON.parse({"scope_decision" => sc.decision, "host" => sc.host}.to_json))
      end

      # A SANDBOX refusal at the socket seam. Distinct from `scope_blocked`: Sandbox is a
      # HARD containment gate that allow_unscoped deliberately does NOT lift (the TUI and
      # `gori run repeater` have always enforced it that way; MCP used to let
      # allow_unscoped:true walk straight past it), so the message must not offer that flag
      # as the fix.
      private def sandbox_blocked(reason : String, host : String, field : String) : Result
        err("#{reason} — Sandbox mode blocks every request outside the scope allowlist; turn Sandbox off or add a scope include rule",
          "SCOPE_BLOCKED", field: field,
          details: JSON.parse({"scope_decision" => "sandbox", "host" => host}.to_json))
      end

      # The request-target (path) from the first line of a raw request, for
      # building the scheme://host/target URL the scope string/regex rules see.
      private def request_target(bytes : Bytes) : String
        Outbound.request_target(bytes)
      end

      # The URL the scope gate evaluates, anchored on the DIAL target rather than the request
      # LINE's host. The rule itself now lives in the seam (`Outbound.scope_url`) so the sweep
      # and Repeater paths get the same absolute-form handling this used to have alone.
      private def request_scope_url(plan : Repeater::Plan) : String
        Outbound.scope_url(plan.scheme, plan.host, request_target(plan.bytes))
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
