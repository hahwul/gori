require "../spec_helper"

# `Repeater::Sender#evidence?` suppresses `Env.expand_bindings` on a captured request on
# purpose — a capture's `$filter` is a byte the origin saw, not a reference anybody wrote —
# and its own comment accepts the cost as "the direction that can only be READ WRONG, never
# SENT wrong". That holds for the SUBSTITUTION. It does not hold for the REPORT: the status
# line said `✓ sent → 200` with no further word while `Authorization: Bearer $CTOK` went out
# literally and the tab's own binding hint showed a value for `$CTOK`.
#
# So the expansion stays suppressed and the fact is stated. This pins the predicate that
# decides whether it is stated.

private def with_layer(bindings : Gori::Bindings?, &)
  previous = Gori::Env.layer
  Gori::Env.layer = bindings
  begin
    yield
  ensure
    Gori::Env.layer = previous
  end
end

private def bound(store, name : String, value : String) : Gori::Bindings
  b = Gori::Bindings.load(store)
  b.add(name, "", Gori::ExtractKind::JsonPath, "$.t").should be_nil
  head = "HTTP/1.1 200 OK\r\n\r\n"
  b.observe(
    Gori::Repeater::Result.new(head.to_slice, %({"t":"#{value}"}).to_slice,
      Gori::Proxy::Codec::Http1.parse_response_head(head.to_slice), 1_i64, nil),
    Gori::InterceptFilter::Subject.new(method: "POST", host: "acme.test", target: "/login",
      scheme: "https", status: 200)).should eq([name])
  b
end

describe "RepeaterController.literal_bindings" do
  it "names a BOUND binding an evidence tab is about to send unresolved" do
    with_store do |store|
      with_layer(bound(store, "CTOK", "SECRETVALUE12")) do
        req = "GET /a HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer $CTOK\r\n\r\n"
        Gori::Tui::RepeaterController.literal_bindings(true, req).should eq(["CTOK"])
      end
    end
  end

  # COMPLEMENT 1: a DRAFT tab resolves the name, so there is nothing to report — reporting
  # it there would be gori warning about a substitution it made correctly.
  it "says nothing for a draft tab" do
    with_store do |store|
      with_layer(bound(store, "CTOK", "SECRETVALUE12")) do
        req = "GET /a HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer $CTOK\r\n\r\n"
        Gori::Tui::RepeaterController.literal_bindings(false, req).should be_empty
      end
    end
  end

  # COMPLEMENT 2: an evidence tab with no declared name in it is the ordinary case and must
  # stay silent, or every replay grows a warning about nothing.
  it "says nothing for an evidence tab carrying no declared name" do
    with_store do |store|
      with_layer(bound(store, "CTOK", "SECRETVALUE12")) do
        req = "GET /a?$filter=x HTTP/1.1\r\nHost: h\r\n\r\n"
        Gori::Tui::RepeaterController.literal_bindings(true, req).should be_empty
      end
    end
  end

  # COMPLEMENT 3: a DECLARED but UNBOUND name is not this report's business — nothing would
  # have been substituted for it on any surface, so there is no divergence to name.
  it "says nothing for a declared name that has no value yet" do
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("CTOK", "", Gori::ExtractKind::JsonPath, "$.t").should be_nil
      with_layer(b) do
        req = "GET /a HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer $CTOK\r\n\r\n"
        Gori::Tui::RepeaterController.literal_bindings(true, req).should be_empty
      end
    end
  end

  it "says nothing with no binding layer at all" do
    with_layer(nil) do
      Gori::Tui::RepeaterController.literal_bindings(true, "GET /$CTOK HTTP/1.1\r\n\r\n").should be_empty
    end
  end
end
