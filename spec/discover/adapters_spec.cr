require "../spec_helper"

private alias D = Gori::Discover
private alias R = Gori::Repeater::Result

private def with_store(&)
  path = File.tempname("gori-discover-adapters", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close rescue nil
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def notfound : R
  head = "HTTP/1.1 404 X\r\nContent-Type: text/html\r\nContent-Length: 9\r\n\r\n".to_slice
  R.new(head, "not found".to_slice, Gori::Proxy::Codec::Http1.parse_response_head(head), 1000_i64)
end

private class RouteBackend < D::Backend
  def initialize(@route : String -> R)
  end

  def fetch(scheme : String, host : String, port : Int32, target : String) : R
    @route.call(target)
  end
end

# Issue #396 / DESIGN.md §7 ("one reload semantic for the active-traffic scope gate", #354).
#
# Discover's Layer 2 runs through the injected ScopePolicy rather than through
# `Outbound#sweep_block`, so `Outbound#refresh` was never reached on the CLI or MCP and a
# discover run judged every one of its (potentially thousands of) probes against a
# start-time snapshot — while an in-flight fuzz/mine/sequence stopped within a second of the
# same rule being written. These specs pay the wall-clock wait for the throttle window.
describe Gori::Discover::StoreScope do
  describe "reload semantics" do
    it "honours a mid-run EXCLUDE once the throttle window elapses" do
      with_store do |store|
        scope = Gori::Scope.load(store)
        scope.add("include", "host", "acme.test")
        policy = D::StoreScope.new(scope)
        policy.allowed?("https://acme.test/logout", "acme.test").should be_true

        # What `gori run project scope add exclude ...` in a second terminal does: it writes
        # to the SAME db, and nothing notifies the running job (P8 — the job pulls).
        store.add_scope_rule("exclude", "string", "logout")

        # Inside the window the run keeps its last-known rules — the deliberate tradeoff
        # DESIGN.md §7 records, since a per-send DB read is what P6 rules out.
        policy.allowed?("https://acme.test/logout", "acme.test").should be_true

        sleep(Gori::Outbound::RELOAD_INTERVAL + 100.milliseconds)

        policy.allowed?("https://acme.test/logout", "acme.test").should be_false
        # Unrelated URLs are unaffected — the reload re-read the rules, it did not fail shut.
        policy.allowed?("https://acme.test/users", "acme.test").should be_true
      end
    end

    it "keeps the last-known scope when the reload fails (a closed store must not fail open)" do
      path = File.tempname("gori-discover-closed", ".db")
      store = Gori::Store.open(path)
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test")
      scope.enable_sandbox
      policy = D::StoreScope.new(scope)
      store.close
      begin
        sleep(Gori::Outbound::RELOAD_INTERVAL + 100.milliseconds)
        # The reload raises against the closed store and is swallowed: the rules loaded before
        # the close stay in force, so Sandbox still blocks an off-allowlist host rather than
        # the run dying or degrading to allow-everything.
        policy.allowed?("https://acme.test/s", "acme.test").should be_true
        policy.allowed?("https://other.test/s", "other.test").should be_false
      ensure
        File.delete?(path)
        File.delete?("#{path}-wal")
        File.delete?("#{path}-shm")
      end
    end

    it "stops an in-flight discover run's brute-forcer" do
      # The consequence the issue names, end to end: a run already underway must stop, not
      # finish its wordlist. The exclude is written from inside the FIRST send, so the rule
      # lands while the engine is mid-run exactly as a second terminal would place it.
      with_store do |store|
        scope = Gori::Scope.load(store)
        cfg = D::Config.new(spider: false, bruteforce: true, calibrate_probes: 1,
          concurrency: 1, retries: 0)
        sent = [] of String
        armed = false
        backend = RouteBackend.new(->(t : String) do
          sent << t
          unless armed
            armed = true
            store.add_scope_rule("exclude", "host", "t")
            sleep(Gori::Outbound::RELOAD_INTERVAL + 100.milliseconds)
          end
          notfound
        end)
        D::Engine.new("http://t/", %w[admin backup config], backend, cfg,
          D::StoreScope.new(scope)).run { |_ev| }

        # Only the calibration probe that armed the rule went out. Every wordlist candidate
        # was refused afterwards — by `enqueue_probes` before it could reach the frontier, and
        # by `send_with_retries` if it had.
        sent.size.should eq(1)
        sent.none?(&.includes?("admin")).should be_true
      end
    end
  end
end
