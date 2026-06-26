require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private REG = Gori::Convert.default_registry

private def render_convert(*, input : String, chain : String, pane : Symbol = :input,
                           popup : ChainComplete = ChainComplete.new,
                           prompt : Symbol? = nil, prompt_buf : String = "",
                           w : Int32 = 80, h : Int32 = 30) : MemoryBackend
  view = ConvertView.new
  ta = TextArea.new(input)
  result = Gori::Convert.run(REG, input.to_slice, chain)
  backend = MemoryBackend.new(w, h)
  view.render(Screen.new(backend), Rect.new(0, 0, w, h),
    input: ta, chain: chain, chain_cx: chain.size, chain_pre: "",
    result: result, pane: pane, focused: true, popup: popup, prompt: prompt, prompt_buf: prompt_buf)
  backend
end

describe Gori::Tui::ConvertView do
  it "renders the pipeline notebook sections + per-step intermediates + output" do
    b = render_convert(input: "hello", chain: "base64 > sha256")
    b.contains?("INPUT").should be_true
    b.contains?("hello").should be_true
    b.contains?("CHAIN").should be_true
    b.contains?("base64 > sha256").should be_true
    b.contains?("PIPELINE").should be_true
    b.contains?("base64").should be_true   # step 1 name
    b.contains?("aGVsbG8=").should be_true # step 1 intermediate output
    b.contains?("sha256").should be_true   # step 2 name
    b.contains?("OUTPUT").should be_true

    expected = String.new(Gori::Convert.run(REG, "hello".to_slice, "base64 > sha256").output.not_nil!)
    b.contains?(expected[0, 24]).should be_true # the final sha256 hex
  end

  it "shows the identity hint and mirrors input when the chain is empty" do
    b = render_convert(input: "plain text", chain: "")
    b.contains?("no chain").should be_true
    b.contains?("plain text").should be_true
  end

  it "renders a failed step in the pipeline without crashing" do
    b = render_convert(input: "!!notbase64!!", chain: "base64-decode > sha256")
    b.contains?("✗").should be_true
    b.contains?("chain failed").should be_true # OUTPUT header marks the failure
  end

  it "draws the autocomplete dropdown when the chain pane has an open popup" do
    popup = ChainComplete.new
    popup.set(["base64-encode", "base64url-encode"], 0, 3)
    b = render_convert(input: "x", chain: "bas", pane: :chain, popup: popup)
    b.contains?("base64-encode").should be_true
    b.contains?("base64url-encode").should be_true
  end

  it "renders the save/load mini-prompt over the output region" do
    b = render_convert(input: "x", chain: "hex", prompt: :save_as, prompt_buf: "myhash")
    b.contains?("save chain as:").should be_true
    b.contains?("myhash").should be_true
  end

  it "colours the section-divider tees to match the frame (gold when focused)" do
    # The ├/┤ land on the frame's side borders, so a focused body must light them
    # gold instead of leaving a grey notch in the gold frame.
    [{true, Theme.focus_gold}, {false, Theme.border}].each do |(focused, want)|
      view = ConvertView.new
      backend = MemoryBackend.new(80, 30)
      inner = Rect.new(1, 1, 78, 28) # inset so the left tee at inner.x-1 = col 0 is on-screen
      result = Gori::Convert.run(REG, "x".to_slice, "hex")
      view.render(Screen.new(backend), inner,
        input: TextArea.new("x"), chain: "hex", chain_cx: 3, chain_pre: "",
        result: result, pane: :input, focused: focused, popup: ChainComplete.new, prompt: nil, prompt_buf: "")
      tee_row = (0...30).find { |y| backend.grid[y][0] == '├' }
      tee_row.should_not be_nil
      backend.fg_at(0, tee_row.not_nil!).should eq(want)
    end
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
