require "../../spec_helper"

module Gori::CLI::Run
  def self.repeater_update_for_spec(args : Array(String)) : Nil
    cmd_repeater_update(args)
  end
end

# `with_store`'s shape plus the path, which the command opens on its own (`--db`).
private def with_db_store(&)
  path = File.tempname("gori-spec", ".db")
  store = Gori::Store.open(path)
  raised = run_capturing { yield store, path }
  store.close
  delete_db_files(path)
  raise raised if raised
end

private def seed_update_repeater(store : Gori::Store) : Int64
  id = store.insert_repeater(target: "http://127.0.0.1:1",
    request: "GET /old HTTP/1.1\r\nHost: h\r\n\r\n".to_slice,
    http2: false, auto_cl: true, flow_id: nil, position: 0, sni: "keep.example")
  store.set_repeater_name(id, "old")
  store.set_repeater_tags(id, "keep")
  id
end

# `gori run repeater update <id>` (#1681): the in-place edit that delete + create could not be,
# because a new row is a new id and the retest steps and links pointing at the old one orphan.
describe "gori run repeater update" do
  it "changes only what a flag names, keeping the id" do
    with_db_store do |store, path|
      id = seed_update_repeater(store)
      Gori::CLI::Run.repeater_update_for_spec([id.to_s, "--db", path,
                                               "--target", "https://api.example:8443",
                                               "--request-raw", "POST /new HTTP/1.1\r\nHost: h\r\n\r\n",
                                               "--http2", "--no-auto-cl"])
      rec = store.get_repeater(id).not_nil!
      rec.target.should eq("https://api.example:8443")
      String.new(rec.request).should start_with("POST /new ")
      rec.http2?.should be_true
      rec.auto_content_length?.should be_false
      rec.sni.should eq("keep.example")
      rec.name.should eq("old")
      store.repeaters_mcp.find! { |r| r.id == id }.tags.should eq("keep")
    end
  end

  it "normalizes tags as MCP does, and a blank (or whitespace-only) name or SNI clears it" do
    with_db_store do |store, path|
      id = seed_update_repeater(store)
      Gori::CLI::Run.repeater_update_for_spec([id.to_s, "--db", path,
                                               "--tags", "#idor, x,,#IDOR", "--name", "   ", "--sni", ""])
      rec = store.get_repeater(id).not_nil!
      rec.name.should be_nil
      rec.sni.should be_nil
      store.repeaters_mcp.find! { |r| r.id == id }.tags.should eq("idor x")
      String.new(rec.request).should start_with("GET /old ")
    end
  end
end

# The usage banner is the `@[Subcommand]` rows, so a subcommand `cmd_repeater` dispatches but
# the rows omit is missing from `repeater --help`. The banner used to be hand-written and
# listed five of the ten.
describe "gori run repeater subcommand rows" do
  it "name every subcommand cmd_repeater dispatches" do
    rows = Gori::CLI::Run.repeater_subcommand_rows.map(&.[0])
    Gori::CLI::Run::REPEATER_SUBCOMMANDS.keys.map { |k| "repeater #{k}" }.sort!.should eq(rows.sort)
  end
end

describe "gori run repeater update — argv" do
  it "refuses two request sources, nothing to change, and an unsendable target" do
    f = Gori::CLI::Run::RepeaterUpdateFlags.new
    Gori::CLI::Run.repeater_update_error(f, f.sources).not_nil!.should start_with("nothing to change")
    f.request_raw = "GET / HTTP/1.1"
    f.request_stdin = true
    Gori::CLI::Run.repeater_update_error(f, f.sources).should eq("--request-raw, --request-stdin cannot be combined — pick one request source")
    f = Gori::CLI::Run::RepeaterUpdateFlags.new
    f.target = "ftp://x"
    Gori::CLI::Run.repeater_update_error(f, f.sources).should eq(%(invalid --target: unsupported target scheme "ftp"))
    f.target = ""
    Gori::CLI::Run.repeater_update_error(f, f.sources).should eq("--target must not be empty")
    f.target = nil
    f.http2 = false
    Gori::CLI::Run.repeater_update_error(f, f.sources).should be_nil
  end
end
