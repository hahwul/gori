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

# An agent that knows gori's MCP tool names guesses them as `gori run` subcommands
# (`gori run list_history`) and got a bare refusal: the near-typo suggestion only reaches edit
# distance 2. The refusal now names the CLI spelling of the MCP name, and only ever a command
# `gori run -h` lists.
describe "an MCP tool name as a gori run subcommand" do
  it "names the CLI command for the MCP names agents reach for" do
    {
      "list_history" => "history", "get_flow" => "show", "send_request" => "send",
      "export_openapi" => "sitemap export", "list_params" => "sitemap params",
      "race_requests" => "repeater race", "timing_requests" => "repeater timing",
      "run_retest" => "retest run", "create_repeater" => "repeater create",
      "list_issues" => "issues", "get_issue" => "issues show", "probe_scan" => "probe",
      "probe_issues" => "probe issues", "fuzz_start" => "fuzz", "list_sitemap" => "sitemap",
      "switch_project" => "project switch", "import_project" => "project import",
      "list_session_slots" => "session", "create_rule" => "rewriter",
      "create_color_rule" => "colormarker", "add_scope_rule" => "project scope",
      "list_host_overrides" => "project host-override", "cache_deception_check" => "cache-deception",
      "graphql_schema" => "graphql schema", "list_probe_rules" => "probe rules",
      "get_repeater_context" => "repeater show",
    }.each do |tool, path|
      {tool, tool.tr("_", "-"), tool.upcase}.each do |word|
        Gori::CLI::Run.cli_spelling(word).should eq(path), failure_message: "#{word} → #{path}"
      end
    end
  end

  it "suggests only a listed command for every MCP tool, and nothing for one with no CLI side" do
    Gori::MCP::Tools::TOOL_NAMES.each do |tool|
      next unless path = Gori::CLI::Run.cli_spelling(tool)
      Gori::CLI::Run::COMMAND_PATHS.should contain(path)
      Gori::CLI::Run::SUBCOMMAND_NAMES.should contain(path.split.first)
    end
    Gori::CLI::Run::MCP_TOOL_PATHS.each_value { |path| Gori::CLI::Run::COMMAND_PATHS.should contain(path) }
    Gori::CLI::Run::MCP_NOUNS.each_value { |path| Gori::CLI::Run::COMMAND_PATHS.should contain(path) }
    %w[list_events ql_reference list_jobs get_current_context].each do |tool|
      Gori::CLI::Run.cli_spelling(tool).should be_nil
    end
  end

  it "says it in the one-line refusal, after the near-typo suggestion" do
    msg = Gori::CLI::Run.unknown_verb_message("gori run", "list-history", Gori::CLI::Run::SUBCOMMAND_NAMES)
    msg.should eq("gori run: unknown subcommand 'list-history' — the CLI spells that 'gori run history'\n" \
                  "Run 'gori run --help' for the list.")
    Gori::CLI::Run.unknown_verb_message("gori run repeater", "list_repeaters", %w[list show])
      .should start_with("gori run repeater: unknown subcommand 'list_repeaters' — the CLI spells that 'gori run repeater list'")
    # A subcommand's unknown verb is answered only with that subcommand's own verbs: `repeater
    # send-ws` is not the top-level `gori run send`.
    Gori::CLI::Run.unknown_verb_message("gori run repeater", "send-ws", %w[list show])
      .should eq("gori run repeater: unknown subcommand 'send-ws'\nRun 'gori run repeater --help' for the list.")
    Gori::CLI::Run.cli_spelling("send_request", "repeater").should be_nil
    # A bare word is a typo or another command's verb, never an MCP name.
    Gori::CLI::Run.cli_spelling("show").should be_nil
    Gori::CLI::Run.cli_spelling("--list_history").should be_nil
  end
end
