require "../../spec_helper"
require "json"
require "compress/gzip"

# `--headers-only` / `--max-body` (#1119), `--path` (#1116) and `repeater create --format json`
# (#1117) on `gori run repeater`. The command bodies end in `exit`, so what is pinned is the
# pieces they are assembled from: the refusals, the prefix cut, and the JSON objects.
module Gori::CLI::Run
  def self.capped_repeater_json_for_spec(result : Repeater::Result, cap : BodyCap,
                                         request_target : String? = nil) : JSON::Any
    JSON.parse(repeater_json(result, nil, cap: cap, request_target: request_target))
  end

  def self.repeater_created_json_for_spec(store : Store, id : Int64, websocket : Bool = false,
                                          ws_messages : Int32 = 0, rewrote : Bool = false) : JSON::Any
    JSON.parse(repeater_created_json(store, id, websocket, ws_messages, rewrote))
  end

  def self.repeater_list_row_for_spec(store : Store, id : Int64) : JSON::Any
    rows = store.repeaters_mcp
    i = rows.index { |r| r.id == id }.not_nil!
    JSON.parse(JSON.build { |j| j.object { repeater_row_fields(j, rows[i], i + 1) } })
  end
end

private def ok_result(head : String, body : Bytes) : Gori::Repeater::Result
  Gori::Repeater::Result.new(head.to_slice, body, nil, 1000_i64, nil, false)
end

private BIG = ("a" * 100).to_slice

describe "gori run repeater — output caps and --path" do
  describe "refusals" do
    it "refuses --headers-only with --max-body" do
      Gori::CLI::Run.body_cap_error(true, 10).not_nil!.should contain("cannot be combined")
      Gori::CLI::Run.body_cap_error(true, nil).should be_nil
      Gori::CLI::Run.body_cap_error(false, 10).should be_nil
    end

    # `--max-body` cuts the body the diff still compares whole, so the two answers could not
    # be read against each other; the head-only diff is what `--headers-only --diff` means.
    it "refuses --max-body with --diff and allows --headers-only with it" do
      Gori::CLI::Run.output_diff_error(Gori::CLI::Run::BodyCap.new(max: 5), true).not_nil!.should contain("--diff")
      Gori::CLI::Run.output_diff_error(Gori::CLI::Run::BodyCap.new(omit: true), true).should be_nil
      Gori::CLI::Run.output_diff_error(Gori::CLI::Run::BodyCap.new(max: 5), false).should be_nil
    end

    it "refuses an empty --path, which would send a request line with no target" do
      Gori::CLI::Run.path_override_error("").not_nil!.should contain("--path")
      Gori::CLI::Run.path_override_error(nil).should be_nil
      Gori::CLI::Run.path_override_error("/x").should be_nil
    end
  end

  describe ".body_prefix" do
    it "cuts at the byte count, backing off a split UTF-8 sequence" do
      bytes = "aé".to_slice # 61 C3 A9
      Gori::CLI::Run.body_prefix(bytes, 2).should eq("a".to_slice)
      Gori::CLI::Run.body_prefix(bytes, 3).should eq(bytes)
      Gori::CLI::Run.body_prefix("abcdef".to_slice, 4).should eq("abcd".to_slice)
    end

    it "leaves a body within the cap untouched" do
      Gori::CLI::Run.body_prefix("abc".to_slice, 10).should eq("abc".to_slice)
    end
  end

  describe "the JSON body object" do
    head = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n"

    it "is unchanged when nothing caps it" do
      body = Gori::CLI::Run.capped_repeater_json_for_spec(ok_result(head, BIG), Gori::CLI::Run::BodyCap.new)["body"]
      body["size"].as_i.should eq(100)
      body["truncated"].as_bool.should be_false
      body["shown_size"]?.should be_nil
      body["text"].as_s.size.should eq(100)
    end

    it "keeps the whole size and the prefix under --max-body, and says it was cut" do
      body = Gori::CLI::Run.capped_repeater_json_for_spec(ok_result(head, BIG), Gori::CLI::Run::BodyCap.new(max: 10))["body"]
      body["size"].as_i.should eq(100)
      body["shown_size"].as_i.should eq(10)
      body["truncated"].as_bool.should be_true
      body["text"].as_s.should eq("a" * 10)
    end

    it "keeps the shape and drops the bytes under --headers-only" do
      body = Gori::CLI::Run.capped_repeater_json_for_spec(ok_result(head, BIG), Gori::CLI::Run::BodyCap.new(omit: true))["body"]
      body["omitted"].as_bool.should be_true
      body["size"].as_i.should eq(100)
      body["encoding"].as_s.should eq("text")
      body["text"]?.should be_nil
      body["base64"]?.should be_nil
    end

    # The cap applies to the DECODED body the output shows, so `size` is what an uncut dump
    # would have printed — not the compressed wire length.
    it "caps and sizes the decoded body of a gzip response" do
      io = IO::Memory.new
      Compress::Gzip::Writer.open(io, &.write(("z" * 500).to_slice))
      gz_head = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: #{io.size}\r\n\r\n"
      body = Gori::CLI::Run.capped_repeater_json_for_spec(ok_result(gz_head, io.to_slice), Gori::CLI::Run::BodyCap.new(max: 8))["body"]
      body["size"].as_i.should eq(500)
      body["shown_size"].as_i.should eq(8)
      body["text"].as_s.should eq("z" * 8)
    end

    it "names the --path it was sent to, and only then" do
      j = Gori::CLI::Run.capped_repeater_json_for_spec(ok_result(head, BIG), Gori::CLI::Run::BodyCap.new, "/api/v1/items/42")
      j["path"].as_s.should eq("/api/v1/items/42")
      Gori::CLI::Run.capped_repeater_json_for_spec(ok_result(head, BIG), Gori::CLI::Run::BodyCap.new)["path"]?.should be_nil
    end
  end

  describe "repeater create --format json (#1117)" do
    it "is the row `repeater list --format json` prints, plus what only create knows" do
      with_store do |store|
        id = store.insert_repeater(target: "https://api.example.test", request: "GET / HTTP/1.1\r\nHost: api.example.test\r\n\r\n".to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0)
        created = Gori::CLI::Run.repeater_created_json_for_spec(store, id, rewrote: true)
        listed = Gori::CLI::Run.repeater_list_row_for_spec(store, id)
        created["id"].as_i64.should eq(id)
        created["target"].as_s.should eq("https://api.example.test")
        created["http2"].as_bool.should be_false
        listed.as_h.each { |k, v| created[k].should eq(v) }
        (created.as_h.keys - listed.as_h.keys).should eq(["websocket", "request_line_rewritten"])
        created["websocket"].as_bool.should be_false
        created["request_line_rewritten"].as_bool.should be_true
      end
    end

    it "counts the frames a WebSocket session was created with" do
      with_store do |store|
        id = store.insert_repeater(target: "wss://ws.example.test", request: "GET /ws HTTP/1.1\r\nHost: ws.example.test\r\n\r\n".to_slice,
          http2: false, auto_cl: true, flow_id: nil, position: 0)
        created = Gori::CLI::Run.repeater_created_json_for_spec(store, id, websocket: true, ws_messages: 3)
        created["websocket"].as_bool.should be_true
        created["ws_messages"].as_i.should eq(3)
        created["request_line_rewritten"]?.should be_nil
      end
    end
  end

  it "previews a request line short and terminal-safe" do
    Gori::CLI::Run.request_line_preview("GET /\e[31mx HTTP/1.1\r\nHost: h\r\n\r\n".to_slice)
      .should eq(%("GET /⟨ESC⟩[31mx HTTP/1.1"))
  end
end
