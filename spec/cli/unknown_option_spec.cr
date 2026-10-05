require "../spec_helper"

# #1389: an unknown option dumped the command's whole usage after the flag, and an unknown
# `gori run` subcommand printed the ~80-line help to STDOUT — into the pipe a script was
# reading. Both are now one refusal naming the typo, the nearest real name, and `--help`.
private def refusal_for(args : Array(String), with_unknown_args : Bool) : String
  message = ""
  parser = OptionParser.new do |p|
    p.on("--format=FMT", "Output") { }
    p.on("--project=NAME", "Project") { }
    p.on("-k", "--insecure-upstream", "TLS") { }
    p.unknown_args { |_, _| } if with_unknown_args
    p.invalid_option { |f| message = Gori::CLI.unknown_option_message("gori run demo", f, p) }
  end
  parser.parse(args)
  message
end

describe "unknown options and subcommands (#1389)" do
  it "names the nearest flag and --help, not the usage — with or without an unknown_args handler" do
    [true, false].each do |with_unknown_args|
      msg = refusal_for(["--fomat", "json"], with_unknown_args)
      msg.should eq("gori run demo: unknown option: --fomat — did you mean --format?\n" \
                    "Run 'gori run demo --help' for its options.")
      msg.should_not contain("Output") # the usage is not appended any more
    end
  end

  it "suggests nothing for a flag nowhere near one, or for a short flag" do
    refusal_for(["--zzzzzz"], false).should_not contain("did you mean")
    Gori::CLI.nearest_flag("-x", ["-k", "--insecure-upstream"]).should be_nil
    Gori::CLI.nearest_flag("--projct=a", ["--project"]).should eq("--project")
  end

  it "suggests the nearest subcommand" do
    msg = Gori::CLI::Run.unknown_verb_message("gori run", "histroy", ["history", "fuzz", "mine"])
    msg.should start_with("gori run: unknown subcommand 'histroy' — did you mean 'history'?")
    Gori::CLI::Run.nearest_name("zzz", ["history"]).should be_nil
    Gori::CLI::Run::SUBCOMMAND_NAMES.should contain("history")
  end

  # The class gate. A handler that interpolates the parser (`#{p}`) is the old whole-usage
  # dump; one that skips the helper loses the suggestion. New commands copy their neighbours.
  it "routes every invalid_option handler through CLI.unknown_option_message" do
    root = File.join(__DIR__, "..", "..", "src", "gori")
    stray = [] of String
    glob_files(root, "**", "*.cr").sort.each do |path|
      File.read_lines(path).each_with_index do |line, i|
        next if line.lstrip.starts_with?('#')
        next unless line.includes?(".invalid_option")
        stray << "#{path.sub(root, "src/gori")}:#{i + 1}" unless line.includes?("unknown_option_message(")
      end
    end
    stray.should eq([] of String)
  end
end
