require "./screen"
require "./theme"
require "./highlight"
require "../env"
require "../settings"
require "./gutter"
require "./search_hi"
require "./reveal"
require "./env_complete"

module Gori::Tui
  # A minimal multi-line text editor for inline editing (e.g. the Replay
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
      @gutter = false # left line-number gutter (on for the Replay request body)
      @search_hl = "" # active ^F query → matches highlighted in render
      @reveal = false # show whitespace (space ·, tab →) instead of syntax colours
      @edits = 0      # monotonic content-change counter — cheap cache key for owners
      @lc_lines = [] of String # downcased lines for ^F search, memoized on @edits
      @lc_lines_rev = -1
      # Opt-in background tints: [start, end) FULL-buffer char offsets + colour, painted
      # UNDER the text (over syntax/plain, beneath search + cursor). Empty for every editor
      # except the Fuzzer template — Replay/Notes never set it, so they're unaffected. The
      # widget knows nothing about §-markers; the owner supplies offsets + resolved colours.
      @bg_regions = [] of {Int32, Int32, Color}
      @undo_stack = [] of UndoState
      # Opt-in `$ENV` autocomplete popup (nil = disabled). Enabled only on the outbound
      # request editors (Replay request, Fuzzer template) where env tokens are expanded on
      # send; every other editor keeps it nil so its edit path is byte-for-byte unchanged.
      @env_complete = nil.as(EnvComplete?)
      set_text(text)
    end

    setter gutter : Bool
    setter search_hl : String
    setter reveal : Bool
    setter bg_regions : Array({Int32, Int32, Color})
    # Enable horizontal cursor-following (the Project description); off everywhere
    # else, so those editors keep @xscroll == 0 and their hot render path unchanged.
    setter follow_x : Bool
    getter edits : Int32
    getter cy : Int32
    getter cx : Int32
    getter scroll : Int32
    getter? gutter : Bool

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
      @cx = cx + 1
      @styled = nil
      @edits += 1
      refresh_env_complete
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
        @lines[@cy] = "#{line[0, cx - 1]}#{line[cx..]}"
        @cx = cx - 1
      elsif @cy > 0
        push_undo
        prev = @lines[@cy - 1]
        @cx = prev.size
        @lines[@cy - 1] = prev + @lines[@cy]
        @lines.delete_at(@cy)
        @cy -= 1
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
        @lines[@cy] = "#{line[0, cx]}#{line[cx + 1..]}"
      elsif @cy < @lines.size - 1
        push_undo
        @lines[@cy] = line + @lines[@cy + 1]
        @lines.delete_at(@cy + 1)
      else
        return # end of buffer — nothing to delete, don't dirty
      end
      @cx = cx
      @styled = nil
      @edits += 1
      refresh_env_complete
    end

    def move(dr : Int32, dc : Int32) : Nil
      if dr != 0
        @cy = (@cy + dr).clamp(0, @lines.size - 1)
        @cx = @cx.clamp(0, @lines[@cy].size)
      end
      return if dc == 0
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
    # a codepoint index via Screen.column_for. `rect` is the SAME rect render gets.
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
      @cx = Screen.column_for(@lines[@cy], mx - (rect.x + gw) + @xscroll)
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
      env_complete_close
    end

    def line_count : Int32
      @lines.size
    end

    # Replace one line in-place (cursor clamped when on that row). Used by Replay to
    # resync a lone Content-Length header without resetting the whole buffer.
    def replace_line(idx : Int32, content : String) : Nil
      return if idx < 0 || idx >= @lines.size
      return if @lines[idx] == content
      push_undo
      @lines[idx] = content
      @cx = @cx.clamp(0, content.size) if @cy == idx
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

    # `highlight` overlays request/response syntax colours on the buffer while
    # keeping it fully editable: pass `:request` or `:response` for the held
    # HTTP message editors (Replay, Intercept), nil for plain prose (Notes,
    # Finding notes). The styled lines are 1:1 with `@lines`, so the cursor —
    # drawn last, on top — still lands on the right column.
    def render(screen : Screen, rect : Rect, cursor : Bool, highlight : Symbol? = nil) : Nil
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
      # Replay/Notes (no regions) skip it so their hot path is unchanged.
      line_off = 0
      (0...@scroll).each { |k| line_off += @lines[k].size + 1 } unless @bg_regions.empty? # +1 for '\n'
      caret_cell = nil.as({Int32, Int32}?) # the drawn caret's screen cell — anchors the env-complete popup
      (0...rect.h).each do |i|
        li = @scroll + i
        break if li >= @lines.size
        Gutter.draw(screen, rect.x, rect.y + i, li, gw, current: li == @cy) if @gutter
        line = @lines[li]
        if @xscroll > 0
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
              px += Screen.column_width(prefix) # ≥1/char, matching the drawn cells + caret math
            end
            if !@preedit.empty?
              screen.text(px, rect.y + i, @preedit, Theme.text, attr: Attribute::Underline, width: cw - (px - cx0))
              px += Screen.display_width(@preedit)
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
        paint_bg_regions(screen, cx0, rect.y + i, line_off, line, cw) unless li == @cy && !@preedit.empty?
        line_off += line.size + 1 # advance BEFORE the cursor `next` so it can't desync
        unless @search_hl.empty?
          # Mark on the visible (left-sliced) text so the highlight columns line up
          # with the cells we actually drew once horizontally scrolled.
          st = @xscroll > 0 ? slice_left(line, @xscroll) : line
          SearchHi.mark(screen, cx0, rect.y + i, st, @search_hl, cx0 + cw)
        end
        next unless cursor && li == @cy
        # column_width (not display_width): a raw control char in the prefix occupies a
        # cell and click-to-cursor counts it, so the caret must too — else it sits one
        # column left of the real position and paints over a glyph.
        prefix_w = Screen.column_width(line[0, @cx])
        preedit_w = Screen.display_width(@preedit)
        cxs = cx0 + prefix_w + preedit_w - @xscroll
        if cxs >= cx0 && cxs < cx0 + cw
          caret_cell = {cxs, rect.y + i}
          screen.cursor(cxs, rect.y + i)
          cgw = [Screen.display_width((@preedit.empty? ? (@cx < line.size ? line[@cx] : ' ') : @preedit[0]).to_s), 1].max
          ch = @preedit.empty? ? (@cx < line.size ? line[@cx] : ' ') : @preedit[0]
          (0...cgw).each do |off|
            break if cxs + off >= cx0 + cw # a wide-glyph caret at the last column must not spill its 2nd cell onto the pane border
            cch = (off == 0 ? ch : ' ')
            screen.cell(cxs + off, rect.y + i, cch, Theme.bg, Theme.accent)
          end
        end
      end
      # The env-complete dropdown paints LAST (over the text, anchored at the caret) so it
      # never renders when the caret is off-screen or the editor is unfocused (cursor=false).
      if cursor && (cc = caret_cell) && (ec = @env_complete)
        ec.render(screen, cc[0], cc[1], rect)
      end
    end

    # Overlay the bg_regions intersecting THIS line. `off0` is the line's start offset
    # in the full LF-joined buffer. Column math mirrors SearchHi.mark (same
    # Screen.display_width as the base draw, so an ambiguous-width glyph can't drift the
    # tint off the cells). Multi-line regions clamp to [0, line.size): first line tints
    # col→EOL, fully-covered lines 0→size, last line BOL→col; the '\n' offset has no cell.
    # Region columns are computed against the FULL (unscrolled) line, then shifted left by
    # @xscroll and clipped to the visible window — a no-op when @xscroll == 0 (the common
    # case, since only the Fuzzer template sets bg_regions and it doesn't enable follow_x).
    private def paint_bg_regions(screen : Screen, cx0 : Int32, y : Int32, off0 : Int32,
                                 line : String, cw : Int32) : Nil
      return if @bg_regions.empty? || @reveal # opt-in; reveal rewrites the glyphs
      line_end = off0 + line.size
      @bg_regions.each do |(a, b, color)|
        next if b <= off0 || a >= line_end # region doesn't touch this line
        la = (a - off0).clamp(0, line.size)
        lb = (b - off0).clamp(0, line.size)
        next if la >= lb
        start_col = Screen.display_width(line[0, la]) - @xscroll
        end_col = Screen.display_width(line[0, lb]) - @xscroll
        draw_from = {start_col, 0}.max
        draw_to = {end_col, cw}.min
        next if draw_from >= draw_to
        seg = slice_left(line[la, lb - la], draw_from - start_col)
        screen.text(cx0 + draw_from, y, seg, Theme.marker_fg, color, width: draw_to - draw_from)
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
      pw = Screen.display_width(@preedit)
      # column_width (not display_width) to match the actual draw at line 363: a raw
      # control char occupies one drawn cell, so measuring it as width 0 here would let
      # the caret render outside the window (cursor detaches / no scroll-into-view).
      if Screen.column_width(line) + pw <= cw
        @xscroll = 0
        return
      end
      cx = @cx.clamp(0, line.size)
      curx = Screen.column_width(line[0, cx]) + pw      # caret's column in the full line
      @xscroll = curx if curx < @xscroll                # caret left of the window → snap left
      @xscroll = curx - cw + 1 if curx >= @xscroll + cw # caret past the right edge → snap right
      @xscroll = 0 if @xscroll < 0
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
      @lines = state.lines           # the snapshot is popped/unreferenced, so no defensive dup
      @lines = [""] if @lines.empty?
      @cy = state.cy.clamp(0, @lines.size - 1)
      @cx = state.cx.clamp(0, @lines[@cy].size)
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
  end
end
