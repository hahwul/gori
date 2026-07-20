require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def env_key(k : Termisu::Input::Key)
  Termisu::Event::Key.new(k)
end

# Render `text` with the caret parked `cx` columns in and env-peek enabled, then return
# the painted screen (cursor = INSERT mode, peek = the read-mode value-peek flag).
private def render_peek(text : String, cx : Int32, cursor : Bool, peek : Bool) : MemoryBackend
  ta = Gori::Tui::TextArea.new(text)
  ta.env_complete = true # enables the paired value peek too
  ta.move(0, cx)         # slide the caret into the token
  backend = MemoryBackend.new(60, 8)
  ta.render(Gori::Tui::Screen.new(backend), Gori::Tui::Rect.new(0, 0, 60, 8),
    cursor: cursor, highlight: :request, peek: peek)
  backend
end

# Render `text` with the given conceal spans and caret column, returning the screen.
private def render_concealed(text : String, conceal : Array({Int32, Int32}), cx : Int32 = 0) : MemoryBackend
  ta = Gori::Tui::TextArea.new(text)
  ta.conceal_spans = conceal
  ta.move(0, cx)
  backend = MemoryBackend.new(60, 8)
  ta.render(Gori::Tui::Screen.new(backend), Gori::Tui::Rect.new(0, 0, 60, 8),
    cursor: true, highlight: :request)
  backend
end

# Issue #278 helpers: request-highlighted TextArea (Repeater-style) at a given caret col.
private def render_req_tab(text : String, cx : Int32, cursor : Bool = true) : MemoryBackend
  ta = Gori::Tui::TextArea.new(text)
  ta.move(0, cx)
  b = MemoryBackend.new(40, 3)
  ta.render(Gori::Tui::Screen.new(b), Gori::Tui::Rect.new(0, 0, 40, 3),
    cursor: cursor, highlight: :request)
  b
end

