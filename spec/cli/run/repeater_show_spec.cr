require "../../spec_helper"

module Gori::CLI::Run
  def self.repeater_row_json_for_spec(r : Store::RepeaterRecord) : JSON::Any
    JSON.parse(JSON.build { |j| j.object { repeater_row_fields(j, r, 1) } })
  end

  def self.repeater_show_sides_for_spec(rec : Store::RepeaterRecord, matcher : Redact::Matcher?)
    repeater_show_sides(rec, matcher)
  end
end

private REQ = "POST /login HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\nabc".to_slice

private def seed_session(store : Gori::Store) : Int64
  store.insert_repeater(target: "http://127.0.0.1:1", request: REQ,
    http2: false, auto_cl: true, flow_id: nil, position: 0)
end

private def answer(store : Gori::Store, id : Int64, request : Bytes = REQ,
                   head : String = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 6\r\n\r\n",
                   body : Bytes = "denied".to_slice) : Nil
  store.update_repeater_response(id, head.to_slice, body, nil, 708_i64,
    request_sha256: Gori::Evidence.request_digest(request))
end

private def listed(store : Gori::Store, id : Int64) : Gori::Store::RepeaterRecord
  store.repeaters_mcp.find!(&.id.==(id))
end

# `gori run repeater list` / `show` (#1665): a saved session's last response, read headless
# without re-sending it.
describe "gori run repeater list/show" do
  it "lists the last status, stored body size and summary, null when never answered" do
    with_store do |store|
      id = seed_session(store)
      row = Gori::CLI::Run.repeater_row_json_for_spec(listed(store, id))
      row["summary"].as_s.should eq("POST /login")
      row["last_status"].raw.should be_nil
      row["last_size"].raw.should be_nil

      answer(store, id)
      row = Gori::CLI::Run.repeater_row_json_for_spec(listed(store, id))
      row["last_status"].as_i.should eq(401)
      row["last_size"].as_i.should eq(6)
      row["last_duration_us"].as_i.should eq(708)
    end
  end

  it "shows the stored request and response, and null for a session never sent" do
    with_store do |store|
      id = seed_session(store)
      json = ->(drifted : Bool) {
        rec = store.get_repeater_full(id).not_nil!
        head = rec.response_head
        JSON.parse(Gori::CLI::Run.repeater_show_json(listed(store, id), 1, REQ[0, REQ.size - 3], REQ[REQ.size - 3, 3],
          head, head && rec.response_body, drifted))
      }
      doc = json.call(false)
      doc["request"]["head"].as_s.should start_with("POST /login HTTP/1.1\r\n")
      doc["request"]["body"]["text"].as_s.should eq("abc")
      doc["response"].raw.should be_nil
      doc["request_drifted"]?.should be_nil

      answer(store, id)
      doc = json.call(true)
      doc["response"]["status"].as_i.should eq(401)
      doc["response"]["reason"].as_s.should eq("Unauthorized")
      doc["response"]["body"]["text"].as_s.should eq("denied")
      doc["request_drifted"].as_bool.should be_true
    end
  end

  it "sizes an answered empty body 0, not as never answered (an empty body is stored as NULL)" do
    with_store do |store|
      id = seed_session(store)
      answer(store, id, head: "HTTP/1.1 204 No Content\r\n\r\n", body: Bytes.empty)
      row = Gori::CLI::Run.repeater_row_json_for_spec(listed(store, id))
      row["last_status"].as_i.should eq(204)
      row["last_size"].as_i.should eq(0)
    end
  end

  it "splits the stored request and sanitizes both sides under a redaction profile" do
    with_store do |store|
      req = "POST /x HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\"password\":\"hunter2\"}".to_slice
      id = store.insert_repeater(target: "http://127.0.0.1:1", request: req,
        http2: false, auto_cl: true, flow_id: nil, position: 0)
      rec = store.get_repeater_full(id).not_nil!
      req_head, req_body, resp_head, _, report = Gori::CLI::Run.repeater_show_sides_for_spec(rec, nil)
      String.new(req_head).should end_with("\r\n\r\n")
      String.new(req_body.not_nil!).should contain("hunter2")
      resp_head.should be_nil
      report.should be_nil

      matcher = Gori::Redact::Policy.resolve(store, nil, true).matcher.not_nil!
      _, req_body, resp_head, _, report = Gori::CLI::Run.repeater_show_sides_for_spec(rec, matcher)
      String.new(req_body.not_nil!).should_not contain("hunter2")
      String.new(req_body.not_nil!).should contain("[REDACTED")
      resp_head.should be_nil
      report.not_nil!.count.should be > 0
    end
  end
end
