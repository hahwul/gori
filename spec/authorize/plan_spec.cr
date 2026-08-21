require "../spec_helper"
require "../../src/gori/authorize/plan"

private alias Plan = Gori::Authorize::Plan
private alias PlanOptions = Gori::Authorize::PlanOptions
private alias PlanError = Gori::Authorize::PlanError
private alias Identity = Gori::Authorize::Identity
private alias Reason = Gori::Authorize::PlanError::Reason

# Two identities that genuinely differ on a request carrying a Cookie — the shape every
# selection spec needs, since `Passive.skip_reason` declines a flow no identity changes.
private IDENTS_JSON = <<-JSON
  [{"name": "as-captured", "baseline": true, "set": [], "remove": []},
   {"name": "anonymous", "set": [], "remove": ["Cookie"]}]
  JSON

# One identity, NOT flagged baseline — the ordinary CLI shape (`--identity '{…}'`), which
# only works because the builder prepends `Identity.as_captured`.
private ONE_IDENT_JSON = <<-JSON
  [{"name": "anonymous", "set": [], "remove": ["Cookie"]}]
  JSON

private def with_store(&)
  path = File.tempname("gori-authorize-plan", ".db")
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

# One captured flow. `complete: false` leaves it Pending (`:incomplete`); `short_circuited`
# marks it as answered by gori.
private def seed(store : Gori::Store, method : String = "GET", target : String = "/admin",
                 host : String = "acme.test", complete : Bool = true,
                 short_circuited : Bool = false, cookie : Bool = true,
                 source : Gori::FlowSource::Kind = Gori::FlowSource::Kind::Proxy) : Int64
  head = String.build do |s|
    s << method << ' ' << target << " HTTP/1.1\r\nHost: " << host << "\r\n"
    s << "Cookie: session=ADMIN\r\n" if cookie
    s << "\r\n"
  end
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: host, port: 443,
    method: method, target: target, http_version: "HTTP/1.1",
    head: head.to_slice, short_circuited: short_circuited, source: source))
  if complete
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice,
      body: "ok".to_slice, duration_us: 1_000_i64))
  end
  store.flush
  id
end

private def options(store : Gori::Store, flow_ids : Array(Int64) = [] of Int64,
                    query : String? = nil, limit : Int32 = Plan::DEFAULT_LIMIT,
                    unsafe_methods : Bool = false) : PlanOptions
  PlanOptions.new(store, flow_ids: flow_ids, query: query, limit: limit,
    unsafe_methods: unsafe_methods, identities_json: IDENTS_JSON)
end

# A backend that answers everything 200, so `Plan#run` can be exercised with no socket.
private class FakeBackend < Gori::Fuzz::Backend
  getter sent = [] of Bytes

  def initialize(@origin : Gori::Fuzz::Origin)
  end

  def origin : Gori::Fuzz::Origin
    @origin
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sent << bytes
    Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\n\r\n".to_slice, "hello world".to_slice, nil, 1_i64)
  end
end

# A capture whose stored request head is an h2 FIELD DUMP rather than a request line. It
# passes every skip test — complete, GET, and an identity that drops `cookie` changes it — and
# then `FlowRequest.build` refuses it, which is the point.
private def pseudo_header_seed(store : Gori::Store) : Int64
  head = ":method: GET\r\n:path: /admin\r\n:authority: acme.test\r\ncookie: session=ADMIN\r\n\r\n"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: "/admin", http_version: "HTTP/1.1", head: head.to_slice, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice,
    body: "ok".to_slice, duration_us: 1_000_i64))
  store.flush
  id
end

private def fake_engine(backend : FakeBackend) : Gori::Authorize::Engine
  Gori::Authorize::Engine.new(->(_o : Gori::Fuzz::Origin, _h : Bool) { backend.as(Gori::Fuzz::Backend) })
end

