require "../../spec_helper"

# A dozen `gori run … delete` commands require `--yes` and fourteen others refused it as an
# unknown option, so a wrapper that always passes it broke on half of them. Every delete
# parser now takes it: required where it confirms, `yes_flag` (accepted, ignored) elsewhere.
# Read off the source, as `unknown_args_sweep_spec` is: the defect is an absence a new
# command copies from its neighbours.
describe "gori run — every delete accepts --yes" do
  it "registers --yes on each delete/rm/remove/forget parser" do
    root = File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run")
    opener = /(?:parse_args|one_positional_list|one_positional|option_parser|parse_no_positionals)\(\s*\w*,?\s*"gori run [^"]*\b(delete|rm|remove|forget)"/
    missing = [] of String
    seen = 0
    glob_files(root, "*.cr").sort.each do |path|
      lines = File.read_lines(path)
      lines.each_with_index do |line, i|
        next unless line =~ opener
        seen += 1
        window = lines[i, 12].join('\n')
        missing << "#{File.basename(path)}:#{i + 1}" unless window.includes?("--yes") || window.includes?("yes_flag(p)")
      end
    end
    seen.should be > 10
    missing.should eq([] of String)
  end
end
