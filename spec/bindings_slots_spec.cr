require "./spec_helper"

# `Bindings` namespaced by session slots (DESIGN.md §7, 2026-08-17).
#
# The property under test is a COMPATIBILITY one first and a feature one second: a project
# with no slots — every project that existed before this — must behave byte for byte the way
# it did, and a project WITH slots must keep two identities' credentials apart in memory,
# resolve the active one, and still never write either to disk.

private alias Slot = Gori::SessionSlot

private def with_store(&)
  path = File.tempname("gori-binding-slots", ".db")
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

private def with_layer(bindings : Gori::Bindings?, &)
  previous = Gori::Env.layer
  Gori::Env.layer = bindings
  begin
    yield
  ensure
    Gori::Env.layer = previous
  end
end

private def response_result(head : String, body : String = "") : Gori::Repeater::Result
  bytes = head.to_slice
  Gori::Repeater::Result.new(bytes, body.to_slice,
    Gori::Proxy::Codec::Http1.parse_response_head(bytes), 1_i64, nil)
end

private def subject(host : String = "acme.test", target : String = "/login") : Gori::InterceptFilter::Subject
  Gori::InterceptFilter::Subject.new(method: "POST", host: host, target: target,
    scheme: "https", status: 200)
end

private def login(value : String) : Gori::Repeater::Result
  response_result("HTTP/1.1 200 OK\r\nSet-Cookie: sid=#{value}; Path=/\r\nContent-Length: 0\r\n\r\n")
end

