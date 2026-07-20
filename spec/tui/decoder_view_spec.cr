require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private REG = Gori::Decoder.default_registry

private def render_decoder(*, input : String, chain : String, pane : Symbol = :input,
                           popup : ChainComplete = ChainComplete.new,
                           prompt : Symbol? = nil, prompt_buf : String = "",
                           w : Int32 = 80, h : Int32 = 30) : MemoryBackend
  view = DecoderView.new
  ta = TextArea.new(input)
  result = Gori::Decoder.run(REG, input.to_slice, chain)
  backend = MemoryBackend.new(w, h)
  view.render(Screen.new(backend), Rect.new(0, 0, w, h),
    input: ta, chain: chain, chain_cx: chain.size, chain_pre: "",
    result: result, pane: pane, focused: true, popup: popup, prompt: prompt, prompt_buf: prompt_buf)
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

  it "renders the save/load mini-prompt over the output region" do
    b = render_decoder(input: "x", chain: "hex", prompt: :save_as, prompt_buf: "myhash")
    b.contains?("save chain as:").should be_true
    b.contains?("myhash").should be_true
  end

  it "hscroll_output scrolls a long OUTPUT line sideways into view (shift+←/→)" do
    view = DecoderView.new
    long_line = "HEAD" + ("." * 150) + "TAIL"
    # `result` (the OUTPUT content) is independent of the `input:` TextArea (the INPUT
    # card's own display) — keep INPUT short/unrelated so its unscrolled echo of the
    # long line's head can't be mistaken for the OUTPUT card's (scrollable) content.
    result = Gori::Decoder.run(REG, long_line.to_slice, "")
    rect = Rect.new(0, 0, 80, 30)
    render_args = {
      input: TextArea.new("unrelated"), chain: "", chain_cx: 0, chain_pre: "",
      result: result, pane: :output, focused: true, popup: ChainComplete.new,
      prompt: nil, prompt_buf: "",
    }

    backend = MemoryBackend.new(80, 30)
    view.render(Screen.new(backend), rect, **render_args)
    backend.contains?("HEAD").should be_true
    backend.contains?("TAIL").should be_false # off the right edge, clipped

    40.times { view.hscroll_output(1) } # scroll well past the line's width
    backend2 = MemoryBackend.new(80, 30)
    view.render(Screen.new(backend2), rect, **render_args)
    backend2.contains?("TAIL").should be_true
    backend2.contains?("HEAD").should be_false # scrolled off the left edge
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
      result: result, pane: :input, focused: true, popup: ChainComplete.new, prompt: nil, prompt_buf: "")

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
      result: result, pane: :chain, focused: true, popup: ChainComplete.new, prompt: nil, prompt_buf: "")
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
      result: result, pane: :output, focused: true, popup: ChainComplete.new, prompt: nil, prompt_buf: "")
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

describe "DecoderView OUTPUT h-scroll" do
  # Decoding is precisely where raw control bytes surface — an unhex/base64 of a binary
  # blob is the whole point of the tab. The OUTPUT rows draw through `screen.text`, which
  # gives every control char a cell, but the h-scroll clamp measured them with
  # display_width, where those chars are 0 columns. The clamp's ceiling therefore fell
  # short of the real content and the tail of a decoded line could not be scrolled to.
  it "scrolls a decoded line containing control bytes to its end" do
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
        result: result, pane: :output, focused: true, popup: ChainComplete.new,
        prompt: nil, prompt_buf: "")
    end

    # Assert on the OUTPUT card ALONE: the PIPELINE card above it echoes the same decoded
    # bytes as the unhex step's intermediate and does NOT scroll, so a whole-grid match
    # would report the unscrolled copy (cf. the hscroll_output spec above, which keeps
    # INPUT unrelated for the same reason).
    out_card = ->(b : MemoryBackend) do
      top = (0...30).index { |y| b.row(y).includes?("OUTPUT") }.not_nil!
      (top...30).map { |y| b.row(y) }.join("\n")
    end

    at0 = MemoryBackend.new(80, 30)
    render.call(at0)
    out_card.call(at0).should contain("STARTTOK")
    out_card.call(at0).should_not contain("ENDTOK") # tail off to the right

    15.times { view.hscroll_output(4) }
    scrolled = MemoryBackend.new(80, 30)
    render.call(scrolled)
    out_card.call(scrolled).should contain("ENDTOK")       # reachable
    out_card.call(scrolled).should_not contain("STARTTOK") # head genuinely scrolled off
  end
end
