require "../spec_helper"

describe Gori::Repeater::SendPersistence do
  it "stores the replayable HTTP/2 projection rather than the field dump" do
    fields = [
      {":method", "POST"},
      {":path", "/h2"},
      {":scheme", "https"},
      {":authority", "api.example.test"},
      {"content-type", "text/plain"},
    ]
    dump = Gori::Repeater::H2Engine.field_dump(fields, "body".to_slice)

    saved = Gori::Repeater::SendPersistence.replayable_request(fields, "dial.example.test", 443, dump)

    String.new(saved).should eq(
      "POST /h2 HTTP/2\r\nHost: api.example.test\r\ncontent-type: text/plain\r\n\r\nbody")
  end

  it "keeps wire values in the saved row and returns separate masked scan values" do
    with_store_env do |store|
      Gori::Env.save_project(store, [{"HOST", "api.secret.test"}, {"TOKEN", "token-value-1234"}])
      Gori::Env.load_project(store)
      target = "http://api.secret.test"
      request = "GET / HTTP/1.1\r\nHost: api.secret.test\r\nAuthorization: Bearer token-value-1234\r\n\r\n".to_slice
      response = Gori::Repeater::Result.new(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice,
        "ok".to_slice, nil, 12_i64, nil, false)

      saved = Gori::Repeater::SendPersistence.persist(store, "http", "api.secret.test", 80,
        request, false, false, nil, response)

      saved.id.should_not be_nil
      saved.target.should eq(target)
      saved.masked_target.should eq("http://$HOST")
      saved.request.should eq(request)
      saved.masked_request.should contain("$TOKEN")
      saved.response_saved?.should be_true
      row = store.get_repeater_full(saved.id.not_nil!).not_nil!
      row.target.should eq(target)
      row.request.should eq(request)
      row.response_head.should eq(response.head)
      row.response_body.should eq(response.body)
      row.response_request_sha256.should eq(Gori::Evidence.request_digest(request))
    end
  end

  it "brackets a bare IPv6 dial host so the saved target re-parses" do
    with_store do |store|
      response = Gori::Repeater::Result.new(
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".to_slice,
        Bytes.empty, nil, 1_i64, nil, false)

      saved = Gori::Repeater::SendPersistence.persist(store, "http", "::1", 8080,
        "GET / HTTP/1.1\r\nHost: [::1]:8080\r\n\r\n".to_slice, false, false, nil, response)

      saved.target.should eq("http://[::1]:8080")
      Gori::Repeater::FlowRequest.dial_target(saved.target).should eq({"http", "::1", 8080})
    end
  end
end
