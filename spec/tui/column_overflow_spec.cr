require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# Width must be measured in DISPLAY COLUMNS, never `String#size`. A Hangul/CJK syllable is
# one character and TWO columns, so a char-count budget ("fits in 22") lets a cell paint
# double its allowance — through the neighbouring column, through the card's right border,
# and (Fuzzer) across the gap into the DIST sidebar. `Screen.draw_width` is the column
# measure `Screen#text` actually advances by, and `Screen.column_for` is its exact inverse
# at cluster boundaries (`foundation_spec.cr`), so truncating with the pair can never split
# a wide glyph.

private def tmp_sitemap_store(&)
  path = File.tempname("gori-colspill", ".db")
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

private def capture_flow(store, host, method, target)
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: host, port: 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil))
end

# The screen row the tagged leaf landed on: the only row carrying both the memo marker and
# the method chip.
private def tagged_row(b : MemoryBackend, h : Int32) : Int32
  (0...h).each { |y| return y if b.row(y).includes?("#") && b.row(y).includes?("GET") }
  -1
end

describe "SitemapView tag column" do
  # At 70 cols the tag column is [45, 60] and the GET chip sits at [66, 68]. A 9-syllable
  # memo is 12 chars but 21 COLUMNS, so `text.size > avail` (12 > 16) was false, nothing
  # truncated, and the right-aligned origin `tag_right - text.size + 1` started the run 5
  # columns too far right — straight through the gap and over the METHODS chip.
  it "never paints a CJK memo past the tag column's right edge" do
    tmp_sitemap_store do |store|
      capture_flow(store, "acme.test", "GET", "/api/users")
      store.set_sitemap_tag("acme.test", "/api/users", "결제플로우확인요망")

      view = SitemapView.new
      view.reload(store)
      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))

      y = tagged_row(b, 20)
      y.should_not eq(-1)
      row = b.row(y) # one char per CELL, so an index here is a column
      # tag_right is column 60; 61..65 is the mandated gap before the METHODS column.
      (61..65).each { |x| row[x].should eq(' ') } # (col #{x})
      row[66, 3].should eq("GET")
      # The memo is still SHOWN — clipped with an ellipsis, not dropped.
      b.row(y).should contain("…")
    end
  end

  # The truncation branch was worse than the branch that never fired: `text[0, avail - 1]`
  # cut by CHARACTERS, so 15 chars of Hangul is 27 columns drawn from a char-derived origin
  # 9 columns left of where it belongs — over the whole METHODS column AND the right border.
  it "keeps a long CJK memo inside the tag column when it truncates" do
    tmp_sitemap_store do |store|
      capture_flow(store, "acme.test", "GET", "/api/users")
      store.set_sitemap_tag("acme.test", "/api/users", "결제플로우확인요망결제플로우확인요")

      view = SitemapView.new
      view.reload(store)
      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))

      y = tagged_row(b, 20)
      y.should_not eq(-1)
      row = b.row(y)
      (61..65).each { |x| row[x].should eq(' ') } # (col #{x})
      row[66, 3].should eq("GET")
      row[69].should eq(' ') # the row's last column stays clear of the memo
    end
  end
end

describe "FuzzerView results payload cell" do
  # 80 cols with the DIST sidebar on (`v`) gives RESULTS `inner.w = 53` — its right border
  # is column 54 and the DIST card starts at 56. A 22-character Hangul payload is 44
  # COLUMNS, so `payload.size > 22` was false, `ljust(22)` added nothing, and the row ran 22
  # columns long; neither `screen.text` passed `width:`, so the status cell alone was drawn
  # from column 53 straight over the border and into the gap.
  it "does not paint a CJK payload past the RESULTS card border" do
    hangul = "가나다라마바사아자차카타파하거너더러머버서어" # 22 syllables = 44 columns
    hangul.size.should eq(22)
    Screen.draw_width(hangul).should eq(44)

    rendered = ["p" * 22, hangul].map do |payload|
      view = FuzzerView.new
      view.load_request("https://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
      view.focus_pane(:results) # the DIST sidebar is on by default (`v` toggles it)
      view.append_result(Gori::Fuzz::Result.new(
        0_i64, [payload], nil, 200, 1200_i64, 40, 5, 1000_i64, nil, false, false, nil))
      b = MemoryBackend.new(80, 24)
      view.render(Screen.new(b), Rect.new(0, 0, 80, 24), true)
      b
    end
    ascii_b, cjk_b = rendered

    hdr = (0...24).find { |y| ascii_b.row(y).includes?("  #   payload") }.not_nil!
    row_y = hdr + 1
    cjk_b.row(row_y).should contain("200") # the row really rendered

    # Column 54 is the RESULTS card's right border and 55 the gap before DIST. Nothing the
    # payload cell does may reach either — and everything from the border rightwards must be
    # byte-identical to the ASCII control, whose cells all land well inside.
    cjk_b.row(row_y)[54].should eq(Frame::V)
    cjk_b.row(row_y)[54..].should eq(ascii_b.row(row_y)[54..])
  end

  # The other half of the same defect, reachable with a plain ASCII payload: a body under
  # DIST_MIN_TOTAL (a 40-column terminal ⇒ body.w 36) gets no sidebar, RESULTS takes the
  # full width, and the status cell then ends EXACTLY at `inner.right`. Every remaining cell
  # was clamped with `{inner.right - x, 1}.max` — floored at ONE, not zero — so the
  # len/words/time cell still painted a column at `inner.right`, which is the column
  # `Frame.card` drew this card's own right border on.
  it "spends no column at all once the row reaches the card's right edge" do
    view = FuzzerView.new
    view.load_request("https://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    view.focus_pane(:results)
    view.append_result(Gori::Fuzz::Result.new(
      0_i64, ["ab"], nil, 200, 1200_i64, 40, 5, 1000_i64, nil, false, false, nil))
    b = MemoryBackend.new(36, 24)
    view.render(Screen.new(b), Rect.new(0, 0, 36, 24), true)

    row_y = (0...24).find { |y| b.row(y).includes?("  #   payload") }.not_nil! + 1
    b.row(row_y).should contain("200") # the row really rendered
    b.row(row_y)[35].should eq(Frame::V)
  end
end
