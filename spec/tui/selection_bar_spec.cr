require "../spec_helper"

# The `▎` selection bar is the one glyph that has to read identically in every list gori
# draws, because it answers the same question everywhere: you are here.
#
# Two lists had given it a second job. The Listeners overlay tinted it by the row's
# status (red/green/muted) and the Passthrough overlay painted it `Theme.yellow` — so the
# marker changed colour between two modals an operator opens from the same menu. Neither
# tint carried information the row did not already state in words, and the status one could
# not even be read: the glyph is drawn only on the SELECTED row (the rest get a space, where
# a foreground colour renders nothing), so it coloured exactly one row at a time.
describe "the ▎ selection bar" do
  it "is drawn in Theme.accent by every list" do
    root = File.join(__DIR__, "..", "..", "src", "gori", "tui")
    offenders = [] of String
    glob_files(root, "**", "*.cr").sort.each do |path|
      File.read(path).lines.each_with_index do |line, i|
        # The selection-bar idiom specifically: glyph-or-space on a per-row flag, which is
        # what makes the cell a MARKER COLUMN the list owns on every row. A bare `'▎'` is a
        # different device — the Fuzzer draws one in `Theme.marker_hue` beside a `→N` chip to
        # tie a row to its payload marker, and that one is meant to carry a colour.
        next unless line.includes?("? '▎' : ' '")
        next unless line.includes?("screen.cell")
        # `pal.accent` is the wizard's THEME PREVIEW, which paints a sample row in the palette
        # being previewed rather than the one in force. It is the only legitimate exception:
        # drawing that row in the active theme would defeat the preview.
        next if line.includes?("pal.accent")
        next if line.includes?("Theme.accent")
        offenders << "#{File.basename(path)}:#{i + 1}"
      end
    end
    offenders.should be_empty
  end
end
