require "uri"
require "./screen"
require "./theme"
require "./frame"
require "./traffic_empty_state"
require "./highlight"
require "../env"
require "./hex_view"
require "./hex_edit"
require "./text_area"
require "./wrap"
require "./gutter"
require "./search_hi"
require "./reveal"
require "./fmt"
require "../store"
require "../proxy/h2/grpc"
require "../repeater/engine"
require "../repeater/h2_engine"
require "../repeater/ws_engine"
require "../repeater/diff"
require "../repeater/flow_request"
require "../repeater/minimize" # PIPELINE_SEP aliases Minimize::GROUP_SEP
require "../repeater/subtab_filter"
require "../fuzz"
require "../decoder"
require "./chain_pane"
require "./chain_overlay"
require "./input_mode"
require "./read_cursor"
require "./text_read_state"
require "./line_field_read"
require "./subtab_clone"

module Gori::Tui
  # The Repeater workbench (a tab). Layout: a target URL field on top, then a split
  # of REQUEST (inline editor, origin-form) | RESPONSE (toggles to DIFF). Request
  # and target default to READ (space cmds, select/copy); i/↵ enters INS. Tab
  # cycles focus (target → request → response); Ctrl-R resends byte-exact.
  class RepeaterView
    getter? loaded : Bool
    getter? http2 : Bool
    getter focus : Symbol  # :request | :response | :target
    getter target : String # the raw target URL (persistence + cross-session sync)
    # unsaved local edits — gates persistence + protects the tab from sync clobber
    @dirty : Bool = false
    # One-shot, armed only by load_blank (a fresh ^N tab). The first time the user edits the
    # target away from the placeholder, the Host header is mirrored to the new host so they
    # don't have to edit both; cleared after that first sync (and never armed for tabs loaded
    # from a captured flow / saved repeater), so a hand-set Host is never clobbered.
    @link_host_to_target : Bool = false

    def dirty? : Bool
      @dirty || (@ws_mode && @decoded_dirty)
    end

    property name : String? # custom sub-tab chip label (nil = derive from the request); set separately from restore()
    # Flat multi-label tags (V31) for organizing/filtering the sub-tab strip. Set
    # separately from restore() — like @name, the reconcile clobber never touches it.
    property tags : Array(String) = [] of String

    # PROVENANCE: this tab's request came from a CAPTURED flow (^R off History, the Sitemap,
    # an Issue, a reopened flow-seeded session), not from `^N` or a hand-typed draft. Feeds
    # `Repeater::PlanOptions#evidence?` and gates the editor's own `$KEY` expansion — see
    # `expanded_text_to_bytes`.
    #
    # The Fuzzer/Miner/Sequencer tabs got this in round 4's first half and the Repeater, the
    # tab a capture lands in FIRST, did not: `repeater_plan` passed `expand_request: false`
    # while the view had already run `Env.expand_wire` over the same bytes, so a project that
    # happens to define `filter`/`top` sent `GET /api?PWNED=name&99=10` from a pane still
    # reading `GET /api?$filter=name&$top=10`, for a flow `gori run repeater 1` replayed
    # byte-exact in the same project. An operator edit does NOT clear it, the same call
    # `FuzzerView#evidence_template` documents: provenance is about where the bytes came
    # from, and dropping it on the first keystroke puts the substitution straight back on
    # the commonest workflow there is.
    getter? evidence : Bool

    def initialize
      @name = nil
      @tags = [] of String
      @evidence = false
      @flow = nil.as(Store::FlowDetail?)
      @target = ""
      @tcx = 0             # target (URL) cursor
      @sni = ""            # custom TLS SNI host ("" = present the target host)
      @scx = 0             # SNI cursor
      @target_field = :url # which field the TARGET pane edits: :url | :sni
      @editor = TextArea.new
      @editor.gutter = true # line numbers in the request body (pairs with ^G)
      # Soft wrap, Burp-style: a long header / URL / minified body spills onto continuation
      # rows instead of running off the right edge, and the line number stays on the first
      # of them. Replaces the old ⇧←/→ horizontal scroll outright — a request pane you have
      # to pan sideways to read is a request pane you misread.
      @editor.wrap = true
      @editor.env_complete = true # `$KEY` autocomplete against the registered env vars (expanded on send)
      @editor.chain_peek = true   # tooltip revealing the concealed ¦chain of the §…§ marker under the caret
      @search_hl = ""             # active ^F query → highlight in the response pane (request is via @editor)
      @reveal = false             # 'w' shows whitespace/CR/LF as glyphs (response from raw bytes, request via @editor)
      @reveal_lines = nil.as(Array(String)?)
      @reveal_lines_src = Pointer(UInt8).null
      @original_lines = [] of String
      @result = nil.as(Repeater::Result?)
      @prev_result = nil.as(Repeater::Result?) # the previous send's result — the diff baseline
      # Per-result render caches (rebuilt only when @result/@prev_result change, not
      # every frame): the windowed response view (head styled + body kept RAW and
      # styled per visible line, so a multi-MiB replayed response doesn't freeze),
      # and the LCS diff lines.
      @resp_view_cache = nil.as(RespView?)
      @resp_view_rev = Theme.revision # the theme the cached (colour-baked) response head was built under
      # Per-visible-line styled BODY memo (keyed by absolute line index). RespView keeps the
      # body RAW and styles each visible line lazily so a multi-MiB response opens instantly —
      # but render() fires on EVERY input event (a keystroke in the request editor, a 1-line
      # scroll), re-styling the whole visible response window each time even when the response
      # didn't change. Memoize so an unchanged response pane re-renders for free. Bounded
      # (RESP_STYLED_CACHE_CAP) so scrolling a huge body can't materialise every line — the very
      # property RespView's laziness exists to protect. Dropped in lockstep with @resp_view_cache.
      @resp_styled_cache = {} of Int32 => Highlight::Line
      @diff_lines_cache = nil.as(Array(Repeater::DiffLine)?)
      @resp_hex = false                        # 'x' toggles a raw hex dump of the response bytes
      @resp_hex_bytes = nil.as(Bytes?)         # cached combined head+body of the last result (hex source)
      @pretty = Settings.pretty_bodies_default # 'p' pretty-prints the response body (display only); pushed from the runner
      @resp_pretty_applied = false             # whether Pretty actually reflowed the current response (drives the chip)
      @req_hex_edit = nil.as(HexEdit?)         # ^X: editable byte buffer for the REQUEST (authoritative while set)
      @scroll_req = 0                          # scroll offset for the hex request editor
      @focus = :request
      @resp_mode = :response # :response | :diff
      @scroll = 0
      # THE response-pane scroll anchor: the top drawn row is visual row @scroll_sub of
      # logical row @scroll. Replaces the horizontal offset this pane used to carry —
      # response, diff, reveal and transcript all soft-wrap now, so there is nothing off to
      # the side to scroll to. A (row, sub-row) pair rather than a flat visual index for the
      # reason spelled out in Wrap: a flat index can only be produced by wrapping the whole
      # response, and a response is routinely multiple MB.
      @scroll_sub = 0
      @resp_wrap = {} of Int32 => Wrap::Layout # per-row wrap memo, keyed by the width below
      @resp_wrap_w = -1
      # Gutter + content width from the LAST render of whichever response pane is active.
      # Hit-testing and the scroll walkers read these rather than re-deriving them, because
      # the per-mode line counts the gutter is sized from are not all the same
      # (`resp_line_count` has no group-transcript branch, for one) and the wrap memo is
      # KEYED on the content width — a click that recomputed a different width would not
      # merely land a column off, it would flush and rebuild the memo at a width the anchor
      # was never laid out against.
      @resp_last_gw = 0
      @resp_last_cw = 0
      @loaded = false
      @http2 = false
      # WebSocket repeater mode (a 101 flow): the request editor holds the editable
      # outbound MESSAGES (one per line) and the response pane shows the TRANSCRIPT.
      # Session-only — these tabs are never persisted/synced (db_id stays nil).
      @ws_mode = false
      @ws_upgrade = nil.as(Bytes?) # the captured upgrade-request bytes (handshake source)
      @ws_result = nil.as(Repeater::WsEngine::Result?)
      @ws_lines_cache = nil.as(Array({String, Color})?)
      @transcript_rev = Theme.revision # theme the colour-baked transcript cache was built under
      # gRPC repeater mode (an application/grpc h2 flow): the editor holds the editable
      # request HEAD (metadata headers) and the framed message body is sent byte-exact
      # from @grpc_body; the response pane shows a deframed gRPC transcript + status.
      # Session-only like WS (db_id nil) — the binary body can't round-trip the text store.
      @grpc_mode = false
      @grpc_body = Bytes.empty # the pristine framed request message(s), sent verbatim
      @grpc_msg_count = 0      # deframed message count of @grpc_body (immutable → computed once)
      @grpc_req_residual = 0   # …and the tail of @grpc_body that is NOT a complete frame
      # A SINGLE-message gRPC call (the unary common case) is reframable: its payload is
      # hex-editable (^X) and the 5-byte length prefix is recomputed on send. A 0- or
      # multi-message body isn't (boundaries are prefix-defined) — it stays verbatim.
      @grpc_reframable = false
      @grpc_compressed = false    # the editable message's compressed flag (preserved on reframe)
      @grpc_payload = Bytes.empty # the current (possibly hex-edited) single-message payload
      @grpc_lines_cache = nil.as(Array({String, Color})?)
      # "Send group" mode (space → g): the editor holds several requests separated by a lone
      # `%%%` line; a group send pipelines them on ONE keep-alive connection (active smuggling
      # / keep-alive-reuse), and the response pane shows a TRANSCRIPT of every response. Set
      # only while a group result is displayed; a normal ^R send clears it. {label, result}.
      @group_results = nil.as(Array({String, Repeater::Result})?)
      @group_lines_cache = nil.as(Array({String, Color})?)
      # Split-decode repeater mode (a flow carrying an encoded payload — SAML or GraphQL):
      # the SPLIT REQUEST column shows the full request envelope (@editor — headers,
      # target, other params: all editable) on top and the DECODED payload (@decoded —
      # SAML XML / GraphQL query+variables) below. ^T toggles which sub-pane is active
      # (the active one is enlarged). On send the decoded payload, IF edited, is
      # re-encoded back into the envelope (SAML param / GraphQL JSON body) with
      # Content-Length resynced; otherwise the envelope is sent as captured. Sent as a
      # NORMAL request (ordinary response pane). Session-only (db_id nil) like WS/gRPC.
      @decode_kind = nil.as(Symbol?) # nil | :saml | :graphql
      @decoded = TextArea.new        # the payload editor (lower split)
      @decoded.gutter = true
      @decoded.wrap = true         # long decoded payload lines (SAML XML, GraphQL query) wrap, like the envelope
      @decoded.env_complete = true # env tokens re-encode into the request on send here too (WS messages, decoded payload)
      @req_pane = :envelope        # :envelope | :decoded — which split sub-pane is active
      @decoded_dirty = false       # the decoded payload was edited → re-encode on send
      # The WS session's outbound messages EXACTLY as they were loaded, opcodes and raw
      # bytes, plus whether the pane has been touched since. The pane is a text projection —
      # one message per line, LF-split — so it cannot represent a binary frame or a TEXT
      # frame carrying invalid UTF-8. Sending the projection back was how a captured binary
      # message became an opcode-1 text one on every save. So: untouched pane → the seed
      # goes out (and is persisted) verbatim; edited pane → what the operator typed, as
      # text. Same rule the WS relay keeps — gori's own framing only for what was changed.
      @ws_out_seed = [] of Store::WsOutMessage
      @ws_out_edited = false
      # Send the handshake's own `Sec-WebSocket-Key` instead of a fresh one. Off, which is
      # what this tab has always done — regenerating avoids a server's replay guard. On, the
      # operator's header block goes out exactly as typed, key line and position included,
      # which is the only way to ask what a server does with an absent, short, duplicated or
      # non-base64 key. See `WsEngine.build_handshake`.
      @ws_keep_key = false
      @saml_param = "SAMLResponse"
      @saml_binding = :post       # :post (base64) | :redirect (deflate+base64)
      @saml_location = :body      # :body (form) | :query (request line)
      @graphql_location = :body   # :body (POST JSON) | :query (GET ?query=) — where the op lives
      @inflight = false           # a repeater round-trip is outstanding — gates re-send (^R mashing)
      @diffable = false           # true only when loaded from a captured flow (has an original to diff)
      @auto_content_length = true # recompute Content-Length from the edited body on send
      # `§…§` markers carry inline Decoder chains applied on send (mark a value, attach
      # base64-encode → it's encoded on the wire). On a DRAFT they are always active (like the
      # Fuzzer): a request that contains a marker region renders it on send, a marker-free
      # request is byte-identical to a plain send. Highlighting + the CHAIN pane surface
      # contextually — no mode. On an EVIDENCE tab they are inert until declared, see
      # `@markers_declared` / `markers_live?`.
      @markers_declared = false
      # The `%%%` twin of `@markers_declared`, and deliberately NOT the same flag: `§` and
      # `%%%` are different syntaxes an operator types independently, so sharing one would
      # both over-declare (mark a word → the capture's own `%%%` starts splitting the send)
      # and under-declare. This one counts instead of latching because `%%%` has no marking
      # verb to latch on — see `pipeline_live?`. Baseline = the separators the CAPTURE
      # arrived with; 0 on a draft, where every `%%%` is the operator's by definition.
      @evidence_pipeline_seps = 0
      @marker_regions_rev = -1
      @marker_regions_cache = [] of {Int32, Int32, Int32}
      # §…§ spans + the chain under the cursor, cached on the editor revision (marked_spans)
      # and on {revision, cursor} (chain_at) — both re-join the whole buffer, so an unchanged
      # request/CHAIN pane shouldn't recompute them every frame (mirrors marker_regions).
      @marker_spans_rev = -1
      @marker_spans_cache = [] of {Int32, Int32}
      @chain_rev = -1
      @chain_cursor = -1
      @chain_cache = nil.as(String?)
      # The CHAIN sub-pane: a visible editor for the chain of the §…§ marker under the
      # request cursor, split in only while the cursor is in a marker. @chain_focused =
      # editing it (split enlarges + keys route there); @chain_marker_cursor remembers which
      # marker to write back to on commit.
      @chain_pane = ChainPane.new
      @chain_focused = false
      @chain_marker_cursor = 0
      @dirty = false # set by every editor/target/flag mutator, cleared on save/restore
      @request_mode = InputMode::Read
      @target_mode = InputMode::Read
      @resp_cursor = ReadCursor.new
      @req_read = TextReadState.new
      @target_read = LineFieldRead.new
      @resp_last_h = 0 # viewport height from last response render (wheel clamp)
    end

    # --- hex edit (^X on the REQUEST pane) ---
    # While @req_hex_edit is set, the byte buffer is AUTHORITATIVE (the TextArea is
    # frozen/stale) — every request consumer reads it. Lossiness lives only at the
    # text boundary (enter snapshot, exit write-back, persist), documented in-UI.
    def request_hex? : Bool
      !@req_hex_edit.nil?
    end

    def toggle_request_hex : Bool
      # A gRPC tab only exposes hex for a reframable (unary) payload; a 0-/multi-message
      # body has nothing to edit, so entering hex is a no-op (the controller also guards
      # this, but keep the view self-consistent for any caller).
      return false if @grpc_mode && !@grpc_reframable && !@req_hex_edit
      @req_hex_edit ? exit_request_hex : enter_request_hex
      request_hex?
    end

    private def enter_request_hex : Nil
      # In gRPC mode the hex buffer edits the deframed message PAYLOAD (the head stays in
      # @editor, sent as text); grpc_request_bytes re-length-prefixes it on send. Otherwise
      # it snapshots the whole wire request.
      #
      # `wire_bytes`, NOT `to_bytes`. `to_bytes` re-joins the LF projection with CRLF, so the
      # "raw bytes" pane was a FABRICATION: it invented an 0x0D in front of every bare LF in
      # the body and showed the operator bytes that had never existed anywhere. Worse, hex
      # mode deliberately disables auto-Content-Length, so those invented bytes shipped under
      # the head's older, shorter CL and the remainder was left on the socket for the origin
      # to read as the front of the next request — gori desyncing its own connection while
      # reporting `✓ sent`. Hex mode is the documented byte-exact escape hatch; it has to
      # start from the bytes.
      @req_hex_edit = HexEdit.new(@grpc_mode ? @grpc_payload : @editor.wire_bytes)
      @scroll_req = 0 # entering the same bytes isn't an edit — no @dirty
    end

    private def exit_request_hex : Nil
      if (h = @req_hex_edit) && h.mutated? # a pure peek (no edits) leaves state + @dirty untouched
        if @grpc_mode
          @grpc_payload = h.to_bytes # keep the edited payload byte-exact (reframed on send)
        else
          # Round-trips byte-exactly now: set_text keeps each line's terminator in @eols, and
          # `String.new(Bytes)` does not scrub, so the hex buffer's bytes come back out of
          # `wire_bytes` unchanged — hex ⇄ text is no longer a one-way door.
          @editor.set_text(String.new(h.to_bytes))
        end
        @dirty = true # the edit is a content change
      end
      @req_hex_edit = nil
    end

    # Mutators delegated from the Runner's hex key handler (each marks @dirty only on
    # a real change, so save persists + the cross-session reconcile won't clobber).
    def hex_set_nibble(c : Char) : Nil
      return unless (h = @req_hex_edit) && (v = c.to_i?(16))
      @dirty = true if h.set_nibble(v)
    end

    def hex_move(dr : Int32, dc : Int32) : Nil # navigation does NOT dirty
      return unless h = @req_hex_edit
      if dr != 0
        h.move_rows(dr)
      elsif dc < 0
        h.move_left
      elsif dc > 0
        h.move_right
      end
    end

    def hex_home : Nil
      @req_hex_edit.try(&.home)
    end

    def hex_end : Nil
      @req_hex_edit.try(&.end_of_row)
    end

    def hex_insert : Nil
      @dirty = true if @req_hex_edit.try(&.insert_byte)
    end

    def hex_backspace : Nil
      @dirty = true if @req_hex_edit.try(&.backspace)
    end

    def hex_delete : Nil
      @dirty = true if @req_hex_edit.try(&.delete)
    end

    # --- READ / INS input modes (request + target panes) ---
    getter request_mode : InputMode
    getter target_mode : InputMode
    getter resp_cursor : ReadCursor

    def request_insert? : Bool
      @request_mode == InputMode::Insert
    end

    def target_insert? : Bool
      @target_mode == InputMode::Insert
    end

    def pane_insert?(pane : Symbol) : Bool
      case pane
      when :request then request_insert? || request_hex? || chain_pane_active?
      when :target  then target_insert? || editing_sni?
      else               false
      end
    end

    def enter_request_insert! : Nil
      @request_mode = InputMode::Insert
    end

    def exit_request_insert! : Nil
      @request_mode = InputMode::Read
      req_editor.env_complete_close # no dangling $ENV dropdown once we leave insert mode
      # Drop the INS selection with the mode that owns it. Its band is only painted while
      # `cursor` is on (INS), so leaving the anchor set hides it without clearing it — and
      # `esc` then `i` brought a band back that the operator had visually dismissed, over a
      # caret they had since moved.
      req_editor.clear_selection
    end

    # --- $ENV autocomplete in the request editor (delegates to the active req editor) ---
    # True while the request pane is a live text editor (insert mode, not hex) — the state
    # in which the $ENV dropdown and editor-style Tab apply (read by the controller too).
    def request_text_editing? : Bool
      @focus == :request && request_insert? && !request_hex?
    end

    def request_env_completing? : Bool
      request_text_editing? && req_editor.env_completing?
    end

    # The popup owns tab/↵/↑/↓/esc while open; accepting a key edits the buffer, so mirror
    # the dirty-marking edit_* helpers do. Returns true when the key was consumed.
    def handle_request_env_complete_key(ev : Termisu::Event::Key) : Bool
      return false unless request_text_editing?
      ed = req_editor
      before = ed.edits
      handled = ed.handle_env_complete_key(ev)
      mark_req_edit if handled && ed.edits != before
      handled
    end

    # Editor-style Tab: insert a literal tab into the request editor (no focus move).
    def request_tab_insert : Nil
      return unless request_text_editing?
      req_editor.insert('\t')
      req_editor.set_preedit("") # commit any preedit (termisu dup-guard)
      mark_req_edit
    end

    def enter_target_insert! : Nil
      @target_mode = InputMode::Insert
    end

    def exit_target_insert! : Nil
      @target_mode = InputMode::Read
      sync_host_to_target_once
    end

    def resp_navigable? : Bool
      @focus == :response && !@resp_hex
    end

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
      seed_pipeline_baseline
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

    getter? ws_mode : Bool

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
      @ws_keep_key = false # a fresh capture: the regenerated key is the default (see the ivar)
      @http2 = false       # WebSocket is HTTP/1.1
      @ws_upgrade = detail.request_head
      @ws_result = nil
      @ws_lines_cache = nil
      @target = build_target(detail.row.scheme, detail.row.host, detail.row.port)
      @tcx = @target.size
      @sni = ""
      @scx = 0
      @target_field = :url
      @editor.set_text(String.new(detail.request_head))
      seed_pipeline_baseline
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
      return @ws_keep_key unless @ws_mode
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
      j.field "ws_mode", @ws_mode
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
      resp_wrap_reset
      # Seed @result so the HTTP response tab can render the handshake response
      @result = Repeater::Result.new(result.handshake_head, Bytes.empty, nil, result.duration_us, result.error)
      reset_result_caches
    end

    getter? grpc_mode : Bool
    getter? grpc_reframable : Bool # a unary gRPC call whose payload is hex-editable + reframed
    getter grpc_msg_count : Int32  # deframed request-message count (gates/explains hex availability)

    # Load a captured gRPC flow (an application/grpc HTTP/2 call) for repeater. The request
    # HEAD is seeded into the editor (editable — metadata headers). protobuf is opaque
    # without a .proto, so the message body isn't text-editable — but a UNARY call (exactly
    # one framed message) exposes its payload for HEX editing (^X), with the 5-byte length
    # prefix recomputed on send (see grpc_request_bytes). A 0- or multi-message body is
    # kept byte-exact in @grpc_body and re-appended verbatim. The response renders as a
    # deframed gRPC transcript + grpc-status.
    def load_grpc(detail : Store::FlowDetail) : Nil
      @flow = detail
      @evidence = true
      @markers_declared = false
      @grpc_mode = true
      @ws_mode = false
      @http2 = true # gRPC is HTTP/2
      @grpc_body = detail.request_body || Bytes.empty
      # `scan`, not `messages`: the residual is the REQUEST side of the same report. A capture
      # whose length prefix over-claims used to count as "0 messages" and be described in the
      # transcript as `→ sent 0 request messages (10b)` — the byte count and the message count
      # disagreeing, with nothing saying why.
      msgs, @grpc_req_residual = Proxy::H2::Grpc.scan(@grpc_body)
      @grpc_msg_count = msgs.size
      # Reframable only when the body is EXACTLY one clean message: then a hex edit of the
      # payload can be re-length-prefixed unambiguously. (A partial trailing frame would
      # leave msgs shorter than the wire, so require the framing to be lossless too.)
      if msgs.size == 1 && Proxy::H2::Grpc.frame(msgs[0].compressed, msgs[0].data) == @grpc_body
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
      seed_pipeline_baseline
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
      @grpc_mode = false
      @http2 = detail.http_version == "HTTP/2"
      @target = build_target(detail.row.scheme, detail.row.host, detail.row.port)
      @tcx = @target.size
      @sni = ""
      @scx = 0
      @target_field = :url
      @editor.set_text(origin_form_text(detail))
      seed_pipeline_baseline
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
      ((@decode_kind || @ws_mode) && @req_pane == :decoded) ? @decoded : @editor
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
      return unless @decode_kind || @ws_mode
      return if to == @req_pane
      if @decode_kind
        to == :envelope ? commit_decoded : refresh_decoded
      end
      @req_pane = to
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
      return env if @graphql_location == :none
      if @graphql_location == :query # GET: rewrite the request-line query (no body), like SAML Redirect
        lines = env.split('\n')
        lines[0] = graphql_query_line(lines[0], @decoded.text) if lines[0]?
        lines.join('\n')
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

    # The replayable request bytes for a gRPC tab: the edited head + the canonical
    # CRLFCRLF terminator (what H2Engine.split_head_body keys on) + the message body.
    # A reframable (unary) call reframes the current payload — hex-edited via @req_hex_edit
    # while in hex mode, else the stored @grpc_payload — so the 5-byte length prefix always
    # matches the payload the origin receives; otherwise the pristine @grpc_body is resent
    # verbatim. Auto-Content-Length never applies (h2 frames by DATA/END_STREAM).
    private def grpc_request_bytes : Bytes
      raw = expanded_editor_bytes
      n = raw.size
      while n > 0 && (raw[n - 1] == 0x0A_u8 || raw[n - 1] == 0x0D_u8) # trim trailing CR/LF
        n -= 1
      end
      body = grpc_send_body
      io = IO::Memory.new(n + body.size + 4)
      io.write(raw[0, n])
      io << "\r\n\r\n"
      io.write(body)
      io.to_slice
    end

    # The framed message body to send: a reframable call re-length-prefixes the live
    # payload (hex buffer if editing, else the stored payload); everything else is verbatim.
    private def grpc_send_body : Bytes
      return @grpc_body unless @grpc_reframable
      payload = (h = @req_hex_edit) ? h.to_bytes : @grpc_payload
      Proxy::H2::Grpc.frame(@grpc_compressed, payload)
    end

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
      !(@grpc_mode || @ws_mode || @decode_kind || @http2)
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
      if @req_hex_edit || @grpc_mode || @ws_mode || @decode_kind
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

    # Record how many `%%%` lines the just-seeded buffer arrived with. Called from every
    # loader AFTER the editor is set, so the baseline is always the bytes gori was handed
    # rather than anything typed since. On a draft it is 0 either way (`pipeline_live?`
    # short-circuits on `@evidence`); recording it anyway keeps a later `duplicate_from`
    # or an evidence flip from inheriting a stale number.
    private def seed_pipeline_baseline : Nil
      @evidence_pipeline_seps = pipeline_sep_count_in(@editor.wire_text)
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
      # and the border chip saying so; ^K re-declares.)
      @markers_declared = false
      apply_request_fields(target, request, http2, auto_cl, sni, ws_messages, ws_keep_key)

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
                           evidence : Bool = false) : Nil
      @evidence = evidence
      # A peer's row carries the same two facts a restore does, so the same answer: see restore.
      @markers_declared = false
      apply_request_fields(target, request, http2, auto_cl, sni, ws_messages, ws_keep_key)
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
    def request_side_matches?(target : String, request : String, http2 : Bool, auto_cl : Bool,
                              sni : String?, ws_keep_key : Bool = false) : Bool
      @target == target && request_text == request &&
        @http2 == http2 && @auto_content_length == auto_cl &&
        @ws_keep_key == ws_keep_key &&
        (sni_override || "") == (sni || "")
    end

    # Shared request/target/flag write used by restore (full) and apply_peer_request (soft).
    private def apply_request_fields(target : String, request : String, http2 : Bool, auto_cl : Bool,
                                     sni : String,
                                     ws_messages : Array(Store::WsOutMessage)?,
                                     ws_keep_key : Bool = false) : Nil
      @ws_keep_key = ws_keep_key
      @http2 = http2
      @target = target
      @tcx = @target.size
      @sni = sni
      @scx = @sni.size
      @target_field = :url

      is_ws = !ws_messages.nil? || Repeater::WsEngine.upgrade_request?(request)
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
        @req_pane = :decoded
      else
        @ws_mode = false
        @editor.set_text(request) if @editor.wire_text != request
      end

      @auto_content_length = auto_cl
      seed_pipeline_baseline
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
      @ws_upgrade = src.@ws_upgrade.try(&.dup)
      @ws_result = nil
      @ws_lines_cache = nil

      @grpc_mode = src.@grpc_mode
      @grpc_body = src.@grpc_body.dup
      @grpc_msg_count = src.@grpc_msg_count
      @grpc_reframable = src.@grpc_reframable
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

    # {head, body} strings of the last HTTP response (nil until a send lands, or in
    # WS/gRPC mode where the "response" is a transcript, not raw head+body bytes).
    # Feeds the RESPONSE pane's "copy as X" options (status+headers / body / raw).
    def response_parts : {String, String}?
      return nil if @ws_mode || @grpc_mode
      res = @result
      return nil unless res
      {String.new(res.head), (b = res.body) ? String.new(b) : ""}
    end

    # The last HTTP response's raw {head, body} bytes — for the manual "Run active scan" action,
    # which rebuilds a synthetic flow from the current request + this response. nil until a send
    # lands (a response head is required), or in WS/gRPC mode where the active rules don't apply.
    def last_http_response : {Bytes, Bytes?}?
      return nil if @ws_mode || @grpc_mode
      res = @result
      return nil unless res
      return nil if res.head.empty?
      {res.head, res.body}
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
      wire = @evidence ? Env.normalize_wire(text) : Env.expand_wire(text)
      Repeater::FlowRequest.normalize_multipart_body(wire)
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
      return @http2 if @ws_mode || @grpc_mode
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
      return false if @http2 || @req_hex_edit || @grpc_mode || @ws_mode
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
      if @ws_mode && @req_pane == :decoded
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

    # Whether the CHAIN sub-pane currently owns keyboard input (focused + actually on the
    # request column). The controller routes body keys here when true.
    def chain_pane_active? : Bool
      @chain_focused && @focus == :request && !request_hex?
    end

    # ^Y: drop focus into the CHAIN pane for the marker under the request cursor. Returns
    # a hint string when it can't (surfaced by the controller), nil on success.
    def focus_chain_pane : String?
      return "not available in hex edit" if request_hex?
      return "move to the REQUEST pane first (↹)" unless @focus == :request
      return literal_marker_hint unless markers_live?
      chain = Fuzz::Template.chain_at(@editor.text, @editor.cursor_offset)
      return "put the cursor in a §…§ marker · ^A mark all · ^T insert §" if chain.nil?
      @chain_marker_cursor = @editor.cursor_offset
      @chain_pane.load(chain)
      @chain_focused = true
      nil
    end

    # Commit the CHAIN pane's text back to the bound marker and return focus to the editor.
    # Idempotent — a no-op when the pane isn't focused (so set_focus can call it freely).
    def commit_chain_pane : Nil
      return unless @chain_focused
      # The marker's open § (value region) is unchanged by the chain edit, so it's a stable
      # anchor — restoring the raw cursor could land inside a now-longer hidden chain.
      anchor = Fuzz::Template.marker_start_at(@editor.text, @chain_marker_cursor) || @chain_marker_cursor
      if updated = Fuzz::Template.set_chain(@editor.text, @chain_marker_cursor, @chain_pane.value)
        @editor.set_text(updated)
        @editor.place_at_offset(anchor) # back into the marker (set_text reset it) → tooltip stays up
        @dirty = true
      end
      @chain_focused = false
    end

    # Leave the CHAIN pane WITHOUT writing its edits back to the marker (esc =
    # cancel, the universal editor convention). The editor text was never touched
    # while the pane had focus — only commit_chain_pane writes — so dropping focus
    # is a clean discard; restore the cursor onto the marker so its tooltip stays up.
    def discard_chain_pane : Nil
      return unless @chain_focused
      anchor = Fuzz::Template.marker_start_at(@editor.text, @chain_marker_cursor) || @chain_marker_cursor
      @editor.place_at_offset(anchor)
      @chain_focused = false
    end

    # Route a key while the CHAIN pane is focused: typing/autocomplete stays in the
    # pane; ↵/tab/↑ commit the edit and return to the request editor, while esc
    # cancels (discards the edit) — matching how esc backs out elsewhere.
    def handle_chain_pane_key(ev : Termisu::Event::Key) : Nil
      return if @chain_pane.handle_key(ev) # consumed by the pane (edit / completion nav)
      key = ev.key
      if key.escape?
        discard_chain_pane
      elsif key.enter? || key.tab? || key.up?
        commit_chain_pane
      end
    end

    # --- marking (§…§ Decoder-chain positions) -------------------------------
    # These mirror the Fuzzer's marking helpers, gated on the REQUEST pane (a marked value
    # renders through its chain on send). All delegate to the shared Fuzz::Template helpers.
    # Each of the three that CREATES a marker also declares the buffer a template — see
    # `markers_live?` for why an evidence tab needs to be told.
    def auto_mark : String
      return mark_hint unless markable?
      # `Fuzz::Template.auto_mark` is a documented no-op once the text holds ANY `§`, so on a
      # capture that carries one there is nothing to gain by declaring — and everything to
      # lose: the capture's own `§` would become live positions in exchange for zero new ones.
      # Name that instead of doing it silently.
      return "the capture's own § would become markers and auto-mark adds none — ^K marks the token at the cursor" if literal_markers?
      declare_markers
      @editor.set_text(Fuzz::Template.auto_mark(@editor.text))
      @dirty = true
      n = Fuzz::Template.parse(@editor.text).position_count
      "auto-marked #{n} position#{n == 1 ? "" : "s"}"
    end

    def mark_word : String
      return mark_hint unless markable?
      before = @editor.text
      after = Fuzz::Template.mark_word(before, @editor.cursor_offset)
      return "no word at the cursor — place it on a token (or auto-mark)" if after == before
      note = adopted_literals_note
      declare_markers
      @editor.set_text(after)
      @dirty = true
      msg = Fuzz::Template.parse(after).position_count < Fuzz::Template.parse(before).position_count ? "unmarked position" : "marked position"
      "#{msg}#{note}"
    end

    def insert_marker : String
      return mark_hint unless markable?
      note = adopted_literals_note
      declare_markers
      @editor.insert(Fuzz::Template::MARKER)
      @editor.set_preedit("")
      @dirty = true
      if @editor.text.count(Fuzz::Template::MARKER).odd?
        "marker opened — move the cursor and mark again to close the region#{note}"
      else
        n = Fuzz::Template.parse(@editor.text).position_count
        "marked point — #{n} position#{n == 1 ? "" : "s"}#{note}"
      end
    end

    # NOT a declaring action: `Template.clear_markers` renders the defaults, i.e. it DELETES
    # every `§` in the buffer. On an evidence tab those are the capture's bytes, so running
    # it would do exactly the damage this whole gate exists to prevent — refuse by name.
    def clear_marks : String
      return mark_hint unless markable?
      return literal_marker_hint unless markers_live?
      @editor.set_text(Fuzz::Template.clear_markers(@editor.text))
      @markers_declared = false # back to a buffer with no markers of its own
      invalidate_marker_caches
      @dirty = true
      "cleared all § markers"
    end

    # PROVENANCE: `§…§` (and its `¦chain`) is the operator's DRAFT language, not a value the
    # wire can carry. A `§` that arrived as captured evidence is DATA — U+00A7 is ordinary
    # text, ubiquitous in German and legal bodies — and rendering it as syntax deletes two
    # bytes the origin really sent, silently, with `Content-Length` re-synced behind it so
    # the loss leaves no trace. `gori run repeater <id>` and MCP `send_request` both replay
    # those bytes exactly; the TUI was the one surface that did not.
    #
    # So on an EVIDENCE tab markers start INERT and the operator declares them — by marking
    # (^A / ^K / insert §), the same explicit act the Fuzzer's ⇧I → ^A workflow already is.
    # Declaring is per-buffer and monotone: from then on every `§` in the buffer is a marker
    # (the status line says so when the capture carried one), which is the honest reading of
    # "this buffer is now a template".
    #
    # Deliberately NOT keyed on `@dirty`. `evidence?` documents that an operator edit does
    # not clear provenance — editing a header does not make the `§` in the body something the
    # operator typed — and gating on the first keystroke would put the deletion straight back
    # on the commonest workflow there is (seed a capture, tweak a header, send).
    #
    # A restore()/reconcile lands undeclared: the persisted row carries the request text and
    # its `flow_id`, and nothing that says which `§` in it the operator typed. gori does not
    # know, and for evidence the answer when gori does not know is the wire's. The REQUEST
    # border chip says which state the tab is in whenever a `§` is present at all.
    private def markers_live? : Bool
      !@evidence || @markers_declared
    end

    # Public for the send-path guards that live in the controller (group send / minimize):
    # "are there §…§ regions this send has to render?", provenance included, so a capture's
    # own `§` neither renders nor blocks an unrelated action.
    def markers_active? : Bool
      !marker_regions.empty?
    end

    # True when the buffer holds a `§` that is being treated as literal capture bytes — the
    # only state the REQUEST border needs a chip for (a marker-free request renders exactly
    # as before).
    def literal_markers? : Bool
      !markers_live? && Fuzz::Template.marker_bytes_in?(@editor.text.to_slice)
    end

    private def declare_markers : Nil
      return if @markers_declared
      @markers_declared = true
      invalidate_marker_caches
    end

    # The caches key on `@editor.edits`, which a pure state flip does not bump.
    private def invalidate_marker_caches : Nil
      @marker_regions_rev = -1
      @marker_spans_rev = -1
      @chain_rev = -1
    end

    # Named in the status line when declaring adopts `§` the capture brought with it: those
    # bytes stop being data on the very next send, and that is not something to discover from
    # a 4-byte-shorter request.
    private def adopted_literals_note : String
      literal_markers? ? " — the capture's own § are markers now (^Z undoes)" : ""
    end

    private def literal_marker_hint : String
      "§ here is captured data, not a marker — ^K marks a token (the capture's § become markers too)"
    end

    # Insert an OAST payload URL at the request-editor caret (cross-tab "Insert OAST
    # payload"). Only when the request pane is focused and not in hex mode.
    def insert_oast_payload(url : String) : Bool
      return false unless @focus == :request && !request_hex?
      @editor.insert_string(url)
      @editor.set_preedit("")
      @dirty = true
      true
    end

    private def markable? : Bool
      @focus == :request && !request_hex?
    end

    private def mark_hint : String
      return "marking isn't available in hex edit" if request_hex?
      "marking works on the REQUEST pane — ↹ to it"
    end

    # When enabled, rewrite an existing `Content-Length` header so it matches the
    # actual edited body length (the part after the blank line). Common when
    # tampering with a captured body — you change the JSON and the length should
    # follow. Only an EXISTING header is updated (never added, so GETs stay clean);
    # chunked/h2 bodies have no Content-Length and are left untouched. Shared with the
    # headless CLI/MCP repeater-send paths via FlowRequest so they can't drift apart.
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
    private def reflect_content_length_in_editor : Nil
      return unless @auto_content_length
      return if @req_hex_edit || @grpc_mode || @ws_mode
      return if @decode_kind && @req_pane == :decoded

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

      @editor.replace_line(idx, new_line)
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
      return if @req_hex_edit || @ws_mode || @grpc_mode
      scheme, host, port = parse_target
      return if host.empty?
      # Shared with the engine and the CLI (build_target derives from the same call), so the
      # three cannot drift. The local formula this replaced never re-bracketed an IPv6 literal —
      # parse_target hands back a bracket-free host — and so wrote the malformed `Host: ::1:8443`.
      authority = Repeater::FlowRequest.authority(scheme, host, port)
      env_sep = @editor.text.index("\n\n")
      return unless env_sep
      head_lines = @editor.text[0, env_sep].split('\n')
      host_idx = head_lines.index { |l| l.lstrip.downcase.starts_with?("host:") }
      return unless host_idx
      new_line = "Host: #{authority}"
      return if head_lines[host_idx] == new_line
      @editor.replace_line(host_idx, new_line)
    end

    # {scheme, host, port} parsed from the target field.
    # Delegate to the engine's parser so the TUI field and `gori run`/the repeater engine never
    # disagree on host/port (they used to be byte-for-byte duplicate implementations).
    def parse_target : {String, String, Int32}
      Repeater::FlowRequest.parse_target(Env.expand(@target))
    end

    # The TARGET card grows to a second content row (4 high vs 3) whenever an SNI
    # override is set OR is being edited — so the override is always visible, and the
    # input row only appears once you reach for it (^S).
    private def sni_active? : Bool
      !@sni.strip.empty? || (editing_sni? && @focus == :target)
    end

    private def target_card_h : Int32
      sni_active? ? 4 : 3
    end

    # The TARGET card row prefixes (marker + the field value 1 col to its right). Kept
    # as constants so render_target and the click→caret mapping agree on the value base.
    TARGET_PREFIX = "›"
    SNI_PREFIX    = "SNI ›"

    private def field_base(rect : Rect, prefix : String) : Int32
      rect.x + 2 + prefix.size + 1
    end

    # --- focus ring (driven by the Runner's Tab/Shift-Tab) ---
    # Pane order top-to-bottom: target ▸ request ▸ response. focus_first/last are
    # the ends of the ring; pane_advance returns false when it would step off an
    # end (the Runner then wraps focus back to the tab bar).
    PANE_ORDER = [:target, :request, :response]

    def focus_first : Nil
      set_focus(:target)
    end

    def focus_last : Nil
      set_focus(:response)
    end

    # Move focus to `pane`, exiting the ^S SNI sub-field. SNI editing is an explicit
    # per-visit sub-mode (you opt in with ^S each time you're on the target), so ANY
    # focus change drops back to the URL field — otherwise navigating away while
    # editing SNI and returning would silently route URL keystrokes into @sni.
    private def set_focus(pane : Symbol) : Nil
      commit_chain_pane if @chain_focused # any focus change saves a pending chain edit
      # Leaving the target for another pane flushes the ^N host-link here — BEFORE the user
      # can reach the request body to hand-edit the Host. That ordering is what keeps the
      # one-shot from ever clobbering a deliberately-mismatched Host (Host-header attacks):
      # the flag is spent on the way out of the target, so a later body Host edit stands.
      # Covers every target→elsewhere path (keyboard pane_advance, mouse focus_pane, chips);
      # exit_target_insert! (Esc) and repeater_send (^R straight from target) are the other two.
      sync_host_to_target_once if @focus == :target && pane != :target
      @focus = pane
      @target_field = :url
    end

    def set_preedit(text : String) : Nil
      chain_pane_active? ? @chain_pane.set_preedit(text) : req_editor.set_preedit(text)
    end

    def pane_advance(dir : Int32) : Bool
      i = PANE_ORDER.index(@focus) || 0
      ni = i + dir
      return false if ni < 0 || ni >= PANE_ORDER.size
      set_focus(PANE_ORDER[ni])
      true
    end

    # Public setter mirroring the focus ring: jump straight to a pane (e.g. a click)
    # rather than stepping with pane_advance. Ignores anything not in PANE_ORDER.
    # (A click on the SNI row re-enters it: target_click_to_cursor runs after this.)
    def focus_pane(pane : Symbol) : Nil
      set_focus(pane) if PANE_ORDER.includes?(pane)
    end

    # Inverts render's layout: a 3-row target band on top, then a half-width
    # request|response split (the column at content.x + half is the divider).
    def pane_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil unless @loaded && rect.contains?(mx, my)
      target_h = {rect.h, target_card_h}.min
      return :target if my < rect.y + target_h
      content = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
      return nil if content.h <= 0
      half = {(content.w - 1) // 2, 1}.max
      return :request if mx < content.x + half
      mx >= content.x + half + 1 ? :response : nil
    end

    # Border-chrome hit-test for REQUEST/RESPONSE toggle chips. Shares geometry with
    # render_request / render_response_chrome (label strings + start_x / right chain).
    # Returns a chip id, or nil so the caller can fall through to caret placement.
    def chrome_hit(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil unless @loaded && rect.contains?(mx, my)
      target_h = {rect.h, target_card_h}.min
      # TARGET NOR/INS chip (top band) — click toggles insert like ↵/esc.
      if my == rect.y && target_h >= 2
        if Frame.mode_badge_hit(mx, my, rect.y, rect.right - 1, rect.x + 8, target_insert?)
          return :target_mode
        end
      end
      content = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
      return nil if content.h <= 0
      half = {(content.w - 1) // 2, 1}.max
      left = Rect.new(content.x, content.y, half, content.h)
      right = Rect.new(content.x + half + 1, content.y, {content.w - half - 1, 0}.max, content.h)

      # RESPONSE: d:diff / x:hex / p:pretty (not drawn in WS/gRPC/group transcript modes)
      unless @ws_mode || @grpc_mode || group_mode?
        if right.w >= 2 && my == right.y
          if hit = Frame.left_chip_hit(mx, my, right.y, right.x + 12, [
               {:diff, " d:diff "},
               {:hex, " ^X:hex "},
               {:pretty, " p:pretty "},
             ] of {Symbol, String})
            return hit
          end
        end
      end

      # REQUEST badges: ^R:SEND is always rightmost (primary action). Then CL/PRETTY (or
      # HEX) when drawn; NOR/INS mode chip chains left of those. Decode / CHAIN splits
      # keep chrome on the top card. WS/gRPC skip the mode chip (no render_mode_badge).
      req_card = (@decode_kind || @ws_mode) ? decode_split(left)[0] : left
      if req_card.w >= 2 && my == req_card.y
        label = render_request_label
        min_x = req_card.x + label.size + 4
        right_edge = req_card.right - 1
        badges = [{:send, "^R", "SEND"}] of {Symbol, String, String}
        if @grpc_mode
          if @req_hex_edit
            badges << {:req_hex, "^X", "HEX"} # editing the payload
          elsif @grpc_reframable
            badges << {:req_hex, "^X", "MSG"} # click to hex-edit the unary payload
          end
        elsif !@ws_mode
          if @req_hex_edit
            badges << {:req_hex, "^X", "HEX"}
          else
            badges << {:cl, "^L", "CL"}
            badges << {:pretty_req, "^U", "PRETTY"}
          end
        end
        if hit = Frame.right_badge_hit(mx, my, req_card.y, right_edge, min_x, badges)
          return hit
        end
        # Mode chip only drawn for plain HTTP request (not WS / gRPC / hex-edit).
        unless @ws_mode || @grpc_mode || @req_hex_edit
          mode_edge = Frame.right_badge_edge(right_edge, min_x, badges)
          if Frame.mode_badge_hit(mx, my, req_card.y, mode_edge, min_x, request_insert?)
            return :mode
          end
        end
      end
      nil
    end

    # Mouse: place the request-editor caret (text) or nibble cursor (hex) at a click.
    # `rect` is the full body rect render() receives; re-derive the request half-pane
    # (target band + split, then the card's 1-cell inset) exactly as render_request does.
    def request_click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless @loaded
      target_h = {rect.h, target_card_h}.min
      content = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
      return if content.h <= 0
      half = {(content.w - 1) // 2, 1}.max
      col = Rect.new(content.x, content.y, half, content.h)
      if @decode_kind || @ws_mode # split: click selects the envelope/handshake or decoded/messages sub-pane + places its caret
        env, dec = decode_split(col)
        if my >= dec.y
          switch_req_pane(:decoded)
          @decoded.click_to_cursor(dec.inset(1, 1), mx, my)
        else
          switch_req_pane(:envelope)
          @editor.click_to_cursor(env.inset(1, 1), mx, my)
        end
        return
      end
      commit_chain_pane if @chain_focused # a click outside the ^Y modal commits + dismisses it, then places the caret
      inner = col.inset(1, 1)
      if h = @req_hex_edit
        h.click_to_nibble(inner, mx, my, @scroll_req) # hex mode: place the nibble cursor
      else
        @editor.click_to_cursor(inner, mx, my)
      end
    end

    # Vertical split of the request column into {envelope, decoded} rects for a decode
    # tab — the ACTIVE sub-pane is enlarged (~2/3). Both clamp to ≥1 row so neither
    # vanishes. render() and request_click_to_cursor share this so they never disagree.
    private def decode_split(col : Rect) : {Rect, Rect}
      inactive = {col.h // 3, 1}.max
      env_h = @req_pane == :envelope ? {col.h - inactive, 1}.max : inactive
      env = Rect.new(col.x, col.y, col.w, env_h)
      dec = Rect.new(col.x, col.y + env_h, col.w, {col.h - env_h, 0}.max)
      {env, dec}
    end

    private def ws_resp_split(col : Rect) : {Rect, Rect}
      # The handshake response header is short (typically 4-5 lines of HTTP headers).
      # We allocate a fixed height (7 rows) for the handshake card, and the rest for transcript.
      handshake_h = 7.clamp(1, {col.h - 2, 1}.max)
      handshake = Rect.new(col.x, col.y, col.w, handshake_h)
      transcript = Rect.new(col.x, col.y + handshake_h, col.w, {col.h - handshake_h, 0}.max)
      {handshake, transcript}
    end

    # Mouse: focus the URL or SNI field of the TARGET band by which row was clicked,
    # and place that field's caret. The value bases mirror render_target (field_base).
    def target_click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless @loaded
      # The SNI row is at exactly rect.y+2 (bottom border is rect.y+3) — match it
      # precisely, so a click on the card's border doesn't route edits into @sni.
      if sni_active? && my == rect.y + 2
        @target_field = :sni
        @scx = Screen.column_for(@sni, mx - field_base(rect, SNI_PREFIX))
      else
        @target_field = :url
        @tcx = Screen.column_for(@target, mx - field_base(rect, TARGET_PREFIX))
      end
    end

    # Top boundary of the focused pane — the Runner pops focus to the tab bar when
    # ↑ is pressed here (natural upward flow): the single-line target always, the
    # request editor at its first line, the response when scrolled to the top. In a
    # split-decode tab, ↑ at the top of the DECODED sub-pane crosses UP to the ENVELOPE
    # (handled in edit_move), NOT to the tab bar — so it reports false here.
    def at_top? : Bool
      case @focus
      when :target then true
      when :request
        if h = @req_hex_edit
          h.at_top?
        elsif (@decode_kind || @ws_mode) && @req_pane == :decoded
          false
        else
          @editor.at_top?
        end
        # Cursor-aware for navigable modes (mirrors fuzzer_view's detail_cursor_at_top?) so
        # ↑/⇧↑ move/extend the read cursor upward until it reaches line 0 with scroll at top,
        # instead of ejecting the pane whenever the response fits on screen (@scroll stays 0).
        # The non-navigable hex dump has no caret, so keep scroll-based ejection there.
      when :response then resp_navigable? ? (@resp_cursor.cy == 0 && @scroll == 0) : @scroll == 0
      else                false
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

    # --- request editor (focus == :request) ---
    # Input/cursor target the active sub-pane (envelope or decoded); a content edit
    # dirties the right buffer — the envelope (persist/sync) or the decoded payload
    # (→ re-encode on send). Pure navigation dirties neither.
    private def mark_req_edit : Nil
      if (@decode_kind || @ws_mode) && @req_pane == :decoded
        @decoded_dirty = true
        @ws_out_edited = true
      else
        @dirty = true
        reflect_content_length_in_editor
      end
    end

    # undo / backspace / forward-delete are NO-OPS on an empty undo stack, at buffer start and
    # at end-of-buffer respectively (TextArea returns early without bumping @edits). A no-op
    # must not mark the buffer edited. `intercept_view.cr` has carried this guard and the
    # reason for it since #513; the Repeater's copy did not, and the consequence here is
    # worse: `mark_req_edit` sets `@ws_out_edited`, so a single `Ctrl-Z` in READ mode on an
    # untouched WebSocket tab took the pane off its seed and dropped every frame the pane was
    # not showing — observed as a captured BIN frame vanishing from the wire between two
    # otherwise identical replays. Gate on a real edit.
    def edit_undo : Nil
      return unless @focus == :request
      ed = req_editor
      before = ed.edits
      ed.undo
      mark_req_edit if ed.edits != before
    end

    def edit_insert(ch : Char) : Nil
      return unless @focus == :request
      # Marker-in-marker guard: a §/¦ typed inside (or flush against) a closed marker is
      # auto-escaped to a §§/¦¦ literal so the structure survives (Template.insert_breaks_marker?).
      if req_marker_editable? &&
         Fuzz::Template.insert_breaks_marker?(@editor.text, @editor.cursor_offset, ch, marker_spans)
        @editor.insert_pair(ch)
      else
        req_editor.insert(ch)
      end
      mark_req_edit
    end

    def edit_newline : Nil
      return unless @focus == :request
      req_editor.insert_newline
      mark_req_edit
    end

    def edit_backspace : Nil
      return unless @focus == :request
      ed = req_editor
      before = ed.edits
      ed.backspace
      mark_req_edit if ed.edits != before # no-op at buffer start — see edit_undo
    end

    # `selecting` is the Shift half of ⇧←/→/↑/↓: it extends the INS-mode selection from its
    # anchor instead of collapsing it. Defaulted false so every existing caller is a plain
    # move. The pane-crossing branch below deliberately does NOT forward it — a selection
    # that jumped from the ENVELOPE into the DECODED sub-pane would span two buffers, and
    # neither `cut_selection` nor the band painter can express that.
    def edit_move(dr : Int32, dc : Int32, selecting : Bool = false) : Nil
      return unless @focus == :request
      # In a split-decode tab, a vertical step off the end of one sub-pane crosses into
      # the other (↓ off the ENVELOPE bottom → DECODED top; ↑ off the DECODED top →
      # ENVELOPE bottom), syncing the two at the boundary — so the split feels like one
      # continuous column. (↑ off the ENVELOPE top pops to the tab bar via at_top?.)
      if (@decode_kind || @ws_mode) && dc == 0
        if dr > 0 && @req_pane == :envelope && @editor.at_bottom?
          switch_req_pane(:decoded)
          @decoded.goto_line(1)
          return
        end
        if dr < 0 && @req_pane == :decoded && @decoded.at_top?
          switch_req_pane(:envelope)
          @editor.goto_line(Int32::MAX) # clamps to the last line
          return
        end
      end
      req_editor.move(dr, dc, selecting)
      # Cursor navigation is NOT a content edit: leave @dirty alone. Marking it here made
      # pure arrow-key movement persist the tab (V11) and, worse, latch sync-clobber
      # protection so a live cross-session update could no longer refresh the tab.
    end

    # Home/End: pure navigation (caret to line start/end) → does NOT dirty, like edit_move.
    def edit_home : Nil
      req_editor.home if @focus == :request
    end

    def edit_end : Nil
      req_editor.end_of_line if @focus == :request
    end

    # Forward-delete: a content edit → dirties (matches edit_backspace).
    def edit_delete : Nil
      return unless @focus == :request
      ed = req_editor
      before = ed.edits
      ed.delete
      mark_req_edit if ed.edits != before # no-op at end-of-buffer — see edit_undo
    end

    # --- marker structure guards (delimiter delete / nesting) --------------------
    # When a backspace here would delete a §/¦ that structures a closed marker, the {a, b}
    # span of that marker (fed to the strip-confirm) — else nil. Only in the plain-HTTP
    # request envelope, where §…§ markers render + conceal.
    def marker_break_on_backspace : {Int32, Int32}?
      return nil unless req_marker_editable?
      Fuzz::Template.structural_marker_at(@editor.text, @editor.cursor_offset - 1, marker_spans)
    end

    # Same, for a forward-delete (the char UNDER the caret).
    def marker_break_on_delete : {Int32, Int32}?
      return nil unless req_marker_editable?
      Fuzz::Template.structural_marker_at(@editor.text, @editor.cursor_offset, marker_spans)
    end

    # 1-based ordinal of the closed marker at `span` — for the confirm copy ("marker §N").
    def marker_ordinal(span : {Int32, Int32}) : Int32
      (marker_spans.index(span) || 0) + 1
    end

    # Confirmed strip: drop the whole marker at `span`, keeping only its raw value; caret to
    # the freed value's end. One undoable edit, so prior edits stay undoable. Dirties the tab.
    def strip_marker_span(span : {Int32, Int32}) : Nil
      return unless @focus == :request
      new_text, caret = Fuzz::Template.strip_marker(@editor.text, span)
      @editor.replace_all(new_text, caret)
      mark_req_edit
    end

    # ^G go-to-line in the request editor (no-op in hex mode — the TextArea is stale).
    # Pure navigation → does NOT dirty the tab (no content change to persist/lock).
    def goto_request_line(n : Int32) : Nil
      return unless @focus == :request && !request_hex?
      req_editor.goto_line(n)
    end

    # ^F search in the request editor: 0-based line indices containing `query`.
    def request_search_lines(query : String) : Array(Int32)
      return [] of Int32 if request_hex?
      req_editor.search_lines(query)
    end

    # ^F find&replace over the request editor. Hex mode is excluded like the search
    # above (the TextArea is stale there, so a write would clobber the real bytes).
    def request_match_count(query : String) : Int32
      return 0 if request_hex?
      req_editor.match_count(query)
    end

    def request_replace_matches(query : String, replacement : String) : Int32
      return 0 if request_hex?
      n = req_editor.replace_matches(query, replacement)
      mark_req_edit if n > 0
      n
    end

    # Whitespace reveal toggle — response renders from raw bytes; the request editor
    # shows within-line whitespace too.
    def reveal=(on : Bool) : Nil
      return if @reveal == on # the controller pushes this every frame; guard so @scroll isn't zeroed each render
      @reveal = on
      @editor.reveal = on
      @decoded.reveal = on # the decode split's payload editor honours reveal too
      @scroll = 0          # reveal renders the response from RAW bytes → a different line count; reset like pretty=/x/d
      resp_wrap_reset
    end

    # Pretty toggle feeds `resp_view`, so a change drops only the response-view cache
    # (the diff/hex caches are unaffected — pretty touches neither). Change-detected
    # because the runner pushes this every frame.
    def pretty=(on : Bool) : Nil
      return if @pretty == on
      @pretty = on
      drop_resp_view_cache
      @scroll = 0 # reflow changes the line count → a stale offset could blank the pane (like x/d toggles)
      resp_wrap_reset
    end

    # ^F highlight, scoped to the searched pane (the Runner picks which).
    def request_search_hl=(q : String) : Nil
      @editor.search_hl = q
      @decoded.search_hl = q
    end

    def response_search_hl=(q : String) : Nil
      @search_hl = q
    end

    # --- target field (focus == :target) ---
    # The TARGET pane edits one of two single-line fields — the URL or the SNI host
    # override — selected by @target_field (^S toggles). The mutators below act on
    # whichever is active so one set of keys drives both.
    getter sni : String

    # The SNI host to present in the TLS handshake, or nil when blank (→ the dialed
    # target host is used, the usual case).
    def sni_override : String?
      s = @sni.strip
      s.empty? ? nil : s
    end

    def editing_sni? : Bool
      @target_field == :sni
    end

    # ^S (on the TARGET pane): flip between editing the URL and the SNI host. Entering
    # the SNI field homes its caret to the end; leaving it returns to the URL.
    def toggle_sni_field : Nil
      if @target_field == :sni
        @target_field = :url
      else
        @target_field = :sni
        @scx = @sni.size
        @target_mode = InputMode::Insert
      end
    end

    # Drop back to URL editing (↵/esc in the SNI field) without changing the value.
    def exit_sni_field : Nil
      @target_field = :url
    end

    def target_insert(ch : Char) : Nil
      if @target_field == :sni
        @sni = "#{@sni[0, @scx]}#{ch}#{@sni[@scx..]}"
        @scx += 1
      else
        @target = "#{@target[0, @tcx]}#{ch}#{@target[@tcx..]}"
        @tcx += 1
      end
      @dirty = true
    end

    def target_backspace : Nil
      if @target_field == :sni
        return if @scx == 0
        @sni = "#{@sni[0, @scx - 1]}#{@sni[@scx..]}"
        @scx -= 1
      else
        return if @tcx == 0
        @target = "#{@target[0, @tcx - 1]}#{@target[@tcx..]}"
        @tcx -= 1
      end
      @dirty = true
    end

    def target_move(d : Int32) : Nil
      if @target_field == :sni
        @scx = (@scx + d).clamp(0, @sni.size)
      else
        @tcx = (@tcx + d).clamp(0, @target.size)
      end
      # Cursor navigation is not a content edit — do NOT dirty (caret is never persisted),
      # mirroring edit_move/goto_request_line/hex_move.
    end

    # Home/End on the single-line target/SNI field — pure caret moves, no dirty.
    def target_home : Nil
      @target_field == :sni ? (@scx = 0) : (@tcx = 0)
    end

    def target_end : Nil
      @target_field == :sni ? (@scx = @sni.size) : (@tcx = @target.size)
    end

    # Forward-delete the char under the caret on the target/SNI field — a content edit.
    def target_delete : Nil
      if @target_field == :sni
        return if @scx >= @sni.size
        @sni = "#{@sni[0, @scx]}#{@sni[@scx + 1..]}"
      else
        return if @tcx >= @target.size
        @target = "#{@target[0, @tcx]}#{@target[@tcx + 1..]}"
      end
      @dirty = true
    end

    # --- response pane (focus == :response) ---
    def toggle_resp_mode : Nil
      @resp_mode = @resp_mode == :response ? :diff : :response
      @scroll = 0
      resp_wrap_reset
    end

    # 'x' toggles a raw hex dump of the response bytes (overrides response/diff).
    def toggle_resp_hex : Nil
      @resp_hex = !@resp_hex
      @scroll = 0 # row-based offset differs from the line-based one
      resp_wrap_reset
    end

    getter? resp_hex : Bool

    # Whether Pretty actually reflowed the current response body (drives the chip).
    # resp_view memoizes it; reading forces the (memoized) build so it's current.
    def resp_pretty_applied? : Bool
      resp_view
      @resp_pretty_applied
    end

    # Combined head+body of the last result (hex source), cached; nil when not sent
    # or errored. Invalidated when a new result is applied (reset_result_caches).
    private def resp_hex_bytes : Bytes?
      return @resp_hex_bytes if @resp_hex_bytes
      result = @result
      return nil unless result && result.ok?
      @resp_hex_bytes = combine(result.head, result.body)
    end

    # Scroll the response pane by `delta` DRAWN rows. In hex the pane draws its own fixed
    # rows and there is nothing to wrap, so that mode keeps the plain row offset.
    def scroll(delta : Int32) : Nil
      if @resp_hex || @resp_last_cw <= 0
        @scroll = (@scroll + delta).clamp(0, {resp_line_count - 1, 0}.max)
        @scroll_sub = 0 # the anchor line moved by whole lines; a carried sub-row would
        return          # be read against a line that was never laid out at that row
      end
      size, line_at, _ = resp_drawn_source
      return if size <= 0
      fn = resp_layout_fn(@resp_last_cw, line_at)
      @scroll = @scroll.clamp(0, size - 1)
      @scroll, @scroll_sub = if delta < 0
                               Wrap.step_back(@scroll, @scroll_sub, -delta, fn)
                             else
                               Wrap.step_forward(@scroll, @scroll_sub, delta, size, fn)
                             end
    end

    # Response READ: move caret (and optional selection). Scroll follows the caret.
    # Lazy line source — vertical steps only materialise the destination line.
    #
    # ↑/↓ step one VISUAL row (see `resp_visual_target`), like the request editor's.
    def resp_move(dr : Int32, dc : Int32, selecting : Bool = false) : Nil
      return unless resp_navigable?
      size, line_at = resp_line_source
      return if size <= 0
      if target = resp_visual_target(dr)
        @resp_cursor.move_to(target[0], target[1], selecting: selecting)
      else
        @resp_cursor.move(dr, dc, size, line_at, selecting)
      end
      ensure_resp_visible(@resp_last_h) if @resp_last_h > 0
    end

    # The caret `dr` visual rows away, in the BARE line coordinates `@resp_cursor` holds, or
    # nil when this pane has no wrap to walk — hex draws its own fixed rows, and before the
    # first frame there is no content width to have laid anything out at (`scroll` guards on
    # the same pair). The caller then steps logical lines, which is what a row is there.
    #
    # The walk runs on the DRAWN line, because that is what the wrap was computed on: in
    # diff mode every row carries a `"+ "`/`"- "` decoration whose columns shift each break.
    # So the column goes in as `cx + off` and the result comes back out through the same
    # `{cx - off, 0}.max.clamp(…)` the click and the wheel already use — a caret that lands
    # on the decoration belongs at column 0 of the text, the only place it can be drawn.
    private def resp_visual_target(dr : Int32) : {Int32, Int32}?
      return nil if dr == 0 || @resp_hex || @resp_last_cw <= 0
      size, drawn_at, off = resp_drawn_source
      return nil if size <= 0
      _, line_at = resp_line_source
      li, dcx = Wrap.step_caret(@resp_cursor.cy, @resp_cursor.cx + off, dr, size,
        drawn_at, resp_layout_fn(@resp_last_cw, drawn_at))
      {li, {dcx - off, 0}.max.clamp(0, line_at.call(li).size)}
    end

    # The INS half of the guard is gone: the wheel scrolls the request editor in insert
    # mode exactly as it does in normal mode. There were TWO guards for this, one here and
    # one in the controller's handle_wheel, so removing either alone changed nothing — they
    # landed together in the replay→repeater migration rather than as a decision, and the
    # neighbours disagree with them (Notes and the Decoder input scroll in insert mode with
    # no mode guard at all).
    #
    # `scroll_view` moves the viewport and drags the caret only when the window would
    # otherwise leave it behind — that is what NOR already uses, and mode consistency is the
    # point. A pure detached viewport is not available here: `render` calls `ensure_visible`
    # on EVERY frame, so a detached scroll would snap back on the next one.
    #
    # The hex half stays. `@req_hex_edit` is a different widget and the TextArea behind it
    # holds stale bytes, so scrolling it would move a buffer the operator is not looking at.
    def request_scroll_view(step : Int32) : Nil
      return if request_hex?
      req_editor.scroll_view(step)
    end

    # Wheel: `step` is DRAWN rows. Still O(viewport) — the anchor walk never counts the
    # response's total rows (see @scroll_sub) and only the caret line is materialised.
    def resp_scroll_view(step : Int32) : Nil
      return unless resp_navigable?
      size, drawn_at, off = resp_drawn_source
      _, line_at = resp_line_source
      return if @resp_last_h <= 0 || size <= 0
      cw = @resp_last_cw
      if cw <= 0
        return if size <= @resp_last_h
        @scroll = (@scroll + step).clamp(0, size - @resp_last_h)
        @scroll_sub = 0 # see `scroll`: no layout exists yet to carry a sub-row against
      else
        fn = resp_layout_fn(cw, drawn_at)
        @scroll = @scroll.clamp(0, size - 1)
        @scroll, @scroll_sub = if step < 0
                                 Wrap.step_back(@scroll, @scroll_sub, -step, fn)
                               else
                                 Wrap.step_forward(@scroll, @scroll_sub, step, size, fn)
                               end
        mli, msub = Wrap.max_anchor(size, @resp_last_h, fn)
        if @scroll > mli || (@scroll == mli && @scroll_sub > msub)
          @scroll = mli
          @scroll_sub = msub
        end
      end
      # Pull the caret into the window, compared in VISUAL rows: a caret on the anchor LINE
      # can still be several wrapped rows above the anchor ROW, and the line-only clamp let
      # it sit there and drag the view straight back on the next ensure_resp_visible.
      rows = resp_rows(cw, @resp_last_h, size, drawn_at)
      return if rows.empty?
      first = rows[0]
      last = rows[rows.size - 1]
      cy = @resp_cursor.cy
      cx = @resp_cursor.cx + off # compare in the DRAWN line's coordinates (diff decoration)
      if cy < first.li || (cy == first.li && cx < first.a)
        cy, cx = first.li, first.a
      elsif cy > last.li || (cy == last.li && cx > last.b)
        cy, cx = last.li, last.a
      end
      @resp_cursor.sync(cy, {cx - off, 0}.max.clamp(0, line_at.call(cy).size))
    end

    def resp_click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless resp_navigable? && @loaded
      target_h = {rect.h, target_card_h}.min
      content = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
      return if content.h <= 0
      half = {(content.w - 1) // 2, 1}.max
      col = Rect.new(content.x + half + 1, content.y, {content.w - half - 1, 1}.max, content.h)
      return unless col.contains?(mx, my)
      body = response_body_rect(col)
      # Render's own numbers, not a re-derivation — see @resp_last_gw. Falls back to the
      # gutter estimate only before the first frame, when nothing has been laid out yet.
      gw = @resp_last_cw > 0 ? @resp_last_gw : resp_gutter_w(body)
      cw = @resp_last_cw > 0 ? @resp_last_cw : {body.w - gw, 0}.max
      size, drawn_at, off = resp_drawn_source
      _, line_at = resp_line_source
      return if size <= 0
      row = my - body.y
      return if row < 0
      rows = resp_rows(cw, body.h, size, drawn_at)
      return if rows.empty?
      # The wrap inverse, not `@scroll + row`: a screen row is a VISUAL row now, and the
      # continuation rows between it and the anchor are exactly what the old arithmetic
      # skipped. `Wrap.row_index` clamps to the row it was given, so a click past the end of
      # a wrapped row stops at the break rather than selecting the next row's first char.
      vr = rows[row]? || rows[rows.size - 1]
      drawn = drawn_at.call(vr.li)
      hit = Wrap.row_index(drawn, nil, vr.a, vr.b, mx - (body.x + gw))
      @resp_cursor.clear_selection
      @resp_cursor.sync(vr.li, {hit - off, 0}.max.clamp(0, line_at.call(vr.li).size))
      ensure_resp_visible(body.h)
    end

    def request_read_move(dr : Int32, dc : Int32, selecting : Bool = false) : Nil
      return if request_insert? || request_hex?
      lines = request_read_lines
      return if lines.empty?
      @req_read.move(req_editor, dr, dc, selecting: selecting)
    end

    def target_read_move(dc : Int32, selecting : Bool = false) : Nil
      return if target_insert?
      line = target_active_line
      cx = @target_read.move_cx(target_active_cx, dc, line.size, selecting: selecting)
      @target_field == :sni ? (@scx = cx) : (@tcx = cx)
    end

    private def target_active_line : String
      @target_field == :sni ? @sni : @target
    end

    private def target_active_cx : Int32
      @target_field == :sni ? @scx : @tcx
    end

    def request_read_lines : Array(String)
      req_editor.lines_snapshot
    end

    # The INS branch is the other half of `pane_selection?` — see the comment there for why
    # the two must move together. `selection_text` is `String?` (nil when nothing is
    # selected); the `||` keeps the NOR path's caret-line fallback rather than letting insert
    # mode be the one place where a copy with no selection yields nothing.
    def request_copy_text : String
      if pane_insert?(:request)
        req_editor.selection_text || @req_read.copy_text(req_editor)
      else
        @req_read.copy_text(req_editor)
      end
    end

    def request_copy_all_text : String
      @req_read.copy_all(req_editor)
    end

    # The active transcript rows when the response pane is a transcript (WS / gRPC / group
    # send), else nil (a normal single response). The single source these read/copy/search
    # paths share so a new transcript mode wires into all of them at once.
    private def transcript_rows? : Array({String, Color})?
      return ws_transcript_lines if @ws_mode
      return grpc_transcript_lines if @grpc_mode
      return group_transcript_lines if group_mode?
      nil
    end

    def resp_plain_lines : Array(String)
      if t = transcript_rows?
        t.map(&.[0])
      elsif @resp_mode == :diff
        diff_lines.map(&.text)
      elsif @reveal && (rl = reveal_lines)
        rl
      else
        rv = resp_view
        (0...rv.total).map { |i| rv.line_text(i) }
      end
    end

    # O(1) count + lazy line fetch for BodyLines-backed response panes.
    def resp_line_source
      if t = transcript_rows?
        {t.size, ->(i : Int32) { t[i][0] }}
      elsif @resp_mode == :diff
        data = diff_lines
        {data.size, ->(i : Int32) { data[i].text }}
      elsif @reveal && (rl = reveal_lines)
        {rl.size, ->(i : Int32) { rl[i] }}
      else
        rv = resp_view
        {rv.total, ->(i : Int32) { rv.line_text(i) }}
      end
    end

    def resp_copy_text : String
      size, line_at = resp_line_source
      return "" if size <= 0
      @resp_cursor.selection_text(size, line_at) || @resp_cursor.current_line(size, line_at)
    end

    def resp_copy_all_text : String
      size, line_at = resp_line_source
      return "" if size <= 0
      # Rare full-copy path — still build once for clipboard, not per frame.
      (0...size).map { |i| line_at.call(i) }.join("\n")
    end

    def target_copy_text : String
      @target_read.copy_text(target_active_line, target_active_cx)
    end

    def pane_copy_text : String
      case @focus
      when :request  then request_copy_text
      when :response then resp_copy_text
      when :target   then target_copy_text
      else                ""
      end
    end

    def pane_copy_all_text : String
      case @focus
      when :request  then request_copy_all_text
      when :response then resp_copy_all_text
      when :target   then target_active_line
      else                ""
      end
    end

    def pane_selection? : Bool
      case @focus
      # Two selection models, one per mode, and they can never both be live: `@req_read` is
      # the NOR band (its painter is called with `focused && !ins`), `req_editor` holds the
      # INS one. Reporting only the NOR side made "Copy selection" absent in INS even with a
      # visible ⇧-arrow band. Changed together with `request_copy_text` below — this predicate
      # drives `Runner#read_selection_active?`, which gates BOTH the space-menu entry's title
      # and `read_copy`, so claiming a selection here while copy still read `@req_read` would
      # offer "Copy selection" and then copy the caret line.
      when :request  then pane_insert?(:request) ? req_editor.selection? : @req_read.selection?
      when :response then @resp_cursor.selection?
      when :target   then !pane_insert?(:target) && @target_read.selection?
      else                false
      end
    end

    def pane_select_line : Nil
      case @focus
      when :request
        return if pane_insert?(:request)
        @req_read.select_line(req_editor)
      when :response
        size, line_at = resp_line_source
        return if size <= 0
        @resp_cursor.select_line(size, line_at)
        ensure_resp_visible(@resp_last_h) if @resp_last_h > 0
      when :target
        return if pane_insert?(:target)
        line = target_active_line
        cx = @target_read.select_line(line.size)
        @target_field == :sni ? (@scx = cx) : (@tcx = cx)
      end
    end

    def pane_clear_selection : Nil
      case @focus
      when :request  then @req_read.clear_selection
      when :response then @resp_cursor.clear_selection
      when :target   then @target_read.clear_selection
      end
    end

    private def resp_gutter_w(body : Rect) : Int32
      return 0 unless Settings.show_gutter # keep click→cursor mapping aligned with the gutter-less render
      {Gutter.width(resp_line_count), body.w}.min
    end

    private def response_body_rect(col : Rect) : Rect
      if @ws_mode
        _, transcript = ws_resp_split(col)
        transcript.inset(1, 1)
      else
        col.inset(1, 1)
      end
    end

    # Keep the caret's VISUAL row inside the pane. Line-indexed scrolling drifts the moment
    # anything wraps — the caret can be on the anchor line and still be a dozen drawn rows
    # off-screen — so the comparison and the re-anchor both happen in rows (Wrap).
    # Falls back to the line-based arithmetic before the first render, when no width is
    # known yet and nothing has been laid out to disagree with.
    private def ensure_resp_visible(view_h : Int32) : Nil
      return if view_h <= 0
      cy = @resp_cursor.cy
      cw = @resp_last_cw
      size, line_at, off = resp_drawn_source
      if cw <= 0 || size <= 0
        if cy < @scroll
          @scroll = cy
        elsif cy >= @scroll + view_h
          @scroll = cy - view_h + 1
        end
        @scroll = 0 if @scroll < 0
        return
      end
      @scroll = @scroll.clamp(0, size - 1)
      fn = resp_layout_fn(cw, line_at)
      csub = fn.call(cy).row_of(@resp_cursor.cx + off)
      @scroll, @scroll_sub = Wrap.ensure_visible(@scroll, @scroll_sub, cy, csub, view_h, fn)
    end

    # --- response soft wrap ----------------------------------------------------

    # Ceiling on the response wrap memo — see TextArea::WRAP_CACHE_CAP, same reasoning.
    RESP_WRAP_CACHE_CAP = 512

    # Drop the wrap memo and put the anchor back on a first row. Called from every site that
    # swaps what the pane is showing (a new result, a mode toggle, reveal/pretty, a fresh
    # load) — the same sites that used to zero the horizontal offset, which is not a
    # coincidence: those are exactly the moments the old layout stops describing the pane.
    private def resp_wrap_reset : Nil
      @scroll_sub = 0
      @resp_wrap.clear
    end

    # Publish the geometry the active response pane just drew with, so hit-testing and the
    # scroll walkers key the wrap memo on exactly the width the rows were laid out at.
    private def resp_record_metrics(gw : Int32, cw : Int32) : Nil
      @resp_last_gw = gw
      @resp_last_cw = cw
    end

    private def resp_layout(li : Int32, cw : Int32, line_at : Int32 -> String) : Wrap::Layout
      if @resp_wrap_w != cw
        @resp_wrap.clear
        @resp_wrap_w = cw
      end
      if hit = @resp_wrap[li]?
        return hit
      end
      @resp_wrap.clear if @resp_wrap.size >= RESP_WRAP_CACHE_CAP
      @resp_wrap[li] = Wrap.layout(line_at.call(li), cw)
    end

    private def resp_layout_fn(cw : Int32, line_at : Int32 -> String) : Int32 -> Wrap::Layout
      ->(i : Int32) { resp_layout(i, cw, line_at) }
    end

    # The response pane's drawn rows for an `h`-row viewport at content width `cw`.
    private def resp_rows(cw : Int32, h : Int32, size : Int32, line_at : Int32 -> String) : Array(Wrap::Row)
      return [] of Wrap::Row if size <= 0 || h <= 0 || cw <= 0
      @scroll = @scroll.clamp(0, size - 1)
      Wrap.rows(@scroll, @scroll_sub, h, size, resp_layout_fn(cw, line_at))
    end

    # What the pane actually DRAWS per row, which is what the wrap has to be computed on.
    # Identical to `resp_line_source` in every mode but DIFF, where each row is prefixed
    # with a 2-column "+ "/"- " decoration: those columns shift every break, so wrapping the
    # bare text there would put the anchor, the click inverse and the draw on three
    # different grids. The third element is that decoration's width, the single constant
    # that converts between the two coordinate systems (see `render_diff`).
    private def resp_drawn_source : {Int32, Proc(Int32, String), Int32}
      if transcript_rows?.nil? && !@reveal && @resp_mode == :diff
        data = diff_lines
        return {data.size, ->(i : Int32) do
          d = data[i]
          prefix = case d.kind
                   when .add? then '+'
                   when .del? then '-'
                   else            ' '
                   end
          "#{prefix} #{d.text}"
        end, DIFF_PREFIX_COLS}
      end
      size, line_at = resp_line_source
      {size, line_at, 0}
    end

    # ⇧←/→ used to nudge the response/diff/reveal/transcript pane sideways. There is no
    # sideways any more: every one of those panes soft-wraps, so the content the operator
    # was panning to is already on the next row. Kept as an explicit no-op ONLY because the
    # chord is still bound in `controllers/repeater_controller.cr` — deleting the method
    # breaks that build, and that file is not in this change's scope. The binding and this
    # stub should go together.

    # ^G go-to-line in the response pane: scroll so 1-based line `n` is at the top
    # (interpreted in the currently-shown mode — response/diff/hex row). Hex mode has
    # no caret to move; in navigable (cursor-tracked) modes, sync @resp_cursor too —
    # otherwise the first ↑/↓ after the jump moves from the caret's stale pre-jump
    # position instead of the line just jumped to.
    def goto_response_line(n : Int32) : Nil
      if resp_navigable?
        size, _ = resp_line_source
        return if size <= 0
        cy = (n - 1).clamp(0, size - 1)
        @resp_cursor.sync(cy, 0)
        @scroll = cy
        @scroll_sub = 0 # ^G names a LOGICAL line, so land on its first visual row
      else
        @scroll = (n - 1).clamp(0, {resp_line_count - 1, 0}.max)
      end
    end

    # ^F search in the response pane: 0-based line indices containing `query` in the
    # CURRENTLY-shown mode (response text or diff). Empty in hex mode.
    def response_search_lines(query : String) : Array(Int32)
      hits = [] of Int32
      return hits if query.empty? || @resp_hex
      q = query.downcase
      if t = transcript_rows? # the transcript is the active "response" pane (WS / gRPC / group)
        t.each_with_index { |row, i| hits << i if row[0].downcase.includes?(q) }
        return hits
      end
      if @resp_mode == :diff
        diff_lines.each_with_index { |d, i| hits << i if d.text.downcase.includes?(q) }
      else
        rv = resp_view
        (0...rv.total).each { |i| hits << i if rv.line_text(i).downcase.includes?(q) }
      end
      hits
    end

    # --- rendering -----------------------------------------------------------

    def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      unless @loaded
        TrafficEmptyState.render(screen, rect, variant: :repeater, title: "no flow loaded")
        return
      end

      # target pane: a 3-row card on top (4 when an SNI override is set/edited);
      # request | response cards fill the rest.
      target_h = {rect.h, target_card_h}.min
      render_target(screen, Rect.new(rect.x, rect.y, rect.w, target_h), focused && @focus == :target)

      content = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
      return if content.h <= 0
      half = {(content.w - 1) // 2, 1}.max
      left = Rect.new(content.x, content.y, half, content.h)
      right = Rect.new(content.x + half + 1, content.y, {content.w - half - 1, 0}.max, content.h)
      req_focused = focused && @focus == :request
      if @decode_kind || @ws_mode # split the request column into ENVELOPE/HANDSHAKE (top) + DECODED/MESSAGES (bottom)
        env, dec = decode_split(left)
        render_request(screen, env, req_focused && @req_pane == :envelope)
        render_decoded(screen, dec, req_focused && @req_pane == :decoded)
      else
        render_request(screen, left, req_focused && !@chain_focused) # dimmed while the ^Y modal owns focus
      end
      render_response(screen, right, focused && @focus == :response)
      render_chain_overlay(screen, rect) if @chain_focused # centered modal ON TOP (replaces the old split)
    end

    # The ^Y chain editor: a centered modal over the whole tab, bound to the marker the
    # cursor sat in when ^Y was pressed. Shows the marker's value, the editable chain, and
    # a live transform preview. Keys route here via the controller (chain_pane_active?).
    private def render_chain_overlay(screen : Screen, area : Rect) : Nil
      value = Fuzz::Template.value_at(@editor.text, @chain_marker_cursor) || ""
      ChainOverlay.render(screen, area, "CHAIN · #{marker_label}", value, @chain_pane)
    end

    # "§N" label for the marker under the cursor (1-based), or "§" when not in one.
    private def marker_label : String
      cur = @editor.cursor_offset
      idx = marker_spans.index { |(a, b)| a <= cur && cur <= b }
      idx ? "§#{idx + 1}" : "§"
    end

    # §…§ char-offset spans for the current request buffer, cached on the editor revision —
    # marker_label + the CHAIN title both read it, so an unchanged buffer joins/scans once.
    # The request editor is the plain-HTTP envelope where §…§ markers render + conceal —
    # the only place the delimiter-delete / nesting guards apply. Hex, gRPC, WS and the
    # decoded split pane all have their own byte semantics and CLEAR concealment, so a §
    # there is literal payload, not a marker.
    private def req_marker_editable? : Bool
      @focus == :request && !request_hex? && !@grpc_mode && !@ws_mode &&
        @decode_kind.nil? && req_editor.same?(@editor)
    end

    private def marker_spans : Array({Int32, Int32})
      return NO_SPANS unless markers_live?
      if @editor.edits != @marker_spans_rev
        @marker_spans_rev = @editor.edits
        @marker_spans_cache = Fuzz::Template.marked_spans(@editor.text)
      end
      @marker_spans_cache
    end

    # The chain (`¦…`) of the marker under the cursor, or nil (not in a marker) / "" (marker,
    # no chain). Cached on {editor revision, cursor} so a stationary cursor doesn't re-join +
    # re-scan the whole buffer every render frame the CHAIN pane is visible.
    private def chain_under_cursor : String?
      return nil unless markers_live? # a captured `¦` isn't a chain — no tooltip over evidence
      cur = @editor.cursor_offset
      if @editor.edits != @chain_rev || cur != @chain_cursor
        @chain_rev = @editor.edits
        @chain_cursor = cur
        @chain_cache = Fuzz::Template.chain_at(@editor.text, cur)
      end
      @chain_cache
    end

    # The DECODED split sub-pane: the editable payload (SAML XML / GraphQL query+vars),
    # with a badge naming the codec (+ the SAML param/binding) on the top border.
    private def render_decoded(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      label = if @ws_mode
                "MESSAGES"
              elsif @decode_kind == :saml
                "DECODED · SAML XML"
              else
                "DECODED · GraphQL"
              end
      Frame.card(screen, rect, label, bg: Theme.bg, border: pane_border(focused))
      if @ws_mode
        # The seeded frames this pane cannot render as a line. Without this the operator sees
        # an empty (or short) MESSAGES pane and has no way to know a PING, a CLOSE 1002 or an
        # RSV1 frame is still in the seed and still going out — which is precisely the
        # difference between reading a result and misreading one. `ws_line_renderable?` owns
        # the rule; this only says so.
        unshown = ws_unshown_seed
        unless unshown.empty?
          badge = " +#{unshown.size} not shown: #{unshown.join(", ")} "
          bx = {rect.right - badge.size - 1, rect.x + label.size + 4}.max
          screen.text(bx, rect.y, badge, Theme.text_bright, Theme.accent_bg) if bx > rect.x + label.size + 4
        end
      end
      if @decode_kind == :saml
        badge = " #{@saml_param} · #{@saml_binding == :redirect ? "redirect" : "post"} "
        bx = {rect.right - badge.size - 1, rect.x + label.size + 4}.max
        screen.text(bx, rect.y, badge, Theme.text_bright, Theme.accent_bg) if bx > rect.x + label.size + 4
      end
      # XML/JSON-ish payload / WS messages → plain editing (no HTTP request/header colouring).
      @decoded.render(screen, rect.inset(1, 1), cursor: focused, highlight: nil, peek: focused, gauge: true, gauge_focused: focused)
    end

    private def pane_border(focused : Bool, insert : Bool = false) : Color
      return Frame.pane_border(false) unless focused
      insert ? Theme.accent : Theme.focus_gold
    end

    private def render_target(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.h < 2
      ins = focused && target_insert?
      Frame.card(screen, rect, "TARGET", bg: Theme.bg, border: pane_border(focused, insert: ins))
      Frame.mode_badge(screen, rect.right - 1, rect.y, rect.x + 8, ins)
      # An at-a-glance SNI marker on the top border (right of the title) whenever an
      # override is set, so a custom SNI is visible even before the row is reached.
      unless @sni.strip.empty?
        badge = " SNI "
        bx = {rect.right - badge.size - 1, rect.x + 9}.max
        screen.text(bx, rect.y, badge, Theme.text_bright, Theme.accent_bg)
      end
      url_active = focused && @target_field == :url
      sni_active_row = focused && @target_field == :sni
      draw_target_row(screen, rect, rect.y + 1, TARGET_PREFIX, @target, @tcx, url_active, target_insert?)
      draw_target_row(screen, rect, rect.y + 2, SNI_PREFIX, @sni, @scx, sni_active_row, target_insert?) if sni_active? && rect.h >= 4
    end

    # One single-line field row of the TARGET card: a marker prefix, then the value,
    # with the block caret + terminal cursor when this row is the active field.
    private def draw_target_row(screen : Screen, rect : Rect, row : Int32, prefix : String, value : String,
                                cx : Int32, active : Bool, insert : Bool) : Nil
      screen.text(rect.x + 2, row, prefix, active ? Theme.accent : Theme.muted)
      base = field_base(rect, prefix)
      w = {rect.right - base - 1, 1}.max
      if active && !insert
        if span = @target_read.selection_span(cx)
          paint_char_span_bg(screen, base, row, value, span[0], span[1], Theme.accent_bg)
        end
      end
      Highlight.draw(screen, base, row, Highlight.env_line(value, Theme.text_bright), width: w)
      if active
        # column_width — the measure paint_char_span_bg (the selection tint, a few lines up)
        # already uses on this same value in this same render, and the exact inverse of the
        # Screen.column_for that target_click_to_cursor uses to turn a click back into `cx`.
        # display_width scored a zero-width char as 0, so the three disagreed: the tint
        # covered one span, the caret sat a column left of its glyph, and a click landed a
        # character off. A URL carrying U+200B is ordinary traffic for this tool (it is a
        # stock filter-bypass payload), so this is reachable, not theoretical.
        cursor_x = base + Screen.draw_width(value[0, cx])
        if cursor_x < rect.right - 1
          ch = cx < value.size ? value[cx] : ' '
          screen.cell(cursor_x, row, ch, Theme.bg, insert ? Theme.accent : Theme.accent_bg)
          screen.cursor(cursor_x, row)
        end
      end
    end

    # The RESPONSE pane's top-border chrome: keyed toggle chips + the right-aligned
    # latency·size of the last send. Each chip carries its shortcut (history-style:
    # d diff · x hex · p pretty) so the toggle is discoverable in place, and lights
    # when active. Plain response mode needs no chip of its own — it's simply none of
    # these lit (the pane is already titled RESPONSE).
    private def render_response_chrome(screen : Screen, rect : Rect) : Nil
      resp_plain = !@resp_hex && @resp_mode == :response
      diff_lit = !@resp_hex && @resp_mode == :diff
      pretty_lit = resp_plain && !@reveal && resp_pretty_applied?
      x = Frame.chip(screen, rect.x + 12, rect.y, " d:diff ", diff_lit) + 1
      x = Frame.chip(screen, x, rect.y, " ^X:hex ", @resp_hex) + 1
      chips_end = Frame.chip(screen, x, rect.y, " p:pretty ", pretty_lit)
      if result = @result
        meta = result.ok? ? "#{Fmt.dur(result.duration_us)} · #{Fmt.size((result.head.size + (result.body.try(&.size) || 0)).to_i64)}" : Fmt.dur(result.duration_us)
        meta_x = rect.right - meta.size - 1
        screen.text(meta_x, rect.y, meta, Theme.muted, Theme.bg) if meta_x > chips_end + 1
        # A persistent amber marker when the response was cut short (the body the
        # origin sent is incomplete) — the transient send toast scrolls away.
        if result.incomplete?
          warn = "⚠ incomplete"
          warn_x = meta_x - warn.size - 2
          screen.text(warn_x, rect.y, warn, Theme.yellow, Theme.bg) if warn_x > chips_end + 1
        end
      end
    end

    private def render_request_label : String
      return "HANDSHAKE REQUEST" if @ws_mode
      return "GRPC REQUEST" if @grpc_mode
      return "ENVELOPE" if @decode_kind # the full request; the payload is the DECODED split below
      @http2 ? "REQUEST (h2)" : "REQUEST"
    end

    private def render_request(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      label = render_request_label
      ins = focused && request_insert?
      Frame.card(screen, rect, label, bg: Theme.bg, border: pane_border(focused, insert: ins))
      min_x = rect.x + label.size + 4 # keep clear of the pane title on the top border
      right_edge = rect.right - 1     # leave the right border cell untouched
      # Primary action rides the REQUEST border (discoverable without the footer chord):
      # rightmost, a gold button while idle, recessed while a send is in flight.
      send_edge = Frame.action_badge(screen, right_edge, rect.y, min_x, "^R", "SEND", !@inflight)
      if @grpc_mode # head as text; a unary call's payload is hex-editable (^X → MSG/HEX)
        if h = @req_hex_edit
          Frame.toggle_badge(screen, send_edge, rect.y, min_x, "^X", "HEX", true)
          @scroll_req = h.render(screen, rect.inset(1, 1), focused, @scroll_req)
        else
          Frame.toggle_badge(screen, send_edge, rect.y, min_x, "^X", "MSG", false) if @grpc_reframable
          @editor.conceal_spans = [] of {Int32, Int32} # gRPC frames aren't §-marker HTTP text — no stale concealment
          @editor.chain_peek_text = nil
          @editor.render(screen, rect.inset(1, 1), cursor: focused && request_insert?, highlight: :request, peek: focused, gauge: true, gauge_focused: focused)
        end
        return
      end
      if @ws_mode
        # KEY names what happens to the `Sec-WebSocket-Key` line the operator is looking at.
        # OFF (the default) means gori drops it and appends a fresh one, so the key in this
        # editor is NOT the key on the wire — which is worth a badge on its own, because the
        # pane otherwise reads as byte-exact. ON sends the block as written.
        Frame.toggle_badge(screen, send_edge, rect.y, min_x, "␣K", "KEY", @ws_keep_key)
        @editor.conceal_spans = [] of {Int32, Int32} # WS messages aren't §-marker HTTP text — no stale concealment
        @editor.chain_peek_text = nil
        @editor.render(screen, rect.inset(1, 1), cursor: focused && request_insert?, highlight: :request, peek: focused, gauge: true, gauge_focused: focused)
        return
      end
      if h = @req_hex_edit
        Frame.toggle_badge(screen, send_edge, rect.y, min_x, "^X", "HEX", true)
        @scroll_req = h.render(screen, rect.inset(1, 1), focused, @scroll_req)
        return
      end
      cl_x = Frame.toggle_badge(screen, send_edge, rect.y, min_x, "^L", "CL", @auto_content_length)
      mode_x = Frame.toggle_badge(screen, cl_x, rect.y, min_x, "^U", "PRETTY", false)
      mark_x = Frame.mode_badge(screen, mode_x, rect.y, min_x, ins)
      # Only when a `§` is actually in the buffer, so a request without one draws exactly the
      # border it drew before. Unlit = the capture's § are literal bytes (^K declares them);
      # lit = this buffer is a template and ^R renders them. See `markers_live?`.
      if literal_markers? || (@evidence && markers_active?)
        Frame.toggle_badge(screen, mark_x, rect.y, min_x, "^K", "MARK", markers_live?)
      end
      update_request_marker_tint
      inner = rect.inset(1, 1)
      @editor.render(screen, inner, cursor: ins, highlight: :request, peek: focused, gauge: true, gauge_focused: focused)
      paint_request_read_chrome(screen, inner, focused && !ins)
    end

    # READ-mode over-paint (selection tint + block caret) on top of the frame the editor
    # just drew. It inverts `TextArea#last_rows` — the rows that were ACTUALLY laid down —
    # rather than re-deriving `line - scroll`: under soft wrap a screen row is no longer a
    # logical line, and the two derivations drifting apart is precisely how a selection ends
    # up tinting the wrong text. Every span is clipped to its row, so a selection crossing a
    # wrap break is painted on each row it covers.
    private def paint_request_read_chrome(screen : Screen, rect : Rect, active : Bool) : Nil
      return unless active
      ed = req_editor
      lines = ed.lines_snapshot
      return if lines.empty?
      @req_read.sync_from(ed)
      sel_bg = Theme.accent_bg
      rows = ed.last_rows
      return if rows.empty?
      gw = ed.gutter? ? Gutter.width(lines.size) : 0
      spans = @req_read.cursor.highlight_spans(lines)
      cy, cx = ed.cy, ed.cx
      rows.each_with_index do |vr, row|
        y = rect.y + row
        line = lines[vr.li]? || ""
        spans.each do |(li, x0, x1)|
          next unless li == vr.li
          a = {x0, vr.a}.max
          b = {x1, vr.b}.min
          next if a >= b
          paint_char_span_bg(screen, rect.x + gw, y, line, a, b, sel_bg, vr.a)
        end
        # The caret belongs to exactly one row: the one whose slice contains it, with the
        # end of a wrapped row losing to the row it starts (Wrap::Layout#row_of's rule,
        # spelled out here because ReadCursor holds no layout of its own).
        next unless vr.li == cy && cx >= vr.a && (cx < vr.b || vr.b >= line.size)
        px = rect.x + gw + Wrap.row_col(line, nil, vr.a, cx)
        next unless px < rect.x + rect.w
        ch = cx < line.size ? line[cx] : ' '
        screen.cell(px, y, ch, Theme.bg, Theme.accent_bg)
        screen.cursor(px, y)
      end
    end

    # `row_start` is the char index the drawn row begins at — 0 for an unwrapped line, the
    # wrap break for a continuation row. Columns are measured from THERE, so a tint on a
    # continuation row starts at the pane's left edge like the text it covers.
    private def paint_char_span_bg(screen : Screen, x : Int32, y : Int32, line : String,
                                   x0 : Int32, x1 : Int32, bg : Color, row_start : Int32 = 0) : Nil
      return if x0 >= x1
      # Cluster-wise, matching the base draw and the caret. Summing draw_width over single
      # CHARS is exactly the retired per-codepoint measure: it drifts right by each
      # cluster's inflation (1 column for a skin tone, 9 for a ZWJ family), and drawing
      # char-by-char also SHREDS a cluster across cells, stranding a bare combining mark in
      # one of its own. Span edges snap outward so the tint covers whole glyphs.
      a = {Screen.cluster_start(line, {x0, line.size}.min), row_start}.max
      b = Screen.cluster_end(line, {x1, line.size}.min)
      return if a >= b
      px = x + Wrap.row_col(line, nil, row_start, a)
      i = a
      while i < b
        e = Screen.cluster_end(line, i + 1)
        seg = line[i...e]
        screen.text(px, y, seg, Theme.text, bg)
        px += Screen.draw_width(seg)
        i = e
      end
    end

    # §…§ marker tinting: colour each marker in the request editor — the value in the
    # position hue, the ¦chain segment over-painted dimmer. Always on (like the Fuzzer):
    # a marker-free request yields no regions, so this is a no-op paint then.
    private def update_request_marker_tint : Nil
      bg = [] of {Int32, Int32, Color}
      conceal = [] of {Int32, Int32}
      marker_regions.each_with_index do |region, i|
        a, sep, close = region
        bg << {a, close + 1, Theme.marker_bg(i)} # band spans the whole marker; the conceal-aware paint skips hidden cells
        conceal << {sep, close} if sep < close   # hide the ¦chain inline (kept in the buffer → tooltip + ^Y overlay)
      end
      @editor.bg_regions = bg
      @editor.conceal_spans = conceal
      chain = chain_under_cursor
      @editor.chain_peek_text = (chain && !chain.empty?) ? chain : nil # tooltip only for a concealed (non-empty) chain
    end

    # {open, sep, close} marker regions cached on the editor revision — update_request_marker_tint
    # (and request_bytes / chain_split_visible?) read it every render; the cache skips
    # marker_regions' 2× whole-buffer `text.chars` on an unchanged request buffer.
    #
    # Empty while the markers are INERT (see `markers_live?`), which is the one place that
    # decision has to live: every consumer — the send (`request_bytes`), the Content-Length
    # reflection, the tint/conceal paint, `minimizable?`, the editor's delimiter guards —
    # reads it, and they must not be able to disagree about whether a `§` in this buffer is
    # syntax or data.
    private def marker_regions : Array({Int32, Int32, Int32})
      return NO_REGIONS unless markers_live?
      if @editor.edits != @marker_regions_rev
        @marker_regions_rev = @editor.edits
        @marker_regions_cache = Fuzz::Template.marker_regions(@editor.text)
      end
      @marker_regions_cache
    end

    NO_REGIONS = [] of {Int32, Int32, Int32}
    NO_SPANS   = [] of {Int32, Int32}

    private def render_ws_handshake(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "HANDSHAKE RESPONSE", bg: Theme.bg, border: pane_border(focused))
      if result = @result
        meta = result.ok? ? "#{Fmt.dur(result.duration_us)} · #{Fmt.size((result.head.size + (result.body.try(&.size) || 0)).to_i64)}" : Fmt.dur(result.duration_us)
        meta_x = rect.right - meta.size - 1
        screen.text(meta_x, rect.y, meta, Theme.muted, Theme.bg) if meta_x > rect.x + 22
      end
      body = rect.inset(1, 1)
      rv = resp_view
      total = rv.total
      gw = Settings.show_gutter ? {Gutter.width(total), body.w}.min : 0
      cw = {body.w - gw, 0}.max
      return if cw <= 0
      # This card is always pinned to the top of the handshake response and has its own
      # tiny window, so it wraps from row 0 with a local layout rather than sharing the
      # transcript's anchor + memo (different line source, ≤7 rows to lay out).
      rows = Wrap.rows(0, 0, body.h, total, ->(i : Int32) { Wrap.layout(rv.line_text(i), cw) })
      rows.each_with_index do |vr, i|
        if gw > 0
          if vr.sub == 0
            Gutter.draw(screen, body.x, body.y + i, vr.li, gw)
          else
            screen.text(body.x, body.y + i, " " * {gw - 1, 0}.max, Theme.muted, width: gw)
          end
        end
        # slice_chars is the identity for a row that IS the whole line, so an unwrapped
        # handshake header costs nothing extra.
        shown = Highlight.slice_chars(styled_resp_line(rv, vr.li), vr.a, vr.b)
        Highlight.draw(screen, body.x + gw, body.y + i, shown, width: cw)
      end
    end

    private def render_response(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      if @ws_mode
        handshake_rect, transcript_rect = ws_resp_split(rect)
        render_ws_handshake(screen, handshake_rect, focused)
        render_transcript(screen, transcript_rect, focused, "TRANSCRIPT", ws_transcript_lines, @ws_result.try(&.duration_us))
        return
      end
      if @grpc_mode
        render_transcript(screen, rect, focused, "GRPC RESPONSE", grpc_transcript_lines, @result.try(&.duration_us))
        return
      end
      if group_mode?
        g = @group_results.not_nil!
        total = g.sum(&.[1].duration_us)
        render_transcript(screen, rect, focused, "GROUP · #{g.size} req", group_transcript_lines, total)
        return
      end
      Frame.card(screen, rect, "RESPONSE", bg: Theme.bg, border: pane_border(focused))
      render_response_chrome(screen, rect)
      body = rect.inset(1, 1)
      if @resp_hex
        (b = resp_hex_bytes) ? HexView.render(screen, body, b, @scroll) : screen.text(body.x, body.y, "— not sent — press ^R to resend —", Theme.muted)
      elsif @resp_mode == :diff
        render_diff(screen, body, focused)
      elsif @reveal && (rl = reveal_lines)
        render_reveal(screen, body, rl, focused)
      else
        render_response_body(screen, body, focused)
      end
      Frame.scroll_gauge(screen, body, resp_line_count, @scroll, focused)
    end

    # Shared windowed renderer for the WS / gRPC transcript panes (a list of
    # {text, colour} rows, scrolled by @scroll). `dur_us` rides the top border.
    private def render_transcript(screen : Screen, rect : Rect, focused : Bool,
                                  title : String, lines : Array({String, Color}), dur_us : Int64?) : Nil
      Frame.card(screen, rect, title, bg: Theme.bg, border: pane_border(focused))
      if d = dur_us
        meta = Fmt.dur(d)
        mx = rect.right - meta.size - 1
        screen.text(mx, rect.y, meta, Theme.muted, Theme.bg) if mx > rect.x + title.size + 4
      end
      body = rect.inset(1, 1)
      return if body.h <= 0
      if lines.empty?
        screen.text(body.x, body.y, "— not sent — press ^R to resend —", Theme.muted)
        return
      end
      gw = Settings.show_gutter ? {Gutter.width(lines.size), body.w}.min : 0
      cw = {body.w - gw, 0}.max
      @resp_last_h = body.h
      resp_record_metrics(gw, cw)
      return if cw <= 0
      sel_spans = resp_sel_spans_if(focused)
      resp_rows(cw, body.h, lines.size, ->(i : Int32) { lines[i][0] }).each_with_index do |vr, i|
        text, color = lines[vr.li]
        y = body.y + i
        draw_resp_gutter(screen, body.x, y, gw, vr, focused)
        screen.text(body.x + gw, y, text[vr.a...vr.b], color, width: cw)
        paint_resp_line_chrome(screen, body.x + gw, y, vr.li, text, focused, sel_spans, vr.a, vr.b)
        Wrap.mark_search(screen, body.x + gw, y, text, vr.a, vr.b, @search_hl, body.x + gw + cw) unless @search_hl.empty?
      end
      Frame.scroll_gauge(screen, body, lines.size, @scroll, focused)
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
          rows << {"HTTP #{st}", st >= 400 ? Theme.red : Theme.text}
          grpc_response_rows(result).each { |r| rows << r }
          rows << grpc_status_row(result)
        end
        rows
      end
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
          head_color = res.error ? Theme.red : ((st && st >= 400) ? Theme.yellow : Theme.green)
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

    # `scan`, not `messages`: `messages` throws away the residual — the tail bytes that are
    # not a complete frame — so a deliberately-wrong length prefix (a standard gRPC parser
    # test) rendered as a bare "(no complete gRPC messages)" with no byte count, which reads
    # identically to "this response is not gRPC at all". `gori run show --format json`
    # already reports it; this is the pane that shows the same response.
    private def grpc_response_rows(result : Repeater::Result) : Array({String, Color})
      rows = [] of {String, Color}
      msgs, residual = Proxy::H2::Grpc.scan(result.body || Bytes.empty)
      if msgs.empty? && residual == 0
        rows << {"← (no complete gRPC messages)", Theme.muted}
      else
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
            grpc_hex_preview(m.data).each { |h| rows << {h, Theme.muted} }
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

    # Windowed render of revealed (whitespace-visible) response lines.
    private def render_reveal(screen : Screen, rect : Rect, lines : Array(String), focused : Bool) : Nil
      total = lines.size
      @resp_last_h = rect.h
      gw = Settings.show_gutter ? {Gutter.width(total), rect.w}.min : 0
      cw = {rect.w - gw, 0}.max
      resp_record_metrics(gw, cw)
      return if cw <= 0
      sel_spans = resp_sel_spans_if(focused)
      # Reveal substitutes a 1-column marker for every control char (tab → '→', CR → '␍'),
      # which is exactly what `Screen.grapheme_cols` already scores them, so the wrap of the
      # RAW line and the wrap of the revealed line are the same break — no second layout.
      resp_rows(cw, rect.h, total, ->(i : Int32) { lines[i] }).each_with_index do |vr, i|
        y = rect.y + i
        line = lines[vr.li]
        draw_resp_gutter(screen, rect.x, y, gw, vr, focused)
        # `last` only on the row that actually ends the line — the ␊ marker belongs at the
        # true end of the line, not at every wrap break inside it.
        eol = vr.b >= line.size && vr.li < total - 1
        Highlight.draw(screen, rect.x + gw, y, Reveal.styled(line[vr.a...vr.b], eol, cw), width: cw)
        paint_resp_line_chrome(screen, rect.x + gw, y, vr.li, line, focused, sel_spans, vr.a, vr.b)
        Wrap.mark_search(screen, rect.x + gw, y, line, vr.a, vr.b, @search_hl, rect.x + gw + cw) unless @search_hl.empty?
      end
    end

    # Revealed response lines, cached + rebuilt only when the response bytes change.
    private def reveal_lines : Array(String)?
      bytes = resp_hex_bytes
      return nil unless bytes
      cached = @reveal_lines
      return cached if cached && @reveal_lines_src == bytes.to_unsafe
      @reveal_lines_src = bytes.to_unsafe
      @reveal_lines = Reveal.lines(bytes)
    end

    # Ceiling on the styled-body memo. A visible window is ~tens of lines, so this covers
    # many screens of local scroll while capping memory on a huge response; on overflow the
    # whole memo is dropped (the next frame re-styles just the visible window — cheap).
    RESP_STYLED_CACHE_CAP = 2048

    # The styled line at absolute index `li`, memoized for BODY lines. Head lines are already
    # materialised (RespView#line_at returns the pre-built array), so they skip the memo.
    private def styled_resp_line(rv : RespView, li : Int32) : Highlight::Line
      return rv.line_at(li) if li < rv.head.size
      if cached = @resp_styled_cache[li]?
        return cached
      end
      @resp_styled_cache.clear if @resp_styled_cache.size >= RESP_STYLED_CACHE_CAP
      @resp_styled_cache[li] = rv.line_at(li)
    end

    # Steady-scroll hot path: only materialises/styles VISIBLE lines. Selection spans
    # are computed once per frame (lazy line_at over the selected range only).
    private def render_response_body(screen : Screen, rect : Rect, focused : Bool) : Nil
      rv = resp_view
      total = rv.total
      @resp_last_h = rect.h
      gw = Settings.show_gutter ? {Gutter.width(total), rect.w}.min : 0
      cw = {rect.w - gw, 0}.max
      resp_record_metrics(gw, cw)
      return if cw <= 0
      sel_spans = resp_sel_spans_if(focused)
      # The wrap is computed on the PLAIN text (`line_text`) and the styled overlay is then
      # sliced to the same char range — Highlight is a 1:1 colour overlay, so one layout
      # describes both and the colours cannot land a column off the glyphs.
      resp_rows(cw, rect.h, total, ->(i : Int32) { rv.line_text(i) }).each_with_index do |vr, i|
        li = vr.li
        y = rect.y + i
        need_plain = (focused && resp_navigable? && (li == @resp_cursor.cy || sel_spans)) || !@search_hl.empty?
        text = need_plain ? rv.line_text(li) : nil
        draw_resp_gutter(screen, rect.x, y, gw, vr, focused)
        shown = Highlight.slice_chars(styled_resp_line(rv, li), vr.a, vr.b)
        Highlight.draw(screen, rect.x + gw, y, shown, width: cw)
        paint_resp_line_chrome(screen, rect.x + gw, y, li, text, focused, sel_spans, vr.a, vr.b) if text
        if (t = text) && !@search_hl.empty?
          Wrap.mark_search(screen, rect.x + gw, y, t, vr.a, vr.b, @search_hl, rect.x + gw + cw)
        end
      end
    end

    # Response-pane gutter: the row number rides the FIRST visual row of a logical row only
    # (Burp style); a continuation gets a blank of the same width so the text column stays
    # put and no stale digits survive there.
    private def draw_resp_gutter(screen : Screen, x : Int32, y : Int32, gw : Int32,
                                 vr : Wrap::Row, focused : Bool) : Nil
      return if gw <= 0
      if vr.sub == 0
        Gutter.draw(screen, x, y, vr.li, gw, current: focused && vr.li == @resp_cursor.cy)
      else
        screen.text(x, y, " " * {gw - 1, 0}.max, Theme.muted, width: gw)
      end
    end

    # Selection tint + block caret for ONE drawn row. `rs`/`re` bound the row's slice of the
    # line (the whole line when nothing wrapped), so a selection spanning a wrap break is
    # painted on each row it covers and the caret paints on exactly one of them — the row
    # that STARTS at its column, matching Wrap::Layout#row_of.
    private def paint_resp_line_chrome(screen : Screen, x : Int32, y : Int32, li : Int32, line : String,
                                       focused : Bool, sel_spans : Array({Int32, Int32, Int32})? = nil,
                                       rs : Int32 = 0, re : Int32 = -1) : Nil
      return unless focused && resp_navigable?
      re = line.size if re < 0
      if spans = sel_spans
        spans.each do |(l, x0, x1)|
          next unless l == li
          a = {x0, rs}.max
          b = {x1, re}.min
          paint_char_span_bg(screen, x, y, line, a, b, Theme.accent_bg, rs) if a < b
        end
      end
      return unless li == @resp_cursor.cy
      cx = @resp_cursor.cx.clamp(0, line.size)
      return unless cx >= rs && (cx < re || re >= line.size)
      px = x + Wrap.row_col(line, nil, rs, cx)
      ch = cx < line.size ? line[cx] : ' '
      screen.cell(px, y, ch, Theme.bg, Theme.accent_bg)
      screen.cursor(px, y)
    end

    # Selection spans once per frame (lazy line_at; only selected range materialised).
    private def resp_sel_spans_if(focused : Bool) : Array({Int32, Int32, Int32})?
      return nil unless focused && resp_navigable? && @resp_cursor.selection?
      size, line_at = resp_line_source
      @resp_cursor.highlight_spans(size, line_at)
    end

    # The diff pane draws a 2-column "+ "/"- " decoration in front of each line, so the
    # wrapped row is a slice of `full` (decoration + text) while the caret, selection and
    # search all address `text`. The two coordinate systems differ by exactly 2 characters
    # of width 1 each — that constant is the ONLY place they are reconciled, here.
    DIFF_PREFIX_COLS = 2

    private def render_diff(screen : Screen, rect : Rect, focused : Bool) : Nil
      data = diff_lines
      gw = Settings.show_gutter ? {Gutter.width(data.size), rect.w}.min : 0
      cw = {rect.w - gw, 0}.max
      @resp_last_h = rect.h
      resp_record_metrics(gw, cw)
      return if cw <= 0
      sel_spans = resp_sel_spans_if(focused)
      # The pane scrolls in rows of the DECORATED line, so that is what the anchor, the wrap
      # memo and the click inverse all index — `resp_line_source` hands out the bare text,
      # which is 2 columns narrower and would wrap at different offsets. `resp_drawn_source`
      # is the single definition of that; using it here keeps render and hit-testing on one
      # grid instead of two that agree until a line is exactly pane-wide.
      _, decorated, _ = resp_drawn_source
      resp_rows(cw, rect.h, data.size, decorated).each_with_index do |vr, i|
        d = data[vr.li]
        y = rect.y + i
        color = case d.kind
                when .add? then Theme.green
                when .del? then Theme.red
                else            Theme.muted
                end
        draw_resp_gutter(screen, rect.x, y, gw, vr, focused)
        screen.text(rect.x + gw, y, decorated.call(vr.li)[vr.a...vr.b], color, width: cw)
        # Re-base the row onto `text`: on the first row the text starts DIFF_PREFIX_COLS in,
        # on a continuation it starts at the pane edge.
        tx = rect.x + gw + {DIFF_PREFIX_COLS - vr.a, 0}.max
        ts = {vr.a - DIFF_PREFIX_COLS, 0}.max
        te = {vr.b - DIFF_PREFIX_COLS, 0}.max
        paint_resp_line_chrome(screen, tx, y, vr.li, d.text, focused, sel_spans, ts, te)
        # Mark only the line text, so the highlights match what response_search_lines
        # counts (d.text) rather than the diff decoration.
        Wrap.mark_search(screen, tx, y, d.text, ts, te, @search_hl, rect.x + gw + cw) unless @search_hl.empty?
      end
    end

    # --- content ------------------------------------------------------------

    # The visible line count of the active response view (drives the scroll bound).
    private def resp_line_count : Int32
      if @ws_mode
        {ws_transcript_lines.size, 1}.max
      elsif @grpc_mode
        {grpc_transcript_lines.size, 1}.max
      elsif @resp_hex
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
          Repeater::Diff.lines(baseline, message_lines(result.head, display_body(result.head, result.body)))
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
end
