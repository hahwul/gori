require "../spec_helper"

# How a confirm dialog is DRESSED, which had split into two conventions.
#
# `ConfirmDialog` renders both strings verbatim — the heading through `Frame.card`, the
# button through `render_button` — so the two spellings really did reach the screen. Eleven
# dialogs shouted an uppercase noun over a lowercase button (`DELETE ISSUE` / `delete`),
# matching every card title in gori; six newer ones used sentence case with a capitalised
# button (`Delete rule` / `Delete`), which also put a `Delete` next to the `cancel` that
# `ConfirmDialog` supplies by default — mixed case inside one dialog.
#
# The rule: the heading names the subject in caps, the buttons are lowercase verbs.
describe "confirm dialog wording" do
  root = File.join(__DIR__, "..", "..", "src", "gori", "tui")

  it "gives every dialog an UPPERCASE heading" do
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      File.read(path).lines.each_with_index do |line, i|
        next unless m = line.match(/\bconfirm\((?:I18n\.ui\()?"([^"]+)"/)
        heading = m[1]
        # Interpolated headings are built at runtime; only literal prose is checkable here.
        next if heading.includes?("\#{")
        next if heading == heading.upcase
        offenders << "#{File.basename(path)}:#{i + 1} — #{heading}"
      end
    end
    offenders.should be_empty
  end

  it "gives every dialog lowercase button verbs" do
    # Both buttons, because the pair is what an operator reads at once: `confirm_label` is
    # per-site and `cancel_label` defaults to `cancel`, so a capitalised confirm verb is the
    # one that breaks the pair.
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      File.read(path).lines.each_with_index do |line, i|
        line.scan(/(?:confirm|cancel)_label: (?:I18n\.ui\()?"([^"]+)"/) do |m|
          label = m[1]
          next if label == label.downcase
          offenders << "#{File.basename(path)}:#{i + 1} — #{label}"
        end
      end
    end
    offenders.should be_empty
  end
end
