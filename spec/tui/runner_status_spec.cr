require "../spec_helper"

include Gori::Tui

# The status strip's spinner / ✓ / ✗ rides the KIND a producer passed to `status(message, kind)`,
# not a prefix of the message text (see `Runner#format_status_message`). `Runner.new` owns a
# terminal, so the rule is pinned through the pure class method the instance defers to.
describe "Runner.decorate_status" do
  spinner = "⣾"

  it "decorates the message the kind was set with" do
    Runner.decorate_status("fuzzer error: boom", {"fuzzer error: boom", :error}, spinner).should eq("✗ fuzzer error: boom")
    Runner.decorate_status("sent → 200 in 12ms", {"sent → 200 in 12ms", :done}, spinner).should eq("✓ sent → 200 in 12ms")
    Runner.decorate_status("stopping…", {"stopping…", :busy}, spinner).should eq("⣾ stopping…")
  end

  it "leaves a toast that never named a kind plain, even after a kinded one" do
    # 239 sites write `@toast = …` directly. The kind is keyed to its own message, so the
    # next plain toast does not inherit the previous glyph.
    kinded = {"fuzzer error: boom", :error}
    Runner.decorate_status("screen refreshed", kinded, spinner).should eq("screen refreshed")
    Runner.decorate_status("screen refreshed", nil, spinner).should eq("screen refreshed")
  end

  it "does not depend on the wording — a translated error still earns its mark" do
    Runner.decorate_status("퍼저 오류: boom", {"퍼저 오류: boom", :error}, spinner).should eq("✗ 퍼저 오류: boom")
  end

  it "treats an unknown kind as plain rather than raising on the render path" do
    Runner.decorate_status("x", {"x", :sparkly}, spinner).should eq("x")
  end
end

# A request Intercept holds while another tab is up makes the client look hung; the first one
# is toasted once, and not again until the operator has opened Intercept or turned it off —
# a queue an agent empties and refills must not toast on every refill.
describe "Runner.first_hold?" do
  it "fires once for a hold, off the Intercept tab only" do
    Runner.first_hold?(false, 1, :history).should be_true
    Runner.first_hold?(false, 2, :fuzzer).should be_true  # two in one tick: still one toast
    Runner.first_hold?(true, 1, :history).should be_false # already said; a refill is not news
    Runner.first_hold?(false, 1, :intercept).should be_false
    Runner.first_hold?(false, 0, :history).should be_false
    src = File.read("src/gori/tui/runner.cr")
    src.should contain("@hold_announced = false if @active_tab == :intercept || !@session.interceptor.enabled?")
  end

  it "names the first held message and fits 80×24's 59 columns" do
    Runner.first_hold_toast(Gori::Interceptor::Kind::Request)
      .should eq("intercept holding a request (go to Intercept to forward)")
    Gori::Interceptor::Kind.values.each do |kind|
      Runner.first_hold_toast(kind).size.should be <= 59
    end
  end
end

# A bare `@toast =` never stamped `@toast_at`, so the greeting bubble hid it for 8 s (L#1).
# `status_line` now stamps a toast it has not drawn before.
describe "Runner.toast_stamp" do
  t0 = Time.instant
  t1 = t0 + 1.second

  it "stamps a toast the row has not seen" do
    Runner.toast_stamp("port 8070 in use", nil, nil, t1).should eq(t1)
    Runner.toast_stamp("new", "old", t0, t1).should eq(t1)
  end

  it "keeps the stamp of a toast it already drew, or one `status` stamped" do
    msg = "imported 3 flows"
    Runner.toast_stamp(msg, msg, t0, t1).should eq(t0)
  end

  it "leaves the stamp alone when there is no toast" do
    Runner.toast_stamp(nil, "old", t0, t1).should eq(t0)
  end
end

# A capture that did not start names its cause; the lock FILE failing is not another window (W#9).
describe "Runner.bind_error_line" do
  it "blames permissions, not a phantom instance, when the lock file could not be created" do
    line = Runner.bind_error_line("Permission denied", false, true, "/p/demo")
    line.should start_with("capture OFF — cannot create the capture lock")
    line.should contain("/p/demo")
    line.should_not contain("take over")
    # A long project path is the detail 80×24 drops, never the outcome.
    long = Runner.bind_error_line("Permission denied", false, true, "/Users/someone/Projects/#{"x" * 40}")
    Chrome.fit_hints(long, 59).should eq("capture OFF — cannot create the capture lock …")
  end

  it "keeps the view-only and port wording for the other two causes" do
    Runner.bind_error_line("another gori instance already holds this database's capture lock", false, false, "/p")
      .should start_with("view-only — ")
    Runner.bind_error_line("Address in use", true, false, "/p").should contain("set a free port")
  end
end

describe "Runner.orphaned_line" do
  it "says how many in-flight flows the last session left, cause first" do
    Runner.orphaned_line(5).should start_with("5 flows left incomplete by the last session")
    Runner.orphaned_line(1).should start_with("1 flow left incomplete by the last session")
    # 80×24's 59 toast columns keep the outcome; the cause is the segment that drops.
    Chrome.fit_hints(Runner.orphaned_line(9999), 59).should eq("9999 flows left incomplete by the last session …")
  end
end

# The import's warning rode AFTER ` · path`, so `fit_hints` dropped it with the path and a
# duplicate import read exactly like the first (W#1).
describe "Runner.import_done_line" do
  dup = "50 flows are already in this project from an earlier import of a file named \"s.har\""

  it "keeps a warning ahead of the path, so the row's segment cut leaves it" do
    msg, warned = Runner.import_done_line(Gori::Import::Result.new(50, notes: [dup]), "HAR", "/tmp/s.har", false)
    warned.should be_true
    msg.should eq("imported 50 flows from HAR — #{dup} · /tmp/s.har")
    Chrome.fit_hints(msg, 59).should start_with("imported 50 flows from HAR — 50 flows are already")
  end

  it "names a partial write first too" do
    msg, warned = Runner.import_done_line(Gori::Import::Result.new(8, attempted: 10), "HAR", "/tmp/s.har", false)
    warned.should be_true
    msg.should start_with("imported 8 flows from HAR — 2 of 10 did NOT commit")
  end

  it "is a plain success line, with no ring push, when there is nothing to warn about" do
    Runner.import_done_line(Gori::Import::Result.new(3), "HAR", "/tmp/s.har", false)
      .should eq({"imported 3 flows from HAR · /tmp/s.har", false})
  end
end

# While the strip's `/` bar takes keys its letters type, so the footer must not keep
# advertising `e rename · t mark · f find` (L#6). `Runner.new` owns a terminal, so the order of
# the checks is pinned on the source, comments stripped (they name the tokens looked for).
describe "the sub-tab strip footer while its filter is being typed" do
  src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner.cr"))
    .lines.reject(&.lstrip.starts_with?('#'))

  it "answers with the filter's editing hint before any strip hint" do
    at = src.index(&.includes?("if @focus == :subtabs")).not_nil!
    src[at + 1].should contain("return SUBTAB_FILTER_HINT if")
    src[at + 1].should contain("subtab_filter_editing?")
  end

  it "fits the 80×24 row and names only what the bar answers" do
    Runner::SUBTAB_FILTER_HINT.should eq("type to filter · ↹ complete · ↵ apply · esc clear")
    Screen.display_width(Runner::SUBTAB_FILTER_HINT).should be <= 59
  end
end
