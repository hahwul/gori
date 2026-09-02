require "../spec_helper"

include Gori::Tui

# Miss Ring's stand on the TUTORIAL (Tutorial.companion_place / .companion_band / .step_card).
#
# Unlike the picker — which centres a 50-column card and drops her when she doesn't fit
# beside it — the tour NARROWS its card to make room, because copying the picker's rule to
# a 78-column card would not have seated her until ~102 columns. These sweep the pair of
# rules together: the card's width and her stand are two halves of one decision, and the
# way this breaks is that they stop agreeing.
describe Gori::Tui::Tutorial do
  # The whole reason the band exists. 80x24 is the conventional terminal, and the tour's
  # own "too small" message names 80 as its floor — a guide mascot absent on exactly the
  # terminals new users run would have missed the point.
  it "seats her from 80 columns" do
    Tutorial.companion_place(80, 24).should_not be_nil
    Tutorial.companion_place(80, 16).should_not be_nil
    Tutorial.companion_place(120, 40).should_not be_nil
  end

  # Below ~52 columns step_card's 40-column floor wins and the card grows back over her
  # stand, so she stands down rather than painting over the mock.
  it "stands down when the card floor leaves her no room" do
    Tutorial.companion_place(50, 24).should be_nil
    Tutorial.companion_place(44, 24).should be_nil
  end

  # The sprite may never touch the card: she stands there for the whole tour, and the mock
  # shell is what the user is being taught to read. (Her bubble is another matter — it
  # floats over the card for the few seconds she is talking, exactly as it does over the
  # picker's card and a tab body in the session.)
  #
  # Measured against the rect COMPANION.DRAW would paint, NOT against companion_place's return value.
  # Those are the same rect when she is seated, but sourcing it from the draw path is what
  # keeps this from being a restatement of companion_place's own guard — see the render-path
  # test below, which is the one that fails if render_companion stops consulting the gate.
  it "never overlaps the card at any size she appears at" do
    (16..60).each do |h|
      (40..200).each do |w|
        next unless Tutorial.companion_place(w, h) # the gate render_companion applies
        rect = Companion.place(Tutorial.companion_stage(w, h)).should_not be_nil
        box = Tutorial.step_card(w, h, Tutorial.companion_band(w, h))
        # Her plate claims a column either side of the sprite (Companion.draw), so the box that
        # actually gets painted is one wider on each side than `rect`.
        cols = (rect.x - 1) < box.right && (rect.right + 1) > box.x
        rows = rect.y < box.bottom && rect.bottom > box.y
        (cols && rows).should be_false
      end
    end
  end

  # THE RENDER-PATH DRIFT GUARD, and the reason the tour needs one the picker does not.
  #
  # Tutorial.companion_place is deliberately stricter than Companion.place: it stands her down at sizes
  # Companion.place will happily seat her at. Companion.draw only knows Companion.place, so render_companion has to
  # apply the stricter rule itself — and when it did not, she painted over the mock tab bar
  # across the whole 40..51-column band while every other example here still passed.
  #
  # This asserts the two rules disagree EXACTLY where the card would be hit: seated sizes
  # clear the narrowed card, stood-down sizes are precisely the ones that would not have.
  # That makes the gate load-bearing rather than decorative.
  it "stands down precisely at the sizes Companion.draw would paint over the card" do
    stood_down = 0
    (16..60).each do |h|
      (40..200).each do |w|
        next unless drawn = Companion.place(Tutorial.companion_stage(w, h)) # else Companion.draw paints nothing
        if Tutorial.companion_place(w, h)
          # Seated: the card was narrowed for her, so what Companion.draw paints clears it.
          Tutorial.step_card(w, h, Tutorial::COMPANION_BAND).right.should be <= drawn.x - 1
        else
          # Stood down: had render_companion not gated, Companion.draw would have hit the card.
          stood_down += 1
          Tutorial.step_card(w, h, 0).right.should be > drawn.x - 1
        end
      end
    end
    # The band is real, not a rule that never fires — 40..51 columns at every height.
    stood_down.should be > 0
  end

  # …and the render path itself. render_companion hands Companion.draw whatever companion_draw_stage returns,
  # so asserting on that rect IS asserting on what gets painted: nil means Companion.draw is
  # never reached, and non-nil means the sprite Companion.draw derives from it clears the card.
  # This is the example that fails if the gate is dropped from render_companion.
  it "hands Companion.draw a stage only when the sprite it derives will clear the card" do
    (16..60).each do |h|
      (40..200).each do |w|
        stage = Tutorial.companion_draw_stage(w, h)
        if stage.nil?
          Tutorial.companion_place(w, h).should be_nil # nothing is drawn at all
          next
        end
        rect = Companion.place(stage).should_not be_nil # exactly what Companion.draw will paint
        box = Tutorial.step_card(w, h, Tutorial.companion_band(w, h))
        (rect.x - 1).should be >= box.right
        (rect.right + 1).should be <= w
      end
    end
  end

  it "stays inside the terminal" do
    (16..60).each do |h|
      (40..200).each do |w|
        next unless rect = Tutorial.companion_place(w, h)
        (rect.x - 1).should be >= 0
        (rect.right + 1).should be <= w
        rect.y.should be >= 0
      end
    end
  end

  # The two footer rows (h-2 hint, h-1 Prev/Next) are the tour's escape hatch — a mascot
  # parked on them would cover the one control that is never allowed to be unreachable.
  it "keeps clear of the footer rows" do
    (16..60).each do |h|
      (40..200).each do |w|
        next unless rect = Tutorial.companion_place(w, h)
        rect.bottom.should be <= h - Tutorial::FOOTER_ROWS
      end
    end
  end

  # A default install has her OFF, and must render the tour exactly as it did before she
  # existed. band: 0 is the code path that takes — assert it against the original formula
  # rather than against a snapshot, so a change to either side has to be deliberate.
  it "leaves the card untouched while she is off" do
    (16..60).each do |h|
      (40..200).each do |w|
        box = Tutorial.step_card(w, h, 0)
        cw = { {w - 4, Tutorial::CARD_W}.min, 40 }.max
        box.w.should eq(cw)
        box.x.should eq({(w - cw) // 2, 0}.max)
      end
    end
  end

  # …and with her on, the card gives up only her band — never more, and never so much that
  # it stops being able to hold a mock (step_card's own 40-column floor).
  it "narrows the card by her band and no further" do
    (16..60).each do |h|
      (40..200).each do |w|
        band = Tutorial.companion_band(w, h)
        next if band.zero?
        box = Tutorial.step_card(w, h, band)
        plain = Tutorial.step_card(w, h, 0)
        box.w.should be <= plain.w
        box.w.should be >= 40
        box.w.should be >= plain.w - Tutorial::COMPANION_BAND
      end
    end
  end

  # Height is not hers to change: the band is a COLUMN reservation, and the tour's
  # "too small" guard tests step_card(w, h).h against MIN_CARD_H.
  it "never changes the card's height or vertical seat" do
    (16..60).each do |h|
      (40..200).each do |w|
        banded = Tutorial.step_card(w, h, Tutorial.companion_band(w, h))
        plain = Tutorial.step_card(w, h, 0)
        banded.h.should eq(plain.h)
        banded.y.should eq(plain.y)
      end
    end
  end
end

# `Event::Key#char` is `@char || key.to_char`, so a CHORD arrives carrying its bare letter:
# ^P is char 'p', ⌥L is char 'l'. Every `ev.char == …` guard in the tour was reading the chord
# as the letter, which was reproducible end to end at four separate sites:
#
#   ^L in Practice        → switched a tab and ticked the "switch" goal
#   ^O with space open    → ran the menu's `o Open` row and closed it
#   ^P then ^T in INS     → typed "pt" into the mock request body
#   ^P then ^T in the palette filter → left "pt" in the query box, ON THE ^P LESSON
#
# The real app guards this at each of the matching sites (Runner#handle_palette_key,
# Runner#handle_space_menu_key, TextField#handle_edit_key); the tour guarded it nowhere.
# These pin the shared rule, which is a class method for exactly this reason — the four
# call sites need a tty, the rule does not.
private def tut_key(k : Termisu::Input::Key,
                    mods : Termisu::Input::Modifier = Termisu::Input::Modifier::None,
                    char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, mods, char)
end

private def tut_char_key(c : Char,
                         mods : Termisu::Input::Modifier = Termisu::Input::Modifier::None) : Termisu::Event::Key
  # char: nil is what the Ctrl+letter parser branch produces (and what Keybind.dealias
  # rebuilds ⌥P as), so `char` falls back through `key.to_char` — the fallback that is the
  # whole bug.
  tut_key(Termisu::Input::Key.from_char(c), mods)
end

describe "Gori::Tui::Tutorial.bare_char" do
  it "passes an unmodified key through" do
    Gori::Tui::Tutorial.bare_char(tut_char_key('l')).should eq('l')
    Gori::Tui::Tutorial.bare_char(tut_char_key('[')).should eq('[')
    Gori::Tui::Tutorial.bare_char(tut_char_key('3')).should eq('3')
    # space_open_key? reads this one — Key::Space.to_char is ' '.
    Gori::Tui::Tutorial.bare_char(tut_key(Termisu::Input::Key::Space)).should eq(' ')
  end

  it "refuses the letter a ctrl or alt chord carries" do
    Gori::Tui::Tutorial.bare_char(tut_char_key('l', Termisu::Input::Modifier::Ctrl)).should be_nil
    Gori::Tui::Tutorial.bare_char(tut_char_key('o', Termisu::Input::Modifier::Ctrl)).should be_nil
    Gori::Tui::Tutorial.bare_char(tut_char_key('p', Termisu::Input::Modifier::Ctrl)).should be_nil
    Gori::Tui::Tutorial.bare_char(tut_char_key('i', Termisu::Input::Modifier::Alt)).should be_nil
    # …including when the terminal attached the char explicitly rather than via to_char.
    Gori::Tui::Tutorial.bare_char(
      tut_key(Termisu::Input::Key::LowerJ, Termisu::Input::Modifier::Ctrl, 'j')).should be_nil
  end

  it "keeps ⇧ — a capital is a bare character, and the Edit lesson accepts I" do
    Gori::Tui::Tutorial.bare_char(
      tut_key(Termisu::Input::Key::UpperI, Termisu::Input::Modifier::Shift)).should eq('I')
  end
end

describe "Gori::Tui::Tutorial.typed_char" do
  it "inherits the chord guard, so a chord never reaches a text field" do
    Gori::Tui::Tutorial.typed_char(tut_char_key('p', Termisu::Input::Modifier::Ctrl)).should be_nil
    Gori::Tui::Tutorial.typed_char(tut_char_key('t', Termisu::Input::Modifier::Ctrl)).should be_nil
    Gori::Tui::Tutorial.typed_char(tut_char_key('s', Termisu::Input::Modifier::Alt)).should be_nil
  end

  it "types ordinary printables" do
    Gori::Tui::Tutorial.typed_char(tut_char_key('a')).should eq('a')
    Gori::Tui::Tutorial.typed_char(tut_key(Termisu::Input::Key::Space)).should eq(' ')
  end

  # The window this replaced was `ord >= 32 && ord < 127`, so the lesson that asks the user
  # to "type a username" silently dropped every character a Korean/Japanese/accented keyboard
  # produces. TextField#insert has no such limit.
  it "accepts non-ASCII text the way the real editor does" do
    Gori::Tui::Tutorial.typed_char(tut_key(Termisu::Input::Key::Unknown, char: '한')).should eq('한')
    Gori::Tui::Tutorial.typed_char(tut_key(Termisu::Input::Key::Unknown, char: 'é')).should eq('é')
  end

  it "refuses control characters" do
    # Enter and Backspace are handled by their own branches ahead of the append, and carry
    # control chars besides — Key::Enter.to_char is '\n'.
    Gori::Tui::Tutorial.typed_char(tut_key(Termisu::Input::Key::Enter)).should be_nil
    Gori::Tui::Tutorial.typed_char(tut_key(Termisu::Input::Key::Unknown, char: '\u{7F}')).should be_nil
  end
end

# The tour's fake palette is filterable, so its row list can be EMPTY — and the ↑ arm took its
# modulo before checking, so `gori tutorial` → palette step → `^P` → type a non-matching
# character → ↑ died with an unhandled DivisionByZeroError. Both arrows now go through one
# helper; these are the cases that used to differ between them.
describe "Gori::Tui::Tutorial.wrap_sel" do
  it "returns 0 for an empty list instead of dividing by zero" do
    Gori::Tui::Tutorial.wrap_sel(0, -1, 0).should eq(0)  # the crash
    Gori::Tui::Tutorial.wrap_sel(0, +1, 0).should eq(0)  # the arm that was already guarded
    Gori::Tui::Tutorial.wrap_sel(7, -1, 0).should eq(0)  # a stale selection, list filtered away
    Gori::Tui::Tutorial.wrap_sel(3, +1, -1).should eq(0) # defensive: n can never be < 0, but 0 is the answer
  end

  it "wraps both directions over a non-empty list" do
    Gori::Tui::Tutorial.wrap_sel(0, -1, 4).should eq(3) # floored %, so ↑ from the top goes to the end
    Gori::Tui::Tutorial.wrap_sel(3, +1, 4).should eq(0)
    Gori::Tui::Tutorial.wrap_sel(1, -1, 4).should eq(0)
    Gori::Tui::Tutorial.wrap_sel(1, +1, 4).should eq(2)
  end

  it "lands in range even when the selection is already past the end" do
    # `render_fake_palette` clamps for drawing, but the state itself must not stay out of range.
    Gori::Tui::Tutorial.wrap_sel(9, +1, 3).should be < 3
    Gori::Tui::Tutorial.wrap_sel(9, -1, 3).should be < 3
    Gori::Tui::Tutorial.wrap_sel(1, +1, 1).should eq(0)
  end
end

# The fake palette had no scrolling and a hard 8-row overlay cap, so its FIFTH row could not
# be drawn at any terminal size — while ↑/↓ still selected it, the ▎ marker vanished off the
# bottom and ↵ ran a command that had never been on screen. The click path bounded the row by
# `rows.size` rather than by what was painted, so a click on the overlay's own bottom border
# ran an undrawn row. Draw, scroll and hit-test now share these two.
describe "Gori::Tui::Tutorial palette window" do
  # border + query + divider + rows + border, so an n-row list needs n + 4.
  it "counts only the rows between the divider and the bottom border" do
    Gori::Tui::Tutorial.palette_rows_visible(Gori::Tui::Rect.new(0, 0, 30, 9)).should eq(5)
    Gori::Tui::Tutorial.palette_rows_visible(Gori::Tui::Rect.new(0, 0, 30, 6)).should eq(2)
    Gori::Tui::Tutorial.palette_rows_visible(Gori::Tui::Rect.new(0, 0, 30, 4)).should eq(0)
    Gori::Tui::Tutorial.palette_rows_visible(Gori::Tui::Rect.new(0, 0, 30, 1)).should eq(0)
  end

  it "does not scroll while the whole list fits" do
    (0..4).each { |sel| Gori::Tui::Tutorial.palette_scroll(sel, 5, 5).should eq(0) }
    Gori::Tui::Tutorial.palette_scroll(4, 5, 8).should eq(0)
  end

  # The bug, in one line: at a 6-row overlay only 2 of 5 rows draw, and sel 4 must still be
  # one of them.
  it "keeps the selection inside the window" do
    (0..4).each do |sel|
      top = Gori::Tui::Tutorial.palette_scroll(sel, 5, 2)
      sel.should be >= top
      sel.should be < top + 2
    end
  end

  it "never scrolls past the end of the list" do
    Gori::Tui::Tutorial.palette_scroll(4, 5, 2).should eq(3)
    Gori::Tui::Tutorial.palette_scroll(9, 5, 2).should eq(3) # stale selection, list filtered down
  end

  it "returns 0 for an empty window or an empty list" do
    Gori::Tui::Tutorial.palette_scroll(0, 5, 0).should eq(0)
    Gori::Tui::Tutorial.palette_scroll(0, 0, 4).should eq(0)
  end
end

# The card MIN_CARD_H admits is three rows shorter than CONTENT_ROWS asks for, and the lessons
# used to walk a FIXED prose height down it — so at an 80x16 terminal (the size the tour's own
# "too small" message names as its minimum) the shell was left 4 rows, one under render_shell's
# floor, and Navigate and Practice painted an EMPTY card under "roam the mock". At 13 and 14
# rows the FLOWS pane showed 1 and 2 of its 3 rows, teaching "↓ list" over a list that could
# not move. The prose gives way now; these pin the whole reachable band, not one height.
describe "Gori::Tui::Tutorial.lesson_split" do
  # box.h at terminal heights 16..22 — step_card gives min(CONTENT_ROWS + 3, max(h - 4, 3)).
  card = ->(bh : Int32) { Gori::Tui::Rect.new(0, 2, 74, bh) }

  it "gives the mock its rows at every card height the tour will render" do
    (Gori::Tui::Tutorial::MIN_CARD_H..18).each do |bh|
      box = card.call(bh)
      # Navigate / Palette / SpaceMenu / Edit: headline + try line, muted detail rows tradeable.
      _, sy = Gori::Tui::Tutorial.lesson_split(box, fixed: 2, detail: 2)
      shell_h = box.bottom - 1 - sy
      shell_h.should be >= Gori::Tui::Tutorial::SHELL_ROWS
    end
  end

  # Practice carries the six goal chips, so it is the tightest lesson — and the one whose key
  # line teaches "↓ list". One-row chips (fixed: 2) must still clear SHELL_ROWS at the floor.
  it "clears the mock's rows on Practice once its goal chips fold to one row" do
    box = card.call(Gori::Tui::Tutorial::MIN_CARD_H)
    pad = Gori::Tui::Tutorial.prose_gaps(box, 2 + Gori::Tui::Tutorial::SHELL_ROWS, 1)
    _, sy = Gori::Tui::Tutorial.lesson_split(box, fixed: 2, detail: 0, pad: pad)
    (box.bottom - 1 - pad - sy).should be >= Gori::Tui::Tutorial::SHELL_ROWS
  end

  it "spends its spare rows on the prose once the card is tall enough" do
    box = card.call(18)
    keep, _ = Gori::Tui::Tutorial.lesson_split(box, fixed: 2, detail: 2)
    keep.should eq(2) # nothing dropped when there is room for both
    box12 = card.call(Gori::Tui::Tutorial::MIN_CARD_H)
    Gori::Tui::Tutorial.lesson_split(box12, fixed: 2, detail: 2)[0].should eq(0)
  end
end

# Welcome and Done wrote eleven rows into a card that can hold ten, and the eleventh painted
# straight over the bottom border ("╰─Re-run this tour anytime: gori tutorial──╯" at 80x16).
describe "Gori::Tui::Tutorial.prose_gaps" do
  it "drops spacers before text, and keeps every row inside the card" do
    [{9, 2}, {8, 2}].each do |(content, want)|
      (Gori::Tui::Tutorial::MIN_CARD_H..18).each do |bh|
        box = Gori::Tui::Rect.new(0, 2, 74, bh)
        gaps = Gori::Tui::Tutorial.prose_gaps(box, content, want)
        gaps.should be <= want
        last = Gori::Tui::Tutorial.prose_top(box) + content + gaps - 1
        last.should be < box.bottom - 1 # never the border row
      end
    end
  end
end

# The practice palette's "Go to …" rows act on the tab index they CARRY, not on their label:
# `run_overlay_selection` used to `case` on the English text, so rewording a row (or drawing
# it in another language) turned the switch into a silent no-op.
describe "Gori::Tui::Tutorial::PALETTE_ROWS" do
  it "carry the fake tab each navigating row switches to" do
    rows = Gori::Tui::Tutorial::PALETTE_ROWS
    rows.select { |(_, label, _)| label.starts_with?("Go to") || label == "Open Help" }
      .map { |(_, _, tab)| tab }.should eq([4, 2, 6])
    rows.reject { |(_, label, _)| label.starts_with?("Go to") || label == "Open Help" }
      .all? { |(_, _, tab)| tab.nil? }.should be_true
  end
end
