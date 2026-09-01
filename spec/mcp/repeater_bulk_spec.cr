require "../spec_helper"

# The tab-number / database-id split (#904), the reorder that `position` had no writer for,
# and the bulk tools. Everything here goes through `Tools#call`, because the argument
# validation and the per-id reporting are the point — a handler called directly would skip
# `unknown_args` and the schema the reply is supposed to match.

private def with_store(&)
  path = File.tempname("gori-repeaterbulk", ".db")
  store = Gori::Store.open(path)
  prev_env = Gori::Settings.project_env_vars
  begin
    yield store
  ensure
    Gori::Settings.project_env_vars = prev_env
    Gori::Env.bump_highlight_rev
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def tools(store)
  Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
end

private def call_json(store, name, args : String) : JSON::Any
  r = tools(store).call(name, JSON.parse(args))
  fail "#{name} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

private def call_err(store, name, args : String) : Gori::MCP::Tools::Result
  r = tools(store).call(name, JSON.parse(args))
  fail "#{name} unexpectedly succeeded: #{r.text}" unless r.is_error
  r
end

private def seed_flow(store, method : String, path : String) : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
    method: method, target: path, http_version: "HTTP/1.1",
    head: "#{method} #{path} HTTP/1.1\r\nHost: api.test\r\n\r\n".to_slice,
    body: nil, source: Gori::FlowSource::Kind::Import))
end