describe Gori::Authorize::Plan do
  describe "target selection" do
    it "resolves explicit flow ids, in the order they were given" do
      with_store do |store|
        a = seed(store, target: "/admin")
        b = seed(store, target: "/orders")
        plan = Plan.build(options(store, flow_ids: [b, a]), ungated_outbound)
        plan.targets.map(&.row.id).should eq([b, a])
        plan.skipped.should be_empty
        plan.skip_summary.should be_nil
        # 2 requests × 2 identities.
        plan.total_sends.should eq(4)
      end
    end

    it "resolves a QL query over history" do
      with_store do |store|
        seed(store, host: "acme.test", target: "/admin")
        other = seed(store, host: "other.test", target: "/admin")
        plan = Plan.build(options(store, query: "host:acme.test"), ungated_outbound)
        plan.targets.map(&.row.host).should eq(["acme.test"])
        plan.targets.map(&.row.id).should_not contain(other)
      end
    end

    # Ids first, then the query's rows — and a flow reached twice is REPORTED as a duplicate
    # rather than silently uniq'd, so `--flow 7 --query host:acme.test` says what it did.
    it "dedups a flow reached by both an id and the query, naming it" do
      with_store do |store|
        id = seed(store, target: "/admin")
        plan = Plan.build(options(store, flow_ids: [id], query: "host:acme.test"), ungated_outbound)
        plan.targets.map(&.row.id).should eq([id])
        plan.skipped.map(&.reason).should eq([:duplicate])
        plan.skipped.first.flow_id.should eq(id)
        plan.skip_summary.should eq("1 already queued")
      end
    end

    # `scope:` selects by the project's scope rules (#754), and on a project that HAS none a
    # negated scope term is a negated never-match — every flow — which `Plan.search`'s
    # `reject_empty?` cannot catch (it compares the compiled SQL against `1`, and `NOT (0)` is not
    # that string). Every row selected here becomes `identities.size` real requests against a live
    # target, so the query is refused rather than run — the same guard `gori run history delete`
    # takes for the same reason.
    it "refuses a scope: query on a project with no scope rules" do
      with_store do |store|
        seed(store, host: "acme.test", target: "/admin")
        %w[-scope:in scope:out].each do |q|
          ex = expect_raises(PlanError) { Plan.build(options(store, query: q), ungated_outbound) }
          ex.reason.should eq(PlanError::Reason::BadQuery)
          ex.message.not_nil!.should contain("NO scope rules")
        end

        # Configured, it is an ordinary term: the boundary selects, and nothing is refused.
        Gori::Scope.load(store).add("include", "host", "acme.test")
        Plan.build(options(store, query: "scope:in"), ungated_outbound)
          .targets.map(&.row.host).should eq(["acme.test"])
        # …and a term that legitimately selects nothing is `NoFlows` — an empty RESULT, not a
        # refused query. The two reasons send an operator to different places.
        empty = expect_raises(PlanError) { Plan.build(options(store, query: "scope:out"), ungated_outbound) }
        empty.reason.should eq(PlanError::Reason::NoFlows)
      end
    end

    it "caps how many rows a query may contribute" do
      with_store do |store|
        3.times { |i| seed(store, target: "/p#{i}") }
        plan = Plan.build(options(store, query: "host:acme.test", limit: 2), ungated_outbound)
        plan.targets.size.should eq(2)
      end
    end
  end

  describe "identity resolution" do
    it "reads explicit JSON in the shape Authorize.parse_json already takes" do
      with_store do |store|
        id = seed(store)
        plan = Plan.build(options(store, flow_ids: [id]), ungated_outbound)
        plan.identities.map(&.name).should eq(["as-captured", "anonymous"])
        plan.identities.count(&.baseline?).should eq(1)
        plan.identities[1].remove_headers.should eq(["Cookie"])
      end
    end

    # The SAME settings row the TUI's identities pane writes, so a headless run defaults to
    # the set the operator already configured in the tab.
    it "falls back to the project's saved identities" do
      with_store do |store|
        id = seed(store)
        saved = [Identity.as_captured, Identity.new("low-priv", set_headers: [{"Cookie", "session=USER"}])]
        store.set_setting(Gori::Store::AUTHORIZE_IDENTITIES_KEY, Gori::Authorize.serialize(saved))
        plan = Plan.build(PlanOptions.new(store, flow_ids: [id]), ungated_outbound)
        plan.identities.map(&.name).should eq(["as-captured", "low-priv"])
      end
    end

    # Without this a lone `--identity` would be promoted to baseline by the engine and judged
    # against itself — a run that compares nothing.
    it "prepends the as-captured baseline when no identity claims it" do
      with_store do |store|
        id = seed(store)
        plan = Plan.build(PlanOptions.new(store, flow_ids: [id], identities_json: ONE_IDENT_JSON),
          ungated_outbound)
        plan.identities.map(&.name).should eq(["as-captured", "anonymous"])
        plan.identities.first.baseline?.should be_true
        plan.identities.first.passthrough?.should be_true
      end
    end

    it "keeps the operator's own baseline when the JSON flags one" do
      with_store do |store|
        id = seed(store)
        json = <<-JSON
          [{"name": "admin", "baseline": true, "set": [{"name": "Cookie", "value": "a=1"}]},
           {"name": "user", "set": [{"name": "Cookie", "value": "b=2"}]}]
          JSON
        plan = Plan.build(PlanOptions.new(store, flow_ids: [id], identities_json: json), ungated_outbound)
        plan.identities.map(&.name).should eq(["admin", "user"])
      end
    end

    # The name is the only column that tells the per-identity rows apart, and the TUI's form
    # has always refused a duplicate. The headless surfaces took one and produced a table (and
    # a `bypasses[].identities` array) with two rows under one label.
    it "refuses two identities under one name" do
      with_store do |store|
        id = seed(store)
        json = <<-JSON
          [{"name": "admin", "baseline": true, "set": [{"name": "Cookie", "value": "a=1"}]},
           {"name": "Admin", "set": [{"name": "Cookie", "value": "b=2"}]}]
          JSON
        ex = expect_raises(PlanError) do
          Plan.build(PlanOptions.new(store, flow_ids: [id], identities_json: json), ungated_outbound)
        end
        ex.reason.should eq(Reason::DuplicateIdentity)
        ex.detail.should eq("Admin") # the second one — the row that collided
      end
    end

    # …and the baseline gori PREPENDS must not be the collision. An operator whose own set has
    # a non-baseline "as-captured" would otherwise be told off for a duplicate gori created.
    it "names the prepended baseline around an operator's own as-captured" do
      with_store do |store|
        id = seed(store)
        json = <<-JSON
          [{"name": "as-captured", "set": [], "remove": ["Cookie"]}]
          JSON
        plan = Plan.build(PlanOptions.new(store, flow_ids: [id], identities_json: json), ungated_outbound)
        plan.identities.map(&.name).should eq(["as-captured 2", "as-captured"])
        plan.identities.first.baseline?.should be_true
        plan.identities.first.passthrough?.should be_true
      end
    end
  end

  describe "PlanError" do
    it "NoTarget — neither a flow id nor a query" do
      with_store do |store|
        ex = expect_raises(PlanError) { Plan.build(options(store), ungated_outbound) }
        ex.reason.should eq(Reason::NoTarget)
      end
    end

    # The bare `gori run authorize` on a fresh project — nothing named AND no identities
    # saved. Both are missing, so the order the builder resolves them in decides which
    # mistake the operator is told about. It has to be the one they actually made:
    # `NoIdentities` sends them to configure the Authorize tab, when all they did was
    # forget to name a request. The helper above always supplies identities, so this is
    # the one place the ordering is observable.
    it "NoTarget wins over NoIdentities when neither was supplied" do
      with_store do |store|
        seed(store)
        ex = expect_raises(PlanError) do
          Plan.build(PlanOptions.new(store), ungated_outbound)
        end
        ex.reason.should eq(Reason::NoTarget)
      end
    end

    it "NoFlows — the selection resolved to nothing" do
      with_store do |store|
        seed(store)
        ex = expect_raises(PlanError) { Plan.build(options(store, flow_ids: [9999_i64]), ungated_outbound) }
        ex.reason.should eq(Reason::NoFlows)

        ex2 = expect_raises(PlanError) { Plan.build(options(store, query: "host:nope.test"), ungated_outbound) }
        ex2.reason.should eq(Reason::NoFlows)
        ex2.detail.should eq("host:nope.test")
      end
    end

    # `QL::EMPTY` matches EVERY flow, so a typo would replay the whole history under every
    # identity. Refused, exactly as `gori run history` refuses it.
    it "BadQuery — a query that compiles to no clause at all" do
      with_store do |store|
        seed(store)
        ex = expect_raises(PlanError) { Plan.build(options(store, query: "status:>=foo"), ungated_outbound) }
        ex.reason.should eq(Reason::BadQuery)
        ex.detail.should eq("status:>=foo")
      end
    end

    it "NoIdentities — a set that cannot produce a comparison, naming its source" do
      with_store do |store|
        id = seed(store)
        ex = expect_raises(PlanError) { Plan.build(PlanOptions.new(store, flow_ids: [id], identities_json: "[]"), ungated_outbound) }
        ex.reason.should eq(Reason::NoIdentities)
        ex.detail.should eq("json")

        # A malformed blob degrades to "no identities" in `parse_json`; the emptiness is what
        # gets named rather than swallowed.
        ex2 = expect_raises(PlanError) { Plan.build(PlanOptions.new(store, flow_ids: [id], identities_json: "not json"), ungated_outbound) }
        ex2.reason.should eq(Reason::NoIdentities)

        # Nothing saved on the project either.
        ex3 = expect_raises(PlanError) { Plan.build(PlanOptions.new(store, flow_ids: [id]), ungated_outbound) }
        ex3.reason.should eq(Reason::NoIdentities)
        ex3.detail.should eq("project")
      end
    end

    # DESIGN.md §7 (2026-07-26): a run that sends nothing says so. The per-flow reasons ride
    # on the error, so the refusal can list what it looked at.
    it "NothingToSend — flows were found and every one of them was skipped" do
      with_store do |store|
        a = seed(store, method: "POST", target: "/transfer")
        b = seed(store, method: "DELETE", target: "/orders/1")
        ex = expect_raises(PlanError) { Plan.build(options(store, flow_ids: [a, b]), ungated_outbound) }
        ex.reason.should eq(Reason::NothingToSend)
        ex.skipped.map(&.reason).should eq([:unsafe_method, :unsafe_method])
        ex.skipped.map(&.flow_id).should eq([a, b])
        ex.skipped.first.label.should eq("not a safe method to repeat")
        ex.detail.should eq("2 not a safe method to repeat")
      end
    end
  end

  describe "skip reporting" do
    it "keeps the runnable flows and names each refusal on the plan" do
      with_store do |store|
        ok = seed(store, target: "/admin")
        post = seed(store, method: "POST", target: "/transfer")
        pending = seed(store, target: "/slow", complete: false)
        gori = seed(store, target: "/mocked", short_circuited: true)
        plan = Plan.build(options(store, flow_ids: [ok, post, pending, gori]), ungated_outbound)
        plan.targets.map(&.row.id).should eq([ok])
        plan.skipped.map { |s| {s.flow_id, s.reason} }.should eq([
          {post, :unsafe_method}, {pending, :incomplete}, {gori, :short_circuited},
        ])
      end
    end

    # `--unsafe-methods` is the opt-in a surface offers where a human named the request — the
    # same split the TUI draws between its manual queue and passive replay.
    it "replays an unsafe method only when the surface opted in" do
      with_store do |store|
        id = seed(store, method: "POST", target: "/transfer")
        plan = Plan.build(options(store, flow_ids: [id], unsafe_methods: true), ungated_outbound)
        plan.targets.map(&.row.id).should eq([id])
        plan.skipped.should be_empty
      end
    end

    # Lifting `:unsafe_method` must not lift `:no_effect` behind it. `Passive.skip_reason` is
    # an ordered chain and the unsafe rung comes FIRST, so a builder that simply returns nil
    # there never asks whether any identity changes the request. The cost of getting this
    # wrong is not a spurious row: every trial sends identical bytes, every verdict comes
    # back `Same`, and the run reports a bypass it manufactured — after re-running a POST
    # once per identity to do it.
    it "still declines an unsafe method no identity changes, even with the opt-in" do
      with_store do |store|
        # No Cookie on the wire, so the `anonymous` identity's `remove` is a no-op.
        id = seed(store, method: "POST", target: "/transfer", cookie: false)
        ex = expect_raises(PlanError) do
          Plan.build(options(store, flow_ids: [id], unsafe_methods: true), ungated_outbound)
        end
        ex.reason.should eq(Reason::NothingToSend)
        ex.skipped.map(&.reason).should eq([:no_effect])
      end
    end

    # `:no_effect` — every trial would send identical bytes, so the responses match by
    # construction and the row would read `same`: a finding manufactured out of nothing.
    it "declines a flow no identity actually changes" do
      with_store do |store|
        ok = seed(store, target: "/admin")
        json = <<-JSON
          [{"name": "as-captured", "baseline": true},
           {"name": "nudge", "remove": ["X-Not-Present"]}]
          JSON
        ex = expect_raises(PlanError) do
          Plan.build(PlanOptions.new(store, flow_ids: [ok], identities_json: json), ungated_outbound)
        end
        ex.reason.should eq(Reason::NothingToSend)
        ex.skipped.map(&.reason).should eq([:no_effect])
      end
    end

    # LAYER 1, judged on the DIAL target via `Outbound.scope_url` — not the request line.
    # `Outbound.allowlist` over a project with no include rule refuses everything, which is
    # the strictest surface policy and the one the TUI's passive path picks.
    it "reports a flow the scope gate refuses as out-of-scope rather than sending it" do
      with_store do |store|
        id = seed(store, target: "/admin")
        gated = Gori::Outbound.allowlist(Gori::Scope.load(store))
        ex = expect_raises(PlanError) { Plan.build(options(store, flow_ids: [id]), gated) }
        ex.reason.should eq(Reason::NothingToSend)
        ex.skipped.map(&.reason).should eq([:out_of_scope])
        ex.skipped.first.label.should eq("outside project scope")
      end
    end

    it "leaves an in-scope flow alone once the project includes it" do
      with_store do |store|
        id = seed(store, target: "/admin")
        store.add_scope_rule("include", "host", "acme.test")
        store.flush
        gated = Gori::Outbound.allowlist(Gori::Scope.load(store))
        plan = Plan.build(options(store, flow_ids: [id]), gated)
        plan.targets.map(&.row.id).should eq([id])
      end
    end
  end

  describe "#run" do
    it "replays every target under every identity and yields each finished Target" do
      with_store do |store|
        a = seed(store, target: "/admin")
        b = seed(store, target: "/orders")
        built = Plan.build(options(store, flow_ids: [a, b]), ungated_outbound)
        backend = FakeBackend.new(Gori::Fuzz::Origin.new("https", "acme.test", 443))
        plan = Plan.new(engine: fake_engine(backend), identities: built.identities,
          targets: built.targets, skipped: built.skipped)

        seen = [] of Gori::Authorize::Target
        sent = plan.run { |_detail, target| seen << target }
        sent.should eq(2)
        seen.map(&.url).should eq(["https://acme.test/admin", "https://acme.test/orders"])
        seen.each(&.trials.size.should(eq(2)))
        backend.sent.size.should eq(4)
        # The anonymous identity's overlay reached the wire.
        backend.sent.count { |wire| String.new(wire).includes?("Cookie:") }.should eq(2)
      end
    end

    # A stop that lands part-way through one request's identities yields NOTHING for it: a
    # partial set of trials must not become a Target (see `Engine#run`).
    it "stops between requests and never yields a half-run one" do
      with_store do |store|
        a = seed(store, target: "/admin")
        b = seed(store, target: "/orders")
        built = Plan.build(options(store, flow_ids: [a, b]), ungated_outbound)
        backend = FakeBackend.new(Gori::Fuzz::Origin.new("https", "acme.test", 443))
        plan = Plan.new(engine: fake_engine(backend), identities: built.identities,
          targets: built.targets, skipped: built.skipped)

        seen = 0
        stop = false
        sent = plan.run(-> { stop }) { |_d, _t| seen += 1; stop = true }
        sent.should eq(1)
        seen.should eq(1)
        backend.sent.size.should eq(2) # only the first request's two identities
      end
    end

    # A few flows RAISE before any send — a stored h2 pseudo-header head is the reachable one
    # (`FlowRequest::PseudoHeaderHead`). Letting that escape the loop cost the whole selection:
    # `gori run authorize` lost every remaining flow AND its buffered `--format json` array,
    # and an MCP job went `:error` holding results it had already collected. The TUI never had
    # the problem, because its own loop rescues per request.
    describe "a flow that cannot be replayed at all" do
      it "reports it through on_error and replays the rest" do
        with_store do |store|
          bad = pseudo_header_seed(store)
          good = seed(store, target: "/orders")
          built = Plan.build(options(store, flow_ids: [bad, good]), ungated_outbound)
          built.targets.size.should eq(2) # nothing about it is a SKIP — it looks replayable
          backend = FakeBackend.new(Gori::Fuzz::Origin.new("https", "acme.test", 443))
          plan = Plan.new(engine: fake_engine(backend), identities: built.identities,
            targets: built.targets, skipped: built.skipped)

          failures = [] of {Int64, String}
          replayed = [] of String
          sent = plan.run(nil, ->(d : Gori::Store::FlowDetail, ex : Exception) {
            failures << {d.row.id, ex.class.name}
            nil
          }) { |d, _t| replayed << d.row.target }

          sent.should eq(1)
          replayed.should eq(["/orders"])
          failures.map(&.[0]).should eq([bad])
          failures.first[1].should eq("Gori::Repeater::FlowRequest::PseudoHeaderHead")
        end
      end

      # Absent a handler the raise still escapes: a surface has to DECIDE what to do with an
      # unreplayable flow rather than inherit silence from the seam.
      it "still raises when the caller passed no on_error" do
        with_store do |store|
          bad = pseudo_header_seed(store)
          built = Plan.build(options(store, flow_ids: [bad]), ungated_outbound)
          backend = FakeBackend.new(Gori::Fuzz::Origin.new("https", "acme.test", 443))
          plan = Plan.new(engine: fake_engine(backend), identities: built.identities,
            targets: built.targets, skipped: built.skipped)
          expect_raises(Gori::Repeater::FlowRequest::PseudoHeaderHead) do
            plan.run { |_d, _t| }
          end
        end
      end
    end
  end
