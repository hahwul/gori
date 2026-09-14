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

# `literal` — the names the CAPTURE arrived with — is the third argument because the seam it
# reports on is now narrowed per name (`Repeater::Sender#evidence_literals`): an evidence tab
# resolves an operator's own `$CTOK` and withholds only the capture's. nil is the caller with
# no per-name answer (a WS out-frame), for which the whole buffer is still withheld.
private def captured(*names : String) : Set(String)
  names.to_a.to_set
end

describe "RepeaterController.literal_bindings" do
  it "names a BOUND binding an evidence tab is about to send unresolved" do
    with_store do |store|
      with_layer(bound(store, "CTOK", "SECRETVALUE12")) do
        req = "GET /a HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer $CTOK\r\n\r\n"
        Gori::Tui::RepeaterController.literal_bindings(true, req, captured("CTOK")).should eq(["CTOK"])
      end
    end
  end

  # The other half of the narrowing, and the reason this argument exists: the same name typed
  # by the OPERATOR into a seeded tab is substituted by the seam, so reporting it would claim
  # a literal send of the one value that did resolve.
  it "says nothing for a name the capture did not bring" do
    with_store do |store|
      with_layer(bound(store, "CTOK", "SECRETVALUE12")) do
        req = "GET /a HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer $CTOK\r\n\r\n"
        Gori::Tui::RepeaterController.literal_bindings(true, req, captured("filter")).should be_empty
      end
    end
  end

  # A surface with no seed to answer per name — the WS out-frames, which `expand_messages`
  # still withholds whole — keeps the blanket report.
  it "reports every declared name when the caller has no per-name answer" do
    with_store do |store|
      with_layer(bound(store, "CTOK", "SECRETVALUE12")) do
        Gori::Tui::RepeaterController.literal_bindings(true, %({"t":"$CTOK"}), nil).should eq(["CTOK"])
      end
    end
  end

  # COMPLEMENT 1: a DRAFT tab resolves the name, so there is nothing to report — reporting
  # it there would be gori warning about a substitution it made correctly.
  it "says nothing for a draft tab" do
    with_store do |store|
      with_layer(bound(store, "CTOK", "SECRETVALUE12")) do
        req = "GET /a HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer $CTOK\r\n\r\n"
        Gori::Tui::RepeaterController.literal_bindings(false, req, captured("CTOK")).should be_empty
      end
    end
  end

  # COMPLEMENT 2: an evidence tab with no declared name in it is the ordinary case and must
  # stay silent, or every replay grows a warning about nothing.
  it "says nothing for an evidence tab carrying no declared name" do
    with_store do |store|
      with_layer(bound(store, "CTOK", "SECRETVALUE12")) do
        req = "GET /a?$filter=x HTTP/1.1\r\nHost: h\r\n\r\n"
        Gori::Tui::RepeaterController.literal_bindings(true, req, captured("filter")).should be_empty
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
        Gori::Tui::RepeaterController.literal_bindings(true, req, captured("CTOK")).should be_empty
      end
    end
  end

  it "says nothing with no binding layer at all" do
    with_layer(nil) do
      Gori::Tui::RepeaterController.literal_bindings(true, "GET /$CTOK HTTP/1.1\r\n\r\n",
        captured("CTOK")).should be_empty
    end
  end
end
