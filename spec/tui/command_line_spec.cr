require "../spec_helper"
require "../support/memory_backend"
require "../support/fake_context"

include Gori::Tui

describe Gori::Tui::CommandLine do
  it "lists only the current scope's verbs plus Global, runnable via the registry (P1)" do
    ctx = FakeExecContext.new
    cmd = CommandLine.new(Gori::Verbs.registry)
    cmd.open(Gori::Verb::Scope::Body, ctx)

    cmd.results.size.should be > 0
    cmd.results.all? { |v| v.scope.body? || v.scope.global? }.should be_true
    cmd.results.map(&.id).should contain("app.quit")                      # Global is always offered
    cmd.results.map(&.id).any?(&.starts_with?("replay.")).should be_false # out-of-scope excluded
  end

  it "filters by a fuzzy query and exposes the selected verb" do
    ctx = FakeExecContext.new
    cmd = CommandLine.new(Gori::Verbs.registry)
    cmd.open(Gori::Verb::Scope::Global, ctx)
    "quit".each_char { |c| cmd.append(c, ctx) }
    cmd.selected_verb.try(&.id).should eq("app.quit")
  end

  it "moves the selection within results (clamped)" do
    ctx = FakeExecContext.new
    cmd = CommandLine.new(Gori::Verbs.registry)
    cmd.open(Gori::Verb::Scope::Body, ctx)
    cmd.move(-5)
    cmd.selected.should eq(0)
  end

  it "renders the ':' input on the status row with a suggestion stacked above" do
    ctx = FakeExecContext.new
    cmd = CommandLine.new(Gori::Verbs.registry)
    cmd.open(Gori::Verb::Scope::Global, ctx)
    "quit".each_char { |c| cmd.append(c, ctx) }

    backend = MemoryBackend.new(80, 24)
    cmd.render(Screen.new(backend), Rect.new(0, 23, 80, 1), Rect.new(0, 3, 80, 20))
    backend.contains?("quit").should be_true      # the typed query on the status row
    backend.contains?("Quit gori").should be_true # the matched verb title in the list
  end
end
