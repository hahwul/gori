require "./spec_helper"
require "compress/gzip"

# `Gori::SessionFromFlow` — one captured login exchange read into a session slot's header
# overlay. The engine half of `gori run session from-flow` and MCP `create_session_slot{flow_id}`;
# both surfaces call THIS, so what is pinned here is what both do.
#
# The refusals are the point of most of it. A surface that builds half a session, or one that
# builds a slot out of a response carrying a smuggled CR, is worse than one that says no.

private alias FromFlow = Gori::SessionFromFlow

private def flow(response : String?, request : String = "POST /login HTTP/1.1\r\nHost: h.test\r\n\r\n",
                 response_body : String? = nil, request_body : String? = nil,
                 error : String? = nil, status : Int32 = 200) : Gori::Store::FlowDetail
  row = Gori::Store::FlowRow.new(7_i64, 1_i64, "https", "POST", "h.test", 443, "/login",
    status, 100_i64, Gori::Store::FlowState::Complete, 50_i64, 1_i64, "application/json")
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", request.to_slice, request_body.try(&.to_slice),
    response.try(&.to_slice), response_body.try(&.to_slice), error: error)
end

private def draft(detail : Gori::Store::FlowDetail) : FromFlow::Draft
  result = FromFlow.draft(detail)
  result.should be_a(FromFlow::Draft)
  result.as(FromFlow::Draft)
end

private def refusal(detail : Gori::Store::FlowDetail) : FromFlow::Refusal
  result = FromFlow.draft(detail)
  result.should be_a(FromFlow::Refusal)
  result.as(FromFlow::Refusal)
end

private def request_draft(detail : Gori::Store::FlowDetail,
                          names : Array(String)) : FromFlow::Draft
  result = FromFlow.draft_request(detail, names)
  result.should be_a(FromFlow::Draft)
  result.as(FromFlow::Draft)
end

private def request_refusal(detail : Gori::Store::FlowDetail,
                            names : Array(String)) : FromFlow::Refusal
  result = FromFlow.draft_request(detail, names)
  result.should be_a(FromFlow::Refusal)
  result.as(FromFlow::Refusal)
end

private def headers_of(detail : Gori::Store::FlowDetail) : Hash(String, String)
  draft(detail).set_headers.to_h
end

