require "../../spec_helper"
require "../../support/mcp_harness"

private RESULT = %({"data":{"__schema":{"queryType":{"name":"Query"},"types":[{"kind":"OBJECT",) +
                 %("name":"Query","fields":[{"name":"me","args":[],"type":{"kind":"SCALAR","name":"String"}}]}]}}})

describe "gori run graphql schema --format json" do
  it "prints the keys MCP graphql_schema answers with for a captured result" do
    with_store do |store|
      id = mcp_seed_flow(store, "api.test", "POST", "/graphql", 200, resp_body: RESULT.to_slice)
      mcp = JSON.parse(tools_for(store).call("graphql_schema", JSON.parse(%({"flow_id":#{id}}))).text)
      summary = Gori::Graphql::Schema.summarize(Gori::Graphql::Schema.parse(nil, RESULT.to_slice).as(JSON::Any))
      cli = JSON.parse(Gori::CLI::Run.graphql_schema_json(id, false, nil, summary))
      cli.as_h.keys.should eq(mcp.as_h.keys)
      cli.should eq(mcp)
    end
  end
end