end

# A `--query body:…` selection drains the off-commit trigram index (Store V4) before selecting
# rows, because an under-reporting query here means REPLAYING FEWER FLOWS than asked — and an
# access-control sweep that quietly skipped flows reports the same "no bypasses found" as one
# that actually looked at them.
#
# `index_pending!` reports a batch that lost SQLite's single writer slot to a capturing peer as
# "0 indexed" and takes its `break if n == 0` there (Store#index_pending!), so it returns
# normally with rows still dirty and the drain's return says nothing. The peer connection stands
# in for that second gori: SQLite locks per CONNECTION, so one pool holding BEGIN IMMEDIATE is
# the same contention a second process produces. `busy_timeout=1` skips the real 5 s wait.
private def contended_authz_store(&)
  path = File.tempname("gori-authz-fts", ".db")
  url = "sqlite3:#{path}?journal_mode=wal&busy_timeout=1"
  db = DB.open(url)
  Gori::Store::Schema.migrate!(db)
  store = Gori::Store.new(db, nil)
  # Without this the idle indexer drains the backlog within one FAST tick (5 ms), before the peer
  # lock can be taken. Pausing it is a real product state (#752); the explicit `index_pending!`
  # under test is an op on the write channel and still runs.
  store.pause_background_index
  peer = DB.open(url)
  begin
    yield store, peer
  ensure
    done = Channel(Nil).new(1)
    spawn do
      store.close
      done.send(nil)
    end
    select
    when done.receive
      # closed cleanly
    when timeout(20.seconds)
      # a wedged writer must fail the example, never hang the run
    end
    peer.close rescue nil
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def while_authz_peer_writes(peer : DB::Database, &)
  lock = peer.checkout
  lock.exec("BEGIN IMMEDIATE")
  begin
    yield
  ensure
    lock.exec("ROLLBACK") rescue nil
    lock.release rescue nil
  end
