require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The Probe detail's AFFECTED URLS region, brought onto the shape `IssuesView`'s RELATED card
# was given in dae5cf21.
#
# It was an OPEN region — an `inner_divider`, a text heading, then the URL rows running to the
# bottom of the pane. Open-ended blocks read as "the rest of this pane" rather than as a thing
# with its own edges, which is the wrong reading for the one region of a drill-in an operator
# actually navigates; and it was the last detail pane in the tree still drawn that way.
#
# The defect underneath the cosmetics is the one this file's `agrees with the draw` example
# guards: the renderer walked `rect.y + 5` → divider → heading → list while `affected_rect`
# wrote out the `rect.y + 7` that lands on, under a comment claiming it was "the derivation
# `render_detail` walks". Two derivations agreeing by arithmetic, not by construction — move a
# row in the renderer and every click in the URL list addresses the wrong row, with nothing
# raising and no test failing.

private def detail_store(&)
  path = File.tempname("gori-probe-detail", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# An open Probe detail on a finding with `urls` affected URLs.
private def detail(store, urls = 3, &)
  urls.times do |i|
    store.upsert_probe_issue(Gori::Probe::Detection.new(
      "missing_hsts", "headers", "a.test", "https://a.test/page/#{i}",
      "Strict-Transport-Security missing", Gori::Store::Severity::Medium))
  end
  view = ProbeView.new
  view.reload(store)
  view.open_detail(store).should be_true
  yield view
end

# Renders the detail through the same `BodyChrome.framed` path the shell uses and hands back
# the backend plus the framed interior — the rect every geometry method is asked about.
private def draw(view, w = 80, h = 20, focused = true) : {MemoryBackend, Rect}
  backend = MemoryBackend.new(w, h)
  screen = Screen.new(backend)
  inner = uninitialized Rect
  BodyChrome.framed(screen, Rect.new(0, 0, w, h), true) do |r|
    inner = r
    view.render(screen, r, focused)
  end
  {backend, inner}
end

private def row_of(backend, text : String) : Int32
  (0...backend.size[1]).each { |y| return y if backend.row(y).includes?(text) }
  raise "#{text.inspect} is not on the rendered grid"
end

describe "Probe detail — AFFECTED URLS card" do
  it "closes the region into a card whose heading rides the top border" do
    detail_store do |store|
      detail(store) do |view|
        backend, _ = draw(view)
        y = row_of(backend, "AFFECTED URLS")
        line = backend.row(y)
        # A CARD, not a heading over an open region: the title sits ON a border run, and the
        # row carries the card's own corners. The old shape put `AFFECTED URLS (3)` on a plain
        # text row with an `inner_divider` above it and no left/right edge at all.
        line.includes?("╭─ AFFECTED URLS ").should be_true
        line.ends_with?("╮│").should be_true
        # …and the card closes. The old region simply stopped at the detail frame.
        backend.row(view.affected_card_rect(Rect.new(1, 1, 78, 18)).bottom - 1)
          .includes?("╰─").should be_true
      end
    end
  end

  it "puts the count and hit total in the border-meta slot, not in the title" do
    detail_store do |store|
      detail(store) do |view|
        backend, _ = draw(view)
        line = backend.row(row_of(backend, "AFFECTED URLS"))
        # `shared_chrome_spec` bans both halves of the old head string: a count inside a card
        # title (it makes the title's width a moving target) and a hand-placed right-aligned
        # annotation on a card's top border. `Frame.border_meta` is the slot for both.
        line.includes?("AFFECTED URLS (").should be_false
        line.includes?(" 3 · seen ×3 ").should be_true
        # Right-aligned, which is what makes it independent of the title's width.
        line.index("3 · seen").not_nil!.should be > line.index("AFFECTED URLS").not_nil!
      end
    end
  end

  it "agrees with the draw about which row a click lands on" do
    detail_store do |store|
      detail(store) do |view|
        backend, inner = draw(view)
        # Find where the renderer actually PUT each URL, then click there and ask which URL
        # the caret is on. This is the drift guard: it reads the row off the rendered grid
        # rather than pinning a number, so it fails the moment the hit-test's geometry stops
        # being the renderer's.
        (0...3).each do |i|
          url = "https://a.test/page/#{i}"
          view.detail_click(inner, 4, row_of(backend, url))
          view.affected_url.should eq(url)
        end
      end
    end
  end

  it "keeps every row the open region drew" do
    detail_store do |store|
      detail(store) do |view|
        _, inner = draw(view)
        # Row-budget neutral, the same trade the Issues change made: the heading moves onto the
        # top border and the card's bottom border takes the row that frees. The old region ran
        # from `inner.y + 7` to the bottom of the pane.
        body = view.affected_rect(inner).not_nil!
        body.h.should eq(inner.bottom - (inner.y + 7))
      end
    end
  end

  it "stays inside the detail pane" do
    detail_store do |store|
      detail(store) do |view|
        _, inner = draw(view)
        card = view.affected_card_rect(inner)
        card.x.should be >= inner.x
        card.right.should be <= inner.right
        card.bottom.should be <= inner.bottom
      end
    end
  end

  it "dims its border when the body does not have focus" do
    detail_store do |store|
      detail(store) do |view|
        lit, _ = draw(view, focused: true)
        dim, _ = draw(view, focused: false)
        y = row_of(lit, "AFFECTED URLS")
        # The one region of this drill-in that takes keys, so its outline is where focus is
        # legible. The `inner_divider` it replaces took the same input; a card keeps the signal
        # on all four sides instead of one.
        lit.fg_at(1, y).should eq(Frame.pane_border(true))
        dim.fg_at(1, y).should eq(Frame.pane_border(false))
      end
    end
  end

  it "accounts for itself when the finding has no affected URLs" do
    detail_store do |store|
      # `Store#parse_affected` answers `[] of String` for a row whose JSON will not parse, so
      # an empty list is reachable — and `ReadPane` draws nothing at all for one. Before the
      # card that was an unremarkable gap under a heading; inside a bordered card it was a
      # framed void with no account of itself.
      store.upsert_probe_issue(Gori::Probe::Detection.new(
        "missing_hsts", "headers", "a.test", "https://a.test/", "t", Gori::Store::Severity::Low))
      store.@db.exec("UPDATE probe_issues SET affected = ?", "not json")
      view = ProbeView.new
      view.reload(store)
      view.open_detail(store).should be_true
      view.affected_url.should be_nil

      backend, _ = draw(view)
      row_of(backend, "AFFECTED URLS").should be >= 0
      backend.row(row_of(backend, "(none recorded)")).includes?("(none recorded)").should be_true
    end
  end

  it "draws no card at a height that cannot hold one" do
    detail_store do |store|
      detail(store) do |view|
        # `Frame.card` spends two rows on its own outline, so a one-row grant must draw nothing
        # rather than a half-frame — and `affected_rect` must answer nil there, or a click
        # would be measured against a card that is not on screen.
        short = Rect.new(1, 1, 78, ProbeView::DETAIL_HEAD_ROWS + 1)
        view.affected_card_rect(short).h.should eq(1)
        view.affected_rect(short).should be_nil
      end
    end
  end
end
