# gRPC repeater mode (an `application/grpc` h2 flow): the editor holds the editable request
# HEAD and the framed message body is sent byte-exact — or, for the unary case the hex editor
# can reach, with its length prefix recomputed while `␣F:FRAME` is on — plus the deframed
# response transcript and status row.
# Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  getter? grpc_mode : Bool
  getter? grpc_reframable : Bool # a unary gRPC call whose payload is hex-editable
  getter grpc_msg_count : Int32  # deframed request-message count (gates/explains hex availability)

  # Whether a reframable call's 5-byte length prefix is RECOMPUTED over the payload on send.
  # Split off `grpc_reframable?` in PR 13: "unary, so hex-editable" is a fact about the
  # capture, "reframe on send" is a decision, and fusing them meant the TUI could not send
  # what `gori run repeater send` sends by default. ON here, OFF headless — see the ivar's
  # comment in repeater_view.cr and DESIGN.md §7.
  getter? grpc_reframe : Bool

  # `␣F:FRAME` / `repeater.toggle-grpc-reframe`. Refused unless this is a gRPC tab holding a
  # REFRAMABLE body: there is otherwise no unary prefix to recompute, and a flag that cannot
  # change what goes on the wire is worse than a toast saying so.
  #
  # The transcript cache is deliberately NOT dropped: those rows describe the send that
  # produced the result on screen, and `apply` already rebuilds them per send. Dropping them
  # here would re-report a PAST send's byte count under the toggle's new state — the same
  # reason `^X` does not drop them either.
  def toggle_grpc_reframe : Bool
    return @grpc_reframe unless @grpc_mode && @grpc_reframable
    @grpc_reframe = !@grpc_reframe
  end

  # Load a captured gRPC flow (an application/grpc HTTP/2 call) for repeater. The request
  # HEAD is seeded into the editor (editable — metadata headers). The message body is wire
  # protobuf, not text, so it isn't text-editable — but a UNARY call (exactly one framed
  # message) exposes its payload for HEX editing (^X), with the 5-byte length prefix
  # recomputed on send while `␣F:FRAME` is on (see grpc_request_bytes; the toggle defaults on
  # here and off headless). A 0- or multi-message body is kept byte-exact in @grpc_body and
  # re-appended verbatim. The response renders as a deframed gRPC transcript + grpc-status,
  # each payload decoded schema-lessly (`p` swaps the tree for a hex preview) — the wire
  # format names every field's number and type without a `.proto`.
  def load_grpc(detail : Store::FlowDetail) : Nil
    @flow = detail
    @evidence = true
    @markers_declared = false
    @grpc_mode = true
    @ws_http_only = false # in lockstep with @ws_mode below — a gRPC tab holds no handshake
    @ws_mode = false
    # The flow's OWN transport, not a constant. gRPC-Web is gRPC framing over HTTP/1.1, and
    # forcing h2 here re-sent a captured h1 call over a protocol its origin may not speak —
    # while the tab was only reachable for h2 flows, `true` was merely redundant; now that
    # grpc-web opens too, it would be a lie about the request.
    @http2 = detail.http_version == "HTTP/2"
    @grpc_body = detail.request_body || Bytes.empty
    @grpc_web_text = Proxy::H2::Grpc.web_text?(Gori::MediaType.of(detail.request_head))
    # `scan`, not `messages`: the residual is the REQUEST side of the same report. A capture
    # whose length prefix over-claims used to count as "0 messages" and be described in the
    # transcript as `→ sent 0 request messages (10b)` — the byte count and the message count
    # disagreeing, with nothing saying why.
    #
    # Deframed off `framed`, which is `@grpc_body` itself except for grpc-web-text, where
    # the frames are base64 on the wire. `@grpc_body` stays the CAPTURED bytes — it is what
    # a non-reframable tab re-sends verbatim (P7).
    framed = grpc_framed_body
    msgs, @grpc_req_residual = Proxy::H2::Grpc.scan(framed)
    @grpc_msg_count = msgs.size
    # Per LOAD, like `@ws_keep_key`: a freshly seeded tab starts at this tab's own default
    # (on), whatever the previous flow in this view left it at.
    @grpc_reframe = true
    # Reframable only when the body is EXACTLY one clean message: then a hex edit of the
    # payload can be re-length-prefixed unambiguously. (A partial trailing frame would
    # leave msgs shorter than the wire, so require the framing to be lossless too.)
    if msgs.size == 1 && Proxy::H2::Grpc.frame(msgs[0].compressed, msgs[0].data) == framed
      @grpc_reframable = true
      @grpc_compressed = msgs[0].compressed
      @grpc_payload = msgs[0].data
    else
      @grpc_reframable = false
      @grpc_compressed = false
      @grpc_payload = Bytes.empty
    end
    @grpc_lines_cache = nil
    @target = build_target(detail.row.scheme, detail.row.host, detail.row.port)
    @tcx = @target.size
    @sni = ""
    @scx = 0
    @target_field = :url
    @editor.set_text(origin_head_text(detail))
    seed_draft_baselines
    @original_lines = [] of String
    @result = nil
    @prev_result = nil
    reset_result_caches
    @focus = :request
    @resp_mode = :response
    @scroll = 0
    resp_wrap_reset
    @diffable = false
    @loaded = true
    @dirty = false
    @req_hex_edit = nil
    @scroll_req = 0
  end

  # The replayable request bytes for a gRPC tab: the edited head + the canonical
  # CRLFCRLF terminator (what H2Engine.split_head_body keys on) + the message body.
  # A reframable (unary) call sends the current payload — hex-edited via @req_hex_edit while
  # in hex mode, else the stored @grpc_payload — behind either a RECOMPUTED length prefix
  # (`␣F:FRAME` on, the default) or the CAPTURED one (off, which is how a deliberately-stale
  # prefix is sent); a non-reframable body is the pristine @grpc_body, verbatim.
  # Auto-Content-Length never applies over h2 (it frames by DATA/END_STREAM).
  private def grpc_request_bytes : Bytes
    raw = expanded_editor_bytes
    n = raw.size
    while n > 0 && (raw[n - 1] == 0x0A_u8 || raw[n - 1] == 0x0D_u8) # trim trailing CR/LF
      n -= 1
    end
    body = grpc_send_body
    head = String.new(raw[0, n])
    # Over HTTP/1.1 (gRPC-Web) the body is delimited by Content-Length, not by a DATA frame
    # with END_STREAM — so a reframed payload that changed size leaves a header the origin
    # will read as the message boundary, and the call hangs or is cut. h2 keeps the header
    # untouched, exactly as before. Honours the Auto-Content-Length toggle: a deliberate
    # desync is a test, and turning the toggle off is how the operator asks for one.
    head = sync_cl_head(head, body.size) if !@http2 && @auto_content_length
    io = IO::Memory.new(head.bytesize + body.size + 4)
    io << head << "\r\n\r\n"
    io.write(body)
    io.to_slice
  end

  # Rewrite an existing Content-Length in a CRLF- or LF-terminated head to `size`. Absent
  # header → unchanged (adding one is a decision about framing the operator did not make).
  # The sibling of `sync_cl_text`, which takes a whole LF-joined envelope and measures the
  # body it already contains; a gRPC tab holds only the HEAD, and its body is built after.
  private def sync_cl_head(head : String, size : Int32) : String
    eol = head.includes?("\r\n") ? "\r\n" : "\n"
    lines = head.split(eol)
    idx = lines.index(&.lstrip.downcase.starts_with?("content-length:")) || return head
    lines[idx] = "Content-Length: #{size}"
    lines.join(eol)
  end

  # The captured request body with grpc-web-text's base64 removed — the bytes `scan`
  # deframes. Identity for native gRPC and binary grpc-web.
  private def grpc_framed_body : Bytes
    return @grpc_body unless @grpc_web_text
    Proxy::H2::Grpc.decode_web_text(@grpc_body) || @grpc_body # P7: undecodable → show as captured
  end

  # The message body to send, IN WIRE FORM: a reframable call frames the live payload (hex
  # buffer if editing, else the stored payload) and re-applies grpc-web-text's base64;
  # everything else is the captured body verbatim.
  #
  # `@grpc_reframe` picks WHICH prefix goes in front of that payload — recomputed, or the
  # captured five bytes kept as-is. Both are one message; the difference is whether the
  # declaration follows the edit (an ordinary call the origin should accept) or stays where
  # the capture left it (the P7 default headless, where the mismatch IS the test).
  private def grpc_send_body : Bytes
    return @grpc_body unless @grpc_reframable
    payload = (h = @req_hex_edit) ? h.to_bytes : @grpc_payload
    framed = @grpc_reframe ? Proxy::H2::Grpc.frame(@grpc_compressed, payload) : grpc_stale_frame(payload)
    @grpc_web_text ? Base64.strict_encode(framed).to_slice : framed
  end

  # The CAPTURED 5-byte prefix in front of the live payload — the reframe toggle's OFF half.
  # Flag byte and all four length octets are copied from the capture, so with no hex edit the
  # result is the captured body byte-for-byte, and after one it is the same stale declaration
  # `gori run repeater send` (no `--reframe-grpc`) would put on the wire.
  #
  # A reframable tab always has ≥ 5 framed bytes (load_grpc proved the body re-frames to
  # itself); the guard is there so a future caller cannot make this read past the slice.
  private def grpc_stale_frame(payload : Bytes) : Bytes
    captured = grpc_framed_body
    return Proxy::H2::Grpc.frame(@grpc_compressed, payload) if captured.size < 5
    stale = Bytes.new(5 + payload.size)
    captured[0, 5].copy_to(stale)
    payload.copy_to(stale[5, payload.size])
    stale
  end

  # The gRPC transcript as {text, colour} rows (cached): the request message count,
  # the HTTP status, the deframed response messages (hex preview), and grpc-status.
  private def grpc_transcript_lines : Array({String, Color})
    drop_transcript_cache_on_theme_change
    @grpc_lines_cache ||= begin
      rows = [] of {String, Color}
      result = @result
      if result && !result.ok?
        rows << {"✗ #{result.error}", Theme.red}
      elsif result
        reqn = @grpc_msg_count # already deframed once in load_grpc
        # Report the bytes actually put on the wire — a reframed (edited) unary payload
        # differs from the captured @grpc_body.
        rows << {"→ sent #{reqn} request message#{reqn == 1 ? "" : "s"} (#{grpc_send_body.size}b)", Theme.muted}
        rows << {"⚠ #{Proxy::H2::Grpc.framing_error(@grpc_req_residual)}", Theme.yellow} if @grpc_req_residual > 0
        st = result.response.try(&.status) || 0
        # `status_color`, not a local `>= 400 ? red`. This line painted a 404 RED while
        # line ~4812 of this same file painted it yellow, and every other status cell in
        # gori (flow_status, the Fuzzer results, Discover) reads the shared ladder. Red is
        # 5xx; a 4xx that shows as red says "the server broke" about a 404.
        rows << {"HTTP #{st}", Theme.status_color(st)}
        grpc_response_rows(result).each { |r| rows << r }
        rows << grpc_status_row(result)
      end
      rows
    end
  end

  # `scan`, not `messages`: `messages` throws away the residual — the tail bytes that are
  # not a complete frame — so a deliberately-wrong length prefix (a standard gRPC parser
  # test) rendered as a bare "(no complete gRPC messages)" with no byte count, which reads
  # identically to "this response is not gRPC at all". `gori run show --format json`
  # already reports it; this is the pane that shows the same response.
  private def grpc_response_rows(result : Repeater::Result) : Array({String, Color})
    rows = [] of {String, Color}
    # Keyed on the RESPONSE's own content-type: a grpc-web-text reply is base64 on the wire
    # (and a server may answer `-text` to a binary request), so the framing lives one decode
    # below the bytes.
    msgs, residual = Proxy::H2::Grpc.scan_body(Gori::MediaType.of(result.head),
      result.body || Bytes.empty)
    if msgs.empty? && residual == 0
      rows << {"← (no complete gRPC messages)", Theme.muted}
    else
      # One legend above the messages, and only when a tree will actually be drawn — see
      # ProtobufTree::NOTE. Same rule as the History framing pane, from the same predicate.
      rows << {ProtobufTree::NOTE, Theme.muted} if ProtobufTree.legend?(msgs, @pretty)
      msgs.each_with_index do |m, i|
        if m.trailer
          rows << {"← trailer  #{m.data.size}b", Theme.green}
          Proxy::H2::Grpc.trailer_headers(m.data).each do |k, v|
            if k == "grpc-status"
              n = v.to_i?
              ok = n == 0
              name = n ? Proxy::H2::Grpc.status_name(n) : v
              rows << {"    #{k}: #{v} #{name}", ok ? Theme.green : Theme.red}
            else
              rows << {"    #{k}: #{v}", Theme.muted}
            end
          end
        else
          rows << {"← message ##{i + 1}  #{m.data.size}b#{m.compressed ? " (compressed)" : ""}", Theme.green}
          grpc_payload_rows(m).each { |r| rows << r }
        end
      end
    end
    rows << {"⚠ #{Proxy::H2::Grpc.framing_error(residual)}", Theme.yellow} if residual > 0
    rows
  end

  # grpc-status/grpc-message arrive as response trailers (absorbed into the synth
  # head by H2Engine), so they're plain response headers here.
  private def grpc_status_row(result : Repeater::Result) : {String, Color}
    resp = result.response
    code = resp.try(&.headers.get?("grpc-status"))
    return {"⚠ no grpc-status trailer", Theme.yellow} unless code
    n = code.to_i?
    ok = n == 0
    name = n ? Proxy::H2::Grpc.status_name(n) : code
    msg = resp.try(&.headers.get?("grpc-message"))
    {"#{ok ? "✓" : "✗"} grpc-status: #{code} #{name}#{msg ? " · #{msg}" : ""}", ok ? Theme.green : Theme.red}
  end

  # One response message's payload, under its `← message #N` header. PRETTY (`p`, the same
  # global toggle that reflows a JSON response body) picks the reading: the schema-less
  # protobuf tree, or the hex preview that is the honest view when the decoder can make no
  # sense of the bytes. `ProtobufTree` is shared with the History framing pane so the two
  # cannot drift — #496 deferred this precisely so it would be answered once.
  #
  # `ProtobufTree.decode?` owns the compressed/trailer carve-outs the CLI and MCP make, so
  # this pane and the History framing pane cannot disagree about which payloads are protobuf.
  private def grpc_payload_rows(m : Proxy::H2::Grpc::Message) : Array({String, Color})
    unless ProtobufTree.decode?(m, @pretty)
      return grpc_hex_preview(m.data).map { |h| {h, Theme.muted} }
    end
    ProtobufTree.lines(Protobuf.decode(m.data), indent: "    ").map { |l| {l, Theme.text} }
  end

  private def grpc_hex_preview(data : Bytes, max : Int32 = 32) : Array(String)
    slice = data[0, {data.size, max}.min]
    lines = [] of String
    slice.each_slice(16) do |chunk|
      hex = chunk.map(&.to_s(16).rjust(2, '0')).join(' ')
      ascii = chunk.map { |b| 0x20 <= b <= 0x7e ? b.unsafe_chr : '.' }.join
      lines << "    #{hex.ljust(48)} #{ascii}"
    end
    lines << "    … (#{data.size - max} more)" if data.size > max
    lines
  end
end
