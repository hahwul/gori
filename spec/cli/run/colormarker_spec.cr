require "../../spec_helper"
require "json"

# `gori run colormarker` — the printed shapes. The commands themselves end in `abort`/`exit`
# and cannot be exercised from a spec, so what is pinned here is what an operator (or a script
# parsing `--format=json`) actually reads.
private def rule(id : Int64 = 1_i64, enabled = true, filter = "status:>=500",
                 color = "red",
                 style = Gori::Store::MarkerStyle::Full, name = "",
                 scope = Gori::Store::RuleScope::Project, overridden = false)
  Gori::Store::ColorRule.new(id, enabled, filter, color, style, name,
    scope: scope, overridden: overridden)
end

private def json_for(r : Gori::Store::ColorRule) : JSON::Any
  JSON.parse(JSON.build { |j| Gori::CLI::Run.colormarker_rule_json(j, r) })
end

describe "gori run colormarker — text rows" do
  it "leads with the scope letter, because that is half the rule's identity" do
    # The two stores number independently and both count from 1, so `#1` alone does not say
    # which rule the next command would address.
    row = Gori::CLI::Run.colormarker_rule_row(rule(name: "prod 5xx"))
    row.should start_with("P#1 [x] full  red   ")
    row.should contain("[prod 5xx]")
    row.should end_with("status:>=500")

    Gori::CLI::Run.colormarker_rule_row(rule(scope: Gori::Store::RuleScope::Global))
      .should start_with("G#1")
  end

  it "marks a global rule this project overrides, so two opposite rows cannot look alike" do
    r = rule(enabled: false, scope: Gori::Store::RuleScope::Global, overridden: true)
    row = Gori::CLI::Run.colormarker_rule_row(r)
    row.should start_with("G*#1 [ ]")
  end

  it "names an empty condition rather than printing a blank tail" do
    # The parser tolerates one already on disk (creation refuses to make one), and a row that
    # simply ended after the colour would read as a formatting bug rather than a real rule.
    Gori::CLI::Run.colormarker_rule_row(rule(filter: "")).should end_with("(every flow)")
  end

  it "aligns the style and colour columns so the conditions line up down the list" do
    a = Gori::CLI::Run.colormarker_rule_row(rule(filter: "host:a",
      color: "red", style: Gori::Store::MarkerStyle::Full))
    b = Gori::CLI::Run.colormarker_rule_row(rule(filter: "host:b",
      color: "orange", style: Gori::Store::MarkerStyle::Strip))
    a.index("host:a").should eq(b.index("host:b"))
  end

  # A custom colour is an operator-typed name of any length, so the column cannot be a literal
  # width that happens to fit the longest built-in word. One `hotpink` used to shift the name and
  # condition columns on every OTHER row of the listing.
  it "widens the colour column to the longest name in the listing, and only then" do
    rules = [rule(filter: "host:a", color: "red"),
             rule(id: 2_i64, filter: "host:b", color: "electric-lavender")]
    w = Gori::CLI::Run.colormarker_color_width(rules)
    rows = rules.map { |r| Gori::CLI::Run.colormarker_rule_row(r, w) }
    rows[0].index("host:a").should eq(rows[1].index("host:b"))
    rows[0].should contain("red               ") # padded out to the long name's width

    # A listing of built-ins keeps the width it has always had, so the common output is byte
    # identical to before.
    builtin = [rule(color: "red"), rule(id: 2_i64, color: "orange")]
    Gori::CLI::Run.colormarker_color_width(builtin).should eq(6)
    Gori::CLI::Run.colormarker_rule_row(builtin[0], 6)
      .should eq(Gori::CLI::Run.colormarker_rule_row(builtin[0]))
  end
end

describe "gori run colormarker — JSON" do
  it "uses the same `when` key settings.json writes and the MCP tools accept" do
    o = json_for(rule(name: "n"))
    o["when"].as_s.should eq("status:>=500")
    o["color"].as_s.should eq("red")
    o["style"].as_s.should eq("full")
    o["scope"].as_s.should eq("project")
    o["enabled"].as_bool.should be_true
    o["name"].as_s.should eq("n")
  end

  # A project rule has ONE state. Printing two fields for it would invite the reader to look
  # for a difference that cannot exist.
  it "omits the override pair for a project rule" do
    o = json_for(rule)
    o.as_h.has_key?("overridden").should be_false
    o.as_h.has_key?("default_enabled").should be_false
  end

  it "carries both states for a global rule, where they can differ" do
    before = Gori::Settings.colormarker_rules
    begin
      Gori::Settings.colormarker_rules = [
        Gori::Settings::ColormarkerRule.new(4_i64, true, "", "host:cdn", "blue", "strip"),
      ]
      # enabled: the EFFECTIVE state here (off) · default_enabled: what the library says (on)
      o = json_for(rule(id: 4_i64, enabled: false,
        scope: Gori::Store::RuleScope::Global, overridden: true))
      o["enabled"].as_bool.should be_false
      o["overridden"].as_bool.should be_true
      o["default_enabled"].as_bool.should be_true
    ensure
      Gori::Settings.colormarker_rules = before
    end
  end
end

module Gori::CLI::Run
  def self.colormarker_added_json_for_spec(id : Int64, store : Store?) : String
    colormarker_added_json(id, store)
  end
end

# `colormarker add --format json` (#1117): the listing's object for the rule just written,
# read back from the store it went to.
describe "gori run colormarker add --format json" do
  it "prints a project rule's listing object, id included" do
    with_store do |store|
      id = store.insert_color_rule("status:>=500", "red", Gori::Store::MarkerStyle::Strip, "errs", false)
      o = JSON.parse(Gori::CLI::Run.colormarker_added_json_for_spec(id, store))
      o["id"].as_i64.should eq(id)
      o["scope"].as_s.should eq("project")
      o["enabled"].as_bool.should be_false

      listed = json_for(Gori::Colormarker.merged(store).find! { |r| !r.global? && r.id == id })
      o.as_h.keys.should eq(listed.as_h.keys)
      o.should eq(listed)
    end
  end

  # No store on this path: `add --scope global` writes settings.json and opens no project.
  it "prints a global rule's listing object, override pair included" do
    before = Gori::Settings.colormarker_rules
    begin
      Gori::Settings.colormarker_rules = [
        Gori::Settings::ColormarkerRule.new(7_i64, true, "", "host:cdn", "blue", "strip"),
      ]
      o = JSON.parse(Gori::CLI::Run.colormarker_added_json_for_spec(7_i64, nil))
      o["id"].as_i64.should eq(7)
      o["scope"].as_s.should eq("global")
      o["overridden"].as_bool.should be_false
      o["default_enabled"].as_bool.should be_true

      with_store do |store|
        listed = json_for(Gori::Colormarker.merged(store).find! { |r| r.global? && r.id == 7_i64 })
        o.as_h.keys.should eq(listed.as_h.keys)
        o.should eq(listed)
      end
    ensure
      Gori::Settings.colormarker_rules = before
    end
  end
end
