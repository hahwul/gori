require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"
require "../../src/gori/tui/authorize_identity_overlay"
require "../../src/gori/tui/authorize_identities_overlay"

include Gori::Tui

# The modal LIST cards answer a double-click on a row with what ↵ does there. Two shapes:
#
#   * Settings › Hostname overrides / Env open the row's inline editor and stay up (`:stay`);
#   * the Authorize identities and History columns lists hand off to a FORM — they arm
#     `pending` and close (`:cancel`), and the Runner's `on_close` opens the form.
#
# The second shape is why `Overlay#handle_double_click` answers an OUTCOME rather than the
# Bool the tab tier does: a list whose ↵ closes the card had no way to say so. `:pass` is the
# decline — the harness, like the shell, then delivers the press as an ordinary click.

private alias Identity = Gori::Authorize::Identity

private def with_hosts(entries : Array({String, String}), &)
  prev = Gori::Settings.hostname_overrides
  Gori::Settings.hostname_overrides = entries
  yield
ensure
  Gori::Settings.hostname_overrides = prev.not_nil!
end

private def with_env(prefix : String, vars : Array({String, String}), &)
  prev_prefix = Gori::Settings.env_prefix
  prev_vars = Gori::Settings.env_vars
  Gori::Settings.env_prefix = prefix
  Gori::Settings.env_vars = vars
  yield
ensure
  Gori::Settings.env_prefix = prev_prefix.not_nil!
  Gori::Settings.env_vars = prev_vars.not_nil!
end

# A cell on list row `idx`, found by inverting the overlay's own `row_at` over its box.
private def row_cell(h : OverlayHarness, &hit : Rect, Int32, Int32 -> Int32?) : {Int32, Int32}
  box = h.box.not_nil!
  box.h.times do |dy|
    y = box.y + dy
    x = box.x + 4
    return {x, y} if hit.call(box, x, y)
  end
  raise "the row is not on screen"
end

describe "HostsOverlay double-click" do
  it "opens the row's editor and stays up; off a row it passes" do
    with_hosts([{"a.test", "10.0.0.1"}, {"b.test", "10.0.0.2"}]) do
      ov = HostsOverlay.new
      h = OverlayHarness.new(ov)
      h.render
      x, y = row_cell(h) { |box, mx, my| ov.row_at(box, mx, my) == 1 ? 1 : nil }
      h.click(x, y)
      h.double_click(x, y).should be_true
      h.open?.should be_true
      ov.adding?.should be_true
      ov.text_fields.first.value.should eq("10.0.0.2 b.test")

      # A pair on the open row's text selects a word (the base contract) — still up, still editing.
      h.render
      h.double_click(x, y).should be_true
      ov.adding?.should be_true

      esc = OverlayHarness.new(HostsOverlay.new)
      esc.render
      box = esc.box.not_nil!
      esc.double_click(box.x + 4, box.bottom - 1).should be_false # the border row: no row there
      esc.open?.should be_true                                    # …and inside the box, so no dismiss
    end
  end
end

describe "EnvOverlay double-click" do
  it "opens the row's editor and stays up" do
    with_env("$", [{"ALPHA", "1"}, {"BETA", "2"}]) do
      ov = EnvOverlay.new
      h = OverlayHarness.new(ov)
      h.render
      x, y = row_cell(h) { |box, mx, my| ov.row_at(box, mx, my) == 1 ? 1 : nil }
      h.click(x, y)
      h.double_click(x, y).should be_true
      h.open?.should be_true
      ov.adding?.should be_true
      ov.text_fields.first.value.should eq("BETA 2")
    end
  end
end

describe "AuthorizeIdentitiesOverlay double-click" do
  it "arms an edit of the row and closes, leaving the form to the shell" do
    ids = [Identity.as_captured("as-captured"), Identity.new("admin", set_headers: [{"Cookie", "s=1"}])]
    ov = AuthorizeIdentitiesOverlay.new(ids)
    h = OverlayHarness.new(ov)
    h.render
    x, y = row_cell(h) { |box, mx, my| ov.row_at(box, mx, my) == 1 ? 1 : nil }
    h.click(x, y)
    h.double_click(x, y).should be_true
    h.open?.should be_false
    ov.pending.not_nil!.index.should eq(1)
  end

  it "passes off every row" do
    ov = AuthorizeIdentitiesOverlay.new([Identity.as_captured("as-captured")])
    h = OverlayHarness.new(ov)
    h.render
    box = h.box.not_nil!
    h.double_click(box.x + 4, box.y).should be_false # the title border: no row
    h.open?.should be_true
    ov.pending.should be_nil
  end
end

describe "ColumnsOverlay double-click" do
  it "arms an edit of the row and closes, leaving the form to the shell" do
    cols = [
      Gori::Store::DisplayColumn.new(1_i64, 0, "uid", Gori::MessageSide::Response, Gori::ExtractKind::Regex, "uid=(\\d+)"),
      Gori::Store::DisplayColumn.new(2_i64, 1, "role", Gori::MessageSide::Response, Gori::ExtractKind::Regex, "role=(\\w+)"),
    ]
    ov = ColumnsOverlay.new(cols)
    h = OverlayHarness.new(ov)
    h.render
    x, y = row_cell(h) { |box, mx, my| ov.row_at(box, mx, my) == 1 ? 1 : nil }
    h.click(x, y)
    h.double_click(x, y).should be_true
    h.open?.should be_false
    ov.pending.not_nil!.index.should eq(1)
  end
end
