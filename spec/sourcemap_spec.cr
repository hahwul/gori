require "./spec_helper"
require "base64"

private alias SM = Gori::Sourcemap

private CLOCK = [1_700_000_000_000_000_i64]

# A captured JS exchange whose RESPONSE is `body`, so `Sourcemap.unpack` can read its
# sourceMappingURL. `host` is the bundle's origin; the base recovered sources resolve against.
private def sm_flow(store : Gori::Store, body : String, *, host = "shop.test",
                    target = "/app.js", resp_headers = "") : Gori::Store::FlowDetail
  CLOCK[0] += 1000
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: CLOCK[0], scheme: "https", host: host, port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: application/javascript\r\n#{resp_headers}\r\n".to_slice,
    body: body.to_slice, content_type: "application/javascript"))
  store.flush
  store.get_flow(id).not_nil!
end

# A minimal source map whose single original source holds `source`.
private def sm_map(source : String, name = "src/api.js") : String
  {version: 3, sources: [name], sourcesContent: [source]}.to_json
end

private SOURCE = <<-JS
  export function load() {
    return fetch("/api/v1/secret").then(r => r.json());
  }
  export const admin = () => axios.get('/internal/admin/users');
  JS

private def base : Gori::Discover::Url::Parts
  Gori::Discover::Url.parse("https://shop.test/app.js").not_nil!
end

describe Gori::Sourcemap do
  describe ".endpoints" do
    it "recovers the endpoints hidden in a map's original sources" do
      refs, sources, scap, rcap = SM.endpoints(sm_map(SOURCE), base, Gori::JsRefs::Base::Referer)
      sources.should eq(1)
      scap.should be_false
      rcap.should be_false
      refs.map(&.path).sort!.should eq(["/api/v1/secret", "/internal/admin/users"])
      refs.all? { |r| r.host == "shop.test" }.should be_true
    end

    it "returns nothing for a map that is not a JSON object (bounded, no raise)" do
      SM.endpoints("[1,2,3]", base, Gori::JsRefs::Base::Referer)[0].should be_empty
      SM.endpoints("not json at all", base, Gori::JsRefs::Base::Referer)[0].should be_empty
      # A sourcesContent entry that is null (content omitted) is skipped, not a crash.
      m = {version: 3, sources: ["a.js"], sourcesContent: [nil]}.to_json
      SM.endpoints(m, base, Gori::JsRefs::Base::Referer)[0].should be_empty
    end

    it "deduplicates endpoints seen across several sources" do
      m = {version: 3, sources: ["a.js", "b.js"],
           sourcesContent: [%(fetch("/dup")), %(fetch("/dup");fetch("/only-b"))]}.to_json
      refs, _, _, _ = SM.endpoints(m, base, Gori::JsRefs::Base::Referer)
      refs.map(&.path).sort!.should eq(["/dup", "/only-b"])
    end
  end

  describe ".reference" do
    it "reads the //# sourceMappingURL comment from the body" do
      with_store do |store|
        detail = sm_flow(store, "var x=1;\n//# sourceMappingURL=app.js.map\n")
        SM.reference(detail).should eq("app.js.map")
      end
    end

    it "reads the SourceMap response header" do
      with_store do |store|
        detail = sm_flow(store, "var x=1;", resp_headers: "SourceMap: /maps/app.js.map\r\n")
        SM.reference(detail).should eq("/maps/app.js.map")
      end
    end

    it "is nil when the response names no map" do
      with_store do |store|
        SM.reference(sm_flow(store, "var x=1;")).should be_nil
      end
    end
  end

  describe ".unpack" do
    it "parses an inline data: source map in place without any fetch and stores the endpoints" do
      with_store do |store|
        b64 = Base64.strict_encode(sm_map(SOURCE))
        detail = sm_flow(store, "var x=1;\n//# sourceMappingURL=data:application/json;base64,#{b64}\n")
        report = SM.unpack(store, detail, ungated_outbound)
        report.error.should be_nil
        report.origin.should eq(Gori::Sourcemap::Origin::Inline)
        report.refs.map(&.path).sort!.should eq(["/api/v1/secret", "/internal/admin/users"])
        report.stored.should be_true
        # Stored against the flow → visible to the JS-reference listing.
        store.js_ref_sightings(host: "shop.test").map(&.path).sort!.should eq(["/api/v1/secret", "/internal/admin/users"])
      end
    end

    it "refuses to fetch an out-of-scope .map and recovers nothing" do
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "shop.test") # the bundle's host, NOT the map's
        detail = sm_flow(store, "var x=1;\n//# sourceMappingURL=https://cdn.evil.test/app.js.map\n")
        report = SM.unpack(store, detail, Gori::Outbound.agent(scope, false))
        report.error.should_not be_nil
        report.error.not_nil!.should start_with(Gori::Repeater::Sender::SCOPE_REFUSAL_PREFIX)
        report.refs.should be_empty
        report.stored.should be_false
        store.js_ref_sightings.should be_empty
      end
    end

    it "reports a clean no-op when the response names no source map" do
      with_store do |store|
        report = SM.unpack(store, sm_flow(store, "var x=1;"), ungated_outbound)
        report.refs.should be_empty
        report.origin.should be_nil
        report.error.should eq("no source map reference in this response")
      end
    end
  end
end
