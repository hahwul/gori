require "json"
require "../../env"
require "../../store"

module Gori
  module MCP
    class Tools
      # The request bytes to PERSIST: the author's own, verbatim.
      #
      # These used to be `Env.mask_secrets(request).to_slice`, and that is a draft-time
      # transform applied to the operator's authored test case — the P7 line. `mask_secrets`
      # resolves against `Env.masking_vars`, which folds in `Bindings#held_values`, so an
      # agent that typed a LIVE token had gori rewrite it to `$CTOK` **in the stored row**.
      # No other writer does this: the TUI persists what the operator typed
      # (`RepeaterController#save_current_repeater`) and so does `gori run repeater`.
      #
      # It was not merely surprising, it SPLIT the surfaces. `flow_id` survives an
      # `update_repeater` that replaces every byte, and the TUI turns `flow_id` into
      # `RepeaterView#evidence?` — which by design does NOT expand `$NAME` (a capture's
      # `$filter` is a byte the origin saw, not a reference anybody wrote). So one stored row
      # put `Authorization: Bearer $CTOK` on the wire from the TUI and the real token from
      # MCP and the CLI, under `✓ sent → 200` on all three.
      #
      # Redaction is kept where it belongs: on the way OUT. Every field this tool returns to
      # the LLM (`summary`, `target`, `name`) is still derived from a masked copy, exactly as
      # `send_request`'s reply already separates `wire` from its masked display. What changes
      # is that a value the AUTHOR put in a request draft is stored the way they wrote it —
      # the same standing as an operator typing it into the TUI editor, and the same standing
      # `flows` already gives it for captured traffic. `bindings.cr`'s redaction guarantee
      # names this exception alongside the capture one.
      private def stored_request(request : String) : Bytes
        request.to_slice
      end

      # A repeater field that REACHES THE WIRE, to PERSIST: the author's own, verbatim.
      #
      # `target` and `sni` used to go through `Env.mask_secrets` on the way in, justified as
      # "short author-typed fields with no wire semantics of their own … re-expanded
      # identically by every surface". Half of that is true and the half that is not destroys
      # the value:
      #
      #   * **They have wire semantics.** `sni` IS the TLS `server_name` extension — the field
      #     a vhost-confusion, certificate-routing or CDN-origin test exists to control — and
      #     `target` is the dial tuple, which also supplies the ClientHello ServerName whenever
      #     `sni` is absent. Neither is a label.
      #   * **The two ends do not share a vocabulary.** Masking resolves against
      #     `Env.masking_vars`, which folds in every session-binding value currently held
      #     (including disabled rules); the send path resolves with `Env.effective_vars` — env
      #     vars only — and `Repeater::Plan` additionally runs
      #     `refuse_unresolved(Env.unresolved(s, deferred: nil))`, which refuses a declared
      #     binding name outright. So a binding value masked into an SNI mints a `$NAME` that
      #     can never resolve on any send path, from any surface. A one-way door.
      #
      # An author who typed `prod-edge-07.internal.example.com` while a rule bound `$edge` to
      # `prod-edge-07` got `$edge.internal.example.com` in the row, every send refused, the
      # original string unrecoverable, and a prescription ("set the env var") that would put a
      # GUESSED hostname in the ClientHello of a vhost test. `update_repeater` re-reads and
      # re-masks a field the caller never mentioned, so a plain RENAME destroyed an SNI the
      # CLI had stored correctly.
      #
      # Same seam, same reason and same resolution as `stored_request` (round 5) and the
      # WebSocket-frame store (round 6): a store row is a claim that those exact bytes are the
      # author's. Redaction stays on the way OUT — `masked_target` still feeds every field
      # this tool returns to the LLM. `name` and `tags` keep masking on the way in because
      # they are TUI labels and never reach a socket.
      private def wire_field(value : String) : String
        value
      end

      # Only when it FIRED. `summary` is the masked projection, so without this an author who
      # sent a live value reads a summary spelling it `$CTOK` with no statement anywhere that
      # the two are the same bytes — a silent substitution where a named report belonged.
      private def emit_secrets_masked(j : JSON::Builder, raw : String, masked : String) : Nil
        names = masked_names(raw, masked)
        return if names.empty?
        j.field("secrets_masked") { j.array { names.each { |n| j.string n } } }
        j.field "secrets_masked_note",
          "#{Env.token_list(names)} #{names.size == 1 ? "resolves" : "resolve"} to a value present in this " \
          "request; the stored request keeps your bytes and only this result masks them"
      end

      # The names `mask_secrets` rewrote in these bytes, so the reply can name them. gori no
      # longer edits the stored draft, but an author who handed over a live credential should
      # be told gori recognised one rather than left to infer it from a `summary` that reads
      # differently from what they sent. A name the author TYPED as `$NAME` is excluded — it
      # was already `$NAME` before the pass and nothing was substituted for it.
      private def masked_names(raw : String, masked : String) : Array(String)
        return [] of String if raw == masked
        prefix = Settings.env_prefix
        return [] of String if prefix.empty?
        Env.masking_vars.keys
          .select { |n| masked.includes?("#{prefix}#{n}") && !raw.includes?("#{prefix}#{n}") }
          .sort!
      end

      private def create_repeater(h) : Result
        issue_id = int(h, "issue_id")
        return Result.new(id_error(h, "issue_id"), is_error: true) if issue_id.nil? && present?(h, "issue_id")
        flow_id = int(h, "flow_id")
        return Result.new(id_error(h, "flow_id"), is_error: true) if flow_id.nil? && present?(h, "flow_id")

        target = str(h, "target")
        # `request_base64` wins over `request`: it is the byte-exact form, the only way to
        # seed a repeater whose stored bytes carry a latin-1 header value, an invalid-UTF-8
        # traversal payload, or a binary body. A JSON string reaches the store as its UTF-8
        # encoding, so those bytes could previously only arrive via a Burp XML file on disk.
        request = base64_str(h, "request_base64") || str(h, "request")

        if issue_id
          issue = store.get_issue(issue_id)
          return not_found("no issue with id #{issue_id}") unless issue
          if fid = issue.flow_id
            flow_id = fid
          elsif target.nil? || target.empty? || request.nil? || request.empty?
            return Result.new("issue #{issue_id} has no associated flow_id", is_error: true)
          end
        end

        # Three-state on purpose: `http2` absent means "inherit from the seed flow" (below),
        # which is not the same as `http2:false`. `auto_content_length` has no seed to inherit
        # from, so it is a plain default-on flag.
        http2_val = optional_bool_arg(h, "http2")
        http2 = http2_val || false
        auto_cl = bool_arg(h, "auto_content_length", true)
        # Read here rather than at its one use below, so an unintelligible value is refused on
        # EVERY call and not only on the flow-seeded ones — an argument that is validated in
        # one branch and ignored in another is the same silent-substitution trap one level up.
        keep_request_line = bool_arg(h, "keep_request_line", false)
        ws_messages_override = nil.as(Array(Store::WsOutMessage)?)
        rewrote_request_line = false
        notice_rows_dropped = 0

        if flow_id
          flow = store.get_flow(flow_id)
          return not_found("no flow with id #{flow_id}") unless flow

          # Seed through `FlowRequest.build`, exactly as `gori run repeater create --flow` and
          # `send_request{flow_id}` do. Hand-assembling head+body here skipped all three things
          # that function exists for:
          #   * `resync_truncated_head` — a capture cut at CAPTURE_MAX keeps its original
          #     `Transfer-Encoding: chunked` over a body with no terminating 0-chunk (or a
          #     Content-Length promising bytes that no longer exist), so the send blocked for
          #     the full 30 s io_timeout and put a partial chunked stream on the wire. That
          #     function's stated reason for existing is "so the repeater terminates instead
          #     of hanging"; this was the one caller that did not get it.
          #   * `origin_form_bytes` — every plain-HTTP flow gori captures has an ABSOLUTE-form
          #     request line (that is how a proxy client writes it), which was then sent
          #     verbatim to an origin that expects origin-form.
          #   * `build_target` — this was a third hand-rolled copy of the authority formula,
          #     without the ws/wss default-port fold or IPv6 re-bracketing the shared one has.
          #
          # `origin_form_bytes` is also the one of the three that is not always housekeeping:
          # on a flow gori recorded from a DIRECT send the absolute-form line is the routing /
          # cache-poisoning / SSRF payload, and baking the rewrite in here made the loss
          # PERMANENT — the stored session no longer holds the line, so not even
          # `send_repeater --verbatim` can recover it. `keep_request_line` turns it off and
          # `request_line_rewritten` reports it when it fires, matching
          # `gori run repeater --keep-request-line` and `send_request`.
          built = Repeater::FlowRequest.build(flow, rewrite_absolute_form: !keep_request_line)

          target = built.target if target.nil? || target.empty?
          if request.nil? || request.empty?
            request = String.new(built.bytes)
            # Only when the SEEDED bytes are the ones being stored: an explicit `request`
            # argument was never rewritten.
            rewrote_request_line = built.rewrote_request_line
          end
          http2 = built.http2 if http2_val.nil?
          # `built.sni` is deliberately NOT seeded here: `gori run repeater create --flow`
          # takes SNI from the operator's flag alone, and this tool is its MCP twin.

          if flow.row.status == 101 && !present?(h, "ws_out_messages")
            # Opcode and raw bytes, both kept. The `&& m.text?` filter dropped every captured
            # BINARY out-frame with no warning at all (the CLI at least printed one), and the
            # `.scrub` rewrote an invalid-UTF-8 TEXT payload to U+FFFD before it was stored —
            # so a §8.1/§5.6 test case could not be seeded into a repeater from MCP.
            # A `[gori]` advisory row is a diagnostic about the socket, not traffic it
            # carried; seeding one would replay gori's own sentence as a client frame. The
            # count rides back to the agent — a seed quietly holding fewer frames than the
            # capture is as wrong as one holding an extra. See `CLI::Run.ws_seed_rows`.
            rows, notice_rows_dropped = CLI::Run.ws_seed_rows(store.ws_messages(flow_id))
            ws_messages_override = rows
              .map { |m| Store::WsOutMessage.new(m.opcode, m.payload, CLI::Run.seed_shape(m.shape)) }
          end
        end

        return Result.new("missing required 'target'", is_error: true) if target.nil? || target.empty?
        return Result.new("missing required 'request'", is_error: true) if request.nil? || request.empty?

        sni = str(h, "sni")

        position = int(h, "position")
        if position.nil?
          return Result.new(id_error(h, "position"), is_error: true) if present?(h, "position") # present but non-integer
          position = store.repeaters_meta.size.to_i64
        elsif position < Int32::MIN || position > Int32::MAX
          return Result.new("'position' out of range", is_error: true)
        end

        # Masked for the REPLY only — see `stored_request` and `wire_field`. There is no
        # `masked_sni`: this reply never carried the SNI, so that projection existed for the
        # STORE alone, which is exactly what `wire_field` argues it must not do.
        masked_target = Env.mask_secrets(target)
        masked_request = Env.mask_secrets(request)
        # `name` is a TAB LABEL: it never reaches a socket, so masking it on the way in costs
        # nothing and keeps a secret out of a string the TUI paints. `target` and `sni` do
        # reach one, and are stored as authored — see `wire_field`.
        name = str(h, "name").try { |n| Env.mask_secrets(n) }

        # WebSocket mode check — on the bytes that will be STORED and sent, not a projection.
        is_ws = Repeater::WsEngine.upgrade_request?(request)

        # Parsed BEFORE the row is inserted: a refused frame must leave nothing behind. Doing
        # it after produced a half-created session — an error result and a persisted repeater
        # whose message list was empty — which is the "partial operation reported as one
        # outcome" this refusal exists to stop.
        ws_messages =
          if is_ws
            present?(h, "ws_out_messages") ? ws_out_messages_arg(h) : (ws_messages_override || [] of Store::WsOutMessage)
          end

        id = store.insert_repeater(
          target: wire_field(target),
          request: stored_request(request),
          http2: http2,
          auto_cl: auto_cl,
          flow_id: flow_id,
          position: position.to_i32,
          sni: sni.try { |s| wire_field(s) },
          ws_keep_key: bool_arg(h, "ws_keep_key", false),
          ws_http_only: bool_arg(h, "ws_http_only", false)
        )

        return busy("failed to persist repeater (store busy or unwritable)") if id == 0

        if issue_id
          store.add_link(Store::LinkOwnerKind::Issue, issue_id,
            Store::LinkRefKind::Repeater, id)
        end

        if name && !name.empty?
          store.set_repeater_name(id, name)
        end

        # WebSocket messages handling
        ws_count = ws_messages.try(&.size)
        if (messages = ws_messages) && !messages.empty?
          store.update_repeater_ws_messages(id, messages)
        end

        # Derive summary from the MASKED request — the raw request may carry a secret
        # in the request-target (e.g. ?token=…), and this field is returned to the LLM.
        line = masked_request.each_line.first?.try(&.strip) || ""
        parts = line.split(' ')
        s = "#{parts[0]?} #{parts[1]?}".strip
        s = line if s.empty?
        summary = s.size > 80 ? "#{s[0, 79]}…" : s

        Result.new(JSON.build { |j|
          j.object do
            j.field "id", id
            j.field "name", name || ""
            j.field "target", masked_target
            j.field "summary", summary
            j.field "position", position
            # Only when it FIRED, and it is worth more here than on `send_request`: the stored
            # session no longer carries the absolute-form line, so this is the only record
            # that it was ever there.
            j.field "request_line_rewritten", true if rewrote_request_line
            emit_secrets_masked(j, request, masked_request)
            # How many frames were actually stored, so an agent authoring a multi-frame
            # sequence can assert on it rather than take the count on trust.
            j.field "ws_out_message_count", ws_count if ws_count
            # Only when it FIRED. The seed holds fewer frames than the capture, and a count
            # an agent asserts on has to come with the reason it is short.
            if notice_rows_dropped > 0
              j.field "ws_notice_rows_dropped", notice_rows_dropped
              j.field "note", CLI::Run.ws_notice_dropped_note(notice_rows_dropped)
            end
          end
        })
      rescue ex : Gori::Error
        # A bad `request_base64` is caller input, not a server fault — return the message
        # instead of letting call()'s generic "tool error:" wrapper swallow it.
        Result.new(ex.message || "invalid repeater arguments", is_error: true)
      end

      # The `ws_out_messages` argument, in any of the three forms the schema advertises: an
      # array of strings, a newline-separated string, or an array of objects.
      #
      # The OBJECT form is what makes a binary frame expressible from MCP at all. Every
      # string form is a TEXT frame (opcode 1) — that was the only shape this tool could ever
      # produce, so `{"payload_base64": …}` (opcode 2 unless `opcode` says otherwise) is the
      # one addition, and it is where a later fin/rsv/mask field belongs too.
      # An unparseable entry RAISES rather than being dropped. `compact_map` used to discard
      # the nil, so `create_repeater` reported `isError:false` while storing 2 of the 4 frames
      # it was handed — and the run then "passed" against a sequence that was never sent. The
      # identical grammar on `send_websocket{messages}` has always refused the same entry;
      # one grammar gets one behaviour. Both callers already rescue `Gori::Error`.
      private def ws_out_messages_arg(h) : Array(Store::WsOutMessage)
        if arr = h["ws_out_messages"]?.try(&.as_a?)
          return arr.map do |item|
            msg, err = ws_out_message_item(item)
            raise Gori::Error.new(ws_entry_error("ws_out_messages", item, err)) unless msg
            msg
          end
        end
        return [] of Store::WsOutMessage unless str_val = str(h, "ws_out_messages")
        str_val.split('\n').compact_map { |l| l.strip.empty? ? nil : Store::WsOutMessage.text(l) }
      end

      # The refusal for one bad `ws_out_messages` / `messages` entry. The entry is echoed so a
      # caller building a long sequence can find it, and the parser's own sentence is appended
      # so the answer is "which field, and why" rather than "something in here".
      private def ws_entry_error(field : String, item : JSON::Any, detail : String?) : String
        "invalid '#{field}' entry #{item.to_json}#{detail ? " — #{detail}" : ""}"
      end

      # One `ws_out_messages` / `messages` entry, in any form the schema advertises.
      #
      # A bare STRING stays a plain TEXT frame — that is the overwhelmingly common case and
      # it must not acquire a syntax, because the moment a marker prefix means something a
      # payload starting with it becomes unsendable. A string that carries a `=` in the
      # `WsFrameSpec` grammar (`opcode=ping,text=hi`) is the scripted authoring form, shared
      # verbatim with `gori run repeater send --message-frame`; the OBJECT form is the same
      # fields spelled out, and is what a caller building JSON programmatically wants.
      # `{message, nil}` or `{nil, the reason}` — the same pair `WsFrameSpec.parse` returns,
      # so a caller reports rather than guesses.
      private def ws_out_message_item(item : JSON::Any) : {Store::WsOutMessage?, String?}
        if text = item.as_s?
          return Repeater::WsFrameSpec.parse(text) if ws_frame_spec?(text)
          return {Store::WsOutMessage.text(text), nil}
        end
        return {nil, "expected a string or an object"} unless obj = item.as_h?
        ws_out_message_object(obj)
      end

      # The OBJECT form, routed through the ONE parser the string form uses.
      #
      # It used to re-read the keys here, and that is the whole defect: `as_i?` returns nil
      # for the NAMED opcode the schema advertises, `as_bool?` returns nil for the `0`/`1` it
      # advertises for `fin`/`mask`, and every nil fell through to the encoder default. So a
      # PING went out as TEXT, a CLOSE as BINARY, `fin:0` as FIN=1 and `mask:0` masked — with
      # `isError:false`, and (through `ws_out_messages`) persisted into the project database,
      # so every later send from any surface replayed the wrong frame. `rsv`, `mask_key`,
      # `len` and any unknown key were dropped the same silent way.
      #
      # Building the spec string rather than reaching into `WsFrameSpec::Fields` keeps the
      # grammar — the name table, the range checks, the "unknown field" refusal — in the one
      # place that owns it. The two forms the schema presents as equivalent now are.
      private def ws_out_message_object(obj : Hash(String, JSON::Any)) : {Store::WsOutMessage?, String?}
        return {nil, "no frame fields (expected at least one of #{ws_object_field_list})"} if obj.empty?
        spec, err = ws_spec_from_object(obj)
        return {nil, err} unless spec
        Repeater::WsFrameSpec.parse(spec)
      end

      # Object key → `WsFrameSpec` key, for the SHAPE fields. `len` is accepted alongside
      # `declared_len` because the schema text has always named both.
      WS_OBJECT_SHAPE = {
        "opcode" => "opcode", "fin" => "fin", "rsv" => "rsv", "mask" => "mask",
        "mask_key" => "mask_key", "declared_len" => "len", "len" => "len",
      }
      # Object key → `WsFrameSpec` key, for the PAYLOAD. Exactly one may be present: two
      # payloads in one object have no defensible reading, and picking one silently is the
      # class of bug this method exists to remove.
      WS_OBJECT_PAYLOAD = {"text" => "text", "payload_base64" => "b64", "payload_hex" => "hex"}

      private def ws_object_field_list : String
        (WS_OBJECT_SHAPE.keys.to_a + WS_OBJECT_PAYLOAD.keys.to_a).join(", ")
      end

      # The object rendered as one `WsFrameSpec` spec, or the reason it cannot be. The payload
      # goes LAST because `text=` swallows the remainder of the spec — that is what lets a
      # payload contain a comma without an escape nobody would remember.
      private def ws_spec_from_object(obj : Hash(String, JSON::Any)) : {String?, String?}
        parts = [] of String
        payload = nil.as({String, String}?)
        obj.each do |k, v|
          if key = WS_OBJECT_SHAPE[k]?
            s = ws_scalar(v)
            return {nil, "bad #{k} #{v.to_json} (expected a string, number or boolean)"} unless s
            parts << "#{key}=#{s}"
          elsif key = WS_OBJECT_PAYLOAD[k]?
            return {nil, "pass only one of #{WS_OBJECT_PAYLOAD.keys.to_a.join(", ")}"} if payload
            s = v.as_s?
            return {nil, "bad #{k} #{v.to_json} (expected a string)"} unless s
            payload = {key, s}
          else
            return {nil, "unknown frame field #{k.inspect} (expected #{ws_object_field_list})"}
          end
        end
        parts << "#{payload[0]}=#{payload[1]}" if payload
        {parts.join(','), nil}
      end

      # A JSON scalar as the text `WsFrameSpec` validates. Lenient on the ENCODING (a number,
      # a boolean and their stringified forms all mean the same thing — clients and LLMs
      # serialize tool args every which way, and `Tools#bool`/`#int` exist for that reason),
      # strict on the VALUE: whatever comes out still has to satisfy the grammar.
      private def ws_scalar(v : JSON::Any) : String?
        case raw = v.raw
        when String  then raw
        when Bool    then raw.to_s
        when Int64   then raw.to_s
        when Float64 then (raw.finite? && raw == raw.trunc) ? raw.to_i64.to_s : nil
        end
      end

      # Does this string use the `WsFrameSpec` grammar? A leading `key=` in the known field
      # set, and nothing else. Deliberately narrow: `hello=world` is a payload, not a spec,
      # and misreading it would mean gori sending something other than what was asked for.
      private def ws_frame_spec?(s : String) : Bool
        # `valid_encoding?` guard, NOT a scrub: an invalid-UTF-8 message is a legitimate
        # WebSocket TEXT payload to send (`send.cr` keeps it unscrubbed on purpose), so the
        # string must not be rewritten — but PCRE2 raises `ArgumentError` on it, which
        # surfaced as an INTERNAL error instead of sending the frame. Such a string cannot
        # start with one of these ASCII keys anyway, so "not a spec" is the right answer.
        return false unless s.valid_encoding?
        s.matches?(/\A(opcode|fin|rsv|mask|mask_key|len|hex|b64|text)=/)
      end

      private def update_repeater(h) : Result
        id = int(h, "id")
        return Result.new("missing or invalid required 'id'", is_error: true) unless id

        existing = store.get_repeater(id)
        return not_found("no repeater with id #{id}") unless existing

        target = str(h, "target") || existing.target
        request = base64_str(h, "request_base64") || str(h, "request") || String.new(existing.request)
        # An explicitly-passed empty string is truthy in Crystal, so guard it here to
        # mirror create_repeater's invariant — a blank target/request can't be sent.
        return Result.new("target must not be empty", is_error: true) if target.empty?
        return Result.new("request must not be empty", is_error: true) if request.empty?

        http2 = bool_arg(h, "http2", existing.http2?)
        auto_cl = bool_arg(h, "auto_content_length", existing.auto_content_length?)

        sni = present?(h, "sni") ? str(h, "sni") : existing.sni
        ws_keep_key = bool_arg(h, "ws_keep_key", existing.ws_keep_key?)
        ws_http_only = bool_arg(h, "ws_http_only", existing.ws_http_only?)

        # Masked for the REPLY only. `target`/`sni` are stored as authored (`wire_field`) —
        # this is the write that made a plain RENAME destroy them: both fall back to the
        # EXISTING row when the caller did not mention them, so re-masking here rewrote a
        # field nobody touched.
        masked_target = Env.mask_secrets(target)
        masked_request = Env.mask_secrets(request)
        name = present?(h, "name") ? str(h, "name").try { |n| Env.mask_secrets(n) } : existing.name

        # Parsed before the first write, as in create_repeater: a refused frame must not leave
        # the target/request half-updated behind an error result.
        ws_msgs = present?(h, "ws_out_messages") ? ws_out_messages_arg(h) : nil

        unless store.update_repeater(
                 id: id,
                 target: wire_field(target),
                 request: stored_request(request),
                 http2: http2,
                 auto_cl: auto_cl,
                 sni: sni.try { |s| wire_field(s) },
                 ws_keep_key: ws_keep_key,
                 ws_http_only: ws_http_only
               )
          return busy("repeater NOT updated (store busy or unwritable); it is unchanged")
        end

        if present?(h, "name")
          store.set_repeater_name(id, name)
        end

        # Tags are the TUI's subtab labels (the `t` key) — the grouping a human uses to keep a
        # long session navigable. An explicit blank clears them.
        if present?(h, "tags")
          tags = str(h, "tags").try { |t| Env.mask_secrets(t).strip }
          store.set_repeater_tags(id, tags.presence)
        end

        # WebSocket messages handling
        ws_count = ws_msgs.try(&.size)
        store.update_repeater_ws_messages(id, ws_msgs) if ws_msgs

        # Derive the summary from the MASKED request, like create_repeater: the raw request may
        # carry a secret in the request-target (e.g. ?token=…) and this field goes to the LLM.
        line = masked_request.each_line.first?.try(&.strip) || ""
        parts = line.split(' ')
        s = "#{parts[0]?} #{parts[1]?}".strip
        s = line if s.empty?
        summary = s.size > 80 ? "#{s[0, 79]}…" : s

        Result.new(JSON.build { |j|
          j.object do
            j.field "id", id
            j.field "name", name || ""
            j.field "target", masked_target
            j.field "summary", summary
            j.field "position", existing.position
            j.field "ws_out_message_count", ws_count if ws_count
            emit_secrets_masked(j, request, masked_request)
            # `flow_id` is unchanged by this write, and it is not a label: the TUI turns it
            # into `RepeaterView#evidence?`, which suppresses `$NAME` expansion because a
            # capture's `$filter` is a byte and not a reference. Once these bytes are no
            # longer the flow's, that reading is wrong — so the row is reported as what it
            # now IS rather than left advertising a provenance none of its bytes have.
            # Clearing the column outright needs a store change (`update_repeater` does not
            # write `flow_id` at all); until then the disagreement is stated, not hidden.
            if (fid = existing.flow_id) && String.new(existing.request) != request
              j.field "flow_id", fid
              j.field "derived_from_flow_note",
                "repeater #{id} is still linked to flow #{fid}, but its request no longer holds that " \
                "flow's bytes — the TUI reads that link as \"these bytes are a capture\" and sends " \
                "$NAME literally there"
            end
          end
        })
      rescue ex : Gori::Error
        Result.new(ex.message || "invalid repeater arguments", is_error: true)
      end

      private def delete_repeater(h) : Result
        id = int(h, "id")
        return Result.new("missing or invalid required 'id'", is_error: true) unless id

        existing = store.get_repeater(id)
        return not_found("no repeater with id #{id}") unless existing

        return busy("repeater NOT deleted (store busy or unwritable); it is unchanged") unless store.delete_repeater(id)
        Result.new(JSON.build { |j| j.object { j.field "success", true } })
      end

      # The tools/list schemas for the Repeater tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_repeater_tools(j : JSON::Builder) : Nil
        return unless @allow_actions

        tool j, "create_repeater", "Create a new repeater tab/session in the database. Provide either ('target' and 'request') OR ('flow_id') OR ('issue_id')." do |s|
          s.field "target", strprop("absolute target URL (scheme+host+optional port), e.g. https://api.example.com")
          s.field "request", strprop("verbatim raw HTTP request bytes/text")
          s.field "request_base64", strprop("the raw HTTP request as base64 — the byte-exact form; use it when the request carries an octet a JSON string cannot (0x00, 0x80-0xFF, invalid UTF-8, a binary body). Overrides 'request'")
          s.field "http2", boolprop("use HTTP/2 (default false)")
          s.field "auto_content_length", boolprop("auto-calculate Content-Length header (default true)")
          s.field "flow_id", intprop("optional original flow id this repeater stems from")
          s.field "keep_request_line", boolprop("flow_id/issue_id seeding only: store the captured request line as-is instead of rewriting an absolute-form line (GET http://h/p) to origin-form (GET /p). Default false. The rewrite is PERMANENT once stored — not even send_request --verbatim can recover the line — so pass true when the absolute form is the payload. `request_line_rewritten:true` comes back whenever it fired")
          s.field "issue_id", intprop("optional issue id to populate target/request/messages from")
          s.field "position", intprop("tab position order index (optional, defaults to appending at end)")
          s.field "sni", strprop("optional TLS Server Name Indication override")
          s.field "name", strprop("optional custom name for the repeater tab")
          s.field "ws_out_messages", ws_out_messages_prop
          s.field "ws_keep_key", boolprop("WebSocket: send this session's own Sec-WebSocket-Key instead of a fresh one (default false)")
          s.field "ws_http_only", boolprop("WebSocket: treat this session as plain HTTP — `gori run repeater send` and the TUI send the upgrade handshake as an ordinary request and read the 101 as a response, instead of performing the framed exchange. The bytes are unchanged and the session's messages are kept (default false)")
        end

        tool j, "update_repeater", "Update an existing repeater tab's properties by database id." do |s|
          s.field "id", intprop("repeater database id"), required: true
          s.field "target", strprop("absolute target URL")
          s.field "request", strprop("verbatim raw HTTP request")
          s.field "request_base64", strprop("the raw HTTP request as base64 — the byte-exact form (see create_repeater). Overrides 'request'")
          s.field "http2", boolprop("use HTTP/2")
          s.field "auto_content_length", boolprop("auto-calculate Content-Length")
          s.field "sni", strprop("TLS SNI override")
          s.field "name", strprop("custom name for the repeater tab")
          s.field "tags", strprop("free-text tags for grouping tabs (the TUI subtab label); empty string clears them")
          s.field "ws_out_messages", ws_out_messages_prop
          s.field "ws_keep_key", boolprop("WebSocket: send this session's own Sec-WebSocket-Key instead of a fresh one")
          s.field "ws_http_only", boolprop("WebSocket: treat this session as plain HTTP — the handshake is sent as an ordinary request and the 101 read as a response. The bytes are unchanged and the session's messages are kept")
        end

        tool j, "delete_repeater", "Delete a repeater tab by database id." do |s|
          s.field "id", intprop("repeater database id"), required: true
        end
      end
    end
  end
end
