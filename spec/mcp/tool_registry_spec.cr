require "../spec_helper"

# The tool registry is generated from the `@[Tool]` annotations on the handlers
# (src/gori/mcp/tool.cr, and the `macro finished` block in tools.cr). These examples pin
# the two contracts the generation is trusted for, by DRIVING every tool through the real
# `Tools#call` rather than by reading the constants back:
#
#   1. tools/list and the dispatcher name the same set — a tool an agent can see is one it
#      can call, and a tool it can call is one it was told about;
#   2. the flag on a handler is the gate the call actually meets — `gated:` is refused
#      under --read-only before the handler runs, and everything not `unbound:` is refused
#      with NO_PROJECT while no project is bound.
#
# Every call below is made with EMPTY arguments. That is what keeps a sweep over every tool
# safe: a gated tool is refused before its handler runs, an unbound-refused tool likewise,
# and a read tool handed nothing either lists an empty project or refuses the missing
# argument. It is also why the non-gated arm asserts "not INTERNAL": an empty argument
# hash is the operator's mistake, and `Tools#call` promises to code that INVALID_ARGUMENT
# (or a tool-specific NOT_FOUND), never as a server crash.

private def advertised(tools : Gori::MCP::Tools) : Array(String)
  JSON.parse(JSON.build { |j| tools.list(j) }).as_a.map(&.["name"].as_s)
end

private EMPTY_ARGS = JSON.parse("{}")

describe "MCP tool registry" do
  it "declares every tool name once" do
    names = Gori::MCP::Tools::TOOL_NAMES
    names.uniq.size.should eq(names.size)
    names.should_not be_empty
  end

  it "advertises exactly the tools it dispatches" do
    with_store do |store|
      tools = tools_for(store)
      listed = advertised(tools)
      listed.uniq.size.should eq(listed.size)
      listed.sort.should eq(Gori::MCP::Tools::TOOL_NAMES.sort)
    end
  end

  it "under --read-only advertises exactly the tools it will run, and refuses the rest before their handlers" do
    with_store do |store|
      tools = tools_for(store, allow_actions: false)
      # Project selection is not `gated:` because an install on a fresh machine needs it
      # under --read-only too: `switch_project` always runs, and `create_project` runs while
      # UNBOUND and self-gates once a project is bound (`create_project_entry`). Bound and
      # read-only, as here, it is therefore refused — but still ADVERTISED, which is the
      # deliberate part: the listing withheld it before, and a catalogue that loses a tool
      # when a client binds a project is one that "varies as a side effect of other requests
      # on the connection", which 2026-07-28 spells MUST NOT. The gate moved to the call; it
      # did not move to the listing.
      self_gated = ["create_project"]
      runnable = Gori::MCP::Tools::TOOL_NAMES.reject { |n| Gori::MCP::Tools::GATED_TOOLS.includes?(n) }
      advertised(tools).sort.should eq(runnable.sort)
      {"reply_to_operator", "oast_poll", "oast_payload"}.each do |name|
        Gori::MCP::Tools::GATED_TOOLS.should contain(name)
        advertised(tools).should_not contain(name)
      end
      # The unbound bootstrap exception is separate from action gating and stays listed.
      advertised(tools).should contain("create_project")

      Gori::MCP::Tools::TOOL_NAMES.each do |name|
        r = tools.call(name, EMPTY_ARGS)
        if Gori::MCP::Tools::GATED_TOOLS.includes?(name) || self_gated.includes?(name)
          r.error_code.should eq("TOOL_DISABLED"), "#{name} ran under --read-only"
        else
          r.error_code.should_not eq("TOOL_DISABLED"), "#{name} is a read tool but was refused as disabled"
          r.error_code.should_not eq("UNKNOWN_TOOL"), "#{name} is advertised but not dispatched"
          r.error_code.should_not eq("INTERNAL"), "#{name} crashed on empty arguments: #{r.text}"
        end
      end
    end
  end

  it "pins the flags the other examples cannot see through a call" do
    # The sets are generated from the same annotations the dispatcher is, so a flag typo
    # would make a set silently smaller and every example above still pass. Pin a member
    # of each set whose reason is written down: the send is the canonical agent action and
    # the canonical `$KEY` expander; `list_env` reports the env and so must re-read it;
    # `decode` is a pure tool and so needs no project.
    Gori::MCP::Tools::AGENT_ACTION_TOOLS.should contain("send_request")
    Gori::MCP::Tools::AGENT_ACTION_TOOLS.should_not contain("list_history")
    # `run_retest` joins the senders for the same reason they are here: a retest step replays
    # a Repeater session whose bytes may carry a `$KEY`, so the project's env has to be
    # re-read before the run rather than at whatever point this server last looked.
    # `minimize_repeater` for the same reason: every probe it sends is `Env.expand_wire`d.
    # `probe_scan` and `authorize_start` because the refresh also re-reads the session-slot
    # list their sends overlay and resolve bindings against (#1216).
    Gori::MCP::Tools::ENV_REFRESH_TOOLS.should eq(Set{"send_request", "send_websocket", "fuzz_start", "mine_start",
                                                      "sequence_start", "discover_start", "run_retest",
                                                      "minimize_repeater", "probe_scan", "authorize_start",
                                                      "list_env", "set_env_var", "delete_env_var"})
    Gori::MCP::Tools::UNBOUND_SAFE.should contain("decode")
    Gori::MCP::Tools::UNBOUND_SAFE.should_not contain("list_history")
    Gori::MCP::Tools::GATED_TOOLS.should contain("send_request")
    Gori::MCP::Tools::GATED_TOOLS.should_not contain("get_flow")
  end

  it "with no project bound and actions allowed, the tools flagged both unbound and gated reach their handlers" do
    # Under --read-only the next example refuses these before dispatch, so it proves nothing
    # about their handlers. With actions allowed the handler runs, and every one of the three
    # refuses its arguments before touching a network or a store: a provider that does not
    # exist, a session that was never started, a project with no name.
    tools = Gori::MCP::Tools.new(nil, allow_actions: true, verify_upstream: false)
    both = Gori::MCP::Tools::UNBOUND_SAFE & Gori::MCP::Tools::GATED_TOOLS
    both.should eq(Set{"oast_start", "oast_stop", "oast_poll", "oast_payload", "delete_project"})
    safe_args = {
      "oast_start"     => %({"provider":"no-such-provider"}),
      "oast_stop"      => %({}),
      "oast_poll"      => %({}),
      "oast_payload"   => %({}),
      "delete_project" => %({}),
    }
    both.each do |name|
      r = tools.call(name, JSON.parse(safe_args[name]))
      r.error_code.should_not eq("NO_PROJECT"), "#{name} is flagged unbound but asked for a project"
      r.error_code.should_not eq("TOOL_DISABLED"), "#{name} was refused with actions allowed"
      r.error_code.should_not eq("INTERNAL"), "#{name} crashed: #{r.text}"
    end
  end

  it "with no project bound answers only the tools flagged unbound, and refuses every other one with NO_PROJECT" do
    tools = Gori::MCP::Tools.new(nil, allow_actions: false, verify_upstream: false)
    Gori::MCP::Tools::TOOL_NAMES.each do |name|
      r = tools.call(name, EMPTY_ARGS)
      if Gori::MCP::Tools::UNBOUND_SAFE.includes?(name)
        r.error_code.should_not eq("NO_PROJECT"), "#{name} is flagged unbound but asked for a project"
        r.error_code.should_not eq("UNKNOWN_TOOL"), "#{name} is flagged unbound but not dispatched"
      else
        r.error_code.should eq("NO_PROJECT"), "#{name} reached its handler with no project bound"
      end
    end
  end
