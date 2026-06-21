require "../spec_helper"
require "../support/memory_backend"
require "../support/fake_context"

include Gori::Tui

describe Gori::Tui::CommandLine do
  it "lists ONLY the focused area's own verbs — app control (Global) stays in Ctrl-P" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64 # flow-gated Body actions available
    cmd = CommandLine.new(Gori::Verbs.registry)
    cmd.open(Gori::Verb::Scope::Body, ctx)

    cmd.results.size.should be > 0
    cmd.results.all?(&.scope.body?).should be_true         # strictly scope-local
    cmd.results.map(&.id).should contain("history.replay") # an area action
    cmd.results.map(&.id).should_not contain("app.quit")   # NOT the app-control surface
  end

  it "filters by a fuzzy query and exposes the selected verb" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    cmd = CommandLine.new(Gori::Verbs.registry)
    cmd.open(Gori::Verb::Scope::Body, ctx)
    "replay".each_char { |c| cmd.append(c, ctx) }
    cmd.selected_verb.try(&.id).should eq("history.replay")
  end

  it "moves the selection within results (clamped)" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    cmd = CommandLine.new(Gori::Verbs.registry)
    cmd.open(Gori::Verb::Scope::Body, ctx)
    cmd.move(-5)
    cmd.selected.should eq(0)
  end

  it "renders the ':' input on the status row with a suggestion stacked above" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    cmd = CommandLine.new(Gori::Verbs.registry)
    cmd.open(Gori::Verb::Scope::Body, ctx)
    "replay".each_char { |c| cmd.append(c, ctx) }

    backend = MemoryBackend.new(80, 24)
    cmd.render(Screen.new(backend), Rect.new(0, 23, 80, 1), Rect.new(0, 3, 80, 20))
    backend.contains?("replay").should be_true      # the typed query on the status row
    backend.contains?("Replay flow").should be_true # the matched verb title in the list
  end
end
