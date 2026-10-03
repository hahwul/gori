require "../spec_helper"
require "../support/mcp_harness"

# The wordlist catalog over MCP (#1353): `list_wordlists`, `get_wordlist`, `save_wordlist`,
# `rename_wordlist`, `delete_wordlist`. The contract these pin is the security one — no VALUE
# leaves a list unless `include_values:true` asked for it, a name is a filename and never a
# path, no write is silent (overwrite and delete are explicit choices), every write sits
# behind the `write` permission group — plus that the tools work with no project bound,
# because the catalog is global.
private alias Catalog = Gori::WordlistCatalog

private def unbound_tools(allow_actions = true, denied : Set(String)? = nil) : Gori::MCP::Tools
  Gori::MCP::Tools.new(nil, allow_actions: allow_actions, verify_upstream: false, denied_permissions: denied)
end

private def call(tools, name : String, args : String) : Gori::MCP::Tools::Result
  tools.call(name, JSON.parse(args))
end

private def ok(tools, name : String, args : String) : JSON::Any
  r = call(tools, name, args)
  fail "#{name} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

describe "MCP wordlist catalog" do
  it "works with no project bound: listing, saving, reading, renaming, deleting" do
    with_wordlist_home do
      t = unbound_tools
      ok(t, "save_wordlist", %({"name":"a.txt","values":["one","two"]}))["values"].as_i.should eq(2)
      ok(t, "list_wordlists", "{}")["wordlists"].as_a.map(&.["name"].as_s).should eq(["a.txt"])
      ok(t, "get_wordlist", %({"name":"a.txt"}))["lines"].as_i64.should eq(2_i64)
      ok(t, "rename_wordlist", %({"name":"a.txt","new_name":"b.txt"}))["renamed_from"].as_s.should eq("a.txt")
      ok(t, "delete_wordlist", %({"name":"b.txt","confirm":true}))["deleted"].as_s.should eq("b.txt")
      ok(t, "list_wordlists", "{}")["wordlists"].as_a.should be_empty
    end
  end

  describe "list_wordlists / get_wordlist never return a value by default" do
    it "lists metadata only" do
      with_wordlist_home do |dir|
        Catalog.save_values("creds.txt", ["hunter2-marker", "letmein-marker"])
        r = call(unbound_tools, "list_wordlists", "{}")
        r.text.should_not contain("hunter2-marker")
        j = JSON.parse(r.text)
        j["directory"].as_s.should eq(dir)
        row = j["wordlists"].as_a.first
        row["name"].as_s.should eq("creds.txt")
        row["bytes"].as_i64.should eq(30_i64)
        row["modified_at"].as_s.should match(/\A\d{4}-\d\d-\d\dT/)
        row.as_h.keys.should eq(%w[name bytes modified_at symlink])
        j["truncated"].as_bool.should be_false
      end
    end

    it "gives get_wordlist's metadata without values unless include_values:true" do
      with_wordlist_home do
        Catalog.save_values("creds.txt", ["hunter2-marker", "letmein-marker", "third"])
        t = unbound_tools
        plain = call(t, "get_wordlist", %({"name":"creds.txt"}))
        plain.text.should_not contain("hunter2-marker")
        JSON.parse(plain.text)["preview"]?.should be_nil
        both = ok(t, "get_wordlist", %({"name":"creds.txt","include_values":true,"max_lines":2}))
        both["preview"].as_a.map(&.as_s).should eq(["hunter2-marker", "letmein-marker"])
        both["preview_truncated"].as_bool.should be_true
        both["lines"].as_i64.should eq(3_i64)
        both["lines_complete"].as_bool.should be_true
      end
    end

    it "keeps the reply valid JSON for a value that is not UTF-8, and says so" do
      with_wordlist_home do
        Catalog.save_io("bin.txt", IO::Memory.new(Bytes[0x61, 0xff, 0x0a, 0x62, 0x0a]))
        r = call(unbound_tools, "get_wordlist", %({"name":"bin.txt","include_values":true}))
        r.text.valid_encoding?.should be_true
        j = JSON.parse(r.text)
        j["preview"].as_a.size.should eq(2)
        j["preview_scrubbed_lines"].as_i.should eq(1)
      end
    end

    it "caps the preview and the listing" do
      with_wordlist_home do
        Catalog.save_values("big.txt", (1..500).map(&.to_s))
        5.times { |i| Catalog.save_values("l#{i}.txt", ["x"]) }
        t = unbound_tools
        ok(t, "get_wordlist", %({"name":"big.txt","include_values":true,"max_lines":100000}))["preview"].as_a.size.should eq(200)
        l = ok(t, "list_wordlists", %({"limit":3}))
        l["returned"].as_i.should eq(3)
        l["truncated"].as_bool.should be_true
      end
    end
  end

  describe "save_wordlist" do
    it "keeps every value exactly, including blank and `#` lines" do
      with_wordlist_home do |dir|
        ok(unbound_tools, "save_wordlist", %({"name":"p.txt","values":["a","","# b","  c  ",12345]}))
        File.read(File.join(dir, "p.txt")).should eq("a\n\n# b\n  c  \n12345\n")
      end
    end

    it "refuses to replace unless overwrite:true, and says which argument" do
      with_wordlist_home do |dir|
        t = unbound_tools
        ok(t, "save_wordlist", %({"name":"p.txt","values":["first"]}))["replaced"].as_bool.should be_false
        r = call(t, "save_wordlist", %({"name":"p.txt","values":["second"]}))
        r.is_error.should be_true
        r.error_code.should eq("INVALID_ARGUMENT")
        r.field.should eq("name")
        r.text.should contain("overwrite:true")
        File.read(File.join(dir, "p.txt")).should eq("first\n")
        ok(t, "save_wordlist", %({"name":"p.txt","values":["second"],"overwrite":true}))["replaced"].as_bool.should be_true
        File.read(File.join(dir, "p.txt")).should eq("second\n")
      end
    end

    it "refuses a name that is a path, and writes nothing outside the catalog" do
      with_wordlist_home do |dir|
        ["../escape.txt", "a/b.txt", "/tmp/abs.txt", ".hidden", "..", ""].each do |bad|
          r = call(unbound_tools, "save_wordlist", {"name" => bad, "values" => ["x"]}.to_json)
          r.is_error.should be_true
          r.error_code.should eq("INVALID_ARGUMENT")
        end
        File.exists?(File.join(File.dirname(dir), "escape.txt")).should be_false
        Dir.exists?(dir).should be_false
      end
    end

    it "refuses a value that cannot be one line, and an empty or non-array values" do
      with_wordlist_home do
        t = unbound_tools
        r = call(t, "save_wordlist", %({"name":"p.txt","values":["ok","two\\nlines"]}))
        r.is_error.should be_true
        r.field.should eq("values")
        r.text.should contain("value 2")
        call(t, "save_wordlist", %({"name":"p.txt","values":[]})).is_error.should be_true
        call(t, "save_wordlist", %({"name":"p.txt","values":"[1,2]"})).text.should contain("array of strings")
        call(t, "save_wordlist", %({"name":"p.txt","values":[["nested"]]})).is_error.should be_true
        call(t, "save_wordlist", %({"name":"p.txt"})).text.should contain("missing required 'values'")
        Catalog.list.entries.should be_empty
      end
    end

    it "does not split a value that looks like a JSON array" do
      with_wordlist_home do |dir|
        ok(unbound_tools, "save_wordlist", %({"name":"p.txt","values":["[1,2]"]}))
        File.read(File.join(dir, "p.txt")).should eq("[1,2]\n")
      end
    end
  end

  describe "rename_wordlist" do
    it "refuses to replace unless overwrite:true" do
      with_wordlist_home do |dir|
        t = unbound_tools
        Catalog.save_values("a.txt", ["A"])
        Catalog.save_values("b.txt", ["B"])
        r = call(t, "rename_wordlist", %({"name":"a.txt","new_name":"b.txt"}))
        r.is_error.should be_true
        r.text.should contain("overwrite:true")
        File.read(File.join(dir, "b.txt")).should eq("B\n")
        ok(t, "rename_wordlist", %({"name":"a.txt","new_name":"b.txt","overwrite":true}))
        File.read(File.join(dir, "b.txt")).should eq("A\n")
      end
    end

    it "answers NOT_FOUND for a missing list and refuses an escaping new name" do
      with_wordlist_home do
        Catalog.save_values("a.txt", ["A"])
        call(unbound_tools, "rename_wordlist", %({"name":"nope.txt","new_name":"b.txt"})).error_code.should eq("NOT_FOUND")
        call(unbound_tools, "rename_wordlist", %({"name":"a.txt","new_name":"../b.txt"})).error_code.should eq("INVALID_ARGUMENT")
        call(unbound_tools, "rename_wordlist", %({"name":"a.txt"})).text.should contain("missing required 'new_name'")
      end
    end
  end

  describe "delete_wordlist" do
    it "refuses without confirm:true and reports what it would remove" do
      with_wordlist_home do |dir|
        Catalog.save_values("a.txt", ["A"])
        r = call(unbound_tools, "delete_wordlist", %({"name":"a.txt"}))
        r.is_error.should be_true
        r.error_code.should eq("CONFIRM_REQUIRED")
        r.text.should contain("a.txt")
        File.exists?(File.join(dir, "a.txt")).should be_true
        call(unbound_tools, "delete_wordlist", %({"name":"a.txt","confirm":"nope"})).is_error.should be_true
        File.exists?(File.join(dir, "a.txt")).should be_true
      end
    end

    it "answers NOT_FOUND, and never reaches outside the catalog" do
      with_wordlist_home do |dir|
        Dir.mkdir_p(dir)
        outside = File.join(File.dirname(dir), "outside.txt")
        File.write(outside, "x\n")
        call(unbound_tools, "delete_wordlist", %({"name":"nope.txt","confirm":true})).error_code.should eq("NOT_FOUND")
        call(unbound_tools, "delete_wordlist", %({"name":"../outside.txt","confirm":true})).error_code.should eq("INVALID_ARGUMENT")
        File.exists?(outside).should be_true
      end
    end
  end

  describe "permissions" do
    it "hides the writes under --read-only and keeps the reads" do
      names = JSON.parse(JSON.build { |j| unbound_tools(allow_actions: false).list(j) }).as_a.map(&.["name"].as_s)
      names.should contain("list_wordlists")
      names.should contain("get_wordlist")
      %w[save_wordlist rename_wordlist delete_wordlist].each { |w| names.should_not contain(w) }
    end

    it "puts every write behind the `write` group, and no read behind anything" do
      %w[save_wordlist rename_wordlist delete_wordlist].each do |w|
        Gori::MCP::Tools::TOOL_PERMISSIONS[w]?.should eq("write")
        Gori::MCP::Tools::AGENT_ACTION_TOOLS.includes?(w).should be_true
      end
      %w[list_wordlists get_wordlist].each { |r| Gori::MCP::Tools::TOOL_PERMISSIONS.has_key?(r).should be_false }
    end

    it "refuses the writes when the `write` group is off, and changes nothing" do
      with_wordlist_home do
        t = unbound_tools(denied: Set{"write"})
        r = call(t, "save_wordlist", %({"name":"p.txt","values":["x"]}))
        r.is_error.should be_true
        r.error_code.should eq("TOOL_DISABLED")
        Catalog.list.entries.should be_empty
        ok(t, "list_wordlists", "{}") # reading is never switched
      end
    end
  end

  it "logs a write to a bound project's agent feed" do
    with_wordlist_home do
      with_store do |store|
        ok(tools_for(store), "save_wordlist", %({"name":"p.txt","values":["x"]}))
        store.events_recent(10).rows.any? { |e| e.kind == "agent_action" && e.message.includes?("save_wordlist") }.should be_true
      end
    end
  end

  # This server's stdin is its transport: `/dev/stdin` as a wordlist read the JSON-RPC stream
  # as payloads and hung the server. `/dev/null` stands in for every non-regular file.
  it "refuses a wordlist that is not a regular file, on every tool that reads one" do
    with_store do |store|
      tools = tools_for(store)
      flask = "eyJhIjoxfQ.aGVsbG8.c2ln"
      template = "GET /§x§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_json
      [{"cookie_crack", %({"cookie":#{flask.to_json},"wordlist":"/dev/null"})},
       {"fuzz_start", %({"template":#{template},"allow_unscoped":true,"payloads":[{"wordlist":"/dev/null"}]})},
       {"fuzz_start", %({"template":#{template},"allow_unscoped":true,"payloads":[{"preset":"sqli","file":"/dev/null"}]})},
       {"mine_start", %({"template":#{template},"allow_unscoped":true,"wordlist":"/dev/null"})},
       {"discover_start", %({"url":"http://127.0.0.1:9/","allow_unscoped":true,"wordlist":"/dev/null"})},
      ].each do |name, args|
        r = call(tools, name, args)
        r.is_error.should be_true
        r.text.should contain("not a regular file")
      end
      File.tempfile("wl") do |f|
        f.puts "nope"
        f.flush
        call(tools, "cookie_crack", %({"cookie":#{flask.to_json},"wordlist":#{f.path.to_json}})).is_error.should be_false
      end
    end
  end
end