end

# The third contract the generation carries: `annotations.readOnlyHint`, which is what an
# MCP client reads to decide whether a call needs the human. It defaults to `!gated` — the
# same declaration `--read-only` enforces, so the hint and the gate cannot drift — and the
# `read_only:` flag spells the two populations where they disagree (mcp/tool.cr).
describe "MCP tool annotations" do
  it "hints read-only on the tools that neither mutate nor dial, and on no others" do
    with_store do |store|
      listed = JSON.parse(JSON.build { |j| tools_for(store).list(j) }).as_a
      by_name = listed.to_h { |t| {t["name"].as_s, t} }

      {"list_history", "get_flow", "ql_reference", "fuzz_status", "list_jobs"}.each do |name|
        by_name[name]["annotations"]["readOnlyHint"].as_bool.should be_true
        # A read tool answers from this project's store and never dials.
        by_name[name]["annotations"]["openWorldHint"].as_bool.should be_false
      end

      # Tools that mutate, may send, or require the action-enabled surface all need the
      # conservative false hint even though some are gated at dispatch.
      {"send_request", "create_issue", "probe_scan", "oast_poll", "oast_payload",
       "switch_project", "reply_to_operator"}.each do |name|
        by_name[name]["annotations"]["readOnlyHint"].as_bool.should be_false
        # Left unstated, so the spec's conservative default (true) stands: an action tool
        # may or may not reach the network, and the population that does includes the fuzzer.
        by_name[name]["annotations"]["openWorldHint"]?.should be_nil
      end

      listed.each { |t| t["annotations"]["readOnlyHint"].raw.should be_a(Bool) }
    end
  end

  # An agent action is by definition a mutation or an outbound send. The macro refuses the
  # combination on the declaration; this is the same statement read off the built sets.
  it "never calls an agent action read-only" do
    (Gori::MCP::Tools::READ_ONLY_TOOLS & Gori::MCP::Tools::AGENT_ACTION_TOOLS).should be_empty
  end
end