describe "Bindings × session slots" do
  describe "an unscoped rule (no slot claims it)" do
    it "writes the one global table, whatever slot is active" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("admin", set_headers: [{"X-Who", "admin"}])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil

        b.observe(login("GLOBAL1"), subject).should eq(["SESSION"])
        b.values["SESSION"].should eq("GLOBAL1")

        # Activating a slot changes nothing for a rule that slot does not claim: it is the
        # SAME table before and after, which is the whole "existing playbooks keep working"
        # guarantee (docs/content/playbooks/carry-a-session.md).
        slots.activate("admin")
        b.values["SESSION"].should eq("GLOBAL1")
        b.observe(login("GLOBAL2"), subject).should eq(["SESSION"])
        b.values["SESSION"].should eq("GLOBAL2")
        slots.activate(nil)
        b.values["SESSION"].should eq("GLOBAL2")
        b.rows.map(&.slot).should eq([nil])
      end
    end

    it "behaves identically with no slot registry at all" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.slots.should be_nil
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        b.observe(login("PLAIN"), subject).should eq(["SESSION"])
        b.values["SESSION"].should eq("PLAIN")
        b.bound?("SESSION").should be_true
      end
    end
  end

  describe "a scoped rule (some slot claims it)" do
    it "runs only under the slot that claims it, and binds into that slot's table" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([
          Slot.new("admin", set_headers: [{"Cookie", "sid=$SESSION"}], rules: ["SESSION"]),
          Slot.new("user", set_headers: [{"Cookie", "sid=$SESSION"}], rules: ["SESSION"]),
        ])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil

        # No slot active: the rule is CLAIMED, so it is not a candidate at all.
        b.observe(login("NOBODY"), subject).should be_empty
        b.values.should be_empty

        slots.activate("admin")
        b.observe(login("ADMINTOKEN"), subject).should eq(["SESSION"])
        slots.activate("user")
        b.observe(login("USERTOKEN"), subject).should eq(["SESSION"])

        # Two identities, two live values, and the ACTIVE one is what resolves.
        b.values["SESSION"].should eq("USERTOKEN")
        slots.activate("admin")
        b.values["SESSION"].should eq("ADMINTOKEN")
        slots.activate(nil)
        b.values.should be_empty
      end
    end

    it "shadows a global name for the active slot only" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("admin", rules: ["SESSION"])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        b.add("CSRF", "", Gori::ExtractKind::Header, "x-csrf")

        # CSRF is unscoped and binds globally; SESSION is claimed and binds into admin.
        slots.activate("admin")
        b.observe(response_result(
          "HTTP/1.1 200 OK\r\nSet-Cookie: sid=ADMINTOKEN; Path=/\r\nX-CSRF: C1\r\nContent-Length: 0\r\n\r\n"),
          subject).sort.should eq(["CSRF", "SESSION"])

        b.values.should eq({"CSRF" => "C1", "SESSION" => "ADMINTOKEN"})
        # Deactivate: the global half survives, the slot half stops resolving.
        slots.activate(nil)
        b.values.should eq({"CSRF" => "C1"})
      end
    end

    it "reports one row per claiming slot, each with its own value" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("admin", rules: ["SESSION"]), Slot.new("user", rules: ["SESSION"])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        slots.activate("admin")
        b.observe(login("ADMINTOKEN"), subject)

        rows = b.rows
        rows.map(&.slot).should eq(["admin", "user"])
        rows[0].value.should eq("ADMINTOKEN")
        rows[0].bound?.should be_true
        rows[1].value.should be_nil
        rows[1].bound?.should be_false
      end
    end
  end

  describe "the memory-only guarantee" do
    it "keeps a slot's value out of the project DB, exactly as a global one" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("admin", rules: ["SESSION"])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        slots.activate("admin")
        b.observe(login("ADMINTOKEN"), subject).should eq(["SESSION"])

        # The RULE persisted and the MEMBERSHIP persisted; the value did not.
        raw = store.setting(Gori::Store::SESSION_SLOTS_KEY).not_nil!
        raw.should contain("SESSION")
        raw.should_not contain("ADMINTOKEN")
        reopened = Gori::SessionSlots.load(store)
        Gori::Bindings.load(store, reopened).values.should be_empty
        reopened.active.should be_nil
      end
    end

    # Masking is the one read that must see EVERY table: two identities holding two different
    # `$SESSION` values are two secrets, and folding them by name would print one of them.
    it "masks every slot's value, not just the active one" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("admin", rules: ["SESSION"]), Slot.new("user", rules: ["SESSION"])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        slots.activate("admin")
        b.observe(login("ADMINTOKENAAA"), subject)
        slots.activate("user")
        b.observe(login("USERTOKENBBB"), subject)

        with_layer(b) do
          held = Gori::Env.masking_vars
          held.values.includes?("ADMINTOKENAAA").should be_true
          held.values.includes?("USERTOKENBBB").should be_true
          masked = Gori::Env.mask_secrets("a=ADMINTOKENAAA b=USERTOKENBBB")
          masked.should_not contain("ADMINTOKENAAA")
          masked.should_not contain("USERTOKENBBB")
        end
      end
    end
  end

  describe "clearing" do
    it "clears one slot's value and leaves the other's, then clear_all takes both" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("admin", rules: ["SESSION"]), Slot.new("user", rules: ["SESSION"])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        slots.activate("admin")
        b.observe(login("ADMINTOKEN"), subject)
        slots.activate("user")
        b.observe(login("USERTOKEN"), subject)

        # Names the table, rather than meaning "whichever one is active" — the difference the
        # deleted `clear` blurred. Its global half is `clear_row(name, nil)`, covered below.
        b.clear_row("SESSION", "user")
        b.values.should be_empty
        slots.activate("admin")
        b.values["SESSION"].should eq("ADMINTOKEN")

        b.clear_all
        slots.activate("user")
        b.values.should be_empty
        slots.activate("admin")
        b.values.should be_empty
      end
    end

    it "drops a deleted rule's value from every slot table" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("admin", rules: ["SESSION"])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        slots.activate("admin")
        b.observe(login("ADMINTOKEN"), subject)
        b.values["SESSION"].should eq("ADMINTOKEN")

        b.remove(b.rules.first.id).should be_true
        b.values.should be_empty
        with_layer(b) { Gori::Env.masking_vars.values.includes?("ADMINTOKEN").should be_false }
      end
    end
  end

  # `Bindings` keys its per-slot tables by slot NAME, and a name is reusable: delete an
  # identity, create a different one under the same name, and the dead identity's credential
  # would resolve for it — a live token from a session the operator deliberately discarded,
  # sent under a slot that never observed it. So the registry tells `Bindings` which names
  # survive every list edit, and the tables of the ones that did not are dropped.
  describe "a deleted slot's name" do
    it "does not resolve a deleted slot's value under a NEW slot that reuses its name" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("admin", rules: ["SESSION"])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        slots.activate("admin")
        b.observe(login("ADMINTOKEN"), subject)
        b.values["SESSION"].should eq("ADMINTOKEN")

        # The operator rotates identities: delete "admin", create a DIFFERENT identity that
        # happens to reuse the name, activate it, and send before anything has re-bound.
        slots.remove("admin").should be_true
        slots.add(Slot.new("admin", rules: ["SESSION"])).should be_true
        slots.activate("admin").should be_true

        b.values["SESSION"]?.should be_nil
        b.values.should be_empty
        b.bound?("SESSION").should be_false
      end
    end

    # The guard on the other side: a list edit that KEEPS a slot must not touch its table.
    # `add`/`set_baseline` hand `save` freshly-constructed `SessionSlot` objects carrying the
    # same names, so a prune keyed on object identity would wipe a live token on an unrelated
    # edit.
    it "keeps a surviving slot's value across an unrelated list edit" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("admin", rules: ["SESSION"])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        slots.activate("admin")
        b.observe(login("ADMINTOKEN"), subject)

        slots.add(Slot.new("user", rules: ["SESSION"])).should be_true
        slots.set_baseline("user").should be_true
        slots.activate("admin").should be_true
        b.values["SESSION"].should eq("ADMINTOKEN")
      end
    end

    # The OUT-OF-PROCESS shape of the same rotation, and the reason a surviving name is not a
    # key a `reload` can use: a peer's `gori run session remove admin` and `session add admin`
    # are two writes, and this process only ever sees the row they land on. `admin` is present
    # on both sides of a write that discarded the identity, so the name set says "nothing to
    # prune" about the exact case the prune exists for. What DID move is the persisted row.
    it "does not resolve it after a peer deleted and re-created the slot between reloads" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("admin", set_headers: [{"Cookie", "sid=$SESSION"}], rules: ["SESSION"])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
        slots.activate("admin")
        b.observe(login("ADMINTOKEN"), subject)
        b.values["SESSION"].should eq("ADMINTOKEN")

        # Two peer writes, one net row: `admin` is gone and then back for a DIFFERENT identity.
        store.set_setting(Gori::Store::SESSION_SLOTS_KEY, Slot.serialize([] of Slot))
        store.set_setting(Gori::Store::SESSION_SLOTS_KEY,
          Slot.serialize([Slot.new("admin", set_headers: [{"Cookie", "sid=$SESSION"}],
            remove_headers: ["Authorization"], rules: ["SESSION"])]))
        slots.reload
        slots.activate("admin").should be_true

        # The dead identity's live credential must not be what this slot's `$SESSION` resolves
        # to: nothing has been observed under the new admin, so nothing resolves.
        b.values["SESSION"]?.should be_nil
        b.bound?("SESSION").should be_false
      end
    end

    # The other half, and what makes the reload safe to call on the TUI's `data_version` tick
    # (`Runner#apply_external_change`, ~1×/sec, own captures included): a reload that finds the
    # row exactly as this process last read or wrote it is not a list edit at all. It must
    # neither drop a table nor move the revision `Rules#subst_snapshot` memoises against on the
    # proxy path — an unconditional prune on that cadence would wipe every live token.
    it "keeps every table across a reload that finds the row unmoved" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("admin", rules: ["SESSION"])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        slots.activate("admin")
        b.observe(login("ADMINTOKEN"), subject)
        before = b.rev

        slots.reload
        slots.reload
        b.values["SESSION"].should eq("ADMINTOKEN")
        b.rev.should eq(before)
      end
    end
  end

  describe "the Env::Layer overlay hook" do
    it "writes the active slot's headers, resolving that slot's own binding" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([
          Slot.new("admin", set_headers: [{"Authorization", "Bearer $SESSION"}], rules: ["SESSION"]),
          Slot.new("anon", remove_headers: ["Authorization"]),
        ])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        slots.activate("admin")
        b.observe(login("ADMINTOKEN"), subject)

        wire = "GET /me HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer STALE\r\n\r\n".to_slice
        with_layer(b) do
          String.new(Gori::Env.overlay_slot(wire)).should contain("Authorization: Bearer ADMINTOKEN")
          slots.activate("anon")
          String.new(Gori::Env.overlay_slot(wire)).should_not contain("Authorization")
          # No slot at all is the no-overlay baseline: the SAME slice comes back.
          slots.activate(nil)
          Gori::Env.overlay_slot(wire).to_unsafe.should eq(wire.to_unsafe)
        end
      end
    end

    # The value is the ORIGIN'S bytes landing in a header, so the boundary guard applies —
    # the same split `Bindings.boundary_forging?` documents for `Env.expand_bindings`.
    it "withholds a boundary-forging value from a slot header rather than forging a line" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("admin", set_headers: [{"Authorization", "Bearer $SESSION"}], rules: ["SESSION"])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Header, "x-token")
        slots.activate("admin")
        # A header value the codec kept whole but which carries a CR when read back.
        b.observe(response_result(
          "HTTP/1.1 200 OK\r\nX-Token: abc\rX-Admin: true\r\nContent-Length: 0\r\n\r\n"), subject)
        # It BOUND — the refusal lives at the injection site, not at extraction — so the
        # assertions below are about the guard and not about an empty table.
        b.bound?("SESSION").should be_true
        Gori::Bindings.boundary_forging?(b.values["SESSION"]).should be_true

        with_layer(b) do
          sent = String.new(Gori::Env.overlay_slot("GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice))
          sent.should_not contain("X-Admin: true")
          # The name stays LITERAL when its value is withheld — visible, not silently dropped.
          sent.should contain("Authorization: Bearer $SESSION")
        end
      end
    end

    it "leaves rev moving when only the send context changed" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("a"), Slot.new("b")])
        b = Gori::Bindings.load(store, slots)
        before = b.rev
        slots.activate("a")
        b.rev.should be > before
      end
    end
  end

  # A name's OWNERSHIP is not fixed at the moment a rule is written: an operator binds first
  # and creates slots afterwards, or edits a slot back down to a pure header overlay. Both
  # transitions used to be invisible to the READ half — `candidates` and `bind` gate the WRITE
  # half on `slots.scoped?` AND `active.claims?`, and `values_in` had neither — so the pane
  # (`rows`, which asks the question) and the wire (`values`, which did not) disagreed.
  describe "a name whose ownership MOVES" do
    it "retires a global value the moment a slot claims the name" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil

        # Bound globally FIRST — the rule is unclaimed, so this is the ordinary pre-slot path.
        b.observe(login("VICTIM-TOKEN"), subject).should eq(["SESSION"])
        b.values["SESSION"].should eq("VICTIM-TOKEN")

        # …and only now does the operator split the name across two identities.
        slots.save([
          Slot.new("admin", set_headers: [{"Cookie", "sid=$SESSION"}], rules: ["SESSION"]),
          Slot.new("user", set_headers: [{"Cookie", "sid=$SESSION"}], rules: ["SESSION"]),
        ])

        # The pane always said UNBOUND for both rows; the resolution now agrees. Handing both
        # identities that one retired token is "one credential wearing several names" —
        # `Env.expand_bindings_as` names it as the failure this feature exists to prevent.
        b.rows.map { |r| {r.slot, r.value} }.should eq([{"admin", nil}, {"user", nil}])
        b.slot_values("admin").should be_empty
        b.slot_values("user").should be_empty
        slots.activate("admin")
        b.values.should be_empty
        b.bound?("SESSION").should be_false
        slots.activate("user")
        b.values.should be_empty
        b.bound?("SESSION").should be_false

        # It is RETIRED, not destroyed: it was on the wire, so masking must still redact it.
        with_layer(b) { Gori::Env.masking_vars.values.includes?("VICTIM-TOKEN").should be_true }
      end
    end

    it "retires a slot's value the moment the operator hands the name back" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("admin", set_headers: [{"Cookie", "sid=$SESSION"}], rules: ["SESSION"])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
        slots.activate("admin")
        b.observe(login("ADMIN-TOKEN"), subject).should eq(["SESSION"])
        b.values["SESSION"].should eq("ADMIN-TOKEN")

        # The operator edits `admin` down to a pure header overlay: `SESSION` is unclaimed
        # again, so it binds globally again.
        slots.activate(nil)
        slots.update("admin", Slot.new("admin", set_headers: [{"X-Who", "admin"}])).should be_true
        b.observe(login("GLOBAL-TOKEN"), subject).should eq(["SESSION"])
        b.rows.map { |r| {r.slot, r.value} }.should eq([{nil, "GLOBAL-TOKEN"}])

        # Under `admin` the retired table must not shadow the global one — it used to, and
        # permanently: no later global rebind could ever be seen while that slot was active.
        slots.activate("admin")
        b.values["SESSION"].should eq("GLOBAL-TOKEN")
        b.bound?("SESSION").should be_true
        b.observe(login("GLOBAL-TOKEN-2"), subject).should eq(["SESSION"])
        b.values["SESSION"].should eq("GLOBAL-TOKEN-2")
      end
    end

    it "still gives each identity its OWN token when the claim is in place" do
      # The regression guard on both fixes above: the normal case must be untouched.
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([
          Slot.new("admin", set_headers: [{"Cookie", "sid=$SESSION"}], rules: ["SESSION"]),
          Slot.new("user", set_headers: [{"Cookie", "sid=$SESSION"}], rules: ["SESSION"]),
        ])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        slots.activate("admin")
        b.observe(login("ADMINTOKEN"), subject)
        slots.activate("user")
        b.observe(login("USERTOKEN"), subject)

        wire = "GET /me HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
        with_layer(b) do
          slots.activate("admin")
          String.new(Gori::Env.overlay_slot(wire)).should contain("Cookie: sid=ADMINTOKEN")
          slots.activate("user")
          String.new(Gori::Env.overlay_slot(wire)).should contain("Cookie: sid=USERTOKEN")
          # …and the same, for the caller that cannot activate each in turn.
          Gori::Env.expand_bindings_as("sid=$SESSION", "admin").should eq("sid=ADMINTOKEN")
          Gori::Env.expand_bindings_as("sid=$SESSION", "user").should eq("sid=USERTOKEN")
        end
      end
    end

    it "does not resolve another slot's name for an identity that is not a slot" do
      # `Authorize` prepends a baseline and can be handed identities from a file — names the
      # slot list has never heard of. Degrading to the global table is right; degrading to a
      # CLAIMED name's retired global value is the same "one credential, several names".
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        b.add("CSRF", "", Gori::ExtractKind::Header, "x-csrf")
        b.observe(response_result(
          "HTTP/1.1 200 OK\r\nSet-Cookie: sid=GLOBAL; Path=/\r\nX-CSRF: C1\r\nContent-Length: 0\r\n\r\n"),
          subject)
        slots.save([Slot.new("admin", rules: ["SESSION"])])

        b.slot_values("not-a-slot").should eq({"CSRF" => "C1"})
      end
    end
  end

  # `candidates` runs a CLAIMED rule only while the slot claiming it is active. That is the
  # namespacing decision and it stands — but until `unasked` existed, nothing could say so, so
  # `--bind-from` reported "no extract rule matched its response … check the rule's host glob,
  # condition and selector" about a rule that matched all three and was simply not asked.
  describe "rules a slot has scoped OUT of this send context" do
    it "names the rule and the slots claiming it" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("idA", rules: ["SESSION"]), Slot.new("idB", rules: ["SESSION"]),
                    Slot.new("anon", remove_headers: ["Cookie"])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")

        # No slot active — the pre-slot playbook's send context, and the `--bind-from` one.
        b.observe(login("TOK"), subject).should be_empty
        b.unasked(subject).should eq([{"SESSION", ["idA", "idB"]}])
        b.claiming_slots("SESSION").should eq(["idA", "idB"])

        # A slot that does not claim it is active: same story.
        slots.activate("anon")
        b.unasked(subject).should eq([{"SESSION", ["idA", "idB"]}])

        # …and the subject-free half, for the caller with no message in hand (`--bind-from`).
        slots.activate(nil)
        b.scoped_out.should eq([{"SESSION", ["idA", "idB"]}])
        slots.activate("anon")
        b.scoped_out.should eq([{"SESSION", ["idA", "idB"]}])

        # Either claiming slot: the rule IS asked, so there is nothing to explain.
        slots.activate("idB")
        b.unasked(subject).should be_empty
        b.scoped_out.should be_empty

        # The right one, and there is nothing left to explain.
        slots.activate("idA")
        b.unasked(subject).should be_empty
        b.observe(login("TOK"), subject).should eq(["SESSION"])
      end
    end

    it "stays silent about a rule that genuinely did not match" do
      # The distinction is the whole point: `unasked` must not blame the slots for a host glob
      # that missed, or the diagnostic swaps one wrong answer for another.
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("idA", rules: ["SESSION"])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid", host: "other.test")
        b.unasked(subject).should be_empty
        b.claiming_slots("SESSION").should eq(["idA"])
        # `scoped_out` does NOT know about the host glob and must not pretend to: it answers
        # "this rule cannot be asked here at all", which stays true on any message.
        b.scoped_out.should eq([{"SESSION", ["idA"]}])
        # …and an unclaimed rule is never scoped out, whatever is active.
        b.add("CSRF", "", Gori::ExtractKind::Header, "x-csrf")
        b.unasked(subject).should be_empty
      end
    end

    it "answers empty for a project with no slots at all" do
      with_store do |store|
        b = Gori::Bindings.load(store)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        b.unasked(subject).should be_empty
        b.scoped_out.should be_empty
        b.claiming_slots("SESSION").should be_empty
      end
    end
  end

  # A binding value is memory-only, so EVERY `gori run … --slot` process starts with an empty
  # table: without `--bind-from`, a slot header saying `Bearer $SESSION` ships those eight
  # bytes and the run exits 0 with no warning. In Authorize that is a MISSED bypass — the
  # identity goes out unauthenticated, draws the same 401 as anonymous, and the row reads
  # `enforced`.
  describe "a slot overlay that resolves to nothing" do
    it "reports the literal it is about to send, and keeps sending it" do
      with_store do |store|
        Gori::Env.take_unbound_overlay # drain whatever an earlier example left
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("idA", set_headers: [{"Authorization", "Bearer $SESSION"}],
          rules: ["SESSION"])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
        slots.activate("idA")

        with_layer(b) do
          Gori::Env.unbound_in_slot(slots.find("idA").not_nil!).should eq(["SESSION"])
          sent = String.new(Gori::Env.overlay_slot("GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice))
          # A REPORT, not a refusal: the bytes still go, so a half-configured slot cannot kill
          # a run (the #525 shape — a guard with no exit costs more than the loss it prevents).
          sent.should contain("Authorization: Bearer $SESSION")
        end

        drained = Gori::Env.take_unbound_overlay
        drained.should eq([{"idA", "SESSION"}])
        # Drained once: a summary prints it, it does not accumulate per send.
        Gori::Env.take_unbound_overlay.should be_empty
      end
    end

    it "says nothing once the name is bound" do
      with_store do |store|
        Gori::Env.take_unbound_overlay
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("idA", set_headers: [{"Authorization", "Bearer $SESSION"}],
          rules: ["SESSION"])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        slots.activate("idA")
        b.observe(login("REALTOKEN"), subject)

        with_layer(b) do
          sent = String.new(Gori::Env.overlay_slot("GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice))
          sent.should contain("Authorization: Bearer REALTOKEN")
        end
        Gori::Env.take_unbound_overlay.should be_empty
      end
    end

    it "leaves an operator's own `$$` escape and an unknown name alone" do
      # `$$NAME` is the one escape this module defines and the exit an operator has when the
      # literal IS what they meant. An unknown `$FOO` is plan-build's business (#525) — two
      # answers for one syntax is exactly what that shape rules out.
      with_store do |store|
        Gori::Env.take_unbound_overlay
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("idA", set_headers: [{"X-A", "$$SESSION"}, {"X-B", "$NOSUCH"}])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        slots.activate("idA")
        with_layer(b) do
          Gori::Env.unbound_in_slot(slots.find("idA").not_nil!).should be_empty
          sent = String.new(Gori::Env.overlay_slot("GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice))
          sent.should contain("X-A: $SESSION")
          sent.should contain("X-B: $NOSUCH")
        end
        Gori::Env.take_unbound_overlay.should be_empty
      end
    end

    it "reports per IDENTITY on the Authorize path, where each resolves its own table" do
      with_store do |store|
        Gori::Env.take_unbound_overlay
        slots = Gori::SessionSlots.load(store)
        slots.save([
          Slot.new("admin", set_headers: [{"Cookie", "sid=$SESSION"}], rules: ["SESSION"]),
          Slot.new("user", set_headers: [{"Cookie", "sid=$SESSION"}], rules: ["SESSION"]),
        ])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        slots.activate("admin")
        b.observe(login("ADMINTOKEN"), subject)
        slots.activate(nil)

        with_layer(b) do
          admin = Gori::Authorize.resolve(slots.find("admin").not_nil!)
          admin.set_headers.should eq([{"Cookie", "sid=ADMINTOKEN"}])
          user = Gori::Authorize.resolve(slots.find("user").not_nil!)
          # Nothing bound for `user`: the literal goes out and THAT is what must be said, or
          # the 401 it draws reads as access control working.
          user.set_headers.should eq([{"Cookie", "sid=$SESSION"}])
        end
        Gori::Env.take_unbound_overlay.should eq([{"user", "SESSION"}])
      end
    end
  end

  # `rows` emits one row per (rule, table it writes), so the pane can show two rows with one
  # `rule_id`. The clear action has to name the ROW.
  describe "clearing one row" do
    it "forgets exactly the table the row names" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("admin", rules: ["SESSION"]), Slot.new("user", rules: ["SESSION"])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        slots.activate("admin")
        b.observe(login("ADMINTOKEN"), subject)
        slots.activate("user")
        b.observe(login("USERTOKEN"), subject)

        # `admin` is not the send context, so the context-scoped `clear` could never reach it.
        b.clear_row("SESSION", "admin")
        b.rows.map { |r| {r.slot, r.value} }.should eq([{"admin", nil}, {"user", "USERTOKEN"}])
        slots.activate("admin")
        b.values.should be_empty
        slots.activate("user")
        b.values["SESSION"].should eq("USERTOKEN")
      end
    end

    it "forgets the GLOBAL table when the row names no slot" do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("admin")])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        b.observe(login("GLOBALTOKEN"), subject)
        slots.activate("admin")
        b.clear_row("SESSION", nil)
        b.rows.map(&.value).should eq([nil])
        b.values.should be_empty
      end
    end
  end
end
