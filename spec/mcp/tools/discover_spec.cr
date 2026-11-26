require "../../spec_helper"

module Gori::MCP
  class Tools
    def discover_timeout_plan_for_spec(h, ob : Gori::Outbound) : Gori::Discover::Plan
      build_discover_plan(h, ob)
    end
  end
end

private def discover_plan_timeout(store, timeout_arg : String) : Time::Span?
  args = %({"url":"http://127.0.0.1:9/","bruteforce":false#{timeout_arg}})
  tools_for(store).discover_timeout_plan_for_spec(JSON.parse(args), ungated_outbound).config.timeout
end

# discover_start read `timeout_ms` through a private reader with no ceiling, while every other
# MCP tool reads it through `fuzz_timeout` (1..600000 ms). Discover's stop only sets a flag, so
# an agent-chosen 1e19 left a stopped job `running` on a silent origin indefinitely. The plan
# is built only, nothing is sent.
describe "MCP discover_start timeout_ms" do
  [%("timeout_ms":1e19), %("timeout_ms":"99999999999999999999"),
   %("timeout_ms":9223372036854775807), %("timeout_ms":600001)].each do |arg|
    it "clamps #{arg} to the 600 s MCP ceiling on the plan the engine gets" do
      with_store { |store| discover_plan_timeout(store, ", #{arg}").should eq(10.minutes) }
    end
  end

  it "keeps the semantics below the ceiling" do
    with_store do |store|
      discover_plan_timeout(store, %(, "timeout_ms":2000)).should eq(2.seconds)
      discover_plan_timeout(store, %(, "timeout_ms":0)).should be_nil
      discover_plan_timeout(store, %(, "timeout_ms":-5)).should be_nil
      discover_plan_timeout(store, "").should be_nil
    end
  end
end
