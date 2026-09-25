require "./spec_helper"
require "../src/gori/session_refresh"

# The cooldown is 30 s of wall clock; a spec moves it rather than sleeping through it.
class Gori::SessionRefresh::Runner
  def expire_cooldown_for_spec(slot : String) : Nil
    @states[slot]?.try(&.cooldown_until=(Time.utc - 1.second))
  end
end

# A session slot refreshing itself from Repeater steps (#1233). The origin below is a real
# socket, because the property under test is what reaches the WIRE: a step resolves the
# refreshing slot's own bindings, carries no slot overlay, and rebinds only that slot — while
# some other slot is the send context.

private alias Slot = Gori::SessionSlot
private alias Policy = Gori::SessionSlot::RefreshBefore

# One request head seen by the origin, plus its path — enough to assert which header a step
# carried and in which order the steps went out.
private class Seen
  getter heads = [] of String
  getter paths = [] of String
end

# `/csrf` answers a fresh `X-CSRF: C<n>`, `/login` a fresh `Set-Cookie: sid=T<n>` — or the
# status `login_status` says. Serves until the spec closes it.
private def start_login_origin(seen : Seen, login_status : Int32 = 200,
                               csrf_status : Int32 = 200) : {TCPServer, Int32}
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  n = 0
  spawn do
    while conn = server.accept?
      begin
        conn.read_timeout = 5.seconds
        head = Gori::Proxy::Codec::Http1.read_head(conn)
        next unless head
        text = String.new(head)
        path = text.split(' ', 3)[1]? || "/"
        seen.heads << text
        seen.paths << path
        n += 1
        extra =
          if path.starts_with?("/csrf") && csrf_status < 400
            "X-CSRF: C#{n}\r\n"
          elsif path.starts_with?("/login") && login_status < 400
            "Set-Cookie: sid=T#{n}; Path=/\r\n"
          else
            ""
          end
        status = path.starts_with?("/login") ? login_status : (path.starts_with?("/csrf") ? csrf_status : 200)
        conn << "HTTP/1.1 #{status} X\r\n#{extra}Content-Length: 0\r\nConnection: close\r\n\r\n"
        conn.flush
      rescue
      ensure
        conn.close rescue nil
      end
    end
  end
  {server, port}
end

private def with_refresh_env(&)
  with_store_env do |store|
    prev_hook = Gori::SessionRefresh.hook
    begin
      yield store
    ensure
      Gori::SessionRefresh.hook = prev_hook
    end
  end
end

# Two Repeater sessions — `csrf-fetch` then `login` carrying `$CSRF` — and the slots/bindings
# wired the way `Session.open` wires them.
private def refresh_fixture(store : Gori::Store, port : Int32, admin_policy : Policy = Policy.off)
  target = "http://127.0.0.1:#{port}"
  csrf = store.insert_repeater(target, "GET /csrf HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
    false, true, nil, 0)
  login = store.insert_repeater(target,
    "POST /login HTTP/1.1\r\nHost: 127.0.0.1\r\nX-CSRF: $CSRF\r\nContent-Length: 0\r\n\r\n".to_slice,
    false, true, nil, 1)
  store.set_repeater_name(login, "login")
  slots = Gori::SessionSlots.load(store)
  slots.save([
    Slot.new("admin", set_headers: [{"Cookie", "sid=$SESSION"}, {"X-Who", "admin"}],
      rules: ["SESSION", "CSRF"], refresh: [csrf, login], refresh_before: admin_policy),
    Slot.new("user", set_headers: [{"X-Who", "user"}], rules: ["SESSION"]),
  ])
  bindings = Gori::Bindings.load(store, slots)
  bindings.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
  bindings.add("CSRF", "", Gori::ExtractKind::Header, "x-csrf").should be_nil
  Gori::Env.layer = bindings
  runner = Gori::SessionRefresh::Runner.new(store, bindings, -> { ungated_outbound }).install
  {runner, bindings, slots, csrf, login}
end

