require "../spec_helper"
require "../support/mcp_harness"

# The docs playbooks served as MCP prompts (#1596, src/gori/mcp/prompts.cr).

private PLAYBOOK_DIR = File.expand_path("../../docs/content/playbooks", __DIR__)

private MODERN_META = %("_meta":{"io.modelcontextprotocol/protocolVersion":"#{Gori::MCP::Protocol::LATEST}",) +
                      %("io.modelcontextprotocol/clientCapabilities":{}})

# Drives a server over `lines` (after a legacy handshake) and returns the reply to id 7, plus
# the names `tools/list` carried, so a prompt can be checked against the catalogue it runs on.
private def prompt_call(store, line : String, *, allow_actions = true, tools : String? = nil) : {JSON::Any, Set(String)}
  filter = tools.try do |sp|
    Gori::MCP::ToolFilter.parse(sp, Gori::MCP::Tools::TOOL_NAMES, Gori::MCP::Tools::TOOL_DEPENDENCIES)
  end
  filter.should_not be_a(String) if tools
  input = IO::Memory.new(
    %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}) + "\n" +
    %({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}) + "\n" + line + "\n")
  output = IO::Memory.new
  Gori::MCP::Server.new(store, allow_actions: allow_actions, verify_upstream: false,
    tool_filter: filter.as(Gori::MCP::ToolFilter?), input: input, output: output).run
  lines = output.to_s.each_line.reject(&.strip.empty?).map { |l| JSON.parse(l) }.to_a
  names = lines.find! { |l| l["id"]? == 2 }["result"]["tools"].as_a.map(&.["name"].as_s).to_set
  {lines.find! { |l| l["id"]? == 7 }, names}
end

