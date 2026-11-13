require "../spec_helper"
require "../support/memory_backend"
require "../support/tui_probes"

include Gori::Tui

describe "Runner.scope_chip" do
  it "counts rules while the lens is on, in intercept's on/off form" do
    Runner.scope_chip(true, 3).should eq("scope:on(3)")
  end

  # The on form is three columns wider than the old `scope:N`; at 80 columns the bar must
  # still keep the state chips (it yields the project name, probe and rules first), and the
  # drawn chip must still be the one a click resolves to.
  it "keeps scope, intercept, sandbox and listen at 80 columns, and the chip still clicks" do
    rect = Rect.new(0, 0, 80, 1)
    backend = MemoryBackend.new(80, 1)
    args = {scope: Runner.scope_chip(true, 7), probe: "probe:passive", rules: "rules:2",
            intercept: "intercept:on(0)", sandbox: "sandbox", listen: "localhost:18982"}
    Chrome.render_top_bar(Screen.new(backend), rect, **args, project: "demo")
    row = backend.row(0)
    {"scope:on(7)", "intercept:on(0)", "sandbox", "localhost:18982"}.each { |c| row.should contain(c) }
    x = row.index("scope:on(7)").not_nil!
    backend.fg_at(x, 0).should eq(Theme.text) # on is not `:off`-muted
    # Both ends of the drawn text resolve to the scope chip.
    {x, x + "scope:on(7)".size - 1}.each do |mx|
      Chrome.top_bar_chip_at(rect, mx, 0, **args, project: "demo").should eq(:scope)
    end
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
