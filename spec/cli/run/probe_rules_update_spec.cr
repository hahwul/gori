require "../../spec_helper"

module Gori::CLI::Run
  def self.probe_rule_update_for_spec(args : Array(String)) : Nil
    cmd_probe_rule_update(args)
  end
end

private def with_probe_db(&)
  path = File.tempname("gori-spec", ".db")
  store = Gori::Store.open(path)
  raised = run_capturing { yield store, path }
  store.close
  delete_db_files(path)
  raise raised if raised
end

private def seed_custom_rule(store : Gori::Store) : Int64
  store.insert_probe_custom_rule("Leaked key", "an AWS key", "response", "body", "regex",
    "AKIA[0-9A-Z]{16}", Gori::Store::Severity::High)
end

# `gori run probe rules update <custom-rule-id>`: the headless `update_probe_rule`, editing the
# row in place so its id — and every finding and toggle keyed by it — survives.
describe "gori run probe rules update" do
  it "changes only what a flag names, keeping the id and enabled state" do
    with_probe_db do |store, path|
      id = seed_custom_rule(store)
      store.set_probe_custom_rule_enabled(id, false)
      Gori::CLI::Run.probe_rule_update_for_spec(["custom_p_#{id}", "--db", path,
                                                 "--title", "AWS key", "--severity", "critical", "--description", ""])
      r = store.probe_custom_rules.find! { |x| x.id == id }
      r.title.should eq("AWS key")
      r.severity.should eq(Gori::Store::Severity::Critical)
      r.description.should eq("")
      r.pattern.should eq("AKIA[0-9A-Z]{16}")
      r.kind.should eq("regex")
      r.enabled?.should be_false
    end
  end

  it "refuses nothing to change, a blank title or pattern, and a pattern the new kind cannot use" do
    with_store do |store|
      id = seed_custom_rule(store)
      prev = store.probe_custom_rules.find! { |x| x.id == id }
      f = Gori::CLI::Run::ProbeRuleUpdateFlags.new
      Gori::CLI::Run.probe_rule_update(f, prev).as(String).should start_with("nothing to change")
      f.title = "  "
      Gori::CLI::Run.probe_rule_update(f, prev).should eq("--title must not be blank (omit it to keep the current title)")
      f = Gori::CLI::Run::ProbeRuleUpdateFlags.new
      f.pattern = ""
      Gori::CLI::Run.probe_rule_update(f, prev).should eq("--pattern must not be blank (omit it to keep the current pattern)")
      f = Gori::CLI::Run::ProbeRuleUpdateFlags.new
      f.pattern = "(" # the stored kind is regex, so the new pattern is judged as one
      Gori::CLI::Run.probe_rule_update(f, prev).should eq("invalid regex --pattern (PCRE rejected it)")
      f.kind = "string"
      Gori::CLI::Run.probe_rule_update(f, prev).as(Gori::Store::ProbeCustomRule).kind.should eq("string")
      f.side = "sideways"
      Gori::CLI::Run.probe_rule_update(f, prev).as(String).should start_with("invalid --side 'sideways'")
    end
  end
end
