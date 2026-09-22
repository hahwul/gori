require "../../spec_helper"
require "json"

# `gori run probe rules add --format json` (#1117): a script adding a custom match rule had to
# scrape `custom_p_7` out of "Custom rule 'custom_p_7' created.". The object is the rule's entry
# from `probe rules --format json`, so `id` is the CODE that listing prints and the sibling verbs
# take, not the bare row number they refuse.
module Gori::CLI::Run
  def self.probe_rule_added_output_for_spec(store : Store, id : Int64, format : Symbol) : String
    probe_rule_added_output(store, id, format)
  end
end

describe "gori run probe rules add --format json" do
  it "prints the new rule's listing entry, its code as the id" do
    with_store do |store|
      row = store.insert_probe_custom_rule("Leaked key", "an AWS key in a body", "response", "body",
        "regex", "AKIA[0-9A-Z]{16}", Gori::Store::Severity::High)
      o = JSON.parse(Gori::CLI::Run.probe_rule_added_output_for_spec(store, row, :json))
      o["id"].as_s.should eq("custom_p_#{row}")
      o["kind"].as_s.should eq("custom")
      o["scope"].as_s.should eq("project")
      o["severity"].as_s.should eq("high")

      entry = Gori::Probe::RuleCatalog.load(store).find! { |e| e.id == "custom_p_#{row}" }
      listed = JSON.parse(JSON.build { |j| Gori::Probe::RuleCatalog.entry_json(j, entry) })
      o.as_h.keys.should eq(listed.as_h.keys)
      o.should eq(listed)
    end
  end

  it "keeps the text sentence unchanged" do
    with_store do |store|
      Gori::CLI::Run.probe_rule_added_output_for_spec(store, 7_i64, :text)
        .should eq("Custom rule 'custom_p_7' created.")
    end
  end
end
