require "./screen"
require "./theme"
require "./frame"
require "./highlight"
require "./wrap"
require "../env"
require "../settings"
require "./gutter"
require "./read_cursor"
require "./reveal"
require "./env_complete"
require "./env_peek"
require "./chain_peek"

module Gori::Tui
  # A minimal multi-line text editor for inline editing (e.g. the Repeater
  # request). Holds lines + a cursor; no modes — typing edits directly. Converts
  # back to bytes with CRLF line endings (HTTP wire form).
  class TextArea
    # Snapshot for undo. Holds the LINE ARRAY (a shallow copy), not a joined-buffer String:
    # line Strings are immutable and every edit REPLACES `@lines[i]` (never mutates in place),
    # so unchanged lines are structurally shared across all 100 snapshots. This turns push_undo
    # from a whole-buffer String copy per keystroke (and up to 100 full-buffer copies retained)
    # into an Array-of-pointers copy that shares the line data. `eols` rides along for the same
    # reason and at the same cost: an Array of pointers into a handful of shared literals.
    record UndoState, lines : Array(String), eols : Array(String), cy : Int32, cx : Int32

    # The terminator a NEWLY typed line break gets (`insert_newline`). LF, not CRLF, because
    # the wire promotion of the HEAD is `Env.expand_wire`'s job and it is the only thing that
    # knows where the head ends — a break typed into a BODY is a body byte and must stay one.
    DEFAULT_EOL = "\n"

    # One DRAWN row — see `Wrap::Row`. Aliased rather than redeclared so this editor and
    # the Repeater's response pane cannot grow two slightly different ideas of a row.
    alias VRow = Wrap::Row

    # Ceiling on the per-line wrap memo. A visible window is tens of rows, so this covers
    # many screens of local scroll while capping memory; on overflow the whole memo is
    # dropped and the next frame re-wraps just the visible window (cheap — see `layout_of`).
    WRAP_CACHE_CAP = 512

    def initialize(text : String = "")
      @lines = [""]
      @eols = [""]
      @cy = 0
      @cx = 0
      @scroll = 0
      @xscroll = 0      # leftmost visible display COLUMN (horizontal scroll); only moves when @follow_x is on
      @last_h = 0       # viewport height from the last render — lets scroll_view (wheel) clamp
      @last_cw = 0      # content width from the last render — the wrap mappings outside render need it
      @follow_x = false # follow the cursor horizontally (long lines scroll into view); off ⇒ legacy right-clip
      # --- soft wrap (opt-in; see `wrap=`) -------------------------------------
      # Off by default, so every editor that does NOT ask for it keeps @xscroll/@follow_x
      # and renders byte-for-byte as before. On, a logical line spills onto as many visual
      # rows as it needs and @xscroll is pinned at 0 — the two are mutually exclusive by
      # construction, not by convention.
      @wrap = false
      # THE scroll anchor when wrapping: the top visible row is row @scroll_sub of logical
      # line @scroll. A (line, sub-row) pair IS a visual-row coordinate — it is Vim's
      # topline+skipcol and VS Code's line-map — and it is deliberately not a FLAT visual
      # row index, because a flat index can only be produced by wrapping every line from the
      # top of the buffer. That is an O(whole document) pass on every width change and every
      # edit, over bodies that reach multiple MB; with the anchor, scrolling, ensure_visible
      # and hit-testing are all O(viewport height). Always 0 when @wrap is off, so @scroll
      # keeps its old meaning for the seven owners that read it.
      @scroll_sub = 0
      @wrap_cache = {} of Int32 => Wrap::Layout
      @wrap_rev = -1 # @edits the memo was built for
      @wrap_w = -1   # content width the memo was built for
      @line_offs = [] of Int32
      @line_off_rev = -1
      @last_rows = [] of VRow
      @preedit = ""
      # Cached syntax-highlight overlay (1:1 with @lines), rebuilt only when the
      # buffer content changes — not on every render frame. @styled_kind tracks
      # which highlight symbol it was built for.
      @styled = nil.as(Highlight::Windowed?)
      # One-entry memo over `Windowed#line_at`. Under WRAP one logical line becomes N visual
      # rows and the draw loop asks for the same `li` once per row, and `line_at` re-runs the
      # body tokenizer every time — so a 4 KB minified JSON line filling a 40-row pane was 40
      # identical tokenisations per frame, where the old eager array cost nothing on a frame
      # that changed no text. Consecutive rows share `li`, so one slot is all it takes.
      # Cleared with @styled, whose identity is what makes the memo valid.
      @styled_line_li = -1
      @styled_line = nil.as(Highlight::Line?)
      @styled_kind = nil.as(Symbol?)
      @styled_rev = Theme.revision
      @styled_env_rev = Env.highlight_rev
      @gutter = false          # left line-number gutter (on for the Repeater request body)
      @search_hl = ""          # active ^F query → matches highlighted in render
      @reveal = false          # show whitespace (space ·, tab →) instead of syntax colours
      @edits = 0               # monotonic content-change counter — cheap cache key for owners
      @lc_lines = [] of String # downcased lines for ^F search, memoized on @edits
      @lc_lines_rev = -1
      # Opt-in background tints: [start, end) FULL-buffer char offsets + colour, painted
      # UNDER the text (over syntax/plain, beneath search + cursor). Empty for every editor
      # except the Fuzzer template — Repeater/Notes never set it, so they're unaffected. The
      # widget knows nothing about §-markers; the owner supplies offsets + resolved colours.
      @bg_regions = [] of {Int32, Int32, Color}
      # Opt-in DISPLAY concealment: [start, end) FULL-buffer char offsets hidden from the
      # rendered line while kept verbatim in the buffer (so `to_bytes`/send are unchanged).
      # Empty for every editor except the Repeater/Fuzzer request editors, which hide the
      # `¦chain` segment of a §…§ marker (only `§value§` shows; the chain rides a tooltip +
      # the ^Y overlay). All column math (caret, click, h-scroll, marker band) is remapped
      # to the concealed line; when empty the widget is byte-for-byte unchanged.
      @conceal_spans = [] of {Int32, Int32}
      # The FIXED end of an INSERT-mode selection ({cy, cx}), or nil when nothing is
      # selected; the moving end is the caret itself, so there is exactly one copy of each
      # coordinate. nil for every editor that never calls `move(..., selecting: true)`, and
      # every path this adds is one nil check behind that — an editor without a selection
      # renders and edits byte-for-byte as before.
      #
      # This layer, not the owner's `ReadCursor`, is where an INS selection belongs, for
      # three reasons that all point the same way: deleting or replacing one is a BUFFER
      # mutation and undo/@edits/@styled/@conceal live here; painting one needs the wrap
      # layout (`layout_of`, `Wrap.row_col`), which only this file has; and the READ-mode
      # over-painter that draws the NOR selection is called with `focused && !insert`, so in
      # INS nothing outside this editor paints at all. The read-mode model stays exactly
      # where it is — the two never coexist (see `render`, which draws this one only when
      # the block caret is on, i.e. only in INS).
      @sel_anchor = nil.as({Int32, Int32}?)
      # The caret position the next typed character must land on to JOIN the undo step
      # already on the stack, or nil when no typing run is open — see `push_undo`.
      @coalesce = nil.as({Int32, Int32}?)
      @coalesce_len = 0
      @undo_stack = [] of UndoState
      # Opt-in `$ENV` autocomplete popup (nil = disabled). Enabled only on the outbound
      # request editors (Repeater request, Fuzzer template) where env tokens are expanded on
      # send; every other editor keeps it nil so its edit path is byte-for-byte unchanged.
      # `$NAME`s this editor's OWNER will NOT substitute on send (empty for every editor that
      # substitutes them all). The peek and the syntax colour both consult it, so a token the
      # wire will carry literally is not painted — or tooltipped — as a resolved variable.
      # Fed by the Repeater's evidence baseline; see `RepeaterView#operator_env_vars`.
      @env_literal_names = Set(String).new
      @env_complete = nil.as(EnvComplete?)
      # Opt-in `$ENV` value peek (nil = disabled). Paired with @env_complete — the same
      # request editors get it. Shows the resolved value of a COMPLETE `$KEY` token under
      # the caret (NORMAL or INSERT) once the autocomplete dropdown isn't offering matches.
      @env_peek = nil.as(EnvPeek?)
      # Opt-in chain tooltip (nil = disabled). Paired with @conceal_spans on the request
      # editors: reveals the hidden ¦chain of the §…§ marker under the caret. @chain_peek_text
      # is fed by the owner each frame (nil = caret not in a marker → no tooltip).
      @chain_peek = nil.as(ChainPeek?)
      @chain_peek_text = nil.as(String?)
      @chain_peek_hint = ChainPeek::DEFAULT_HINT
      # Characters the LAST `insert` replaced (0 when it replaced nothing). Read by the owner
      # right after the call, exactly the way owners already check `edits` around `backspace`
      # — this widget has no route to the shell and must not grow one, so it reports the fact
      # and the controller decides whether to say anything about it.
      @last_replaced = 0
      set_text(text)
    end

    setter gutter : Bool
    setter search_hl : String
    setter reveal : Bool
    setter bg_regions : Array({Int32, Int32, Color})
    # Enable horizontal cursor-following (the Decoder/JWT inputs); off everywhere
    # else, so those editors keep @xscroll == 0 and their hot render path unchanged.
    # Ignored while wrap is on — a wrapped line has nothing off to the side.
    setter follow_x : Bool

    # …and ON, unasked, for an editor that opted into wrap while the Display preference has
    # wrap switched off. Every one of those panes REPLACED a `follow_x` pan when it started
    # wrapping (their constructors say so), and the ⇧←/→ h-scroll bindings went with it — so
    # without this the operator would be left with a right-clipped line and no way to reach
    # its tail, which is neither of the two models on offer.
    private def follow_x? : Bool
      @follow_x || (@wrap && !Settings.wrap_lines?)
    end

    getter edits : Int32
    # Characters the last `insert` replaced — see the ivar's note. Owners report a MULTI-char
    # replace ("^Z to undo"); a 1-char one is ordinary typing over a selection and stays quiet.
    getter last_replaced : Int32
    getter cy : Int32
    getter cx : Int32
    getter scroll : Int32
    getter? gutter : Bool
    getter? wrap : Bool
    # The rows this editor drew on its LAST frame, in screen order (index == row offset
    # from `rect.y`). Published so an owner that over-paints on top of the editor — the
    # Repeater's READ-mode selection tint and caret — inverts exactly the layout that was
    # drawn instead of re-deriving it and drifting. Empty before the first render.
    getter last_rows : Array(VRow)

    # Turn soft wrap on for THIS editor. Long lines spill onto continuation rows instead of
    # being clipped (or side-scrolled) at the right edge; the line number stays on the first
    # visual row only. Enabled for the Repeater request/decoded editors, where the whole
    # point of the pane is that a long header or a minified body is readable at a glance;
    # every other editor leaves it off and is unaffected.
    #
    # Turning it on pins @xscroll at 0 for good: with wrap there is nothing to the side of
    # the viewport, and leaving a stale offset behind would shift every row left by it.
    def wrap=(on : Bool) : Nil
      return if @wrap == on
      @wrap = on
      @xscroll = 0
      @scroll_sub = 0
      @wrap_cache.clear
    end

    # Conceal ranges arrive fresh from the owner every frame and are derived from the
    # buffer, but NOT always via an edit: toggling ^K (markers live ⇄ inert) swaps them
    # wholesale without touching @edits. The wrap memo is keyed on @edits, so it has to be
    # dropped here too — a stale layout would keep reserving cells for a chain that is no
    # longer hidden (or hiding one that is).
    def conceal_spans=(spans : Array({Int32, Int32})) : Nil
      @wrap_cache.clear if @wrap && spans != @conceal_spans
      @conceal_spans = spans
    end

    # The exact LF form `set_text` would store for `text` — the single source of truth for
    # "does this incoming string already match what the buffer holds?" **as a document**.
    #
    # Compare against `#text`, never `#wire_text`: this deliberately erases line endings, and
    # a caller that needs "would set_text be a no-op, byte for byte" wants `wire_text == s`
    # instead (the Repeater's reconcile, which persists wire form and so can be exact).
    #
    # The DOCUMENT reconcile paths (FuzzerView#session_side_matches? / #apply_peer_session,
    # NotesView#soft_merge_from) compare an incoming store string against `#text` BEFORE
    # calling set_text, because set_text zeroes the caret + scroll and CLEARS THE UNDO STACK.
    # `#text` is always LF while the store can hold wire CRLF — MCP create_note + update_note,
    # `gori run notes create` piping a raw request or a CRLF file, import, or a peer session
    # all write the body verbatim. So a raw `==` is falsely unequal on EVERY poll, the guard
    # never fires, and the caret is slammed back to 0,0 (and undo wiped) on every data_version
    # tick (~1.3×/s while capturing). Lives here, next to set_text, because set_text is what
    # defines the answer: the two cannot drift.
    #
    # Mirrors set_text's split/rstrip rather than a blanket \r→\n gsub deliberately: a LONE \r
    # mid-line is data set_text KEEPS on the line, whereas a gsub would split it into a second
    # line and report a spurious mismatch — the very false-negative this exists to kill. The
    # LAST segment is left alone for the same reason: nothing follows it, so a trailing `\r`
    # there terminates no line — it is a byte, and set_text stores it as one.
    def self.normalize_lf(text : String) : String
      return text unless text.includes?('\r') # the overwhelmingly common case — no allocation
      parts = text.split('\n')
      last = parts.size - 1
      parts.map_with_index { |p, i| i == last ? p : p.rstrip('\r') }.join('\n')
    end

    # NOTE: `self.normalize_lf` above mirrors this split — keep them in step.
    #
    # The `\r` stripped off each line is NOT discarded: it is moved into `@eols[i]`, the exact
    # terminator that followed line i in `text`. `@lines` stays the CR-FREE projection every
    # render/column/search path in this file already assumes, so nothing below changes; but
    # `#wire_text` can now hand back the bytes that came in, and it is the EXACT inverse of
    # this method.
    #
    # The old code destroyed those CRs outright, on the belief that a text editor's buffer is
    # a list of lines and a line ending is a rendering detail. That is true of the HEAD of an
    # HTTP message and false of its BODY, where 0x0D is data — and this editor holds both in
    # one buffer. So a captured `line1\r\nline2` came back as `line1\nline2`, `Content-Length`
    # was resynced DOWN to match, and the Repeater's "byte-exact resend" put a request on the
    # wire that the operator never captured. Request smuggling, CRLF-in-body and every binary
    # format that uses 0x0D were untestable from the TUI for exactly this reason.
    def set_text(text : String) : Nil
      @lines, @eols = split_wire(text)
      @cy = 0
      @cx = 0
      @scroll = 0
      @scroll_sub = 0
      @xscroll = 0
      @preedit = ""
      @styled = nil
      @edits += 1
      @sel_anchor = nil # the anchor indexes the OLD buffer — it names nothing in this one
      @undo_stack.clear
      # Drop stale conceal offsets — they index the OLD buffer; the owner re-feeds fresh
      # ones next render. Guards any move/place between now and that render.
      @conceal_spans = [] of {Int32, Int32} unless @conceal_spans.empty?
      break_run # a caret move ends the typing run — see push_undo
      env_complete_close
    end

    # Preedit/composing text from IME (e.g. current Hangul syllable while typing jamo).
    # Rendered after the current line's text at cursor, with composing style (underline).
    # Cleared by the input handler when composition commits (final char arrives as normal insert).
    def set_preedit(text : String) : Nil
      @preedit = text
    end

    def preedit : String
      @preedit
    end

    # Split `text` into the CR-free line projection + the exact terminator that followed each
    # line. `lines[i] + eols[i]` concatenated is `text`, byte for byte, always — including the
    # pathological `"a\r\r\n"` (line `"a"`, eol `"\r\r\n"`), which the old rstrip silently
    # collapsed to one CR.
    private def split_wire(text : String) : {Array(String), Array(String)}
      parts = text.split('\n')
      lines = Array(String).new(parts.size)
      eols = Array(String).new(parts.size)
      last = parts.size - 1
      parts.each_with_index do |p, i|
        if i == last
          lines << p # nothing followed it — no terminator
          eols << ""
        elsif p.ends_with?('\r')
          stripped = p.rstrip('\r')
          n = p.bytesize - stripped.bytesize
          lines << stripped
          eols << (n == 1 ? "\r\n" : "#{"\r" * n}\n")
        else
          lines << p
          eols << "\n"
        end
      end
      lines << "" if lines.empty? # String#split never yields this, but the invariant is load-bearing
      eols << "" if eols.empty?
      {lines, eols}
    end

    # The terminator after line `i`, defaulting for any index an edit path has yet to fill in.
    # Defensive on purpose: a desync between @lines and @eols must degrade to today's LF
    # behaviour, never raise inside a render or a send.
    private def eol_at(i : Int32) : String
      @eols[i]? || DEFAULT_EOL
    end

    def to_bytes : Bytes
      @lines.join("\r\n").to_slice
    end

    # The buffer with every line's ORIGINAL terminator — the exact inverse of `set_text`, and
    # the only accessor a send path may use.
    #
    # Distinct from both of its neighbours, and all three are needed. `#text` (LF) is the
    # document form: comparisons, search offsets, marker parsing, Notes. `#to_bytes` (CRLF)
    # is the "everything is a header line" form the hex snapshot and the first-line probes
    # want. `#wire_text` is what actually came in: CRLF where the capture had CRLF, LF where
    # it had LF, and a lone CR left wherever it sat. `Env.expand_wire` still promotes the head
    # afterwards, so a line the operator typed fresh (eol `\n`) is CRLF-terminated on the wire
    # if it is a header and stays LF if it is body — which is the split this editor could not
    # express before.
    def wire_text : String
      return @lines[0] if @lines.size == 1
      String.build do |io|
        @lines.each_with_index do |l, i|
          io << l
          io << eol_at(i)
        end
      end
    end

    def wire_bytes : Bytes
      wire_text.to_slice
    end

    # The buffer as {line, terminator} pairs — for a consumer that has to cut the buffer on
    # line boundaries and still reassemble wire bytes (the Repeater's `%%%` send-group).
    def wire_lines : Array({String, String})
      @lines.map_with_index { |l, i| {l, eol_at(i)} }
    end

    # Plain text (LF-joined) for non-wire uses (e.g. the Notes document).
    def text : String
      @lines.join("\n")
    end

    def lines_snapshot : Array(String)
      @lines.map(&.itself)
    end

    # First line with non-whitespace content — used to derive a label/preview
    # (e.g. a Notes sub-tab title) without joining the whole buffer. nil when the
    # document is entirely blank.
    def first_nonblank_line : String?
      @lines.find { |l| !l.blank? }
    end

    def insert(ch : Char) : Nil
      # The ONE call that may join the step before it — see `push_undo`. A selection makes
      # this a replace, which is a step of its own however it was typed.
      push_undo(force: !@sel_anchor.nil?)
      note_replaced
      # Replace-on-type: a printable typed over a selection REPLACES it. The cut runs after
      # push_undo and before the splice, so the pair is ONE undo step — ⌃Z brings back both
      # the deleted run and the character that displaced it, which is what "replace" means.
      #
      # One caveat, and it is the owner's to close, not this file's: `RepeaterView#edit_insert`
      # asks `Fuzz::Template.insert_breaks_marker?` about the caret BEFORE calling here, so
      # for a selection the answer describes the pre-cut buffer. It only bites when the typed
      # char is `§` or `¦` — the predicate returns false for everything else — so an ordinary
      # keystroke over a selection is exact and only a literal marker delimiter typed over a
      # selection can be escaped on a stale offset.
      cut_selection
      line = @lines[@cy]
      cx = @cx.clamp(0, line.size)
      @lines[@cy] = "#{line[0, cx]}#{ch}#{line[cx..]}"
      # Forward-snap: the typed char can MERGE with what follows (typing `e` in front of a
      # lone U+0301 makes one `é` cluster), which would leave the caret inside it.
      @cx = cx + 1
      snap_cx_to_cluster(1)
      continue_run(ch) # the next character may join this step — see push_undo
      @styled = nil
      @edits += 1
      refresh_env_complete
    end

    # Insert a whole string at the caret as ONE undo unit (cross-tab "insert OAST payload").
    # Single-line content by name; `insert_text` is the same operation without that promise,
    # and this is a call into it so the two cannot drift on caret placement or undo shape.
    def insert_string(str : String) : Nil
      insert_text(str)
    end

    # Splice MULTI-LINE `text` in at the caret as ONE undo unit, one `@edits` bump and one
    # highlight invalidation — the bulk form of typing it, and the reason a paste no longer
    # costs a full edit cycle (undo snapshot, syntax rebuild, owner's Content-Length resync,
    # frame) per character. A 244 KB request took minutes that way; the work is now
    # proportional to the paste, not to its square.
    #
    # `text` must already use `\n` for every line break: the Runner builds it from the key
    # events a bracketed paste produced, where `PasteNewline` has ALREADY collapsed each
    # CRLF into one Enter — so what arrives here is line breaks, not the wire's CR bytes, and
    # normalizing again here would be a second opinion about the same question.
    #
    # Line ENDINGS follow `insert_newline`'s rule exactly: every break the paste introduces is
    # new and gets `DEFAULT_EOL`, while the terminator that ended the split line rides down to
    # the TAIL, which is still the same line it always terminated. (`Env.expand_wire` promotes
    # a head's LF back to CRLF on send, so a pasted header is CRLF on the wire and a pasted
    # body byte stays exactly what it was — identical to typing the same paste in.)
    def insert_text(text : String) : Nil
      return if text.empty?
      push_undo
      note_replaced
      cut_selection # replace-on-paste, one undo step — see `insert`
      line = @lines[@cy]
      cx = @cx.clamp(0, line.size)
      head = line[0, cx]
      tail = line[cx..]
      tail_eol = eol_at(@cy)
      parts = text.split('\n')
      if parts.size == 1
        @lines[@cy] = "#{head}#{parts[0]}#{tail}"
        @cx = cx + parts[0].size
      else
        @lines[@cy] = "#{head}#{parts[0]}"
        @eols[@cy] = DEFAULT_EOL
        last = parts.size - 1
        (1..last).each do |i|
          @lines.insert(@cy + i, i == last ? "#{parts[i]}#{tail}" : parts[i])
          @eols.insert(@cy + i, i == last ? tail_eol : DEFAULT_EOL)
        end
        @cy += last
        @cx = parts[last].size
      end
      snap_cx_to_cluster(1) # the paste's last char can merge with the text it landed before
      @styled = nil
      @edits += 1
      refresh_env_complete
    end

    # Insert `ch` TWICE as one undo unit — the `§§`/`¦¦` escaped-literal pair the marker
    # guard produces when a `§`/`¦` would otherwise nest inside (or flush against) a marker.
    # Caret ends past both, so the literal sits behind it like a normal keystroke.
    # How much the splice about to run will DESTROY, for an owner that wants to say so (see
    # `last_replaced`). Measured before the cut, and set on EVERY splice that cuts — including
    # the ones that replace nothing — so an owner reading it right after a call can never see a
    # stale count from an earlier keystroke.
    private def note_replaced : Nil
      @last_replaced = @sel_anchor.nil? ? 0 : (selection_text.try(&.size) || 0)
    end

    def insert_pair(ch : Char) : Nil
      push_undo
      note_replaced
      cut_selection # replace-on-type, one undo step — see `insert`
      line = @lines[@cy]
      cx = @cx.clamp(0, line.size)
      @lines[@cy] = "#{line[0, cx]}#{ch}#{ch}#{line[cx..]}"
      @cx = cx + 2
      snap_cx_to_cluster(1) # `§`/`¦` are their own clusters, but the char after may combine
      @styled = nil
      @edits += 1
      refresh_env_complete
    end

    # Swap the ENTIRE buffer for `new_text` as ONE undoable edit — unlike set_text, which
    # hard-resets and CLEARS the undo stack. Used by the marker-strip confirm so the edits
    # made before it stay undoable. Places the caret at char offset `caret`; stale conceal
    # offsets are dropped (the owner re-feeds fresh ones next render).
    def replace_all(new_text : String, caret : Int32) : Nil
      push_undo
      @lines, @eols = split_wire(new_text)
      @conceal_spans = [] of {Int32, Int32} unless @conceal_spans.empty?
      @styled = nil
      @edits += 1
      place_at_offset(caret)
    end

    def insert_newline : Nil
      push_undo
      cut_selection # ↵ over a selection replaces it with the break — see `insert`
      line = @lines[@cy]
      cx = @cx.clamp(0, line.size)
      @lines[@cy] = line[0, cx]
      @lines.insert(@cy + 1, line[cx..])
      # The TAIL keeps whatever terminated the line we just split; the break the user typed is
      # brand new, so it gets DEFAULT_EOL. (Splitting a CRLF-terminated header line therefore
      # yields a new LF-terminated line — which expand_wire promotes back to CRLF, since it is
      # still in the head. In a body it stays LF, matching what typing Enter has always sent.)
      @eols.insert(@cy + 1, eol_at(@cy))
      @eols[@cy] = DEFAULT_EOL
      @cy += 1
      @cx = 0
      @styled = nil
      @edits += 1
      refresh_env_complete
    end

    def backspace : Nil
      # A selection outranks the character: ⌫ with text selected removes the SELECTION, at
      # the buffer start as much as anywhere else — so the early return below (which exists
      # for "there is no character before the caret") must not fire first.
      return if delete_selection
      return if @cx == 0 && @cy == 0 # buffer start — nothing to delete, don't dirty (mirrors delete)
      if @cx > 0
        push_undo
        line = @lines[@cy]
        cx = @cx.clamp(0, line.size)
        # Delete the whole grapheme CLUSTER before the caret, not one codepoint. Backspacing
        # `café` gives `caf`, never `cafe` with the acute silently dropped; backspacing a ZWJ
        # family removes the family rather than leaving `👨‍👩‍👧‍` with a trailing joiner that the
        # terminal renders as a broken sequence. The cluster is the user-perceived character,
        # so this is what one press should undo — and it keeps @cx on a boundary for free.
        # (Composing a cluster codepoint-by-codepoint is the IME's job, via preedit; once it
        # has COMMITTED a glyph, taking it apart is not something a backspace should do.)
        st = Screen.cluster_start(line, cx - 1)
        @lines[@cy] = "#{line[0, st]}#{line[cx..]}"
        @cx = st
      elsif @cy > 0
        push_undo
        prev = @lines[@cy - 1]
        @cx = prev.size
        @lines[@cy - 1] = prev + @lines[@cy]
        @lines.delete_at(@cy)
        # The terminator that separated the two lines is exactly what the backspace deleted;
        # the merged line now ends with whatever ended the line pulled up.
        @eols.delete_at(@cy - 1)
        @cy -= 1
        # The JOIN re-clusters across the seam: if the next line opened with a combining
        # mark it has just fused onto `prev`'s last glyph, so `prev.size` — the seam — is
        # now cluster INTERIOR. Snap forward, past the fused glyph, which is where the seam
        # visually is ("café|x", not "caf|éx"). Without this the caret paints over the
        # following glyph, an insert splices INTO the cluster ("cafe" + "́x" then
        # typing Z gave "cafeŹx"), and the next backspace strands the mark on the wrong
        # base ("caf́x") — the exact outcome the whole-cluster delete above exists to avoid.
        snap_cx_to_cluster(1)
      end
      @styled = nil
      @edits += 1
      refresh_env_complete
    end

    # Home / End: jump the cursor to the start / end of the current line. Pure navigation
    # (no buffer change), so @styled/@edits are untouched — mirrors `move`.
    #
    # `selecting` is the Shift half, and it is the same anchor rule the arrows use: ⇧Home
    # extends to the line start, plain Home collapses. Without it ⇧Home/⇧End did not merely
    # fail to extend — they DROPPED a selection the operator had already built with ⇧arrows,
    # which is the one thing a shifted key must never do.
    def home(selecting : Bool = false) : Nil
      anchor_for(selecting)
      @cx = 0
      snap_cx_out_of_conceal(-1) unless @conceal_spans.empty?
      break_run # a caret move ends the typing run — see push_undo
      env_complete_close
    end

    def end_of_line(selecting : Bool = false) : Nil
      anchor_for(selecting)
      @cx = @lines[@cy].size
      snap_cx_out_of_conceal(1) unless @conceal_spans.empty?
      break_run # a caret move ends the typing run — see push_undo
      env_complete_close
    end

    # Plant (or keep) the selection anchor for a shifted motion, or drop it for a plain one.
    # The one place that decision is made, so every motion added later inherits it.
    private def anchor_for(selecting : Bool) : Nil
      selecting ? (@sel_anchor ||= {@cy, @cx}) : (@sel_anchor = nil)
    end

    # PageUp / PageDown: move the caret `rows` VISUAL rows and carry the view with it. The
    # editors ignored both keys entirely, so a long body could only be crossed one row at a
    # time (or with ^G, which needs a line number the operator has to already know).
    #
    # Visual rows, not logical lines, for the reason `move`'s ↑/↓ branch gives: under soft
    # wrap a logical-line page skips over everything the pane is showing. `rows` is the
    # caller's viewport height minus an overlap row or two — the same figure the list views
    # page by (`Runner#page_nav_delta`), so paging feels identical everywhere.
    def page(rows : Int32, selecting : Bool = false) : Nil
      return if rows == 0
      anchor_for(selecting)
      if wrapping?
        rows.abs.times { move_visual(rows > 0 ? 1 : -1) }
      else
        @cy = (@cy + rows).clamp(0, @lines.size - 1)
        @cx = @cx.clamp(0, @lines[@cy].size)
        snap_cx_to_cluster(0)
      end
      snap_cx_out_of_conceal(0) unless @conceal_spans.empty?
      break_run # a caret move ends the typing run — see push_undo
      env_complete_close
    end

    # Buffer start / end (⌃Home / ⌃End, and what a `page` past the edge lands on).
    def to_buffer_start(selecting : Bool = false) : Nil
      anchor_for(selecting)
      @cy = 0
      @cx = 0
      break_run # a caret move ends the typing run — see push_undo
      env_complete_close
    end

    def to_buffer_end(selecting : Bool = false) : Nil
      anchor_for(selecting)
      @cy = @lines.size - 1
      @cx = @lines[@cy].size
      break_run # a caret move ends the typing run — see push_undo
      env_complete_close
    end

    # --- word motion (⌥/⌃ + ←/→, ⌥⌫) ----------------------------------------
    #
    # WORD = a run of key-ish characters (letters, digits, `_`, `-`) OR a run of punctuation,
    # with whitespace skipped on the way. Deliberately NOT Vim's WORD and not "everything up
    # to the next space": the text in these editors is a URL, a header value, a JSON body, so
    # `/api/v2/users?id=7` has to break at every `/`, `?` and `=` for the motion to be worth
    # having, while `Content-Type` must not fragment at the hyphen (it is one header name).
    #
    # `-` is inside the run and `.`/`/`/`?`/`=`/`&`/`:` are not, which is the split that makes
    # `X-Request-Id: a.b.c` walk as `X-Request-Id`, `:`, `a`, `.`, `b`… — one press per token
    # an operator would actually retype.
    def word_left(selecting : Bool = false) : Nil
      anchor_for(selecting)
      if @cx == 0
        move(0, -1, selecting: selecting) # at column 0 a word step is just "up a line"
        return
      end
      line = @lines[@cy]
      i = @cx.clamp(0, line.size)
      while i > 0 && line[i - 1].whitespace?
        i -= 1
      end
      if i > 0
        word = word_char?(line[i - 1])
        while i > 0 && !line[i - 1].whitespace? && word_char?(line[i - 1]) == word
          i -= 1
        end
      end
      @cx = i
      snap_cx_to_cluster(-1)
      snap_cx_out_of_conceal(-1) unless @conceal_spans.empty?
      break_run # a caret move ends the typing run — see push_undo
      env_complete_close
    end

    def word_right(selecting : Bool = false) : Nil
      anchor_for(selecting)
      line = @lines[@cy]
      if @cx >= line.size
        move(0, 1, selecting: selecting) # at EOL a word step is "down a line"
        return
      end
      i = @cx.clamp(0, line.size)
      if i < line.size && !line[i].whitespace?
        word = word_char?(line[i])
        while i < line.size && !line[i].whitespace? && word_char?(line[i]) == word
          i += 1
        end
      end
      while i < line.size && line[i].whitespace?
        i += 1
      end
      @cx = i
      snap_cx_to_cluster(1)
      snap_cx_out_of_conceal(1) unless @conceal_spans.empty?
      break_run # a caret move ends the typing run — see push_undo
      env_complete_close
    end

    # ⌥⌫ — delete back to the previous word boundary, as ONE undo step. A no-op (false, and
    # not even a dirty flag) at the buffer start, so callers can gate on the return like they
    # do for `backspace`.
    def delete_word_left : Bool
      return true if delete_selection # a selection outranks the word, as it does for ⌫
      return false if @cx == 0 && @cy == 0
      if @cx == 0
        backspace # at column 0 there is no word behind the caret, only the line break
        return true
      end
      from = @cx
      push_undo
      word_left
      line = @lines[@cy]
      @lines[@cy] = "#{line[0, @cx]}#{line[from.clamp(0, line.size)..]}"
      @styled = nil
      @edits += 1
      refresh_env_complete
      true
    end

    private def word_char?(c : Char) : Bool
      c.alphanumeric? || c == '_' || c == '-'
    end

    # Forward delete: remove the char under the cursor, or join the next line when at EOL.
    # A buffer mutation, so it invalidates the highlight cache and bumps @edits (like backspace).
    def delete : Nil
      return if delete_selection # a selection outranks the char under the caret — see `backspace`
      line = @lines[@cy]
      cx = @cx.clamp(0, line.size)
      if cx < line.size
        push_undo
        # Whole-cluster forward delete, mirroring backspace — see the note there.
        @lines[@cy] = "#{line[0, cx]}#{line[Screen.cluster_end(line, cx + 1)..]}"
      elsif @cy < @lines.size - 1
        push_undo
        @lines[@cy] = line + @lines[@cy + 1]
        @lines.delete_at(@cy + 1)
        @eols.delete_at(@cy) # the separator is what forward-delete removed (mirrors backspace)
      else
        return # end of buffer — nothing to delete, don't dirty
      end
      @cx = cx
      # The line-join branch re-clusters across the seam exactly as backspace's does (see
      # the note there), so the caret has to be re-snapped. Forward rather than back:
      # snapping back would leave the caret before a glyph the join FUSED, so the next
      # Delete would take the pre-existing base char with it ("cafe" → "cafx"). A no-op on
      # the common in-line branch, where `cx` was already a boundary.
      snap_cx_to_cluster(1)
      @styled = nil
      @edits += 1
      refresh_env_complete
    end

    # `selecting` (shift held) pins the far end of a selection at wherever the caret is
    # standing and then moves the caret; without it the arrow COLLAPSES any selection, which
    # is what every editor does and what makes ⇧→→ a reliable way to lose a selection.
    #
    # The motion itself is this method's own, deliberately NOT `ReadCursor#move`: that one
    # steps LOGICAL lines and snaps ⇧↑/⇧↓ to end-of-line (whole-line selection, right for a
    # read-only pane), while an INS caret steps one VISUAL row under soft wrap and keeps its
    # display column. Selecting has to move the caret exactly where an unmodified arrow would
    # — over wrapped rows, grapheme clusters and concealed `¦chain` runs alike — or the
    # selection covers text the user never crossed. So the ANCHOR is shared with the read
    # model's shape and the MOTION is not.
    def move(dr : Int32, dc : Int32, selecting : Bool = false) : Nil
      if selecting
        @sel_anchor ||= {@cy, @cx}
      else
        @sel_anchor = nil
      end
      if dr != 0
        if wrapping?
          # ↑/↓ step one VISUAL row, not one logical line. On an unwrapped line the two are
          # the same thing; on a wrapped one, stepping by logical line would jump the caret
          # over everything the pane is showing between here and the next line number,
          # which is exactly the confusion soft wrap exists to remove.
          move_visual(dr)
        else
          @cy = (@cy + dr).clamp(0, @lines.size - 1)
          @cx = @cx.clamp(0, @lines[@cy].size)
          snap_cx_to_cluster(0) # the column carried across rows can land mid-cluster
        end
      end
      if dc != 0
        @cx += dc
        if @cx < 0
          if @cy > 0
            @cy -= 1
            @cx = @lines[@cy].size
          else
            @cx = 0
          end
        elsif @cx > @lines[@cy].size
          if @cy < @lines.size - 1
            @cy += 1
            @cx = 0
          else
            @cx = @lines[@cy].size
          end
        end
        # `@cx += dc` steps CODEPOINTS; the caret column and the draw step CLUSTERS. Snap
        # in the direction of travel so → clears a whole cluster and ← lands on its start,
        # rather than resting between the `e` and the combining acute of `é` (where the
        # caret would be column-ambiguous and a delete would strand the mark).
        snap_cx_to_cluster(dc)
      end
      snap_cx_out_of_conceal(dc) unless @conceal_spans.empty? # never rest on a hidden ¦chain char
      refresh_env_complete
    end

    # --- INSERT-mode selection (opt-in: nothing here fires until `move(…, selecting: true)`) ---

    # Whether a NON-EMPTY selection is held. Emptiness matters and is not pedantry: ⇧→ then
    # ⇧← puts the caret back on the anchor, and if that still counted as a selection the next
    # ⌫ would delete zero characters instead of one — a dead key the operator cannot explain.
    def selection? : Bool
      !selection_range.nil?
    end

    def clear_selection : Nil
      @sel_anchor = nil
    end

    # The selected text, or nil when nothing is selected.
    #
    # The multi-line slice is `ReadCursor`'s rather than a second copy of it: that method
    # already assigns the boundary columns to the lines they belong to in DOCUMENT order and
    # clamps each to its own line's length — the fix for an upward selection copying the
    # wrong text and raising `IndexError` on a short top line. Duplicating it here is exactly
    # how that bug would come back on the INS side only.
    #
    # The anchor is planted through `move(0, 0, selecting: true)`, whose `@anchor ||= {cy, cx}`
    # runs while both motion branches are guarded off by the zero deltas, and the caret is
    # then placed with `sync`, which documents itself as moving the caret WITHOUT disturbing
    # the selection. That dance exists because `ReadCursor` exposes no anchor setter and
    # read_cursor.cr is owned elsewhere this round; an `anchor=` there would replace it.
    def selection_text : String?
      r = selection_range
      return nil unless r
      y0, x0, y1, x1 = r
      rc = ReadCursor.new
      rc.sync(y0, x0)
      rc.move(0, 0, @lines, selecting: true)
      rc.sync(y1, x1)
      rc.selection_text(@lines)
    end

    # Remove the selection as one undoable edit, leaving the caret where it started.
    # Returns false (and touches nothing, not even @edits) when there is no selection, so a
    # caller can use it as the first line of ⌫/Del without a second predicate call.
    def delete_selection : Bool
      return false unless selection_range
      push_undo
      cut_selection
      refresh_env_complete
      true
    end

    # The selection as a DOCUMENT-ORDERED {y0, x0, y1, x1}, or nil when there is none (or it
    # is empty). Both ends are clamped to the buffer as it stands now: the anchor was planted
    # against an earlier revision and an external `replace_line` / `resync Content-Length`
    # can have shortened its line since.
    # The INSERT-mode selection as an ORDERED span, for an owner handing it to the read-mode
    # cursor when leaving INS (`TextReadState#adopt_editor_selection`). Public because the
    # handover crosses files; nil when nothing is selected, exactly like `selection?`.
    def selection_span : {Int32, Int32, Int32, Int32}?
      selection_range
    end

    private def selection_range : {Int32, Int32, Int32, Int32}?
      anc = @sel_anchor
      return nil unless anc
      ay = anc[0].clamp(0, @lines.size - 1)
      ax = anc[1].clamp(0, @lines[ay].size)
      cy = @cy.clamp(0, @lines.size - 1)
      cx = @cx.clamp(0, @lines[cy].size)
      return nil if ay == cy && ax == cx # collapsed — see `selection?`
      (ay < cy || (ay == cy && ax < cx)) ? {ay, ax, cy, cx} : {cy, cx, ay, ax}
    end

    # Splice the selection out of the buffer WITHOUT pushing undo — the caller owns the undo
    # unit, which is what lets replace-on-type be one ⌃Z instead of two. No-op (false) when
    # nothing is selected, so every insert path can call it unconditionally.
    #
    # The line ENDINGS follow `backspace`'s join rule exactly: joining lines y0…y1 into one
    # drops the terminators that separated them and keeps `@eols[y1]`, the ending of the last
    # line consumed. A cut that kept `@eols[y0]` instead would put the FIRST line's CRLF on a
    # body line that was LF-terminated (or the reverse), changing bytes on the wire that the
    # operator never touched.
    private def cut_selection : Bool
      r = selection_range
      @sel_anchor = nil
      return false unless r
      y0, x0, y1, x1 = r
      @lines[y0] = "#{@lines[y0][0, x0]}#{@lines[y1][x1..]}"
      (y1 - y0).times do
        @lines.delete_at(y0 + 1)
        @eols.delete_at(y0)
      end
      @cy = y0
      @cx = x0
      # The splice re-clusters across the seam the same way a backspace-join does: if the
      # kept tail opens with a combining mark it has just fused onto the head's last glyph,
      # so the seam is now cluster interior. Snap forward, past the fused glyph — see the
      # long note in `backspace`.
      snap_cx_to_cluster(1)
      @styled = nil
      @edits += 1
      true
    end

    # Cursor is on the first line — the Runner pops focus to the tab bar when ↑
    # is pressed here (natural upward flow, matching the body lists).
    #
    # Under wrap it is the first VISUAL row that pops focus, not the first logical line:
    # the caret on row 3 of a wrapped line 1 still has three rows above it inside this
    # pane, and stealing that ↑ would make those rows unreachable from the keyboard.
    def at_top? : Bool
      return @cy == 0 unless wrapping?
      @cy == 0 && layout_of(0, @last_cw).row_of(@cx) == 0
    end

    # Cursor is on the last line — used to cross out of the editor on ↓ (e.g. the
    # Decoder INPUT editor descends to the CHAIN field) without swallowing normal
    # downward cursor movement. Last VISUAL row under wrap — see `at_top?`.
    def at_bottom? : Bool
      last = @lines.size - 1
      return @cy == last unless wrapping?
      lay = layout_of(last, @last_cw)
      @cy == last && lay.row_of(@cx) == lay.rows - 1
    end

    # Cursor at the very start (first line, first column) — used to pop focus out of
    # the editor on ← without swallowing normal cursor movement.
    def at_start? : Bool
      @cy == 0 && @cx == 0
    end

    # Place the cursor at the click (mx,my), inverting render's layout: the visible
    # row maps to @scroll + offset; the display-x (after the optional gutter) maps to
    # a character index (at a cluster start) via Screen.column_for. `rect` is the SAME
    # rect render gets.
    # Coords are 0-based; a click below the text lands on the last line, left of the
    # text on column 0. render's ensure_visible reconciles @scroll next frame.
    # `selecting` is the DRAG half (and what a future shift-click would pass): the anchor is
    # kept (or planted where the caret stands) and the caret moves to the pointer, so the
    # selection grows to wherever the pointer went — the same anchor rule ⇧arrows use, driven
    # from the mouse instead of the keyboard.
    def click_to_cursor(rect : Rect, mx : Int32, my : Int32, selecting : Bool = false) : Nil
      return if rect.empty? || @lines.empty?
      # The scroll gauge rides `rect.right` — render draws it there — so a click on that one
      # column is a scroll request, not a caret placement. Answering it HERE covers every
      # editor in the app at once, because every caller hands `click_to_cursor` the same rect
      # it handed `render`. Routed through `scroll_view` rather than assigning `@scroll`, so
      # the caret is dragged along (else render's `ensure_visible` snaps the view straight
      # back) and wrap's `@scroll_sub` stays consistent. Under wrap the gauge is a proportion
      # indicator rather than a coordinate — see the note on the draw — so this lands close
      # rather than exactly, which is what the thumb was already saying.
      # Not on a DRAG: a selection that has run past the right edge must keep extending.
      if !selecting && (top = Frame.scroll_gauge_top(rect, @lines.size, mx, my))
        scroll_view(top - @scroll)
        return
      end
      row = my - rect.y
      # A drag ABOVE the pane still means something — the pointer left the top edge while the
      # button was held — so it pins to the first visible row instead of being dropped. A
      # plain click there is not this editor's (the chrome above it owns that cell).
      if row < 0
        return unless selecting
        row = 0
      end
      gw = @gutter ? {Gutter.width(@lines.size), rect.w}.min : 0
      cw = {rect.w - gw, 0}.max
      # Rebuild the SAME row list render lays down (same rect, same anchor, same wrap
      # function) rather than reading @last_rows: the mapping then holds for a click that
      # arrives before the first frame, and there is exactly one definition of where a row
      # begins. Without wrap this is one row per line and `@scroll + row` falls straight out.
      rows = visible_rows(cw, rect.h)
      return if rows.empty?
      # Planted BEFORE the caret moves, so the anchor is where the press left it.
      anchor_for(selecting)
      vr = rows[row]? || rows[rows.size - 1]
      @cy = vr.li
      # + @xscroll: the click lands at display column (mx - content_x) WITHIN the
      # visible window, which is @xscroll columns into the full line (always 0 under wrap).
      target = mx - (rect.x + gw) + @xscroll
      line = @lines[@cy]
      cr = @conceal_spans.empty? ? nil : line_conceal(line_start_offset(@cy), line.size)
      # `Wrap.row_index` is the exact inverse of `Wrap.row_col`, which is what the caret,
      # the selection tint and the search overdraw all measure with — so a click lands on
      # the cell the caret would paint, on a continuation row as much as on a first row. It
      # steps by CLUSTER and hops whole concealed runs, so the result is always a cluster
      # start and never an unseen `¦chain` char; it clamps to the row's own end, so a click
      # past the text of a wrapped row stops at the break instead of running into the next
      # row's characters.
      @cx = Wrap.row_index(line, cr, vr.a, vr.b, target, nearest: true)
      snap_cx_out_of_conceal(0) # a click on the closing-§ column resolves to it; nudge to a legal rest
      break_run                 # a caret move ends the typing run — see push_undo
      env_complete_close
    end

    # Select the WORD under (mx, my) — the double-click gesture. Places the caret at the
    # pointer first (so the pane scrolls and focuses exactly as a click does), then spreads
    # to the word boundaries `word_left`/`word_right` would stop at, which is what keeps
    # double-click and ⌥←/→ agreeing about where a word ends.
    #
    # A double-click on whitespace or past the end of a line selects nothing rather than
    # grabbing the run of spaces: the gesture means "give me this token", and there is none.
    def select_word_at(rect : Rect, mx : Int32, my : Int32) : Bool
      click_to_cursor(rect, mx, my)
      select_word_at_cursor
    end

    # The word-spread half of `select_word_at`, WITHOUT the hit test — for a caller whose caret
    # is already where the pointer put it. `ReadCursor` carries this same pair for the same
    # reason (see its comment): a second inverse can disagree with the first when the layout
    # moved between the two presses of a double-click, which is exactly what a Repeater split
    # column does — adopting the lower sub-pane on press 1 resizes both cards, so press 2's
    # rect is no longer the one press 1 was inverted against.
    def select_word_at_cursor : Bool
      return false if @lines.empty?
      @cy = @cy.clamp(0, @lines.size - 1)
      line = @lines[@cy]
      cx = @cx.clamp(0, line.size)
      # `Screen.column_for_click` rounds a POINTER to the NEAREST cluster boundary, so a
      # double-click on the RIGHT half of a WIDE glyph — a Hangul syllable, a CJK ideograph:
      # half of every pointer position over such text — resolves to the position AFTER it,
      # where the word may have already ended and there is no token to take. Step back over
      # that one glyph, and ONLY when it is wide: a 1-column cluster cannot be rounded past,
      # so every ASCII gesture is bit-for-bit what it was (including "a double-click on a
      # space takes nothing", which is this method's stated contract).
      cx = Screen.step_back_over_wide(line, cx)
      return false if cx >= line.size || line[cx].whitespace?
      word = word_char?(line[cx])
      a = cx
      while a > 0 && !line[a - 1].whitespace? && word_char?(line[a - 1]) == word
        a -= 1
      end
      b = cx
      while b < line.size && !line[b].whitespace? && word_char?(line[b]) == word
        b += 1
      end
      return false if a == b
      @sel_anchor = {@cy, a}
      @cx = b
      snap_cx_to_cluster(1)
      env_complete_close
      true
    end

    # Viewport scroll by `step` lines (the mouse wheel), INDEPENDENT of the cursor:
    # shift the visible window, then pull the cursor into it so render's ensure_visible
    # won't snap the view back to the old cursor line. Unlike move(), the window jumps
    # immediately (no "wheel until the cursor reaches the edge" lag). No-op before the
    # first render (height unknown) or when the buffer already fits.
    def scroll_view(step : Int32) : Nil
      return if @last_h <= 0
      before = {@cy, @cx}
      if wrapping?
        scroll_view_wrapped(step)
      elsif @lines.size > @last_h
        max = @lines.size - @last_h
        @scroll = (@scroll + step).clamp(0, max)
        @cy = @cy.clamp(@scroll, {@scroll + @last_h - 1, @lines.size - 1}.min)
        @cx = @cx.clamp(0, @lines[@cy].size)
        snap_cx_to_cluster(0) # the row changed under the caret; its column may re-cluster
        break_run             # a caret move ends the typing run — see push_undo
        env_complete_close
      end
      # The caret is DRAGGED (not steered) when the window would otherwise leave it behind.
      # A drag is not a selecting move, so it must not silently grow a selection: the wheel
      # would then extend it to wherever the operator scrolled, and the next keystroke — a
      # replace-on-type — would eat everything in between. Dropped only when the drag really
      # happened; scrolling with the caret still on screen leaves the selection alone.
      @sel_anchor = nil if @sel_anchor && {@cy, @cx} != before
    end

    # Wheel under soft wrap: `step` is VISUAL rows, so one notch moves one drawn row even
    # when that row is the middle of a wrapped line. The anchor walks; nothing counts the
    # buffer's total rows (see @scroll_sub), and the bottom stop is found by walking BACK
    # one viewport from the last row — O(viewport), not O(document).
    private def scroll_view_wrapped(step : Int32) : Nil
      cw = @last_cw
      return if cw <= 0
      advance_anchor(step, cw)
      mli, msub = Wrap.max_anchor(@lines.size, @last_h, layout_fn(cw))
      if @scroll > mli || (@scroll == mli && @scroll_sub > msub)
        @scroll = mli
        @scroll_sub = msub
      end
      # Pull the caret into the window so render's ensure_visible doesn't snap the view
      # straight back to where it was (mirrors the unwrapped branch). The comparison has to
      # be in VISUAL rows: a caret on line 0 is "inside" a window that starts at row 3 of
      # line 0 only by logical-line arithmetic, and that arithmetic is exactly what made
      # the wheel fight ensure_visible to a standstill.
      rows = visible_rows(cw, @last_h)
      return if rows.empty?
      first = rows[0]
      last = rows[rows.size - 1]
      if @cy < first.li || (@cy == first.li && @cx < first.a)
        @cy = first.li
        @cx = first.a
      elsif @cy > last.li || (@cy == last.li && layout_of(last.li, cw).row_of(@cx) > last.sub)
        @cy = last.li
        @cx = last.a
      end
      @cx = @cx.clamp(0, @lines[@cy].size)
      snap_cx_to_cluster(0) # the row changed under the caret; its column may re-cluster
      break_run             # a caret move ends the typing run — see push_undo
      env_complete_close
    end

    # Jump the cursor to 1-based line `n`, column 0 (out-of-range clamps to the
    # first/last line). render's ensure_visible scrolls it into view next frame.
    def goto_line(n : Int32) : Nil
      @cy = (n - 1).clamp(0, @lines.size - 1)
      @cx = 0
      @sel_anchor = nil
      break_run # a caret move ends the typing run — see push_undo
      env_complete_close
    end

    # Place the caret without pushing undo (read-mode navigation / click-to-cursor).
    def place_cursor(cy : Int32, cx : Int32) : Nil
      @cy = cy.clamp(0, @lines.size - 1)
      @cx = cx.clamp(0, @lines[@cy].size)
      snap_cx_to_cluster(0) # caller-supplied index — unconstrained, may land mid-cluster
      # This is how the READ-mode cursor writes itself back (TextReadState#apply), so it is
      # also where an INS selection left behind by `esc` is retired: navigating in NOR must
      # not leave a stale INS selection waiting to reappear the next time `i` is pressed.
      @sel_anchor = nil
      break_run # a caret move ends the typing run — see push_undo
      env_complete_close
    end

    def line_count : Int32
      @lines.size
    end

    # THE motion keymap every text editor shares — ⇧arrows to select, PageUp/PageDown,
    # ⇧Home/⇧End, ⌃/⌥+←→ by word, ⌃/⌥+Home/End to the buffer ends, ⌥⌫ to delete a word.
    # Returns true when it consumed the key.
    #
    # Here, and not copied into each controller, because "what do the arrow keys do in a text
    # box" is one answer and gori had eight: the Repeater grew ⇧arrows while the Fuzzer did
    # not, Notes had them in READ mode and not in INSERT, the Intercept editor had none at
    # all, and nothing anywhere paged or stepped by word. An owner with pane-crossing rules
    # (the Repeater's ↑-at-top pop, a marker-delimiter confirm) still handles those keys
    # itself and calls this for the rest; an owner without them can route everything here.
    #
    # `word_delete` is the one MUTATION in the set. It is included because ⌥⌫ is a motion in
    # the user's head — the mirror of ⌥← — and splitting it out would put half the chord pair
    # in a different file. Owners that must mark themselves dirty check `edits` around the
    # call, exactly as they already do for `backspace`.
    def handle_motion_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      shift = ev.shift?
      mod = ev.ctrl? || ev.alt? # ⌥ is the macOS spelling, ⌃ everywhere else — accept both
      case
      when mod && key.left?     then word_left(shift)
      when mod && key.right?    then word_right(shift)
      when mod && key.home?     then to_buffer_start(shift)
      when mod && key.end?      then to_buffer_end(shift)
      when word_delete_key?(ev) then delete_word_left
      when key.left?            then move(0, -1, selecting: shift)
      when key.right?           then move(0, 1, selecting: shift)
      when key.up?              then move(-1, 0, selecting: shift)
      when key.down?            then move(1, 0, selecting: shift)
      when key.home?            then home(shift)
      when key.end?             then end_of_line(shift)
      when key.page_up?         then page(-page_rows, selecting: shift)
      when key.page_down?       then page(page_rows, selecting: shift)
      else                           return false
      end
      true
    end

    # A modified ⌫. The `char` half is load-bearing: a terminal sends ⌥⌫ as ESC + 0x7F, and
    # termisu's Alt-prefix branch maps the payload through `Key.from_char`, which has no name
    # for DEL — so it arrives as `Key::Unknown` + Alt carrying that char, not as Backspace.
    def word_delete_key?(ev : Termisu::Event::Key) : Bool
      return false unless ev.ctrl? || ev.alt?
      return true if ev.key.backspace?
      c = ev.char
      !!c && (c == '\u{7F}' || c == '\b')
    end

    # One screenful for `page`, taken from the LAST RENDERED viewport height so the step
    # always matches the pane on screen (a split pane pages by its half). Two rows of overlap,
    # the same courtesy `Runner#page_nav_delta` gives the list views, so the operator keeps a
    # line of context across the jump. Floors at 1 so a page still moves before the first frame.
    def page_rows : Int32
      {@last_h - 2, 1}.max
    end

    # Replace one line in-place (cursor clamped when on that row). Used by Repeater to
    # resync a lone Content-Length header without resetting the whole buffer.
    def replace_line(idx : Int32, content : String) : Nil
      return if idx < 0 || idx >= @lines.size
      return if @lines[idx] == content
      push_undo
      @lines[idx] = content
      if @cy == idx
        @cx = @cx.clamp(0, content.size)
        snap_cx_to_cluster(0) # the replacement line re-clusters under the old index
      end
      @styled = nil
      @edits += 1
    end

    # Flat char offset of the cursor into `text` (LF-joined) — for marking helpers
    # that operate on the whole buffer text (e.g. the Fuzzer's §-position toggle).
    def cursor_offset : Int32
      off = 0
      (0...@cy).each { |i| off += @lines[i].size + 1 } # +1 for the joining '\n'
      off + @cx.clamp(0, @lines[@cy].size)
    end

    # Inverse of cursor_offset: place the caret at a flat char offset into the LF-joined
    # buffer. Used to restore the caret to a §…§ marker after a set_text that rebuilt the
    # buffer (e.g. committing the ^Y chain edit) so the marker tooltip keeps showing.
    def place_at_offset(offset : Int32) : Nil
      off = {offset, 0}.max
      cy = 0
      while cy < @lines.size - 1 && off > @lines[cy].size
        off -= @lines[cy].size + 1
        cy += 1
      end
      @cy = cy
      @cx = off.clamp(0, @lines[cy].size)
      snap_cx_to_cluster(0) # a flat buffer offset carries no cluster guarantee
      @sel_anchor = nil
      break_run # a caret move ends the typing run — see push_undo
      env_complete_close
    end

    # ^F search: 0-based indices of lines containing `query` (case-insensitive). The
    # downcased lines are cached on @edits, so each keystroke of an incremental search (and
    # the re-scans on drain/poll while the prompt is open) reuses them instead of allocating a
    # fresh `.downcase` per line every time — the buffer doesn't change while you type a query.
    def search_lines(query : String) : Array(Int32)
      hits = [] of Int32
      return hits if query.empty?
      q = query.downcase
      lowercased_lines.each_with_index { |l, i| hits << i if l.includes?(q) }
      hits
    end

    private def lowercased_lines : Array(String)
      if @edits != @lc_lines_rev
        @lc_lines_rev = @edits
        @lc_lines = @lines.map(&.downcase)
      end
      @lc_lines
    end

    # ^F find&replace: how many times `query` occurs — same matching as search_lines
    # but counted per OCCURRENCE, not per line (a line with three hits counts three).
    # The confirm prompt quotes this before the edit commits.
    # -1 when the buffer cannot be searched at all — see `searchable?`. The caller reports
    # that; it must not be folded into 0, which reads as "no matches" and would make
    # find-and-replace a silent no-op on exactly the buffers where it looks like it worked.
    def match_count(query : String) : Int32
      return 0 if query.empty?
      return -1 unless searchable?
      text.scan(search_regex(query)).size
    end

    # Whether a PCRE may be run over this buffer. Crystal's Regex RAISES
    # `ArgumentError: UTF-8 error: illegal byte` on a subject that is not valid UTF-8, and
    # this buffer is routinely loaded from RAW CAPTURED BYTES — a Repeater tab seeded from a
    # POST with a multipart/protobuf/gzip body, a held request in the intercept editor. That
    # raise had no `rescue` between here and `Runner#run`, so ^F + replace on such a buffer
    # took the whole TUI down mid-triage, losing every unsaved buffer and force-forwarding the
    # intercept queue on the way out.
    #
    # NOT solved by scrubbing at load: these bytes are the request the operator is about to
    # send, and replacing an invalid sequence with U+FFFD would change what goes on the wire
    # (P7). NOT solved by scrubbing here either, because `replace_matches` writes its result
    # BACK into the buffer. So the operation is refused and named. The codebase already takes
    # this shape elsewhere — `fuzz/template.cr` rescues the identical raise "rather than crash
    # the TUI auto-mark", and `fuzz/matcher.cr` scrubs before its regexes because there the
    # result is only read.
    def searchable? : Bool
      text.valid_encoding?
    end

    # Swap every occurrence of `query` for `replacement` as ONE undoable edit (so a
    # surprise result is one ^Z away), returning how many landed. `replacement` is
    # inserted literally — the block form of gsub skips \1 backreference expansion,
    # which the user did not ask for by typing a `\1`. The caret keeps its old offset
    # (clamped): a bulk edit has no single site to land on.
    def replace_matches(query : String, replacement : String) : Int32
      return 0 if query.empty?
      return 0 unless searchable? # see `searchable?`; the confirm never opens for these
      n = 0
      swapped = text.gsub(search_regex(query)) { n += 1; replacement }
      return 0 if n == 0
      replace_all(swapped, cursor_offset)
      n
    end

    # Literal `query`, matched case-insensitively to mirror what ^F highlights. Regex
    # rather than a downcase scan because downcasing can change a string's LENGTH for
    # some Unicode (e.g. 'İ'), which would skew the offsets a manual scan splices on.
    private def search_regex(query : String) : Regex
      Regex.new(Regex.escape(query), Regex::Options::IGNORE_CASE)
    end

    # `highlight` overlays request/response syntax colours on the buffer while
    # keeping it fully editable: pass `:request` or `:response` for the held
    # HTTP message editors (Repeater, Intercept), nil for plain prose (Notes,
    # Issue notes). The styled lines are 1:1 with `@lines`, so the cursor —
    # drawn last, on top — still lands on the right column.
    # `gauge` rides a right-border scroll gauge on the frame the CALLER drew (pass it
    # only when this editor fills a card's `rect.inset(1, 1)`, so `rect.right` lands on
    # the hairline); `gauge_focused` brightens the thumb when this pane holds focus.
    def render(screen : Screen, rect : Rect, cursor : Bool, highlight : Symbol? = nil, peek : Bool = false,
               gauge : Bool = false, gauge_focused : Bool = false) : Nil
      return if rect.empty?
      @last_h = rect.h                                           # remembered for scroll_view (wheel) clamping
      gw = @gutter ? {Gutter.width(@lines.size), rect.w}.min : 0 # never exceed the pane
      cx0 = rect.x + gw                                          # content start x (after the optional gutter)
      cw = {rect.w - gw, 0}.max                                  # content width
      # The gutter is sized from the LOGICAL line count and must stay that way: wrapping
      # multiplies the drawn rows, and letting the numbers widen to match would shift the
      # text column every time a line spilled — the gutter names logical lines, and there
      # are exactly as many of those as there ever were.
      @last_cw = cw # the wrap mappings that run outside render (move / click / at_top?) need it
      # Each branch zeroes the OTHER's state. They were mutually exclusive by construction
      # while `wrap=` was the only way in; the Display preference can now flip the answer
      # under a live editor, and a leftover offset would shift every wrapped row left by it
      # (or leave the caret anchored to a continuation row that no longer exists).
      if wrapping?
        @xscroll = 0
        ensure_visible_wrapped(cw, rect.h)
      else
        @scroll_sub = 0
        ensure_visible(rect.h)
        ensure_visible_x(cw) # slide @xscroll so the caret stays on screen (no-op unless follow_x?)
      end
      styled = highlight ? highlighted(highlight) : nil
      rows = visible_rows(cw, rect.h)
      @last_rows = rows
      # The visual row the caret lives on, decided ONCE by Wrap::Layout#row_of — the same
      # function the click inverse and the goal-column move consult, so the three cannot
      # disagree about which row owns a caret sitting exactly on a wrap break.
      caret_sub = wrapping? ? layout_of(@cy, cw).row_of(caret_index(@cy)) : 0
      # Buffer char-offset of the first visible line — advanced per row so each line
      # knows its start for the bg-region overlay without an O(n²) rescan. Only the
      # opt-in bg_regions consumer (the Fuzzer template) pays the O(@scroll) prefix sum;
      # Repeater/Notes (no regions) skip it so their hot path is unchanged.
      line_off = 0
      (0...@scroll).each { |k| line_off += @lines[k].size + 1 } unless @bg_regions.empty? && @conceal_spans.empty? # +1 for '\n'
      cur_li = @scroll
      caret_cell = nil.as({Int32, Int32}?) # the drawn caret's screen cell — anchors the env-complete popup
      rows.each_with_index do |vr, i|
        li = vr.li
        # Walk `line_off` up to this row's logical line. Rows arrive in document order, so
        # the whole loop is still one pass over the visible lines (continuation rows of the
        # same line don't advance it — they share their line's start offset).
        while cur_li < li
          line_off += @lines[cur_li].size + 1
          cur_li += 1
        end
        # The line number rides the FIRST visual row of a logical line and nothing else
        # (Burp style). A continuation row gets a blank of the same width rather than no
        # write at all, so the text column stays put and no stale digits survive there.
        if @gutter
          if vr.sub == 0
            Gutter.draw(screen, rect.x, rect.y + i, li, gw, current: li == @cy)
          else
            screen.text(rect.x, rect.y + i, " " * {gw - 1, 0}.max, Theme.muted, width: gw)
          end
        end
        composing = li == @cy && !@preedit.empty?
        # `drawn_line` folds the IME preedit into the caret line: under wrap the composing
        # text is what shifts the break, so layout, draw, caret and click must all measure
        # the SAME string or the row the caret sits on isn't the row it was laid out on.
        line = drawn_line(li)
        a, b = vr.a, vr.b
        whole = a == 0 && b == line.size
        seg = whole ? line : line[a...b]
        # Concealed lines (a §…§ marker with a hidden ¦chain) go through a dedicated draw:
        # delete the concealed chars from the styled line, then slice + draw. The
        # IME-preedit caret line is left raw (its columns shift with the composing text).
        cr = (@conceal_spans.empty? || composing) ? nil : line_conceal(line_off, line.size)
        if cr && !cr.empty? && !@reveal
          draw_concealed_line(screen, cx0, rect.y + i, li, line, styled, cr, cw, a, b)
        elsif @xscroll > 0 # unwrapped editors only — `wrap=` pins @xscroll at 0
          draw_scrolled(screen, cx0, rect.y + i, li, line, styled, cw)
        elsif @reveal
          Highlight.draw(screen, cx0, rect.y + i, Reveal.styled(seg, false, cw), width: cw)
        elsif composing && wrapping?
          # The styled overlay is built from the BUFFER and so cannot describe the
          # composing text; under wrap it is part of the laid-out line, so it is drawn
          # from spans instead. (Unwrapped editors keep the legacy order below, where a
          # highlighted line wins and the preedit shows only through the caret glyph.)
          Highlight.draw(screen, cx0, rect.y + i, preedit_spans(line, a, b), width: cw)
        elsif styled && (sl = styled_line(styled, li))
          Highlight.draw(screen, cx0, rect.y + i, Highlight.slice_chars(sl, a, b), width: cw)
        else
          if composing
            prefix = line[0, @cx]
            suffix = line[@cx..]
            px = cx0
            if !prefix.empty?
              screen.text(px, rect.y + i, prefix, Theme.text, width: cw)
              px += Screen.draw_width(prefix) # ≥1/cluster, matching the drawn cells + caret math
            end
            if !@preedit.empty?
              screen.text(px, rect.y + i, @preedit, Theme.text, attr: Attribute::Underline, width: cw - (px - cx0))
              # draw_width, not display_width (#289): `screen.text` just drew the preedit by
              # CLUSTER with a ≥1 floor, so the advance has to be measured the same way or
              # the suffix is laid down on top of the composing text. The two differ when a
              # preedit carries a control or zero-width codepoint — see ensure_visible_x for
              # what the IME actually sends.
              px += Screen.draw_width(@preedit)
            end
            if !suffix.empty?
              screen.text(px, rect.y + i, suffix, Theme.text, width: cw - (px - cx0))
            end
          else
            screen.text(cx0, rect.y + i, seg, Theme.text, width: cw)
          end
        end
        # Marker tint UNDER search/cursor — skip the IME-preedit line (its columns are
        # shifted by the composing text, which isn't in the buffer line). paint_bg_regions
        # itself no-ops when there are no regions or in reveal mode.
        paint_bg_regions(screen, cx0, rect.y + i, line_off, @lines[li], cw, cr, a, b) unless composing
        unless @search_hl.empty?
          # ONE scan for both modes: over the WHOLE logical line, each hit clipped to this
          # row (so a match straddling a wrap break lights up on both rows instead of on
          # neither) and shifted by @xscroll, which is 0 whenever the editor wraps.
          #
          # The h-scrolled branch this replaces marked the RAW line and ignored `cr`, while
          # `draw_concealed_line` had DELETED the concealed ¦chain run from what it drew — so
          # on a marker line every hit past a marker painted a second, highlighted copy of the
          # query to the right of the real one. Unreachable while wrap was a per-editor
          # constant (the two editors with conceal both wrapped); the Display preference can
          # now send them down this path.
          Wrap.mark_search(screen, cx0, rect.y + i, line, a, b, @search_hl, cx0 + cw, cr,
            xoff: @xscroll)
        end
        # The INS selection tint, over the text and the search marks, under the caret —
        # the same stacking (and the same `Theme.accent_bg`) the READ-mode over-painter
        # uses, so the band does not change appearance when `i` is pressed. `cursor` is the
        # gate: it is on only in INSERT, which is exactly when the owner's read-mode painter
        # stands down, so the two selections can never be drawn at once.
        paint_selection(screen, cx0, rect.y + i, li, line, cr, a, b, cw) if cursor
        # The caret cell is captured for the caret line whether or not the block cursor
        # is drawn (cursor=false in NORMAL) — the value peek anchors to it in read mode too.
        # The block-cursor GLYPH itself still paints only when `cursor` (insert mode).
        next unless li == @cy && vr.sub == caret_sub
        ci = caret_index(li)
        # draw_width (not display_width): a raw control char in the prefix occupies a cell
        # and click-to-cursor counts it, so the caret must too — else it sits one column
        # left of the real position and paints over a glyph. Per CLUSTER, matching the draw
        # exactly: `@cx` rests only on cluster boundaries (snap_cx_to_cluster), so this is
        # single-valued and Wrap.row_index inverts it. Measured from the ROW's first char,
        # which is char 0 of the line whenever nothing wrapped.
        prefix_w = Wrap.row_col(line, cr, a, ci)
        # Unwrapped editors draw the preedit AFTER the buffer text without it being part of
        # `line`, so its width is added here; under wrap `drawn_line` already spliced it in.
        preedit_w = wrapping? ? 0 : Screen.draw_width(@preedit)
        cxs = cx0 + prefix_w + preedit_w - @xscroll
        if cxs >= cx0 && cxs < cx0 + cw
          caret_cell = {cxs, rect.y + i}
          if cursor
            screen.cursor(cxs, rect.y + i)
            # The cell under the block caret is the first VISIBLE glyph at/after @cx: on a
            # concealed line the raw char there may be a hidden `¦chain` byte, so skip past
            # any concealed run to the glyph the user actually sees (the closing §).
            r = @cx
            cr.each { |(ra, rb)| r = rb if r >= ra && r < rb } if cr && !cr.empty?
            # The whole CLUSTER at `r`, not `line[r]`: parking on `é` (e + U+0301) or a ZWJ
            # family has to invert the glyph the user sees, not its leading codepoint.
            ch = @preedit.empty? ? Screen.caret_glyph(line, r) : Screen.caret_glyph(@preedit, 0)
            # ONE write, never two. The accent still spans both columns of a width-2 glyph,
            # though NOT because the continuation carries the lead's colors — it doesn't;
            # Cell.continuation is a default-colored singleton. It works because termisu's
            # render_row_batch SKIPS continuation cells without breaking the SGR batch and
            # advances by the lead's width, so the lead's accent is still in effect across
            # the pair (verified against the real backend for both CJK and a ZWJ family).
            # The second write was not merely redundant but destructive: it landed ON the
            # continuation, and a write there orphans the lead, which the backend blanks
            # (mirroring termisu's clear_continuation_owner). The caret therefore ERASED
            # the very glyph it was highlighting — the long-standing "caret blanks a
            # Hangul/CJK glyph" bug. MemoryBackend models continuation cells now, so this
            # is covered rather than invisible to every spec in the suite.
            #
            # A wide glyph whose continuation would land outside the pane is drawn as a
            # space instead. The claim happens during the glyph's OWN write, so the `break`
            # this loop used to do on its second iteration was already too late to keep the
            # caret off the pane border.
            wide = Screen.grapheme_cols(ch.to_s) == 2
            cch = (wide && cxs + 1 >= cx0 + cw) ? ' ' : ch
            screen.cell(cxs, rect.y + i, cch, Theme.bg, Theme.accent)
          end
        end
      end
      # The gauge stays in LOGICAL lines under wrap — a deliberate approximation, not an
      # oversight. Sizing it in visual rows means knowing how many the whole buffer has,
      # which is the one O(document) question this design exists to never ask (see
      # @scroll_sub). The thumb therefore tracks the anchor LINE and can step unevenly on a
      # heavily wrapped buffer; it is a proportion indicator, not a coordinate.
      Frame.scroll_gauge(screen, rect, @lines.size, @scroll, gauge_focused) if gauge
      # The env-complete dropdown + value peek paint LAST (over the text, anchored at the
      # caret) so they never render when the caret is off-screen.
      render_env_popups(screen, caret_cell, rect, cursor, peek)
    end

    # --- soft-wrap layout ------------------------------------------------------
    # Everything below is inert (or trivially one-row-per-line) while @wrap is off.

    # Wrap is only meaningful once a render has told us how wide the content column is —
    # every mapping outside render (move / click / at_top? / wheel) needs that width, and
    # guessing one would put the caret on a different row than the draw did.
    private def wrapping? : Bool
      wrap_on? && @last_cw > 0
    end

    # This editor's opt-in AND the app-wide preference (Preferences ▸ Appearance ▸ Display).
    # Read live, not latched into `@wrap`, so the toggle reaches editors built at startup;
    # every mapping here goes through `wrapping?` per call, so a flip lands on the next frame.
    # No memo is dropped on the flip — a `Wrap::Layout` is a pure function of (line, width,
    # conceal), so one built while wrapping is still correct when wrap comes back.
    private def wrap_on? : Bool
      @wrap && Settings.wrap_lines?
    end

    # Logical line `li` AS DRAWN: the buffer line, with any IME preedit spliced in at the
    # caret. One string for layout, draw, caret and click, so the composing text cannot
    # move the wrap break out from under the caret that produced it.
    private def drawn_line(li : Int32) : String
      line = @lines[li]
      return line unless wrapping? && li == @cy && !@preedit.empty?
      cx = @cx.clamp(0, line.size)
      "#{line[0, cx]}#{@preedit}#{line[cx..]}"
    end

    # The caret's index into `drawn_line(li)` — past the composing text, which is where an
    # insertion point belongs.
    private def caret_index(li : Int32) : Int32
      return @cx unless wrapping? && li == @cy && !@preedit.empty?
      @cx.clamp(0, @lines[li].size) + @preedit.size
    end

    # The wrap of line `li` at content width `cw`, memoized on (@edits, cw).
    #
    # The memo is what keeps a keystroke cheap: without it every frame re-wraps every
    # visible line, and with a multi-MB minified body that is a grapheme walk over
    # megabytes per frame. The memo alone would not be enough either — which is why
    # `Wrap::Layout` stores no per-row table for an ASCII line — but together they make the
    # common case (a big ASCII body, scrolled) O(1) per row with no allocation at all.
    private def layout_of(li : Int32, cw : Int32) : Wrap::Layout
      cr = @conceal_spans.empty? ? nil : line_conceal(line_start_offset(li), @lines[li].size)
      # The caret line while an IME is composing changes with every jamo WITHOUT bumping
      # @edits, so it must never enter the memo — a stale layout there desyncs the caret
      # from the row it is drawn on.
      return Wrap.layout(drawn_line(li), cw, cr) if li == @cy && !@preedit.empty?
      if @wrap_rev != @edits || @wrap_w != cw
        @wrap_cache.clear
        @wrap_rev = @edits
        @wrap_w = cw
      end
      if hit = @wrap_cache[li]?
        return hit
      end
      @wrap_cache.clear if @wrap_cache.size >= WRAP_CACHE_CAP
      @wrap_cache[li] = Wrap.layout(@lines[li], cw, cr)
    end

    # A `Wrap` layout provider bound to this buffer at content width `cw`.
    private def layout_fn(cw : Int32) : Int32 -> Wrap::Layout
      ->(i : Int32) { layout_of(i, cw) }
    end

    # The rows the pane shows, top to bottom, starting at the (line, sub-row) anchor.
    # Without wrap this is the identity it always was: one row per logical line from
    # @scroll, `sub` 0, the whole line.
    private def visible_rows(cw : Int32, h : Int32) : Array(VRow)
      unless wrapping?
        rows = Array(VRow).new({h, 0}.max)
        return rows if h <= 0
        (0...h).each do |i|
          li = @scroll + i
          break if li >= @lines.size
          rows << VRow.new(li, 0, 0, @lines[li].size)
        end
        return rows
      end
      @scroll = @scroll.clamp(0, @lines.size - 1)
      Wrap.rows(@scroll, @scroll_sub, h, @lines.size, layout_fn(cw))
    end

    # Wrapped companion to `ensure_visible`: keep the caret's VISUAL row inside the pane.
    # The walk itself is `Wrap.ensure_visible` (shared with the Repeater response pane).
    private def ensure_visible_wrapped(cw : Int32, h : Int32) : Nil
      return if h <= 0 || cw <= 0
      @scroll = @scroll.clamp(0, @lines.size - 1)
      csub = layout_of(@cy, cw).row_of(caret_index(@cy))
      @scroll, @scroll_sub = Wrap.ensure_visible(@scroll, @scroll_sub, @cy, csub, h, layout_fn(cw))
    end

    # Place the anchor `back` visual rows above (li, sub).
    private def anchor_back_from(li : Int32, sub : Int32, back : Int32, cw : Int32) : Nil
      @scroll, @scroll_sub = Wrap.step_back(li, sub, back, layout_fn(cw))
    end

    # Move the anchor `step` visual rows (negative = up), stopping at the buffer's ends.
    private def advance_anchor(step : Int32, cw : Int32) : Nil
      @scroll, @scroll_sub = if step < 0
                               Wrap.step_back(@scroll, @scroll_sub, -step, layout_fn(cw))
                             else
                               Wrap.step_forward(@scroll, @scroll_sub, step, @lines.size, layout_fn(cw))
                             end
    end

    # ↑/↓ across wrapped rows: step `dr` VISUAL rows, keeping the caret's display column.
    private def move_visual(dr : Int32) : Nil
      @cy, @cx = visual_row_target(dr) || return
      snap_cx_to_cluster(0) # row_index already lands on a boundary; cheap guard for the empty-row case
    end

    # Where the caret would land `dr` VISUAL rows away, or nil when this editor has nothing
    # to wrap (soft wrap off, or no render has measured the content width yet) — in which
    # case a visual row IS a logical line and the caller's plain step is already right.
    #
    # Public because NORMAL mode's caret is driven from outside, by `TextReadState`, and it
    # has to move exactly where an INSERT-mode arrow would: this editor owns the wrap memo
    # and the conceal spans, so the alternative is a second layout somewhere that cannot
    # see either. Reports only the destination and touches no state — the read model plants
    # its own anchor and writes back through `place_cursor`.
    def visual_row_target(dr : Int32) : {Int32, Int32}?
      return nil unless wrapping?
      return nil if dr == 0
      cw = @last_cw
      conceal_at = if @conceal_spans.empty?
                     nil
                   else
                     ->(i : Int32) : Array({Int32, Int32})? { line_conceal(line_start_offset(i), @lines[i].size) }
                   end
      Wrap.step_caret(@cy, @cx, dr, @lines.size,
        ->(i : Int32) { @lines[i] },
        ->(i : Int32) { layout_of(i, cw) },
        conceal_at)
    end

    # The composing caret line as spans: buffer text, the preedit underlined, buffer text —
    # sliced to the visual row `[a, b)`. Only reached under wrap (see the draw dispatch).
    private def preedit_spans(line : String, a : Int32, b : Int32) : Highlight::Line
      cx = @cx.clamp(0, @lines[@cy].size)
      pe = cx + @preedit.size
      spans = Highlight::Line.new
      add = ->(lo : Int32, hi : Int32, attr : Attribute) do
        s = {lo, a}.max
        e = {hi, b}.min
        spans << Highlight::Span.new(line[s...e], Theme.text, attr) if s < e
      end
      add.call(0, cx, Attribute::None)
      add.call(cx, pe, Attribute::Underline)
      add.call(pe, line.size, Attribute::None)
      spans
    end

    # The caret-anchored `$ENV` overlays, drawn after the text. The autocomplete dropdown
    # shows only in INSERT (cursor) while a `$partial` is typed; the value peek shows the
    # resolved value of a COMPLETE token under the caret in NORMAL (peek) OR INSERT, but
    # never while the dropdown owns the caret. The peek is re-derived each frame from
    # @cx/@cy, so moving the cursor off the token closes it without any explicit event.
    private def render_env_popups(screen : Screen, caret_cell : {Int32, Int32}?,
                                  rect : Rect, cursor : Bool, peek : Bool) : Nil
      ec = @env_complete
      if cursor && (cc = caret_cell) && ec
        ec.render(screen, cc[0], cc[1], rect)
      end
      # Chain tooltip takes precedence over the env peek — but only when it has a chain to
      # reveal; `render_chain_peek` owns that tie-break (a `§$KEY§` marker is a real shape).
      return if render_chain_peek(screen, caret_cell, rect, cursor, peek, ec)
      ep = @env_peek
      return unless ep
      # Suppress the peek only while the autocomplete dropdown is ACTUALLY on screen (insert
      # mode + open). In NORMAL mode the dropdown never renders, so a stale-open `ec` (left by
      # a cursor move mid-token) must not hide the peek.
      dropdown_visible = cursor && ec && ec.open?
      if (cursor || peek) && (cc = caret_cell) && !dropdown_visible && (tok = env_token_at_cursor)
        ep.set(tok[0], tok[1], Settings.env_prefix)
        ep.render(screen, cc[0], cc[1], rect)
      else
        ep.close
      end
    end

    # The chain tooltip pass: when the caret sits in a §…§ marker (owner-fed via
    # @chain_peek_text) and the editor is focused, reveal the concealed chain at the caret
    # and suppress the env peek. Returns true when it took over (the caller then skips the
    # env peek). No-op (false) when the tooltip is disabled or the caret isn't in a marker.
    private def render_chain_peek(screen : Screen, caret_cell : {Int32, Int32}?, rect : Rect,
                                  cursor : Bool, peek : Bool, ec : EnvComplete?) : Bool
      cp = @chain_peek
      return false unless cp
      chain = @chain_peek_text
      # An EMPTY chain draws the affordance only ("no chain yet · ^Y edit"), so it YIELDS to a
      # `$KEY` peek under the same caret: `§$HOST§` is an ordinary marker, and the resolved
      # value is a datum nothing else on screen shows, where the hint is a standing reminder
      # that will be there on the next keystroke too. A non-empty chain still wins — it reveals
      # bytes concealed in the buffer, which is the one thing only this tooltip can do.
      if chain && (cursor || peek) && (cc = caret_cell) && !(cursor && ec && ec.open?) &&
         !(chain.empty? && @env_peek && env_token_at_cursor)
        cp.set(chain, @chain_peek_hint)
        cp.render(screen, cc[0], cc[1], rect)
        @env_peek.try(&.close)
        return true
      end
      cp.close
      false
    end

    # Band the INS selection over ONE visual row `[a, b)` of logical line `li`.
    #
    # The span is clipped to the row rather than to the line, which is the whole reason this
    # is per-row: a selection running off the right edge of a wrapped row must tint that row
    # to its end AND continue on the next one. Clipping to the line instead paints the band
    # once, at the columns of the first row, and leaves the rest of the selection looking
    # unselected — the exact failure the wrap layer introduced for every over-painter.
    #
    # Derived from `selection_range` in O(1) per row instead of asking `ReadCursor` for the
    # whole span list: that walk is O(the selection), and a selection here can cover a
    # multi-MB response body pasted into the request. It mirrors ReadCursor#highlight_spans'
    # rule exactly — first line from its column to EOL, last line to its column, everything
    # between whole — with the columns already put in document order by `selection_range`.
    private def paint_selection(screen : Screen, cx0 : Int32, y : Int32, li : Int32, line : String,
                                cr : Array({Int32, Int32})?, a : Int32, b : Int32, cw : Int32) : Nil
      return if @sel_anchor.nil?
      return if @reveal                       # reveal rewrites the glyphs — see paint_bg_regions
      return if li == @cy && !@preedit.empty? # composing: `line` holds text the buffer offsets don't index
      return unless r = selection_range
      y0, x0, y1, x1 = r
      return if li < y0 || li > y1
      lo = {li == y0 ? x0 : 0, a}.max
      hi = {li == y1 ? x1 : line.size, b}.min
      paint_band(screen, cx0, y, line, cr, a, lo, hi, cw)
    end

    # --- READ-mode over-paint seam --------------------------------------------------------
    # The NORMAL-mode selection band and block caret are drawn by the OWNER (the Repeater's
    # request pane, the Fuzzer template, Notes, …): that selection lives in a `ReadCursor` this
    # widget deliberately does not model. The COLUMN MATH, though, is this widget's — and both
    # owners of a CONCEALING editor had re-derived it without the concealed runs, which is two
    # separate wrongs at once:
    #
    #   * measured on the raw line, the caret and the band land N columns right of the text they
    #     address, N being the width of the `¦chain` runs hidden to their left; and
    #   * each band chunk RE-DRAWS its own text, so painting from the raw line put the hidden
    #     chain back on screen — selecting a line UNCONCEALED it and shifted the rest of the row.
    #
    # Both were live in the Repeater's request pane and the Fuzzer template, the two places an
    # operator actually writes `§value¦chain§`. The copy was correct throughout (it reads buffer
    # coordinates), so the band highlighted different bytes than `y` put on the clipboard.
    #
    # These two methods are the same measure and the same conceal walk `render` uses for the
    # INSERT band, exposed so an owner cannot derive a second, conceal-blind one.

    # This line's concealed runs in LINE-local char coords, or nil when nothing is hidden there
    # (which is every editor that never sets `conceal_spans`, and every line of one that does).
    def conceal_of(li : Int32) : Array({Int32, Int32})?
      return nil if @conceal_spans.empty? || @reveal
      line = @lines[li]? || return nil
      cr = line_conceal(line_start_offset(li), line.size)
      cr.empty? ? nil : cr
    end

    # Where a READ block caret for buffer index `cx` on line `li` belongs: its drawn column
    # (measured from `row_start`, which is the wrap break for a continuation row) and the first
    # VISIBLE glyph at or after it — a caret parked on a hidden `¦chain` byte has to invert the
    # glyph the operator can actually see, which is the closing `§`. `render` computes exactly
    # this pair for the INSERT caret.
    def read_caret_cell(li : Int32, cx : Int32, row_start : Int32 = 0) : {Int32, Char | String}
      line = @lines[li]? || ""
      cr = conceal_of(li)
      col = Wrap.row_col(line, cr, row_start, cx)
      r = cx
      cr.each { |(ra, rb)| r = rb if r >= ra && r < rb } if cr
      {col, Screen.caret_glyph(line, r)}
    end

    # Paint `[x0, x1)` of line `li` on the selection background, clipped to the drawn row
    # `[row_start, row_end)` and split around this editor's concealed runs. `cx0` is the row's
    # first content cell (past the gutter); `cw` its width.
    def paint_read_band(screen : Screen, cx0 : Int32, y : Int32, li : Int32,
                        x0 : Int32, x1 : Int32, row_start : Int32, row_end : Int32, cw : Int32) : Nil
      line = @lines[li]? || return
      lo = {x0, row_start}.max
      hi = {x1, row_end < 0 ? line.size : row_end}.min
      paint_band(screen, cx0, y, line, conceal_of(li), row_start, lo, hi, cw)
    end

    # `[lo, hi)` of `line` on the selection background, split around the concealed runs in `cr`.
    #
    # A concealed `¦chain` occupies no cells, so the band is laid down as the VISIBLE runs between
    # the hidden ones; painting straight through would tint cells the chain's neighbours are
    # standing in, shift the rest of the row's tint right by its length, and — because each chunk
    # RE-DRAWS its own text — put the hidden chain back on screen.
    private def paint_band(screen : Screen, cx0 : Int32, y : Int32, line : String,
                           cr : Array({Int32, Int32})?, row_start : Int32,
                           lo : Int32, hi : Int32, cw : Int32) : Nil
      return if lo >= hi
      if cr.nil? || cr.empty?
        paint_sel_chunk(screen, cx0, y, line, cr, row_start, lo, hi, cw)
        return
      end
      chunk = lo
      i = lo
      while i < hi
        if run = cr.find { |(ra, rb)| i >= ra && i < rb }
          paint_sel_chunk(screen, cx0, y, line, cr, row_start, chunk, i, cw)
          i = {run[1], hi}.min
          chunk = i
        else
          i += 1
        end
      end
      paint_sel_chunk(screen, cx0, y, line, cr, row_start, chunk, hi, cw)
    end

    # One contiguous, fully-visible `[s, e)` of the row that starts at `row_start`, re-drawn
    # on the selection background. Columns come from `Wrap.row_col` — the measure the base
    # draw, the caret and the click all use — so the band covers exactly the cells the text
    # was put in, wide glyphs and tabs included.
    private def paint_sel_chunk(screen : Screen, cx0 : Int32, y : Int32, line : String,
                                cr : Array({Int32, Int32})?, row_start : Int32,
                                s : Int32, e : Int32, cw : Int32) : Nil
      return if s >= e
      from = Wrap.row_col(line, cr, row_start, s) - @xscroll
      to = {Wrap.row_col(line, cr, row_start, e) - @xscroll, cw}.min
      seg = line[s...e]
      if from < 0 # h-scrolled off the left edge (unwrapped follow_x editors only)
        seg = Highlight.slice_left_text(seg, -from)
        from = 0
      end
      return if from >= to || seg.empty?
      screen.text(cx0 + from, y, seg, Theme.text, Theme.accent_bg, width: to - from)
    end

    # Overlay the bg_regions intersecting THIS line. `off0` is the line's start offset
    # in the full LF-joined buffer. Column math mirrors the base draw + caret
    # (Screen.draw_width / grapheme_cols ≥1 per cluster, so a tab in a marker band can't
    # drift the tint left of the cells). Multi-line regions clamp to [0, line.size): first
    # line tints col→EOL, fully-covered lines 0→size, last line BOL→col; the '\n' offset
    # has no cell. Region columns are computed against the FULL (unscrolled) line, then
    # shifted left by @xscroll and clipped to the visible window — always a no-op today, since
    # the only editors that set bg_regions (the Fuzzer template, the Repeater request pane)
    # soft-wrap, and `wrap=` pins @xscroll at 0 for good.
    #
    # `rs`/`re` bound the VISUAL ROW being painted: the whole line without wrap, one wrapped
    # slice of it with. A region is clipped to the row, so a marker that spans a wrap break
    # is banded on every row it covers rather than once, in the wrong cells.
    private def paint_bg_regions(screen : Screen, cx0 : Int32, y : Int32, off0 : Int32,
                                 line : String, cw : Int32, cr : Array({Int32, Int32})? = nil,
                                 rs : Int32 = 0, re : Int32 = -1) : Nil
      return if @bg_regions.empty? || @reveal # opt-in; reveal rewrites the glyphs
      re = line.size if re < 0
      return paint_bg_regions_concealed(screen, cx0, y, off0, line, cw, cr, rs, re) if cr && !cr.empty?
      line_end = off0 + line.size
      @bg_regions.each do |(a, b, color)|
        next if b <= off0 || a >= line_end # region doesn't touch this line
        la = (a - off0).clamp(rs, re)
        lb = (b - off0).clamp(rs, re)
        next if la >= lb
        start_col = Wrap.row_col(line, nil, rs, la) - @xscroll
        end_col = Wrap.row_col(line, nil, rs, lb) - @xscroll
        draw_from = {start_col, 0}.max
        draw_to = {end_col, cw}.min
        next if draw_from >= draw_to
        seg = Highlight.slice_left_text(line[la, lb - la], draw_from - start_col)
        screen.text(cx0 + draw_from, y, seg, Theme.marker_fg, color, width: draw_to - draw_from)
      end
    end

    # Band over-paint for a line whose §…§ markers hide a ¦chain: re-draw only the VISIBLE
    # marker glyphs (concealed chars occupy no cell) at their concealed display columns,
    # matching what the base Highlight.draw already put on screen. The glyph right after
    # each concealed run — the closing § — is accented so a chained marker reads distinctly
    # from a plain one; the rest keep Theme.marker_fg.
    private def paint_bg_regions_concealed(screen : Screen, cx0 : Int32, y : Int32, off0 : Int32,
                                           line : String, cw : Int32, cr : Array({Int32, Int32}),
                                           rs : Int32 = 0, re : Int32 = -1) : Nil
      re = line.size if re < 0
      line_end = off0 + line.size
      @bg_regions.each do |(a, b, color)|
        next if b <= off0 || a >= line_end
        la = (a - off0).clamp(rs, re)
        lb = (b - off0).clamp(rs, re)
        next if la >= lb
        col = Wrap.row_col(line, cr, rs, la) # display columns before the first drawn char, within this row
        i = la
        while i < lb
          hit = cr.find { |(ra, rb)| i >= ra && i < rb }
          if hit
            i = hit[1] # skip the hidden run in one hop
            next
          end
          w = Screen.grapheme_cols(line[i].to_s)
          sx = cx0 + col - @xscroll
          if sx >= cx0 && sx < cx0 + cw
            accent = cr.any? { |(_, rb)| rb == i } # char immediately after a concealed run = closing §
            screen.text(sx, y, line[i].to_s, accent ? Theme.marker_accent : Theme.marker_fg, color, width: {cx0 + cw - sx, 1}.max)
          end
          col += w
          i += 1
        end
      end
    end

    # --- display concealment (opt-in @conceal_spans) -------------------------
    # Everything below no-ops (or isn't reached) when @conceal_spans is empty, so every
    # editor but the Repeater/Fuzzer request editors keeps its exact column math.

    # Line-LOCAL conceal ranges for the line spanning full-buffer offsets [off0, off0+size),
    # sorted, clamped to [0, size). Empty when no span touches this line.
    private def line_conceal(off0 : Int32, size : Int32) : Array({Int32, Int32})
      out = [] of {Int32, Int32}
      line_end = off0 + size
      @conceal_spans.each do |(a, b)|
        next if b <= off0 || a >= line_end
        la = (a - off0).clamp(0, size)
        lb = (b - off0).clamp(0, size)
        out << {la, lb} if la < lb
      end
      out.sort_by!(&.[0]) if out.size > 1
      out
    end

    # Full-buffer char offset of line `cy`'s first char (only reached when concealing),
    # memoized on @edits.
    #
    # It used to walk the buffer per call, which was tolerable when `snap_cx_out_of_conceal`
    # was the only caller — once per caret move. Soft wrap needs the conceal ranges of every
    # VISIBLE line to lay it out, so a linear walk per line turns one frame into
    # O(lines × rows). The table is built once per edit and read h times instead.
    private def line_start_offset(cy : Int32) : Int32
      if @line_off_rev != @edits
        @line_off_rev = @edits
        offs = Array(Int32).new(@lines.size + 1)
        acc = 0
        @lines.each do |l|
          offs << acc
          acc += l.size + 1 # +1 for the joining '\n'
        end
        offs << acc
        @line_offs = offs
      end
      @line_offs[cy.clamp(0, @lines.size)]
    end

    # NOTE: the three concealed-column helpers that used to live here — `concealed_col`,
    # `concealed_display_prefix` (a verbatim duplicate of it) and `concealed_col_to_raw` —
    # are gone. `Wrap.row_col` / `Wrap.row_index` are the same measure and the same inverse,
    # generalised over a row's starting offset (which is 0 for an unwrapped line, so the
    # behaviour is identical), and folding them together is the point: this file's standing
    # hazard is a second nearly-identical width measure drifting from the one the draw uses.

    # Pull @cx onto a grapheme-CLUSTER boundary. `@cx` stays a CHARACTER index — conceal
    # ranges, bg_regions, marker spans and the search / find-replace offsets are all char-
    # or byte-indexed and come from string operations rather than caret motion, so
    # renumbering it would break every one of them — but it may only ever REST on a
    # boundary. That is what makes `Screen.draw_width(line[0, @cx])` single-valued (it
    # returns the same column for all 7 char indices inside a ZWJ family) and therefore
    # exactly invertible by `Screen.column_for`, so caret and click agree by construction.
    #
    # `dir` is the travel sign: > 0 rounds up to the cluster's far edge (→ crosses the
    # whole glyph), < 0 rounds down to its start, 0 rounds down (vertical move, click,
    # clamp after an external edit). Called at EVERY @cx mutation point, not just `move` —
    # an insert can merge the caret's char into the preceding cluster, and a caller-
    # supplied index (place_cursor / place_at_offset / undo) is unconstrained.
    # Both helpers no-op cheaply when @cx is already on a boundary (Screen.boundary?), so
    # ordinary typing never pays for the grapheme walk.
    private def snap_cx_to_cluster(dir : Int32) : Nil
      line = @lines[@cy]
      @cx = dir > 0 ? Screen.cluster_end(line, @cx) : Screen.cluster_start(line, @cx)
    end

    # Pull @cx out of the "no-rest zone" `(a, b]` of a concealed run so the caret can't
    # land where an edit would touch UNSEEN bytes: the interior chars AND the boundary
    # `@cx == b` (just before the visible closing glyph, where backspace would delete the
    # last hidden char and typing would insert into the hidden run). Only `a` (the run's
    # left edge, on visible bytes) and `b + 1` (past the closing glyph) are legal rests —
    # and they sit at the same column / the next column, so crossing the whole run is one
    # keypress in each direction (no dead press). `dir` is the travel sign.
    #
    # Runs LAST, after snap_cx_to_cluster, because resting on a hidden byte corrupts the
    # buffer while resting mid-cluster only mispaints — so this one gets the final word.
    # Both landing sites stay cluster-legal, but not for the reason one might guess: the
    # delimiters are `¦` U+00A6 and `§` U+00A7, which are NOT ASCII. What matters is that
    # both are Grapheme_Cluster_Break=Other, so each always BEGINS a cluster no matter what
    # precedes it — hence `a` (the `¦`) is provably a boundary and needs no snap. `b + 1`
    # is not: it is the index AFTER the closing `§`, and a combining mark typed right there
    # binds to that `§`, making b + 1 cluster interior. So round it up. Forward is the only
    # safe direction — it can only increase, staying clear of the `(a, b]` no-rest zone,
    # whereas rounding down would land on `b` itself, the one index this exists to avoid.
    private def snap_cx_out_of_conceal(dir : Int32) : Nil
      return if @conceal_spans.empty?
      line = @lines[@cy]
      line_conceal(line_start_offset(@cy), line.size).each do |(a, b)|
        next unless @cx > a && @cx <= b
        right = {Screen.cluster_end(line, b + 1), line.size}.min
        @cx = if dir > 0
                right
              elsif dir < 0
                a
              else
                (@cx - a <= right - @cx) ? a : right # vertical move / click: nearer legal edge
              end
        return
      end
    end

    # The highlight overlay for `kind` (:request/:response), cached until the
    # buffer content changes — so a held editor isn't re-tokenised 20×/sec.
    # The styled line at `li`, memoised for the run of visual rows that share it (see
    # @styled_line_li). Returns nil past the end so callers fall back to plain text.
    private def styled_line(w : Highlight::Windowed, li : Int32) : Highlight::Line?
      return nil unless 0 <= li < w.total
      return @styled_line if @styled_line_li == li && @styled_line
      line = w.line_at(li)
      @styled_line_li = li
      @styled_line = line
      line
    end

    # WINDOWED: the head is styled eagerly, the body kept raw and styled per VISIBLE line.
    #
    # This used to hand back a fully-styled array, and every mutation nils the memo — so each
    # typed character re-tokenised the whole buffer, twice for a request (`from_lines` maps
    # the lines, then maps them again through `with_env_tokens`). Measured on
    # bench/text_area_keystroke_bench.cr, per keystroke including the frame:
    #
    #     1 KB /    31 lines   0.039 ms
    #    64 KB / 1,644 lines   1.04  ms
    #   512 KB / 13,113 lines  5.53  ms
    #
    # i.e. linear in buffer size on the path an operator holds a key down in (Repeater,
    # Fuzzer, Intercept, Rewriter, JWT). Windowed, it is linear in the ~40 rows on screen.
    #
    # Markdown stays eager and is wrapped: its syntax spans lines (a fenced block opened
    # above the viewport changes how the visible ones read), so styling a window of it in
    # isolation would be wrong rather than merely slower.
    private def highlighted(kind : Symbol) : Highlight::Windowed
      cached = @styled
      env_rev = Env.highlight_rev
      return cached if cached && @styled_kind == kind && @styled_rev == Theme.revision && @styled_env_rev == env_rev
      @styled_kind = kind
      @styled_rev = Theme.revision
      @styled_env_rev = env_rev
      @styled_line_li = -1
      @styled_line = nil
      @styled =
        if kind == :markdown
          Highlight.eager_window(Highlight.markdown(@lines))
        else
          request = kind == :request
          Highlight.from_lines_windowed(@lines, request,
            env_tokens: request, literal: @env_literal_names)
        end
    end

    private def ensure_visible(h : Int32) : Nil
      return if h <= 0
      @scroll = @cy if @cy < @scroll
      @scroll = @cy - h + 1 if @cy >= @scroll + h
      @scroll = 0 if @scroll < 0
    end

    # Horizontal companion to ensure_visible: slide @xscroll so the caret (cursor +
    # any IME preedit) stays inside the visible column window. A line that fits whole
    # resets to 0 (no needless side-scroll). No-op unless @follow_x, so every other
    # editor keeps @xscroll == 0 and renders exactly as before.
    private def ensure_visible_x(cw : Int32) : Nil
      return unless follow_x?
      return if cw <= 0
      line = @lines[@cy]
      # draw_width, not display_width (#289): the preedit is drawn by `screen.text` /
      # Highlight.draw, both per-cluster with a ≥1 floor, so the window has to be sized the
      # same way. What the IME actually puts here is whatever the terminal forwards in the
      # kitty keyboard protocol's text codepoints — termisu passes it through verbatim
      # (input/parser.cr emits Event::Preedit with the raw text, no normalisation), so gori
      # cannot assume a form. A Hangul IME composing 한 may send the precomposed syllable
      # U+D55C, a compatibility jamo U+314E, or conjoining jamo U+1112 U+1161 U+11AB; the
      # first two are one cluster and one codepoint, the third is one cluster of THREE. Only
      # a cluster measure is right for all of them, which is the collapse this file now
      # relies on everywhere else.
      pw = Screen.draw_width(@preedit)
      # On a concealed line, measure in CONCEALED columns — the hidden ¦chain doesn't take
      # cells, so the caret window must be sized/positioned against what's actually drawn.
      cr = @conceal_spans.empty? ? nil : line_conceal(line_start_offset(@cy), line.size)
      concealed = cr && !cr.empty?
      # draw_width (not display_width) to match the actual draw: a raw control char
      # occupies one drawn cell, so measuring it as width 0 here would let the caret render
      # outside the window (cursor detaches / no scroll-into-view).
      #
      # These columns used to be per-CODEPOINT, because the caret was: @cx is a char index
      # and `move` stepped it raw, so the caret could park inside a ZWJ/skin-tone cluster
      # while Highlight.slice_left consumed @xscroll in per-CLUSTER (drawn) columns. The two
      # disagreed by the cluster's "inflation" (1 column for a skin tone, 9 for a 4-person
      # family) and the view over-scrolled by that much. @cx now snaps to cluster boundaries
      # (snap_cx_to_cluster) and every measure here, in `cxs`/`prefix_w`, and in
      # Highlight.slice_left is draw_width, so the window, the slice and the caret finally
      # agree — that reconciliation was the caret-model change this comment used to defer.
      full = concealed ? Wrap.row_col(line, cr, 0, line.size) : Screen.draw_width(line)
      if full + pw <= cw
        @xscroll = 0
        return
      end
      cx = @cx.clamp(0, line.size)
      curx = (concealed ? Wrap.row_col(line, cr, 0, cx) : Screen.draw_width(line[0, cx])) + pw
      @xscroll = curx if curx < @xscroll                # caret left of the window → snap left
      @xscroll = curx - cw + 1 if curx >= @xscroll + cw # caret past the right edge → snap right
      @xscroll = 0 if @xscroll < 0
    end

    # Draw one visual row `[a, b)` of a line whose §…§ markers hide a ¦chain: cut the row
    # out of the styled line, delete the concealed chars from it (a single plain span when
    # highlighting is off), then h-scroll-slice and draw. The marker band + accented closing
    # § are over-painted afterwards by paint_bg_regions (concealment-aware). Only reached
    # when the line has conceal ranges; `[0, line.size)` — the whole line — without wrap.
    #
    # The conceal ranges are re-based onto the row before `Highlight.conceal` sees them:
    # that function indexes the LINE it is given, and the line it is given here is the row.
    private def draw_concealed_line(screen : Screen, cx0 : Int32, y : Int32, li : Int32,
                                    line : String, styled : Highlight::Windowed?,
                                    cr : Array({Int32, Int32}), cw : Int32,
                                    a : Int32 = 0, b : Int32 = -1) : Nil
      b = line.size if b < 0
      base = Highlight.slice_chars((styled ? styled_line(styled, li) : nil) || [Highlight::Span.new(line, Theme.text)], a, b)
      local = a == 0 ? cr : cr.compact_map do |(ra, rb)|
        lo = {ra, a}.max - a
        hi = {rb, b}.min - a
        lo < hi ? {lo, hi} : nil
      end
      cl = Highlight.conceal(base, local)
      cl = Highlight.slice_left(cl, @xscroll) if @xscroll > 0
      Highlight.draw(screen, cx0, y, cl, width: cw)
    end

    # The horizontally-scrolled per-line draw (only when @xscroll > 0): left-slice
    # the line by @xscroll display columns so the caret's neighbourhood is visible,
    # then reuse the normal drawers (which handle right truncation + the … ellipsis).
    private def draw_scrolled(screen : Screen, cx0 : Int32, y : Int32, li : Int32,
                              line : String, styled : Highlight::Windowed?, cw : Int32) : Nil
      if @reveal
        Highlight.draw(screen, cx0, y, Highlight.slice_left(Reveal.styled(line, false, cw + @xscroll), @xscroll), width: cw)
      elsif styled && (sl = styled_line(styled, li))
        Highlight.draw(screen, cx0, y, Highlight.slice_left(sl, @xscroll), width: cw)
      elsif li == @cy && !@preedit.empty?
        cx = @cx.clamp(0, line.size)
        spans = Highlight::Line.new
        spans << Highlight::Span.new(line[0, cx], Theme.text) if cx > 0
        spans << Highlight::Span.new(@preedit, Theme.text, Attribute::Underline) unless @preedit.empty?
        suffix = line[cx..]
        spans << Highlight::Span.new(suffix, Theme.text) unless suffix.empty?
        Highlight.draw(screen, cx0, y, Highlight.slice_left(spans, @xscroll), width: cw)
      else
        screen.text(cx0, y, Highlight.slice_left_text(line, @xscroll), Theme.text, width: cw)
      end
    end

    # Snapshot for undo, COALESCING a run of typing into one step.
    #
    # One snapshot per keystroke made ⌃Z a per-character rewind — five presses to take back
    # `HELLO` — and, worse, spent the whole 100-slot history on 100 characters: type two lines
    # and the state you actually wanted back had already been shifted off the bottom, silently
    # and with no way to reach it. Every GUI editor groups a typing run instead, and that is
    # what makes a bounded history usable rather than a rewind of the last two seconds.
    #
    # A run is consecutive `insert`s (a single printable character each) with the caret
    # advancing along ONE line: `@coalesce` names the {cy, cx} the next such insert must land
    # on. Anything else — a newline, a delete, a paste, an undo, an external edit, a caret
    # move, a run that reaches WORD_RUN characters — clears it and so opens a new step. The
    # boundary at a word break is deliberate: it keeps a long line from collapsing into one
    # all-or-nothing step, which is the other way this goes wrong.
    #
    # `force` is the caller's way of saying "this is a step of its own whatever came before"
    # — every edit path except `insert` passes it, since only typing coalesces.
    private def push_undo(force : Bool = true) : Nil
      if !force && (co = @coalesce) && co == {@cy, @cx} && @coalesce_len < WORD_RUN
        @coalesce_len += 1
        return # inside the current run — the step already on the stack covers it
      end
      @undo_stack << UndoState.new(@lines.dup, @eols.dup, @cy, @cx) # shallow: shares the immutable Strings
      @undo_stack.shift if @undo_stack.size > 100
      @coalesce_len = force ? 0 : 1
      @coalesce = nil
    end

    # Longest run of typing folded into one undo step. Roughly a long word: past this a step
    # is big enough that taking it back wholesale is its own surprise.
    WORD_RUN = 40

    # Called by `insert` AFTER the character has landed: the run continues only if the very
    # next insert arrives at the caret this one left behind. A word break ends the run, so
    # `hello world` is two steps and not one.
    private def continue_run(ch : Char) : Nil
      @coalesce = ch.whitespace? ? nil : {@cy, @cx}
    end

    # Break the current typing run — the next `insert` starts a fresh undo step. Called from
    # every caret move and every non-typing edit; a no-op when no run is open.
    private def break_run : Nil
      @coalesce = nil
    end

    def undo : Nil
      return if @undo_stack.empty?
      state = @undo_stack.pop
      @lines = state.lines # the snapshot is popped/unreferenced, so no defensive dup
      @eols = state.eols   # restored in lockstep — a desync would send a line's neighbour's ending
      if @lines.empty?
        @lines = [""]
        @eols = [""]
      end
      @cy = state.cy.clamp(0, @lines.size - 1)
      @cx = state.cx.clamp(0, @lines[@cy].size)
      snap_cx_to_cluster(0) # the snapshot's line may differ from the one we clamp against
      @sel_anchor = nil     # the anchor names offsets in the buffer the undo just replaced
      # Whatever run was open belonged to the state just discarded: typing after a ⌃Z must
      # start a NEW step, or the next character would fold itself into the step it restored
      # and a second ⌃Z would take back more than the operator typed.
      break_run
      @styled = nil
      @edits += 1
      refresh_env_complete
    end

    # --- `$ENV` autocomplete (opt-in) ----------------------------------------
    # Enable/disable the completion popup. Enabled editors get a live dropdown of
    # matching env vars while a `$partial` token is under the caret; disabled editors
    # keep @env_complete nil and every edit-path guard below short-circuits.
    def env_complete=(on : Bool) : Nil
      @env_complete = on ? (@env_complete || EnvComplete.new) : nil
      @env_peek = on ? (@env_peek || EnvPeek.new) : nil # the value peek rides the same opt-in
    end

    # The `$NAME`s that will NOT be substituted on send — see the ivar. Drops the styled
    # cache: the overlay it holds was built against the old answer, and nothing else in the
    # cache key (@edits, theme, Env.highlight_rev) moves when an owner re-seeds this.
    def env_literal_names=(names : Set(String)) : Nil
      return if names == @env_literal_names
      @env_literal_names = names
      @styled = nil
    end

    # Enable the chain tooltip (paired with @conceal_spans on the request editors).
    def chain_peek=(on : Bool) : Nil
      @chain_peek = on ? (@chain_peek || ChainPeek.new) : nil
    end

    # Per-frame feed: the chain of the §…§ marker under the caret, or nil when the caret
    # isn't in a marker at all. `""` is a marker WITHOUT a chain and still opens the tooltip
    # (as "no chain yet" + the hint) — that is the case where the operator has the least to
    # go on, so it is the one that most needs the affordance. The owner resolves it (it
    # knows the §-marker layout).
    def chain_peek_text=(chain : String?) : Nil
      @chain_peek_text = chain
    end

    # The right-aligned affordance on the chain tooltip's row. Per-surface: see
    # `ChainPeek::DEFAULT_HINT`.
    def chain_peek_hint=(hint : String) : Nil
      @chain_peek_hint = hint
    end

    def env_completing? : Bool
      (ec = @env_complete) ? ec.open? : false
    end

    def env_complete_close : Nil
      @env_complete.try(&.close)
    end

    # While the popup owns the keyboard: Tab/↵ accept, ↑/↓ (+ Shift-Tab) move the
    # selection, Esc closes. Returns true when consumed (the caller stops routing the key).
    def handle_env_complete_key(ev : Termisu::Event::Key) : Bool
      ec = @env_complete
      return false unless ec && ec.open?
      key = ev.key
      case
      when key.tab?, key.enter?   then env_accept(ec)
      when key.up?, key.back_tab? then ec.move(-1)
      when key.down?              then ec.move(1)
      when key.escape?            then ec.close
      else                             return false
      end
      true
    end

    private def env_accept(ec : EnvComplete) : Nil
      push_undo
      line = @lines[@cy]
      newline, ncx = ec.accept(line, @cx.clamp(0, line.size))
      @lines[@cy] = newline
      @cx = ncx.clamp(0, newline.size)
      snap_cx_to_cluster(1) # the expansion's tail can merge with the text it was spliced into
      ec.close
      @styled = nil
      @edits += 1
    end

    # Recompute the match set for the `$partial` token the caret sits in — the run of
    # env-key chars immediately left of the caret, which must be preceded by the prefix
    # sigil. Closes when there's no token, no registered vars, or the sole match is already
    # fully typed. Called after every insert-mode edit; a cheap no-op when disabled.
    private def refresh_env_complete : Nil
      ec = @env_complete
      return unless ec
      prefix = Settings.env_prefix
      return ec.close if prefix.empty?
      # `display_vars`, so a bound `$SESSION` completes beside the env vars — one syntax,
      # one dropdown. `declared` is read ONCE here, not per candidate row: it takes the
      # binding table's mutex.
      vars = Env.display_vars
      declared = Env.declared_bindings
      return ec.close if vars.empty?
      line = @lines[@cy]
      cx = @cx.clamp(0, line.size)
      plen = prefix.size
      ks = cx
      while ks > 0 && env_key_tail?(line[ks - 1])
        ks -= 1
      end
      # A prefix sigil must sit immediately before the key run (else it isn't an env token).
      return ec.close unless ks - plen >= 0 && line[(ks - plen)...ks] == prefix
      partial = line[ks...cx]
      # A non-empty partial must start with a valid key head — `$1` etc. never expand.
      return ec.close if !partial.empty? && !env_key_head?(partial[0])
      # Extend right over the rest of the key run so accepting replaces the whole identifier.
      ke = cx
      while ke < line.size && env_key_tail?(line[ke])
        ke += 1
      end
      pl = partial.downcase
      matches = vars.keys
        .select { |k| !@env_literal_names.includes?(k) } # offering one would promise a substitution this buffer won't make
        .select { |k| pl.empty? || k.downcase.starts_with?(pl) }
        .sort!
        .first(40)
        .map { |k| {k, env_value_preview(vars[k], declared.includes?(k))} }
      if matches.empty? || (matches.size == 1 && matches[0][0] == partial)
        ec.close # nothing to offer, or already fully typed
      else
        ec.set(matches, ks - plen, ke, prefix)
      end
    end

    private def env_key_head?(c : Char) : Bool
      c.ascii_letter? || c == '_'
    end

    private def env_key_tail?(c : Char) : Bool
      c.ascii_alphanumeric? || c == '_'
    end

    # A one-line, whitespace-collapsed, length-capped value hint for the dropdown row.
    #
    # A BINDING is masked and an env var is not, and the difference is deliberate. An env
    # var is what the operator typed, and the Project tab's ENV pane shows it in plaintext
    # two tabs over — hiding it here would be theatre. A binding value came off the wire, is
    # never printed anywhere else in gori, and is usually a credential; the length-capped
    # form showed its first 19 characters, which is right for `$HOST` and wrong for a
    # session cookie. `mask_preview` shows enough to tell two tokens apart and no more.
    private def env_value_preview(v : String, masked : Bool = false) : String
      return Bindings.mask_preview(v) if masked
      # This string is NOT guaranteed valid UTF-8: a binding value came off the wire, and an
      # env var can be set from argv (`gori run project env set`). PCRE2 RAISES on such a
      # subject rather than failing to match, and this runs on the render path, where there
      # is no rescue between here and `Runner#run` — so one bound response byte took the TUI
      # down while the operator was typing a `$KEY`.
      #
      # SCRUBBED, not refused, because unlike `searchable?` above the result is display-only
      # and never written back into the buffer — the same split `fuzz/matcher.cr` takes. The
      # `valid_encoding?` guard keeps the common path allocation-free (scrub always rebuilds).
      s = (v.valid_encoding? ? v : v.scrub).gsub(/\s+/, " ").strip
      s.size > 20 ? "#{s[0, 19]}…" : s
    end

    # The COMPLETE, REGISTERED `$KEY` env token the caret currently sits inside (or
    # immediately after), as {key, value-preview} — for the value peek. Scans the key run
    # around @cx, requires the prefix sigil right before it, and looks the key up in the
    # effective env vars. nil when the caret isn't on a token OR the key isn't registered —
    # an unknown `$word` (e.g. a literal `$` typed during testing) is just text, no peek.
    private def env_token_at_cursor : {String, String}?
      prefix = Settings.env_prefix
      return nil if prefix.empty?
      line = @lines[@cy]?
      return nil unless line
      cx = @cx.clamp(0, line.size)
      plen = prefix.size
      ks = cx
      while ks > 0 && env_key_tail?(line[ks - 1]) # walk left to the key run's start
        ks -= 1
      end
      # The prefix sigil must sit immediately before the key run (else it isn't an env token).
      return nil unless ks - plen >= 0 && line[(ks - plen)...ks] == prefix
      ke = cx
      while ke < line.size && env_key_tail?(line[ke]) # extend right over the rest of the key
        ke += 1
      end
      key = line[ks...ke]
      # A valid identifier: non-empty and starting with a key head (`$1` never expands).
      return nil if key.empty? || !env_key_head?(key[0])
      # `display_vars`: the peek is the operator's answer to "is my `$SESSION` bound, and to
      # what?" in the editor where they are writing the token — Repeater, Fuzzer, Intercept —
      # with no new surface at all. A declared-but-UNBOUND name has no value and so gets no
      # peek, which is the same answer `token_regions` paints (it stays `env_unknown`).
      # A name the OWNER will ship literally gets no peek, for the same reason an unregistered
      # one doesn't: on this buffer it is not a variable reference. An evidence tab used to
      # tooltip the resolved secret under a `$TOKEN` the send path then wrote to the socket
      # as six literal bytes.
      return nil if @env_literal_names.includes?(key)
      val = Env.display_vars[key]?
      return nil unless val # unregistered → just a literal string, not an env reference
      {key, env_value_preview(val, Env.declared_bindings.includes?(key))}
    end
  end
end
