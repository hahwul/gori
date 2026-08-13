require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The `↓` dropdown. It is OPT-IN because it is dearer than the inline row, not cheaper — it
# occludes list rows where the row costs one — so most of what matters here is that it stays out
# of the way until asked for, and hands back exactly what the inline row would have done when it
# was never opened.
describe Gori::Tui::SuggestPopup do
  it "stays shut until asked, and refuses to open on nothing" do
    p = SuggestPopup.new
    p.open?.should be_false

    p.set([] of String)
    p.open!.should be_false
    p.open?.should be_false

    p.set(["host:", "header:"])
    p.open!.should be_true
    p.open?.should be_true
  end

  it "leaves Tab's outcome unchanged while it has never been opened" do
    # The whole compatibility promise: a bar whose popup was never opened splices `sugg.first`,
    # exactly as every filter bar did before this class existed.
    p = SuggestPopup.new
    p.choice(["host:", "header:"]).should eq("host:")
    p.choice([] of String).should be_nil

    # ...and once open, Tab takes what the arrows landed on instead.
    p.set(["host:", "header:"])
    p.open!
    p.move(1)
    p.choice(["host:", "header:"]).should eq("header:")
  end

  it "clamps at both ends rather than wrapping" do
    p = SuggestPopup.new
    p.set(["a:", "b:", "c:"])
    p.open!
    p.move(-1)
    p.selected.should eq(0)
    p.move(99)
    p.selected.should eq(2)
  end

  it "does not raise when moved with nothing in it" do
    # `clamp(0, -1)` raises on min > max instead of saturating, so the empty case has to return
    # before it. Unreachable via the current callers, which is why it needs a test.
    p = SuggestPopup.new
    p.set([] of String)
    p.move(1)
    p.selected.should eq(0)
  end

  it "keeps the selection on the same candidate across an edit that narrows the list" do
    # Typing another character must not silently move what Tab would take.
    p = SuggestPopup.new
    p.set(["req.header:", "resp.header:", "req.body:", "resp.body:"])
    p.open!
    p.move(3)
    p.choice([] of String).should eq("resp.body:")

    p.set(["resp.header:", "resp.body:"]) # the user typed `resp.`
    p.choice([] of String).should eq("resp.body:")
  end

  it "shuts itself when an edit leaves nothing to show" do
    # An empty dropdown is a hole punched in the list for no content.
    p = SuggestPopup.new
    p.set(["host:"])
    p.open!
    p.set([] of String)
    p.open?.should be_false
  end

  it "renders a row per candidate, each with its meaning and its polarity" do
    p = SuggestPopup.new
    p.set(["-resp.body:", "-resp.header:"])
    p.open!
    backend = MemoryBackend.new(100, 12)
    p.render(Screen.new(backend), 4, 1, Rect.new(1, 2, 98, 9))

    backend.contains?("-resp.body:").should be_true
    backend.contains?("-resp.header:").should be_true
    # The reason a row each is worth the occlusion: EVERY candidate gets its description, where
    # the one-line row can only describe the first.
    backend.contains?(Gori::QL::FIELD_HELP["resp.body"]).should be_true
    backend.contains?(Gori::QL::FIELD_HELP["resp.header"]).should be_true
    backend.contains?("excludes").should be_true
  end

  it "shuts itself on a frame it cannot draw, rather than hijacking Esc and Enter invisibly" do
    # `open?` gates Esc and ↵ in three controllers. An open-but-undrawable popup — a pane
    # narrower than MIN_W, or one where the anchor has reached the bottom — makes Esc stop
    # clearing the filter and ↵ stop applying it, with nothing on screen to explain why. Reachable
    # by resizing the terminal while the list is open.
    backend = MemoryBackend.new(100, 12)
    screen = Screen.new(backend)

    narrow = SuggestPopup.new
    narrow.set(["host:", "header:"])
    narrow.open!
    narrow.render(screen, 1, 1, Rect.new(1, 2, 8, 9)) # w < MIN_W
    narrow.open?.should be_false

    squashed = SuggestPopup.new
    squashed.set(["host:", "header:"])
    squashed.open!
    squashed.render(screen, 1, 9, Rect.new(1, 10, 98, 0)) # no rows to grow into
    squashed.open?.should be_false
  end

  it "draws nothing while closed, however many candidates it holds" do
    p = SuggestPopup.new
    p.set(["host:", "header:"])
    backend = MemoryBackend.new(100, 12)
    p.render(Screen.new(backend), 4, 1, Rect.new(1, 2, 98, 9))
    backend.contains?("host:").should be_false
  end

  it "flips above the anchor when there is no room below" do
    p = SuggestPopup.new
    p.set(["host:", "header:", "path:"])
    p.open!
    backend = MemoryBackend.new(100, 12)
    # Anchor near the bottom of the allowed region: below has 1 row, above has 6.
    p.render(Screen.new(backend), 4, 8, Rect.new(1, 2, 98, 7))
    backend.contains?("host:").should be_true
  end

  it "reads the BACKEND's help, like the inline row" do
    p = SuggestPopup.new
    p.set(["body:"])
    p.open!
    backend = MemoryBackend.new(100, 12)
    p.render(Screen.new(backend), 4, 1, Rect.new(1, 2, 98, 9),
      ->(f : String) { Gori::InterceptFilter.field_help(f) })
    backend.contains?("payload in hand").should be_true
    backend.contains?("8 KiB").should be_false
  end
end
