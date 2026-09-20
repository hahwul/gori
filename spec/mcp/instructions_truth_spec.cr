require "../spec_helper"
require "../support/mcp_harness"

# `instructions` is the first thing the model reads, and it is read as FACT. A sentence that
# names a tool `tools/list` does not carry sends the agent to call something that answers
# "unknown tool" — and under `--tools` this text used to do exactly that, starting with its
# very first instruction ("Call ql_reference before writing queries") on a server that
# advertised no ql_reference.
#
# The mechanism was already here: the operator-messages note asked `advertises?`. It simply
# never reached the rest of the text.

# Every tool name the instructions can spell. A name added to the prose without being added
# here is not checked, so keep the two together — that is what this file is for.
private NAMEABLE = %w[
  send_request send_websocket create_issue update_issue create_rule delete_rule
  set_rule_enabled switch_project create_project delete_project list_projects
  operator_messages reply_to_operator ql_reference list_history list_sitemap
  project_info decode jwt_decode
]

private def instructions_under(store, spec : String?, allow_actions = true) : {String, Set(String)}
  filter = spec.try { |sp| Gori::MCP::ToolFilter.parse(sp, Gori::MCP::Tools::TOOL_NAMES) }
  filter.should_not be_a(String) if spec
  input = IO::Memory.new(
    %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}) + "\n" +
    %({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}) + "\n")
  output = IO::Memory.new
  Gori::MCP::Server.new(store, allow_actions: allow_actions, verify_upstream: false,
    tool_filter: filter.as(Gori::MCP::ToolFilter?), input: input, output: output).run
  lines = output.to_s.each_line.reject(&.strip.empty?).map { |l| JSON.parse(l) }.to_a
  text = lines.find { |l| l["id"]? == 1 }.not_nil!["result"]["instructions"].as_s
  names = lines.find { |l| l["id"]? == 2 }.not_nil!["result"]["tools"].as_a.map(&.["name"].as_s).to_set
  {text, names}
end

# A tool name in the prose, as a whole word — `decode` must not match `encode/decode/hash`
# prose describing a tool that is gone, which is the shape of the last leak found.
private def named_in(text : String) : Set(String)
  NAMEABLE.select { |n| text.matches?(/\b#{Regex.escape(n)}\b/) }.to_set
end

describe "MCP instructions truthfulness" do
  it "never names a tool the server does not advertise, under any filter" do
    with_store do |store|
      # `list_*,operator_messages` is in the set because the operator-messages paragraph names
      # TWO tools and was admitted on one of them — a filter that keeps the poll tool and not
      # the reply tool is the shape that catches it.
      {nil, "*", "list_*", "get_*,decode", "ql_*", "send_request", "-fuzz_*,-mine_*",
       "list_*,operator_messages", "reply_to_operator,get_*"}.each do |spec|
        text, names = instructions_under(store, spec)
        leaked = named_in(text) - names
        leaked.should be_empty, "--tools=#{spec.inspect} instructions name #{leaked.to_a.sort.join(", ")}, which tools/list does not carry"
      end
    end
  end

  # `--read-only` and `--tools` remove a tool for different reasons, and only one of them is
  # reversible. The read-only sentence exists to name what restarting would restore, so it
  # NAMES tools that `tools/list` does not carry — legitimately. What it must not name is a
  # tool the FILTER removed, which no restart brings back.
  it "under --read-only names only what lifting the gate would restore" do
    with_store do |store|
      text, _ = instructions_under(store, nil, allow_actions: false)
      text.should contain("Read-only mode")
      text.should contain("send_request")

      narrowed, listed = instructions_under(store, "list_*", allow_actions: false)
      named_in(narrowed).should_not contain("send_request")
      (named_in(narrowed) - listed).should be_empty
    end
  end

  # …and every OTHER sentence is held to the same rule as under `--tools`, which is where
  # this leaked: "Projects can be managed via …, delete_project" went out to every read-only
  # server, offering a gated tool that is neither listed nor runnable. The read-only sentence
  # is the ONE allowed to name an absent tool, so it is subtracted by name rather than by
  # trusting the whole paragraph.
  it "names no gated tool outside the sentence that exists to name them" do
    with_store do |store|
      text, listed = instructions_under(store, nil, allow_actions: false)
      restored = text.split("Read-only mode:")[1]?.try(&.split(". ").first) || ""
      leaked = named_in(text) - listed - named_in(restored)
      leaked.should be_empty, "read-only instructions name #{leaked.to_a.sort.join(", ")}, which tools/list does not carry"
      listed.should_not contain("delete_project")
    end
  end

  # The backstop for a name added to the prose later without this treatment: when the
  # catalogue was narrowed on purpose, say so and name the authority.
  it "says the surface was narrowed, and points at tools/list" do
    with_store do |store|
      text, _ = instructions_under(store, "list_*")
      text.should contain("--tools=")
      text.should contain("tools/list is the authority")
      instructions_under(store, nil)[0].should_not contain("tools/list is the authority")
    end
  end

  # The unfiltered text is the one every ordinary install gets: it must still carry the
  # things the agent is expected to act on.
  it "keeps the full guidance when nothing is filtered" do
    with_store do |store|
      text, _ = instructions_under(store, nil)
      text.should contain("ql_reference")
      text.should contain("SCOPE_BLOCKED")
      text.should contain("project_info")
      text.should contain("operator_messages")
    end
  end
end