describe Gori::Tui::TextArea do
  # Issue #278: syntax-highlighted editors (Repeater request) used to collapse `\t` to
  # zero columns in Highlight.draw while the caret advanced by column_width (≥1), so
  # parking the caret on a tab overwrote the next glyph ("pushed characters together").
  describe "tab / zero-width control cells (issue #278)" do
    it "draws an embedded tab as a space without collapsing neighbours" do
      b = render_req_tab("x,\ty", 0, cursor: false)
      b.row(0).rstrip.should eq("x, y")
    end

    it "keeps the next glyph visible when the caret sits on the tab" do
      # Before the fix: Highlight collapsed the tab, caret painted a space at col 2 → "x,"
      # (the 'y' was overwritten). After: "x, y" with the space under the caret.
      b = render_req_tab("x,\ty", 2, cursor: true) # cx on '\t'
      b.row(0).rstrip.should eq("x, y")
      b.row(0)[2].should eq(' ') # tab cell
      b.row(0)[3].should eq('y') # neighbour intact
    end

    it "does not double-paint the next glyph when the caret is just past the tab" do
      # Before: caret at cx=3 used column_width prefix=3 on a 2-col collapsed draw → "x,yy"
      b = render_req_tab("x,\ty", 3, cursor: true) # cx on 'y'
      b.row(0).rstrip.should eq("x, y")
      b.row(0)[0, 4].should eq("x, y")
    end

    it "handles a JSON body with a tab after a comma (the issue screenshot case)" do
      body = "{\"a\":1,\t\"b\":2}"
      tab_i = body.index('\t').not_nil!
      # No caret: tab is a space cell, not deleted
      render_req_tab(body, 0, cursor: false).row(0).rstrip.should eq("{\"a\":1, \"b\":2}")
      # Caret on the tab: does not swallow the following quote
      on_tab = render_req_tab(body, tab_i, cursor: true)
      on_tab.row(0).rstrip.should eq("{\"a\":1, \"b\":2}")
      on_tab.row(0)[tab_i + 1].should eq('"')
      # Caret after the tab: no doubled quote
      after = render_req_tab(body, tab_i + 1, cursor: true)
      after.row(0).rstrip.should eq("{\"a\":1, \"b\":2}")
    end
  end

  # Multi-codepoint grapheme clusters. The caret column was computed per CODEPOINT
  # (Screen.column_width) while the glyphs were drawn per CLUSTER (Highlight.draw /
  # Screen#text), so on any decomposed or combined text the caret landed N columns
  # right of its glyph — N being the cluster's "inflation", codepoints minus clusters —
  # and painted a DUPLICATE of value[@cx] there. Longstanding (reproduces at fe11895),
  # not a regression from #278/#285/#289.
  describe "multi-codepoint grapheme clusters (decomposed / ZWJ / skin tone)" do
    nfc = "\u{d55c}\u{ae00}"          # 한글, 2 precomposed syllables
    han = "\u{1112}\u{1161}\u{11ab}"  # 한, 3 conjoining jamo — ONE cluster, 2 columns
    geul = "\u{1100}\u{1173}\u{11af}" # 글, likewise
    nfd = han + geul                  # 한글, 6 codepoints / 2 clusters
    cafe = "cafe\u{301}"              # café, e + combining acute (5 codepoints / 4 clusters)

    it "keeps the caret on its own glyph for precomposed Hangul (the case that already worked)" do
      # 1 codepoint per cluster, so per-codepoint and per-cluster columns agree.
      render_req_tab(nfc + "X", nfc.size).row(0).rstrip.should eq("한 글 X")
    end

    it "does not paint a duplicate glyph past decomposed Hangul" do
      # 6 jamo collapse to 2 drawn syllables: the old per-codepoint caret column was 8 while
      # the draw advanced 4, so the caret stamped a second 'X' four cells right of the real
      # one ("ᄒ ᄀ X   X"). Each syllable is one wide cluster → glyph + pad cell.
      b = render_req_tab(nfd + "X", nfd.size)
      b.row(0).rstrip.should eq("ᄒ ᄀ X")
      # Built from the same codepoints, not an NFC literal: the two forms print identically
      # but are different strings, so a literal here would fail while looking correct.
      b.cluster_row(0).rstrip.should eq("#{han} #{geul} X") # wide cluster + its pad cell
    end

    it "does not paint a duplicate glyph past a combining acute" do
      # Caret column was 5 against a 4-column draw → the caret's 'X' landed one cell right
      # of the real one ("cafeXX"). cluster_row proves the acute is still on its base 'e'.
      b = render_req_tab(cafe + "X", cafe.size)
      b.row(0).rstrip.should eq("cafeX") # @grid is Array(Char): the acute can't show here
      b.cluster_row(0).rstrip.should eq(cafe + "X") # every codepoint intact, none doubled
    end

    it "steps the caret over whole clusters, visiting only boundaries" do
      # @cx stays a CHARACTER index, so the boundaries are 0,3,6 for two 3-jamo syllables —
      # it just never RESTS between them. One → per syllable, no dead presses.
      ta = TextArea.new(nfd)
      ta.cx.should eq(0)
      ta.move(0, 1)
      ta.cx.should eq(han.size) # 3 — cleared the whole syllable, not one jamo
      ta.move(0, 1)
      ta.cx.should eq(nfd.size) # 6
      ta.move(0, -1)
      ta.cx.should eq(han.size)
      ta.move(0, -1)
      ta.cx.should eq(0)
    end

    it "renders no duplicate glyph at any caret position while stepping through" do
      # The bug appeared only at certain caret columns, so walk them all.
      text = "#{cafe}#{nfd}X"
      ta = TextArea.new(text)
      (0..text.size).each do |_|
        b = MemoryBackend.new(40, 3)
        ta.render(Screen.new(b), Rect.new(0, 0, 40, 3), cursor: true, highlight: :request)
        # Strip the caret's own cell by comparing against the no-caret render: the drawn
        # text must be identical either way — the caret may INVERT a cell, never add one.
        plain = MemoryBackend.new(40, 3)
        TextArea.new(text).render(Screen.new(plain), Rect.new(0, 0, 40, 3),
          cursor: false, highlight: :request)
        b.cluster_row(0).should eq(plain.cluster_row(0)) # (cx=#{ta.cx})
        ta.move(0, 1)
      end
    end

    it "backspaces a whole cluster rather than stranding a combining mark" do
      ta = TextArea.new(cafe)
      ta.move(0, 999) # end of line
      ta.cx.should eq(cafe.size)
      ta.backspace
      ta.text.should eq("caf") # NOT "cafe" with the acute silently dropped
      ta.cx.should eq(3)
    end

    it "backspaces a ZWJ family without leaving a dangling joiner" do
      family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
      ta = TextArea.new("a#{family}b")
      ta.move(0, 999)
      ta.backspace # the 'b'
      ta.backspace # the whole family
      ta.text.should eq("a")
    end

    it "forward-deletes a whole cluster too" do
      ta = TextArea.new(nfd + "X")
      ta.delete
      ta.text.should eq(geul + "X") # the first syllable went as a unit
      ta.delete
      ta.text.should eq("X")
    end

    it "keeps the caret on a boundary after inserting in front of a combining mark" do
      # Typing `e` before a lone U+0301 MERGES them into one cluster; the caret must end
      # past the whole thing rather than inside it.
      ta = TextArea.new("\u{0301}")
      ta.insert('e')
      ta.text.should eq("e\u{0301}")
      ta.cx.should eq(2) # past the merged cluster, not between its two codepoints
    end

    it "lands a click on a cluster start, agreeing with where the caret paints" do
      rect = Rect.new(0, 0, 40, 3)
      ta = TextArea.new(cafe + "X")
      # Column 3 is the `é` cluster (c,a,f each 1 column).
      ta.click_to_cursor(rect, 3, 0)
      ta.cx.should eq(3) # the cluster START — never 4, between the e and the acute
      ta.click_to_cursor(rect, 4, 0)
      ta.cx.should eq(cafe.size) # past the cluster, on the X
    end
  end

  describe "display concealment (@conceal_spans)" do
    # "q=§data¦base64-encode§ x": open § at 2, ¦ at 7, closing § at 21.
    text = "q=§data¦base64-encode§ x"

    it "hides the concealed span inline while keeping it in the buffer" do
      backend = render_concealed(text, [{7, 21}])
      backend.row(0).rstrip.should eq("q=§data§ x") # ¦base64-encode gone from the screen
      # the buffer (and thus the wire bytes) still carry the full marker + chain
    end

    it "is a no-op with no conceal spans (full marker shows)" do
      backend = render_concealed(text, [] of {Int32, Int32})
      backend.row(0).rstrip.should eq(text)
    end

    it "treats a concealed run as atomic on horizontal move (one keypress each way, no hidden rest)" do
      # run [7,21) = ¦base64-encode; the closing § is at index 21, the trailing " x" after it.
      ta = TextArea.new(text)
      ta.conceal_spans = [{7, 21}]
      ta.move(0, 7) # left edge of the run (offset 7), on the visible value
      ta.cx.should eq(7)
      ta.move(0, 1)       # right: skips the whole run AND the closing § in one press
      ta.cx.should eq(22) # past the § (b+1) — NOT 21, where a backspace would hit a hidden byte
      ta.move(0, -1)      # left: back across it in one press
      ta.cx.should eq(7)
    end

    it "never lets an edit at the run boundary touch a hidden byte" do
      ta = TextArea.new(text)
      ta.conceal_spans = [{7, 21}]
      ta.move(0, 7) # the only legal rest at the value/chain seam is on the VISIBLE value side
      ta.backspace  # deletes the last value char, never a concealed chain byte
      ta.text.should eq("q=§dat¦base64-encode§ x")
    end

    it "keeps concealment from corrupting the buffer text" do
      ta = TextArea.new(text)
      ta.conceal_spans = [{7, 21}]
      ta.text.should eq(text) # concealment is display-only
    end

    it "bands the visible marker and accents the closing § (chain-attached signal)" do
      # Displayed "q=§data§ x": § at col 2, data 3..6, closing § at col 7.
      ta = TextArea.new(text)
      ta.conceal_spans = [{7, 21}]
      ta.bg_regions = [{2, 22, Theme.marker_bg(0)}] # whole marker; the conceal-aware paint skips hidden cells
      b = MemoryBackend.new(60, 8)
      ta.render(Screen.new(b), Rect.new(0, 0, 60, 8), cursor: false, highlight: :request)
      b.row(0).rstrip.should eq("q=§data§ x")
      # The band bg covers the visible marker cells only (cols 2..7), not the surrounding text.
      b.bg_at(2, 0).should eq(Theme.marker_bg(0))
      b.bg_at(7, 0).should eq(Theme.marker_bg(0))
      b.bg_at(0, 0).should_not eq(Theme.marker_bg(0)) # "q" before the marker
      b.bg_at(8, 0).should_not eq(Theme.marker_bg(0)) # space after the marker
      # The closing § is accented (chain attached); the opening § keeps plain marker_fg.
      b.fg_at(7, 0).should eq(Theme.marker_accent)
      b.fg_at(2, 0).should eq(Theme.marker_fg)
      # The accent MUST differ from marker_fg or the signal is invisible (in monochrome
      # palettes accent == text_bright == marker_fg, which is exactly the trap to avoid).
      Theme.marker_accent.should_not eq(Theme.marker_fg)
    end
  end

  describe "#insert_pair (marker escape §§/¦¦)" do
    it "inserts the char twice as one undoable unit, caret past both" do
      ta = TextArea.new("ab")
      ta.end_of_line
      ta.insert_pair('§')
      ta.text.should eq("ab§§")
      ta.cx.should eq(4)
      ta.undo # a single undo removes the whole pair
      ta.text.should eq("ab")
    end
  end

  describe "#replace_all (undoable full-buffer swap)" do
    it "swaps the buffer, places the caret, and stays undoable (unlike set_text)" do
      ta = TextArea.new("q=§secret¦base64-encode§")
      ta.insert('X') # a prior edit that must survive as undoable
      ta.replace_all("q=secretX", 9)
      ta.text.should eq("q=secretX")
      ta.cx.should eq(9)
      ta.undo # reverts the strip...
      ta.text.should eq("Xq=§secret¦base64-encode§")
      ta.undo # ...and the earlier insert is still on the stack
      ta.text.should eq("q=§secret¦base64-encode§")
    end
  end

  describe "#match_count / #replace_matches (^F find&replace)" do
    it "counts and replaces every occurrence, case-insensitively like the search" do
      ta = TextArea.new("Admin admin\nADMIN x")
      ta.match_count("admin").should eq(3) # per occurrence, not per line
      ta.replace_matches("admin", "root").should eq(3)
      ta.text.should eq("root root\nroot x")
    end

    it "is one undo step" do
      ta = TextArea.new("a a a")
      ta.replace_matches("a", "b")
      ta.text.should eq("b b b")
      ta.undo
      ta.text.should eq("a a a")
    end

    it "treats the replacement literally (no backreference expansion)" do
      ta = TextArea.new("hello")
      ta.replace_matches("hello", "\\1$0").should eq(1)
      ta.text.should eq("\\1$0")
    end

    it "escapes regex metacharacters in the query" do
      ta = TextArea.new("a.c abc")
      ta.match_count("a.c").should eq(1) # the '.' is literal, so "abc" must not match
      ta.replace_matches("a.c", "z").should eq(1)
      ta.text.should eq("z abc")
    end

    it "deletes matches on an empty replacement, and no-ops when nothing matches" do
      ta = TextArea.new("foo bar foo baz")
      ta.replace_matches("foo ", "").should eq(2)
      ta.text.should eq("bar baz")
      ta.replace_matches("nope", "x").should eq(0)
      ta.match_count("").should eq(0) # an empty query never matches
      ta.text.should eq("bar baz")
    end
  end

  describe "#home / #end_of_line" do
    it "jumps the caret to the start / end of the current line (insert lands there)" do
      ta = TextArea.new("abc")
      ta.end_of_line
      ta.insert('X') # appended at end
      ta.home
      ta.insert('Y') # prepended at start
      ta.text.should eq("YabcX")
    end
  end

  describe "#delete" do
    it "removes the char under the caret" do
      ta = TextArea.new("abc") # caret at column 0 after construction
      ta.delete
      ta.text.should eq("bc")
    end

    it "joins the next line when the caret is at end-of-line" do
      ta = TextArea.new("ab\ncd")
      ta.end_of_line # caret at end of line 0
      ta.delete      # forward-delete across the line break
      ta.text.should eq("abcd")
    end

    it "is a no-op at the very end of the buffer (does not dirty)" do
      ta = TextArea.new("ab")
      ta.end_of_line
      before = ta.edits
      ta.delete
      ta.text.should eq("ab")
      ta.edits.should eq(before)
    end
  end

  describe "#undo (array-snapshot)" do
    it "reverts a single-char insert" do
      ta = TextArea.new("ab")
      ta.end_of_line
      ta.insert('c')
      ta.text.should eq("abc")
      ta.undo
      ta.text.should eq("ab")
    end

    it "reverts a newline split and a subsequent line-join independently (multi-line ops)" do
      ta = TextArea.new("hello world")
      ta.move(0, 5)     # caret after "hello"
      ta.insert_newline # -> "hello\n world"
      ta.text.should eq("hello\n world")
      ta.backspace # join back -> "hello world"
      ta.text.should eq("hello world")
      ta.undo # undo the join -> split again
      ta.text.should eq("hello\n world")
      ta.undo # undo the split -> original
      ta.text.should eq("hello world")
    end

    it "keeps earlier snapshots intact after editing a restored buffer (no shared-array corruption)" do
      ta = TextArea.new("a\nb\nc")
      ta.end_of_line
      ta.insert('X') # "aX\nb\nc"
      ta.insert('Y') # "aXY\nb\nc"
      ta.undo        # back to "aX\nb\nc"
      ta.text.should eq("aX\nb\nc")
      ta.insert('Z') # edit the restored buffer -> "aXZ\nb\nc"
      ta.text.should eq("aXZ\nb\nc")
      ta.undo # the Z edit
      ta.text.should eq("aX\nb\nc")
      ta.undo # the X edit -> original
      ta.text.should eq("a\nb\nc")
    end
  end

  describe "#env_complete ($ENV autocomplete)" do
    before_each do
      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [{"HOST", "api.test"}, {"TOKEN", "s3cr3t-value"}, {"TOKEN2", "other"}]
      Gori::Settings.project_env_vars = [] of {String, String}
    end

    after_each do
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.project_env_vars = [] of {String, String}
      Gori::Settings.env_prefix = "$"
    end

    it "stays inert until enabled" do
      ta = TextArea.new
      ta.insert('$')
      ta.env_completing?.should be_false
    end

    it "opens on a bare prefix and offers every registered var" do
      ta = TextArea.new
      ta.env_complete = true
      ta.insert('$')
      ta.env_completing?.should be_true
    end

    it "filters as a partial key is typed and Tab accepts the selected var" do
      ta = TextArea.new
      ta.env_complete = true
      "$TO".each_char { |c| ta.insert(c) } # matches TOKEN + TOKEN2
      ta.env_completing?.should be_true
      ta.handle_env_complete_key(env_key(Termisu::Input::Key::Tab)).should be_true
      ta.text.should eq("$TOKEN") # first match (sorted), whole token rewritten
      ta.env_completing?.should be_false
    end

    it "closes once the sole match is fully typed (nothing to complete)" do
      ta = TextArea.new
      ta.env_complete = true
      "$HOST".each_char { |c| ta.insert(c) }
      ta.env_completing?.should be_false
    end

    it "does not treat a non-key partial as an env token ($1 is literal)" do
      ta = TextArea.new
      ta.env_complete = true
      "$1".each_char { |c| ta.insert(c) }
      ta.env_completing?.should be_false
    end

    it "closes when the caret leaves the token (Home/arrow)" do
      ta = TextArea.new
      ta.env_complete = true
      "$TOK".each_char { |c| ta.insert(c) }
      ta.env_completing?.should be_true
      ta.home
      ta.env_completing?.should be_false
    end

    it "↓ then Enter accepts the second match" do
      ta = TextArea.new
      ta.env_complete = true
      "$TO".each_char { |c| ta.insert(c) }
      ta.handle_env_complete_key(env_key(Termisu::Input::Key::Down)).should be_true
      ta.handle_env_complete_key(env_key(Termisu::Input::Key::Enter)).should be_true
      ta.text.should eq("$TOKEN2")
    end

    it "opens nothing when no vars are registered" do
      Gori::Settings.env_vars = [] of {String, String}
      ta = TextArea.new
      ta.env_complete = true
      ta.insert('$')
      ta.env_completing?.should be_false
    end
  end

  describe "#env_peek ($ENV value peek)" do
    before_each do
      Gori::Settings.env_prefix = "$"
      Gori::Settings.env_vars = [{"HOST", "api.test"}, {"TOKEN", "s3cr3t-value"}]
      Gori::Settings.project_env_vars = [] of {String, String}
    end

    after_each do
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.project_env_vars = [] of {String, String}
      Gori::Settings.env_prefix = "$"
    end

    it "reveals a complete $KEY's resolved value under the caret in NORMAL mode (peek)" do
      # "k=$TOKEN" — caret at col 4 sits inside the TOKEN key run; not insert (cursor:false).
      render_peek("k=$TOKEN", 4, false, true).contains?("s3cr3t-value").should be_true
    end

    it "also reveals the value in INSERT mode when the autocomplete isn't offering matches" do
      # Caret at col 8 = end of a fully-typed unique $TOKEN → the dropdown closes, peek shows.
      render_peek("k=$TOKEN", 8, true, false).contains?("s3cr3t-value").should be_true
    end

    it "stays hidden for an unregistered $KEY (a literal $word is just text, not a var)" do
      # $NOPE isn't a registered var → no peek row; row 1 (below the caret) stays blank.
      # The literal "k=$NOPE" still paints on row 0 as ordinary editor text.
      render_peek("k=$NOPE", 4, false, true).row(1).strip.should be_empty
    end

    it "stays hidden when the pane is neither focused-insert nor peeking" do
      render_peek("k=$TOKEN", 4, false, false).contains?("s3cr3t-value").should be_false
    end

    it "stays hidden when the caret isn't on an env token" do
      render_peek("k=$TOKEN", 1, false, true).contains?("s3cr3t-value").should be_false
    end
  end

  describe "right-border scroll gauge (opt-in)" do
    it "rides a thumb on the border when the buffer overflows, and only when enabled" do
      ta = Gori::Tui::TextArea.new((0...50).map { |i| "line #{i}" }.join("\n"))
      col = 20 # rect.right of a 20-wide pane — where a framing card's hairline sits

      on = MemoryBackend.new(30, 10)
      ta.render(Screen.new(on), Rect.new(0, 0, 20, 8), cursor: false, gauge: true, gauge_focused: true)
      on.grid[0][col].should eq('┃') # 50 lines ≫ 8 rows → thumb pinned at the top (scroll 0)
      (0...8).count { |y| on.grid[y][col] == '┃' }.should be > 0

      off = MemoryBackend.new(30, 10)
      ta.render(Screen.new(off), Rect.new(0, 0, 20, 8), cursor: false) # gauge defaults off
      (0...8).count { |y| off.grid[y][col] == '┃' }.should eq(0)
    end
  end

  describe ".normalize_lf" do
    # The contract is exactly "what set_text would store", since every reconcile guard uses it
    # to decide whether set_text (caret/scroll/undo destroying) can be skipped.
    it "returns the text set_text would store, for CRLF, bare LF and lone CR" do
      {"a\r\nb\r\n\r\n", "a\nb\n\n", "plain", "", "a\rb", "tail\r"}.each do |s|
        TextArea.normalize_lf(s).should eq(TextArea.new(s).text)
      end
    end

    # A blanket \r→\n gsub would split "a\rb" into two lines and report a spurious mismatch;
    # set_text keeps the lone \r on the line, so normalize_lf must too.
    it "keeps a lone mid-line CR instead of splitting it into a new line" do
      TextArea.normalize_lf("a\rb").should eq("a\rb")
    end
  end
end
