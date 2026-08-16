# "Send group" mode: the `%%%`-separated pipeline the editor can hold, the framing rules a
# group send must satisfy before it goes out on one keep-alive connection, the minimize
# refusals, and the transcript every response lands in.
# Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # A lone line of exactly this (trimmed) splits the editor into the requests a "send
  # group" pipelines on one connection.
  #
  # Aliased to the ENGINE's constant rather than spelling `"%%%"` again. It was duplicated
  # for a real reason — nothing in `cli/` or `mcp/` may reach into `tui/`, so the headless
  # minimize surfaces could not have taken it from here — but the dependency runs the other
  # way and the TUI can take it from them. Four surfaces now refuse or split on this
  # separator; two spellings of it was the last drift left in that set, and a separator the
  # TUI and the engine disagreed about is precisely the "two places decide the split"
  # failure this whole seam exists to prevent. The local name stays: the comments here are
  # about pipelining, not about minimize.
  PIPELINE_SEP = Repeater::Minimize::GROUP_SEP

  # A group send is meaningful only in plain HTTP text mode (hex / gRPC / WS / decode /
  # MARK have their own byte semantics), over HTTP/1.1 (send_pipeline is an h1 primitive).
  def group_sendable? : Bool
    !@req_hex_edit && group_framing_applies?
  end

  # The modes in which a lone `%%%` line means "group" at all — `group_sendable?` minus the
  # hex clause. Split out because the two questions differ on exactly that clause: you
  # cannot RUN a group send from hex, but the hex buffer is a SNAPSHOT of the chunked pane
  # taken before `^X`, so it is still carrying a group's Content-Length and must still be
  # refused a whole-buffer send. Folding hex into this predicate is what let the sharpest
  # face of the defect through on the first attempt at the fix.
  private def group_framing_applies? : Bool
    !(@grpc_mode || ws_mode? || @decode_kind || @http2)
  end

  # "Minimize request" removes header/cookie/param lines from the plain-text request and
  # re-sends to verify the response is unchanged.
  def minimizable? : Bool
    minimize_refusal.nil?
  end

  # Why minimize cannot run on this buffer, or nil. Public and NAMED because these are three
  # different problems and "not minimizable" answers none of them; `minimizable?` is defined
  # in terms of it so the predicate and the sentence cannot drift.
  #
  # The `%%%` clause is the third whole-buffer reader on this branch. `repeater_minimize`
  # never calls `request_bytes` — it snapshots `request_text` and re-syncs Content-Length
  # over the whole buffer in its own `resolve` — so the framing `^R` now refuses ONCE, a
  # minimize did up to `Minimize::SEND_CAP` times in one keypress:
  #
  #   pane     Content-Length: 3     minimizable?  true
  #   resolve  Content-Length: 60    ×hundreds of probe sends
  #
  # Unlike `group_framing_refusal` this is NOT scoped to auto-CL: `Minimize.run` reads
  # `base_text` STRUCTURALLY as one request (head/body split, then header/cookie/param
  # candidates), so on a group buffer it strips lines out of the operator's SECOND request
  # and reports them as headers removed from the first — meaningless whether or not gori
  # wrote the Content-Length. With `^L` off a whole-buffer `^R` is still a legitimate
  # byte-exact send, which is why that one stays allowed and this one does not.
  #
  # h2 is fine, via `group_framing_applies?`: `%%%` is not a group there (send_pipeline is
  # an h1 primitive), the pane already reflects the whole buffer, and there is nothing
  # chunk-scoped to misread.
  def minimize_refusal : String?
    if @req_hex_edit || @grpc_mode || ws_mode? || @decode_kind
      return "minimize needs a plain HTTP text request (not hex/gRPC/WS/decode)"
    end
    unless marker_regions.empty?
      return "minimize does not render §…§ markers — clear them first (line removal and chain resolution are ambiguous together)"
    end
    if group_document?(@editor.wire_lines)
      return "request holds a %%% separator, so minimize would read several requests as one — " \
             "remove it, or minimize each request in its own tab"
    end
    nil
  end

  # The requests a "send group" pipelines: the editor text split on a lone `%%%` line,
  # each chunk env-expanded, CRLF-normalized and (honouring Auto-CL) length-synced.
  # Returns {label, wire-bytes}; an all-blank chunk is dropped, and no separator ⇒ the
  # single whole request. The label (the request line) heads that request's block in the
  # response transcript. A head-only (bodyless) chunk gets its CRLFCRLF terminator
  # appended — the blank line the user typed before `%%%` is consumed by the split, so we
  # must NOT rely on it surviving (the timeout-hunting bug the group-send E2E caught).
  # Carries each line's own terminator through the split, so a chunk's BODY keeps the CRs it
  # was captured with — the same reason `expanded_editor_bytes` reads `wire_text`. The last
  # surviving line's terminator is dropped: that newline is the one before the `%%%` (or the
  # end of the buffer), which belongs to the separator, not to the body.
  def pipeline_requests : Array({String, Bytes})
    wl = @editor.wire_lines
    chunk_line_spans(wl).map do |sp|
      {wl[sp.begin][0].strip, finalize_wire(expanded_text_to_bytes(chunk_text(wl, sp)))}
    end
  end

  # PROVENANCE, the `%%%` half of `markers_live?` — and the reason that one is not enough.
  # `%%%` is draft syntax too: it means "split here" only because the OPERATOR typed it.
  # A capture whose body happens to hold a lone `%%%` line (a diff hunk, a delimiter, a
  # template fragment) is not two requests, and treating it as two produced the same three
  # faces the `§` defect did — the visible `Content-Length` covering only the pre-`%%%`
  # bytes while `^R` sent the whole 17, `^X` snapshotting that head into a byte-exact send,
  # and `space ▸ g` manufacturing a second request whose request LINE was the capture's own
  # `line2`. Nobody authored that request.
  #
  # Unlike `§` there is no marking VERB to declare with, so the declaration is the count:
  # a separator the buffer holds beyond the ones the capture arrived with is one the
  # operator typed. Same question as `markers_live?` ("did the operator author this
  # token?"), answered with the strongest signal this seam has. Once they add one the whole
  # buffer is a group draft, captured separators included — the honest reading, and visible
  # in the per-chunk Content-Lengths the reflection immediately writes.
  #
  # A draft is unaffected: `@evidence` is false, so every `%%%` in it splits as it always
  # has. A restore lands with the baseline set from the restored text, for the same reason
  # `@markers_declared` lands false — the row says nothing about who typed which line, and
  # when gori cannot know, evidence wins.
  private def pipeline_live?(wl : Array({String, String})) : Bool
    !@evidence || pipeline_sep_count(wl) > @evidence_pipeline_seps
  end

  private def pipeline_sep_count(wl : Array({String, String})) : Int32
    wl.count { |(l, _)| l.strip == PIPELINE_SEP }
  end

  # The reason a WHOLE-BUFFER send is refused, or nil.
  #
  # A buffer holding a live `%%%` is TWO documents in one: the operator wrote requests, and
  # `reflect_content_length_in_editor` writes each one's OWN Content-Length into it — the
  # numbers `space ▸ g` puts on the wire, and the only reading of that pane that means
  # anything (no request in it has a whole-buffer-sized body). `^R` and the `^X` snapshot
  # then read the same buffer WHOLE, and one number cannot be right for both framings:
  #
  #   pane      Content-Length: 3     ← chunk 1's body, "AAA"
  #   ^R        Content-Length: 60    ← re-synced by finalize_wire; self-consistent, but the
  #                                     pane never said 60 and the operator authored 2 requests
  #   ^X then ^R  Content-Length: 3 over a 60-byte body  ← hex sends the snapshot verbatim:
  #                                     a CL/body desync gori INVENTED out of a correct draft
  #
  # So the whole-buffer framing is the one that has no meaning here, and it is refused by
  # name rather than picked silently. The alternative — reflecting the whole-buffer number
  # instead — only moves the lie onto `g`, which this method's own neighbour already calls
  # "the worse way round for a tool whose whole job is telling the operator what it sent".
  #
  # Scoped to auto-CL ON, because that is exactly when gori has written a number of its
  # own. With `^L` off the pane, `^R` and `g` all carry the operator's numbers unchanged,
  # nothing is invented, and a literal `%%%` line in a body stays expressible — which is
  # why the message names `^L` as the second remedy and not just `space ▸ g`.
  #
  # An EVIDENCE buffer whose capture merely CONTAINS `%%%` never reaches this: its separator
  # is not live (see `pipeline_live?`), nothing chunks, and `^R` sends it byte-exact.
  private def group_framing_refusal : String?
    return nil unless chunked_reflection?(@editor.wire_lines)
    "request holds a %%% separator, so its Content-Length describes the first request only — " \
    "space ▸ g sends the group on one connection, or turn ^L off to send the buffer whole as one request"
  end

  # Is the visible head carrying CHUNK-scoped Content-Lengths? The single predicate behind
  # both the reflection that writes them and the refusal that stops a whole-buffer send from
  # reading them — they are the same question, and letting them drift apart is the bug.
  #
  # `group_document?` is the structural half — "this buffer is SEVERAL requests" — and the
  # auto-CL clause is the "…and gori wrote a number for the first one" half. Split because
  # the two readers need different halves: `^R`/`^X` only lie when gori wrote the number
  # (with `^L` off a whole-buffer send is byte-exact and legitimate), while minimize is
  # meaningless on several requests whatever the number is. See `minimize_refusal`.
  private def chunked_reflection?(wl : Array({String, String})) : Bool
    @auto_content_length && group_document?(wl)
  end

  # Is this buffer several requests rather than one? `group_framing_applies?` (NOT
  # `group_sendable?` — see there): in gRPC / WS / decode / h2 a lone `%%%` is not a
  # separator at all, so those modes reflect the whole buffer and need no refusal. Hex is
  # in, because its bytes are a snapshot of a chunked pane.
  private def group_document?(wl : Array({String, String})) : Bool
    group_framing_applies? && pipeline_live?(wl) && pipeline_sep_count(wl) > 0
  end

  # Record what DRAFT SYNTAX the just-seeded buffer arrived with — the `%%%` separators it
  # already had, and the `$NAME` tokens it already referenced. Called from every loader
  # AFTER the editor is set, so both baselines describe the bytes gori was handed rather
  # than anything typed since. On a draft they are empty either way (`pipeline_live?` and
  # `operator_env_vars` short-circuit on `@evidence`); recording them anyway keeps a later
  # `duplicate_from` or an evidence flip from inheriting a stale baseline.
  private def seed_draft_baselines : Nil
    wire = @editor.wire_text
    @evidence_pipeline_seps = pipeline_sep_count_in(wire)
    @evidence_env_names = Env.token_names(wire).to_set
    # Assigned unconditionally, including the empty set a draft gets: a loader can turn a
    # tab that WAS evidence into one that isn't (load_blank after a ^R, a duplicate), and a
    # stale literal set would keep painting resolvable tokens as unknown on a buffer that
    # substitutes every one of them.
    @editor.env_literal_names = @evidence ? @evidence_env_names : Set(String).new
  end

  # The same count over raw text, for seeding the baseline at load/restore.
  private def pipeline_sep_count_in(text : String) : Int32
    text.split('\n').count { |l| l.strip(" \t\r") == PIPELINE_SEP }
  end

  # EDITOR line ranges of each `%%%` chunk, blank edges trimmed. The one place the group
  # split is decided, so the bytes `pipeline_requests` sends and the Content-Length
  # `reflect_content_length_in_editor` shows are derived from the SAME chunking — they used
  # to disagree, and the visible header was the one that was wrong. No separator ⇒ one span
  # covering the whole buffer, which is the ordinary single-request case, and so does a
  # separator that is the CAPTURE's rather than the operator's (see `pipeline_live?`).
  private def chunk_line_spans(wl : Array({String, String})) : Array(Range(Int32, Int32))
    return [0...wl.size] unless pipeline_live?(wl)
    spans = [] of Range(Int32, Int32)
    push = ->(a : Int32, b : Int32) do
      while a < b && wl[a][0].strip.empty? # drop blank lines around the separator
        a += 1
      end
      while b > a && wl[b - 1][0].strip.empty?
        b -= 1
      end
      spans << (a...b) if a < b
    end
    start = 0
    wl.each_with_index do |(l, _), i|
      next unless l.strip == PIPELINE_SEP
      push.call(start, i)
      start = i + 1
    end
    push.call(start, wl.size)
    spans
  end

  # One chunk's wire text. The LAST line's terminator is dropped: that newline is the one
  # before the `%%%` (or the end of the buffer), so it belongs to the separator rather than
  # to the body — the same trim the blank-line shift/pop above performs at the edges.
  private def chunk_text(wl : Array({String, String}), sp : Range(Int32, Int32)) : String
    String.build do |io|
      sp.each do |i|
        io << wl[i][0]
        io << wl[i][1] unless i == sp.end - 1
      end
    end
  end

  # True when the wire bytes already carry a CRLFCRLF head/body separator (so appending
  # a terminator would be wrong). expand_wire normalizes to CRLF, so CRLFCRLF is the only
  # separator to look for.
  private def has_head_terminator?(bytes : Bytes) : Bool
    i = 0
    while i + 3 < bytes.size
      return true if bytes[i] == 0x0d_u8 && bytes[i + 1] == 0x0a_u8 && bytes[i + 2] == 0x0d_u8 && bytes[i + 3] == 0x0a_u8
      i += 1
    end
    false
  end

  # Append the CRLFCRLF head terminator to a head-only request (no body separator present).
  private def terminate_head(raw : Bytes) : Bytes
    term = "\r\n\r\n".to_slice
    buf = Bytes.new(raw.size + term.size)
    raw.copy_to(buf)
    term.copy_to(buf[raw.size, term.size])
    buf
  end

  def group_mode? : Bool
    !@group_results.nil?
  end

  # Show a pipelined group's responses (one transcript, replacing the single-response
  # pane). `labeled` pairs each request's label with its Result, in send order.
  def apply_group(labeled : Array({String, Repeater::Result})) : Nil
    @result = nil # the group transcript takes over the response pane
    @prev_result = nil
    @group_results = labeled
    reset_result_caches
    @resp_mode = :response
    @resp_hex = false
    @reveal = false
    @scroll = 0
    resp_wrap_reset
    @resp_cursor.reset
    @inflight = false
    @loaded = true
  end

  GROUP_PREVIEW_LINES = 500 # per-response cap in the group transcript (scrollable; guards a huge body)

  # The pipelined-group transcript as {text, colour} rows (cached): each request's label,
  # a status/size/timing summary, then that response's head + (decoded) body — every
  # response stacked so a poisoned / desynced reply on the shared connection is visible.
  private def group_transcript_lines : Array({String, Color})
    drop_transcript_cache_on_theme_change
    @group_lines_cache ||= begin
      rows = [] of {String, Color}
      results = @group_results || [] of {String, Repeater::Result}
      results.each_with_index do |(label, res), i|
        st = res.response.try(&.status)
        # Same ladder. The hand-rolled version also collapsed 3xx into green, where
        # `status_color` gives it accent — a redirect is not a 2xx.
        head_color = res.error ? Theme.red : Theme.status_color(st)
        rows << {"══ req #{i + 1} · #{label}", Theme.text_bright}
        summary = if res.error && !res.head.empty?
                    "HTTP #{st} · #{res.error}" # a partial response + a read error (e.g. a CL+TE desync)
                  elsif res.error
                    "✗ #{res.error}"
                  elsif st
                    "HTTP #{st} · #{Fmt.size((res.head.size + (res.body.try(&.size) || 0)).to_i64)} · #{Fmt.dur(res.duration_us)}#{res.incomplete? ? " ⚠ incomplete" : ""}"
                  else
                    "no response"
                  end
        rows << {summary, head_color}
        unless res.head.empty?
          lines = message_lines(res.head, display_body(res.head, res.body))
          lines.first(GROUP_PREVIEW_LINES).each { |l| rows << {l, Theme.text} }
          rows << {"  … #{lines.size - GROUP_PREVIEW_LINES} more line(s)", Theme.muted} if lines.size > GROUP_PREVIEW_LINES
        end
        rows << {"", Theme.muted} unless i == results.size - 1
      end
      rows
    end
  end
end
