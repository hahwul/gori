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

# #1002, the half the `headers` block alone could not fix. This project's CONFIGURED columns
# are drawn by DEFAULT — `DisplayColumns.load(store)` when no `--column` was passed — so a
# `req:header:authorization` set once in the TUI's Columns… dialog kept printing the
# credential on every later `--format json` run, in the same object as the
# `sensitive_headers_redacted: true` the redacted `headers` block had just asserted. A row
# cannot both withhold a credential and print it.
private def col(kind : Gori::ExtractKind, selector : String) : Gori::Store::DisplayColumn
  Gori::Store::DisplayColumn.new(id: 1_i64, position: 0, label: "C",
    side: Gori::MessageSide::Request, kind: kind, selector: selector)
end

describe "gori run history --format json — sensitive History columns" do
  it "covers a header column whose selector names a sensitive header, in any case" do
    Gori::CLI::Output.sensitive_column?(col(Gori::ExtractKind::Header, "authorization")).should be_true
    Gori::CLI::Output.sensitive_column?(col(Gori::ExtractKind::Header, "Authorization")).should be_true
    Gori::CLI::Output.sensitive_column?(col(Gori::ExtractKind::Header, "SET-COOKIE")).should be_true
    Gori::CLI::Output.sensitive_column?(col(Gori::ExtractKind::Header, "x-api-key")).should be_true
  end

  # A named cookie's value is by construction a substring of the `Cookie` header the row
  # redacts, so covering `header:cookie` and not `cookie:sid` would leave the same credential
  # printing beside the same `[REDACTED]`.
  it "covers a cookie column whatever its selector" do
    Gori::CLI::Output.sensitive_column?(col(Gori::ExtractKind::Cookie, "sid")).should be_true
    Gori::CLI::Output.sensitive_column?(col(Gori::ExtractKind::Cookie, "theme")).should be_true
  end

  # The three content-scoped kinds can lift a credential out of any byte of the message and
  # the descriptor cannot say whether they do. Left alone rather than guessed at — the docs
  # name them as uncovered instead of implying a guarantee.
  it "does not claim the content-scoped kinds, nor an ordinary header" do
    Gori::CLI::Output.sensitive_column?(col(Gori::ExtractKind::Header, "x-request-id")).should be_false
    Gori::CLI::Output.sensitive_column?(col(Gori::ExtractKind::Regex, "tok=(\\w+)")).should be_false
    Gori::CLI::Output.sensitive_column?(col(Gori::ExtractKind::JsonPath, "data.token")).should be_false
    Gori::CLI::Output.sensitive_column?(col(Gori::ExtractKind::Position, "")).should be_false
  end

  # The marker has to be true for a row whose ONLY redaction was a column: a
  # `res:header:set-cookie` column reads the RESPONSE, and the `headers` block is
  # request-only, so the block's own hit count cannot stand in for it.
  it "marks a row whose only redaction was a column, head or no head" do
    head = "GET /x HTTP/1.1\r\nHost: h.test\r\nAccept: */*\r\n\r\n".to_slice
    # `has_key?` before `as_bool`: `JSON::Any#[]` RAISES on a missing key, so asserting the
    # value directly turns a caught regression into an ERROR rather than a failure — which
    # reads like a broken spec instead of a broken guarantee.
    doc = JSON.parse(Gori::CLI::Output.flow_row_json(row, head, [{"C", "[REDACTED]"}],
      columns_redacted: true)).as_h
    doc.has_key?("sensitive_headers_redacted").should be_true
    doc["sensitive_headers_redacted"].as_bool.should be_true
    # No request head at all — a Pending capture. The marker still has to appear.
    pending = JSON.parse(Gori::CLI::Output.flow_row_json(row, nil, [{"C", "[REDACTED]"}],
      columns_redacted: true)).as_h
    pending.has_key?("sensitive_headers_redacted").should be_true
    # And stays absent when nothing anywhere was withheld.
    JSON.parse(Gori::CLI::Output.flow_row_json(row, head, [{"C", "abc-1"}])).as_h
      .has_key?("sensitive_headers_redacted").should be_false
  end

  # `row_columns` is private and the command it serves opens a store and writes to STDOUT, so
  # the APPLICATION of the policy is asserted over the source, like the `--include-sensitive`
  # wiring guard in history_spec. Both listing branches must state their intent explicitly —
  # the parameter carries no default precisely so neither can inherit a fail-open one.
  it "applies the policy in row_columns and makes both listing branches declare intent" do
    src = File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run", "history.cr"))
    src.should contain("CLI::Output.sensitive_column?(c)")
    src.should contain("include_sensitive : Bool) : {Array({String, String}), Bool}?")
    sites = src.lines.select(&.includes?("row_columns(store, r, prepared"))
    sites.size.should eq(2)
    sites.each { |l| l.should match(/row_columns\(store, r, prepared, (include_sensitive|include_sensitive: true)\)/) }
  end
end
