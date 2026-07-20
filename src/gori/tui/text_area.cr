require "./screen"
require "./theme"
require "./frame"
require "./highlight"
require "../env"
require "../settings"
require "./gutter"
require "./search_hi"
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
    # into an Array-of-pointers copy that shares the line data.
    record UndoState, lines : Array(String), cy : Int32, cx : Int32

    def initialize(text : String = "")
      @lines = [""]
      @cy = 0
      @cx = 0
      @scroll = 0
      @xscroll = 0      # leftmost visible display COLUMN (horizontal scroll); only moves when @follow_x is on
      @last_h = 0       # viewport height from the last render — lets scroll_view (wheel) clamp
      @follow_x = false # follow the cursor horizontally (long lines scroll into view); off ⇒ legacy right-clip
      @preedit = ""
      # Cached syntax-highlight overlay (1:1 with @lines), rebuilt only when the
      # buffer content changes — not on every render frame. @styled_kind tracks
      # which highlight symbol it was built for.
      @styled = nil.as(Array(Highlight::Line)?)
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
      @undo_stack = [] of UndoState
      # Opt-in `$ENV` autocomplete popup (nil = disabled). Enabled only on the outbound
      # request editors (Repeater request, Fuzzer template) where env tokens are expanded on
      # send; every other editor keeps it nil so its edit path is byte-for-byte unchanged.
      @env_complete = nil.as(EnvComplete?)
      # Opt-in `$ENV` value peek (nil = disabled). Paired with @env_complete — the same
      # request editors get it. Shows the resolved value of a COMPLETE `$KEY` token under
      # the caret (NORMAL or INSERT) once the autocomplete dropdown isn't offering matches.
      @env_peek = nil.as(EnvPeek?)
      # Opt-in chain tooltip (nil = disabled). Paired with @conceal_spans on the request
      # editors: reveals the hidden ¦chain of the §…§ marker under the caret. @chain_peek_text
      # is fed by the owner each frame (nil = caret not in a chained marker → no tooltip).
      @chain_peek = nil.as(ChainPeek?)
      @chain_peek_text = nil.as(String?)
      set_text(text)
    end

    setter gutter : Bool
    setter search_hl : String
    setter reveal : Bool
    setter bg_regions : Array({Int32, Int32, Color})
    setter conceal_spans : Array({Int32, Int32})
    # Enable horizontal cursor-following (the Project description); off everywhere
    # else, so those editors keep @xscroll == 0 and their hot render path unchanged.
    setter follow_x : Bool
    getter edits : Int32
    getter cy : Int32
    getter cx : Int32
    getter scroll : Int32
    getter? gutter : Bool

    # The exact LF form `set_text` would store for `text` — the single source of truth for
    # "does this incoming string already match what the buffer holds?".
    #
    # Every poll-driven reconcile path (RepeaterView#request_side_matches? /
    # #apply_peer_request, FuzzerView#session_side_matches? / #apply_peer_session,
    # NotesView#soft_merge_from) compares an incoming store string against `#text` BEFORE
    # calling set_text, because set_text zeroes the caret + scroll and CLEARS THE UNDO STACK.
    # The buffer is always LF (set_text below splits on \n and rstrips \r) while the store can
    # hold wire CRLF — MCP create_repeater/create_note + update_note, `gori run notes create`
    # piping a raw request or a CRLF file, import, or a peer session all write the body
    # verbatim. So a raw `==` is falsely unequal on EVERY poll, the guard never fires, and the
    # caret is slammed back to 0,0 (and undo wiped) on every data_version tick (~1.3×/s while
    # capturing). Lives here, next to set_text, because set_text is what defines the answer:
    # the two cannot drift.
    #
    # Mirrors set_text's split/rstrip rather than a blanket \r→\n gsub deliberately: a LONE \r
    # mid-line is data set_text KEEPS on the line, whereas a gsub would split it into a second
    # line and report a spurious mismatch — the very false-negative this exists to kill.
    def self.normalize_lf(text : String) : String
      return text unless text.includes?('\r') # the overwhelmingly common case — no allocation
      text.split('\n').map(&.rstrip('\r')).join('\n')
    end

    # NOTE: `self.normalize_lf` above mirrors this line — keep them in step.
    def set_text(text : String) : Nil
      @lines = text.split('\n').map(&.rstrip('\r'))
      @lines = [""] if @lines.empty?
      @cy = 0
      @cx = 0
      @scroll = 0
      @xscroll = 0
      @preedit = ""
      @styled = nil
      @edits += 1
      @undo_stack.clear
      # Drop stale conceal offsets — they index the OLD buffer; the owner re-feeds fresh
      # ones next render. Guards any move/place between now and that render.
      @conceal_spans = [] of {Int32, Int32} unless @conceal_spans.empty?
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

    def to_bytes : Bytes
      @lines.join("\r\n").to_slice
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
      push_undo
      line = @lines[@cy]
      cx = @cx.clamp(0, line.size)
      @lines[@cy] = "#{line[0, cx]}#{ch}#{line[cx..]}"
      # Forward-snap: the typed char can MERGE with what follows (typing `e` in front of a
      # lone U+0301 makes one `é` cluster), which would leave the caret inside it.
      @cx = cx + 1
      snap_cx_to_cluster(1)
      @styled = nil
      @edits += 1
      refresh_env_complete
    end

    # Insert a whole string at the caret as ONE undo unit (cross-tab "insert OAST payload").
    # Assumes single-line content (URLs have no newline); a per-char loop would create N undo
    # steps and refresh env-complete N times.
    def insert_string(str : String) : Nil
      return if str.empty?
      push_undo
      line = @lines[@cy]
      cx = @cx.clamp(0, line.size)
      @lines[@cy] = "#{line[0, cx]}#{str}#{line[cx..]}"
      @cx = cx + str.size
      snap_cx_to_cluster(1) # the paste's last char can merge with the text it landed before
      @styled = nil
      @edits += 1
      refresh_env_complete
    end

    # Insert `ch` TWICE as one undo unit — the `§§`/`¦¦` escaped-literal pair the marker
    # guard produces when a `§`/`¦` would otherwise nest inside (or flush against) a marker.
    # Caret ends past both, so the literal sits behind it like a normal keystroke.
    def insert_pair(ch : Char) : Nil
      push_undo
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
      @lines = new_text.split('\n').map(&.rstrip('\r'))
      @lines = [""] if @lines.empty?
      @conceal_spans = [] of {Int32, Int32} unless @conceal_spans.empty?
      @styled = nil
      @edits += 1
      place_at_offset(caret)
    end

    def insert_newline : Nil
      push_undo
      line = @lines[@cy]
      cx = @cx.clamp(0, line.size)
      @lines[@cy] = line[0, cx]
      @lines.insert(@cy + 1, line[cx..])
      @cy += 1
      @cx = 0
      @styled = nil
      @edits += 1
      refresh_env_complete
    end

    def backspace : Nil
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
    def home : Nil
      @cx = 0
      env_complete_close
    end

    def end_of_line : Nil
      @cx = @lines[@cy].size
      env_complete_close
    end

    # Forward delete: remove the char under the cursor, or join the next line when at EOL.
    # A buffer mutation, so it invalidates the highlight cache and bumps @edits (like backspace).
    def delete : Nil
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

    def move(dr : Int32, dc : Int32) : Nil
      if dr != 0
        @cy = (@cy + dr).clamp(0, @lines.size - 1)
        @cx = @cx.clamp(0, @lines[@cy].size)
        snap_cx_to_cluster(0) # the column carried across rows can land mid-cluster
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

    # Cursor is on the first line — the Runner pops focus to the tab bar when ↑
    # is pressed here (natural upward flow, matching the body lists).
    def at_top? : Bool
      @cy == 0
    end

    # Cursor is on the last line — used to cross out of the editor on ↓ (e.g. the
    # Decoder INPUT editor descends to the CHAIN field) without swallowing normal
    # downward cursor movement.
    def at_bottom? : Bool
      @cy == @lines.size - 1
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
    def click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return if rect.empty? || @lines.empty?
      row = my - rect.y
      return if row < 0
      @cy = {@scroll + row, @lines.size - 1}.min
      gw = @gutter ? {Gutter.width(@lines.size), rect.w}.min : 0
      # + @xscroll: the click lands at display column (mx - content_x) WITHIN the
      # visible window, which is @xscroll columns into the full line.
      target = mx - (rect.x + gw) + @xscroll
      line = @lines[@cy]
      cr = @conceal_spans.empty? ? nil : line_conceal(line_start_offset(@cy), line.size)
      # On a concealed line the click column is in concealed space; map it back through
      # the hidden runs so a click never lands the caret on an unseen ¦chain char.
      # No cluster snap needed: BOTH inverses already return a cluster start by construction
      # (Screen.column_for walks clusters; concealed_col_to_raw does too, and its conceal
      # edges `¦`/`§` always begin a cluster — see snap_cx_out_of_conceal).
      @cx = (cr && !cr.empty?) ? concealed_col_to_raw(line, cr, target) : Screen.column_for(line, target)
      snap_cx_out_of_conceal(0) # a click on the closing-§ column resolves to it; nudge to a legal rest
      env_complete_close
    end

    # Viewport scroll by `step` lines (the mouse wheel), INDEPENDENT of the cursor:
    # shift the visible window, then pull the cursor into it so render's ensure_visible
    # won't snap the view back to the old cursor line. Unlike move(), the window jumps
    # immediately (no "wheel until the cursor reaches the edge" lag). No-op before the
    # first render (height unknown) or when the buffer already fits.
    def scroll_view(step : Int32) : Nil
      return if @last_h <= 0 || @lines.size <= @last_h
      max = @lines.size - @last_h
      @scroll = (@scroll + step).clamp(0, max)
      @cy = @cy.clamp(@scroll, {@scroll + @last_h - 1, @lines.size - 1}.min)
      @cx = @cx.clamp(0, @lines[@cy].size)
      snap_cx_to_cluster(0) # the row changed under the caret; its column may re-cluster
      env_complete_close
    end

    # Horizontal viewport nudge (shift+←/→ in READ panes). No-op unless @follow_x.
    def hscroll_view(step : Int32) : Nil
      return unless @follow_x
      @xscroll = {@xscroll + step * 4, 0}.max
    end

    # Jump the cursor to 1-based line `n`, column 0 (out-of-range clamps to the
    # first/last line). render's ensure_visible scrolls it into view next frame.
    def goto_line(n : Int32) : Nil
      @cy = (n - 1).clamp(0, @lines.size - 1)
      @cx = 0
      env_complete_close
    end

    # Place the caret without pushing undo (read-mode navigation / click-to-cursor).
    def place_cursor(cy : Int32, cx : Int32) : Nil
      @cy = cy.clamp(0, @lines.size - 1)
      @cx = cx.clamp(0, @lines[@cy].size)
      snap_cx_to_cluster(0) # caller-supplied index — unconstrained, may land mid-cluster
      env_complete_close
    end

    def line_count : Int32
      @lines.size
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
    def match_count(query : String) : Int32
      return 0 if query.empty?
      text.scan(search_regex(query)).size
    end

    # Swap every occurrence of `query` for `replacement` as ONE undoable edit (so a
    # surprise result is one ^Z away), returning how many landed. `replacement` is
    # inserted literally — the block form of gsub skips \1 backreference expansion,
    # which the user did not ask for by typing a `\1`. The caret keeps its old offset
    # (clamped): a bulk edit has no single site to land on.
    def replace_matches(query : String, replacement : String) : Int32
      return 0 if query.empty?
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
      @last_h = rect.h # remembered for scroll_view (wheel) clamping
      ensure_visible(rect.h)
      gw = @gutter ? {Gutter.width(@lines.size), rect.w}.min : 0 # never exceed the pane
      cx0 = rect.x + gw                                          # content start x (after the optional gutter)
      cw = {rect.w - gw, 0}.max                                  # content width
      ensure_visible_x(cw)                                       # slide @xscroll so the caret stays on screen (no-op unless @follow_x)
      styled = highlight ? highlighted(highlight) : nil
      # Buffer char-offset of the first visible line — advanced per row so each line
      # knows its start for the bg-region overlay without an O(n²) rescan. Only the
      # opt-in bg_regions consumer (the Fuzzer template) pays the O(@scroll) prefix sum;
      # Repeater/Notes (no regions) skip it so their hot path is unchanged.
      line_off = 0
      (0...@scroll).each { |k| line_off += @lines[k].size + 1 } unless @bg_regions.empty? && @conceal_spans.empty? # +1 for '\n'
      caret_cell = nil.as({Int32, Int32}?)                                                                         # the drawn caret's screen cell — anchors the env-complete popup
      (0...rect.h).each do |i|
        li = @scroll + i
        break if li >= @lines.size
        Gutter.draw(screen, rect.x, rect.y + i, li, gw, current: li == @cy) if @gutter
        line = @lines[li]
        # Concealed lines (a §…§ marker with a hidden ¦chain) go through a dedicated draw:
        # delete the concealed chars from the styled line, then h-scroll-slice + draw. The
        # IME-preedit caret line is left raw (its columns shift with the composing text).
        cr = (@conceal_spans.empty? || (li == @cy && !@preedit.empty?)) ? nil : line_conceal(line_off, line.size)
        if cr && !cr.empty? && !@reveal
          draw_concealed_line(screen, cx0, rect.y + i, li, line, styled, cr, cw)
        elsif @xscroll > 0
          draw_scrolled(screen, cx0, rect.y + i, li, line, styled, cw)
        elsif @reveal
          Highlight.draw(screen, cx0, rect.y + i, Reveal.styled(line, false, cw), width: cw)
        elsif styled && (sl = styled[li]?)
          Highlight.draw(screen, cx0, rect.y + i, sl, width: cw)
        else
          if li == @cy && !@preedit.empty?
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
            screen.text(cx0, rect.y + i, line, Theme.text, width: cw)
          end
        end
        # Marker tint UNDER search/cursor — skip the IME-preedit line (its columns are
        # shifted by the composing text, which isn't in `line`). paint_bg_regions itself
        # no-ops when there are no regions or in reveal mode.
        paint_bg_regions(screen, cx0, rect.y + i, line_off, line, cw, cr) unless li == @cy && !@preedit.empty?
        line_off += line.size + 1 # advance BEFORE the cursor `next` so it can't desync
        unless @search_hl.empty?
          # Mark on the visible (left-sliced) text so the highlight columns line up
          # with the cells we actually drew once horizontally scrolled.
          st = @xscroll > 0 ? slice_left(line, @xscroll) : line
          SearchHi.mark(screen, cx0, rect.y + i, st, @search_hl, cx0 + cw)
        end
        # The caret cell is captured for the caret line whether or not the block cursor
        # is drawn (cursor=false in NORMAL) — the value peek anchors to it in read mode too.
        # The block-cursor GLYPH itself still paints only when `cursor` (insert mode).
        next unless li == @cy
        # draw_width (not display_width): a raw control char in the prefix occupies a cell
        # and click-to-cursor counts it, so the caret must too — else it sits one column
        # left of the real position and paints over a glyph. Per CLUSTER, matching the draw
        # exactly: `@cx` rests only on cluster boundaries (snap_cx_to_cluster), so this is
        # single-valued and Screen.column_for inverts it.
        prefix_w = (cr && !cr.empty?) ? concealed_col(line, cr, @cx) : Screen.draw_width(line[0, @cx])
        preedit_w = Screen.draw_width(@preedit)
        cxs = cx0 + prefix_w + preedit_w - @xscroll
        if cxs >= cx0 && cxs < cx0 + cw
          caret_cell = {cxs, rect.y + i}
          if cursor
            screen.cursor(cxs, rect.y + i)
            # The cell under the block caret is the first VISIBLE glyph at/after @cx: on a
            # concealed line the raw char there may be a hidden `¦chain` byte, so skip past
            # any concealed run to the glyph the user actually sees (the closing §).
            r = @cx
            cr.each { |(a, b)| r = b if r >= a && r < b } if cr && !cr.empty?
            # The whole CLUSTER at `r`, not `line[r]`: parking on `é` (e + U+0301) or a ZWJ
            # family has to invert the glyph the user sees, not its leading codepoint.
            ch = @preedit.empty? ? Screen.caret_glyph(line, r) : Screen.caret_glyph(@preedit, 0)
            # ONE write, never two. A width-2 glyph already claims its trailing column as a
            # continuation cell carrying this same fg/bg/attr — termisu materialises that
            # cell from its lead — so the accent spans both columns without a second write.
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
      Frame.scroll_gauge(screen, rect, @lines.size, @scroll, gauge_focused) if gauge
      # The env-complete dropdown + value peek paint LAST (over the text, anchored at the
      # caret) so they never render when the caret is off-screen.
      render_env_popups(screen, caret_cell, rect, cursor, peek)
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
      # Chain tooltip takes precedence over the env peek (a §…§ marker is never also a $KEY).
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

    # The chain tooltip pass: when the caret sits in a chained §…§ marker (owner-fed via
    # @chain_peek_text) and the editor is focused, reveal the concealed chain at the caret
    # and suppress the env peek. Returns true when it took over (the caller then skips the
    # env peek). No-op (false) when the tooltip is disabled or the caret isn't in a marker.
    private def render_chain_peek(screen : Screen, caret_cell : {Int32, Int32}?, rect : Rect,
                                  cursor : Bool, peek : Bool, ec : EnvComplete?) : Bool
      cp = @chain_peek
      return false unless cp
      chain = @chain_peek_text
      if chain && (cursor || peek) && (cc = caret_cell) && !(cursor && ec && ec.open?)
        cp.set(chain)
        cp.render(screen, cc[0], cc[1], rect)
        @env_peek.try(&.close)
        return true
      end
      cp.close
      false
    end

    # Overlay the bg_regions intersecting THIS line. `off0` is the line's start offset
    # in the full LF-joined buffer. Column math mirrors the base draw + caret
    # (Screen.draw_width / grapheme_cols ≥1 per cluster, so a tab in a marker band can't
    # drift the tint left of the cells). Multi-line regions clamp to [0, line.size): first
    # line tints col→EOL, fully-covered lines 0→size, last line BOL→col; the '\n' offset
    # has no cell. Region columns are computed against the FULL (unscrolled) line, then
    # shifted left by @xscroll and clipped to the visible window — a no-op when
    # @xscroll == 0 (the common case, since only the Fuzzer template sets bg_regions and
    # it doesn't enable follow_x).
    private def paint_bg_regions(screen : Screen, cx0 : Int32, y : Int32, off0 : Int32,
                                 line : String, cw : Int32, cr : Array({Int32, Int32})? = nil) : Nil
      return if @bg_regions.empty? || @reveal # opt-in; reveal rewrites the glyphs
      return paint_bg_regions_concealed(screen, cx0, y, off0, line, cw, cr) if cr && !cr.empty?
      line_end = off0 + line.size
      @bg_regions.each do |(a, b, color)|
        next if b <= off0 || a >= line_end # region doesn't touch this line
        la = (a - off0).clamp(0, line.size)
        lb = (b - off0).clamp(0, line.size)
        next if la >= lb
        start_col = Screen.draw_width(line[0, la]) - @xscroll
        end_col = Screen.draw_width(line[0, lb]) - @xscroll
        draw_from = {start_col, 0}.max
        draw_to = {end_col, cw}.min
        next if draw_from >= draw_to
        seg = slice_left(line[la, lb - la], draw_from - start_col)
        screen.text(cx0 + draw_from, y, seg, Theme.marker_fg, color, width: draw_to - draw_from)
      end
    end

    # Band over-paint for a line whose §…§ markers hide a ¦chain: re-draw only the VISIBLE
    # marker glyphs (concealed chars occupy no cell) at their concealed display columns,
    # matching what the base Highlight.draw already put on screen. The glyph right after
    # each concealed run — the closing § — is accented so a chained marker reads distinctly
    # from a plain one; the rest keep Theme.marker_fg.
    private def paint_bg_regions_concealed(screen : Screen, cx0 : Int32, y : Int32, off0 : Int32,
                                           line : String, cw : Int32, cr : Array({Int32, Int32})) : Nil
      line_end = off0 + line.size
      @bg_regions.each do |(a, b, color)|
        next if b <= off0 || a >= line_end
        la = (a - off0).clamp(0, line.size)
        lb = (b - off0).clamp(0, line.size)
        next if la >= lb
        col = concealed_display_prefix(line, cr, la) # display columns before the first drawn char
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

    # Full-buffer char offset of line `cy`'s first char (only walked when concealing).
    private def line_start_offset(cy : Int32) : Int32
      off = 0
      (0...cy).each { |i| off += @lines[i].size + 1 } # +1 for the joining '\n'
      off
    end

    # Display column (draw_width semantics, matching the caret) of raw caret index `cx`
    # on a concealed line: the width of the surviving chars in [0, cx). A cx inside a
    # concealed run collapses to that run's start column (both edges share the cell).
    private def concealed_col(line : String, ranges : Array({Int32, Int32}), cx : Int32) : Int32
      cx = cx.clamp(0, line.size)
      w = 0
      pos = 0
      ranges.each do |(a, b)|
        break if a >= cx
        w += Screen.draw_width(line[pos...a]) if a > pos
        return w if b >= cx # cx lands inside/at this run → column at the run's start
        pos = b
      end
      w + Screen.draw_width(line[pos...cx])
    end

    # As `concealed_col` — draw_width / grapheme_cols semantics matching Highlight.draw's
    # ≥1 floor, used by the band over-paint so tint columns line up with drawn cells.
    private def concealed_display_prefix(line : String, ranges : Array({Int32, Int32}), cx : Int32) : Int32
      w = 0
      pos = 0
      ranges.each do |(a, b)|
        break if a >= cx
        w += Screen.draw_width(line[pos...a]) if a > pos
        return w if b >= cx
        pos = b
      end
      w + Screen.draw_width(line[pos...cx])
    end

    # Inverse of `concealed_col` for click-to-cursor: the raw char index whose concealed
    # display cell holds column `target`. Never returns an index inside a concealed run
    # (those cells aren't drawn), so a click can't land the caret on a hidden char.
    private def concealed_col_to_raw(line : String, ranges : Array({Int32, Int32}), target : Int32) : Int32
      return 0 if target <= 0
      col = 0
      i = 0
      n = line.size
      while i < n
        hit = ranges.find { |(a, b)| i >= a && i < b }
        if hit
          i = hit[1]
          next
        end
        # Step by CLUSTER, matching `concealed_col`'s draw_width and the cells actually
        # drawn, so this stays that function's exact inverse and a click lands where the
        # caret paints. A conceal run opens on a `¦` and closes before a `§`: neither is
        # ASCII, but both are Grapheme_Cluster_Break=Other and so always BEGIN a cluster,
        # which is what guarantees no cluster straddles a run boundary.
        e = Screen.cluster_end(line, i + 1)
        w = Screen.draw_width(line[i...e])
        return i if target < col + w
        col += w
        i = e
      end
      n
    end

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
    private def highlighted(kind : Symbol) : Array(Highlight::Line)
      cached = @styled
      env_rev = Env.highlight_rev
      return cached if cached && @styled_kind == kind && @styled_rev == Theme.revision && @styled_env_rev == env_rev
      @styled_kind = kind
      @styled_rev = Theme.revision
      @styled_env_rev = env_rev
      @styled = kind == :markdown ? Highlight.markdown(@lines) : Highlight.from_lines(@lines, kind == :request)
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
      return unless @follow_x
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
      full = concealed ? concealed_col(line, cr.not_nil!, line.size) : Screen.draw_width(line)
      if full + pw <= cw
        @xscroll = 0
        return
      end
      cx = @cx.clamp(0, line.size)
      curx = (concealed ? concealed_col(line, cr.not_nil!, cx) : Screen.draw_width(line[0, cx])) + pw
      @xscroll = curx if curx < @xscroll                # caret left of the window → snap left
      @xscroll = curx - cw + 1 if curx >= @xscroll + cw # caret past the right edge → snap right
      @xscroll = 0 if @xscroll < 0
    end

    # Draw a line whose §…§ markers hide a ¦chain: delete the concealed chars from the
    # styled line (a single plain span when highlighting is off), then h-scroll-slice and
    # draw. The marker band + accented closing § are over-painted afterwards by
    # paint_bg_regions (concealment-aware). Only reached when the line has conceal ranges.
    private def draw_concealed_line(screen : Screen, cx0 : Int32, y : Int32, li : Int32,
                                    line : String, styled : Array(Highlight::Line)?,
                                    cr : Array({Int32, Int32}), cw : Int32) : Nil
      base = (styled && styled[li]?) || [Highlight::Span.new(line, Theme.text)]
      cl = Highlight.conceal(base, cr)
      cl = Highlight.slice_left(cl, @xscroll) if @xscroll > 0
      Highlight.draw(screen, cx0, y, cl, width: cw)
    end

    # The horizontally-scrolled per-line draw (only when @xscroll > 0): left-slice
    # the line by @xscroll display columns so the caret's neighbourhood is visible,
    # then reuse the normal drawers (which handle right truncation + the … ellipsis).
    private def draw_scrolled(screen : Screen, cx0 : Int32, y : Int32, li : Int32,
                              line : String, styled : Array(Highlight::Line)?, cw : Int32) : Nil
      if @reveal
        Highlight.draw(screen, cx0, y, Highlight.slice_left(Reveal.styled(line, false, cw + @xscroll), @xscroll), width: cw)
      elsif styled && (sl = styled[li]?)
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
        screen.text(cx0, y, slice_left(line, @xscroll), Theme.text, width: cw)
      end
    end

    # Drop the first `start_col` display columns of `s`. A wide glyph straddling the
    # cut becomes leading spaces for its still-visible cells, so the remaining glyphs
    # keep their columns. Identity when start_col <= 0.
    private def slice_left(s : String, start_col : Int32) : String
      Highlight.slice_left_text(s, start_col)
    end

    private def push_undo : Nil
      @undo_stack << UndoState.new(@lines.dup, @cy, @cx) # shallow: shares the immutable line Strings
      @undo_stack.shift if @undo_stack.size > 100
    end

    def undo : Nil
      return if @undo_stack.empty?
      state = @undo_stack.pop
      @lines = state.lines # the snapshot is popped/unreferenced, so no defensive dup
      @lines = [""] if @lines.empty?
      @cy = state.cy.clamp(0, @lines.size - 1)
      @cx = state.cx.clamp(0, @lines[@cy].size)
      snap_cx_to_cluster(0) # the snapshot's line may differ from the one we clamp against
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

    # Enable the chain tooltip (paired with @conceal_spans on the request editors).
    def chain_peek=(on : Bool) : Nil
      @chain_peek = on ? (@chain_peek || ChainPeek.new) : nil
    end

    # Per-frame feed: the chain of the §…§ marker under the caret, or nil when the caret
    # isn't in a chained marker. The owner resolves it (it knows the §-marker layout).
    def chain_peek_text=(chain : String?) : Nil
      @chain_peek_text = chain
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
      vars = Env.effective_vars
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
        .select { |k| pl.empty? || k.downcase.starts_with?(pl) }
        .sort!
        .first(40)
        .map { |k| {k, env_value_preview(vars[k])} }
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
    private def env_value_preview(v : String) : String
      s = v.gsub(/\s+/, " ").strip
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
      val = Env.effective_vars[key]?
      return nil unless val # unregistered → just a literal string, not an env reference
      {key, env_value_preview(val)}
    end
  end
end
