require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private REG = Gori::Decoder.default_registry

private def render_decoder(*, input : String, chain : String, pane : Symbol = :input,
                           popup : ChainComplete = ChainComplete.new,
                           w : Int32 = 80, h : Int32 = 30) : MemoryBackend
  view = DecoderView.new
  ta = TextArea.new(input)
  result = Gori::Decoder.run(REG, input.to_slice, chain)
  backend = MemoryBackend.new(w, h)
  view.render(Screen.new(backend), Rect.new(0, 0, w, h),
    input: ta, chain: chain, chain_cx: chain.size, chain_pre: "",
    result: result, pane: pane, focused: true, popup: popup)
  backend
end

describe Gori::Tui::DecoderView do
  it "renders the pipeline notebook sections + per-step intermediates + output" do
    b = render_decoder(input: "hello", chain: "base64 > sha256")
    b.contains?("INPUT").should be_true
    b.contains?("hello").should be_true
    b.contains?("CHAIN").should be_true
    b.contains?("base64 > sha256").should be_true
    b.contains?("PIPELINE").should be_true
    b.contains?("base64").should be_true   # step 1 name
    b.contains?("aGVsbG8=").should be_true # step 1 intermediate output
    b.contains?("sha256").should be_true   # step 2 name
    b.contains?("OUTPUT").should be_true

    expected = String.new(Gori::Decoder.run(REG, "hello".to_slice, "base64 > sha256").output.not_nil!)
    b.contains?(expected[0, 24]).should be_true # the final sha256 hex
  end

  it "shows the identity hint and mirrors input when the chain is empty" do
    b = render_decoder(input: "plain text", chain: "")
    b.contains?("no chain").should be_true
    b.contains?("plain text").should be_true
  end

  it "renders a failed step in the pipeline without crashing" do
    b = render_decoder(input: "!!notbase64!!", chain: "base64-decode > sha256")
    b.contains?("✗").should be_true
    b.contains?("chain failed").should be_true # OUTPUT header marks the failure
  end

  it "draws the autocomplete dropdown when the chain pane has an open popup" do
    popup = ChainComplete.new
    popup.set(["base64-encode", "base64url-encode"], 0, 3)
    b = render_decoder(input: "x", chain: "bas", pane: :chain, popup: popup)
    b.contains?("base64-encode").should be_true
    b.contains?("base64url-encode").should be_true
  end

  # The save/load mini-prompt this view used to draw over the OUTPUT region is gone: naming
  # and recalling a chain are centered modals now (NamePromptOverlay / LibraryPicker), so
  # the coverage moved to spec/tui/library_overlays_spec.cr.

  # Was "hscroll_output scrolls a long OUTPUT line sideways into view (shift+←/→)". The OUTPUT
  # pane soft-wraps now, like the Repeater's RESPONSE that draws the same line, so the whole
  # `hscroll_output` chain is retired and both ends of a long decoded line are on screen at
  # once. Still under test: that the tail of a line wider than the pane is reachable at all —
  # which is what the h-scroll pair existed to provide.
  it "wraps a long OUTPUT line instead of scrolling it sideways" do
    view = DecoderView.new
    long_line = "HEAD" + ("." * 150) + "TAIL"
    # `result` (the OUTPUT content) is independent of the `input:` TextArea (the INPUT
    # card's own display) — keep INPUT short/unrelated so its echo of the long line's head
    # can't be mistaken for the OUTPUT card's content.
    result = Gori::Decoder.run(REG, long_line.to_slice, "")
    rect = Rect.new(0, 0, 80, 30)
    render_args = {
      input: TextArea.new("unrelated"), chain: "", chain_cx: 0, chain_pre: "",
      result: result, pane: :output, focused: true, popup: ChainComplete.new,
    }

    backend = MemoryBackend.new(80, 30)
    view.render(Screen.new(backend), rect, **render_args)
    backend.contains?("HEAD").should be_true
    backend.contains?("TAIL").should be_true # on a continuation row, not off the right edge
    # …and on a LOWER row: this is a wrap, not a pane wide enough to hold the whole line.
    head_row = (0...30).find { |y| backend.row(y).includes?("HEAD") }.not_nil!
    tail_row = (0...30).find { |y| backend.row(y).includes?("TAIL") }.not_nil!
    tail_row.should be > head_row
  end

  # `DecoderController#handle_output` pops focus up to the CHAIN field when `output_at_top?`,
  # so that predicate decides whether ↑ walks the pane or leaves it. Measured on the logical
  # line alone, a caret three rows into a wrapped line 0 answers true — and ↑ would abandon the
  # very rows it was asked to walk. `ReadPane#at_top?` measures the first VISUAL row; this pins
  # it through the wiring that actually ships, not just on a bare pane.
  it "is not 'at top' while the OUTPUT caret sits on a continuation row of line 0" do
    view = DecoderView.new
    long_line = "0123456789" * 20
    result = Gori::Decoder.run(REG, long_line.to_slice, "")
    rect = Rect.new(0, 0, 80, 30)
    render_args = {
      input: TextArea.new("unrelated"), chain: "", chain_cx: 0, chain_pre: "",
      result: result, pane: :output, focused: true, popup: ChainComplete.new,
    }
    view.render(Screen.new(MemoryBackend.new(80, 30)), rect, **render_args)

    view.output_at_top?.should be_true
    view.output_move(1, 0, result) # one VISUAL row down — still on line 0
    view.output_at_top?.should be_false
    view.output_move(-1, 0, result)
    view.output_at_top?.should be_true
  end

  it "lights only the focused section's card border gold (per-pane focus)" do
    # Each section is its own card now (not a divided single frame), so focusing
    # INPUT must gild only the INPUT card — the read-only PIPELINE/OUTPUT cards
    # stay hairline grey. The card's top-left corner '╭' carries the border colour.
    view = DecoderView.new
    backend = MemoryBackend.new(80, 30)
    rect = Rect.new(0, 0, 80, 30)
    result = Gori::Decoder.run(REG, "x".to_slice, "hex")
    view.render(Screen.new(backend), rect,
      input: TextArea.new("x"), chain: "hex", chain_cx: 3, chain_pre: "",
      result: result, pane: :input, focused: true, popup: ChainComplete.new)

    corners = (0...30).select { |y| backend.grid[y][0] == '╭' }
    corners.size.should eq 4 # one per card: INPUT, CHAIN, PIPELINE, OUTPUT

    backend.fg_at(0, corners[0]).should eq(Theme.focus_gold) # INPUT (focused) → gold
    backend.fg_at(0, corners[1]).should eq(Theme.border)     # CHAIN (unfocused) → grey
    backend.fg_at(0, corners[2]).should eq(Theme.border)     # PIPELINE (read-only) → grey
    backend.fg_at(0, corners[3]).should eq(Theme.border)     # OUTPUT (read-only) → grey
  end

  it "gilds the CHAIN card border when the chain pane holds focus" do
    view = DecoderView.new
    backend = MemoryBackend.new(80, 30)
    result = Gori::Decoder.run(REG, "x".to_slice, "hex")
    view.render(Screen.new(backend), Rect.new(0, 0, 80, 30),
      input: TextArea.new("x"), chain: "hex", chain_cx: 3, chain_pre: "",
      result: result, pane: :chain, focused: true, popup: ChainComplete.new)
    corners = (0...30).select { |y| backend.grid[y][0] == '╭' }
    backend.fg_at(0, corners[0]).should eq(Theme.border)     # INPUT (unfocused) → grey
    backend.fg_at(0, corners[1]).should eq(Theme.focus_gold) # CHAIN (focused) → gold
  end

  it "gilds the OUTPUT card border when the (read-only but navigable) output pane holds focus" do
    view = DecoderView.new
    backend = MemoryBackend.new(80, 30)
    result = Gori::Decoder.run(REG, "x".to_slice, "hex")
    view.render(Screen.new(backend), Rect.new(0, 0, 80, 30),
      input: TextArea.new("x"), chain: "hex", chain_cx: 3, chain_pre: "",
      result: result, pane: :output, focused: true, popup: ChainComplete.new)
    corners = (0...30).select { |y| backend.grid[y][0] == '╭' }
    backend.fg_at(0, corners[0]).should eq(Theme.border)     # INPUT → grey
    backend.fg_at(0, corners[1]).should eq(Theme.border)     # CHAIN → grey
    backend.fg_at(0, corners[2]).should eq(Theme.border)     # PIPELINE → grey
    backend.fg_at(0, corners[3]).should eq(Theme.focus_gold) # OUTPUT (focused) → gold
  end
