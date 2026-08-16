# The content model behind the response pane: the windowed styled view, the diff lines, the
# per-result caches all of that is memoized in, and the byte→line helpers everything reads
# through. Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # --- content ------------------------------------------------------------

  # The visible line count of the active response view (drives the scroll bound + the gauge).
  private def resp_line_count : Int32
    if resp_handshake_active?
      {resp_view.total, 1}.max
    elsif ws_mode?
      {ws_transcript_lines.size, 1}.max
    elsif @grpc_mode
      {grpc_transcript_lines.size, 1}.max
    elsif resp_hex_active?
      (bytes = resp_hex_bytes) ? HexView.rows(bytes.size) : 1
    elsif @resp_mode == :diff
      diff_lines.size
    elsif @reveal && (rl = reveal_lines)
      rl.size
    else
      resp_view.total
    end
  end

  # Windowed response: the head is styled eagerly; the body stays as lazy BodyLines
  # and is styled ONE VISIBLE LINE AT A TIME at render, so a multi-MiB replayed
  # response opens instantly instead of allocating/tokenising every off-screen line.
  # (For the not-sent / error placeholders the whole content is the bounded `head`.)
  # Mirrors the History detail windowing.
  private record RespView,
    head : Array(Highlight::Line),
    body : Highlight::BodyLines,
    kind : Symbol do
    def total : Int32
      head.size + body.size
    end

    def line_at(i : Int32) : Highlight::Line
      return head[i] if i < head.size
      Highlight.body_styled(body[i - head.size], kind)
    end

    # Plain text of line `i` for searching — body lines raw (no re-styling).
    def line_text(i : Int32) : String
      i < head.size ? head[i].map(&.text).join : body[i - head.size]
    end
  end

  # Memoized + dropped only when a new result is applied (reset_result_caches), so
  # a held Repeater tab isn't re-parsed / re-highlighted / re-diffed 20×/sec.
  private def reset_result_caches : Nil
    resp_wrap_reset # the wrap memo describes the OLD rows; a new result replaces them
    drop_resp_view_cache
    @diff_lines_cache = nil
    @resp_hex_bytes = nil
    @ws_lines_cache = nil
    @grpc_lines_cache = nil
    @group_lines_cache = nil
  end

  # The transcript caches bake Theme colours into each row, so a runtime palette
  # switch (Theme.revision bump) must drop them — mirrors resp_view's guard — else
  # the transcript keeps the old theme's colours until the next send.
  private def drop_transcript_cache_on_theme_change : Nil
    return if @transcript_rev == Theme.revision
    @ws_lines_cache = nil
    @grpc_lines_cache = nil
    @transcript_rev = Theme.revision
  end

  # Drop the styled response view AND the per-line styled-body memo together — the memo
  # holds Lines built from the current view (theme colours + pretty/raw body), so the two
  # MUST move in lockstep. Every site that invalidates the response view goes through here.
  private def drop_resp_view_cache : Nil
    @resp_view_cache = nil
    @resp_styled_cache.clear
    @resp_text_i = -1 # same keying, same hazard — see `resp_line_text`
  end

  private def resp_view : RespView
    drop_resp_view_cache if @resp_view_rev != Theme.revision # theme switched → rebuild with new colours
    @resp_view_rev = Theme.revision
    @resp_view_cache ||= begin
      result = @result
      @resp_pretty_applied = false
      if !result
        RespView.new([[Highlight::Span.new("— not sent — press ^R to resend —", Theme.muted)]], Highlight::BodyLines.empty, :text)
      elsif !result.ok?
        RespView.new([[Highlight::Span.new("repeater error: #{result.error}", Theme.red)]], Highlight::BodyLines.empty, :text)
      else
        src = display_body(result.head, result.body)
        # Pretty-print the response body (display only). The DIFF path uses
        # `display_body` directly (not this view), so both diff sides stay on the
        # same unformatted bytes — pretty never destabilises the diff.
        pretty = @pretty ? Pretty.format(result.head, src) : nil
        @resp_pretty_applied = pretty != nil
        win = Highlight.message_windowed(result.head, pretty.try(&.bytes) || src, request: false, kind: pretty.try(&.kind))
        RespView.new(win.head, win.body, win.kind)
      end
    end
  end

  private def diff_lines : Array(Repeater::DiffLine)
    @diff_lines_cache ||= begin
      result = @result
      if !(result && result.ok?)
        [Repeater::DiffLine.new(Repeater::DiffKind::Same, "send the request (^R) to see a diff")]
      elsif !(baseline = diff_baseline_lines)
        [Repeater::DiffLine.new(Repeater::DiffKind::Same, "— first send: resend (^R) to diff against the previous response —")]
      else
        fresh = message_lines(result.head, display_body(result.head, result.body))
        rows = Repeater::Diff.lines(baseline, fresh)
        # The Comparer tab has always shown this; the Repeater diff tab rendered a CUT diff
        # with nothing to say so, and an empty diff then reads as "the payload changed
        # nothing". Prepended rather than appended: at the cap the row list is long, and a
        # marker at the bottom is the one an operator scrolls past.
        if Repeater::Diff.truncated?(baseline, fresh)
          rows.unshift(Repeater::DiffLine.new(Repeater::DiffKind::Same,
            "— diff truncated to #{Repeater::Diff::MAX_LINES} lines/side; later lines were not compared —"))
        end
        rows
      end
    end
  end

  # The lines the current response is diffed against: the IMMEDIATELY PREVIOUS
  # send's response, falling back to the original captured response on the first
  # resend of a History-loaded flow. nil → nothing to diff against yet.
  private def diff_baseline_lines : Array(String)?
    if (prev = @prev_result) && prev.ok?
      message_lines(prev.head, display_body(prev.head, prev.body))
    elsif @diffable
      @original_lines
    end
  end

  private def build_target(scheme : String, host : String, port : Int32) : String
    Repeater::FlowRequest.build_target(scheme, host, port) # shared with the engine (was duplicated)
  end

  # Rewrites an absolute-form request-line ("GET http://h/p ...") to origin-form
  # ("GET /p ..."); origin-form requests are left unchanged.
  # The captured request as editor text, with ONLY the request line rewritten (absolute-form
  # → origin-form). Everything after the first line is passed through byte for byte.
  #
  # It used to split/rstrip/re-join the whole message, which flattened every terminator in
  # the request — head AND body — before `set_text` ever saw it. That happened at LOAD, so
  # no amount of care in the send path could have recovered the bytes.
  private def origin_form_text(detail : Store::FlowDetail) : String
    raw = String.new(combine(detail.request_head, detail.request_body))
    nl = raw.index('\n')
    first = nl ? raw[0, nl] : raw
    rest = nl ? raw[nl..] : ""
    line = first.rstrip('\r')
    eol = first[line.size..] # the CRs the request line carried — put back verbatim
    parts = line.split(' ')
    if parts.size == 3 && (parts[1].starts_with?("http://") || parts[1].starts_with?("https://"))
      line = "#{parts[0]} #{to_origin(parts[1])} #{parts[2]}"
    end
    "#{line}#{eol}#{rest}"
  end

  private def to_origin(url : String) : String
    uri = URI.parse(url)
    path = uri.path
    path = "/" if path.empty?
    uri.query ? "#{path}?#{uri.query}" : path
  rescue
    url
  end

  private def combine(head : Bytes, body : Bytes?) : Bytes
    return head unless body && !body.empty?
    io = IO::Memory.new
    io.write(head)
    io.write(body)
    io.to_slice
  end

  private def message_lines(head : Bytes?, body : Bytes?) : Array(String)
    lines = bytes_to_lines(head)
    if body && !body.empty?
      lines << ""
      lines.concat(bytes_to_lines(body))
    end
    lines
  end

  # A RESPONSE body decoded for display (gzip/deflate/br/zstd + de-chunk), or the
  # raw body when there's nothing to decode. Used only for the read-only response
  # view + diff baseline — NEVER for the request editor / resend bytes, which must
  # stay byte-exact. Decoding the same (head, body) identically keeps the styled
  # and plain response views 1:1 in line count.
  private def display_body(head : Bytes?, body : Bytes?) : Bytes?
    decoded, _ = Proxy::Codec::ContentDecode.decode(head, body)
    decoded || body
  end

  private def bytes_to_lines(bytes : Bytes?) : Array(String)
    return [] of String unless bytes
    String.new(bytes).split('\n').map(&.rstrip('\r'))
  end
end