# Three saved sessions, tab 1..3, named a/b/c.
private def seed_three(store) : Array(Int64)
  %w[a b c].map do |n|
    call_json(store, "create_repeater",
      %({"target":"https://#{n}.test","request":"GET /#{n} HTTP/1.1\\r\\nHost: #{n}.test\\r\\n\\r\\n","name":#{n.to_json}}))["id"].as_i64
  end
end

describe "MCP repeater tab numbers" do
  it "reports tui_index beside db_id, in the order the TUI paints the strip" do
    with_store do |store|
      ids = seed_three(store)
      sessions = call_json(store, "get_repeater_context", "{}")["sessions"].as_a
      sessions.map { |s| s["db_id"].as_i64 }.should eq(ids)
      sessions.map { |s| s["tui_index"].as_i }.should eq([1, 2, 3])
    end
  end

  it "numbers a session the same way RepeaterController#subtab_labels does" do
    with_store do |store|
      seed_three(store)
      rows = store.repeaters_meta
      # `subtab_labels` is `map_with_index { |tab, i| "#{i + 1}:…" }` over a list sorted by
      # {position, id} — pinned here so the MCP projection and the chip cannot drift.
      expected = rows.map_with_index { |r, i| {r.id, i + 1} }
      call_json(store, "get_repeater_context", "{}")["sessions"].as_a
        .map { |s| {s["db_id"].as_i64, s["tui_index"].as_i} }.should eq(expected)
    end
  end

  it "keeps the numbers ABSOLUTE when a filter narrows the listing" do
    with_store do |store|
      ids = seed_three(store)
      call_json(store, "update_repeaters", %({"ids":[#{ids[1]}],"tags_add":"idor"}))
      got = call_json(store, "get_repeater_context", %({"filter":"tag:idor"}))
      got["sessions"].as_a.size.should eq(1)
      # Tab 2, not tab 1: the TUI's own filtered strip reads with gaps, and renumbering here
      # would make an agent name a different chip than the operator sees.
      got["sessions"][0]["tui_index"].as_i.should eq(2)
    end
  end

  it "reports the number a session HAD when it is deleted, and that the rest shifted" do
    with_store do |store|
      ids = seed_three(store)
      j = call_json(store, "delete_repeater", %({"id":#{ids[1]}}))
      j["id"].as_i64.should eq(ids[1])
      j["name"].as_s.should eq("b")
      j["was_tui_index"].as_i.should eq(2)
      j["note"].as_s.should contain("shifted down")
      j["remaining"].as_i.should eq(2)
      # And the survivors are renumbered densely, so tab 2 is now `c`.
      store.repeaters.map(&.position).should eq([0, 1])
    end
  end

  it "does not renumber-note a delete that took the LAST tab" do
    with_store do |store|
      ids = seed_three(store)
      j = call_json(store, "delete_repeater", %({"id":#{ids[2]}}))
      j["was_tui_index"].as_i.should eq(3)
      j["note"]?.should be_nil
    end
  end

  it "carries tui_index on create and update" do
    with_store do |store|
      seed_three(store)
      created = call_json(store, "create_repeater",
        %({"target":"https://d.test","request":"GET /d HTTP/1.1\\r\\n\\r\\n"}))
      created["tui_index"].as_i.should eq(4)
      call_json(store, "update_repeater", %({"id":#{created["id"]},"name":"dee"}))["tui_index"].as_i.should eq(4)
    end
  end

  it "appends at the end even when the stored positions are sparse" do
    with_store do |store|
      first = seed_three(store)[0]
      # The shape a legacy project is in: positions {0, 1, 9}.
      store.set_repeater_positions([first])
      store.insert_repeater("https://z.test", "GET /z HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 9)
      j = call_json(store, "create_repeater",
        %({"target":"https://new.test","request":"GET /new HTTP/1.1\\r\\n\\r\\n"}))
      store.repeaters.last.id.should eq(j["id"].as_i64)
    end
  end
end

describe "MCP move_repeater" do
  it "moves a session to an absolute tab number and returns the resulting order" do
    with_store do |store|
      ids = seed_three(store)
      j = call_json(store, "move_repeater", %({"id":#{ids[2]},"to_index":1}))
      j["from_index"].as_i.should eq(3)
      j["to_index"].as_i.should eq(1)
      j["moved"].as_bool.should be_true
      j["order"].as_a.map { |r| r["id"].as_i64 }.should eq([ids[2], ids[0], ids[1]])
      j["order"].as_a.map { |r| r["tui_index"].as_i }.should eq([1, 2, 3])
      store.repeaters.map(&.id).should eq([ids[2], ids[0], ids[1]])
    end
  end

  it "nudges one place with direction" do
    with_store do |store|
      ids = seed_three(store)
      call_json(store, "move_repeater", %({"id":#{ids[0]},"direction":"down"}))
      store.repeaters.map(&.id).should eq([ids[1], ids[0], ids[2]])
      call_json(store, "move_repeater", %({"id":#{ids[0]},"direction":"up"}))
      store.repeaters.map(&.id).should eq([ids[0], ids[1], ids[2]])
    end
  end

  it "reports a no-op placement as a success, not a failure" do
    with_store do |store|
      ids = seed_three(store)
      j = call_json(store, "move_repeater", %({"id":#{ids[1]},"to_index":2}))
      j["moved"].as_bool.should be_false
      store.repeaters.map(&.id).should eq(ids)
    end
  end

  it "REFUSES an out-of-range to_index rather than clamping it" do
    with_store do |store|
      ids = seed_three(store)
      r = call_err(store, "move_repeater", %({"id":#{ids[0]},"to_index":9}))
      r.text.should contain("outside this workbench")
      r.text.should contain("1-3")
      store.repeaters.map(&.id).should eq(ids) # nothing moved
    end
  end

  it "refuses to_index and direction together" do
    with_store do |store|
      ids = seed_three(store)
      call_err(store, "move_repeater", %({"id":#{ids[0]},"to_index":2,"direction":"down"}))
        .text.should contain("not both")
    end
  end

  it "refuses a nudge past the end, naming where it already is" do
    with_store do |store|
      ids = seed_three(store)
      call_err(store, "move_repeater", %({"id":#{ids[2]},"direction":"down"}))
        .text.should contain("already at the end")
    end
  end

  it "refuses an unknown direction by naming the accepted values" do
    with_store do |store|
      ids = seed_three(store)
      call_err(store, "move_repeater", %({"id":#{ids[0]},"direction":"sideways"}))
        .text.should contain("up|down")
    end
  end

  it "reports NOT_FOUND for an id that is not a session" do
    with_store do |store|
      seed_three(store)
      call_err(store, "move_repeater", %({"id":9999,"to_index":1})).error_code.should eq("NOT_FOUND")
    end
  end
end

describe "MCP delete_repeaters" do
  it "refuses without confirm, naming the count, and deletes NOTHING" do
    with_store do |store|
      ids = seed_three(store)
      r = call_err(store, "delete_repeaters", %({"ids":[#{ids[0]},#{ids[1]}]}))
      r.error_code.should eq("CONFIRM_REQUIRED")
      r.text.should contain("2 repeater sessions")
      store.repeaters.size.should eq(3)
    end
  end

  it "refuses the WHOLE call when any id is unknown, with zero writes" do
    with_store do |store|
      ids = seed_three(store)
      r = call_err(store, "delete_repeaters", %({"ids":[#{ids[0]},4242],"confirm":true}))
      r.error_code.should eq("NOT_FOUND")
      r.text.should contain("4242")
      store.repeaters.size.should eq(3)
    end
  end

  it "deletes the named set, reports each tab's old number, and renumbers the rest" do
    with_store do |store|
      ids = seed_three(store)
      j = call_json(store, "delete_repeaters", %({"ids":[#{ids[0]},#{ids[2]}],"confirm":true}))
      j["deleted_count"].as_i.should eq(2)
      j["deleted"].as_a.map { |d| d["was_tui_index"].as_i }.should eq([1, 3])
      j["deleted"].as_a.map { |d| d["name"].as_s }.should eq(%w[a c])
      j["remaining"].as_i.should eq(1)
      j["order"].as_a.map { |r| r["tui_index"].as_i }.should eq([1])
      store.repeaters.map(&.id).should eq([ids[1]])
      store.repeaters.map(&.position).should eq([0])
    end
  end

  it "accepts a comma list and a bare id, and collapses a repeated id" do
    with_store do |store|
      ids = seed_three(store)
      call_json(store, "delete_repeaters", %({"ids":"#{ids[0]},#{ids[0]}","confirm":true}))["deleted_count"].as_i.should eq(1)
      call_json(store, "delete_repeaters", %({"ids":#{ids[1]},"confirm":true}))["deleted_count"].as_i.should eq(1)
      store.repeaters.map(&.id).should eq([ids[2]])
    end
  end

  it "names a non-integer entry instead of dropping it" do
    with_store do |store|
      seed_three(store)
      call_err(store, "delete_repeaters", %({"ids":["1","nope"],"confirm":true}))
        .text.should contain("nope")
      store.repeaters.size.should eq(3)
    end
  end

  it "refuses an empty ids list" do
    with_store do |store|
      seed_three(store)
      call_err(store, "delete_repeaters", %({"ids":[],"confirm":true})).error_code.should eq("INVALID_ARGUMENT")
    end
  end
end

describe "MCP update_repeaters" do
  it "adds tags to several sessions, keeping the ones they already had" do
    with_store do |store|
      ids = seed_three(store)
      call_json(store, "update_repeater", %({"id":#{ids[0]},"tags":"auth"}))
      j = call_json(store, "update_repeaters", %({"ids":[#{ids[0]},#{ids[1]}],"tags_add":"idor,#done"}))
      j["updated_count"].as_i.should eq(2)
      store.repeaters_mcp.find!(&.id.==(ids[0])).tags.should eq("auth idor done")
      store.repeaters_mcp.find!(&.id.==(ids[1])).tags.should eq("idor done")
      store.repeaters_mcp.find!(&.id.==(ids[2])).tags.should be_nil
    end
  end

  it "removes tags case-insensitively and clears the column when none are left" do
    with_store do |store|
      ids = seed_three(store)
      call_json(store, "update_repeaters", %({"ids":[#{ids[0]}],"tags_set":"IDOR auth"}))
      call_json(store, "update_repeaters", %({"ids":[#{ids[0]}],"tags_remove":"idor"}))
      store.repeaters_mcp.find!(&.id.==(ids[0])).tags.should eq("auth")
      call_json(store, "update_repeaters", %({"ids":[#{ids[0]}],"tags_remove":"AUTH"}))
      store.repeaters_mcp.find!(&.id.==(ids[0])).tags.should be_nil
    end
  end

  it "refuses tags_set together with tags_add" do
    with_store do |store|
      ids = seed_three(store)
      call_err(store, "update_repeaters", %({"ids":[#{ids[0]}],"tags_set":"x","tags_add":"y"}))
        .text.should contain("not both")
    end
  end

  it "refuses a call that would change nothing" do
    with_store do |store|
      ids = seed_three(store)
      call_err(store, "update_repeaters", %({"ids":[#{ids[0]}]})).text.should contain("nothing to change")
    end
  end

  it "affixes a stored name" do
    with_store do |store|
      ids = seed_three(store)
      j = call_json(store, "update_repeaters", %({"ids":[#{ids[0]}],"name_prefix":"[P1] ","name_suffix":" ✓"}))
      j["updated"][0]["name"].as_s.should eq("[P1] a ✓")
      j["updated"][0]["name_materialised"]?.should be_nil
      store.get_repeater(ids[0]).not_nil!.name.should eq("[P1] a ✓")
    end
  end

  it "NAMES the sessions whose derived label it had to materialise" do
    with_store do |store|
      id = call_json(store, "create_repeater",
        %({"target":"https://n.test","request":"POST /pay HTTP/1.1\\r\\nHost: n.test\\r\\n\\r\\n"}))["id"].as_i64
      j = call_json(store, "update_repeaters", %({"ids":[#{id}],"name_prefix":"[P1] "}))
      j["updated"][0]["name"].as_s.should eq("[P1] POST /pay")
      j["updated"][0]["name_materialised"].as_bool.should be_true
      j["name_materialised_note"].as_s.should contain("no longer follows the request")
    end
  end

  it "refuses the whole call when any id is unknown" do
    with_store do |store|
      ids = seed_three(store)
      r = call_err(store, "update_repeaters", %({"ids":[#{ids[0]},777],"tags_add":"x"}))
      r.error_code.should eq("NOT_FOUND")
      store.repeaters_mcp.find!(&.id.==(ids[0])).tags.should be_nil
    end
  end
end

describe "MCP create_repeaters" do
  it "seeds one tab per flow, in the order given, with a prefix and shared tags" do
    with_store do |store|
      f1 = seed_flow(store, "GET", "/one")
      f2 = seed_flow(store, "POST", "/two")
      j = call_json(store, "create_repeaters",
        %({"flow_ids":[#{f2},#{f1}],"name_prefix":"oas: ","tags":"spec"}))
      j["created_count"].as_i.should eq(2)
      j["created"].as_a.map { |c| c["flow_id"].as_i64 }.should eq([f2, f1])
      j["created"].as_a.map { |c| c["tui_index"].as_i }.should eq([1, 2])
      j["created"].as_a.map { |c| c["name"].as_s }.should eq(["oas: POST /two", "oas: GET /one"])
      store.repeaters_mcp.map(&.tags).should eq(["spec", "spec"])
      store.repeaters_mcp.map(&.flow_id).should eq([f2, f1])
    end
  end

  it "refuses the WHOLE call when any flow is unknown, creating nothing" do
    with_store do |store|
      f1 = seed_flow(store, "GET", "/one")
      r = call_err(store, "create_repeaters", %({"flow_ids":[#{f1},31337]}))
      r.error_code.should eq("NOT_FOUND")
      r.text.should contain("31337")
      store.repeaters.should be_empty
    end
  end

  it "appends after the sessions already in the workbench" do
    with_store do |store|
      existing = seed_three(store)
      f1 = seed_flow(store, "GET", "/one")
      j = call_json(store, "create_repeaters", %({"flow_ids":[#{f1}]}))
      j["created"][0]["tui_index"].as_i.should eq(4)
      store.repeaters.map(&.id).should eq(existing + [j["created"][0]["id"].as_i64])
    end
  end

  it "refuses an empty flow_ids list" do
    with_store do |store|
      call_err(store, "create_repeaters", %({"flow_ids":[]})).error_code.should eq("INVALID_ARGUMENT")
    end
  end
end
