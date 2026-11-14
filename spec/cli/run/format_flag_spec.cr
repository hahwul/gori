require "../../spec_helper"

# `--json` is the alias for `--format=json` on EVERY `gori run` command that takes `--format`
# and offers `json` (#1386). It existed on `notify` alone, so `project list --json` was an
# unknown option. The alias is registered by `format_flag`, so the gate is that no parser
# registers `--format` any other way: a new command copying a bare `p.on("--format=…")` from
# an older neighbour would drop the alias silently, which is how the gap arose.
module Gori::CLI::Run
  def self.format_flag_for_spec(args : Array(String), allowed : Array(Symbol)) : Symbol
    format = :text
    parser = OptionParser.new do |p|
      format_flag(p, allowed, "Output") { |f| format = f }
      p.invalid_option { |f| raise "unknown option: #{f}" }
    end
    parser.parse(args)
    format
  end
end

# `sitemap export` offers no `json`/`text` pair (openapi | openapi-yaml), so there is nothing for
# `--json` to alias there.
private FORMAT_FLAG_EXEMPT = {"sitemap_export.cr"}

describe "gori run --format / --json (#1386)" do
  it "takes --json for --format=json, and still takes --format" do
    Gori::CLI::Run.format_flag_for_spec(["--json"], [:text, :json]).should eq(:json)
    Gori::CLI::Run.format_flag_for_spec(["--format", "jsonl"], [:text, :json, :jsonl]).should eq(:jsonl)
    Gori::CLI::Run.format_flag_for_spec([] of String, [:text, :json]).should eq(:text)
    Gori::CLI::Run.format_flag_for_spec(["--format", "csrf-poc"], [:text, :csrf]).should eq(:csrf)
    Gori::CLI::Run.format_flag_for_spec(["--format", "csrf_poc"], [:text, :csrf]).should eq(:csrf)
    Gori::CLI::Run.format_flag_for_spec(["--format", "md"], [:text, :markdown]).should eq(:markdown)
  end

  # A refusal raised where no `format` is in reach (`open_store`, `busy_abort`) reads this.
  it "remembers whether the invocation asked for JSON on stdout, last flag winning" do
    Gori::CLI::Run.format_flag_for_spec(["--json"], [:text, :json])
    Gori::CLI::Run.json_stdout?.should be_true
    Gori::CLI::Run.format_flag_for_spec(["--json", "--format", "text"], [:text, :json])
    Gori::CLI::Run.json_stdout?.should be_false
    Gori::CLI::Run.format_flag_for_spec(["--format", "jsonl"], [:text, :jsonl])
    Gori::CLI::Run.json_stdout?.should be_true
    Gori::CLI::Run.json_stdout = false
  end

  it "registers no --json where --format offers no json" do
    expect_raises(Exception, "unknown option: --json") do
      Gori::CLI::Run.format_flag_for_spec(["--json"], [:text, :paths])
    end
  end

  it "registers --format only through format_flag, so every such command also takes --json" do
    root = File.join(__DIR__, "..", "..", "..", "src", "gori", "cli")
    bare = [] of String
    glob_files(root, "**", "*.cr").sort.each do |path|
      next if FORMAT_FLAG_EXEMPT.includes?(File.basename(path))
      File.read_lines(path).each_with_index do |line, i|
        next if line.lstrip.starts_with?('#')
        next if line.includes?("pick.call(parse_format(v, allowed, refused))") # `format_flag` itself
        bare << "#{path.sub(root, "src/gori/cli")}:#{i + 1}" if line.includes?(".on(\"--format")
      end
    end
    bare.should eq([] of String)
  end

  # `--format raw` is `show`'s alone; a sender's refusal names the way there (`RAW_ROUTE`).
  it "points a sender's refused --format raw at show" do
    Gori::CLI::Run::RAW_ROUTE.should contain("--record-history")
    Gori::CLI::Run::RAW_ROUTE.should contain("gori run show <flow-id> --format raw")
    root = File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run")
    File.read(File.join(root, "send.cr")).scan("{:raw, RAW_ROUTE}").size.should eq(1)
    File.read(File.join(root, "repeater.cr")).scan("{:raw, RAW_ROUTE}").size.should eq(2) # <flow-id>, send
  end
end
