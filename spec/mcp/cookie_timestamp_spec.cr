require "../spec_helper"
require "json"

# `cookie_forge`'s `timestamp` arg must tell "absent" (→ now) from "present but unusable"
# (→ named refusal). `int(h, "timestamp") || Time.utc.to_unix` collapsed the two: an
# unparseable / fractional / out-of-range / negative value silently stamped the current
# time and reported the forged cookie as success. See `Tools#cookie_forge_tool`.

private def with_store(&)
  path = File.tempname("gori-mcp-cookie-ts", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def cookie_tools(store) : Gori::MCP::Tools
  Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
end

private def forge(tools : Gori::MCP::Tools, ts : String)
  args = %({"format":"flask","secret":"s3cr3t-key","payload":"{\\"user\\":\\"admin\\",\\"role\\":\\"root\\"}"#{ts}})
  tools.call("cookie_forge", JSON.parse(args))
end

describe "MCP cookie_forge timestamp — refused by name, never silently 'now'" do
  it "reproduces the golden Flask cookie for a valid timestamp" do
    with_store do |store|
      r = forge(cookie_tools(store), %(,"timestamp":1750000000))
      r.is_error.should be_false
      JSON.parse(r.text)["cookie"].as_s.should eq(
        "eyJ1c2VyIjoiYWRtaW4iLCJyb2xlIjoicm9vdCJ9.aE7hgA.C-FfBh6RRZZCk2DOX6_rVia4_iQ")
    end
  end

  it "accepts the same value sent as a string (lenient client encoding)" do
    with_store do |store|
      r = forge(cookie_tools(store), %(,"timestamp":"1750000000"))
      r.is_error.should be_false
      JSON.parse(r.text)["cookie"].as_s.should eq(
        "eyJ1c2VyIjoiYWRtaW4iLCJyb2xlIjoicm9vdCJ9.aE7hgA.C-FfBh6RRZZCk2DOX6_rVia4_iQ")
    end
  end

  it "defaults to now when timestamp is ABSENT (still succeeds)" do
    with_store do |store|
      r = forge(cookie_tools(store), "")
      r.is_error.should be_false
      JSON.parse(r.text)["cookie"].as_s.should_not be_empty
    end
  end

  it "treats an explicit JSON null as absent (defaults to now)" do
    with_store do |store|
      r = forge(cookie_tools(store), %(,"timestamp":null))
      r.is_error.should be_false
    end
  end

  it "refuses an unparseable string by name (not silently 'now')" do
    with_store do |store|
      r = forge(cookie_tools(store), %(,"timestamp":"notanumber"))
      r.is_error.should be_true
      r.text.should contain("timestamp")
    end
  end

  it "refuses a fractional number by name (no silent truncation)" do
    with_store do |store|
      r = forge(cookie_tools(store), %(,"timestamp":5.9))
      r.is_error.should be_true
      r.text.should contain("timestamp")
    end
  end

  it "refuses a negative timestamp by name" do
    with_store do |store|
      r = forge(cookie_tools(store), %(,"timestamp":-5))
      r.is_error.should be_true
      r.text.should contain("must not be negative")
    end
  end

  it "accepts 0 as the epoch" do
    with_store do |store|
      r = forge(cookie_tools(store), %(,"timestamp":0))
      r.is_error.should be_false
    end
  end
end
