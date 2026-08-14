require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# Three panes each drew content whose SIZE they never checked against the space they were
# handed. The shapes differ but the mistake is one: clamp one axis, forget the other.
#
#   * Fuzzer CONFIG  — a bottom-anchored tail whose y was `.max`-clamped onto the row the
#     payload-set list starts at, so two writers shared a row.
#   * Repeater RESPONSE — left-anchored border chips with no right edge, on a HALF-width pane.
#   * TrafficEmptyState — a card admitted by a shared height floor rather than its own height.
#
# All three are only visible on a small terminal, and the app renders from 40x8 up
# (`Layout.usable?`), so every size these examples use is one the app supports.

private def fuzzer_with_set(value : String = "one,two,three") : FuzzerView
  view = FuzzerView.new
  view.load_request("http://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
  view.apply_set(nil, SetSpec.new(:list, value))
  view
end

private def rows_of(view : FuzzerView, w : Int32, h : Int32) : Array(String)
  b = MemoryBackend.new(w, h)
  view.render(Screen.new(b), Rect.new(0, 0, w, h))
  (0...h).map { |y| b.row(y) }
end

describe "FuzzerView CONFIG pane on a short pane" do
  # `tail_top = {inner.bottom - 3, inner.y + 1}.max` collapsed onto the sets' first row, and
  # neither writer pads, so "Mode   ‹ sniper › P×N" landed ON " 1 list one,two,three" and the
  # set text showed through the Mode label's spaces: "Modeist‹ sniper ›hP×N". The set's VALUE
  # was gone entirely — the corruption ate the one thing the row exists to show.
  it "never draws the Mode row on top of a payload-set row" do
    (10..20).each do |h|
      rows = rows_of(fuzzer_with_set, 120, h)
      rows.any?(&.includes?(" 1 list one,two,three")).should be_true # (h=#{h})
      rows.any?(&.includes?("Mode   ‹ sniper ›")).should be_true     # (h=#{h})
      rows.any?(&.includes?("Modeist")).should be_false              # (h=#{h})
    end
  end

  # The zero-set case was the FIRST-OPEN default and worse: the empty branch placed the Add
  # row at `{y0 + 1, limit - 1}.min`, which with a collapsed tail is the header's own row —
  # and `draw_add_row` pads, so "PAYLOAD SETS" was erased down to a stray "P".
  it "keeps the PAYLOAD SETS header and the empty-state line when no set is configured" do
    view = FuzzerView.new
    view.load_request("http://h", "GET / HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    (10..20).each do |h|
      rows = rows_of(view, 120, h)
      rows.any?(&.includes?("PAYLOAD SETS")).should be_true        # (h=#{h})
      rows.any?(&.includes?("(no sets yet)")).should be_true       # (h=#{h})
      rows.any?(&.includes?("P+ Add payload set")).should be_false # (h=#{h})
    end
  end

  # The tail gives up rows from the bottom (run read-out, then Advanced, then Mode) instead
  # of climbing — so the sets keep their row and nothing is ever double-written.
  it "drops the tail's lowest rows rather than overlapping, as the pane shrinks" do
    tall = rows_of(fuzzer_with_set, 120, 20)
    tall.any?(&.includes?("Advanced")).should be_true
    short = rows_of(fuzzer_with_set, 120, 10)
    short.any?(&.includes?("Mode   ‹ sniper ›")).should be_true # Mode is the last to go
    short.any?(&.includes?(" 1 list one,two,three")).should be_true
  end
end

# `handle_detail` matched no arm for Home/End/PgUp/PgDn and its trailing `true` swallowed
# them, and FuzzerController defines no `body_scroll`, so the Runner's
# `page_nav_delta` → `body_scroll` fallback could not cover for it either. This pane was the
# only ReadPane consumer in the tree with neither path.
private def detail_view : FuzzerView
  body = (0...40).map { |i| "line #{i} ................" }.join("\n")
  view = FuzzerView.new
  view.load_request("http://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
  r = Gori::Fuzz::Result.new(0_i64, ["p0"], nil, 200, 60_i64, 9, 5, 1000_i64, nil, false, false, nil,
    "HTTP/1.1 200 OK\r\n\r\n".to_slice, body.to_slice)
  view.append_result(r)
  view.open_detail
  view
end

describe "FuzzerView RESULT detail page navigation" do
  it "moves the caret on PgDn and reports the key as consumed" do
    view = detail_view
    view.render(Screen.new(MemoryBackend.new(100, 20)), Rect.new(0, 0, 100, 20))
    before = view.detail_copy_text
    view.detail_motion_key(key(Termisu::Input::Key::PageDown)).should be_true
    view.detail_copy_text.should_not eq(before)
  end

  it "handles End and PgUp too" do
    view = detail_view
    view.render(Screen.new(MemoryBackend.new(100, 20)), Rect.new(0, 0, 100, 20))
    view.detail_motion_key(key(Termisu::Input::Key::PageDown)).should be_true
    paged = view.detail_copy_text
    view.detail_motion_key(key(Termisu::Input::Key::PageUp)).should be_true
    view.detail_copy_text.should_not eq(paged)
    view.detail_motion_key(key(Termisu::Input::Key::End)).should be_true
  end

  # It must DECLINE anything else, or the arms after it in `handle_detail` (↑/↓ row step,
  # ←/→ pane chain) would never run.
  it "declines a non-motion key so the controller keeps matching" do
    view = detail_view
    view.detail_motion_key(key(Termisu::Input::Key::Down)).should be_false
    view.detail_motion_key(key(Termisu::Input::Key::Left)).should be_false
  end
end

describe "RepeaterView RESPONSE border chrome on a narrow pane" do
  # `Frame.chip` does not clip (its sibling `Frame.toggle_badge` documents the opposite
  # contract). The three chips need ~40 columns from `rect.x + 12`, and RESPONSE is a
  # half-width split pane, so below ~88 cols the cluster ran through this card's own '╮'
  # and on over the OUTER frame's border — the row came out one cell longer than every
  # sibling row, ending in "p:pretty" instead of a corner.
  it "keeps the chips inside the card at 80 columns" do
    Gori::Settings.pretty_bodies_default = false
    view = RepeaterView.new
    view.load_blank
    b = MemoryBackend.new(80, 24)
    view.render(Screen.new(b), Rect.new(0, 0, 80, 24))

    y = (0...24).find { |r| b.row(r).includes?("RESPONSE") }
    y.should_not be_nil
    row = b.row(y.not_nil!).rstrip
    row.should end_with("╮")                  # the card's own top-right corner survives
    row.includes?("p:pretty").should be_false # the chip that did not fit is dropped whole
    row.includes?("d:diff").should be_true    # the ones that fit are still drawn
  end

  # Wide enough and every chip is back — the fix is a fit test, not a removal.
  it "still draws all three chips when there is room" do
    Gori::Settings.pretty_bodies_default = false
    view = RepeaterView.new
    view.load_blank
    b = MemoryBackend.new(120, 24)
    view.render(Screen.new(b), Rect.new(0, 0, 120, 24))

    y = (0...24).find { |r| b.row(r).includes?("RESPONSE") }.not_nil!
    row = b.row(y).rstrip
    row.should end_with("╮")
    row.includes?("d:diff").should be_true
    row.includes?("^X:hex").should be_true
    row.includes?("p:pretty").should be_true
  end
end

describe TrafficEmptyState do
  # The variant gate compared `rect.h` against a SHARED floor (7, or 5 for fuzzer_results)
  # while a full card runs 6..13 rows depending on variant and flags. Nothing clips the
  # interior — each renderer walks `y` downward unguarded — so an admitted-but-too-tall card
  # drew straight out of its rect: in the app it cut the outer frame's bottom border and put
  # its own bottom border BELOW the status bar, on the last terminal row.
  #
  # Renders into a backend taller than the rect, so anything drawn past `rect.h` shows up as
  # a non-blank row in the margin.
  #
  # This list is LITERAL, so a variant missing from it is untested rather than passing. It must
  # name every variant `render` dispatches — the four engine tabs and `:project_desc` (which was
  # absent while it was the only variant carrying art, i.e. the one most able to overflow).
  #
  # The width sweep is what covers the FIGURE. A figure rides above the card inside an
  # already-granted full tier, so it is the art gate — not the card gate — that decides whether
  # those extra rows fit; sweeping one fixed width never exercises `FULL_MIN_W` or a figure's
  # own `min_w`, and the art path adds a second reason a renderer can outgrow its rect.
  {% for variant in [:history, :sitemap, :intercept, :repeater, :fuzzer, :fuzzer_results, :probe, :issues, :notes, :project_desc, :discover, :comparer, :miner, :miner_results, :sequencer, :sequencer_samples, :oast] %}
    it "never draws {{ variant.id }} below its rect, at any size the gate admits" do
      (8..26).each do |h|
        [30, 40, 42, 43, 46, 50, 60, 100].each do |w|
          margin = 8
          b = MemoryBackend.new(w, h + margin)
          TrafficEmptyState.render(Screen.new(b), Rect.new(0, 0, w, h),
            variant: {{ variant }}, listen: {"127.0.0.1", 8080})
          (h...(h + margin)).each do |y|
            b.row(y).strip.should eq("") # ({{ variant.id }} at #{w}x#{h} spilled onto row #{y})
          end
        end
      end
    end
  {% end %}

  # …and nothing may run off the RIGHT edge either. A figure is centred on its ink extent, so a
  # block wider than the pane would paint past `rect.right` — where `Screen`'s bounds check
  # silently drops it in the app but a narrower rect inside a wider backend makes it visible.
  {% for variant in [:history, :fuzzer_results, :notes, :project_desc, :sequencer, :oast] %}
    it "never draws {{ variant.id }} past its right edge" do
      (8..26).each do |h|
        [42, 46, 50, 60].each do |w|
          b = MemoryBackend.new(w + 10, h)
          TrafficEmptyState.render(Screen.new(b), Rect.new(0, 0, w, h),
            variant: {{ variant }}, listen: {"127.0.0.1", 8080})
          (0...h).each do |y|
            b.row(y)[w, 10].strip.should eq("") # ({{ variant.id }} at #{w}x#{h} spilled past col #{w} on row #{y})
          end
        end
      end
    end
  {% end %}

  # The intercept card is the tallest variant (up to 13 rows with catch off + capture off),
  # so it is the one whose flag combinations most easily outgrow the rect.
  it "never spills for any intercept flag combination" do
    {true, false}.each do |capturing|
      {true, false}.each do |catch_on|
        (8..24).each do |h|
          b = MemoryBackend.new(100, h + 8)
          TrafficEmptyState.render(Screen.new(b), Rect.new(0, 0, 100, h),
            variant: :intercept, listen: {"127.0.0.1", 8080},
            capturing: capturing, catch_on: catch_on)
          (h...(h + 8)).each do |y|
            b.row(y).strip.should eq("") # (capturing=#{capturing} catch_on=#{catch_on} h=#{h} row #{y})
          end
        end
      end
    end
  end

  # `:oast` is the other variant whose height moves with a flag: with no provider configured the
  # card grows a warning row, exactly the way `:intercept` does for catch/capture. The sweep
  # above only ever exercises the default (a provider present), i.e. the SHORTER of the two.
  it "never spills for either oast provider state" do
    {true, false}.each do |has_provider|
      (8..24).each do |h|
        b = MemoryBackend.new(100, h + 8)
        TrafficEmptyState.render(Screen.new(b), Rect.new(0, 0, 100, h),
          variant: :oast, has_provider: has_provider)
        (h...(h + 8)).each do |y|
          b.row(y).strip.should eq("") # (has_provider=#{has_provider} h=#{h} row #{y})
        end
      end
    end
  end

  # Degrading is the point: a rect too short for the full card still says something.
  it "falls back to a shorter form instead of drawing nothing" do
    b = MemoryBackend.new(100, 9)
    TrafficEmptyState.render(Screen.new(b), Rect.new(0, 0, 100, 9),
      variant: :intercept, listen: {"127.0.0.1", 8080})
    (0...9).map { |y| b.row(y) }.any? { |r| !r.strip.empty? }.should be_true
  end

  # …but degrading is only right when the pane really cannot pay. These are the heights an 80x24
  # leaves the two panes a sub-tab strip squeezes hardest — Sitemap's tree (strip + filter bar +
  # column header) and Probe's findings list (strip + mode row + filter bar + column header).
  # Both cards used to want exactly one row more than that and fell through to the three-line
  # medium form, which on Target put a full card and a bare sentence one chip apart inside a
  # single tab: Discover's pane pays for no filter bar and had rows to spare.
  #
  # Measured from the running app, not derived — if the chrome above either pane grows a row,
  # this is the spec that says so instead of the card quietly vanishing at the common size.
  it "still draws the full card in the panes an 80x24 leaves Sitemap and Probe" do
    [{:sitemap, 11, "SITE MAP"}, {:probe, 10, "PROBE"}].each do |(variant, h, title)|
      b = MemoryBackend.new(80, h)
      TrafficEmptyState.render(Screen.new(b), Rect.new(0, 0, 80, h),
        variant: variant, listen: {"127.0.0.1", 8080})
      b.contains?(title).should be_true, "#{variant} fell out of its full card at 80x#{h}"
    end
  end
end

private def key(k : Termisu::Input::Key, shift : Bool = false) : Termisu::Event::Key
  mods = shift ? Termisu::Input::Modifier::Shift : Termisu::Input::Modifier::None
  Termisu::Event::Key.new(k, mods, nil)
end

# `ReadPane#hscroll` is `return if @wrap` (read_pane.cr), so the chord is inert on every
# wrapping pane. The removal was declared finished at repeater_view.cr's own comment ("the
# footer hint that still advertised '⇧←/→ h-scroll' … are all gone") and the chains really
# were deleted in Intercept and Issues — but six surfaces kept advertising it, three of them
# live footers (fuzzer/intercept/decoder controllers) and three rows of this cheat-sheet.
#
# The Comparer is the one pane that genuinely still pans: `ComparerController` calls
# `view.hscroll`, and its ReadPane is built WITHOUT `wrap:`. It must KEEP its entry.
describe "HelpView ⇧←/→ h-scroll rows" do
  it "advertises h-scroll for the Comparer alone" do
    claiming = HelpView::SECTIONS.flat_map do |(title, items)|
      items.any?(&.desc.includes?("h-scroll")) ? [title] : [] of String
    end
    claiming.should eq(["COMPARER"])
  end
end
