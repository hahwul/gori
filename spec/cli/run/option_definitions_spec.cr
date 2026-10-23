require "../../spec_helper"

# Two flag-definition shapes that compile, print in `--help`, and then misbehave on every run.
# Asserted over the SOURCE, like the missing_option guard beside this file, because a new
# subcommand reintroduces them by copying a neighbour.
describe "gori run — option definitions" do
  lines = glob_files(File.join(__DIR__, "..", "..", "..", "src", "gori", "cli"), "**", "*.cr").sort.flat_map do |path|
    File.read_lines(path).map_with_index { |l, i| {"#{path}:#{i + 1}", l} }
  end

  # `OptionParser` splits a definition at its LAST `=` (a greedy `\S+`), so
  # `"--grpc-field=PATH=VALUE"` registered a flag named `--grpc-field=PATH`, which no argv can
  # spell: `--grpc-field` and `--auto-reply` were "unknown option" on every command.
  it "never puts a second = in a long flag's =VALUE definition" do
    offenders = lines.select { |_, l| l =~ /\bon\("--[\w-]+=[^"\s]*=/ }.map(&.first)
    offenders.should be_empty
  end

  # A repeated `-q` kept only the last in silence: `history delete -q A -q B` deleted B's matches.
  it "refuses a repeated -q/--query on every command that takes one" do
    offenders = lines.select { |_, l| l.includes?(%("--query=QL")) && !l.includes?("once(") }.map(&.first)
    offenders.should be_empty
  end
end
