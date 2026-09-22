require "../spec_helper"

# What `tools/list` ADVERTISES has to be what `Tools#call` ENFORCES (#1140).
#
# An MCP client hands the model the `inputSchema` and, increasingly, validates the call
# against it before it leaves the client. gori's validator is strict — `unknown_args`
# refuses any key a tool does not declare, because a mistyped `verbatm:true` silently left
# `verbatim` off and the caller measured a request it never sent — but every root schema
# omitted `additionalProperties`, which in JSON Schema means "extras are fine". So the
# client was told one contract and scored against another: a typo it could have caught
# locally travelled to the server instead.
#
# The `_`-prefixed exemption the validator keeps (`_meta`) is deliberately NOT advertised:
# spelling it needs `patternProperties`, which several clients cannot parse when they convert
# an MCP `inputSchema` into their provider's tool schema, and one unparseable keyword on all
# 179 tools would cost such a client the whole catalogue. The validator therefore stays the
# more PERMISSIVE of the two — the direction that cannot surprise a caller who followed the
# schema. Catalogue-wide, so a tool added tomorrow cannot reintroduce the gap.
describe "MCP tools/list schema contract" do
  it "closes every root object schema, and keeps it to a subset every client can parse" do
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, true, false)
      catalogue = JSON.parse(JSON.build { |j| tools.list(j) }).as_a
      catalogue.size.should eq(Gori::MCP::Tools::TOOL_NAMES.size)

      open = [] of String
      catalogue.each do |t|
        schema = t["inputSchema"]
        open << t["name"].as_s unless schema["additionalProperties"]?.try(&.as_bool?) == false
        schema["patternProperties"]?.should be_nil, t["name"].as_s
      end
      open.should be_empty, "#{open.size} tools advertise an open schema: #{open.first(5).join(", ")}"
    end
  end

  it "never advertises MORE than the validator accepts" do
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, true, false)
      # An undeclared key is refused — which is what `additionalProperties:false` promises.
      bad = tools.call("list_projects", JSON.parse(%({"bogus":1})))
      bad.is_error.should be_true
      bad.error_code.should eq("INVALID_ARGUMENT")
      bad.text.should contain("bogus")

      # …and the exemption that is not advertised is still honoured, so a client that
      # attaches `_meta` to its arguments goes on working.
      ok = tools.call("list_projects", JSON.parse(%({"_meta":{"progressToken":1}})))
      ok.is_error.should be_false
    end
  end
end
