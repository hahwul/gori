require "../spec_helper"

# `Frame.mode_badge`'s doc-comment states the rule in its own words: "`insert` must be the
# pane's REAL mode — never `focused && insert?`." It says why, too — the two labels are
# different WIDTHS (` ↵:READ ` is 8 cells, ` INS ` is 5), and every caller's hit-test passes
# the bare mode, because a click handler has no idea which pane had focus when the frame was
# drawn. Gate the draw on focus and the two geometries stop describing the same rectangle.
#
# Two callers broke it anyway, and the Issues one broke it in the worst available way: in
# insert-but-unfocused NOTHING was painted on the border while the controller went on
# hit-testing a five-cell INS rect, so clicking blank border cells turned insert off. Nothing
# exits insert on a focus change, so that state is ordinary rather than exotic.
#
# The rule is checkable in source and cheap to check, which is the whole reason to: a comment
# that has already been ignored twice is not a guard.
describe "Frame.mode_badge callers" do
  it "pass the pane's real mode, never a focus-gated one" do
    root = File.join(__DIR__, "..", "..", "src", "gori", "tui")
    offenders = [] of String
    glob_files(root, "**", "*.cr").sort.each do |path|
      next if File.basename(path) == "frame.cr"
      src = File.read(path)
      src.lines.each_with_index do |line, i|
        next unless line.includes?("Frame.mode_badge(")
        # The mode is the last argument. A `focused && …` there is the exact shape the
        # contract forbids; so is a local whose own definition ANDs focus in, which is how
        # all three of these were written (`ins = focused && insert_mode?`).
        #
        # Strip the trailing comment FIRST: the Repeater's call carries the words
        # "not focused&&mode — see Frame.mode_badge" after it, and splitting on the last comma
        # of the raw line took the comment's tail for the argument. And match `focused` as a
        # WORD — the Fuzzer passes `template_insert? || @chain_focused`, which is a different
        # flag whose name merely ends in it.
        code = line.split('#')[0]
        arg = code.rpartition(',')[2].strip.rstrip(')')
        bad = arg.matches?(/(^|[^a-z_])focused\b/) ||
              src.matches?(/\b#{Regex.escape(arg)}\s*=\s*focused\s*&&/)
        offenders << "#{File.basename(path)}:#{i + 1} — #{arg}" if bad
      end
    end
    offenders.should be_empty
  end

  it "draw the badge unconditionally, so the hit rect is never on a blank border" do
    # The second half of the same defect: `if focused` around the CALL leaves the controller's
    # hit-test live over cells with nothing drawn on them. A caller may of course return early
    # for a card too small to draw — that is `mode_badge`'s own `min_x` drop — but focus must
    # not decide whether the chip exists.
    root = File.join(__DIR__, "..", "..", "src", "gori", "tui")
    offenders = [] of String
    glob_files(root, "**", "*.cr").sort.each do |path|
      next if File.basename(path) == "frame.cr"
      lines = File.read(path).lines
      lines.each_with_index do |line, i|
        next unless line.includes?("Frame.mode_badge(")
        prev = lines[i - 1]?.try(&.strip) || ""
        offenders << "#{File.basename(path)}:#{i + 1}" if prev.matches?(/^if\s+.*\bfocused\b/)
      end
    end
    offenders.should be_empty
  end
end
