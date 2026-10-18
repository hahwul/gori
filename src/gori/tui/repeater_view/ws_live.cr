require "../../repeater/ws_session"

# A persistent WebSocket session in the Repeater (#1630), on the EXISTING WS tab layout: the
# left MESSAGES list is the composer — the cursor line is what `↵` sends, and `^R` sends every
# line in order — and the right TRANSCRIPT streams both directions live as the frames arrive.
# The scripted one-shot send (`ws_repeater_send`) stays exactly as it was; "Live session" is a
# sticky Protocol… toggle (`␣Po`) that arms it. Reopens Gori::Tui::RepeaterView.
#
# The engine (`Repeater::WsSession`) owns the upgraded socket on ONE reader fiber and a capped
# in-memory transcript ring. This slice holds only the reference, the sent-row marks and the
# render throttle; it NEVER calls the session's `close` (it blocks) on the UI fiber — the
# controller spawns that. Nothing here is written to History, as every Repeater WS send is.
class Gori::Tui::RepeaterView
  # The fastest the open transcript re-renders, like the SSE live view (#1641): each tick
  # re-derives the rows from the ring (scrub + split), so this bounds the UI fiber's cost, not
  # the frame rate. The pause grows by one WS_LIVE_EVERY per WS_LIVE_STRETCH of buffered
  # payload, the same shape `live.cr` uses, so a big transcript re-renders less often.
  WS_LIVE_EVERY   = 100.milliseconds
  WS_LIVE_STRETCH = 1024 * 1024

  @ws_session : Repeater::WsSession? = nil
  @ws_keep_open = false     # the Protocol… "Live session" toggle: ^R connects and keeps the socket open
  @ws_heartbeat = false     # answer Engine.IO 2→3 (Protocol… `b`), off by default — it writes unasked
  @ws_live_seq = 0_i64      # the highest transcript seq rendered
  @ws_live_start = Time.utc # when the session opened — the transcript's `ss.mmm` and `open <dur>` origin
  @ws_live_at : Time::Instant? = nil
  # MESSAGES line index → the `ss.mmm` it was sent at, for the `✓ ss.mmm` right-edge marker.
  # ponytail: keyed by line index, so an edit that reorders lines leaves a stale mark; reset on
  # each connect, which is when it matters. Good enough for a live compose-and-send loop.
  @ws_sent_marks = {} of Int32 => String

  # The open (or just-closed, still-showing) session, or nil in scripted mode.
  getter ws_session : Repeater::WsSession?

  def ws_keep_open? : Bool
    @ws_keep_open
  end

  def ws_heartbeat? : Bool
    @ws_heartbeat
  end

  # The socket is still open.
  def ws_connected? : Bool
    (s = @ws_session) ? !s.closed? : false
  end

  # A session exists (open or ended) — the tab is showing a live transcript, not a scripted one.
  def ws_session_active? : Bool
    !@ws_session.nil?
  end

  # Arm/disarm keep-open mode (Protocol… `o`). The controller connects/disconnects off this;
  # no-op off a WS tab, the guard `toggle_ws_keep_key` uses.
  def toggle_ws_keep_open : Bool
    return @ws_keep_open unless ws_mode?
    @ws_keep_open = !@ws_keep_open
  end

  # Flip the Engine.IO heartbeat auto-reply (Protocol… `b`). Takes effect at the NEXT connect.
  def toggle_ws_heartbeat : Bool
    return @ws_heartbeat unless ws_mode?
    @ws_heartbeat = !@ws_heartbeat
  end

  # The auto-replies a connect installs: the Engine.IO pair when the toggle is on, else none.
  def ws_auto_replies : Array(Repeater::WsSession::AutoReply)
    @ws_heartbeat ? [Repeater::WsSession::ENGINE_IO_HEARTBEAT] : [] of Repeater::WsSession::AutoReply
  end

  # The MESSAGES cursor line — what `↵` sends — and its index, for the sent-row mark.
  def ws_cursor_message : {Int32, String}
    i = @decoded.cy
    {i, @decoded.lines_snapshot[i]? || ""}
  end

  # Every non-blank MESSAGES line with its index, in order — what `^R` sends while live.
  def ws_all_messages : Array({Int32, String})
    @decoded.lines_snapshot.each_with_index.compact_map { |line, i| {i, line} unless line.blank? }.to_a
  end

  # Record that MESSAGES line `idx` was sent now — drawn as `✓ ss.mmm` at the row's right edge.
  def mark_ws_sent(idx : Int32) : Nil
    @ws_sent_marks[idx] = ws_elapsed_label
  end

  # The `✓ ss.mmm` marker for a MESSAGES line, or nil if it has not been sent this session.
  def ws_sent_mark(idx : Int32) : String?
    @ws_sent_marks[idx]?.try { |t| "✓ #{t}" }
  end

  # `↑sent ↓recv`, counted over the ring in one pass by the engine (an evicted frame is not
  # counted — the status says `+N dropped` when that happens, and the transcript shows it).
  def ws_counts : {Int32, Int32}
    @ws_session.try(&.counts) || {0, 0}
  end

  # How long the socket has been open, for the TRANSCRIPT title (`● open 12s`).
  def ws_open_duration_label : String
    "#{(Time.utc - @ws_live_start).total_seconds.to_i}s"
  end

  # `ss.mmm` since the session opened — the transcript's per-row clock.
  private def ws_elapsed_label : String
    ws_fmt_ss_mmm(Time.utc - @ws_live_start)
  end

  private def ws_fmt_ss_mmm(span : Time::Span) : String
    ms = span.total_milliseconds.to_i64
    ms = 0_i64 if ms < 0
    "%d.%03d" % {ms // 1000, ms % 1000}
  end

  # Install a freshly-opened session and seed the handshake render from its result. The
  # controller's connect fiber hands both back once the 101 landed.
  def begin_ws_session(session : Repeater::WsSession, result : Repeater::WsEngine::Result) : Nil
    @ws_session = session
    @ws_result = result
    @ws_live_seq = 0_i64
    @ws_live_start = Time.utc
    @ws_live_at = nil
    @ws_closed_shown = false # a reconnected session that dies before any frame still shows its close
    @ws_sent_marks.clear
    # Seed @result so the HANDSHAKE RESPONSE card renders the 101, the seed `apply_ws` makes.
    @result = Repeater::Result.new(result.handshake_head, Bytes.empty, nil, result.duration_us, result.error)
    @resp_alt = {0, 0, 0, 0}
    resp_wrap_reset
    reset_result_caches
  end

  # Drop the session reference (the controller has already spawned its close). Used when the
  # tab is torn down; a plain disconnect keeps the reference so the final transcript stays up.
  def end_ws_session : Nil
    @ws_session = nil
  end

  # One UI tick on the open session. Re-renders when the ring grew (or the session just ended,
  # for the close footer) and WS_LIVE_EVERY has passed; true when it did. Only the controller's
  # active-tab gate calls this, so an inactive tab renders none of it. A scripted tab has no
  # session, so this is false for it.
  def ws_live_tick(now : Time::Instant = Time.instant) : Bool
    s = @ws_session || return false
    latest = s.last_seq # the newest seq, without copying the ring
    grew = latest > @ws_live_seq
    closing = s.closed? && !@ws_closed_shown
    return false unless grew || closing
    return false if (at = @ws_live_at) && now - at < WS_LIVE_EVERY * (1 + s.ring_bytes // WS_LIVE_STRETCH)
    @ws_live_seq = latest
    @ws_live_at = now
    @ws_closed_shown = s.closed?
    @ws_lines_cache = nil
    @resp_wrap.clear # the wrap memo describes the old rows; the transcript grew
    true
  end

  @ws_closed_shown = false # the close footer has had its one final render

  # The live transcript as {text, colour} rows: the dropped-frames note, one block per ring
  # entry (`ss.mmm → text <payload>` / `← …`, `↺` for an auto-reply), then the connection
  # state and — once it ends — the close reason. Called by `ws_transcript_lines` when a session
  # is present, in place of the scripted `@ws_result` rows.
  private def ws_live_lines(s : Repeater::WsSession) : Array({String, Color})
    rows = [] of {String, Color}
    if s.dropped > 0
      rows << {"… #{s.dropped} earlier #{s.dropped == 1 ? "frame" : "frames"} dropped (transcript full)", Theme.yellow}
    end
    s.transcript.each do |e|
      m = e.message
      to_server = m.direction == "out"
      arrow = e.auto ? "↺" : (to_server ? "→" : "←")
      color = e.auto ? Theme.muted : (to_server ? Theme.text : Theme.green)
      head = "#{ws_fmt_ss_mmm(e.at - @ws_live_start)} #{arrow} #{ws_live_body(m)}"
      head.split('\n').each_with_index { |t, i| rows << {i.zero? ? t : "        #{t}", color} }
    end
    rows << ws_live_status_row(s)
    rows
  end

  # One live row's body: the opcode word then the payload. A CLOSE carries its status + reason;
  # a binary frame its length + a short hex preview; text the scrubbed payload.
  private def ws_live_body(m : Repeater::WsEngine::Message) : String
    case m.opcode
    when Proxy::WS::OP_TEXT.to_i
      "text #{String.new(m.payload).scrub}"
    when Proxy::WS::OP_BIN.to_i
      "binary #{m.payload.size}b #{ws_hex_preview(m.payload)}"
    when Proxy::WS::OP_PING.to_i
      m.payload.empty? ? "ping" : "ping #{String.new(m.payload).scrub}"
    when Proxy::WS::OP_PONG.to_i
      m.payload.empty? ? "pong" : "pong #{String.new(m.payload).scrub}"
    when Proxy::WS::OP_CLOSE.to_i
      code = Repeater::WsEngine.close_status(m.payload)
      reason = m.payload.size > 2 ? String.new(m.payload[2, m.payload.size - 2]).scrub : ""
      "close#{code ? " #{code}" : ""}#{reason.empty? ? "" : " #{reason}"}"
    else
      "op#{m.opcode} #{m.payload.size}b"
    end
  end

  private def ws_hex_preview(payload : Bytes) : String
    shown = payload[0, Math.min(16, payload.size)].hexstring
    payload.size > 16 ? "#{shown}…" : shown
  end

  # The one status line at the foot of the live transcript: the state and, once ended, why.
  # Key-free prose — the view has no registry to expand a `{space:…}` token; the controller's
  # live status line names the keys instead.
  private def ws_live_status_row(s : Repeater::WsSession) : {String, Color}
    if reason = s.close_reason
      code = s.close_code.try { |c| " #{c}" } || ""
      {"✗ closed#{code} · #{reason}", Theme.red}
    else
      out, recv = ws_counts
      {"● open · ↑#{out} ↓#{recv}", Theme.green}
    end
  end
end