end

# `seed` above flushes (which drains the index); this one deliberately does not, and gives the
# response a body carrying `needle` (≥3 chars → QL's trigram path, not the `instr` fallback).
private def seed_dirty_authz_flow(store, needle : String) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: "/admin", http_version: "HTTP/1.1",
    head: "GET /admin HTTP/1.1\r\nHost: acme.test\r\nCookie: session=ADMIN\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n".to_slice,
    body: "<p>#{needle}</p>".to_slice, content_type: "text/html", duration_us: 1_000_i64))
  id
end

describe "Authorize::Plan — a body: selection whose FTS drain did not finish" do
  it "refuses the whole plan rather than replaying the flows it could see" do
    contended_authz_store do |store, peer|
      seed_dirty_authz_flow(store, "needleone")
      store.fts_backlog.should be > 0 # the drain has real work to fail at

      ex = nil.as(Exception?)
      while_authz_peer_writes(peer) do
        ex = expect_raises(Gori::Error) do
          Plan.build(options(store, query: "body:needleone"), ungated_outbound)
        end
      end
      # NOT a PlanError: every `PlanError::Reason` arm on both surfaces concatenates its own tail
      # to the message, and `BadQuery`'s ("a query that compiles to no clause matches EVERY
      # captured flow") would contradict this sentence for whoever reads it.
      #
      # It also has to be distinguishable from what HEAD raised HERE, which was
      # `PlanError(NoFlows)` — "no captured flows matched the selection", about a flow that was
      # sitting in the store the whole time. That is the lie, in the surface's own words.
      ex.should_not be_a(PlanError)
      msg = ex.not_nil!.message.not_nil!
      msg.should contain("1 flow could not be indexed")
      msg.should contain("clean sweep")
      msg.should contain("Nothing was sent")
    end
  end

  # The complement, and what stops the guard from being unconditional: with the writer free the
  # drain finishes and the same query selects its flow.
  it "plans the flow once the drain actually completes" do
    contended_authz_store do |store, _peer|
      id = seed_dirty_authz_flow(store, "needletwo")
      plan = Plan.build(options(store, query: "body:needletwo"), ungated_outbound)
      plan.targets.map(&.row.id).should eq([id])
      store.fts_backlog.should eq(0) # it drained here — not a pre-indexed pass
    end
  end

  # A query that never reads `flows_fts` must not be refused by a backlog it does not depend on.
  it "leaves a non-FTS query alone while the backlog is stuck" do
    contended_authz_store do |store, peer|
      id = seed_dirty_authz_flow(store, "needlethree")
      while_authz_peer_writes(peer) do
        plan = Plan.build(options(store, query: "host:acme.test"), ungated_outbound)
        plan.targets.map(&.row.id).should eq([id])
      end
    end
  end
