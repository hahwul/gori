require "./spec_helper"

# The slot REGISTRY: the persisted list, the active pointer, and the overlay a send seam asks
# for. `spec/session_slot_spec.cr` covers the value type; this covers what is shared and
# mutable, which is where the failure modes are.

private alias Slot = Gori::SessionSlot

private def with_store(&)
  path = File.tempname("gori-slots", ".db")
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

# The overlay resolver a send seam supplies. `Bindings` passes `Env.expand_bindings`; a spec
# that only cares about the plumbing passes something it can read.
private def slot_overlay(slots : Gori::SessionSlots, wire : String,
                         vars : Hash(String, String) = {} of String => String) : String
  String.new(slots.overlay(wire.to_slice) { |v| vars.reduce(v) { |acc, (k, val)| acc.sub("$#{k}", val) } })
end

describe Gori::SessionSlots do
  describe "persistence" do
    it "saves and reloads the list through the project settings row" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.slots.should be_empty
        slots.save([Slot.new("admin", set_headers: [{"Cookie", "s=1"}], rules: ["SESSION"])]).should be_true

        fresh = Gori::SessionSlots.load(store)
        fresh.slots.map(&.name).should eq(["admin"])
        fresh.slots.first.rules.should eq(["SESSION"])
      end
    end

    # ONE row for both names. An operator who configured identities in the Authorize tab has
    # configured slots, and the reverse — anything else and "the admin session" means two
    # things (DESIGN.md §7, 2026-08-17).
    it "shares the Authorize identities row, in both directions" do
      with_store do |store|
        store.set_setting(Gori::Store::AUTHORIZE_IDENTITIES_KEY,
          Gori::Authorize.serialize([Gori::Authorize::Identity.new("admin", set_headers: [{"Cookie", "s=1"}])]))
        Gori::SessionSlots.load(store).slots.map(&.name).should eq(["admin"])

        Gori::SessionSlots.load(store).save([Slot.new("low-priv", rules: ["SESSION"])]).should be_true
        Gori::Authorize.parse_json(store.setting(Gori::Store::AUTHORIZE_IDENTITIES_KEY))
          .map(&.name).should eq(["low-priv"])
        Gori::Store::SESSION_SLOTS_KEY.should eq(Gori::Store::AUTHORIZE_IDENTITIES_KEY)
      end
    end

    it "reports a failed write rather than pretending the list changed" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        store.close
        slots.save([Slot.new("admin")]).should be_false
        slots.slots.should be_empty
      end
    end

    it "picks up an external edit on reload" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        store.set_setting(Gori::Store::SESSION_SLOTS_KEY, Slot.serialize([Slot.new("peer")]))
        slots.slots.should be_empty
        slots.reload
        slots.slots.map(&.name).should eq(["peer"])
      end
    end
  end

  describe "the active slot" do
    it "starts as nil — as-captured, no overlay, which is what every project opens as" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("admin", set_headers: [{"Cookie", "s=1"}])])
        slots.active.should be_nil
        slots.active_name.should be_nil
        wire = "GET / HTTP/1.1\r\nHost: h\r\n\r\n"
        slot_overlay(slots, wire).should eq(wire)
      end
    end

    it "refuses an unknown name instead of silently leaving the previous slot active" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("admin", set_headers: [{"Cookie", "s=1"}])])
        slots.activate("admin").should be_true
        slots.activate("adnim").should be_false
        # Still admin — a typo must not quietly send as somebody else, and must not
        # quietly send as nobody either.
        slots.active_name.should eq("admin")
        slots.activate(nil).should be_true
        slots.active.should be_nil
      end
    end

    it "drops the active pointer when the slot it names is saved away" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("admin", set_headers: [{"Cookie", "s=1"}])])
        slots.activate("admin")
        slots.save([Slot.new("anon", remove_headers: ["Cookie"])]).should be_true
        slots.active.should be_nil
        # …and on a reload that removes it, the same answer.
        slots.save([Slot.new("anon", remove_headers: ["Cookie"]), Slot.new("admin")])
        slots.activate("admin").should be_true
        store.set_setting(Gori::Store::SESSION_SLOTS_KEY, Slot.serialize([Slot.new("anon")]))
        slots.reload
        slots.active.should be_nil
      end
    end

    it "bumps rev on every activation, so a cached snapshot repaints on a context switch" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("a"), Slot.new("b")])
        before = slots.rev
        slots.activate("a")
        slots.rev.should be > before
        mid = slots.rev
        slots.activate("b")
        slots.rev.should be > mid
      end
    end
  end

  describe "rule membership" do
    it "answers scoped? off the whole list and names every claimed rule once" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("admin", rules: ["SESSION"]), Slot.new("user", rules: ["SESSION", "CSRF"])])
        slots.scoped?.should be_true
        slots.claimed_names.should eq(Set{"SESSION", "CSRF"})
        slots.names.should eq(["admin", "user"])

        slots.save([Slot.new("anon", remove_headers: ["Cookie"])])
        slots.scoped?.should be_false
        slots.claimed_names.should be_empty
      end
    end
  end

  describe "#overlay" do
    it "applies the active slot's set and remove, header-only" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("anon", remove_headers: ["Cookie"], set_headers: [{"X-Role", "none"}])])
        slots.activate("anon")
        wire = "POST /p HTTP/1.1\r\nHost: h\r\nCookie: real=1\r\nContent-Length: 3\r\n\r\nabc"
        sent = slot_overlay(slots, wire)
        sent.should_not contain("Cookie: real=1")
        sent.should contain("X-Role: none")
        sent.should contain("Content-Length: 3")
        sent.should end_with("\r\n\r\nabc")
      end
    end

    it "resolves a reference the operator wrote into a slot header value" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("admin", set_headers: [{"Authorization", "Bearer $SESSION"}], rules: ["SESSION"])])
        slots.activate("admin")
        sent = slot_overlay(slots, "GET / HTTP/1.1\r\nHost: h\r\n\r\n", {"SESSION" => "ADMINTOKEN"})
        sent.should contain("Authorization: Bearer ADMINTOKEN")
      end
    end

    it "returns the SAME slice when the active slot is a passthrough" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.as_captured])
        slots.activate("as-captured").should be_true
        wire = "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
        sent = slots.overlay(wire) { |v| v }
        sent.to_unsafe.should eq(wire.to_unsafe)
      end
    end
  end
end