describe Gori::SessionSlot do
  it "round-trips a slot with no refresh byte-identically to the pre-#1233 shape" do
    blob = Slot.serialize([Slot.new("admin", set_headers: [{"Cookie", "a=1"}])])
    blob.should_not contain("refresh")
    Slot.parse_json(blob).first.refresh.should be_empty
    Slot.parse_json(blob).first.refresh_before.off?.should be_true
  end

  it "persists the steps and the policy, detached steps included" do
    slot = Slot.new("admin", refresh: [4_i64, -7_i64], refresh_before: Policy.parse?("ttl=10m").not_nil!)
    back = Slot.parse_json(Slot.serialize([slot])).first
    back.refresh.should eq([4_i64, -7_i64])
    back.refresh_before.to_s.should eq("ttl=10m")
  end

  it "keeps the refresh half through every copy a list edit makes" do
    slot = Slot.new("admin", rules: ["S"], refresh: [3_i64], refresh_before: Policy.new(Policy::Kind::JwtExp))
    [slot.with_baseline(true), slot.with_rules(["T"]), slot.resolve_values { |v| v }].each do |copy|
      copy.refresh.should eq([3_i64])
      copy.refresh_before.kind.jwt_exp?.should be_true
    end
  end

  it "parses the three policies and refuses the rest" do
    Policy.parse?("off").not_nil!.off?.should be_true
    Policy.parse?("JWT-EXP").not_nil!.kind.jwt_exp?.should be_true
    Policy.parse?("ttl=90").not_nil!.ttl.should eq(90.seconds)
    Policy.parse?("ttl=2h").not_nil!.to_s.should eq("ttl=2h")
    Policy.parse?("ttl=0").should be_nil
    Policy.parse?("ttl=5d").should be_nil
    Policy.parse?("sometimes").should be_nil
  end

  it "detaches one repeater id in place and leaves an unknown key alone" do
    raw = %([{"name":"a","refresh":[3,4],"future":true},{"name":"b"}])
    detached = Slot.detach_refresh(raw, 3).not_nil!
    JSON.parse(detached)[0]["refresh"].as_a.map(&.as_i64).should eq([-3_i64, 4_i64])
    JSON.parse(detached)[0]["future"].as_bool.should be_true
    Slot.detach_refresh(raw, 9).should be_nil
    Slot.detach_refresh("not json", 3).should be_nil
  end
end

