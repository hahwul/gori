require "./spec_helper"

# Every MCP integer argument that ends up in an Int32 has to be BOUNDED IN Int64 FIRST.
# Crystal's `.to_i` / `.to_i32` are checked, so a large-but-legal integer — `{"limit":
# 10000000000}`, the "no limit" number an LLM reaches for — raised OverflowError at the call
# site, sailed past the INVALID_ARGUMENT arm in `Tools#call` and came back as INTERNAL
# "tool error: Arithmetic overflow". An INTERNAL code tells an agent's error policy "the
# server is broken, back off / escalate" over a mistake in its own arguments.
#
# `Tools#clamp` and `mine_bucket` were already written in the right order; preview_color_rule,
# compare_flows and the extract-rule offsets inverted it.

private def with_store(&)
  path = File.tempname("gori-mcp-ints", ".db")
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

private def int_tools(store) : Gori::MCP::Tools
  Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
end

# The failure this file exists for: an INTERNAL result carrying the OverflowError's message.
private def refute_overflow(r : Gori::MCP::Tools::Result, what : String)
  r.error_code.should_not eq("INTERNAL")
  if r.text.includes?("Arithmetic overflow")
    fail "#{what} came back as an arithmetic overflow: #{r.text[0, 200]}"
  end
end

private def int_json(tools : Gori::MCP::Tools, name : String, args : String) : JSON::Any
  r = tools.call(name, JSON.parse(args))
  refute_overflow(r, "#{name}#{args}")
  fail "tool #{name}#{args} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

private def seed_int_flow(store, body : String) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: "/x", http_version: "HTTP/1.1",
    head: "GET /x HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice,
    body: body.to_slice, content_type: "text/plain"))
  id
end

describe "MCP integer arguments — bounded before they are narrowed" do
  it "preview_color_rule bounds a huge 'limit' instead of overflowing into INTERNAL" do
    with_store do |store|
      tools = int_tools(store)
      pv = int_json(tools, "preview_color_rule", %({"when":"body:secret","limit":10000000000}))
      pv["scanned"].as_i.should eq(0)
      pv["would_match"].as_i.should eq(0)
    end
  end

  # The floor stays a CLAMP, not a refusal. `0` is the other spelling of "no limit" an agent
  # reaches for — right beside the huge number above — and this argument has been forgiving at
  # both ends since it existed (`list_history`'s row limit still is). Pinned so the overflow fix
  # above cannot quietly turn one way of failing the call into another.
  it "preview_color_rule clamps a 'limit' below the floor instead of failing the call" do
    with_store do |store|
      r = int_tools(store).call("preview_color_rule", JSON.parse(%({"when":"body:secret","limit":0})))
      r.is_error.should be_false
    end
  end

  it "compare_flows bounds a huge 'context' instead of overflowing into INTERNAL" do
    with_store do |store|
      a = seed_int_flow(store, "line1\nline2\nline3")
      b = seed_int_flow(store, "line1\nCHANGED\nline3")
      tools = int_tools(store)
      huge = int_json(tools, "compare_flows",
        %({"flow_id_a":#{a},"flow_id_b":#{b},"context":5000000000}))
      # A context at or past the diff's length folds nothing, so the bound is exact: the
      # huge value must diff identically to a context that already covers the whole message.
      wide = int_json(tools, "compare_flows",
        %({"flow_id_a":#{a},"flow_id_b":#{b},"context":1000}))
      huge["changed_lines"].as_i.should be > 0
      huge["diff"].should eq(wide["diff"])
    end
  end

  it "create_extract_rule bounds a huge 'pos_start' instead of overflowing into INTERNAL" do
    with_store do |store|
      tools = int_tools(store)
      int_json(tools, "create_extract_rule",
        %({"name":"TOK","kind":"cookie","selector":"sid","pos_start":5000000000}))
      row = store.extract_rules.find { |r| r.name == "TOK" }.not_nil!
      row.pos_start.should eq(Int32::MAX)
    end
  end

  it "update_extract_rule bounds a huge 'pos_end' and leaves the stored offsets alone when omitted" do
    with_store do |store|
      tools = int_tools(store)
      int_json(tools, "create_extract_rule",
        %({"name":"TOK","kind":"cookie","selector":"sid"}))
      id = store.extract_rules.find { |r| r.name == "TOK" }.not_nil!.id
      int_json(tools, "update_extract_rule", %({"id":#{id},"pos_end":5000000000}))
      row = store.extract_rules.find { |r| r.id == id }.not_nil!
      row.pos_end.should eq(Int32::MAX)
      row.pos_start.should eq(0)

      # The omitted-field contract still holds: a later update that names neither offset
      # must pass the stored values through, not re-read them as caller input.
      int_json(tools, "update_extract_rule", %({"id":#{id},"selector":"session"}))
      kept = store.extract_rules.find { |r| r.id == id }.not_nil!
      kept.pos_end.should eq(Int32::MAX)
      kept.selector.should eq("session")
    end
  end
end