end

describe "Gori::Authorize::Passive provenance" do
  # Passive replay follows the BROWSER. Since the Repeater records its sends by default, a flow
  # gori itself put on the wire now arrives on the same live feed — and replaying it fans one
  # `^R` out into a shadow request per identity while telling the operator nothing they did not
  # just ask for. `AuthorizeController`'s watcher comment used to argue a self-loop was
  # structurally impossible; the `source` column is the explicit marker it said would be needed.
  it "declines a flow gori sent, by name, on the unattended path" do
    with_store do |store|
      idents = Gori::Authorize.parse_json(IDENTS_JSON)
      sent_by_gori = store.get_flow(seed(store, source: Gori::FlowSource::Kind::Repeater)).not_nil!
      Gori::Authorize::Passive.passive_skip_reason(sent_by_gori, idents).should eq(:gori_originated)
      Gori::Authorize::Passive.reason_label(:gori_originated).should eq("sent by gori, not the browser")
    end
  end

  it "still replays what the browser produced, and what somebody else captured" do
    with_store do |store|
      idents = Gori::Authorize.parse_json(IDENTS_JSON)
      captured = store.get_flow(seed(store, source: Gori::FlowSource::Kind::Proxy)).not_nil!
      Gori::Authorize::Passive.passive_skip_reason(captured, idents).should be_nil
      # An import is not gori's traffic: it describes a real endpoint somebody captured, and
      # replaying it is exactly what an operator handed a HAR wants.
      imported = store.get_flow(seed(store, target: "/orders",
        source: Gori::FlowSource::Kind::Import)).not_nil!
      Gori::Authorize::Passive.passive_skip_reason(imported, idents).should be_nil
    end
  end

  it "replays a flow gori sent when a HUMAN named it" do
    # The refusal is about UNATTENDED fan-out, not about the bytes. Every explicit path — the
    # manual queue, `gori run authorize 42`, MCP `authorize_start{flow_ids}` — asks
    # `skip_reason` / `manual_skip_reason`, neither of which consults provenance.
    with_store do |store|
      idents = Gori::Authorize.parse_json(IDENTS_JSON)
      id = seed(store, source: Gori::FlowSource::Kind::Repeater)
      detail = store.get_flow(id).not_nil!
      Gori::Authorize::Passive.skip_reason(detail, idents).should be_nil
      Gori::Authorize::Passive.manual_skip_reason(detail, idents).should be_nil
      plan = Plan.build(options(store, flow_ids: [id]), ungated_outbound)
      plan.targets.map(&.row.id).should eq([id])
    end
  end

  it "leaves a pre-provenance flow replayable" do
    # Those rows are overwhelmingly proxy captures — nothing else recorded by default when they
    # were written — so reading "not recorded" as "gori's own" would switch passive replay off
    # for every project captured with an older gori.
    with_store do |store|
      idents = Gori::Authorize.parse_json(IDENTS_JSON)
      detail = store.get_flow(seed(store)).not_nil!
      row = detail.row
      legacy = Gori::Store::FlowRow.new(row.id, row.created_at, row.scheme, row.method, row.host,
        row.port, row.target, row.status, row.size, row.state, row.response_size,
        row.duration_us, row.content_type)
      Gori::Authorize::Passive.gori_originated?(legacy).should be_false
    end
  end
end