end

describe Gori::Tui::ChainComplete do
  it "replaces the token under the caret with the chosen converter + separator" do
    c = ChainComplete.new
    c.set(["sha256"], 9, 12) # "base64 > sha" — token span [9,12)
    chain, cx = c.accept("base64 > sha", 12)
    chain.should eq("base64 > sha256 > ")
    cx.should eq(chain.size)
  end

  it "does not produce a doubled separator when the token abuts a separator" do
    c = ChainComplete.new
    c.set(["url-encode"], 0, 3)            # "b64>sha256" — but completing the first token "url"
    chain, _ = c.accept("url>sha256", 3)   # token [0,3) = "url", tail ">sha256"
    chain.should eq("url-encode > sha256") # NOT "url-encode > >sha256"
  end

  it "keeps the selected row on-screen when it scrolls past the 8-row fold" do
    c = ChainComplete.new
    names = (1..20).map { |i| "conv#{i.to_s.rjust(2, '0')}" }
    c.set(names, 0, 0)
    14.times { c.move(1) } # select index 14 (well past the 8 visible)
    c.selected.should eq 14
    backend = MemoryBackend.new(60, 20)
    inner = Rect.new(0, 0, 60, 20)
    c.render(Screen.new(backend), Rect.new(0, 0, 40, 1), inner)
    backend.contains?("conv15").should be_true # the selected (1-based) row is painted, not clipped
  end

  it "is closed until a non-empty match set is supplied" do
    c = ChainComplete.new
    c.open?.should be_false
    c.set([] of String, 0, 0)
    c.open?.should be_false
    c.set(["hex"], 0, 3)
    c.open?.should be_true
  end
