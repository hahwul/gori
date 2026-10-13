require "../spec_helper"

# #1601 — the project-wide request budget. Two `Store`s on one file stand in for two gori
# processes: each has its own writer connection and its own `Budget`, so the only thing they
# share is the settings table the leases go through.

private alias Budget = Gori::Outbound::Budget

private def set_budget(store : Gori::Store, rps : String? = nil, max : String? = nil) : Nil
  store.set_settings([{Gori::Settings::PROJECT_OUTBOUND_MAX_RPS_KEY, rps},
                      {Gori::Settings::PROJECT_OUTBOUND_MAX_REQUESTS_KEY, max}] of {String, String?})
end

private def spent(store : Gori::Store) : String?
  store.setting(Gori::Store::OUTBOUND_BUDGET_SPENT_KEY)
end

# Two connections on one project DB, closed and deleted on the way out (see `with_store`).
private def with_two_stores(read_only : Bool = false, &)
  path = File.tempname("gori-spec", ".db")
  a = Gori::Store.open(path)
  b = Gori::Store.open(path, read_only: read_only)
  raised = run_capturing { yield a, b }
  a.close
  b.close
  delete_db_files(path)
  raise raised if raised
end

describe Gori::Outbound::Budget do
  it "admits everything and writes nothing when no ceiling is set" do
    with_store do |store|
      b = Budget.new(store)
      b.configured?.should be_false
      5.times { b.admit(nil).should be_nil }
      store.setting(Gori::Store::OUTBOUND_BUDGET_NEXT_KEY).should be_nil
      spent(store).should be_nil
    end
  end

  it "refuses the request after the total, and holds it across processes" do
    with_two_stores do |store, peer|
      set_budget(store, max: "10")
      a = Budget.new(store)
      b = Budget.new(peer)
      sent = 0
      20.times { sent += 1 if a.admit(nil).nil? }
      20.times { sent += 1 if b.admit(nil).nil? }
      sent.should eq(10)
      b.admit(nil).should eq(Gori::Outbound::BUDGET_SPENT_ERROR)
      Gori::Outbound.permanent_refusal?(Gori::Outbound::BUDGET_SPENT_ERROR).should be_true
    end
  end

  it "leases at most a quarter of what is left, so an idle process cannot hoard the total" do
    with_two_stores do |store, peer|
      set_budget(store, max: "8")
      Budget.new(store).admit(nil).should be_nil # a lease of 2, one left unsent and never released
      b = Budget.new(peer)
      sent = 0
      20.times { sent += 1 if b.admit(nil).nil? }
      sent.should eq(6)
    end
  end

  it "hands a lease back when its store closes, whoever closes it" do
    path = File.tempname("gori-spec", ".db")
    a = Gori::Store.open(path)
    set_budget(a, max: "100")
    Gori::Outbound.agent(Gori::Scope.load(a), false).admit.should be_nil # an MCP send, store not owned
    spent(a).should eq(Budget::COUNT_LEASE.to_s)
    a.close
    b = Gori::Store.open(path)
    spent(b).should eq("1")
    b.close
    delete_db_files(path)
  end

  it "hands the unsent part of a lease back on release" do
    with_store do |store|
      set_budget(store, max: "100")
      a = Budget.new(store)
      3.times { a.admit(nil).should be_nil }
      spent(store).should eq(Budget::COUNT_LEASE.to_s) # one lease claimed
      a.release
      spent(store).should eq("3")
    end
  end

  it "releases the lease a store's Outbounds took when that store is done" do
    with_store do |store|
      set_budget(store, max: "100")
      Budget.release(store) # nothing built yet: no lease, no write
      spent(store).should be_nil
      2.times { Gori::Outbound.cli(Gori::Scope.load(store), true).admit.should be_nil }
      Budget.release(store)
      spent(store).should eq("2")
      Budget.release(store) # forgotten: a second close hands nothing back twice
      spent(store).should eq("2")
    end
  end

  it "paces two processes together to the shared rate" do
    with_two_stores do |store, peer|
      set_budget(store, rps: "20")
      a = Budget.new(store)
      b = Budget.new(peer)
      start = Time.instant
      done = Channel(Nil).new
      [a, b].each { |bud| spawn { 10.times { bud.admit(nil).should be_nil }; done.send(nil) } }
      2.times { done.receive }
      # 20 slots 50ms apart: ≥ 19 gaps, less a lease of slack at the start.
      (Time.instant - start).should be > 0.75.seconds
    end
  end

  it "ends a wait for a slot within a nap slice when the run halts" do
    with_store do |store|
      set_budget(store, rps: "0.5") # one slot every 2s
      b = Budget.new(store)
      b.admit(nil).should be_nil
      halted = false
      spawn { sleep 50.milliseconds; halted = true }
      start = Time.instant
      b.admit(-> { halted }).should eq(Gori::Outbound::BUDGET_STOPPED_ERROR)
      (Time.instant - start).should be < Gori::Pacing::NAP_SLICE + 200.milliseconds
    end
  end

  it "is shared by every Outbound over one store" do
    with_store do |store|
      set_budget(store, max: "1")
      scope = Gori::Scope.load(store)
      Gori::Outbound.interactive(scope).admit.should be_nil
      Gori::Outbound.interactive(Gori::Scope.load(store)).admit.should eq(Gori::Outbound::BUDGET_SPENT_ERROR)
      ungated_outbound.admit.should be_nil # no project, no budget
    end
  end

  # MCP and the TUI Repeater build a fresh Outbound per send, so the reload cannot ride on one.
  it "sees a ceiling set, then cleared, mid-session through per-send Outbounds" do
    with_store do |store|
      Gori::Outbound.interactive(Gori::Scope.load(store)).admit.should be_nil
      set_budget(store, max: "2")
      sleep Gori::Outbound::RELOAD_INTERVAL + 100.milliseconds
      sent = 0
      5.times { sent += 1 if Gori::Outbound.interactive(Gori::Scope.load(store)).admit.nil? }
      sent.should eq(2)
      set_budget(store) # the operator unsets the total
      sleep Gori::Outbound::RELOAD_INTERVAL + 100.milliseconds
      Gori::Outbound.interactive(Gori::Scope.load(store)).admit.should be_nil
    end
  end

  it "refunds the slots a multi-slot admit took before it was refused" do
    with_store do |store|
      set_budget(store, max: "10")
      ob = Gori::Outbound.interactive(Gori::Scope.load(store))
      7.times { ob.admit.should be_nil }
      ob.admit(5).should eq(Gori::Outbound::BUDGET_SPENT_ERROR) # a 5-member race, 3 left
      Budget.for(store).release
      spent(store).should eq("7")
    end
  end

  # The CLI hands most commands a READ-ONLY store, which has no writer at all.
  it "leases through a read-only store too" do
    with_two_stores(read_only: true) do |store, ro|
      set_budget(store, max: "2")
      b = Budget.new(ro)
      2.times { b.admit(-> { false }).should be_nil }
      b.admit(nil).should eq(Gori::Outbound::BUDGET_SPENT_ERROR)
      spent(store).should eq("2")
    end
  end

  it "does not stall on a slot a slower rate left far ahead" do
    with_store do |store|
      set_budget(store, rps: "0.01") # one slot every 100s
      b = Budget.new(store)
      b.admit(nil).should be_nil
      set_budget(store, rps: "100")
      b.reload
      start = Time.instant
      b.admit(nil).should be_nil
      (Time.instant - start).should be < 1.second
    end
  end

  it "lets a halted run stop while another fiber waits for the shared clock" do
    with_store do |store|
      set_budget(store, rps: "0.5")
      b = Budget.new(store)
      b.admit(nil).should be_nil
      spawn { b.admit(nil) } # no halt: waits ~2s for the next slot
      Fiber.yield
      halted = false
      spawn { sleep 50.milliseconds; halted = true }
      start = Time.instant
      b.admit(-> { halted }).should eq(Gori::Outbound::BUDGET_STOPPED_ERROR)
      (Time.instant - start).should be < Gori::Pacing::NAP_SLICE + 200.milliseconds
    end
  end
end
