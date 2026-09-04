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
      # The TARGET is read alongside the request because BOTH are projected through
      # `mask_secrets` into the replies above, and reading only the request left a masking that
      # fired on the target ALONE unreported — which is the silent substitution this report
      # exists to prevent, not a case it was meant to skip. On a project whose `$SHOP` holds
      # `https://shop.example`, `create_repeater{target:"https://shop.example"}` answered
      # `"target":"$SHOP"` with nothing saying the two are the same bytes, and with the row
      # holding the author's spelling — so an agent reading the reply back had no way to tell a
      # display mask from a session that had actually been stored env-bound.
      private def emit_secrets_masked(j : JSON::Builder, raw : String, masked : String,
                                      target : String, masked_target : String) : Nil
        names = (masked_names(raw, masked) + masked_names(target, masked_target)).uniq!.sort!
        return if names.empty?
        j.field("secrets_masked") { j.array { names.each { |n| j.string n } } }
        j.field "secrets_masked_note",
          "#{Env.token_list(names)} #{names.size == 1 ? "resolves" : "resolve"} to a value present in this " \
          "session's request or target; the stored session keeps your bytes and only this result masks them"
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

      # The 1-based number the TUI paints on a Repeater sub-tab chip ("6:POST /api").
      #
      # Derived from the SAME order the TUI builds its strip in — `ORDER BY position, id`
      # (`Store#repeaters_meta`; `RepeaterController#reconcile` re-sorts to exactly that on
      # every peer commit, and `#subtab_labels` is `map_with_index { |tab, i| "#{i + 1}:…" }`)
      # — so an agent and the operator can name the same tab. Every repeater reply carries it
      # because that mapping was otherwise something a caller had to keep re-deriving, and
      # acting on the wrong tab is how an audit trail gets polluted.
      #
      # It is a RANK, not an address, and no tool here accepts it as a selector. It shifts on
      # every create, delete and move; `repeaters.id` is itself REUSED after a top-of-space
      # delete (`Store#delete_repeater` documents why that matters), so a caller acting on a
      # remembered number could reach a session it never read. `id` stays the only address.
      #
      # Unsaved and ephemeral sub-tabs (a gRPC or split-decode duplicate, `db_id == nil`) have
      # no row at all; `reconcile` sorts them after every saved one, so they never shift these.
      private def repeater_tui_index(id : Int64, ordered : Array(Store::RepeaterRecord)) : Int32?
        i = ordered.index { |r| r.id == id }
        i ? i + 1 : nil
      end

      # The same, for a caller with no ordered list already in hand. `repeaters_meta` carries
      # no response BLOBs, which is what makes this cheap enough to put on every reply.
      private def repeater_tui_index(id : Int64) : Int32?
        repeater_tui_index(id, store.repeaters_meta)
      end

      # A `tags` argument, normalised through the ONE grammar that owns it
      # (`Repeater::Tags`, which the TUI's `t` editor and the sub-tab filter both read): split
      # on whitespace/commas, leading `#` stripped, deduped case-insensitively, space-joined.
      # `nil` when the argument clears the column — an explicit blank, or a value that held no
      # token at all (`"#"`, `","`), which must not be stored as a tag nothing can match.
      #
      # Masked on the way in, unlike `target`/`sni`: a tag is a TUI caption and never reaches a
      # socket, so masking it costs nothing and keeps a secret out of a string the strip paints
      # (see `wire_field` for the fields where that reasoning does NOT hold).
      private def repeater_tags_arg(h, key : String = "tags") : String?
        raw = str(h, key)
        return nil unless raw
        Repeater::Tags.serialize(Repeater::Tags.parse(Env.mask_secrets(raw)))
      end

      # Everything a captured flow contributes to a new Repeater session.
      #
      # Extracted because `create_repeaters` seeds the SAME way per flow, and a second copy of
      # this block is the shape that has already cost this file twice: `create_repeater` once
      # hand-assembled head+body and so skipped all three jobs `FlowRequest.build` exists for
      # (below), and `Repeater::Plan#with_requests` once dropped `tls_preset` on a copy — a
      # forgotten field in a copy-constructor reports one thing and sends another.
      #
      # `nil` fields mean "the flow contributed nothing here", never "false": `http2` is a real
      # three-state at the call site (absent = inherit from the seed), and folding it in here
      # would flatten that.
      private record FlowSeed,
        target : String,
        request : String,
        http2 : Bool,
        rewrote_request_line : Bool = false,
        ws_messages : Array(Store::WsOutMessage)? = nil,
        notice_rows_dropped : Int32 = 0

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
      #
      # `built.sni` is deliberately NOT seeded: `gori run repeater create --flow` takes SNI
      # from the operator's flag alone, and this tool is its MCP twin.
      private def seed_from_flow(flow, flow_id : Int64, keep_request_line : Bool,
                                 seed_ws_messages : Bool) : FlowSeed
        built = Repeater::FlowRequest.build(flow, rewrite_absolute_form: !keep_request_line)
        target = built.target
        request = String.new(built.bytes)

        # The gate is `WsEngine.replayable?` and not `row.status == 101` (#742). A seed has to
        # produce a session `send_websocket` can actually run, and `WsEngine` re-opens a socket
        # from either handshake: an HTTP/1.1 `Upgrade:` head, or an RFC 8441 extended CONNECT
        # over h2 (#733: `CONNECT`, answered `200`). The status was the h1 handshake's,
        # standing in for the handshake itself — so the h2 shape took the ordinary-HTTP path
        # and its frames went nowhere, unmentioned.
        if Repeater::WsEngine.replayable?(String.new(flow.request_head)) && seed_ws_messages
          # Opcode and raw bytes, both kept. The `&& m.text?` filter dropped every captured
          # BINARY out-frame with no warning at all (the CLI at least printed one), and the
          # `.scrub` rewrote an invalid-UTF-8 TEXT payload to U+FFFD before it was stored —
          # so a §8.1/§5.6 test case could not be seeded into a repeater from MCP.
          # A `[gori]` advisory row is a diagnostic about the socket, not traffic it
          # carried; seeding one would replay gori's own sentence as a client frame. The
          # count rides back to the agent — a seed quietly holding fewer frames than the
          # capture is as wrong as one holding an extra. See `CLI::Run.ws_seed_rows`.
          rows, dropped = CLI::Run.ws_seed_rows(store.ws_messages(flow_id))
          msgs = rows.map { |m| Store::WsOutMessage.new(m.opcode, m.payload, CLI::Run.seed_shape(m.shape)) }
          return FlowSeed.new(target, request, built.http2, built.rewrote_request_line,
            ws_messages: msgs, notice_rows_dropped: dropped)
        end

        FlowSeed.new(target, request, built.http2, built.rewrote_request_line)
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

          seed = seed_from_flow(flow, flow_id, keep_request_line,
            seed_ws_messages: !present?(h, "ws_out_messages"))
          target = seed.target if target.nil? || target.empty?
          if request.nil? || request.empty?
            request = seed.request
            # Only when the SEEDED bytes are the ones being stored: an explicit `request`
            # argument was never rewritten.
            rewrote_request_line = seed.rewrote_request_line
          end
          http2 = seed.http2 if http2_val.nil?
          ws_messages_override = seed.ws_messages
          notice_rows_dropped = seed.notice_rows_dropped
        end
        return Result.new("missing required 'target'", is_error: true) if target.nil? || target.empty?
        return Result.new("missing required 'request'", is_error: true) if request.nil? || request.empty?

        sni = str(h, "sni")

        position = int(h, "position")
        if position.nil?
          return Result.new(id_error(h, "position"), is_error: true) if present?(h, "position") # present but non-integer
          position = store.next_repeater_position.to_i64
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
        # Same standing as `name`, and readable here for the same reason the flags above are:
        # `update_repeater` has always taken `tags` and this tool did not, so a session created
        # from MCP could only be grouped by a second call — and `create_repeaters` needs one
        # spelling to hand every row it seeds.
        tags = present?(h, "tags") ? repeater_tags_arg(h) : nil

        # WebSocket mode check — on the bytes that will be STORED and sent, not a projection,
        # and over both handshakes (`replayable?`).
        is_ws = Repeater::WsEngine.replayable?(request)

        # Read and REFUSED before the insert, like the frames below: an unknown preset name
        # applies nothing, so a session stored with one would dial with gori's bare hello on
        # every later send while the row claimed a browser. See `Settings.tls_preset_error`.
        tls_preset = tls_preset_arg(h)
        if err = Settings.tls_preset_error(tls_preset)
          return Result.new(err, is_error: true)
        end

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
          ws_http_only: bool_arg(h, "ws_http_only", false),
          tls_preset: tls_preset
        )

        return busy("failed to persist repeater (store busy or unwritable)") if id == 0

        if issue_id
          store.add_link(Store::LinkOwnerKind::Issue, issue_id,
            Store::LinkRefKind::Repeater, id)
        end

        # Checked, like the row insert above: the reply names the session's `name` and its
        # `ws_out_message_count`, so a rolled-back batch would report a label and a frame count
        # the row does not have. The row — and any `issue_id` link written just above it — is
        # already committed here, so the error says what EXISTS rather than claiming nothing
        # was created; a retry of the whole call would otherwise mint a second session.
        if name && !name.empty?
          unless store.set_repeater_name(id, name)
            return busy("repeater ##{id} exists (with any issue link this call made), but its NAME was NOT saved (store busy or unwritable); set it with update_repeater")
          end
        end

        # Its own batch after the name, like `update_repeater`'s: each write commits or rolls
        # back alone, so the refusal has to name which half landed rather than report a partial
        # create as one outcome.
        if tags
          unless store.set_repeater_tags(id, tags)
            return busy("repeater ##{id} exists (with any issue link and name this call made), but its TAGS were NOT saved (store busy or unwritable); set them with update_repeater")
          end
        end

        # WebSocket messages handling
        ws_count = ws_messages.try(&.size)
        if (messages = ws_messages) && !messages.empty?
          unless store.update_repeater_ws_messages(id, messages)
            return busy("repeater ##{id} exists (with any issue link this call made), but its WS FRAMES were NOT saved (store busy or unwritable); it holds none — set them with update_repeater")
          end
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
            j.field "tags", tags if tags
            j.field "position", position
            # The chip number the operator will see for this session — read AFTER the insert,
            # because `position` is a sort key and not a rank: a caller that passed
            # `position: 0` gets tab 1, whatever the column says.
            repeater_tui_index(id).try { |n| j.field "tui_index", n }
            # Only when it FIRED, and it is worth more here than on `send_request`: the stored
            # session no longer carries the absolute-form line, so this is the only record
            # that it was ever there.
            j.field "request_line_rewritten", true if rewrote_request_line
            emit_secrets_masked(j, request, masked_request, target, masked_target)
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

      # The `tls_preset` argument, normalised to the spelling the dial and the SSL-context
      # cache key see — so a tab stored as `"Chrome "` and one stored as `"chrome"` are one
      # policy rather than two contexts. Blank/absent is nil ("no override").
      #
      # An UNKNOWN name comes back as itself (lowercased) rather than as nil: the CALLER's
      # `Settings.tls_preset_error` is what names it, and folding a typo to "no override" here
      # would store a session that silently dials with gori's bare hello.
      private def tls_preset_arg(h) : String?
        raw = str(h, "tls_preset")
        return nil if raw.nil? || raw.strip.empty?
        Settings.tls_preset_normalize(raw)
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
        # Same shape as `sni` above, and for the same reason `update_repeater`'s SQL demands
        # it: every column is written unconditionally, so a call that does not mention this
        # one must hand back what the row already holds or a plain rename would drop the
        # tab's fingerprint. `present?` (not `.presence`) so an explicit `""` can CLEAR it.
        tls_preset = present?(h, "tls_preset") ? tls_preset_arg(h) : existing.tls_preset
        if err = Settings.tls_preset_error(tls_preset)
          return Result.new(err, is_error: true)
        end

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
                 ws_http_only: ws_http_only,
                 tls_preset: tls_preset
               )
          return busy("repeater NOT updated (store busy or unwritable); it is unchanged")
        end

        # These three are checked, but NOT with :466's wording: by the time they run the
        # request-side update has already COMMITTED, so "it is unchanged" would be a lie. Each
        # is its own writer batch, so the first rollback also means the ones after it were
        # never attempted — the error names which half landed instead of reporting a partial
        # write as one outcome (the rule `create_repeater`'s pre-insert parse states above).
        if present?(h, "name")
          unless store.set_repeater_name(id, name)
            return busy("request updated, but the NAME was NOT saved (store busy or unwritable) — the row keeps its previous name, and any tags/ws frames in this call were not attempted; retry")
          end
        end

        # Tags are the TUI's subtab labels (the `t` key) — the grouping a human uses to keep a
        # long session navigable. An explicit blank clears them.
        if present?(h, "tags")
          tags = repeater_tags_arg(h)
          unless store.set_repeater_tags(id, tags)
            return busy("request updated, but the TAGS were NOT saved (store busy or unwritable) — the row keeps its previous tags, and any ws frames in this call were not attempted; retry")
          end
        end

        # WebSocket messages handling
        ws_count = ws_msgs.try(&.size)
        if ws_msgs && !store.update_repeater_ws_messages(id, ws_msgs)
          # That write opens with `DELETE FROM ws_messages`, so a rollback leaves the session
          # on its PREVIOUS frames — reporting a `ws_out_message_count` for it would send the
          # old bytes on the next send while the caller believed the new ones were stored.
          return busy("request updated, but the WS FRAMES were NOT saved (store busy or unwritable) — the session still holds its previous frames; retry")
        end

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
            repeater_tui_index(id).try { |n| j.field "tui_index", n }
            j.field "ws_out_message_count", ws_count if ws_count
            emit_secrets_masked(j, request, masked_request, target, masked_target)
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

        ordered = store.repeaters_meta
        existing = store.get_repeater(id)
        return not_found("no repeater with id #{id}") unless existing

        # Read BEFORE the delete — it is the number the tab HAD, and it is the whole point of
        # echoing it: a caller that acted on "tab 6" needs the reply to name the object that
        # was actually destroyed, not `{"success":true}` and a re-listing to find out.
        was = repeater_tui_index(id, ordered)

        return busy("repeater NOT deleted (store busy or unwritable); it is unchanged") unless store.delete_repeater(id)

        # Renumber the survivors densely. `position` had no writer other than the insert, so a
        # close used to leave a gap that the next `create_repeater` collided with; now that
        # there is one, the workbench is repaired on the way out of every delete.
        rest = ordered.reject { |r| r.id == id }
        store.set_repeater_positions(rest.map(&.id))

        Result.new(JSON.build do |j|
          j.object do
            j.field "success", true
            j.field "id", id
            j.field "name", existing.name || ""
            if n = was
              j.field "was_tui_index", n
              # Only when something moved. A caller holding numbers from an earlier listing has
              # to be told they are stale — that is the failure mode this echo exists to close,
              # and staying silent would leave it believing tab 7 is still tab 7.
              j.field "note", "tab #{n} is gone; every session after it shifted down by one — " \
                              "re-read tui_index from get_repeater_context before naming a tab again" if rest.size >= n
            end
            j.field "remaining", rest.size
          end
        end)
      end

      # How many sessions one bulk call may create. A `flow_ids` list is the OpenAPI-import
      # path's second hop, so it is legitimately long — but each seed reads a whole flow
      # (`get_flow` materialises both BLOBs) and stores its request bytes, so an unbounded list
      # is an unbounded read. Refused up front and named, never truncated: a caller that asked
      # for 400 tabs and got 100 without a word would believe its workbench is complete.
      MCP_REPEATER_BULK_MAX = 100

      # The 1-based tab order, as the reply's `order` field: what every session's number IS
      # after the write this call just made. Emitted by the tools that CHANGE the order, so a
      # caller never has to re-list to learn the numbers it must use next.
      private def emit_repeater_order(j : JSON::Builder, rows : Array(Store::RepeaterRecord)) : Nil
        j.field("order") do
          j.array do
            rows.each_with_index do |r, i|
              j.object do
                j.field "id", r.id
                j.field "tui_index", i + 1
                j.field "name", r.name || ""
              end
            end
          end
        end
      end

      # A session's tag column with `add` folded in and `remove` taken out.
      #
      # Removal first, so `{tags_add: "x", tags_remove: "x"}` ends with the tag rather than
      # depending on which line ran last; and the result is re-parsed rather than concatenated,
      # so the case-insensitive de-duplication is `Repeater::Tags`' and not a second copy of it
      # written here.
      private def repeater_tags_edited(current : String?, add : Array(String),
                                       remove : Array(String)) : String?
        drop = remove.map(&.downcase).to_set
        kept = Repeater::Tags.parse(current).reject { |t| drop.includes?(t.downcase) }
        Repeater::Tags.serialize(Repeater::Tags.parse((kept + add).join(' ')))
      end

      # The label the TUI derives for a session with no stored name: "METHOD /path" off the
      # first non-blank request line. Through `SubtabFilter::Subject`, which is where that
      # derivation lives for the headless surfaces — a second copy here would be a second
      # answer to "what is this tab called".
      private def repeater_derived_name(r : Store::RepeaterRecord) : String
        Repeater::SubtabFilter::Subject.summary_of(String.new(r.request))
      end

      # The ids named in `key`, refused as a set when any of them is unknown.
      # Returns the ordered rows to act on, or the Result that refuses.
      #
      # Refusal comes BEFORE any write, and it NAMES the missing ids. Deleting the eight that
      # exist and reporting the ninth as skipped is a partial operation dressed as one outcome,
      # and on this tool the partial half is irreversible.
      private def repeater_bulk_selection(h, key : String) : {Array(Store::RepeaterRecord), Array(Store::RepeaterRecord)} | Result
        ids = id_list_arg(h, key)
        if ids.empty?
          return err("missing required #{key.inspect} — pass the database ids to act on " \
                     "(get_repeater_context lists them beside each tab's tui_index)",
            "INVALID_ARGUMENT", field: key)
        end
        if ids.size > MCP_REPEATER_BULK_MAX
          return err("#{ids.size} ids is over the #{MCP_REPEATER_BULK_MAX}-session cap for one bulk call — " \
                     "split it, so a short result is never mistaken for a complete one",
            "INVALID_ARGUMENT", field: key)
        end
        rows = store.repeaters_mcp
        by_id = rows.index_by(&.id)
        missing = ids.reject { |i| by_id.has_key?(i) }
        unless missing.empty?
          return err("no repeater with id #{missing.join(", ")} — NOTHING was changed. " \
                     "Ids are per-project and are REUSED after a session is deleted, so re-read them " \
                     "from get_repeater_context rather than replaying a remembered list",
            "NOT_FOUND", field: key,
            details: JSON.parse({"missing" => missing}.to_json))
        end
        {ids.map { |i| by_id[i] }, rows}
      end

      # Move one session to another place in the sub-tab strip.
      #
      # `to_index` is the 1-based chip number — the number a human says out loud — and it is
      # the one place on this surface where an index is accepted at all. That is deliberate and
      # narrow: it is a DESTINATION, not a selector. A stale `to_index` puts the tab somewhere
      # else; a stale index in `id`'s place would act on a different session entirely, which is
      # why `id` stays a database id everywhere (see `repeater_tui_index`).
      private def move_repeater(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id

        rows = store.repeaters_mcp
        from = repeater_tui_index(id, rows)
        return not_found("no repeater with id #{id}") unless from

        has_to = present?(h, "to_index")
        dir_s = str(h, "direction").try(&.strip.downcase).presence

        if has_to && dir_s
          return err("pass 'to_index' or 'direction', not both — they are two answers to one question " \
                     "and choosing one silently is how a tab lands somewhere nobody asked for",
            "INVALID_ARGUMENT", field: "to_index")
        end

        target =
          if has_to
            to = int(h, "to_index")
            return Result.new(id_error(h, "to_index"), is_error: true) unless to
            # REFUSED, not clamped. A clamp would move the tab somewhere other than where the
            # call named, report success, and leave the caller's model of the strip wrong.
            unless 1 <= to <= rows.size
              return err("'to_index' #{to} is outside this workbench — tab numbers are 1-based and there " \
                         "#{rows.size == 1 ? "is 1 session" : "are #{rows.size} sessions"} (1-#{rows.size})",
                "INVALID_ARGUMENT", field: "to_index")
            end
            to.to_i32
          elsif dir_s
            step = case dir_s
                   when "up"   then -1
                   when "down" then 1
                   else             return err("invalid 'direction' (expected #{MOVE_DIRS.join("|")})",
                     "INVALID_ARGUMENT", field: "direction")
                   end
            t = from + step
            if t < 1 || t > rows.size
              return err("repeater #{id} is already at the #{step < 0 ? "start" : "end"} of the workbench " \
                         "(tab #{from} of #{rows.size})", "INVALID_ARGUMENT", field: "direction")
            end
            t
          else
            return err("pass one of 'to_index' (the 1-based tab number to move it to) or " \
                       "'direction' (#{MOVE_DIRS.join("|")})", "INVALID_ARGUMENT", field: "to_index")
          end

        moved = target != from
        if moved
          ids = rows.map(&.id)
          ids.delete_at(from - 1)
          ids.insert(target - 1, id)
          unless store.set_repeater_positions(ids)
            return busy("repeater NOT moved (store busy or unwritable) — the workbench order is unchanged")
          end
          rows = store.repeaters_mcp
        end

        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "name", rows.find { |r| r.id == id }.try(&.name) || ""
            j.field "from_index", from
            j.field "to_index", target
            # A no-op placement is a SUCCESS, not an error: a caller declaring an order one
            # call at a time will land on this for every tab already in place, and refusing
            # would turn "already correct" into a failure to handle.
            j.field "moved", moved
            emit_repeater_order(j, rows)
          end
        end)
      end

      # Seed a Repeater tab from each of several captured flows — the last hop of the
      # OpenAPI/HAR path. `import_flows{kind:"oas"}` already parses the spec AND joins
      # `servers[0].url` with each operation path, so the base-path assembly a caller would
      # otherwise do by hand is work the importer has already done; what was missing was a way
      # to turn the resulting flows into tabs without one call each.
      #
      # Every flow is checked to EXIST before the first insert (`flow_row`, the row-only probe
      # — `get_flow` materialises both BLOBs and is read one flow at a time inside the loop, so
      # a long list never holds every response in memory at once).
      private def create_repeaters(h) : Result
        flow_ids = id_list_arg(h, "flow_ids")
        if flow_ids.empty?
          return err("missing required 'flow_ids' — pass the captured flow ids to seed from " \
                     "(list_history returns them; after import_flows, filter with query \"src:import\")",
            "INVALID_ARGUMENT", field: "flow_ids")
        end
        if flow_ids.size > MCP_REPEATER_BULK_MAX
          return err("#{flow_ids.size} flows is over the #{MCP_REPEATER_BULK_MAX}-session cap for one bulk call — " \
                     "split it, so a short result is never mistaken for a complete one",
            "INVALID_ARGUMENT", field: "flow_ids")
        end
        missing = flow_ids.reject { |fid| store.flow_row(fid) }
        unless missing.empty?
          return err("no flow with id #{missing.join(", ")} — NOTHING was created. Check list_history " \
                     "(a pruned or cleared flow is gone, and its id can come back on a different flow)",
            "NOT_FOUND", field: "flow_ids",
            details: JSON.parse({"missing" => missing}.to_json))
        end

        keep_request_line = bool_arg(h, "keep_request_line", false)
        name_prefix = str(h, "name_prefix").try { |v| Env.mask_secrets(v) }
        tags = present?(h, "tags") ? repeater_tags_arg(h) : nil

        created = [] of {Int64, Int64, String?, Bool, Int32}
        failed = [] of {Int64, String}
        pos = store.next_repeater_position

        flow_ids.each do |fid|
          flow = store.get_flow(fid)
          # It existed a moment ago; a peer can still delete between the sweep and here. Named
          # rather than silently short, like every other per-id outcome in this reply.
          next failed << {fid, "flow disappeared before it could be seeded"} unless flow

          seed = seed_from_flow(flow, fid, keep_request_line, seed_ws_messages: true)
          id = store.insert_repeater(
            target: wire_field(seed.target),
            request: stored_request(seed.request),
            http2: seed.http2,
            auto_cl: true,
            flow_id: fid,
            position: pos
          )
          next failed << {fid, "store busy or unwritable"} if id == 0
          # Saturating, for the same reason `next_repeater_position` saturates: a base already
          # at `Int32::MAX` (a poisoned `create_repeater{position}`) would otherwise overflow
          # this `Int32` on the second insert of the batch and abort mid-loop, leaving the
          # rows already committed unreported.
          pos = pos < Int32::MAX ? pos + 1 : Int32::MAX

          # Named off the bytes just stored, not off a re-read of the row: the round trip
          # would answer the same thing and cost a query, and it would have to assert the row
          # it just inserted is there.
          name = name_prefix.try { |pre| "#{pre}#{Repeater::SubtabFilter::Subject.summary_of(seed.request)}" }
          store.set_repeater_name(id, name) if name
          store.set_repeater_tags(id, tags) if tags
          if (msgs = seed.ws_messages) && !msgs.empty?
            store.update_repeater_ws_messages(id, msgs)
          end
          created << {fid, id, name, seed.rewrote_request_line,
                      seed.notice_rows_dropped}
        end

        rows = store.repeaters_mcp
        Result.new(JSON.build do |j|
          j.object do
            j.field "created_count", created.size
            j.field("created") do
              j.array do
                created.each do |(fid, id, name, rewrote, dropped)|
                  j.object do
                    j.field "flow_id", fid
                    j.field "id", id
                    j.field "name", name || ""
                    repeater_tui_index(id, rows).try { |n| j.field "tui_index", n }
                    j.field "request_line_rewritten", true if rewrote
                    j.field "ws_notice_rows_dropped", dropped if dropped > 0
                  end
                end
              end
            end
            unless failed.empty?
              j.field("failed") do
                j.array do
                  failed.each { |(fid, why)| j.object { j.field "flow_id", fid; j.field "reason", why } }
                end
              end
              j.field "note", "#{failed.size} of #{flow_ids.size} flows produced no session — the ones " \
                              "listed under created DID commit, so retry only the failed ids"
            end
            j.field "tags", tags if tags
          end
        end)
      rescue ex : Gori::Error
        Result.new(ex.message || "invalid repeater arguments", is_error: true)
      end

      # Delete several sessions by database id.
      #
      # `ids` only — never a filter. The set a caller SAW and the set this destroys are then
      # the same set, which a filter evaluated here could not promise: it would match whatever
      # the workbench holds now, and a session created since the listing would be deleted
      # without ever having been read. Narrow the listing (`get_repeater_context{filter}`),
      # then pass the ids it returned.
      private def delete_repeaters(h) : Result
        sel = repeater_bulk_selection(h, "ids")
        return sel if sel.is_a?(Result)
        targets, rows = sel

        unless bool_arg(h, "confirm", false)
          n = targets.size
          return err("refusing to delete #{n} repeater session#{n == 1 ? "" : "s"} without confirm:true — " \
                     "this cannot be undone: a session's request bytes, its stored WebSocket frames and any " \
                     "issue link pointing at it go with it",
            "CONFIRM_REQUIRED", field: "confirm",
            details: JSON.parse({"repeaters" => n, "ids" => targets.map(&.id)}.to_json))
        end

        deleted = [] of {Int64, String?, Int32?}
        failed = [] of Int64
        targets.each do |r|
          was = repeater_tui_index(r.id, rows)
          if store.delete_repeater(r.id)
            deleted << {r.id, r.name, was}
          else
            failed << r.id
          end
        end

        gone = deleted.map { |(id, _, _)| id }.to_set
        survivors = rows.reject { |r| gone.includes?(r.id) }
        # Renumber once, after the whole batch: renumbering per delete would make every
        # `was_tui_index` above relative to a different strip.
        store.set_repeater_positions(survivors.map(&.id))
        survivors = store.repeaters_mcp

        Result.new(JSON.build do |j|
          j.object do
            j.field "deleted_count", deleted.size
            j.field("deleted") do
              j.array do
                deleted.each do |(id, name, was)|
                  j.object do
                    j.field "id", id
                    j.field "name", name || ""
                    j.field "was_tui_index", was if was
                  end
                end
              end
            end
            unless failed.empty?
              j.field "failed" { j.array { failed.each { |id| j.number id } } }
              j.field "note", "#{failed.size} session#{failed.size == 1 ? "" : "s"} could NOT be deleted " \
                              "(store busy or unwritable) and #{failed.size == 1 ? "is" : "are"} unchanged; " \
                              "the ones under deleted are gone — retry only the failed ids"
            end
            j.field "remaining", survivors.size
            emit_repeater_order(j, survivors)
          end
        end)
      rescue ex : Gori::Error
        Result.new(ex.message || "invalid repeater arguments", is_error: true)
      end

      # Re-label several sessions at once: tags and name affixes, nothing else.
      #
      # LABELS ONLY, by design. `update_repeater` is the one that writes request bytes, target,
      # transport flags and WebSocket frames — a bulk tool that could reach those would let one
      # call change what many sessions PUT ON THE WIRE, and no per-id report makes that
      # reviewable. Everything this writes is a caption the strip paints.
      private def update_repeaters(h) : Result
        sel = repeater_bulk_selection(h, "ids")
        return sel if sel.is_a?(Result)
        targets, _rows = sel

        has_set = present?(h, "tags_set")
        set_tags = has_set ? repeater_tags_arg(h, "tags_set") : nil
        add = Repeater::Tags.parse(str(h, "tags_add").try { |t| Env.mask_secrets(t) })
        remove = Repeater::Tags.parse(str(h, "tags_remove").try { |t| Env.mask_secrets(t) })
        if has_set && !(add.empty? && remove.empty?)
          return err("pass 'tags_set' or 'tags_add'/'tags_remove', not both — one replaces the tag set " \
                     "and the others edit it, and applying both in some order is a rule nobody could predict",
            "INVALID_ARGUMENT", field: "tags_set")
        end
        prefix = str(h, "name_prefix").try { |v| Env.mask_secrets(v) }
        suffix = str(h, "name_suffix").try { |v| Env.mask_secrets(v) }
        renaming = !(prefix.nil? && suffix.nil?)

        unless has_set || renaming || !add.empty? || !remove.empty?
          return err("nothing to change — pass at least one of tags_set, tags_add, tags_remove, " \
                     "name_prefix, name_suffix",
            "INVALID_ARGUMENT", field: "tags_add")
        end

        updated = [] of {Int64, String?, String?, Bool}
        failed = [] of {Int64, String}

        targets.each do |r|
          new_tags = if has_set
                       set_tags
                     elsif add.empty? && remove.empty?
                       r.tags
                     else
                       repeater_tags_edited(r.tags, add, remove)
                     end

          # A row with no stored name shows a label DERIVED from its request line. Affixing to
          # that materialises it as a stored name, which is a real change — the caption stops
          # tracking the request — so those ids are named in the reply rather than left to be
          # noticed later.
          materialised = renaming && r.name.nil?
          new_name = renaming ? "#{prefix}#{r.name || repeater_derived_name(r)}#{suffix}" : r.name

          if new_tags != r.tags && !store.set_repeater_tags(r.id, new_tags)
            next failed << {r.id, "tags not saved (store busy or unwritable); the session is unchanged"}
          end
          if renaming && !store.set_repeater_name(r.id, new_name)
            next failed << {r.id, "name not saved (store busy or unwritable); any tag change in this call DID commit"}
          end
          updated << {r.id, new_name, new_tags, materialised}
        end

        rows = store.repeaters_mcp
        Result.new(JSON.build do |j|
          j.object do
            j.field "updated_count", updated.size
            j.field("updated") do
              j.array do
                updated.each do |(id, name, tags, materialised)|
                  j.object do
                    j.field "id", id
                    repeater_tui_index(id, rows).try { |n| j.field "tui_index", n }
                    j.field "name", name || ""
                    j.field "tags", tags || ""
                    j.field "name_materialised", true if materialised
                  end
                end
              end
            end
            if (mats = updated.count { |(_, _, _, m)| m }) > 0
              j.field "name_materialised_note",
                "#{mats} session#{mats == 1 ? "" : "s"} had no stored name, so the affix was applied to the " \
                "label gori derives from the request line and that label is now STORED — it no longer " \
                "follows the request if you edit it"
            end
            unless failed.empty?
              j.field("failed") do
                j.array do
                  failed.each { |(id, why)| j.object { j.field "id", id; j.field "reason", why } }
                end
              end
              j.field "note", "#{failed.size} of #{targets.size} sessions were not updated — the ones under " \
                              "updated DID commit, so retry only the failed ids"
            end
          end
        end)
      rescue ex : Gori::Error
        Result.new(ex.message || "invalid repeater arguments", is_error: true)
      end

      # The tools/list schemas for the Repeater tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_repeater_tools(j : JSON::Builder) : Nil
        return unless @allow_actions

        tool j, "create_repeater",
          "Create a new repeater tab/session in the database. Provide either ('target' and 'request') " \
          "OR ('flow_id') OR ('issue_id'). The reply carries both 'id' (the durable database id, " \
          "which every tool here takes) and 'tui_index' (the 1-based number the TUI paints on the " \
          "sub-tab chip, which is what the operator says out loud). To seed many tabs from one " \
          "import, use create_repeaters." do |s|
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
          s.field "tags", strprop("free-text tags for grouping tabs (the TUI subtab label). Space- or comma-separated, a leading # optional; stored deduped and space-joined. Filter on them with get_repeater_context{filter:\"tag:idor\"}")
          s.field "ws_out_messages", ws_out_messages_prop
          s.field "ws_keep_key", boolprop("WebSocket: send this session's own Sec-WebSocket-Key instead of a fresh one (default false)")
          s.field "tls_preset", strprop("TLS fingerprint this session presents: shape the ClientHello like #{Settings::TLS_PRESET_NAMES.join(" | ")} instead of gori's own, without touching the settings.json outbound_tls table. Stored on the session, so `send_request{repeater_id}`, `gori run repeater send` and a reopened TUI tab all present it. Two sessions on ONE host with different values dial two separate SSL contexts — that A/B is what it is for. The destination's client certificate, protocol range and permissive flag still apply. An APPROXIMATION of that client's hello, not a byte-exact JA3 match. https targets only")
          s.field "ws_http_only", boolprop("WebSocket: treat this session as plain HTTP — `gori run repeater send` and the TUI send the upgrade handshake as an ordinary request and read the 101 as a response, instead of performing the framed exchange. The bytes are unchanged and the session's messages are kept (default false)")
        end

        tool j, "update_repeater",
          "Update an existing repeater tab's properties by database id — including the request " \
          "bytes, target and transport flags. To re-label several tabs at once (tags and name " \
          "affixes only) use update_repeaters." do |s|
          s.field "id", intprop("repeater DATABASE id — not the number on the TUI sub-tab chip. get_repeater_context returns both, as 'db_id' and 'tui_index'"), required: true
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
          s.field "tls_preset", strprop("TLS fingerprint this session presents (#{Settings::TLS_PRESET_NAMES.join(" | ")}), overriding the settings.json outbound_tls policy for its own sends only. Pass \"\" to clear it; omit to leave it unchanged")
          s.field "ws_http_only", boolprop("WebSocket: treat this session as plain HTTP — the handshake is sent as an ordinary request and the 101 read as a response. The bytes are unchanged and the session's messages are kept")
        end

        tool j, "delete_repeater",
          "Delete a repeater tab by database id. The reply names what was destroyed — its id, " \
          "name and the 'was_tui_index' it had — because every later tab shifts down by one, so " \
          "tab numbers read before this call are stale afterwards. The remaining sessions are " \
          "renumbered densely." do |s|
          s.field "id", intprop("repeater DATABASE id — not the number on the TUI sub-tab chip"), required: true
        end

        tool j, "move_repeater",
          "Move a repeater session to another place in the TUI's sub-tab strip — the order the " \
          "operator sees, and the order a reopened TUI restores. Pass exactly one of 'to_index' " \
          "(absolute placement) or 'direction' (a one-step nudge). The reply returns the full " \
          "resulting order with each session's new tui_index, so there is no need to re-list." do |s|
          s.field "id", intprop("repeater DATABASE id of the session to move"), required: true
          s.field "to_index", intprop("the 1-based tab number to move it to (1 = first chip). This is the one argument on this surface that takes a tab NUMBER, and only because it is a destination: getting it wrong misplaces this session, it cannot act on a different one. Out of range is refused, never clamped")
          s.field "direction", enumprop("move one place: up toward tab 1, down toward the end. Refused when the session is already at that end", MOVE_DIRS)
        end

        tool j, "create_repeaters",
          "Seed a Repeater tab from each of several captured flows — the second hop of an " \
          "OpenAPI/HAR import. import_flows already parses the spec and joins servers[0].url " \
          "with each operation path, so the recipe is: import_flows{kind:\"oas\"} then " \
          "list_history{query:\"src:import\"} to collect the ids, then this. Every flow is " \
          "checked to exist before the first session is created; tabs append in the order given. " \
          "For one tab, or for a tab from raw request bytes, use create_repeater." do |s|
          s.field "flow_ids", id_list_prop("captured flow ids to seed from, in the order the tabs should appear (ids come from list_history). An array of integers, a single integer, or a comma list. At most #{MCP_REPEATER_BULK_MAX} per call"), required: true
          s.field "name_prefix", strprop("prepend this to each new tab's name; the rest of the name is the label gori derives from the request line (\"METHOD /path\"). Omit to leave the tabs deriving their own labels")
          s.field "tags", strprop("tags to place on every session created by this call (space- or comma-separated, leading # optional)")
          s.field "keep_request_line", boolprop("store each captured request line as-is instead of rewriting an absolute-form line (GET http://h/p) to origin-form (GET /p). Default false; see create_repeater for why this is permanent once stored")
        end

        tool j, "delete_repeaters",
          "Delete several repeater sessions by database id. Requires confirm:true — without it " \
          "the call is refused and reports how many it would have destroyed. This takes ids and " \
          "never a filter: narrow the listing with get_repeater_context{filter} first and pass " \
          "the ids it returned, so the set you read and the set destroyed are the same set. If " \
          "any id is unknown the whole call is refused and nothing is deleted. Cannot be undone." do |s|
          s.field "ids", id_list_prop("repeater DATABASE ids to delete (get_repeater_context returns them as 'db_id'). An array of integers, a single integer, or a comma list. At most #{MCP_REPEATER_BULK_MAX} per call"), required: true
          s.field "confirm", boolprop("must be true to actually delete; anything else refuses and reports the count"), required: true
        end

        tool j, "update_repeaters",
          "Re-label several repeater sessions at once: tags and name affixes, nothing else. It " \
          "never touches request bytes, target, transport flags or WebSocket frames — " \
          "update_repeater is the tool that writes those. If any id is unknown the whole call is " \
          "refused and nothing is changed." do |s|
          s.field "ids", id_list_prop("repeater DATABASE ids to re-label. An array of integers, a single integer, or a comma list. At most #{MCP_REPEATER_BULK_MAX} per call"), required: true
          s.field "tags_set", strprop("replace each session's tags with these (space- or comma-separated; an empty string clears them). Mutually exclusive with tags_add/tags_remove")
          s.field "tags_add", strprop("add these tags to each session, keeping the ones it already has (deduped case-insensitively)")
          s.field "tags_remove", strprop("remove these tags from each session; tags it does not have are ignored")
          s.field "name_prefix", strprop("prepend this to each session's name. A session with no stored name has one derived from its request line — affixing materialises that label as a stored name, and the reply names the sessions where that happened")
          s.field "name_suffix", strprop("append this to each session's name (same materialising note as name_prefix)")
        end
      end
    end
  end
end
