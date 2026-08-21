require "../spec_helper"

# `Repeater::HistoryRecord` — the opt-in write that `gori run repeater send --record-history`
# (and any future TUI verb) uses to enter a workbench send into History (#749).
private def with_store(&)
  path = File.tempname("gori-rephist", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def plan_for(raw : String) : Gori::Repeater::Plan
  Gori::Repeater::Plan.build(
    Gori::Repeater::PlanOptions.new([raw.to_slice], default_target: "http://t.test"),
    ungated_outbound)
end

private def result_for(head : String, body : String?) : Gori::Repeater::Result
  h = head.to_slice
  resp = Gori::Proxy::Codec::Http1.parse_response_head(h)
  Gori::Repeater::Result.new(h, body.try(&.to_slice), resp, 4200_i64)
end

describe Gori::Repeater::HistoryRecord do
  it "records the request + response as one flow whose columns match the head" do
    with_store do |store|
      plan = plan_for("POST /login HTTP/1.1\r\nHost: t.test\r\nContent-Length: 5\r\n\r\nhello")
      result = result_for("HTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\n", "ok")
      id = Gori::Repeater::HistoryRecord.record(store, plan, result, created_at: 123_i64,
        wire: plan.wire_bytes, surface: Gori::FlowSource::Surface::Cli)
      id.should be > 0

      detail = store.get_flow(id).not_nil!
      detail.row.method.should eq("POST")
      detail.row.target.should eq("/login")
      detail.row.host.should eq("t.test")
      detail.row.status.should eq(201)
      # The row says gori sent it, through which surface, and from which repeater session —
      # without which it is indistinguishable from traffic the target's client produced.
      detail.row.source.should eq(Gori::FlowSource::Kind::Repeater)
      detail.row.source_surface.should eq(Gori::FlowSource::Surface::Cli)
      detail.row.sent_by_gori?.should be_true
      String.new(detail.request_body.not_nil!).should eq("hello")
    end
  end

  # The row must be the request the SOCKET got, not the draft the send seam started from.
  # `Sender#send`'s two passes — the `$NAME` binding pass and the active session slot's header
  # overlay — used to run out of sight inside it, so a send made under a slot was recorded
  # WITHOUT the identity header it went out with: replay that flow, or fuzz/scan from it, and
  # the credential gori actually used is nowhere in the evidence.
  it "records the bytes the send seam produced, not the pre-overlay draft" do
    with_store do |store|
      slots = Gori::SessionSlots.load(store)
      slots.save([Gori::SessionSlot.new("admin", set_headers: [{"Authorization", "Bearer ADMIN-TOKEN"}])])
      bindings = Gori::Bindings.load(store, slots)
      slots.activate("admin")
      previous = Gori::Env.layer
      Gori::Env.layer = bindings
      begin
        plan = plan_for("GET /me HTTP/1.1\r\nHost: t.test\r\n\r\n")
        wire = plan.wire_bytes
        String.new(wire).should contain("Authorization: Bearer ADMIN-TOKEN")
        # The draft it came from does not carry it — the two are different bytes, which is
        # exactly why the recorder must be handed the wire.
        String.new(plan.bytes).should_not contain("Authorization")

        result = result_for("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n", "ok")
        id = Gori::Repeater::HistoryRecord.record(store, plan, result, created_at: 7_i64, wire: wire,
          surface: Gori::FlowSource::Surface::Cli)
        detail = store.get_flow(id).not_nil!
        String.new(detail.request_head).should eq(String.new(wire))
      ensure
        Gori::Env.layer = previous
        slots.activate(nil)
      end
    end
  end

  it "records an errored send as an Error flow" do
    with_store do |store|
      plan = plan_for("GET /x HTTP/1.1\r\nHost: t.test\r\n\r\n")
      failed = Gori::Repeater::Result.new(Bytes.new(0), nil, nil, 100_i64, "connection refused")
      id = Gori::Repeater::HistoryRecord.record(store, plan, failed, created_at: 1_i64,
        wire: plan.wire_bytes, surface: Gori::FlowSource::Surface::Cli)
      store.get_flow(id).not_nil!.row.state.error?.should be_true
    end
  end
end
