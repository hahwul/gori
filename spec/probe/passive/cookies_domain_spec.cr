require "../../spec_helper"

# --- file-local harness (mirrors spec/probe/passive/jwt_spec.cr's private with_store/capture_flow) ---

private def capture_flow(store, resp_head : String = "HTTP/1.1 200 OK\r\n\r\n", *,
                         scheme = "https", host = "acme.test", target = "/", status = 200,
                         content_type : String? = "text/html", body : String? = nil,
                         method = "GET", req_headers = "") : Gori::Store::FlowDetail
  head = String.build do |io|
    io << method << " " << target << " HTTP/1.1\r\nHost: " << host << "\r\n" << req_headers << "\r\n"
  end
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: scheme, host: host, port: scheme == "https" ? 443 : 80,
    method: method, target: target, http_version: "HTTP/1.1", head: head.to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy)
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, head: resp_head.to_slice, body: body.try(&.to_slice),
    reason: "OK", content_type: content_type, duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

# Only the cookie rule's detections.
private def cookies(store, **kw) : Array(Gori::Probe::Detection)
  Gori::Probe::Passive.analyze(capture_flow(store, **kw)).select(&.code.starts_with?("cookie_"))
end

private def codes(dets) : Array(String)
  dets.map(&.code)
end

# A response head carrying exactly one Set-Cookie line.
private def set_cookie(line : String) : String
  "HTTP/1.1 200 OK\r\nSet-Cookie: #{line}\r\n\r\n"
end

describe "Gori::Probe::Passive::Cookies (Domain scope)" do
  it "flags a cookie scoped to a parent of the request host" do
    with_store do |store|
      dets = cookies(store, host: "app.example.com",
        resp_head: set_cookie("sid=x; Domain=example.com; Secure; HttpOnly"))
      codes(dets).should contain("cookie_broad_domain")
      d = dets.find { |x| x.code == "cookie_broad_domain" }.not_nil!
      d.severity.should eq(Gori::Store::Severity::Info)
      d.category.should eq(Gori::Probe::Category::COOKIES)
      d.title.should eq("Cookie scoped to a parent domain")
      d.evidence.should eq("sid (Domain=example.com)")
      # The evidence has to survive Store.merge_evidence, which splits on ", ".
      d.evidence.not_nil!.should_not contain(", ")
    end
  end

  it "normalises the leading-dot Domain spelling" do
    with_store do |store|
      dets = cookies(store, host: "app.example.com",
        resp_head: set_cookie("sid=x; Domain=.example.com; Secure; HttpOnly"))
      d = dets.find { |x| x.code == "cookie_broad_domain" }.not_nil!
      d.evidence.should eq("sid (Domain=example.com)")
    end
  end

  it "flags from a deeper subdomain of the same parent" do
    with_store do |store|
      dets = cookies(store, host: "a.b.example.com",
        resp_head: set_cookie("sid=x; Domain=example.com; Secure; HttpOnly"))
      d = dets.find { |x| x.code == "cookie_broad_domain" }.not_nil!
      d.evidence.should eq("sid (Domain=example.com)")
      d.host.should eq("a.b.example.com")
    end
  end

  it "does NOT flag an apex host setting a cookie on its own domain" do
    with_store do |store|
      dets = cookies(store, host: "example.com",
        resp_head: set_cookie("sid=x; Domain=example.com; Secure; HttpOnly"))
      codes(dets).should_not contain("cookie_broad_domain")
    end
  end

  it "does NOT flag a host-only cookie (no Domain attribute)" do
    with_store do |store|
      dets = cookies(store, host: "app.example.com",
        resp_head: set_cookie("sid=x; Path=/; Secure; HttpOnly"))
      codes(dets).should_not contain("cookie_broad_domain")
    end
  end

  it "does NOT flag a Domain that does not cover the request host" do
    with_store do |store|
      # The browser rejects this outright, so the cookie is shared with nobody.
      dets = cookies(store, host: "app.example.com",
        resp_head: set_cookie("sid=x; Domain=other.test; Secure; HttpOnly"))
      codes(dets).should_not contain("cookie_broad_domain")
      # Nor a suffix that is not a domain boundary ("notexample.com" ends with "example.com").
      dets2 = cookies(store, host: "notexample.com",
        resp_head: set_cookie("sid=x; Domain=example.com; Secure; HttpOnly"))
      codes(dets2).should_not contain("cookie_broad_domain")
    end
  end

  it "does NOT flag a cookie being deleted, even on a subdomain" do
    with_store do |store|
      dets = cookies(store, host: "app.example.com",
        resp_head: set_cookie("sid=; Domain=example.com; Max-Age=0; Secure; HttpOnly"))
      codes(dets).should_not contain("cookie_broad_domain")
      # The deletion guard suppresses the whole cookie, not just this check.
      dets.should be_empty
    end
  end

  it "does NOT flag an empty or bare Domain attribute" do
    with_store do |store|
      codes(cookies(store, host: "app.example.com",
        resp_head: set_cookie("sid=x; Domain=; Secure; HttpOnly"))).should_not contain("cookie_broad_domain")
      codes(cookies(store, host: "app.example.com",
        resp_head: set_cookie("sid=x; Domain=.; Secure; HttpOnly"))).should_not contain("cookie_broad_domain")
    end
  end

  it "leaves the existing flag checks firing alongside it" do
    with_store do |store|
      dets = cookies(store, host: "app.example.com",
        resp_head: set_cookie("sid=x; Domain=example.com"))
      found = codes(dets)
      found.should contain("cookie_broad_domain")
      found.should contain("cookie_no_samesite")
      found.should contain("cookie_no_secure")
      found.should contain("cookie_no_httponly")
    end
  end

  it "reports each widened cookie of a multi-cookie response separately" do
    with_store do |store|
      head = "HTTP/1.1 200 OK\r\n" \
             "Set-Cookie: sid=x; Domain=example.com; Secure; HttpOnly; SameSite=Lax\r\n" \
             "Set-Cookie: csrf=y; Path=/; Secure; HttpOnly; SameSite=Lax\r\n\r\n"
      dets = cookies(store, host: "app.example.com", resp_head: head)
      broad = dets.select(&.code.==("cookie_broad_domain"))
      broad.size.should eq(1)
      broad.first.evidence.should eq("sid (Domain=example.com)")
    end
  end
end
