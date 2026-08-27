require "../../spec_helper"
require "json"

# The headless half of user-defined History columns (#819): what `gori run history --column`
# prints and what MCP `list_history{columns}` returns. The values themselves are pinned in
# spec/display_columns_spec.cr; what matters here is that both feeds carry them WITHOUT
# changing what they already emitted for a caller that asked for none.

private def row : Gori::Store::FlowRow
  Gori::Store::FlowRow.new(
    id: 42_i64, created_at: 1_700_000_000_000_000_i64, scheme: "https", method: "GET",
    host: "h.test", port: 443, target: "/x", status: 200, size: 10_i64,
    state: Gori::Store::FlowState::Complete)
end

describe "gori run history — user-defined columns" do
  # EVERY column is printed, empty ones included: "the descriptor found nothing here" is an
  # answer a reader comparing rows needs to see rather than infer from a missing field.
  it "appends label=value to the text row, empty cells included" do
    text = Gori::CLI::Output.flow_row_text(row, [{"RID", "abc-1"}, {"SUB", ""}])
    text.should contain("RID=abc-1")
    text.should contain("SUB=")
  end

  it "leaves the text row byte-identical when no column was asked for" do
    Gori::CLI::Output.flow_row_text(row, nil).should eq(Gori::CLI::Output.flow_row_text(row))
    Gori::CLI::Output.flow_row_text(row, [] of {String, String})
      .should eq(Gori::CLI::Output.flow_row_text(row))
  end

  it "carries the values under `columns` in JSON, and omits the key otherwise" do
    doc = JSON.parse(Gori::CLI::Output.flow_row_json(row, nil, [{"RID", "abc-1"}]))
    doc["columns"]["RID"].as_s.should eq("abc-1")

    JSON.parse(Gori::CLI::Output.flow_row_json(row)).as_h.has_key?("columns").should be_false
    JSON.parse(Gori::CLI::Output.flow_row_json(row, nil, [] of {String, String}))
      .as_h.has_key?("columns").should be_false
  end

  # Two columns MAY share a label — the same header off the request and off the response is a
  # comparison, not a mistake — and a plain last-wins object would drop the half the operator
  # defined first. Same fold `request_headers_json` already uses for repeated header names.
  it "folds two columns under one label into an array rather than dropping one" do
    doc = JSON.parse(Gori::CLI::Output.flow_row_json(row, nil, [{"ID", "sent"}, {"ID", "echoed"}]))
    doc["columns"]["ID"].as_a.map(&.as_s).should eq(["sent", "echoed"])
  end

  it "returns the same shape from the MCP row serializer" do
    doc = JSON.parse(JSON.build { |j| Gori::MCP::Serialize.flow_row(j, row, [{"RID", "abc-1"}]) })
    doc["columns"]["RID"].as_s.should eq("abc-1")

    plain = JSON.parse(JSON.build { |j| Gori::MCP::Serialize.flow_row(j, row) })
    plain.as_h.has_key?("columns").should be_false
  end
end
