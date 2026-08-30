# Editor-side header reflection: keeping `Content-Length` in step with the edited body (and
# with a chunked body's own reflection), and mirroring the target host into `Host:` once on a
# fresh `^N` tab. Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # When enabled, keep `Content-Length` matching the actual edited body length (the
  # part after the blank line): rewrite an existing header, or ADD one when a non-empty
  # body has none at all (leaving the header out entirely otherwise sends a
  # framing-ambiguous request most origins read as an empty body). A bodyless request
  # (GETs stay clean) never gets a header added; chunked/h2 bodies have no
  # Content-Length and are left untouched. Shared with the headless CLI/MCP
  # repeater-send paths via FlowRequest so they can't drift apart.
  private def sync_content_length(raw : Bytes) : Bytes
    Repeater::FlowRequest.resync_content_length(raw)
  end

  # Mirror the auto-Content-Length resync into the visible REQUEST editor (^L on) so
  # the pane shows the same header `request_bytes` will send — not only at ^R time.
  #
  # PER CHUNK, because a `%%%` send-group is several requests and `pipeline_requests` frames
  # each one separately. Reflecting over the whole buffer made the FIRST request's visible
  # `Content-Length` cover the body, the `%%%` line and the entire second request (`3` → `62`
  # in the reported case). The wire was right and the editor was not, which is the worse way
  # round for a tool whose whole job is telling the operator what it sent. Chunk 2 onwards
  # was never reflected at all.
  #
  # Only a REAL `%%%` group is chunked, though. Without a separator ^R sends the whole
  # buffer, trailing newline and all, and `chunk_line_spans` trims blank edges + drops the
  # last line's terminator — correct around a separator, wrong for a body that legitimately
  # ends in one. Reflecting through it made a captured `…tail-after-blank\r\n` read as 32
  # where the send framed 34: the same display-vs-wire lie in the other direction.
  private def reflect_content_length_in_editor(allow_hooks : Bool = false) : Nil
    return unless @auto_content_length
    return if @req_hex_edit || @grpc_mode || ws_mode?
    return if @decode_kind && @req_pane == :decoded
    # Asked ONCE for the whole buffer, not once per `%%%` chunk: the answer is a property of
    # the marker set, and `reflect_chunk_content_length` below parses the template again for
    # every chunk it renders — asking there doubled the parse count on the busiest editor in
    # the app. `allow_hooks` is what an explicit gesture (`^L`) passes; see the method below.
    return if !allow_hooks && marker_chain_runs_command?

    wl = @editor.wire_lines
    # `chunked_reflection?`, not "is there a `%%%` anywhere". A separator the CAPTURE brought
    # is not live, and a mode that cannot group-send has no chunks — in both cases chunking
    # would put chunk 1's length in the visible head while ^R (and the `^X` snapshot of that
    # head) frame the whole buffer. Where it IS chunked, `group_framing_refusal` reads the
    # same predicate and stops the whole-buffer send rather than let the two disagree.
    if chunked_reflection?(wl)
      chunk_line_spans(wl).each { |sp| reflect_chunk_content_length(chunk_text(wl, sp), wl, sp) }
    else
      reflect_chunk_content_length(@editor.wire_text, wl, 0...wl.size)
    end
  end

  # Whether any `§value¦chain§` in this buffer would run an EXTERNAL COMMAND (#818) — the one
  # condition under which the reflection above declines to touch the header.
  #
  # THIS RUNS ON THE KEYSTROKE PATH, and `render_marked` below derives the length by replaying
  # every marker's chain — so an `exec:` step forked the operator's command once per typed
  # character, and once more on every `restore` (a project reopen therefore ran every saved
  # tab's command). A hook is by definition allowed to have side effects; typing is not a send.
  #
  # LEAVING THE HEADER ALONE, rather than reflecting with the hook withheld. A length measured
  # on the UNTRANSFORMED value is a number no request will ever carry — the display-vs-wire lie
  # this file exists to prevent, told in the other direction. The visible line can therefore lag
  # while such a tab is edited; both places where that would REACH the wire close it. `^R` goes
  # through `finalize_wire`, which resyncs from the fully rendered bytes; and `^L` — the moment
  # the operator takes ownership of the header — reflects once with `allow_hooks: true`, because
  # an explicit gesture may spend one run of the command where a keystroke may not.
  #
  # Asked of the EXPANDED bytes, the ones `render_marked` will parse: a `$KEY` inside a chain
  # spec is substituted before the spec is tokenized, so the editor's own text can spell a
  # command it does not contain. And asked through `Decoder.chain_runs_commands?`, not by
  # scanning for the marker: a saved chain is callable by NAME and its token says nothing.
  private def marker_chain_runs_command? : Bool
    return false if marker_regions.empty? # the common case, and `marker_regions` is cached
    Fuzz::Template.parse(String.new(expanded_editor_bytes)).runs_commands?(Decoder.shared_registry)
  end

  # The reflection for ONE request: `text` is exactly the bytes that request will be built
  # from. `wl` is the pre-edit line snapshot; a replace_line here swaps a line in place
  # without changing the line COUNT, so the spans and indices taken from it stay valid
  # across the loop above.
  private def reflect_chunk_content_length(text : String, wl : Array({String, String}),
                                           sp : Range(Int32, Int32)) : Nil
    # Expand env tokens first (like the send path's expanded_editor_bytes) — a `$KEY`
    # whose expansion changes the body length must reflect the SENT Content-Length, or
    # the visible header goes stale and, once Auto-CL is toggled off, is sent mismatched.
    raw = expanded_text_to_bytes(text)
    # With §…§ markers present the CL that ^R actually sends is computed from the
    # RENDERED template (markers stripped, chains applied), not the raw marked text —
    # reflect THAT value so the visible header matches request_bytes.
    source = marker_regions.empty? ? raw : render_marked(raw)
    synced = sync_content_length(source)
    return if synced == source

    synced_head = String.new(synced).split("\r\n\r\n", limit: 2).first
    return unless synced_head
    new_line = synced_head.split("\r\n").find { |l| l.lstrip.downcase.starts_with?("content-length:") }
    return unless new_line

    # This chunk's HEAD is its lines up to the first blank one (the LF-space `\n\n` the old
    # whole-buffer scan looked for, scoped to the chunk).
    head_end = (sp.begin...sp.end).find { |i| wl[i][0].empty? } || return
    # Locate the Content-Length line in the RAW editor head by CONTENT, not by transplanting
    # the expanded-space index — a multi-line $KEY expansion earlier can shift the line count,
    # so the index would otherwise point at (and overwrite) an unrelated raw header line.
    idx = (sp.begin...head_end).find { |i| wl[i][0].lstrip.downcase.starts_with?("content-length:") }
    return unless idx
    return if wl[idx][0] == new_line
    return unless plain_numeric_header?(wl[idx][0])

    @editor.replace_line(idx, new_line)
  end

  # Whether a `Content-Length:` line carries a plain decimal value and nothing else — the
  # ONLY shape the reflection is allowed to rewrite, because the rewrite replaces the WHOLE
  # line and anything else on it would be destroyed.
  #
  # Two failures, one guard. The first is mid-edit clobber: the reflection runs on every
  # keystroke, so the transient line a paste or a typed header produces —
  # `Content-Length: 4GET / HTTP/1.1`, the pasted header with the buffer's next line still
  # glued to its tail — matched the prefix and was replaced by `Content-Length: 53`, taking
  # `GET / HTTP/1.1` with it. Silently, and `Ctrl-Z` could not bring it back (see
  # `edit_undo`). Typing the header by hand in front of an existing one did the same to
  # whatever followed the caret.
  #
  # The second is that gori is a tool for sending requests an origin should not accept. A
  # `Content-Length: 0abc`, a `Content-Length: +5`, an empty one, an indented (obs-fold) one —
  # request-smuggling and desync primitives an operator types ON PURPOSE — and auto-CL quietly
  # correcting them means the test on screen is not the test on the wire. Auto-CL's job is
  # keeping an ordinary length honest while the body is edited; a value that is not a bare
  # number is a deliberate one, so it is left exactly as typed. (Surrounding OWS and leading
  # zeros are NOT in that set: `strip` runs before the digit test, so `  0005  ` is an ordinary
  # length and is kept honest. The rule is about the value's SHAPE, not its spelling.)
  #
  # A DUPLICATED Content-Length is deliberate too, and it is guarded one level down rather
  # than here: `resync_content_length` refuses the whole message when it finds two, so
  # `reflect_chunk_content_length`'s `synced == source` early return means this predicate is
  # never even reached for one.
  #
  # THE predicate lives in `Repeater::FlowRequest`, because the WIRE has to apply the same
  # rule and did not: `resync_content_length` rewrote a `Content-Length: 0abc` that this
  # guard deliberately preserved, so the pane went on showing `0abc` while the socket got
  # `Content-Length: 2` — the display-vs-wire lie the paragraph above is entirely about,
  # told by the half nobody was looking at.
  private def plain_numeric_header?(line : String) : Bool
    Repeater::FlowRequest.rewritable_length_header?(line)
  end

  # See @link_host_to_target: on the FIRST target edit of a fresh ^N tab, mirror the new
  # host into the Host header (a ^N tab starts on https://example.com / Host: example.com,
  # so without this the user edits both). One-shot — cleared after the first sync, and it
  # only fires once the target actually moved off the placeholder.
  # Public so the send path can flush it too: ^R sends WITHOUT going through
  # exit_target_insert! (a modified chord defers straight to the keymap), so a
  # type-target-then-^R flow would otherwise send the stale Host. Calling this at send
  # prep (repeater_send, beside commit_chain_pane) closes that. No-op unless armed.
  def sync_host_to_target_once : Nil
    return unless @link_host_to_target
    return if @target == BLANK_TARGET # not edited off the placeholder yet — keep waiting
    _, host, _ = parse_target
    return if host.empty? # edited to something with no parseable host — stay armed for a real one
    @link_host_to_target = false
    reflect_target_host_in_editor
  end

  # Rewrite the request's `Host:` line to the target's authority (host, or host:port for a
  # non-default port). Plain text tabs only — WS/gRPC/hex request buffers frame their host
  # elsewhere. Models reflect_content_length_in_editor (locate the header by content, then
  # replace_line). @dirty is already set by the target edit that triggered this.
  private def reflect_target_host_in_editor : Nil
    return if @req_hex_edit || ws_mode? || @grpc_mode
    scheme, host, port = parse_target
    return if host.empty?
    # Shared with the engine and the CLI (build_target derives from the same call), so the
    # three cannot drift. The local formula this replaced never re-bracketed an IPv6 literal —
    # parse_target hands back a bracket-free host — and so wrote the malformed `Host: ::1:8443`.
    authority = Repeater::FlowRequest.authority(scheme, host, port)
    env_sep = @editor.text.index("\n\n")
    return unless env_sep
    head_lines = @editor.text[0, env_sep].split('\n')
    host_idx = head_lines.index(&.lstrip.downcase.starts_with?("host:"))
    return unless host_idx
    new_line = "Host: #{authority}"
    return if head_lines[host_idx] == new_line
    # Single-token value only — the `Content-Length` guard's rule for the same reason (this
    # rewrite replaces the WHOLE line, so anything else riding on it would be destroyed) and
    # for the same second reason: an authority carrying a space is either mid-edit text or a
    # deliberately malformed Host, and neither is gori's to silently correct.
    return unless single_token_header?(head_lines[host_idx])
    @editor.replace_line(host_idx, new_line)
  end

  # Whether a header line's value is one whitespace-free token — see the call site.
  private def single_token_header?(line : String) : Bool
    value = line.split(':', 2)[1]?
    return false unless value
    token = value.strip
    !token.empty? && !token.each_char.any?(&.whitespace?)
  end
end
