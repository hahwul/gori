require "../spec_helper"
require "socket"
require "../../src/gori/authorize/engine"

# An Authorize run carries its OWN identity per send. The ACTIVE session slot — the send
# context every OTHER seam wears (`Repeater::Sender`, `Fuzz::Sender`, the intercept forward)
# — must not be written over the top of it.
#
# It was, and the failure was silent and maximal: with any slot active, the "anonymous"
# identity kept the slot's Cookie and the baseline lost its own, every response matched by
# construction, and every queued row reported `⚠ same` — a fabricated broken-access-control
# finding on all three surfaces. The wire is the only place that settles it, so this dials a
# real socket and reads the bytes the origin received.
private class SlotRecordingOrigin
  getter port : Int32
  getter requests = [] of Bytes

  def initialize(@server : TCPServer = TCPServer.new("127.0.0.1", 0))
    @port = @server.local_address.port
  end

  def serve(count : Int32) : Nil
    spawn do
      count.times do
        break unless conn = @server.accept?
        conn.read_timeout = 5.seconds
        head = Gori::Proxy::Codec::Http1.read_head(conn)
        break unless head
        @requests << head.dup
        conn << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        conn.flush
        conn.close
      end
    rescue
    ensure
      @server.close rescue nil
    end
  end
end

private def with_slot_store(&)
  path = File.tempname("gori-authorize-slot", ".db")
  store = Gori::Store.open(path)
  previous = Gori::Env.layer
  begin
    yield store
  ensure
    Gori::Env.layer = previous
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe "Authorize vs the active session slot" do
  it "sends each identity's own overlay, not the active slot's" do
    with_slot_store do |store|
      origin = SlotRecordingOrigin.new
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: origin.port,
        method: "GET", target: "/admin", http_version: "HTTP/1.1",
        head: "GET /admin HTTP/1.1\r\nHost: 127.0.0.1\r\nCookie: session=ADMIN\r\n\r\n".to_slice,
        body: nil, source: Gori::FlowSource::Kind::Proxy))
      detail = store.get_flow(id).not_nil!

      # The operator picked a send context in another tab — the ordinary case, since the slot
      # list and the identity list are the same rows.
      slots = Gori::SessionSlots.new(store,
        [Gori::SessionSlot.new("repeater-admin", set_headers: [{"Cookie", "session=SLOT"}])])
      Gori::Env.layer = Gori::Bindings.load(store, slots)
      slots.activate("repeater-admin").should be_true

      identities = [
        Gori::Authorize::Identity.as_captured,
        Gori::Authorize::Identity.new("anonymous", remove_headers: ["Cookie", "Authorization"]),
      ]
      origin.serve(2)
      target = Gori::Authorize::Engine
        .live(Gori::Outbound.cli(nil, false), false, 5.seconds, overrides: nil)
        .run(detail, identities)
      target.should_not be_nil

      origin.requests.size.should eq(2)
      baseline, anonymous = String.new(origin.requests[0]), String.new(origin.requests[1])
      # The baseline is the request AS CAPTURED — its own session, not the slot's.
      baseline.should contain("Cookie: session=ADMIN")
      baseline.should_not contain("SLOT")
      # And an identity that DROPS the cookie actually goes out without one.
      anonymous.should_not contain("Cookie")
    end
  end
end

# A slot's `rules` half is what makes two identities two SESSIONS rather than two spellings:
# `admin` and `victim` both carry `Authorization: Bearer $SESSION`, each claims the `SESSION`
# extract rule, and each holds its own observed token. That is the documented multi-identity
# story (`Bindings#overlay`, `SessionSlot#rules`), and it is the shape this whole tab is for.
#
# Authorize applies the overlay ITSELF — `Engine.live` turns the active-slot seam off so the
# identity under test is the one that goes out — so nothing downstream expanded the `$NAME`
# and the four literal bytes `$SES…` went on the wire. Both identities then went out
# unauthenticated, drew the same 401 the anonymous one does, and the row aggregated to
# `enforced`: a bypass reported as a target that held. The wire is the only place that settles
# it, so this reads what the origin received.
private def bound_response(value : String) : Gori::Repeater::Result
  bytes = "HTTP/1.1 200 OK\r\nSet-Cookie: sid=#{value}; Path=/\r\nContent-Length: 0\r\n\r\n".to_slice
  Gori::Repeater::Result.new(bytes, "".to_slice,
    Gori::Proxy::Codec::Http1.parse_response_head(bytes), 1_i64, nil)
end

# A COMPLETE capture, built rather than inserted: `insert_flow` records the request half, and
# a flow with no response yet is `:incomplete` — which is the first rung of the skip chain and
# would answer these before the question they are asking is reached.
private def complete_flow : Gori::Store::FlowDetail
  row = Gori::Store::FlowRow.new(1_i64, 0_i64, "https", "GET", "h.test", 443, "/orders",
    200, 100_i64, Gori::Store::FlowState::Complete, 50_i64, 1_i64, "text/html")
  head = "GET /orders HTTP/1.1\r\nHost: h.test\r\nCookie: sid=CAPTURED\r\n\r\n".to_slice
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", head, nil, nil, nil)
end

private def login_subject : Gori::InterceptFilter::Subject
  Gori::InterceptFilter::Subject.new(method: "POST", host: "acme.test", target: "/login",
    scheme: "https", status: 200)
end

