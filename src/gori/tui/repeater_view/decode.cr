# Split-decode repeater mode (SAML / GraphQL): the ENVELOPE editor over the whole request
# and the DECODED payload editor below it, `^T` between them, and the re-encode that splices
# an edited payload back into the envelope with Content-Length resynced.
# Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # A split-decode tab (SAML/GraphQL): the envelope + a decoded payload sub-pane.
  def decode_mode? : Bool
    !@decode_kind.nil?
  end

  getter? decode_kind : Symbol? # nil | :saml | :graphql (the active payload codec)
  getter req_pane : Symbol      # :envelope | :decoded (active request sub-pane)

  # Load a SAML flow into split-decode repeater: the envelope editor holds the FULL
  # request (headers/target/params — all editable); the decoded editor holds the XML,
  # re-encoded back into the param on send (if edited). Sent as a NORMAL request.
  def load_saml(detail : Store::FlowDetail, doc : Saml::Doc) : Nil
    @saml_param = doc.param
    @saml_binding = doc.binding
    @saml_location = doc.location == :query ? :query : :body
    seed_decode(detail, :saml, doc.xml)
  end

  # Load a GraphQL flow: envelope = full request; decoded = the operation as readable
  # query + variables (Graphql.display), re-composed into the JSON body on send.
  def load_graphql(detail : Store::FlowDetail, op : Graphql::Op) : Nil
    # Record the binding (POST body vs GET ?query=) so the re-encode targets the right place —
    # mirrors @saml_location. Without it a GET GraphQL edit would splice into a phantom body
    # while the origin reads the stale URL query (the decoded edit would never reach it).
    @graphql_location = Graphql.location(detail.request_body, detail.request_head)
    seed_decode(detail, :graphql, Graphql.display(op))
  end

  # Shared seeding for a split-decode tab: envelope = the full editable request,
  # decoded = the payload, focus on the envelope, decoded pane clean (so an untouched
  # payload re-sends byte-for-byte). Session-only (db_id nil) — see the controller.
  private def seed_decode(detail : Store::FlowDetail, kind : Symbol, payload : String) : Nil
    @flow = detail
    @evidence = true
    @markers_declared = false
    @decode_kind = kind
    @ws_mode = false
    @ws_http_only = false # in lockstep with @ws_mode — a decode tab holds no handshake
    @grpc_mode = false
    @http2 = detail.http_version == "HTTP/2"
    @target = build_target(detail.row.scheme, detail.row.host, detail.row.port)
    @tcx = @target.size
    @sni = ""
    @scx = 0
    @target_field = :url
    @editor.set_text(origin_form_text(detail))
    seed_draft_baselines
    @decoded.set_text(payload)
    @req_pane = :envelope
    @decoded_dirty = false
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

  # The editor the request column's input/cursor targets: the decoded payload when its
  # split sub-pane is active, else the envelope (the only editor in a non-decode tab).
  private def req_editor : TextArea
    (req_split? && @req_pane == :decoded) ? @decoded : @editor
  end

  # ^T: toggle the active request sub-pane (envelope ⇄ decoded). No-op outside a
  # split-decode tab. Returns the new active pane (the controller surfaces a hint).
  def toggle_req_pane : Symbol
    switch_req_pane(@req_pane == :envelope ? :decoded : :envelope)
    @req_pane
  end

  # Flush any pending decoded-pane edit into the envelope — so a consumer reading the
  # envelope as the request (fuzz/mine cross-tab) sees the latest payload edit even if
  # the user hasn't switched panes yet. No-op outside a decode tab / when unchanged.
  def flush_decoded_edits : Nil
    commit_decoded
  end

  # Change the active sub-pane, keeping the two in sync at the boundary: leaving the
  # DECODED pane COMMITS the edited payload into the envelope (so the envelope reflects
  # it); entering DECODED RE-DECODES the envelope's current param (so it reflects any
  # envelope edits). No-op outside a decode tab / when the pane is unchanged.
  private def switch_req_pane(to : Symbol) : Nil
    return unless req_split?
    return if to == @req_pane
    if @decode_kind
      to == :envelope ? commit_decoded : refresh_decoded
    end
    @req_pane = to
    # ONE `@req_read` serves both sub-panes (it is a cursor over whatever `req_editor`
    # returns), so an anchor left over from the pane being left would paint a band across
    # the arriving buffer's text — coordinates from one document applied to another. A
    # single-buffer tab never had this to answer for; a split one does, and the answer is
    # that crossing panes ends the selection, exactly as it would in INS (`edit_move`'s
    # cross-pane branch deliberately does not forward `selecting`).
    @req_read.clear_selection
    req_editor.clear_selection
  end

  # Re-encode the (edited) decoded payload back into the envelope — SAML param via
  # replace_param, GraphQL body via recompose — and resync Content-Length, so the
  # ENVELOPE is always the authoritative wire request. Only when the payload changed.
  private def commit_decoded : Nil
    return unless @decode_kind && @decoded_dirty
    # Honour the Auto-Content-Length toggle like the plain / MARK send paths do; with
    # Auto-CL off, an intentionally-desynced length (a smuggling test) must survive.
    spliced = splice_decoded_into(@editor.text)
    @editor.set_text(@auto_content_length ? sync_cl_text(spliced) : spliced)
    @decoded_dirty = false
  end

  # Re-decode the envelope's current param into the DECODED pane (and re-sync the SAML
  # param/binding), so an envelope-side edit shows up decoded. Leaves DECODED untouched
  # when the envelope no longer decodes (a mid-edit break shouldn't clobber it).
  private def refresh_decoded : Nil
    tgt, head, body = envelope_parts
    case @decode_kind
    when :saml
      if doc = Saml.from_flow(tgt, head, body, nil, nil)
        @saml_param, @saml_binding = doc.param, doc.binding
        @saml_location = doc.location == :query ? :query : :body
        @decoded.set_text(doc.xml) if doc.xml != @decoded.text
      end
    when :graphql
      if op = Graphql.from_flow(tgt, head, body)
        # Recompute the re-encode target too (mirrors SAML): an envelope edit that moves the
        # op from ?query=… (GET) to a JSON body (POST) must retarget the splice, else commit
        # rewrites the wrong side and the origin reads the old, unedited query.
        @graphql_location = Graphql.location(body, head)
        text = Graphql.display(op)
        @decoded.set_text(text) if text != @decoded.text
      end
    end
  end

  # The envelope editor split into {request-target, head bytes, body bytes} for
  # re-decoding — head/body divide at the first blank line (the editor holds LF).
  private def envelope_parts : {String, Bytes, Bytes?}
    env = @editor.text
    sep = env.index("\n\n")
    head = sep ? env[0, sep] : env
    body = sep ? env[(sep + 2)..] : ""
    target = (head.each_line.first? || "").split(' ')[1]? || "/"
    {target, head.to_slice, body.empty? ? nil : body.to_slice}
  end

  private def splice_decoded_into(env : String) : String
    case @decode_kind
    when :saml    then saml_splice_text(env)
    when :graphql then graphql_splice_text(env)
    else               env
    end
  end

  private def saml_splice_text(env : String) : String
    value = Saml.encode_value(@decoded.text, @saml_binding)
    if @saml_location == :query # Redirect: rewrite the request-line query (no body)
      lines = env.split('\n')
      lines[0] = saml_query_line(lines[0], value) if lines[0]?
      lines.join('\n')
    else # POST: replace the body param, keep the rest
      sep = env.index("\n\n") || return env
      "#{env[0, sep]}\n\n#{Saml.replace_param(env[(sep + 2)..], @saml_param, value)}"
    end
  end

  # Rewrite a request line's query with the SAML param re-encoded (Redirect binding),
  # reading the original query from the line itself (single source of truth).
  private def saml_query_line(rl : String, value : String) : String
    sp1 = rl.index(' ')
    sp2 = rl.rindex(' ')
    return rl unless sp1 && sp2 && sp2 > sp1
    target = rl[(sp1 + 1)...sp2]
    qidx = target.index('?')
    path = qidx ? target[0, qidx] : target
    query = Saml.replace_param(qidx ? target[(qidx + 1)..] : "", @saml_param, value)
    "#{rl[0, sp1]} #{path}?#{query} #{rl[(sp2 + 1)..]}"
  end

  private def graphql_splice_text(env : String) : String
    # `:none` — a batched / persisted / multipart / `application/graphql` request. Those
    # shapes render but do not round-trip (`Graphql::Op#editable?`), so there is nothing to
    # splice: send the envelope the operator sees, byte for byte. The controller already
    # declines to open them split; this is the second gate, because `refresh_decoded` can
    # move a tab into one of those shapes mid-edit and a re-encode from a projection is a
    # request the operator never wrote.
    case @graphql_location
    when :none # see above
      env
    when :query # GET: rewrite the request-line query (no body), like SAML Redirect
      lines = env.split('\n')
      lines[0] = graphql_query_line(lines[0], @decoded.text) if lines[0]?
      lines.join('\n')
    when :form_body
      # A `query=…&variables=…` urlencoded body: the same grammar as the GET binding, so it
      # is rewritten in the same way — NOT recomposed as JSON, which would leave a JSON body
      # under a Content-Type still declaring urlencoded.
      sep = env.index("\n\n") || return env
      "#{env[0, sep]}\n\n#{Graphql.recompose_form(env[(sep + 2)..], @decoded.text)}"
    else # POST: recompose the JSON body, preserving other fields
      sep = env.index("\n\n") || return env
      "#{env[0, sep]}\n\n#{Graphql.recompose(env[(sep + 2)..], @decoded.text)}"
    end
  end

  # Rewrite a request line's query with the edited GraphQL op re-encoded (GET binding),
  # reading the original query from the line itself — mirrors saml_query_line.
  private def graphql_query_line(rl : String, decoded_text : String) : String
    sp1 = rl.index(' ')
    sp2 = rl.rindex(' ')
    return rl unless sp1 && sp2 && sp2 > sp1
    target = rl[(sp1 + 1)...sp2]
    qidx = target.index('?')
    path = qidx ? target[0, qidx] : target
    query = Graphql.recompose_query(qidx ? target[(qidx + 1)..] : "", decoded_text)
    "#{rl[0, sp1]} #{path}?#{query} #{rl[(sp2 + 1)..]}"
  end

  # Rewrite the Content-Length header (if present) to the envelope body's byte size —
  # the LF-joined body has no embedded newlines (form/JSON), so it matches the wire.
  private def sync_cl_text(env : String) : String
    sep = env.index("\n\n") || return env
    body = env[(sep + 2)..]
    lines = env[0, sep].split('\n')
    idx = lines.index(&.lstrip.downcase.starts_with?("content-length:")) || return env
    lines[idx] = "Content-Length: #{body.bytesize}"
    "#{lines.join('\n')}\n\n#{body}"
  end

  # The replayable bytes for a split-decode tab: commit any pending decoded edit into
  # the envelope, then send the envelope (the authoritative request) with CL synced.
  private def decoded_request_bytes : Bytes
    commit_decoded
    finalize_wire(expanded_editor_bytes)
  end

  # The request HEAD as origin-form text (request line rewritten, headers), WITHOUT
  # a trailing blank line — the *_request_bytes builders re-add the head terminator.
  private def origin_head_text(detail : Store::FlowDetail) : String
    lines = String.new(detail.request_head).split('\n').map(&.rstrip('\r'))
    return "" if lines.empty?
    parts = lines[0].split(' ')
    if parts.size == 3 && (parts[1].starts_with?("http://") || parts[1].starts_with?("https://"))
      lines[0] = "#{parts[0]} #{to_origin(parts[1])} #{parts[2]}"
    end
    while !lines.empty? && lines.last.empty?
      lines.pop
    end
    lines.join('\n')
  end
end
