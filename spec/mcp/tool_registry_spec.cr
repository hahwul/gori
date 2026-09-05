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
# Every call below is made with EMPTY arguments. That is what keeps a sweep over 160 tools
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
      # read-only, as here, it is therefore both hidden from the listing and refused — the
      # one tool whose gate is decided by state rather than by its flag.
      self_gated = ["create_project"]
      runnable = Gori::MCP::Tools::TOOL_NAMES.reject { |n| Gori::MCP::Tools::GATED_TOOLS.includes?(n) }
      advertised(tools).sort.should eq((runnable - self_gated).sort)

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
    Gori::MCP::Tools::ENV_REFRESH_TOOLS.should eq(Set{"send_request", "send_websocket", "fuzz_start", "mine_start",
                                                      "sequence_start", "discover_start", "list_env", "set_env_var", "delete_env_var"})
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
    both.should eq(Set{"oast_start", "oast_stop", "delete_project"})
    safe_args = {
      "oast_start"     => %({"provider":"no-such-provider"}),
      "oast_stop"      => %({}),
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
