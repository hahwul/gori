require "../spec_helper"

include Gori::Tui

# `RepeaterView#status_token` — the LIVE half of the sub-tab filter's `status:` field.
#
# The stored-row half (`SubtabFilter::Subject.from_row`, which MCP's `get_repeater_context
# {filter}` reads) is covered in spec/mcp/repeater_filter_spec.cr. Both must spell one
# session the same way, or the operator's `/` and an agent's `filter` would answer
# differently about the same tab — which is why both go through `Subject.status_token`.
describe "RepeaterView#status_token" do
  it "reads unsent before anything has been sent" do
    RepeaterView.new.status_token.should eq("unsent")
  end

  it "reads the status code of a restored response" do
    view = RepeaterView.new
    view.restore("https://h.test", "GET / HTTP/1.1\r\n\r\n", false, true,
      response_head: "HTTP/1.1 403 Forbidden\r\n\r\n".to_slice)
    view.status_token.should eq("403")
  end

  it "reads error when the send itself failed, even with a head from an earlier send" do
    view = RepeaterView.new
    view.restore("https://h.test", "GET / HTTP/1.1\r\n\r\n", false, true,
      response_head: "HTTP/1.1 200 OK\r\n\r\n".to_slice,
      response_error: "connection refused")
    view.status_token.should eq("error")
  end

  it "agrees with the stored-row projection for the same session" do
    path = File.tempname("gori-rvstatus", ".db")
    store = Gori::Store.open(path)
    begin
      id = store.insert_repeater("https://h.test", "GET / HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
      store.update_repeater_response(id, "HTTP/1.1 502 Bad Gateway\r\n\r\n".to_slice, nil, nil, 5_i64)
      row = store.repeaters.first

      view = RepeaterView.new
      view.restore(row.target, String.new(row.request), row.http2?, row.auto_content_length?,
        response_head: row.response_head, response_body: row.response_body,
        response_error: row.response_error, response_duration_us: row.response_duration_us)

      view.status_token.should eq(Gori::Repeater::SubtabFilter::Subject.from_row(row).status)
      view.status_token.should eq("502")
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end
end