private def get_prompt(name : String, args : String? = nil) : String
  %({"jsonrpc":"2.0","id":7,"method":"prompts/get","params":{"name":#{name.to_json}#{%(,"arguments":#{args}) if args}}})
end

private def prompt_text(resp : JSON::Any) : String
  resp["result"]["messages"][0]["content"]["text"].as_s
end

describe Gori::MCP::Prompts do
  it "serves or skips every English playbook, so a new one cannot go unnoticed" do
    on_disk = Dir.children(PLAYBOOK_DIR)
      .select { |f| f.ends_with?(".md") && !f.ends_with?(".ko.md") && !f.starts_with?("_") }
      .map(&.rchop(".md")).to_set
    served = Gori::MCP::Prompts::RAW.keys.to_set
    skipped = Gori::MCP::Prompts::SKIPPED.keys.to_set
    (served & skipped).should be_empty
    missing = on_disk - served - skipped
    missing.should be_empty, "playbooks neither served nor in SKIPPED (src/gori/mcp/prompts.cr): #{missing.to_a.sort.join(", ")}"
    gone = (served | skipped) - on_disk
    gone.should be_empty, "prompts.cr names playbooks that no longer exist: #{gone.to_a.sort.join(", ")}"
  end

  it "parses every served playbook into title, description and a browser-free body" do
    Gori::MCP::Prompts.all.each do |pb|
      raw = File.read(File.join(PLAYBOOK_DIR, "#{pb.name}.md"))
      raw.should contain(%(title = "#{pb.title}"))
      raw.should contain(%(description = "#{pb.description}"))
      pb.title.should_not be_empty
      pb.body.should_not contain("+++")
      pb.body.should_not contain("<figure")
      pb.body.should_not match(/\{#[\w-]+\}/)
      pb.body.should_not contain("](/")
      pb.body.should eq(pb.body.strip)
    end
  end

  it "strips figures and heading anchors and makes site links absolute, nothing else" do
    raw = <<-MD
      +++
      title = "Say \\"hi\\""
      description = "A test."
      weight = 1
      +++

      Intro, see [Guide](/guide/x/#y) and [elsewhere](https://e.com/).

      <figure class="tui-shot">
        <img src="/images/x.png">
      </figure>

      ## Step one {#step-one}

      `{#not-a-heading}` stays mid-line.
      MD
    pb = Gori::MCP::Prompts.parse("t", raw)
    pb.title.should eq(%(Say "hi"))
    pb.description.should eq("A test.")
    pb.body.should eq("Intro, see [Guide](https://gori.hahwul.com/guide/x/#y) and [elsewhere](https://e.com/).\n\n" \
                      "## Step one\n\n`{#not-a-heading}` stays mid-line.")
  end
end

describe "MCP prompts" do
  it "advertises prompts with listChanged false on every handshake revision" do
    with_store do |store|
      Gori::MCP::Protocol::LEGACY_VERSIONS.each do |v|
        out = mcp_drive(store, %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"#{v}"}}))
        out[0]["result"]["capabilities"]["prompts"]["listChanged"].as_bool.should be_false
      end
    end
  end

  it "lists one prompt per served playbook, named by slug, with one optional focus argument" do
    with_store do |store|
      resp, _ = prompt_call(store, %({"jsonrpc":"2.0","id":7,"method":"prompts/list","params":{"cursor":null}}))
      rows = resp["result"]["prompts"].as_a
      rows.map(&.["name"].as_s).should eq(Gori::MCP::Prompts::RAW.keys)
      row = rows.find! { |r| r["name"] == "test-access-control" }
      row["title"].as_s.should eq("Test access control")
      row["description"].as_s.should start_with("Replay the requests you captured")
      row["arguments"].as_a.map(&.["name"].as_s).should eq(["focus"])
      row["arguments"][0]["required"].as_bool.should be_false
      resp["result"]["ttlMs"]?.should be_nil
    end
  end

  it "refuses a cursor it never issued" do
    with_store do |store|
      resp, _ = prompt_call(store, %({"jsonrpc":"2.0","id":7,"method":"prompts/list","params":{"cursor":"p2"}}))
      resp["error"]["code"].as_i.should eq(-32602)
    end
  end

  it "carries the modern envelope and cache hints on the stateless revision" do
    with_store do |store|
      line = %({"jsonrpc":"2.0","id":7,"method":"prompts/list","params":{#{MODERN_META}}})
      res = mcp_drive(store, line).find! { |l| l["id"]? == 7 }["result"]
      res["resultType"].as_s.should eq("complete")
      res["ttlMs"].as_i.should eq(Gori::MCP::Protocol::TOOLS_LIST_TTL_MS)
      res["cacheScope"].as_s.should eq(Gori::MCP::Protocol::CACHE_SCOPE)
      res["prompts"].as_a.size.should eq(Gori::MCP::Prompts::RAW.size)
    end
  end

  it "returns the playbook body after the preamble, with focus verbatim on its own line" do
    with_store do |store|
      focus = %(api.example.com/v1 "flow 12")
      resp, _ = prompt_call(store, get_prompt("attack-a-jwt", {focus: focus}.to_json))
      res = resp["result"]
      res["description"].as_s.should eq(Gori::MCP::Prompts["attack-a-jwt"]?.not_nil!.description)
      res["messages"].as_a.size.should eq(1)
      res["messages"][0]["role"].as_s.should eq("user")
      text = prompt_text(resp)
      text.should start_with(Gori::MCP::Prompts::PREAMBLE)
      text.should contain(Gori::MCP::Prompts["attack-a-jwt"]?.not_nil!.body)
      text.should_not contain("<figure")
      text.should contain("](https://gori.hahwul.com/")
      text.should end_with("\n\nFocus: #{focus}")

      bare, _ = prompt_call(store, get_prompt("attack-a-jwt"))
      prompt_text(bare).should_not contain("Focus:")
    end
  end

  it "refuses an unknown prompt, non-object arguments and a non-string focus with -32602" do
    with_store do |store|
      prompt_call(store, get_prompt("nope"))[0]["error"]["code"].as_i.should eq(-32602)
      prompt_call(store, get_prompt("run-an-ai-co-pilot"))[0]["error"]["code"].as_i.should eq(-32602)
      prompt_call(store, get_prompt("attack-a-jwt", %({"focus":3})))[0]["error"]["code"].as_i.should eq(-32602)
      prompt_call(store, get_prompt("attack-a-jwt", %("api.example.com")))[0]["error"]["code"].as_i.should eq(-32602)
    end
  end

  # The body is the docs' text and names tools as the docs do; the preamble is gori's own and
  # is held to the instructions' rule: never send the agent toward a tool tools/list lacks.
  it "says what kind of server it runs on, and its preamble names only listed tools" do
    with_store do |store|
      {
        {true, nil, nil},
        {false, nil, "--read-only"},
        {true, "@minimal", "--tools=@minimal"},
        {false, "@minimal", "--read-only"},
        {true, "list_*", "--tools=list_*"},
      }.each do |allow, tools, expect|
        resp, listed = prompt_call(store, get_prompt("fuzz-a-parameter"), allow_actions: allow, tools: tools)
        preamble = prompt_text(resp).split("\n\n", 2)[0]
        if expect
          preamble.should contain(expect)
        else
          preamble.should_not contain("--read-only")
          preamble.should_not contain("--tools")
        end
        named = Gori::MCP::Tools::TOOL_NAMES.select { |n| preamble.matches?(/\b#{Regex.escape(n)}\b/) }.to_set
        (named - listed).should be_empty, "preamble under #{tools.inspect}/#{allow} names #{(named - listed).to_a.join(", ")}"
        if listed.includes?("ask_operator")
          preamble.should contain("ask_operator")
        else
          preamble.should contain("named and skipped")
        end
      end
    end
  end
end
