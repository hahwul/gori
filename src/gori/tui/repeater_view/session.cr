# Session lifecycle: the accessors the Runner persists/reconciles a saved repeater by, and
# every way a tab is filled — `load` (a captured HTTP flow), `restore` (a saved row),
# `apply_peer_request` (cross-process sync), `load_blank` (^N) and `duplicate_from` (^D).
# Reopens Gori::Tui::RepeaterView (see tui/repeater_view.cr).
class Gori::Tui::RepeaterView
  # --- persistence accessors (the Runner saves these + reconciles by them) ---
  # What gets PERSISTED (and what reconcile compares against). Wire form, so a saved tab
  # restores to the bytes it was sending: persisting the LF projection would have re-lost
  # every body CR on the next restore, undoing the fix one session later.
  def request_text : String
    (h = @req_hex_edit) ? String.new(h.to_bytes) : @editor.wire_text
  end

  # The same request handed to a tab that reads `§…§` as TEMPLATE SYNTAX — `space ▸ f`
  # (Send to Fuzzer). Where this tab's markers are inert (a capture whose body legitimately
  # carries `§`; see `markers_live?`), the literal `§` are escaped to `§§` — the escape
  # `Fuzz::Template.parse` already defines — so the receiving template renders them back to
  # one `§` on the wire instead of turning the site's own text into an injection position
  # the operator never marked. Byte-identical to `request_text` in every other case, which
  # is every request without a `§` in it.
  #
  # Done over BYTES, not `String#gsub`: this request is a capture, so its body may hold
  # genuinely invalid UTF-8 (round 4's T1), and every String rebuild that walks chars
  # rewrites those bytes to U+FFFD — measured, on this very fixture, turning
  # `ff fe 01 02` into `ef bf bd ef bf bd 01 02` and inflating Content-Length with it.
  # The escape itself is `Fuzz::Template.escape_literal_markers`, not a second copy of the
  # loop: the OTHER road into a fuzz template — `FuzzerView#load`, ⇧I from History — escapes
  # at its own seam with that helper, and two spellings of one rule is the drift this branch
  # spent three round-trips removing for the `%%%` separator. Only the PROVENANCE question
  # (`markers_live?`) is ours; the byte rule belongs to the template.
  #
  # Each road escapes exactly once: `space ▸ f` goes runner/fuzzer.cr → here →
  # `FuzzerView#load_request`, which sets the text unescaped, so a captured `§` is never
  # doubled.
  # The `marker_bytes_in?` guard is LOAD-BEARING, not a redundant pre-check.
  # `escape_literal_markers` returns `raw` itself when there is no `§`, but `String.new(Bytes)`
  # always copies — so collapsing this to one line would copy the whole request buffer on
  # every marker-free `space ▸ f`, which is the overwhelmingly common seed and exactly the
  # allocation the helper's own comment says it avoids.
  def fuzz_seed_text : String
    text = request_text
    src = text.to_slice
    return text if markers_live? || !Fuzz::Template.marker_bytes_in?(src)
    String.new(Fuzz::Template.escape_literal_markers(src))
  end

  # The buffer the external editor (^E) round-trips: the ACTIVE request sub-pane — the
  # envelope, or the decoded payload when it's the split's active pane (so you can edit
  # a big SAML XML / GraphQL query in $EDITOR). Non-decode tabs = the envelope, as before.
  #
  # `wire_text`, NOT `text` — the same distinction `request_text` above draws, and for the
  # same reason. Handing `$EDITOR` the LF projection meant a captured request came back
  # from a round trip with every CRLF in its BODY replaced by a bare LF, and auto-CL then
  # resynced `Content-Length` down to the shortened body, so nothing errored and the
  # smuggled `0\r\n\r\nGET /smuggled …` payload the operator was testing simply stopped
  # being a payload. `set_text` (in `replace_edit_buffer`) is the exact inverse, so a file
  # the editor left alone round-trips byte for byte.
  def edit_buffer_text : String
    (h = @req_hex_edit) ? String.new(h.to_bytes) : req_editor.wire_text
  end

  def replace_edit_buffer(text : String) : Nil
    req_editor.set_text(text)
    mark_req_edit
  end

  # A short, human label for this repeater — "METHOD /path" from the request line,
  # truncated to `max`. Used by the sub-tab strip, the open toast, and the close
  # prompt: far more recognizable than the source flow's internal numeric id, and
  # it tracks live as the request is edited.
  def summary(max : Int32 = 28) : String
    line = (@editor.first_nonblank_line || "").strip
    parts = line.split(' ')
    s = "#{parts[0]?} #{parts[1]?}".strip # METHOD + request-target (drop the HTTP/x.y)
    s = line if s.empty?
    return "new" if s.empty?
    s.size > max ? "#{s[0, max - 1]}…" : s
  end

  # The sub-tab chip label: the custom name if set (non-blank), else the
  # request-derived summary. Truncated to `max` either way.
  def label(max : Int32 = 18) : String
    if (n = @name) && !(t = n.strip).empty?
      t.size > max ? "#{t[0, max - 1]}…" : t
    else
      summary(max)
    end
  end

  # A compact ` #tag #tag` suffix for the sub-tab chip, fit within `budget` columns
  # (leading space included, trailing `…` when it overflows). Empty when untagged.
  def tags_label(budget : Int32 = 12) : String
    return "" if @tags.empty? || budget <= 2
    s = @tags.map { |t| "##{t}" }.join(' ')
    s = "#{s[0, budget - 2]}…" if s.size > budget - 1
    " #{s}"
  end

  # The leading METHOD token of the request line (for the sub-tab filter's `method:`).
  def request_method : String
    (@editor.first_nonblank_line || "").strip.split(' ').first? || ""
  end

  # Replace the request body (e.g. from the external editor); marks dirty so the
  # tab persists + the cross-session reconcile won't clobber it.
  def replace_request(text : String) : Nil
    @editor.set_text(text)
    @dirty = true
    reflect_content_length_in_editor
  end

  # The source History flow id for a ^R-opened tab (nil for a hand-authored ^N).
  def source_flow_id : Int64?
    @flow.try(&.row.id)
  end

  def mark_dirty : Nil
    @dirty = true
  end

  def clear_dirty : Nil
    @dirty = false
    @decoded_dirty = false
  end

  # The starting scaffold for a hand-authored request (Repeater `^N`): a minimal
  # but immediately sendable HTTP/1.1 message the user edits in place.
  BLANK_TARGET  = "https://example.com"
  BLANK_REQUEST = "GET / HTTP/1.1\nHost: example.com\nUser-Agent: gori\nAccept: */*\n\n"

  def load(detail : Store::FlowDetail) : Nil
    @flow = detail
    @evidence = true          # a CAPTURED request — see `evidence?`
    @markers_declared = false # a fresh capture: any § in it is the origin's (see markers_live?)
    @http2 = detail.http_version == "HTTP/2"
    @target = build_target(detail.row.scheme, detail.row.host, detail.row.port)
    @tcx = @target.size
    @sni = ""
    @scx = 0
    @target_field = :url
    @editor.set_text(origin_form_text(detail))
    seed_draft_baselines
    @original_lines = message_lines(detail.response_head, display_body(detail.response_head, detail.response_body))

    @result = nil
    @prev_result = nil
    reset_result_caches
    @focus = :request
    @resp_mode = :response
    @scroll = 0
    resp_wrap_reset
    @diffable = true
    @loaded = true
    @dirty = false
    @req_hex_edit = nil # a fresh load/restore replaces the request → drop any hex buffer
    @scroll_req = 0
    reflect_content_length_in_editor if @auto_content_length
  end

  # Re-open a persisted tab (from the `repeaters` table) without a live FlowDetail.
  # Seeds the editable request + target + flags, and (V11) the LAST send response
  # when one was persisted — so a reopened tab shows it instead of "— not sent —".
  # Non-diffable on its own; a ^R-from-History tab regains its captured-original
  # diff baseline via a follow-up seed_original (the Runner re-fetches it from the
  # persisted flow_id). Clears @dirty so a synced/restored tab is never re-saved by
  # us — that would echo back to the peer.
  #
  # Project-open / brand-new-tab only. Live cross-session request sync must use
  # `apply_peer_request` — full restore resets focus to :target and drops the
  # in-memory response (response BLOBs are intentionally not on the reconcile poll).
  def restore(target : String, request : String, http2 : Bool, auto_cl : Bool,
              response_head : Bytes? = nil, response_body : Bytes? = nil,
              response_error : String? = nil, response_duration_us : Int64? = nil,
              sni : String = "",
              ws_messages : Array(Store::WsOutMessage)? = nil,
              ws_keep_key : Bool = false,
              ws_http_only : Bool = false,
              evidence : Bool = false) : Nil
    @flow = nil
    # `@flow` is deliberately cleared on a restore (the FlowDetail is not persisted), so
    # provenance has to arrive from the caller: the store row's `flow_id`, which is the
    # same carrier `FuzzerView`/`MinerView` restore from. Without it a reopened capture
    # silently reverted to a draft on the next gori start.
    @evidence = evidence
    # …and provenance is all that arrives: the row holds the request TEXT and the flow id,
    # nothing that says which `§` in it the operator typed. Undeclared is the answer gori
    # can defend — see `markers_live?`. (A marked-up capture reopens with its markers inert
    # and the border chip saying so; ^T re-declares.)
    @markers_declared = false
    apply_request_fields(target, request, http2, auto_cl, sni, ws_messages, ws_keep_key, ws_http_only)

    @original_lines = [] of String
    # Rebuild the persisted result: a head (success) or an error (failed send)
    # marks a real stored response; both nil → never sent → empty pane.
    @result =
      if response_head || response_error
        Repeater::Result.new(response_head || Bytes.empty, response_body, nil,
          response_duration_us || 0_i64, response_error)
      end
    @prev_result = nil
    reset_result_caches
    @focus = :target
    @resp_mode = :response
    @scroll = 0
    resp_wrap_reset
    @diffable = false
    @req_hex_edit = nil # a fresh load/restore replaces the request → drop any hex buffer
    @scroll_req = 0
    reflect_content_length_in_editor if @auto_content_length
  end

  # Live request-side sync (reconcile poll). Updates target/request/flags from the
  # shared row WITHOUT wiping the session-local response, focus, scroll, or resp
  # mode. Full restore() was wrong here: it always set focus=:target and cleared
  # @result (reconcile never carries response BLOBs), so a post-send data_version
  # bump or a peer request edit looked like "send reset the response to Target".
  def apply_peer_request(target : String, request : String, http2 : Bool, auto_cl : Bool,
                         sni : String = "",
                         ws_messages : Array(Store::WsOutMessage)? = nil,
                         ws_keep_key : Bool = false,
                         ws_http_only : Bool = false,
                         evidence : Bool = false) : Nil
    @evidence = evidence
    # A peer's row carries the same two facts a restore does, so the same answer: see restore.
    @markers_declared = false
    apply_request_fields(target, request, http2, auto_cl, sni, ws_messages, ws_keep_key, ws_http_only)
    @req_hex_edit = nil
    # Leave @result / @prev_result / @focus / @scroll / @resp_mode / @original_lines alone.
    reflect_content_length_in_editor if @auto_content_length
  end

  # True when the live view's request-side fields match a store row (reconcile skip).
  # Normalizes empty SNI: view.sni_override is nil when blank, but older/peer rows
  # may store "" — those must compare equal or every poll re-applies needlessly.
  # The request compare is now EXACT (`request_text` is wire form, `set_text`'s exact
  # inverse), so a store row holding wire CRLF — MCP create_repeater / import / a peer —
  # matches without normalizing anything away. That normalization existed because the
  # TextArea could only hold LF, which made the compare LF-vs-CRLF false on EVERY poll and
  # slammed the request caret back to the top of the pane on every capture tick. It also
  # made the compare blind to a pure line-ending difference, which is a real edit now.
  # (FuzzerView#session_side_matches? still normalizes — its template is a document, not
  # a captured message, and it is persisted from `#text`.)
  #
  # `ws_http_only` is compared for the same reason `ws_keep_key` is: it is a stored,
  # cross-session request-side field, so a peer's `^V` has to converge here. Leaving it out
  # meant the poll saw the row as unchanged and the override never crossed sessions.
  def request_side_matches?(target : String, request : String, http2 : Bool, auto_cl : Bool,
                            sni : String?, ws_keep_key : Bool = false,
                            ws_http_only : Bool = false) : Bool
    @target == target && request_text == request &&
      @http2 == http2 && @auto_content_length == auto_cl &&
      @ws_keep_key == ws_keep_key && @ws_http_only == ws_http_only &&
      (sni_override || "") == (sni || "")
  end

  # Shared request/target/flag write used by restore (full) and apply_peer_request (soft).
  private def apply_request_fields(target : String, request : String, http2 : Bool, auto_cl : Bool,
                                   sni : String,
                                   ws_messages : Array(Store::WsOutMessage)?,
                                   ws_keep_key : Bool = false,
                                   ws_http_only : Bool = false) : Nil
    @ws_keep_key = ws_keep_key
    @http2 = http2
    @target = target
    @tcx = @target.size
    @sni = sni
    @scx = @sni.size
    @target_field = :url

    is_ws = !ws_messages.nil? || Repeater::WsEngine.upgrade_request?(request)
    # The stored override only means anything on a tab that HOLDS a handshake; a row that
    # carries it without one (a request edited out of upgrade shape by a peer) reads as the
    # plain HTTP tab it now is, rather than a tab claiming to override a mode it isn't in.
    @ws_http_only = is_ws && ws_http_only
    if is_ws
      @ws_mode = true
      @ws_upgrade = request.to_slice
      # Only rewrite the editor when the text ACTUALLY changed: set_text resets the caret
      # + scroll and clears the undo stack, so a soft reconcile poll (apply_peer_request)
      # that only touched a non-text field must not disturb the pane. `wire_text` is
      # set_text's exact inverse, so this is the precise "would set_text be a no-op?" test —
      # no normalization, and a line-ending-only difference is honoured as the edit it is.
      # (Normalizing here would compare unequal on EVERY poll once the store round-trips
      # wire form exactly, and slam the caret.)
      @editor.set_text(request) if @editor.wire_text != request
      seed_ws_out(ws_messages || [] of Store::WsOutMessage)
      # The MESSAGES card is the one the operator wants on a WS tab — but it is not DRAWN
      # under the override (`req_split?` is false there), so parking the active sub-pane on
      # it would leave the request column focused on a card that does not exist.
      @req_pane = ws_mode? ? :decoded : :envelope
    else
      @ws_mode = false
      @editor.set_text(request) if @editor.wire_text != request
    end

    @auto_content_length = auto_cl
    seed_draft_baselines
    @loaded = true
    @dirty = false
  end

  # Re-seed the captured-original diff baseline for a ^R-from-History tab that was
  # reopened/synced via restore() (which is non-diffable on its own). The source
  # flow's response lives in `flows`; the Runner re-fetches it by the persisted
  # flow_id and hands the bytes here, mirroring what load() sets. No-op when the
  # source flow captured no response (nothing to diff against).
  def seed_original(head : Bytes?, body : Bytes?) : Nil
    return unless head
    @original_lines = message_lines(head, display_body(head, body))
    @diffable = true
    @diff_lines_cache = nil # the baseline changed → drop any memoized diff
  end

  # Open a hand-authored request not tied to any captured flow (Repeater `^N`).
  # Seeds the editable scaffold so the user can immediately tweak and send;
  # there is no original response, so the result stays in plain response mode
  # rather than diffing against nothing. Focus starts on the target field — the
  # scaffold URL is a placeholder you almost always change first.
  def load_blank : Nil
    @flow = nil
    @evidence = false         # ^N: a draft the operator is about to type
    @markers_declared = false # moot on a draft (markers_live? is true either way) — kept in lockstep
    @http2 = false
    @target = BLANK_TARGET
    @link_host_to_target = true # first target edit mirrors into the Host header (see the field)
    @tcx = @target.size
    @sni = ""
    @scx = 0
    @target_field = :url
    @editor.set_text(BLANK_REQUEST)
    @evidence_pipeline_seps = 0 # a draft: every `%%%` in it is the operator's
    @original_lines = [] of String
    @result = nil
    @prev_result = nil
    reset_result_caches
    @focus = :target
    @resp_mode = :response
    @scroll = 0
    resp_wrap_reset
    @diffable = false
    @loaded = true
    @dirty = false
    @req_hex_edit = nil # a fresh load/restore replaces the request → drop any hex buffer
    @scroll_req = 0
  end

  # Content-only clone for the sub-tab strip "Duplicate" action. Copies the editable
  # request (all modes: HTTP / WS / gRPC / SAML / GraphQL), flags, last response, and
  # chip name (+ " copy"). Drops source flow linkage, inflight state, and scroll/cursor.
  def duplicate_from(src : RepeaterView) : Nil
    @flow = nil
    @evidence = src.evidence?                             # the same bytes carry the same provenance
    @markers_declared = src.@markers_declared             # …and the same reading of their §
    @evidence_pipeline_seps = src.@evidence_pipeline_seps # …and of their `%%%`
    @evidence_env_names = src.@evidence_env_names.dup     # …and of their `$NAME`
    @http2 = src.@http2
    @target = src.@target
    @tcx = @target.size
    @sni = src.@sni
    @scx = @sni.size
    @target_field = :url
    @auto_content_length = src.@auto_content_length
    @ws_keep_key = src.@ws_keep_key
    @name = SubtabClone.copy_name(src.@name)

    @ws_mode = src.@ws_mode
    @ws_http_only = src.@ws_http_only # a duplicate opens on the transport its source is on
    @ws_upgrade = src.@ws_upgrade.try(&.dup)
    @ws_result = nil
    @ws_lines_cache = nil

    @grpc_mode = src.@grpc_mode
    @grpc_body = src.@grpc_body.dup
    @grpc_msg_count = src.@grpc_msg_count
    @grpc_reframable = src.@grpc_reframable
    @grpc_reframe = src.@grpc_reframe # a send knob, so the clone sends what the source would
    @grpc_compressed = src.@grpc_compressed
    @grpc_payload = src.@grpc_payload.dup # carry any hex-edited payload into the clone
    @grpc_lines_cache = nil

    @decode_kind = src.@decode_kind
    @saml_param = src.@saml_param
    @saml_binding = src.@saml_binding
    @saml_location = src.@saml_location
    @graphql_location = src.@graphql_location
    @req_pane = src.@req_pane
    @decoded.set_text(src.@decoded.text)
    @decoded_dirty = src.@decoded_dirty
    @ws_out_seed = src.@ws_out_seed
    @ws_out_edited = src.@ws_out_edited

    # Hex-mode buffer is authoritative while set — snapshot it into the text editor
    # so the clone is plain text (no shared hex cursor state).
    @editor.set_text(src.request_text)
    @req_hex_edit = nil
    @scroll_req = 0

    if res = src.@result
      @result = Repeater::Result.new(
        res.head.dup, res.body.try(&.dup), res.response,
        res.duration_us, res.error, res.incomplete?)
    else
      @result = nil
    end
    @prev_result = nil
    @original_lines = [] of String
    @diffable = false
    reset_result_caches

    @focus = :request
    @resp_mode = :response
    @scroll = 0
    resp_wrap_reset
    @loaded = true
    @dirty = true
    @inflight = false
    @chain_focused = false
    @chain_marker_cursor = 0
    @request_mode = InputMode::Read
    @target_mode = InputMode::Read
  end
end
