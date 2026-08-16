# WebSocket repeater CONTENT: a captured handshake plus an editable outbound-message list,
# the `^V` transport override that sends the handshake as ordinary HTTP instead, the seed /
# raw / persisted views of the message list, the MCP snapshot, and the frame transcript a
# send produces. Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # Does this tab HOLD WebSocket content — a handshake and a list of outbound frames?
  #
  # This is the persistence question, and it is deliberately not the same one `ws_mode?`
  # answers. Everything that would LOSE the frames by forgetting they exist asks here:
  # `save_current_repeater`, the duplicate path's `update_repeater_ws_messages`, `dirty?`
  # (the MESSAGES pane's own edits), and the MCP snapshot. Asking `ws_mode?` there meant
  # flipping a tab to HTTP and closing the project silently dropped its captured frames.
  def ws_content? : Bool
    @ws_mode
  end

  # Does `^R` dial `WsEngine`, and does the tab RENDER as a WebSocket (split request column,
  # transcript response, the WS badges, and the feature gates that ride with them)?
  #
  # WebSocket content the operator has not overridden. See `@ws_http_only`.
  def ws_mode? : Bool
    @ws_mode && !@ws_http_only
  end

  # The operator overrode auto-detection: a WS tab being sent as plain HTTP. False on a tab
  # that holds no WebSocket content at all — there is nothing to override there, and the
  # chip/`^V` cycle must not claim otherwise.
  def ws_http_only? : Bool
    @ws_mode && @ws_http_only
  end

  # Can `^V` change what `^R` dials on this tab? False only for gRPC, whose transport is
  # fixed by specification (see `repeater_toggle_http2`'s refusal). Gates the `^V` badge:
  # a chip is drawn exactly where the key does something, so a tab that shows none is a tab
  # whose transport is not the operator's to pick.
  def transport_switchable? : Bool
    !@grpc_mode
  end

  # The transport `^R` will dial, as the `^V` badge names it. Only meaningful when
  # `transport_switchable?` — a gRPC tab is always h2 and draws no badge to say so.
  #
  # An overridden handshake tab names BOTH ends ("WS→h1"): its request card is titled
  # REQUEST, because that is what `^R` sends, so this chip is the only text on screen saying
  # the tab holds a WebSocket handshake at all. Naming just the destination would put the tab
  # back where it started — indistinguishable from an ordinary request with a hidden MESSAGES
  # pane, which is the defect the card title used to carry alone.
  def transport_label : String
    return "WS" if ws_mode?
    http = @http2 ? "h2" : "h1"
    ws_http_only? ? "WS→#{http}" : http
  end

  # Should the `^V` badge wear the loud dress? Only when the operator overrode auto-detection
  # — a tab holding a WebSocket handshake that `^R` will send as a plain request. h1 vs h2 on
  # an ordinary tab is not an override (the tab has no other shape to be): it keeps the
  # resting fill and lets the LABEL carry the state.
  def transport_badge_lit? : Bool
    ws_http_only?
  end

  # Cycle the transport `^R` dials: WS → HTTP/1.1 → HTTP/2 → WS. Returns the new state as a
  # label for the status line. Only a tab holding a handshake has three states; anything
  # else keeps the plain two-state h1/h2 toggle (`toggle_http2`).
  #
  # The pane geometry is mode-dependent (a WS tab splits its request column and parks a
  # second caret), so both sub-pane selections are reset to the ones the destination mode
  # draws — otherwise the request column came back on `:decoded` with no decoded card under
  # it, and the response cursor sat on a `:handshake` card the HTTP branch never renders.
  def cycle_ws_transport : String
    return @http2 ? "transport: HTTP/2 (h2)" : "transport: HTTP/1.1" unless @ws_mode
    @dirty = true
    if !@ws_http_only # WS → HTTP/1.1
      @ws_http_only = true
      @http2 = false
    elsif !@http2 # HTTP/1.1 → HTTP/2
      @http2 = true
    else # HTTP/2 → WS (h2 is not a WebSocket transport here — RFC 8441 is out of scope)
      @ws_http_only = false
      @http2 = false
    end
    @req_pane = ws_mode? ? :decoded : :envelope
    @resp_pane = :transcript
    @resp_alt = {0, 0, 0, 0}
    resp_wrap_reset
    reset_result_caches
    if ws_mode?
      "transport: WebSocket — ^R dials WsEngine and pumps the MESSAGES pane"
    else
      "transport: #{@http2 ? "HTTP/2 (h2)" : "HTTP/1.1"} — the handshake is sent as a plain request (frames kept)"
    end
  end

  # Load a captured WebSocket flow (101) for repeater. The request editor is seeded
  # with the handshake upgrade request; the messages editor is seeded with the recorded
  # client→server TEXT messages (one per line, editable). A BINARY message is not
  # representable as editable text so it stays out of the pane — but it stays IN the
  # seed, so an unedited replay still sends it (see `@ws_out_seed`).
  def load_ws(detail : Store::FlowDetail, out_messages : Array(Store::WsOutMessage)) : Nil
    @flow = detail
    @evidence = true # the handshake AND the seeded frames are the capture's
    @markers_declared = false
    @ws_mode = true
    @ws_http_only = false # a fresh capture starts on auto-detect; ^V is the operator's to press
    @ws_keep_key = false  # a fresh capture: the regenerated key is the default (see the ivar)
    @http2 = false        # WebSocket is HTTP/1.1
    @ws_upgrade = detail.request_head
    @ws_result = nil
    @ws_lines_cache = nil
    @target = build_target(detail.row.scheme, detail.row.host, detail.row.port)
    @tcx = @target.size
    @sni = ""
    @scx = 0
    @target_field = :url
    @editor.set_text(String.new(detail.request_head))
    seed_draft_baselines
    seed_ws_out(out_messages)
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
    @req_pane = :decoded
  end

  # The outbound messages to SEND: exactly the list a save would persist
  # (`ws_out_messages_raw`), with `$KEY` env tokens expanded (parity with the handshake and
  # every other outbound path).
  #
  # Derived from `ws_out_messages_raw` rather than re-deriving the list itself, so the wire
  # and the database can never disagree about which frames this tab holds. They did: this
  # method used to fall back to its own LF-split of the pane the moment the pane was edited,
  # while the badge on the pane's border kept naming the frames that fallback had dropped.
  #
  # A tab seeded from a CAPTURED 101 flow is EVIDENCE and is not expanded at all — the
  # same rule `gori run repeater send` and MCP `send_websocket` now apply to a flow-seeded
  # session's stored rows. A captured `{"$where":"this.a==1"}` is a MongoDB injection test,
  # not a reference to a project variable; with the draft policy on it was unsendable (the
  # send named `$where`) and setting the variable to get past that sent
  # `{"WHEREVAL":"this.a==1"}`. Neither half can happen now — an unresolved name is never
  # refused, and evidence is never expanded.
  def ws_out_messages : Array(Repeater::WsEngine::OutMsg)
    ws_out_messages_raw.map do |m|
      # `Env.expand` scans BYTES and copies every unmatched span through untouched, so a
      # TEXT frame carrying invalid UTF-8 survives it; a BINARY frame is not expanded at
      # all, the same rule `gori run repeater send` and MCP `send_websocket` apply.
      expand = m.text? && !@evidence
      Repeater::WsEngine::OutMsg.new(m.opcode,
        expand ? Env.expand(String.new(m.payload)).to_slice : m.payload, m.shape, @evidence)
    end
  end

  # Send the operator's own `Sec-WebSocket-Key` rather than a fresh one. Persisted per
  # session (`repeaters.ws_keep_key`) because it is a property of the handshake being
  # tested, not of one keystroke — and off by default, so every existing tab keeps the
  # regenerated key it has always sent.
  getter? ws_keep_key : Bool

  def toggle_ws_keep_key : Bool
    # `ws_mode?`, not `ws_content?`: in HTTP-only mode the head goes out verbatim through
    # `Engine`, so the key line in the editor IS the key on the wire and there is nothing
    # for this flag to switch. It keeps its stored value for the trip back to WebSocket.
    return @ws_keep_key unless ws_mode?
    @dirty = true
    @ws_keep_key = !@ws_keep_key
  end

  # Is the pane still showing exactly what the session was loaded with? An empty seed
  # means there is nothing to preserve, so a hand-typed list takes the text path.
  private def ws_out_seeded? : Bool
    !@ws_out_edited && !@ws_out_seed.empty?
  end

  # Can this message be shown as ONE LINE OF TEXT in the pane, with nothing lost?
  #
  # Only a plain TEXT frame in the default shape. A binary payload rendered into a TextArea
  # is noise the operator cannot meaningfully edit — that part is old. The rest is new: a
  # PING, a PONG and a CLOSE are not text lines at all, and a TEXT frame carrying RSV1, a
  # cleared FIN, a pinned mask key or a declared length that disagrees with its payload
  # would render as an ORDINARY line, so writing the pane back would silently discard
  # exactly the shape the operator captured it for. Showing it and then losing it is worse
  # than not showing it: the seed replays it verbatim.
  #
  # The last two clauses apply that same rule to a payload whose BYTES defeat the one
  # message = one line projection, which the shape fields do not describe:
  #
  #   * an embedded LF makes one frame render as two lines, and writing the pane back split
  #     a captured `line1\nline2` into two frames on the wire — a real observed defect, not
  #     a hypothetical (the origin logged `op=1 len=5` twice where the capture had one
  #     `op=1 len=11`).
  #   * invalid UTF-8 is a binary payload the pane happens to be displaying (RFC 6455 §5.6
  #     makes UTF-8 the definition of a text frame), and a TextArea round-trip would scrub
  #     it — the same reason `Store::WsOutMessage` exists at all.
  #
  # Both are frames the operator captured *for* those bytes, so they stay in the list and
  # out of the pane, and the "+N not shown" badge names them.
  def self.ws_line_renderable?(m : Store::WsOutMessage) : Bool
    return false unless m.text? && m.shape.default?
    return false if m.payload.includes?(0x0A_u8)
    String.new(m.payload).valid_encoding?
  end

  # The badge/notice label for a frame the pane is not showing. `shape_label` names the
  # frame SHAPE, which is the whole answer for a PING or an RSV1 frame and no answer at all
  # for the two byte-level cases above — both are plain `TEXT` by shape, so the badge would
  # have read "+2 not shown: TEXT, TEXT".
  def self.ws_unshown_label(m : Store::WsOutMessage) : String
    base = m.shape_label
    return base unless m.text? && m.shape.default?
    return "#{base} multiline" if m.payload.includes?(0x0A_u8)
    "#{base} binary"
  end

  # Short labels for the frames the pane is NOT showing, for the badge on the MESSAGES
  # border and the open-from-History status line. Empty when the pane shows everything,
  # which is the ordinary case.
  #
  # Computed from the list actually going out / being written (`ws_out_messages_raw`), NOT
  # from `@ws_out_seed`. It read the seed, which an edit never updates, so after the pane
  # was edited the border went on advertising a PING and a BIN that the write-back had
  # already deleted — the operator was told a binary frame was riding along when it was not.
  def ws_unshown_seed : Array(String)
    ws_out_messages_raw.reject { |m| RepeaterView.ws_line_renderable?(m) }
      .map { |m| RepeaterView.ws_unshown_label(m) }
  end

  # Install a session's outbound messages as both the seed and the pane's text. The pane
  # shows the TEXT frames only — a binary payload rendered into a TextArea is noise the
  # operator cannot meaningfully edit, and writing it back was how it became opcode 1.
  #
  # A soft reconcile (`apply_peer_request`) reaches this on every peer request-side change,
  # so an UNSAVED local edit is left alone — the same guard the pane's `set_text` already
  # had. Adopting the peer's seed under it would send their messages while showing ours.
  private def seed_ws_out(messages : Array(Store::WsOutMessage)) : Nil
    joined = messages.select { |m| RepeaterView.ws_line_renderable?(m) }.join('\n') { |m| String.new(m.payload) }
    same = @decoded.text == TextArea.normalize_lf(joined)
    return if @ws_out_edited && !same
    @decoded.set_text(joined) unless same
    @ws_out_seed = messages
    @ws_out_edited = false
  end

  # The outbound messages to persist (env tokens UNexpanded). The store masks secrets and
  # stores these verbatim, so `$KEY` survives to re-expand on the next send — never bake
  # an expanded secret into the DB (see ws_out_messages).
  #
  # An untouched pane hands back the seed, opcodes and bytes intact; that is what lets a
  # captured BINARY frame survive a save it had nothing to do with.
  #
  # An EDITED pane is a position-keyed SPLICE over that seed, not a replacement of it. It
  # used to be a replacement — `@decoded.text.split('\n').reject(&.empty?)`, every line a
  # fresh default-shape TEXT frame — so one keystroke anywhere in the pane deleted every
  # frame the pane had never rendered. On a persisted session that is irreversible:
  # `Store#update_repeater_ws_messages` opens with `DELETE FROM ws_messages`, and a PING, a
  # binary payload, an empty frame, an RSV1 frame and an unmasked frame were gone from the
  # database with no confirmation and no undo. The pane is a text VIEW of a list it cannot
  # fully represent; an edit to the view may only touch what the view showed.
  #
  # `reject(&.empty?)` is off the mapped range for the same reason: a captured TEXT frame
  # with an empty payload IS renderable (it is a blank line), so dropping blank lines ate
  # it. Only a SURPLUS blank line — one past the end of the seed's renderable slots, which
  # is what pressing Enter at the end of the pane produces — is still discarded.
  def ws_out_messages_raw : Array(Store::WsOutMessage)
    return @ws_out_seed if ws_out_seeded?
    lines = @decoded.text.split('\n')
    out = @ws_out_seed.map { |m| m.as(Store::WsOutMessage?) }
    # The seed positions this pane is showing, in pane order. `ws_line_renderable?` decides
    # both this and what `seed_ws_out` joined into the pane, so line k IS slot slots[k].
    slots = [] of Int32
    @ws_out_seed.each_with_index { |m, i| slots << i if RepeaterView.ws_line_renderable?(m) }
    slots.each_with_index do |idx, k|
      # A line the operator deleted takes its slot with it; nil marks it for removal so the
      # indices of the untouched slots stay valid while the rest are being written.
      out[idx] = (line = lines[k]?) ? Store::WsOutMessage.text(line) : nil
    end
    messages = out.compact
    # Lines with no slot are new: append them in order. Blank ones are the trailing newline
    # an editor leaves behind, not a frame the operator asked for.
    lines[slots.size..]?.try &.each { |l| messages << Store::WsOutMessage.text(l) unless l.empty? }
    messages
  end

  # Persistence just wrote `ws_out_messages_raw` — those bytes ARE the session now, so the
  # pane counts as unedited again. Without this a second save would still be comparing
  # against the pre-edit seed.
  def ws_out_persisted : Nil
    @ws_out_seed = ws_out_messages_raw
    @ws_out_edited = false
  end

  def ws_upgrade_bytes : Bytes
    @ws_mode ? expanded_editor_bytes : (@ws_upgrade || Bytes.empty)
  end

  # Cross-process snapshot for `gori mcp get_repeater_context` (written into ui_state
  # by the TUI). Captures what the user is actually editing/sending — including
  # ephemeral WS/gRPC/decode tabs that never land in the `repeaters` table.
  def write_mcp_fields(j : JSON::Builder) : Nil
    j.field "target", @target
    j.field "summary", summary(80)
    j.field "http2", @http2
    j.field "auto_content_length", @auto_content_length
    j.field "ws_keep_key", @ws_keep_key
    # Both halves of the WebSocket answer, because they are two different facts and an MCP
    # client needs each: `ws_mode` is what the tab HOLDS (a handshake + frames), `ws_http_only`
    # is what `^R` currently DOES with it. A tab reporting `ws_mode: true, ws_http_only: true`
    # still lists its `messages` below — they are kept, not discarded.
    j.field "ws_mode", @ws_mode
    j.field "ws_http_only", @ws_http_only if @ws_mode
    j.field "grpc_mode", @grpc_mode
    j.field "decode_mode", decode_mode?
    if kind = @decode_kind
      j.field "decode_kind", kind.to_s
    end
    j.field "sni", @sni unless @sni.empty?
    j.field "inflight", inflight?
    j.field "focus", @focus.to_s
    if fid = source_flow_id
      j.field "source_flow_id", fid
    end
    if @ws_mode
      j.field "messages", @decoded.text
      unless ws_upgrade_bytes.empty?
        j.field "upgrade_request", String.new(ws_upgrade_bytes).scrub
      end
      if wr = @ws_result
        j.field "last_ws_result" do
          j.object do
            j.field "ok", wr.ok?
            j.field "upgraded", wr.upgraded?
            j.field "error", wr.error
            j.field "note", wr.note
            j.field "truncated", wr.truncated # a cap cut the inbound transcript short
            j.field "close_code", wr.close_code
            j.field "duration_us", wr.duration_us
            j.field "messages_sent", wr.messages.count(&.direction.==("out"))
            # Exclude the synthetic truncation marker: it is an inbound-direction diagnostic,
            # not a frame the peer sent (see `ws_transcript_lines`).
            j.field "messages_received", wr.messages.count { |m| m.direction == "in" && !Proxy::WS.notice?(m.payload) }
          end
        end
      end
    else
      j.field "request", request_text
      if res = @result
        j.field "last_result" do
          j.object do
            j.field "ok", res.ok?
            j.field "error", res.error
            j.field "duration_us", res.duration_us
            j.field "incomplete", res.incomplete? if res.incomplete?
            if resp = res.response
              j.field "status", resp.status
              j.field "reason", resp.reason
            end
          end
        end
      end
    end
  end

  # Apply a finished WS repeater transcript (the counterpart of #apply for HTTP).
  def apply_ws(result : Repeater::WsEngine::Result) : Nil
    @ws_result = result
    @ws_lines_cache = nil
    @scroll = 0
    # A send replaces BOTH response documents — the transcript here, and the handshake head via
    # the `@result` seed below (which `reset_result_caches` re-derives `resp_view` from). So the
    # parked sub-pane's anchor describes a document that no longer exists; zero it with the live
    # one rather than leaving `clamp_resp_cursor` to salvage a position from the last run.
    @resp_alt = {0, 0, 0, 0}
    resp_wrap_reset
    # Seed @result so the HTTP response tab can render the handshake response
    @result = Repeater::Result.new(result.handshake_head, Bytes.empty, nil, result.duration_us, result.error)
    reset_result_caches
  end

  # The transcript as {text, colour} rows (cached; rebuilt only when a new result
  # is applied). Multi-line payloads are split so each wire line is one row.
  private def ws_transcript_lines : Array({String, Color})
    drop_transcript_cache_on_theme_change
    @ws_lines_cache ||= begin
      rows = [] of {String, Color}
      if r = @ws_result
        r.messages.each do |m|
          arrow = m.direction == "out" ? "→" : "←"
          color = m.direction == "out" ? Theme.text : Theme.green
          text = "#{arrow} #{ws_transcript_body(m)}"
          text.split('\n').each_with_index { |t, i| rows << {i.zero? ? t : "    #{t}", color} }
        end
        if err = r.error
          rows << {"✗ #{err}", Theme.red}
        else
          sent = r.messages.count(&.direction.==("out"))
          # A synthetic truncation marker is an inbound-direction row but NOT a frame the peer
          # sent, so it must not inflate "N received" — a diagnostic is not traffic (frame.cr).
          recv = r.messages.count { |m| m.direction == "in" && !Proxy::WS.notice?(m.payload) }
          foot = String.build do |io|
            io << "✓ upgraded"
            io << " · closed #{r.close_code}" if r.close_code
            io << " · #{sent} sent, #{recv} received"
          end
          rows << {foot, Theme.muted}
          if note = r.note
            rows << {"⚠ #{note}", Theme.yellow}
          end
          # The cap-truncation summary. A `← [gori] …` marker row already sits above in the
          # transcript; this footer line is the same fact where the operator reads the run's
          # outcome, next to the note it is deliberately kept separate from.
          if trunc = r.truncated
            rows << {"⚠ #{trunc}", Theme.yellow}
          end
        end
      end
      rows
    end
  end

  # One transcript row's body: the frame's shape when it departs from an ordinary masked
  # TEXT frame, then the payload.
  #
  # A CLOSE row used to render its raw payload — `→ \x03\xEAbye-reason` — because the
  # transcript only ever expected opcodes 1 and 2. §5.5.1's status code is two BINARY bytes
  # in front of the reason, so the one row an operator reads when a WebSocket test fails
  # was the one row that came out as mojibake.
  private def ws_transcript_body(m : Repeater::WsEngine::Message) : String
    to_server = m.direction == "out"
    msg = Store::WsOutMessage.new(m.opcode, m.payload, m.shape)
    label = msg.shape_label(to_server)
    prefix = (m.opcode == 1 && m.shape.default?(to_server)) ? "" : "[#{label}] "
    if code = Store::WsMessage.new(0_i64, 0_i64, nil, 0_i64, m.direction, m.opcode, m.payload).close_code
      reason = m.payload.size > 2 ? String.new(m.payload[2, m.payload.size - 2]).scrub : ""
      return reason.empty? ? "#{prefix}code #{code}" : "#{prefix}code #{code} #{reason}"
    end
    return "#{prefix}«binary #{m.payload.size}b»" if m.opcode == 2
    "#{prefix}#{String.new(m.payload).scrub}"
  end
end
