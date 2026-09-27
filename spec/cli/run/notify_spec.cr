require "../../spec_helper"
require "json"

# `gori run notify` (#1323) — the refusals and the answer. The command itself ends in `abort`
# or `puts`, so the decisions are split out and pinned here; the row it writes is pinned in
# spec/store/agent_replies_spec.cr.
describe "gori run notify — arguments" do
  it "takes a summary, a known level and at most one detail source" do
    Gori::CLI::Run.notify_args_error(["fuzz", "done"], "info", nil, nil).should be_nil
    Gori::CLI::Run.notify_args_error(["x"], "error", "d", nil).should be_nil
    Gori::CLI::Run.notify_args_error(["x"], "warn", nil, "-").should be_nil
  end

  it "refuses a missing or blank summary" do
    Gori::CLI::Run.notify_args_error([] of String, "info", nil, nil).not_nil!.should contain("no summary")
    Gori::CLI::Run.notify_args_error(["  "], "info", nil, nil).not_nil!.should contain("no summary")
  end

  # Refused, not clamped — the MCP tool refuses the same value, and `critical` quietly
  # becoming `info` is a wrong answer with no error on it.
  it "refuses a level outside the four" do
    msg = Gori::CLI::Run.notify_args_error(["x"], "critical", nil, nil).not_nil!
    msg.should contain("info, success, warn, error")
    msg.should contain("critical")
  end

  it "refuses --detail together with --detail-file" do
    Gori::CLI::Run.notify_args_error(["x"], "info", "a", "b.txt").not_nil!.should contain("not both")
  end
end

describe "gori run notify — output" do
  it "says whether a window was there to show it" do
    Gori::CLI::Run.notify_output(7_i64, "acme", "done", 1, :text).should contain("shown in the gori TUI open on acme (1 window)")
    Gori::CLI::Run.notify_output(7_i64, "acme", "done", 2, :text).should contain("(2 windows)")
    zero = Gori::CLI::Run.notify_output(7_i64, "acme", "done", 0, :text)
    zero.should contain("nobody was shown this yet")
    zero.should contain("next one to open sums it up")
    Gori::CLI::Run.notify_output(7_i64, "acme", "done", nil, :text).should contain("cannot tell")
  end

  it "answers JSON in reply_to_operator's `tui` shape" do
    j = JSON.parse(Gori::CLI::Run.notify_output(7_i64, "acme", "done", 0, :json))
    j["ok"].as_bool.should be_true
    j["id"].as_i64.should eq(7)
    j["project"].as_s.should eq("acme")
    j["summary"].as_s.should eq("done")
    j["tui"]["live"].as_bool.should be_false
    j["tui"]["windows"].as_i.should eq(0)
    JSON.parse(Gori::CLI::Run.notify_output(7_i64, "acme", "done", nil, :json))["tui"]["unknown"].as_bool.should be_true
  end
end
