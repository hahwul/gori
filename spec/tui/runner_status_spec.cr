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