describe Gori::SessionFromFlow do
  describe "request header selection" do
    it "copies explicitly named Authorization, Cookie, and custom headers" do
      detail = flow("HTTP/1.1 204 No Content\r\n\r\n",
        request: "GET /me HTTP/1.1\r\nHost: h.test\r\nAuthorization: Bearer SECRET\r\n" \
                 "Cookie: session=COOKIE\r\nX-CSRF-Token: CSRF\r\n\r\n")
      selected = request_draft(detail, ["Authorization", "Cookie", "X-CSRF-Token"])
      selected.set_headers.should eq([
        {"Authorization", "Bearer SECRET"},
        {"Cookie", "session=COOKIE"},
        {"X-CSRF-Token", "CSRF"},
      ])
      selected.sources.should eq([
        "Authorization ← the captured request header",
        "Cookie ← the captured request header",
        "X-CSRF-Token ← the captured request header",
      ])
    end

    it "deduplicates names case-insensitively while preserving first requested order" do
      detail = flow("HTTP/1.1 204 No Content\r\n\r\n",
        request: "GET /me HTTP/1.1\r\nHost: h.test\r\nCookie: c\r\nAuthorization: a\r\n" \
                 "X-Trace: t\r\n\r\n")
      selected = request_draft(detail, ["cookie", "AUTHORIZATION", "Cookie", "x-trace", "authorization"])
      selected.set_headers.map(&.[0]).should eq(["Cookie", "Authorization", "X-Trace"])
    end

    it "takes the last wire value and keeps that field's original casing" do
      detail = flow("HTTP/1.1 204 No Content\r\n\r\n",
        request: "GET /me HTTP/1.1\r\nHost: h.test\r\nX-Key: old\r\nx-key: new\r\n\r\n")
      selected = request_draft(detail, ["X-KEY"])
      selected.set_headers.should eq([{"x-key", "new"}])
    end

    it "refuses an empty selection" do
      result = request_refusal(flow("HTTP/1.1 204 No Content\r\n\r\n"), [] of String)
      result.code.should eq(FromFlow::EMPTY_HEADER_NAMES)
      result.message.should contain("at least one")
    end

    it "refuses an empty or non-token header name" do
      detail = flow("HTTP/1.1 204 No Content\r\n\r\n",
        request: "GET / HTTP/1.1\r\nHost: h.test\r\nAuthorization: a\r\n\r\n")
      request_refusal(detail, [""]).code.should eq(FromFlow::INVALID_HEADER_NAME)
      request_refusal(detail, ["X-Bad:Name"]).code.should eq(FromFlow::INVALID_HEADER_NAME)
      request_refusal(detail, ["X Bad"]).code.should eq(FromFlow::INVALID_HEADER_NAME)
      request_refusal(detail, ["X-Заголовок"]).code.should eq(FromFlow::INVALID_HEADER_NAME)
    end

    it "refuses atomically when any requested header is absent" do
      detail = flow("HTTP/1.1 204 No Content\r\n\r\n",
        request: "GET / HTTP/1.1\r\nHost: h.test\r\nAuthorization: SECRET\r\n\r\n")
      result = request_refusal(detail, ["Authorization", "Cookie"])
      result.code.should eq(FromFlow::MISSING_HEADER)
      result.message.should contain("Cookie")
      result.message.should_not contain("SECRET")
    end

    it "refuses a boundary-forging value without returning a partial draft" do
      detail = flow("HTTP/1.1 204 No Content\r\n\r\n",
        request: "GET / HTTP/1.1\r\nHost: h.test\r\nAuthorization: safe\r\n" \
                 "X-Bad: forged\rX-Injected: yes\r\n\r\n")
      result = request_refusal(detail, ["Authorization", "X-Bad"])
      result.code.should eq(FromFlow::UNSAFE_VALUE)
      result.message.should contain("CR")
      result.message.should_not contain("forged")
    end

    it "never includes request header values in provenance sources" do
      detail = flow("HTTP/1.1 204 No Content\r\n\r\n",
        request: "GET / HTTP/1.1\r\nHost: h.test\r\nAuthorization: SUPERSECRET\r\n\r\n")
      sources = request_draft(detail, ["Authorization"]).sources.join(" ")
      sources.should contain("Authorization")
      sources.should contain("captured request header")
      sources.should_not contain("SUPERSECRET")
    end

    # A slot is applied to a DIFFERENT message than the one it was copied from, so a copied
    # framing header would make every later send declare a length its own body does not have.
    it "refuses a framing or routing header by name, before reading the wire" do
      detail = flow("HTTP/1.1 204 No Content\r\n\r\n",
        request: "POST / HTTP/1.1\r\nHost: h.test\r\nContent-Length: 9\r\n" \
                 "Transfer-Encoding: chunked\r\nAuthorization: SECRET\r\n\r\n")
      %w[Content-Length content-length Transfer-Encoding Host].each do |name|
        result = request_refusal(detail, ["Authorization", name])
        result.code.should eq(FromFlow::REFRAMING_HEADER)
        result.message.should contain(name)
        result.message.should_not contain("SECRET")
      end
    end

    it "marks selected request headers literal for the real slot resolution path" do
      detail = flow("HTTP/1.1 204 No Content\r\n\r\n",
        request: "GET / HTTP/1.1\r\nHost: h.test\r\nAuthorization: Bearer $BIND.TOKEN\r\n\r\n")
      slot = request_draft(detail, ["authorization"]).slot("captured")
      resolved = slot.resolve_values(&.gsub("$BIND.TOKEN", "EXPANDED"))
      resolved.set_headers.should eq([{"Authorization", "Bearer $BIND.TOKEN"}])
      resolved.literal_headers.should eq(["Authorization"])
    end
  end

  describe "the login shape" do
    # The whole feature in one case: a Django-ish login answering with two cookies AND a JSON
    # token. Both halves land, so `--slot admin` sends the cookie jar and the bearer.
    it "reads Set-Cookie and a JSON token off one login response" do
      detail = flow(
        "HTTP/1.1 200 OK\r\n" \
        "Content-Type: application/json\r\n" \
        "Set-Cookie: csrftoken=abc123; Path=/; SameSite=Lax\r\n" \
        "Set-Cookie: sessionid=deadbeef; Path=/; HttpOnly; Secure\r\n\r\n",
        response_body: %({"access_token":"eyJhbGciOiJIUzI1NiJ9.x","expires_in":3600}))
      headers = headers_of(detail)
      headers["Cookie"].should eq("csrftoken=abc123; sessionid=deadbeef")
      headers["Authorization"].should eq("Bearer eyJhbGciOiJIUzI1NiJ9.x")
    end

    it "reads the JSON token beside a number past Int64, but never takes such a number AS one (#1200)" do
      beside = flow("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
        response_body: %({"user_id":18446744073709551615,"access_token":"eyJ.x.y"}))
      headers_of(beside)["Authorization"].should eq("Bearer eyJ.x.y")

      numeric = flow("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
        response_body: %({"access_token":18446744073709551615}))
      refusal(numeric).should be_a(FromFlow::Refusal)
    end

    # Provenance goes back to the operator, and a VALUE never does — this line is printed to
    # scrollback and returned over MCP, and a session cookie is a credential.
    it "names where each header came from, and never what it holds" do
      detail = flow("HTTP/1.1 200 OK\r\nSet-Cookie: sessionid=SUPERSECRET; Path=/\r\n\r\n")
      sources = draft(detail).sources
      sources.size.should eq(1)
      sources.first.should contain("Set-Cookie")
      sources.join(" ").should_not contain("SUPERSECRET")
    end

    it "builds a slot that is a pure header overlay — no rules, nothing stripped" do
      detail = flow("HTTP/1.1 200 OK\r\nSet-Cookie: sessionid=abc\r\n\r\n")
      slot = draft(detail).slot("admin")
      slot.name.should eq("admin")
      slot.rules.should be_empty
      slot.remove_headers.should be_empty
      slot.passthrough?.should be_false
      slot.baseline?.should be_false
      draft(detail).slot("admin", true).baseline?.should be_true
    end

    it "marks every response-derived header literal through slot construction" do
      detail = flow("HTTP/1.1 200 OK\r\nSet-Cookie: session=$GEN.UUID\r\n\r\n")
      slot = draft(detail).slot("captured")
      resolved = slot.resolve_values(&.gsub("$GEN.UUID", "GENERATED"))
      resolved.set_headers.should eq([{"Cookie", "session=$GEN.UUID"}])
      resolved.literal_headers.should eq(["Cookie"])
    end

    it "refuses invalid UTF-8 in a response-derived literal before persistence" do
      response = String.new(Bytes[0x48, 0x54, 0x54, 0x50, 0x2f, 0x31, 0x2e, 0x31, 0x20,
        0x32, 0x30, 0x30, 0x20, 0x4f, 0x4b, 0x0d, 0x0a, 0x53, 0x65, 0x74, 0x2d, 0x43, 0x6f,
        0x6f, 0x6b, 0x69, 0x65, 0x3a, 0x20, 0x73, 0x65, 0x73, 0x73, 0x69, 0x6f, 0x6e, 0x3d,
        0xff, 0x0d, 0x0a, 0x0d, 0x0a])
      result = refusal(flow(response))
      result.code.should eq(FromFlow::UNSAFE_VALUE)
      result.message.should contain("not valid UTF-8")
    end

    it "refuses invalid UTF-8 in a request-derived literal before persistence" do
      request = String.new(Bytes[0x47, 0x45, 0x54, 0x20, 0x2f, 0x20, 0x48, 0x54, 0x54, 0x50,
        0x2f, 0x31, 0x2e, 0x31, 0x0d, 0x0a, 0x48, 0x6f, 0x73, 0x74, 0x3a, 0x20, 0x68, 0x0d,
        0x0a, 0x58, 0x2d, 0x54, 0x6f, 0x6b, 0x65, 0x6e, 0x3a, 0x20, 0xff, 0x0d, 0x0a, 0x0d,
        0x0a])
      result = request_refusal(flow("HTTP/1.1 204 No Content\r\n\r\n", request: request), ["X-Token"])
      result.code.should eq(FromFlow::UNSAFE_VALUE)
      result.message.should contain("not valid UTF-8")
    end

    # The overlay has to survive the seam it exists for: `--slot` applies it to captured wire
    # bytes, upserting over whatever Cookie the request already carried.
    it "produces an overlay a send seam can apply" do
      detail = flow("HTTP/1.1 200 OK\r\nSet-Cookie: sessionid=new\r\n\r\n")
      wire = "GET /me HTTP/1.1\r\nHost: h.test\r\nCookie: sessionid=old\r\n\r\n".to_slice
      out = String.new(Gori::SessionSlot.overlay_wire(wire, draft(detail).slot("admin")))
      out.should contain("Cookie: sessionid=new")
      out.should_not contain("sessionid=old")
    end
  end

  describe "cookies" do
    it "drops attributes and keeps only name=value" do
      detail = flow("HTTP/1.1 200 OK\r\n" \
                    "Set-Cookie: sessionid=abc; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Max-Age=3600; " \
                    "Domain=.h.test; Path=/; Secure; HttpOnly; SameSite=None\r\n\r\n")
      headers_of(detail)["Cookie"].should eq("sessionid=abc")
    end

    # A logout is not a session. `sessionid=` with `Max-Age=0` is how a server DELETES a
    # cookie, and carrying the tombstone forward would send an expired identity as a slot.
    it "skips a cookie the response is DELETING" do
      detail = flow("HTTP/1.1 200 OK\r\n" \
                    "Set-Cookie: sessionid=; Max-Age=0; Path=/\r\n" \
                    "Set-Cookie: keep=yes\r\n\r\n")
      headers_of(detail)["Cookie"].should eq("keep=yes")
    end

    # A repeated name: the LATER value is the one a client would hold, but the line keeps the
    # order the origin wrote it in.
    it "lets the last value win for a repeated name, in first-appearance order" do
      detail = flow("HTTP/1.1 200 OK\r\n" \
                    "Set-Cookie: a=1\r\nSet-Cookie: b=2\r\nSet-Cookie: a=3\r\n\r\n")
      headers_of(detail)["Cookie"].should eq("a=3; b=2")
    end

    it "carries a value that contains '=' whole" do
      detail = flow("HTTP/1.1 200 OK\r\nSet-Cookie: jwt=aGVsbG8=.c2ln; Path=/\r\n\r\n")
      headers_of(detail)["Cookie"].should eq("jwt=aGVsbG8=.c2ln")
    end
  end

  describe "Authorization" do
    it "copies the response's own Authorization header" do
      detail = flow("HTTP/1.1 200 OK\r\nAuthorization: Bearer minted\r\n\r\n")
      headers_of(detail)["Authorization"].should eq("Bearer minted")
    end

    # The request's credential is the LAST resort: a refresh flow whose request carries the
    # stale bearer and whose response body carries the fresh one has to copy the fresh one.
    it "prefers a freshly-minted body token over the request's stale header" do
      detail = flow("HTTP/1.1 200 OK\r\n\r\n",
        request: "POST /refresh HTTP/1.1\r\nHost: h.test\r\nAuthorization: Bearer STALE\r\n\r\n",
        response_body: %({"access_token":"FRESH"}))
      headers_of(detail)["Authorization"].should eq("Bearer FRESH")
    end

    it "falls back to the request's Authorization when the response minted nothing" do
      detail = flow("HTTP/1.1 200 OK\r\n\r\n",
        request: "GET /me HTTP/1.1\r\nHost: h.test\r\nAuthorization: Basic dXNlcjpwdw==\r\n\r\n")
      d = draft(detail)
      d.set_headers.to_h["Authorization"].should eq("Basic dXNlcjpwdw==")
      d.sources.first.should contain("request header")
    end

    describe "the JSON body token" do
      it "reads token / access_token / id_token and nothing else" do
        {"token", "access_token", "id_token"}.each do |key|
          detail = flow("HTTP/1.1 200 OK\r\n\r\n", response_body: %({"#{key}":"T"}))
          headers_of(detail)["Authorization"].should eq("Bearer T")
        end
        # A key that is not one of the three is not a token, however token-ish it reads. The
        # operator writes an extract rule for it — this is not a JSONPath engine.
        detail = flow("HTTP/1.1 200 OK\r\n\r\n", response_body: %({"session_token":"T"}))
        refusal(detail).code.should eq(FromFlow::NO_CREDENTIAL)
      end

      it "prefers access_token when a body carries more than one" do
        detail = flow("HTTP/1.1 200 OK\r\n\r\n",
          response_body: %({"id_token":"IDENT","token":"GENERIC","access_token":"API"}))
        headers_of(detail)["Authorization"].should eq("Bearer API")
      end

      it "does not add a second Bearer to a value that already spells the scheme" do
        detail = flow("HTTP/1.1 200 OK\r\n\r\n", response_body: %({"token":"Bearer eyJ"}))
        headers_of(detail)["Authorization"].should eq("Bearer eyJ")
      end

      # Only a top-level STRING. `{"token": {...}}` is an envelope, and stringifying it would
      # put a JSON object in an Authorization header.
      it "ignores a nested or non-string leaf" do
        refusal(flow("HTTP/1.1 200 OK\r\n\r\n", response_body: %({"data":{"token":"T"}}))).code
          .should eq(FromFlow::NO_CREDENTIAL)
        refusal(flow("HTTP/1.1 200 OK\r\n\r\n", response_body: %({"token":{"v":"T"}}))).code
          .should eq(FromFlow::NO_CREDENTIAL)
        refusal(flow("HTTP/1.1 200 OK\r\n\r\n", response_body: %({"token":12345}))).code
          .should eq(FromFlow::NO_CREDENTIAL)
      end

      # Through `Proxy::Codec::ContentDecode`, the same seam `TokenExtract` reads a body
      # through — a gzipped login response must not be a silent miss.
      it "decodes a compressed body" do
        io = IO::Memory.new
        Compress::Gzip::Writer.open(io, &.print(%({"access_token":"ZIPPED"})))
        detail = flow("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Type: application/json\r\n\r\n",
          response_body: String.new(io.to_slice))
        headers_of(detail)["Authorization"].should eq("Bearer ZIPPED")
      end

      # `JSON.parse` succeeding IS the test: an API that mislabels its login response should
      # not cost the operator the feature.
      it "does not gate on Content-Type" do
        detail = flow("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
          response_body: %({"access_token":"T"}))
        headers_of(detail)["Authorization"].should eq("Bearer T")
      end

      it "does not repair an invalid UTF-8 body into a token" do
        body = String.new(Bytes[0x7b, 0x22, 0x74, 0x6f, 0x6b, 0x65, 0x6e, 0x22, 0x3a,
          0x22, 0xff, 0x22, 0x7d])
        refusal(flow("HTTP/1.1 200 OK\r\n\r\n", response_body: body)).code
          .should eq(FromFlow::NO_CREDENTIAL)
      end

      it "keeps header credentials when an unrelated response body is not valid UTF-8" do
        body = String.new(Bytes[0xff, 0xfe])
        detail = flow("HTTP/1.1 200 OK\r\nSet-Cookie: session=valid\r\n\r\n", response_body: body)
        headers_of(detail)["Cookie"].should eq("session=valid")
      end
    end
  end

  describe "refusals" do
    # The flow that has NEITHER — the case the task exists to refuse loudly rather than save
    # an empty slot for.
    it "refuses a flow that carries no cookie, no Authorization and no token" do
      detail = flow("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n",
        response_body: "<html><body>welcome</body></html>")
      r = refusal(detail)
      r.code.should eq(FromFlow::NO_CREDENTIAL)
      # It has to say what it looked for, or the operator cannot tell a wrong flow from a
      # broken gori — and it has to point at the surface that DOES handle a rotating token.
      r.message.should contain("no cookie")
      r.message.should contain("--bind-from")
    end

    it "refuses a flow with no captured response, and says so" do
      refusal(flow(nil)).message.should contain("no captured response")
      refusal(flow(nil, error: "upstream reset")).message.should contain("upstream reset")
    end

    # PROVENANCE. `SessionSlot.overlay_head` writes a set-header value VERBATIM because an
    # operator-authored overlay is the operator's own bytes. A value harvested off the wire is
    # not, so it passes the same guard a BOUND value passes at the send seam.
    it "refuses a captured value that would forge a header boundary" do
      raw = "HTTP/1.1 200 OK\r\nSet-Cookie: sessionid=abc\r\n\r\n"
      # Built as bytes rather than as a head line, because a real head cannot carry a bare CR
      # in a value — this is the shape an h2 → h1 downgrade or a tolerant parser produces.
      detail = flow(nil)
      forged = Gori::Store::FlowDetail.new(detail.row, "HTTP/1.1", detail.request_head, nil,
        raw.sub("sessionid=abc", "sessionid=abc\rX-Admin: 1").to_slice, nil)
      r = refusal(forged)
      r.code.should eq(FromFlow::UNSAFE_VALUE)
      r.message.should contain("CR")
      r.message.should contain("Cookie")
    end

    it "refuses a NUL in a captured token too" do
      detail = flow("HTTP/1.1 200 OK\r\n\r\n", response_body: %({"token":"a\\u0000b"}))
      refusal(detail).code.should eq(FromFlow::UNSAFE_VALUE)
    end
  end
end
