require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

describe Gori::Tui::HelpView do
  it "renders the grouped shortcut sections" do
    view = HelpView.new
    backend = MemoryBackend.new(100, 240) # tall enough for every row (grows as tabs are added)
    view.render(Screen.new(backend), Rect.new(0, 0, 100, 240))

    backend.contains?("GLOBAL").should be_true
    backend.contains?("command palette").should be_true
    backend.contains?("MOUSE").should be_true
    backend.contains?("REPEATER").should be_true
    backend.contains?("rename").should be_true  # the new sub-tab rename shortcut is documented
    backend.contains?("DECODER").should be_true # the Decoder tab cheat-sheet
  end

  describe "the Query page" do
    it "renders the whole language, built from the parser's own tables" do
      view = HelpView.new
      backend = MemoryBackend.new(100, 120)
      view.render_query(Screen.new(backend), Rect.new(0, 0, 100, 120))

      backend.contains?("SYNTAX").should be_true
      backend.contains?("FIELDS").should be_true
      backend.contains?("WORTH KNOWING").should be_true

      # Every field QL offers, with its meaning — not a hand-kept subset. This is the page the
      # one-row hints delegate to, so it is the one place that must be complete.
      Gori::QL::FIELDS.each do |name|
        backend.contains?("#{name}:").should be_true, "Query page is missing `#{name}:`"
      end
      backend.contains?(Gori::QL::FIELD_HELP["resp.body"]).should be_true

      # ...the operators, which no field list can show...
      backend.contains?("-path:/static").should be_true
      backend.contains?("NOT (host:cdn OR host:img)").should be_true
      # ...the spellings QL accepts but does not offer...
      backend.contains?("res.body:").should be_true
      # ...and the ways a query can look clean without having looked.
      backend.contains?("compressed bodies").should be_true
    end

    it "fits every syntax example in the left column without ellipsis" do
      # The column is widened past the cheat-sheet's KEY_W precisely so an example query is not
      # truncated — `NOT (host:cdn OR ho…` would teach the syntax wrong.
      Gori::QL::SYNTAX_HELP.each do |(example, _)|
        example.size.should be <= HelpView::QUERY_KEY_W, "example too wide: #{example}"
      end
      Gori::QL::CAVEATS.each { |(what, _)| what.size.should be <= HelpView::QUERY_KEY_W }
    end

    it "scrolls independently of the Shortcuts page" do
      # One shared offset would carry the cheat-sheet's position onto this page, where `at_top?`
      # then answers about the wrong page and ↑ pops focus to the strip mid-scroll.
      view = HelpView.new
      view.move(40)
      view.query_at_top?.should be_true
      view.at_top?.should be_false

      view.query_move(3)
      view.query_at_top?.should be_false
    end

    it "clamps to the last screenful rather than scrolling into blank space" do
      view = HelpView.new
      view.query_move(10_000)
      backend = MemoryBackend.new(100, 12)
      view.render_query(Screen.new(backend), Rect.new(0, 0, 100, 12))
      backend.contains?("WORTH KNOWING").should be_true # the last section is still on screen
      backend.contains?("SYNTAX").should be_false       # ...and the first has gone by
    end
  end

  it "gives every workbench tab a section" do
    # Miner, JWT and OAST had none, while Sequencer — also default-hidden — had a full one,
    # so "it's a hidden tab" was never the rule. Three tabs whose whole keyboard surface was
    # missing from the one screen that exists to answer "what can I press here".
    #
    # Title-matched rather than rendered, so a section that scrolls off a short terminal still
    # counts: this is about the CONTENT existing, not about it fitting.
    titles = HelpView::SECTIONS.map { |(t, _)| t }
    %w(REPEATER FUZZER MINER SEQUENCER JWT OAST DECODER COMPARER REWRITER COLORMARKER).each do |tab|
      titles.should contain(tab)
    end
  end

  it "scrolls — the first section leaves and the last arrives" do
    view = HelpView.new
    short = Rect.new(0, 0, 90, 8)
    view.render(Screen.new(MemoryBackend.new(90, 8)), short)
    view.at_top?.should be_true

    view.move(10_000) # past the end → clamped to the last screenful on render
    after = MemoryBackend.new(90, 8)
    view.render(Screen.new(after), short)
    after.contains?("GLOBAL").should be_false  # scrolled off the top
    after.contains?("OVERLAYS").should be_true # last section now on screen
    view.at_top?.should be_false
  end

  it "renders the About page with brand art, version, author, and GitHub URL" do
    view = HelpView.new
    backend = MemoryBackend.new(80, 40)
    view.render_about(Screen.new(backend), Rect.new(0, 0, 80, 40))

    backend.contains?("gori").should be_true
    backend.contains?("v#{Gori::VERSION}").should be_true
    backend.contains?("hahwul").should be_true
    backend.contains?("Hwan Lee").should be_true
    backend.contains?(Gori::REPOSITORY_URL).should be_true
    # Same ink as the project-picker brand mark. Asserted against Brand::ART itself
    # so restyling the mark can't quietly stop it being drawn: the bottom arc is one
    # unbroken run of glyphs, so it lands in the grid as a single contiguous string.
    # Through `ink`, because ART stores ring membership rather than glyphs — the
    # far ring's marker is painted as a solid block in a dimmer gold, and the
    # backend records glyphs.
    bottom = Brand::ART.last.lstrip.chars.map { |ch| Brand.ink(ch, Theme.focus_gold)[0] }.join
    backend.contains?(bottom).should be_true
  end
end
