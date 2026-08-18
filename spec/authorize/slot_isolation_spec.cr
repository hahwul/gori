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
        body: nil))
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
        .live(Gori::Outbound.cli(nil, false), false, 5.seconds)
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
