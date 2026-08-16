# The send path: what leaves the tab as WIRE BYTES — the editor text expanded (`$KEY`),
# marker chains rendered (`§…§`), the head terminated and Content-Length finalised — plus the
# h1/h2 and Auto-CL toggles that change those bytes, and where a Result lands on the way back.
# Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # {head, body} strings of the last HTTP response (nil until a send lands, or where the
  # "response" is a transcript rather than raw head+body bytes). Feeds the RESPONSE pane's
  # "copy as X" options (status+headers / body / raw).
  #
  # A WebSocket tab reading its HANDSHAKE RESPONSE card is NOT one of those cases: that card
  # shows a real HTTP 101 head (`apply_ws` seeds `@result` with it), so it gets the same
  # head/body/raw options every other response head gets. It is only the TRANSCRIPT that has
  # no head+body to split, and that is what `@resp_pane` distinguishes.
  def response_parts : {String, String}?
    return nil if @grpc_mode
    return nil if ws_mode? && !resp_handshake_active?
    res = @result
    return nil unless res
    {String.new(res.head), (b = res.body) ? String.new(b) : ""}
  end

  # The last HTTP response's raw {head, body} bytes — for the manual "Run active scan" action,
  # which rebuilds a synthetic flow from the current request + this response. nil until a send
  # lands (a response head is required), or in WS/gRPC mode where the active rules don't apply.
  def last_http_response : {Bytes, Bytes?}?
    return nil if ws_mode? || @grpc_mode
    res = @result
    return nil unless res
    return nil if res.head.empty?
    {res.head, res.body}
  end

  # This tab's last send as ONE side of a Comparer diff — the request that went out, the
  # response that came back, and the status/time the sender measured.
  #
  # It has to be built here rather than resolved from a flow, because a Repeater send does
  # not become one: WS, gRPC and split-decode tabs are session-only (`db_id` nil) and even
  # an ordinary send leaves no capture row. Comparing "the captured request" against "the
  # same request with one header changed" was the obvious use for this tab and the one
  # thing it could not reach.
  #
  # nil until a send lands. `request_bytes` can refuse (a group-framing send), which is a
  # statement about SENDING, not about reading: fall back to the response half alone rather
  # than withholding the whole slot.
  def comparer_slot : ComparerSlot?
    res = @result
    return nil unless res
    req = begin
      request_bytes
    rescue
      nil
    end
    ComparerSlot.from_exchange(
      "repeater", ComparerSlot.method_of(req), @target,
      req, nil, res.head.empty? ? nil : res.head, res.body,
      status: res.response.try(&.status), duration_us: res.duration_us, error: res.error)
  end

  def request_bytes : Bytes
    # BEFORE the hex branch on purpose — the hex buffer is a SNAPSHOT of this same editor,
    # so it carries the same chunk-scoped Content-Length and sending it verbatim is the
    # sharpest face of the refusal below.
    if reason = group_framing_refusal
      raise Fuzz::ChainError.new(reason)
    end
    return grpc_request_bytes if @grpc_mode                  # edited head + reframed body (owns its own hex buffer)
    return @req_hex_edit.not_nil!.to_bytes if @req_hex_edit  # byte-exact; NO auto-CL in hex mode
    return decoded_request_bytes if @decode_kind             # envelope + re-encoded decoded payload
    return marked_request_bytes unless marker_regions.empty? # §…§ inline Decoder chains applied on send
    finalize_wire(expanded_editor_bytes)
  end

  # `wire_text`, NOT `text`: `text` is the LF projection, and joining the buffer with LF
  # throws away every CR the capture carried in its BODY — where 0x0D is data, not a line
  # ending. expand_wire below normalizes the HEAD to CRLF either way, so the only thing this
  # changes is that body bytes now survive the round trip through the editor.
  private def expanded_editor_bytes : Bytes
    expanded_text_to_bytes(@editor.wire_text)
  end

  # Head terminator + auto-Content-Length: the last two steps every plain-text send
  # shares. Kept in one place so the single send and `pipeline_requests` cannot disagree
  # about the bytes they put on the wire.
  private def finalize_wire(raw : Bytes) : Bytes
    raw = ensure_head_terminator(raw)
    @auto_content_length ? sync_content_length(raw) : raw
  end

  # Append the CRLFCRLF head terminator to a request that carries none. Editor text with
  # no trailing blank line produced a request the origin could only wait on — it has no
  # way to know the headers ended — until something timed out, which the user saw as
  # "no response" and the origin logged as a 400/408. `pipeline_requests` has always
  # terminated its chunks; the single-send path did not.
  #
  # Only a HEAD-ONLY buffer can reach the append (expand_wire turns the editor's blank
  # line into CRLFCRLF, so a request WITH a body always has a terminator), which is why
  # trailing newlines here are line noise rather than body bytes: trim them, terminate once.
  private def ensure_head_terminator(raw : Bytes) : Bytes
    return raw if has_head_terminator?(raw)
    n = raw.size
    while n > 0 && (raw[n - 1] == 0x0A_u8 || raw[n - 1] == 0x0D_u8)
      n -= 1
    end
    terminate_head(raw[0, n])
  end

  # Env-expand the LF editor text and normalize to CRLF wire form. Uses
  # `Env.expand_wire` (gsub `/\r?\n/`) — NOT `split('\n').join("\r\n")` — so a `$KEY`
  # whose value itself carries a CRLF isn't doubled into `\r\r\n`, which would corrupt
  # the header line (or the head/body separator). Shared logic with the CLI/MCP repeater
  # send paths so the TUI can't disagree with them on the bytes it puts on the wire.
  #
  # Plus the one body-level fixup the editor OWES the wire: `expand_wire` normalizes the
  # head alone (a raw 0x0A in a body is a byte, not a line ending), but this editor holds
  # the request as an LF-joined line buffer, so a multipart body could never reach an
  # origin with the CRLF delimiters RFC 2046 requires. See
  # `FlowRequest.normalize_multipart_body` for why that step is opt-in here and not
  # inside `expand_wire`.
  #
  # For an EVIDENCE tab the `$KEY` half is off and only the CRLF half runs. `expand_wire`
  # is two passes welded together — substitute, then promote the head's bare LFs — and only
  # the second is something this editor owes the wire. The first is a draft-time policy:
  # a capture's `$filter`/`$top`/`$where`/`$IFS`/`$user.name` are bytes the origin sent,
  # and substituting a project value into one sends a request nobody captured, which is
  # precisely what `Repeater::PlanOptions#evidence?` and `FuzzerView#evidence_template`
  # already say for the same bytes on every other surface. The CRLF promotion is kept and
  # done explicitly because `TextArea#insert_newline` gives a typed line a bare LF and
  # names `expand_wire` as what promotes it — shipping one inside a head is itself a
  # front-end/back-end desync primitive, i.e. a different test than the one on screen.
  private def expanded_text_to_bytes(text : String) : Bytes
    wire = @evidence ? Env.expand_wire(text, operator_env_vars) : Env.expand_wire(text)
    Repeater::FlowRequest.normalize_multipart_body(wire)
  end

  # The env vars an EVIDENCE tab may substitute: every registered name EXCEPT the ones the
  # CAPTURE itself brought in (`@evidence_env_names`).
  #
  # The blanket "evidence expands no `$` at all" this replaces was right about the capture
  # and wrong about the operator. A tab opened with ^R off History is the commonest place
  # there is to add an `Authorization: $TOKEN` — and that header went out to the origin as
  # the six literal bytes `$TOKEN`, while the editor's own value peek sat under the caret
  # showing the resolved secret. Display promising a substitution the wire does not make is
  # the worst way round for a tool whose job is telling the operator what it sent.
  #
  # Per NAME, not per keystroke or per tab. A capture's `$filter`/`$top`/`$where`/`$IFS`
  # stays literal for the life of the tab even if the project happens to define `filter` —
  # that is the whole point of `Repeater::PlanOptions#evidence?` and it is untouched here.
  # A name the capture never mentioned cannot be an origin byte, so it is the operator's.
  #
  # Deliberately conservative where the two collide: type `$filter` into a tab whose capture
  # already had one and it stays literal, because gori cannot tell the two occurrences apart
  # and evidence wins when it cannot. `$$` escapes to a literal `$` on every path already,
  # so the operator has a spelling for either intent.
  private def operator_env_vars : Hash(String, String)
    Env.vars_without(@evidence_env_names)
  end

  # §…§ marker send: parse the CRLF wire form as a Fuzz template and render each marked
  # position's default through its inline Decoder chain (Template#apply_chains), then
  # resync Content-Length as usual. Parsing the CRLF form (not @editor.text, which is LF)
  # keeps render's output in wire form so the existing CRLF-based sync_content_length works
  # unchanged. A chain-less `§v§` renders `v`.
  #
  # `refuse: true` — this is the ONE path that puts these bytes on the wire, so a `¦chain`
  # that cannot run is REFUSED here (see `refuse_bad_chains`) rather than let
  # `Template#apply_chains` drop the raw, untransformed value onto the socket.
  private def marked_request_bytes : Bytes
    finalize_wire(render_marked(expanded_editor_bytes, refuse: true))
  end

  # Render the §…§ template in `raw` (each marked default through its inline Decoder
  # chain), returning wire-form bytes with the markers stripped. Shared by the marker
  # send AND the CL reflection so both derive Content-Length from the SAME rendered body —
  # otherwise the visible header showed a CL for the raw marked text while ^R sent one for
  # the rendered body.
  #
  # `refuse` is OFF for the render/CL-reflection caller and ON only for the send: this runs
  # on every frame while the operator types, so a broken chain must NOT raise here (it would
  # crash the tab the operator is using to FIX the chain). The send path alone refuses.
  private def render_marked(raw : Bytes, refuse : Bool = false) : Bytes
    tmpl = Fuzz::Template.parse(String.new(raw))
    registry = Decoder.shared_registry
    refuse_bad_chains(tmpl, registry) if refuse
    tmpl.render(tmpl.apply_chains(tmpl.default_payloads, registry))
  end

  # Refuse a send whose `§value¦chain§` markers name a converter that cannot run over the
  # value about to go on the wire. The twin of `Fuzz::Plan#refuse_unusable_chains`, and it
  # exists for the same reason: `Template#apply_chains` returns the value UNTRANSFORMED when
  # its chain does not run (`Decoder.run` never raises), so a §…§ marker whose chain is
  # unknown, names an unusable saved chain, or simply fails on its value would put the RAW
  # value on the wire under a clean-looking send — a corrupted request, not a refusal.
  #
  # Where the Fuzzer runs many payloads per marked position and so refuses only the two
  # TEMPLATE-level failures (unknown converter / unusable saved chain), leaving a genuinely
  # per-payload failure to the next payload, the Repeater sends exactly ONE value — the
  # marked default — so a chain that fails on THAT value IS the value that would go out
  # untransformed. The unknown/unusable wording is byte-identical to `Fuzz::Plan` so the two
  # engines report the same failure the same way (see `Fuzz::ChainError`); the per-value
  # failure is the extra case a single-send surface must also name.
  private def refuse_bad_chains(tmpl : Fuzz::Template, registry : Decoder::Registry) : Nil
    bad = [] of String
    tmpl.positions.each do |pos|
      next if pos.chain.empty?
      # The template-level failures, worded exactly as Fuzz::Plan#refuse_unusable_chains.
      resolvable = true
      Decoder.parse_spec(pos.chain).each do |tok|
        conv = registry[tok]?
        if conv.nil?
          bad << "#{tok}: unknown converter"
          resolvable = false
        elsif reason = conv.unusable
          bad << reason # already prefixed with the chain's own name
          resolvable = false
        end
      end
      # Then the per-value failure: base64-decode over a value that isn't base64, etc. A
      # Fuzz sweep leaves this to the next payload; a repeater send has no next payload, so
      # the marked default going out raw is the corruption to refuse.
      next unless resolvable
      res = Decoder.run(registry, pos.default.to_slice, pos.chain)
      unless res.ok?
        step = res.steps[res.failed_at || 0]
        bad << "#{step.name}: #{step.error || "chain failed"}"
      end
    end
    return if bad.empty?
    raise Fuzz::ChainError.new("§…§ chain cannot run: #{bad.uniq.join("; ")}. " \
                               "The payload would go out untransformed — fix or remove the chain " \
                               "(list the converters with `gori run decoder list`)")
  end

  # A repeater round-trip is outstanding (set/cleared by the Runner around the
  # background send fiber) — used to refuse a second concurrent send.
  def inflight? : Bool
    @inflight
  end

  def inflight=(value : Bool) : Nil
    @inflight = value
  end

  getter? auto_content_length : Bool

  def toggle_auto_content_length : Bool
    return @auto_content_length if @req_hex_edit # meaningless on raw bytes — refuse in hex mode
    @dirty = true
    @auto_content_length = !@auto_content_length
    reflect_content_length_in_editor if @auto_content_length
    @auto_content_length
  end

  # Flip the transport between HTTP/1.1 and HTTP/2 (`^V`). Drives which engine
  # `repeater_send` dials (Engine vs H2Engine) and lets the user OVERRIDE the captured
  # protocol — e.g. resend an h1 request as h2, or force an h2 flow down to h1 for a
  # downgrade/smuggling probe. Refused in the intrinsic-protocol modes: WebSocket is
  # HTTP/1.1 by definition and gRPC rides h2, so their flag is fixed. Rewrites the
  # request-line version token to match so the editor display agrees with the wire (and
  # the verbatim h1 send doesn't ship a stray "HTTP/2"). Dirties so the choice persists.
  def toggle_http2 : Bool
    return @http2 if ws_mode? || @grpc_mode
    @http2 = !@http2
    retarget_request_version unless @req_hex_edit # hex is byte-exact — leave its bytes alone
    @dirty = true
    @http2
  end

  # Rewrite the request line's HTTP-version token to match @http2 (see FlowRequest.
  # retarget_version_line). A no-op when the first line isn't a recognizable request line
  # or is already correct. replace_line keeps the cursor/undo intact (vs set_text).
  private def retarget_request_version : Nil
    first = @editor.text.split('\n', 2).first? || return
    updated = Repeater::FlowRequest.retarget_version_line(first, @http2) || return
    @editor.replace_line(0, updated)
    reflect_content_length_in_editor if @auto_content_length
  end

  # Bring a request line down to HTTP/1.1 before an h1 send when it declares a version h1
  # cannot carry — a request line pasted from another tool's HTTP/2 view. Returns true
  # when it changed anything.
  #
  # Runs at SEND PREP (like `sync_host_to_target_once`) rather than on edit: there is no
  # paste event to hook, and rewriting mid-typing would fight the cursor. Rewriting the
  # VISIBLE line rather than only the wire bytes is the point — the editor is what the
  # user reads, so display and wire must agree, exactly as ^V and auto-CL already keep
  # them. Refused in the byte-exact/own-framing modes; `downgrade_version_line` is itself
  # narrow enough to leave a deliberate version alone.
  #
  # `group` says whether a lone `%%%` line starts a new request. It does for a send-group
  # (each chunk carries its own request line, and every one of them rides the same h1
  # connection); for a single ^R the whole buffer is ONE request, so a `%%%` there is body
  # text and the lines under it must not be touched.
  def downgrade_h2_request_lines(*, group : Bool) : Bool
    return false if @http2 || @req_hex_edit || @grpc_mode || ws_mode?
    changed = false
    at_request_line = true # line 0 starts a request; with `group`, so does the line after a `%%%`
    @editor.lines_snapshot.each_with_index do |line, i|
      stripped = line.strip
      if group && stripped == PIPELINE_SEP
        at_request_line = true
        next
      end
      next unless at_request_line
      next if stripped.empty? # blank padding around a separator — the request line is below it
      at_request_line = false
      next unless updated = Repeater::FlowRequest.downgrade_version_line(line)
      @editor.replace_line(i, updated)
      changed = true
    end
    return false unless changed
    @dirty = true
    reflect_content_length_in_editor if @auto_content_length
    true
  end

  def pretty_print_request : String?
    return "hex mode active" if request_hex?
    if ws_mode? && @req_pane == :decoded
      return "websocket messages editor doesn't support pretty-printing"
    end

    text = @editor.text
    env_sep = text.index("\n\n")
    return "no request body" unless env_sep

    head = text[0, env_sep]
    body = text[env_sep + 2..]
    return "request body is empty" if body.strip.empty?

    if formatted_body = Pretty.format_request(head, body)
      new_text = "#{head}\n\n#{formatted_body}"
      @editor.set_text(new_text)
      @dirty = true
      reflect_content_length_in_editor if @auto_content_length
      nil # success
    else
      "failed to pretty-print (unsupported or malformed body)"
    end
  end

  def apply(result : Repeater::Result) : Nil
    # The prior send becomes the diff baseline (diff vs the *previous* request,
    # not always the original captured flow). For the first send we still fall
    # back to the captured original (when loaded from History).
    @prev_result = @result
    @result = result
    @group_results = nil # a single ^R send takes the pane back from a group transcript
    reset_result_caches  # new response → drop the styled/lines/diff caches
    # Stay on whichever response tab the user last had open — a send no longer
    # force-jumps to the diff. Fall back to :response only when a diff can't be
    # shown: an errored send (its error lives in the response view) or no
    # baseline to compare against yet. Focus (target/request/response) is also
    # left untouched, keeping the user where they were.
    @resp_mode = :response unless @resp_mode == :diff && result.ok? && diff_baseline_lines
    @scroll = 0
    resp_wrap_reset
  end
end