end

describe "DecoderView OUTPUT control bytes" do
  # Decoding is precisely where raw control bytes surface — an unhex/base64 of a binary blob is
  # the whole point of the tab. The OUTPUT rows draw through `screen.text`, which gives every
  # control char a cell, and the retired h-scroll clamp measured them with `display_width`, where
  # those chars are 0 columns: its ceiling fell short of the real content and the tail of such a
  # line could not be reached at all.
  #
  # The pane wraps now, so the clamp is gone and the same hazard lives in the WRAP measure
  # instead — `Wrap.layout` breaks on `Screen.grapheme_cols`, the same ≥1-per-cluster measure
  # the draw advances by. That is what this pins: a line of tabs must break at the pane's edge
  # and its tail must land on a continuation row, not be counted as 14 columns and never wrap.
  it "wraps a decoded line containing control bytes so its end is reachable" do
    line = "STARTTOK#{"\t" * 100}ENDTOK"
    Screen.display_width(line).should eq(14) # the raw measure: 60 tabs count for nothing
    Screen.draw_width(line).should eq(114)   # what `text` paints: one cell per tab
    input = line.to_slice.hexstring
    result = Gori::Decoder.run(REG, input.to_slice, "unhex")
    String.new(result.output.not_nil!).should eq(line) # the decode really produced the tabs

    view = DecoderView.new
    ta = TextArea.new(input)
    rect = Rect.new(0, 0, 80, 30)
    render = ->(b : MemoryBackend) do
      view.render(Screen.new(b), rect, input: ta, chain: "unhex", chain_cx: 5, chain_pre: "",
        result: result, pane: :output, focused: true, popup: ChainComplete.new)
    end

    # Assert on the OUTPUT card ALONE: the PIPELINE card above it echoes the same decoded
    # bytes as the unhex step's intermediate and does NOT wrap, so a whole-grid match would
    # report that copy (cf. the wrap spec above, which keeps INPUT unrelated for the same
    # reason).
    top = 0
    at0 = MemoryBackend.new(80, 30)
    render.call(at0)
    top = (0...30).index { |y| at0.row(y).includes?("OUTPUT") }.not_nil!
    rows = (top...30).map { |y| at0.row(y) }
    card = rows.join("\n")
    card.should contain("STARTTOK")
    card.should contain("ENDTOK") # the tail wrapped onto a later row rather than being clipped
    # …and onto a DIFFERENT row: the tabs were measured at one cell each, so the 114-column
    # line broke at the pane's edge instead of being called 14 columns wide and left unwrapped.
    start_row = rows.index { |r| r.includes?("STARTTOK") }.not_nil!
    end_row = rows.index { |r| r.includes?("ENDTOK") }.not_nil!
    end_row.should be > start_row
  end
end
