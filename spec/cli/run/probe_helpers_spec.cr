require "../../spec_helper"

# `gori run probe` — the argument parses and id decoding, which are the parts of this
# subcommand that run before any traffic does.
#
# The scan itself is an active sender and is covered with the rest of them (see the header of
# spec/cli/run_spec.cr). What is here is everything a triage command decides on its own: which
# rule tier `--kind` names, which STORE a rule id addresses, and how a malformed query is
# echoed back. The `abort` branches call `exit`, so only the success paths run here — the
# same limit spec/cli/run/links_spec.cr works under.

# Private CLI glue — reopen the module for bare-call wrappers.
module Gori::CLI::Run
  def self.parse_rule_kind_for_spec(v : String) : String
    parse_rule_kind(v)
  end

  def self.probe_custom_row_id_for_spec(id : String) : Int64?
    probe_custom_row_id(id)
  end

  def self.parse_probe_issue_id_for_spec(v : String?, ctx : String) : Int64?
    parse_probe_issue_id(v, ctx)
  end

  def self.truncate_query_for_spec(q : String?) : String?
    truncate_query(q)
  end

  def self.parse_severity_for_spec(v : String) : Store::Severity
    parse_severity(v)
  end

  def self.parse_probe_category_for_spec(v : String) : String
    parse_probe_category(v)
  end

  def self.probe_progress_meter_for_spec(meter : Bool) : Proc(Int32, Int32, Nil)?
    probe_progress_meter(meter)
  end
end

describe "gori run probe — flag parsing" do
  it "accepts the three rule tiers, trimmed and case-folded" do
    Gori::CLI::Run.parse_rule_kind_for_spec("passive").should eq("passive")
    Gori::CLI::Run.parse_rule_kind_for_spec("ACTIVE").should eq("active")
    Gori::CLI::Run.parse_rule_kind_for_spec("  custom  ").should eq("custom")
  end

  it "parses every severity level" do
    Gori::CLI::Run.parse_severity_for_spec("info").should eq(Gori::Store::Severity::Info)
    Gori::CLI::Run.parse_severity_for_spec("low").should eq(Gori::Store::Severity::Low)
    Gori::CLI::Run.parse_severity_for_spec("medium").should eq(Gori::Store::Severity::Medium)
    Gori::CLI::Run.parse_severity_for_spec("high").should eq(Gori::Store::Severity::High)
    Gori::CLI::Run.parse_severity_for_spec("critical").should eq(Gori::Store::Severity::Critical)
    Gori::CLI::Run.parse_severity_for_spec("CRITICAL").should eq(Gori::Store::Severity::Critical)
  end

  # The accepted set is `Probe::FILTER_CATEGORIES` itself, not a copy — so a new category
  # becomes filterable on this surface the moment the engine grows one.
  it "accepts every category the engine filters on, case-folded" do
    Gori::CLI::Run::PROBE_CATEGORIES.should_not be_empty
    Gori::CLI::Run::PROBE_CATEGORIES.each do |cat|
      Gori::CLI::Run.parse_probe_category_for_spec(cat).should eq(cat)
      Gori::CLI::Run.parse_probe_category_for_spec(cat.upcase).should eq(cat)
    end
  end

  it "reads a finding id, and treats an absent flag as 'not filtered'" do
    Gori::CLI::Run.parse_probe_issue_id_for_spec("42", "gori run probe dismiss").should eq(42_i64)
    Gori::CLI::Run.parse_probe_issue_id_for_spec("-1", "gori run probe dismiss").should eq(-1_i64)
    Gori::CLI::Run.parse_probe_issue_id_for_spec(nil, "gori run probe dismiss").should be_nil
  end
end

# A custom Probe rule id says which STORE it came from: `custom_p_<rowid>` is a row in THIS
# project's DB, `custom_g_<hex>` a global one in settings.json. Decoding a global id as a row
# id would send a delete at whatever project row happened to share the number.
describe "gori run probe rules — which store an id addresses" do
  it "decodes a project custom id to its row id" do
    Gori::CLI::Run.probe_custom_row_id_for_spec("custom_p_12").should eq(12_i64)
    Gori::CLI::Run.probe_custom_row_id_for_spec("custom_p_1").should eq(1_i64)
  end

  it "refuses a global custom id — it is not a project DB row" do
    Gori::CLI::Run.probe_custom_row_id_for_spec("custom_g_4f2a").should be_nil
    Gori::CLI::Run.probe_custom_row_id_for_spec("custom_g_12").should be_nil
  end

  it "refuses a built-in rule id, which no store row backs" do
    Gori::CLI::Run.probe_custom_row_id_for_spec("jwt_alg_none").should be_nil
    Gori::CLI::Run.probe_custom_row_id_for_spec("cors_reflection").should be_nil
  end

  # The prefix is not enough: everything after it has to be an integer, or the id names
  # nothing and must not be coerced into one.
  it "refuses a project-shaped id with a non-numeric tail" do
    Gori::CLI::Run.probe_custom_row_id_for_spec("custom_p_").should be_nil
    Gori::CLI::Run.probe_custom_row_id_for_spec("custom_p_abc").should be_nil
    Gori::CLI::Run.probe_custom_row_id_for_spec("custom_p_1x").should be_nil
  end
end

# A malformed QL query can be arbitrarily large — a raw regex term, a pasted body — and it is
# echoed back inside an error message. Enough to identify the query, not to replay it.
describe "gori run probe — echoing a query back in an error" do
  it "passes a short query through unchanged" do
    Gori::CLI::Run.truncate_query_for_spec("host:example.com").should eq("host:example.com")
    Gori::CLI::Run.truncate_query_for_spec(nil).should be_nil
    Gori::CLI::Run.truncate_query_for_spec("").should eq("")
  end

  it "leaves a query exactly at the limit alone" do
    q = "a" * Gori::CLI::Run::QUERY_ECHO_LIMIT
    Gori::CLI::Run.truncate_query_for_spec(q).should eq(q)
  end

  it "clips a longer one to the limit plus an ellipsis" do
    truncated = Gori::CLI::Run.truncate_query_for_spec("b" * (Gori::CLI::Run::QUERY_ECHO_LIMIT + 50))
    truncated.should eq("#{"b" * Gori::CLI::Run::QUERY_ECHO_LIMIT}…")
  end

  # `q[0, LIMIT]` slices CHARACTERS, not bytes, so a multi-byte query is cut on a character
  # boundary — slicing bytes here would emit an invalid-UTF-8 error message.
  it "clips on a character boundary, not a byte one" do
    q = "한" * (Gori::CLI::Run::QUERY_ECHO_LIMIT + 10)
    truncated = Gori::CLI::Run.truncate_query_for_spec(q).not_nil!
    truncated.valid_encoding?.should be_true
    truncated.size.should eq(Gori::CLI::Run::QUERY_ECHO_LIMIT + 1) # + the ellipsis
  end
end

describe "gori run probe — the scan progress meter" do
  it "is nil when the meter is off, so the scan pays nothing per flow" do
    Gori::CLI::Run.probe_progress_meter_for_spec(false).should be_nil
  end

  it "is a callable the scan can hand (i, n) to" do
    meter = Gori::CLI::Run.probe_progress_meter_for_spec(true).not_nil!
    meter.call(1, 100).should be_nil # off-beat tick: throttled, prints nothing
  end
end