describe "Authorize and per-identity bindings" do
  it "resolves each identity's $NAME out of THAT identity's own table" do
    with_slot_store do |store|
      origin = SlotRecordingOrigin.new
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "127.0.0.1", port: origin.port,
        method: "GET", target: "/orders", http_version: "HTTP/1.1",
        head: "GET /orders HTTP/1.1\r\nHost: 127.0.0.1\r\nCookie: sid=CAPTURED\r\n\r\n".to_slice,
        body: nil, source: Gori::FlowSource::Kind::Proxy))
      detail = store.get_flow(id).not_nil!

      slots = Gori::SessionSlots.load(store)
      slots.save([
        Gori::SessionSlot.new("admin", set_headers: [{"Cookie", "sid=$SESSION"}],
          baseline: true, rules: ["SESSION"]),
        Gori::SessionSlot.new("victim", set_headers: [{"Cookie", "sid=$SESSION"}],
          rules: ["SESSION"]),
      ]).should be_true
      bindings = Gori::Bindings.load(store, slots)
      bindings.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
      # Each identity logs in once — the ordinary way both tables come to hold a token.
      slots.activate("admin")
      bindings.observe(bound_response("ADMINTOK"), login_subject).should eq(["SESSION"])
      slots.activate("victim")
      bindings.observe(bound_response("VICTIMTOK"), login_subject).should eq(["SESSION"])
      # …and NOTHING is active at the run: the resolution must come from the identity, not
      # from whichever slot a picker in another tab happens to be pointing at.
      slots.activate(nil)
      Gori::Env.layer = bindings

      origin.serve(2)
      Gori::Authorize::Engine
        .live(Gori::Outbound.cli(nil, false), false, 5.seconds, overrides: nil)
        .run(detail, slots.slots).should_not be_nil

      origin.requests.size.should eq(2)
      admin, victim = String.new(origin.requests[0]), String.new(origin.requests[1])
      admin.should contain("Cookie: sid=ADMINTOK")
      victim.should contain("Cookie: sid=VICTIMTOK")
      # The literal reference never reaches the socket, and neither identity wears the other's
      # token — the two failures this replaces.
      admin.should_not contain("$SESSION")
      victim.should_not contain("$SESSION")
      admin.should_not contain("VICTIMTOK")
      victim.should_not contain("ADMINTOK")
    end
  end

  # An identity nothing registered — the baseline `Plan` prepends, an `--identities` file —
  # resolves out of the GLOBAL table, which is what a project with no slots has always done.
  # `SESSION` is claimed by no slot here, so it is an ordinary unscoped rule writing the one
  # global table (`Bindings`' compatibility case).
  it "resolves an unregistered identity's $NAME globally" do
    with_slot_store do |store|
      slots = Gori::SessionSlots.load(store)
      slots.save([Gori::SessionSlot.new("admin")]).should be_true
      bindings = Gori::Bindings.load(store, slots)
      bindings.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
      bindings.observe(bound_response("GLOBALTOK"), login_subject).should eq(["SESSION"])
      Gori::Env.layer = bindings

      loose = Gori::Authorize::Identity.new("from-a-file",
        set_headers: [{"Cookie", "sid=$SESSION"}])
      Gori::Authorize.resolve(loose).set_headers.should eq([{"Cookie", "sid=GLOBALTOK"}])
    end
  end
  # The SKIP decision asks the same question about the same bytes. `admin` and `victim` are
  # character-for-character identical before expansion — both `sid=$SESSION` — so a comparison
  # made on the unresolved overlays answered "no identity changes this request" and declined
  # the one configuration the tab exists for, with `no identity changes them` on the row.
  it "does not decline two identities that differ only after resolution" do
    with_slot_store do |store|
      detail = complete_flow

      slots = Gori::SessionSlots.load(store)
      slots.save([
        Gori::SessionSlot.new("admin", set_headers: [{"Cookie", "sid=$SESSION"}],
          baseline: true, rules: ["SESSION"]),
        Gori::SessionSlot.new("victim", set_headers: [{"Cookie", "sid=$SESSION"}],
          rules: ["SESSION"]),
      ]).should be_true
      bindings = Gori::Bindings.load(store, slots)
      bindings.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
      slots.activate("admin")
      bindings.observe(bound_response("ADMINTOK"), login_subject)
      slots.activate("victim")
      bindings.observe(bound_response("VICTIMTOK"), login_subject)
      slots.activate(nil)
      Gori::Env.layer = bindings

      Gori::Authorize::Passive.skip_reason(detail, slots.slots).should be_nil
      Gori::Authorize::Passive.manual_skip_reason(detail, slots.slots).should be_nil
    end
  end

  # …and the refusal still fires when resolution changes nothing: two identities whose tables
  # hold the SAME token really do send identical bytes, and that is a `⚠ same` manufactured out
  # of nothing. Widening the question must not turn the guard off.
  it "still declines identities that resolve to the same bytes" do
    with_slot_store do |store|
      detail = complete_flow

      slots = Gori::SessionSlots.load(store)
      slots.save([
        Gori::SessionSlot.new("admin", set_headers: [{"Cookie", "sid=$SESSION"}],
          baseline: true, rules: ["SESSION"]),
        Gori::SessionSlot.new("twin", set_headers: [{"Cookie", "sid=$SESSION"}],
          rules: ["SESSION"]),
      ]).should be_true
      bindings = Gori::Bindings.load(store, slots)
      bindings.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
      slots.activate("admin")
      bindings.observe(bound_response("SAMETOK"), login_subject)
      slots.activate("twin")
      bindings.observe(bound_response("SAMETOK"), login_subject)
      slots.activate(nil)
      Gori::Env.layer = bindings

      Gori::Authorize::Passive.skip_reason(detail, slots.slots).should eq(:no_effect)
    end
  end
end