describe Gori::SessionRefresh do
  it "reads the earliest exp out of a bound value" do
    payload = Base64.urlsafe_encode(%({"exp":1700000000}), padding: false)
    header = Base64.urlsafe_encode(%({"alg":"HS256"}), padding: false)
    Gori::SessionRefresh.jwt_exp("Bearer #{header}.#{payload}.sig").should eq(1700000000_i64)
    Gori::SessionRefresh.jwt_exp("plain-cookie-value").should be_nil
  end

  it "refreshes the named slot as itself while another slot is active" do
    with_refresh_env do |store|
      seen = Seen.new
      server, port = start_login_origin(seen)
      begin
        runner, bindings, slots, _, _ = refresh_fixture(store, port)
        slots.activate("user")
        outcome = runner.refresh("admin")
        outcome.ok.should be_true
        outcome.rebound.sort.should eq(["CSRF", "SESSION"])
        seen.paths.should eq(["/csrf", "/login"])
        # Step 2 resolved ADMIN's CSRF, which step 1 had just bound into admin's table …
        seen.heads[1].should contain("X-CSRF: C1")
        # … and carried no slot overlay — neither admin's own nor the active user's.
        seen.heads.none?(&.includes?("X-Who")).should be_true
        # The value landed in admin's table only; user (the send context) is untouched.
        bindings.slot_values("admin")["SESSION"].should eq("T2")
        bindings.values["SESSION"]?.should be_nil
        # Recorded as refresh traffic, one row per step, with the step named.
        rows = store.recent_flows(10)
        rows.size.should eq(2)
        rows.all? { |r| r.source.try(&.refresh?) }.should be_true
        rows.compact_map(&.source_ref).sort.should eq(["slot admin step 1", "slot admin step 2"])
        store.events_recent(10).rows.any? { |e| e.kind == "refresh_ok" }.should be_true
      ensure
        server.close
      end
    end
  end

  it "names the failing step and leaves the binding alone" do
    with_refresh_env do |store|
      seen = Seen.new
      server, port = start_login_origin(seen, login_status: 403)
      begin
        runner, bindings, _, _, _ = refresh_fixture(store, port)
        outcome = runner.refresh("admin")
        outcome.ok.should be_false
        outcome.failed_step.should eq(2)
        outcome.status.should eq(403)
        outcome.message.should contain("refresh admin failed at step 2 (login → 403)")
        bindings.slot_values("admin")["SESSION"]?.should be_nil
        runner.status("admin").failed?.should be_true
        store.events_recent(10).rows.any? { |e| e.kind == "refresh_failed" }.should be_true
      ensure
        server.close
      end
    end
  end

  it "refuses a step whose Repeater session was deleted, even after its id is reused" do
    with_refresh_env do |store|
      seen = Seen.new
      server, port = start_login_origin(seen)
      begin
        runner, bindings, slots, csrf, _ = refresh_fixture(store, port)
        store.delete_repeater(csrf).should be_true
        # The same id taken again by an unrelated tab must not become the login step.
        store.insert_repeater("http://127.0.0.1:#{port}", "GET /unrelated HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 5)
        outcome = runner.refresh("admin")
        outcome.ok.should be_false
        outcome.failed_step.should eq(1)
        outcome.step_label.not_nil!.should contain("(deleted)")
        seen.paths.should be_empty
        slots.find("admin").not_nil!.refresh.first.should eq(-csrf)
        bindings.slots.should_not be_nil
      ensure
        server.close
      end
    end
  end

  it "does not wipe the live bindings when a refresh step's tab is closed" do
    with_refresh_env do |store|
      seen = Seen.new
      server, port = start_login_origin(seen)
      begin
        runner, bindings, slots, csrf, _ = refresh_fixture(store, port)
        runner.refresh("admin").ok.should be_true
        store.delete_repeater(csrf).should be_true
        slots.reload
        bindings.slot_values("admin")["SESSION"].should eq("T2")
      ensure
        server.close
      end
    end
  end

  it "refreshes before a send when the policy says so, once for concurrent senders" do
    with_refresh_env do |store|
      seen = Seen.new
      server, port = start_login_origin(seen)
      begin
        runner, bindings, slots, _, _ = refresh_fixture(store, port, Policy.parse?("ttl=10m").not_nil!)
        slots.activate("admin")
        done = Channel(String?).new
        3.times do
          spawn do
            Gori::SessionRefresh.before_send("admin")
            # What this sender would resolve the moment the hook lets it go.
            done.send(bindings.slot_values("admin")["SESSION"]?)
          end
        end
        seen_values = Array.new(3) { done.receive }
        # Nothing was bound, so the first sender refreshed; the other two WAITED for it, and
        # none of the three went out before the new token was bound.
        seen.paths.should eq(["/csrf", "/login"])
        seen_values.should eq(["T2", "T2", "T2"])
        bindings.slot_values("admin")["SESSION"].should eq("T2")
        # Freshly bound under a 10-minute TTL: not due again.
        Gori::SessionRefresh.before_send("admin")
        seen.paths.size.should eq(2)
        runner.status("admin").last.not_nil!.manual.should be_false
      ensure
        server.close
      end
    end
  end

  it "cools down after an automatic failure and stops after the failure limit" do
    with_refresh_env do |store|
      seen = Seen.new
      server, port = start_login_origin(seen, csrf_status: 500)
      begin
        runner, _, _, _, _ = refresh_fixture(store, port, Policy.parse?("ttl=10m").not_nil!)
        Gori::SessionRefresh.before_send("admin")
        Gori::SessionRefresh.before_send("admin")
        # The second send fell inside the cooldown and sent nothing.
        seen.paths.size.should eq(1)
        # Manual refreshes ignore the cooldown; the third consecutive failure turns auto off.
        runner.refresh("admin").ok.should be_false
        runner.refresh("admin").ok.should be_false
        runner.status("admin").auto_off.should be_true
      ensure
        server.close
      end
    end
  end

  it "retries a partly failed refresh after the cooldown even though step 1 rebound a value" do
    with_refresh_env do |store|
      seen = Seen.new
      server, port = start_login_origin(seen, login_status: 500)
      begin
        runner, bindings, _, _, _ = refresh_fixture(store, port, Policy.parse?("ttl=10m").not_nil!)
        Gori::SessionRefresh.before_send("admin")
        # Step 1 bound a fresh CSRF; the session token was never bound.
        bindings.slot_values("admin")["CSRF"]?.should_not be_nil
        runner.status("admin").failed?.should be_true
        # Past the cooldown, the next send retries — a TTL counted from the fresh CSRF would not.
        runner.expire_cooldown_for_spec("admin")
        Gori::SessionRefresh.before_send("admin")
        seen.paths.size.should eq(4)
      ensure
        server.close
      end
    end
  end

  it "is inert once another project's binding table is the layer" do
    with_refresh_env do |store|
      seen = Seen.new
      server, port = start_login_origin(seen)
      begin
        refresh_fixture(store, port, Policy.parse?("ttl=10m").not_nil!)
        Gori::Env.layer = Gori::Bindings.load(store, Gori::SessionSlots.load(store))
        Gori::SessionRefresh.before_send("admin")
        seen.paths.should be_empty
      ensure
        server.close
      end
    end
  end

  it "runs from a Repeater send's own seam, and a refresh step never triggers one" do
    with_refresh_env do |store|
      seen = Seen.new
      server, port = start_login_origin(seen)
      begin
        _, _, slots, _, _ = refresh_fixture(store, port, Policy.parse?("ttl=10m").not_nil!)
        slots.activate("admin")
        sender = Gori::Repeater::Sender.new(ungated_outbound, scheme: "http", host: "127.0.0.1",
          port: port, verify: false)
        sender.send("GET /api HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice)
        seen.paths.should eq(["/csrf", "/login", "/api"])
        # The send itself went out AS admin, carrying the token the refresh just bound.
        seen.heads[2].should contain("sid=T2")
        seen.heads[2].should contain("X-Who: admin")
      ensure
        server.close
      end
    end
  end
end
