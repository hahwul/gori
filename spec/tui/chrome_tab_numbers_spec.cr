require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# `Settings.tab_numbers?` (Layout, default off) paints `N:` before the first nine tabs, the
# sub-tab strip's convention — so the `1-9 jump` hint has something on screen to point at.
# The number is the tab's VISIBLE position (what `nav.posN` answers to), so a scrolled bar
# that starts at `5:History` still sends `5` there. Off, the bar is byte-identical to before.
describe "Chrome tab-bar numbers" do
  rect = Rect.new(0, 0, 260, 1) # wide enough for all twenty tabs, numbered

  it "leaves the default layout untouched" do
    plain = Chrome.menu_segments(rect, :history)
    numbered_off = Chrome.menu_segments(rect, :history, numbered: false)
    numbered_off.should eq(plain)
  end

  it "prefixes the first nine tabs with N: and widens each by two columns" do
    plain = Chrome.menu_segments(rect, :history)
    numbered = Chrome.menu_segments(rect, :history, numbered: true)
    numbered.size.should eq(plain.size)
    numbered.first(9).each_with_index do |(sym, seg), i|
      sym.should eq(plain[i][0])
      seg.w.should eq(plain[i][1].w + 2) # "N:" is two cells
    end
    numbered[9][1].w.should eq(plain[9][1].w) # the tenth carries no number — no digit reaches it
  end

  it "paints the number on the bar and dims it beside the name" do
    backend = MemoryBackend.new(260, 1)
    Chrome.render_menu(Screen.new(backend), rect, active_tab: :history, focused: true, numbered: true)
    row = backend.row(0)
    row.should contain("1:Project")
    row.should contain("3:History")
    x = row.index("2:Target").not_nil!
    backend.fg_at(x, 0).should eq(Chrome.menu_number_ink) # the digit, a step dimmer
    backend.fg_at(x + 2, 0).should eq(Theme.muted)        # the name
  end
end
