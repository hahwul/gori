require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

describe "Runner.scope_chip" do
  it "counts rules while the lens is on" do
    Runner.scope_chip(true, 3).should eq("scope:3")
  end

  it "tells rules waiting on the lens from no rules at all" do
    Runner.scope_chip(false, 2).should eq("scope:off(2)")
    Runner.scope_chip(false, 0).should eq("scope:off")
  end

  it "draws rules-but-off muted, like a bare scope:off" do
    rect = Rect.new(0, 0, 80, 1)
    backend = MemoryBackend.new(80, 1)
    Chrome.render_top_bar(Screen.new(backend), rect,
      project: "acme", listen: "127.0.0.1:8080", scope: "scope:off(2)")
    srect = Chrome.top_bar_chip_rect(rect, :scope, scope: "scope:off(2)",
      listen: "127.0.0.1:8080").not_nil!
    backend.row(0)[srect.x, srect.w].should eq("scope:off(2)")
    backend.fg_at(srect.x, 0).should eq(Theme.muted)
  end
end
