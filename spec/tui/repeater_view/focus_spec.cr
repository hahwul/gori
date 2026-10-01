require "../../spec_helper"
require "../../support/memory_backend"

include Gori::Tui

private def draw(view : RepeaterView, w : Int32, h : Int32) : MemoryBackend
  mb = MemoryBackend.new(w, h)
  view.render(Screen.new(mb), Rect.new(0, 0, w, h))
  mb
end

# #1421: at terminal height ≤16 the request | response columns were not drawn, yet focus stayed
# on them — the badge read `BODY · REQUEST` and `i` + typing edited a request nobody could see.
describe "Gori::Tui::RepeaterView — panes the frame did not draw" do
  it "moves focus off a column too short to draw, onto the TARGET card" do
    view = RepeaterView.new
    view.load_blank
    view.focus_pane(:request)
    # The 3-row TARGET card plus two rows: a column card there would be borders and no line.
    mb = draw(view, 100, 5)
    view.pane_drawn?(:request).should be_false
    view.pane_drawn?(:response).should be_false
    view.focus.should eq(:target)
    mb.row(3).includes?("need a taller window").should be_true
    view.pane_at(Rect.new(0, 0, 100, 5), 10, 3).should be_nil # nothing there to click
  end

  it "keeps the focus ring, focus_last and a click off the hidden columns" do
    view = RepeaterView.new
    view.load_blank
    draw(view, 100, 5)
    view.focus.should eq(:target)
    view.pane_advance(1)
    view.focus.should eq(:target)
    view.pane_advance(-1)
    view.focus.should eq(:target)
    view.focus_last
    view.focus.should eq(:target)
    view.focus_pane(:response)
    view.focus.should eq(:target)
  end

  it "gives the ring back the columns once they fit again" do
    view = RepeaterView.new
    view.load_blank
    draw(view, 100, 5)
    view.focus.should eq(:target)
    draw(view, 100, 6) # one interior line: the columns draw
    view.pane_drawn?(:request).should be_true
    view.pane_advance(1)
    view.focus.should eq(:request)
    view.focus_last
    view.focus.should eq(:response)
  end

  it "records a TARGET card the body is too short for, and leaves focus where it is" do
    view = RepeaterView.new
    view.load_blank
    view.focus_pane(:request)
    draw(view, 100, 1)
    view.pane_drawn?(:target).should be_false
    view.pane_drawn?(:request).should be_false
    view.focus.should eq(:request) # nowhere on screen to move it; the controller gates the keys
  end
end
