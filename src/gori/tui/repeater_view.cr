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
require "./comparer_slot" # a send can be handed to the Comparer as one side of a diff
require "../fuzz"
require "../decoder"
require "./chain_pane"
require "./chain_overlay"
require "./input_mode"
require "./read_cursor"
require "./text_read_state"
require "./line_field_read"
require "./subtab_clone"
# The class body continues in `repeater_view/` — one class-reopen file per slice, the same
# shape `runner.cr` uses. This file keeps the state (ivars + initialize) every slice reads.
require "./repeater_view/content"
require "./repeater_view/decode"
require "./repeater_view/focus"
require "./repeater_view/geometry"
require "./repeater_view/group"
require "./repeater_view/grpc"
require "./repeater_view/hex"
require "./repeater_view/markers"
require "./repeater_view/pointer"
require "./repeater_view/read_copy"
require "./repeater_view/reflect"
require "./repeater_view/render"
require "./repeater_view/render_request"
require "./repeater_view/render_response"
require "./repeater_view/request_edit"
require "./repeater_view/response"
require "./repeater_view/response_wrap"
require "./repeater_view/search"
require "./repeater_view/send"
require "./repeater_view/session"
require "./repeater_view/target_field"
require "./repeater_view/ws"

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
      # …and the horizontal offset it replaced, back for the operator who turns wrap off
      # (Preferences ▸ Appearance ▸ Display). The two are each other's dead state — a wrapped
      # row has nothing off to the side, an unwrapped one has no continuation rows — so each
      # render branch zeroes the one it isn't using. Moved only by the caret
      # (ensure_resp_visible_x); the ⇧←/→ h-scroll binding this pane used to carry is gone for
      # good, since ⇧←/→ now extends the read selection.
      @resp_xscroll = 0
      @resp_wrap = {} of Int32 => Wrap::Layout # per-row wrap memo, keyed by the width below
      @resp_wrap_w = -1
      # One-entry memo for the PLAIN text of a response line — see `resp_line_text`.
      @resp_text_i = -1
      @resp_text = ""
      # Gutter + content width from the LAST render of whichever response pane is active.
      # Hit-testing and the scroll walkers read these rather than re-deriving them, because
      # the per-mode line counts the gutter is sized from are not all the same
      # (`resp_line_count` has no group-transcript branch, for one) and the wrap memo is
      # KEYED on the content width — a click that recomputed a different width would not
      # merely land a column off, it would flush and rebuild the memo at a width the anchor
      # was never laid out against.
      @resp_last_gw = 0
      @resp_last_cw = 0
      # Which card of a split RESPONSE column is being read (WebSocket only — see resp_split?).
      # Starts on the transcript: that is what an operator opens a WS tab to read, and it keeps
      # a non-WS tab's behaviour literally unchanged.
      @resp_pane = :transcript
      # The INACTIVE response sub-pane's parked {scroll, scroll_sub, cy, cx}. The active pane's
      # copy lives in the live fields, so every existing consumer of `@scroll` / `@resp_cursor`
      # keeps reading them with no idea a second pane exists; `switch_resp_pane` swaps the two.
      # Parked rather than reset, mirroring the request column — each TextArea there keeps its
      # own caret and scroll, so crossing back lands where you left.
      @resp_alt = {0, 0, 0, 0}
      @loaded = false
      @http2 = false
      # WebSocket repeater CONTENT (a 101 flow): this tab holds a handshake plus an editable
      # outbound MESSAGES list. It says what the tab IS, not what `^R` does with it — read
      # `ws_mode?` for that, and see `@ws_http_only` for the difference.
      @ws_mode = false
      # …and the operator's override of it: send the handshake as an ordinary HTTP request
      # (h1 or h2, per `@http2`) and read the response as a response, instead of dialing
      # `WsEngine` and pumping frames. `^V` cycles WS → HTTP/1.1 → HTTP/2 → WS.
      #
      # A handshake IS an HTTP request, and "does this endpoint 101 for an unauthenticated
      # Origin?" is an HTTP question — one that could not be asked here, because auto-detection
      # gated the whole tab: diff, pretty-print, hex edit, minimize, group send, Match&Replace
      # and the h1/h2 toggle are all off in WS mode, and every one of them is a thing you want
      # while testing a handshake. The override switches those back on by making `ws_mode?`
      # false; `@ws_mode` stays true, so the frames are still here and still persisted.
      #
      # It changes NO BYTES. The `Upgrade:` header goes out exactly as authored — this is the
      # engine gori dials, not a rewrite of the request. (In this mode `@ws_keep_key` is moot:
      # `Engine` sends the head verbatim, so the key line in the editor is the key on the wire.)
      @ws_http_only = false
      @ws_upgrade = nil.as(Bytes?) # the captured upgrade-request bytes (handshake source)
      @ws_result = nil.as(Repeater::WsEngine::Result?)
      @ws_lines_cache = nil.as(Array({String, Color})?)
      @transcript_rev = Theme.revision # theme the colour-baked transcript cache was built under
      # gRPC repeater mode (an application/grpc h2 flow): the editor holds the editable
      # request HEAD (metadata headers) and the framed message body is sent byte-exact
      # from @grpc_body; the response pane shows a deframed gRPC transcript + status.
      # Session-only like WS (db_id nil) — the binary body can't round-trip the text store.
      @grpc_mode = false
      @grpc_body = Bytes.empty # the pristine WIRE request body, sent verbatim
      @grpc_msg_count = 0      # deframed message count of the body (immutable → computed once)
      @grpc_req_residual = 0   # …and the tail that is NOT a complete frame
      # `application/grpc-web-text`: the frames are base64 ON THE WIRE. @grpc_body stays the
      # captured (encoded) bytes — deframing decodes first, and a reframed payload is
      # re-encoded on the way out, so the two never mix.
      @grpc_web_text = false
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
      # The `$NAME` twin of the two above, and a SET rather than a latch or a count because
      # `$` is the one draft syntax whose tokens carry their own identity: `$filter` in a
      # captured OData query and `$TOKEN` an operator types into the same buffer are
      # different tokens, so the question "did the operator author this?" is answerable per
      # NAME instead of per buffer. Baseline = the names the CAPTURE arrived with; empty on a
      # draft, where every `$` is the operator's by definition. See `operator_env_vars`.
      @evidence_env_names = Set(String).new
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
  end
end
