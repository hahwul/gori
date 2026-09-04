require "../../spec_helper"

# R3. Two halves of one failure: a diagnostic mechanism with no consumer.
#
# R1 — `Env.report_unbound_overlay` records every `$NAME` a session slot's header sent
# LITERALLY, and `Env.take_unbound_overlay`'s own doc reserves the drain for "a surface that
# prints a run summary … a log line the operator is not tailing is not a report". Nothing
# drained it. So `gori run authorize` with an identity written `Authorization: Bearer $SESSION`
# and nothing bound sent it unauthenticated, drew the same 401 as anonymous, aggregated to
# `enforced`, exited 0 and said NOTHING — the named miss, still silent, with the machinery to
# name it already in the tree.
#
# R2 — `Bindings#scoped_out` was added for the `--bind-from` sentence and never called, so that
# sentence still blamed three innocent things (host glob, condition, selector) for a rule that
# was never ASKED because a slot claims it and no slot is active.
#
# Both are asserted on the functions that MAKE the sentences, plus a source guard that every
# summary surface still calls the drain — the shape this repo keeps re-learning is a notice
# fixed on one surface and left to drift on the other two.

private alias Slot = Gori::SessionSlot

private def with_store(&)
  path = File.tempname("gori-unbound-overlay", ".db")
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

private def login_result(value : String) : Gori::Repeater::Result
  bytes = "HTTP/1.1 200 OK\r\nSet-Cookie: sid=#{value}; Path=/\r\nContent-Length: 0\r\n\r\n".to_slice
  Gori::Repeater::Result.new(bytes, Bytes.empty,
    Gori::Proxy::Codec::Http1.parse_response_head(bytes), 1_i64, nil)
end

private def login_subject : Gori::InterceptFilter::Subject
  Gori::InterceptFilter::Subject.new(method: "POST", host: "acme.test", target: "/login",
    scheme: "https", status: 200)
end

# Both sentences are private — a wording decision belongs to the surface, and a caller outside
# it must not be able to reach past the report. Read through a shim in the same module, the
# `bind_from_blocker_for_spec` pattern one file over.
module Gori::CLI::Run
  def self.bind_from_nothing_bound_for_spec(b : Gori::Bindings, flow_id : Int64,
                                            status : Int32?) : String
    bind_from_nothing_bound(b, flow_id, status)
  end
end

describe "R1 · the unbound-overlay drain has a consumer" do
  describe "Run.unbound_overlay_note" do
    it "is nil for a run whose every reference resolved — a bound run gains NO new line" do
      # The false-warning half, and the one that decides whether an operator keeps reading the
      # notice at all: a summary that says this on a healthy run is a summary nobody reads.
      Gori::CLI::Run.unbound_overlay_note([] of {String, String}).should be_nil
    end

    it "names the slot, the reference, and both exits" do
      note = Gori::CLI::Run.unbound_overlay_note([{"admin", "SESSION"}]).should_not be_nil
      note.should contain("admin sent $SESSION")
      # An INTERRUPTION, not a refusal: the bytes went out, so what this owes the operator is
      # that the result must not be read as evidence about an identity that was never sent.
      note.should contain("NOT evidence")
      # …and the two ways out, both of which already exist — the report adds no new mechanism.
      note.should contain("--bind-from FLOW-ID")
      note.should contain("$$SESSION")
    end

    it "groups by SLOT, because the slot is the thing the operator fixes" do
      note = Gori::CLI::Run.unbound_overlay_note([
        {"admin", "SESSION"}, {"user", "SESSION"}, {"user", "CSRF"},
      ]).should_not be_nil
      note.should contain("admin sent $SESSION")
      note.should contain("user sent $SESSION, $CSRF")
      # Two identities missing the same name are two configurations, not one occurrence of it.
      note.should match(/admin sent .*; user sent /)
    end

    it "says it in the plural when more than one reference went out" do
      one = Gori::CLI::Run.unbound_overlay_note([{"admin", "SESSION"}]).not_nil!
      many = Gori::CLI::Run.unbound_overlay_note([{"admin", "SESSION"}, {"admin", "CSRF"}]).not_nil!
      one.should contain("session value went out")
      many.should contain("session values went out")
      one.should contain("its response is NOT evidence")
      many.should contain("their responses are NOT evidence")
    end
  end

  describe "over the real seam" do
    it "an UNBOUND slot overlay produces the summary sentence" do
      with_store do |store|
        Gori::Env.take_unbound_overlay # drain whatever an earlier example left
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("idA", set_headers: [{"Authorization", "Bearer $SESSION"}],
          rules: ["SESSION"])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
        slots.activate("idA")

        with_layer(b) do
          sent = String.new(Gori::Env.overlay_slot("GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice))
          sent.should contain("Authorization: Bearer $SESSION") # the literal DID go out
        end

        note = Gori::CLI::Run.unbound_overlay_note(Gori::Env.take_unbound_overlay).should_not be_nil
        note.should contain("idA sent $SESSION")
        # Drained: a second surface in the same process must not print it again.
        Gori::CLI::Run.unbound_overlay_note(Gori::Env.take_unbound_overlay).should be_nil
      end
    end

    it "a BOUND slot overlay produces nothing at all" do
      with_store do |store|
        Gori::Env.take_unbound_overlay
        slots = Gori::SessionSlots.load(store)
        slots.save([Slot.new("idA", set_headers: [{"Authorization", "Bearer $SESSION"}],
          rules: ["SESSION"])])
        b = Gori::Bindings.load(store, slots)
        b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid")
        slots.activate("idA")
        b.observe(login_result("REALTOKEN"), login_subject)

        with_layer(b) do
          sent = String.new(Gori::Env.overlay_slot("GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice))
          sent.should contain("Authorization: Bearer REALTOKEN")
        end
        Gori::CLI::Run.unbound_overlay_note(Gori::Env.take_unbound_overlay).should be_nil
      end
    end
  end

  # The drift guard. `take_unbound_overlay` is a DRAIN — exactly one surface per run may take
  # it — so "who calls it" is a property of the tree, not of any one function, and the whole
  # defect this file closes was that the answer used to be NOBODY.
  describe "every run-summary surface drains it" do
    # DERIVED, not listed. This used to name three files by hand, and a hand-written inventory
    # is how the drift it guards against happened anyway: `mine`, `sequence` and `repeater
    # minimize` all grew `--slot`, all print a run summary, and none of them drained — so all
    # three sent `$SESSION` literally under a slot and said so only in a `Log.warn` written
    # BEFORE the results, which is the exact "log line the operator is not tailing" the drain
    # exists to replace. `discover` DID drain and was missing from the list too, so the list was
    # already stale in both directions.
    #
    # The population is "every `gori run` verb that accepts `--slot`", because accepting one is
    # what makes an unresolved `$NAME` possible. Deriving it means a verb that grows `--slot`
    # tomorrow fails here instead of drifting silently.
    it "is wired on every `gori run` verb that accepts --slot" do
      dir = File.join(__DIR__, "../../..", "src/gori/cli/run")
      offenders = [] of String
      Dir.glob(File.join(dir, "*.cr")).sort.each do |path|
        src = File.read(path)
        next unless src.includes?("\"--slot")
        offenders << File.basename(path) unless src.includes?("report_unbound_slot_overlay(")
      end
      offenders.should be_empty
    end

    it "keeps the population non-trivial, so an empty glob cannot pass it vacuously" do
      dir = File.join(__DIR__, "../../..", "src/gori/cli/run")
      with_slot = Dir.glob(File.join(dir, "*.cr")).count { |p| File.read(p).includes?("\"--slot") }
      # fuzz, mine, sequence, discover, repeater, repeater_minimize — six today, and the
      # assertion is a floor, not the count, so adding a seventh is not a spec edit.
      with_slot.should be >= 6
    end

    it "is wired on both MCP surfaces, which have no STDERR an agent reads" do
      %w[src/gori/mcp/tools/send.cr src/gori/mcp/tools/authorize.cr].each do |path|
        src = File.read(File.join(__DIR__, "../../..", path))
        src.should contain("CLI::Run.unbound_overlay_note(Env.take_unbound_overlay)")
        # …and rendered into the payload, not merely computed: an MCP tool has no other channel.
        src.should contain("unbound_overlay_warning")
      end
    end

    it "drops the SEED replay's own record, so a `--bind-from` run stays silent" do
      # `seed_bindings` replays with the table still empty — that is what the replay is FOR —
      # so the active slot's `$NAME` legitimately goes out literal on that one request. Left in
      # the record it warned about the very name the line above reports as bound. Measured on
      # `gori run fuzz --slot idA --bind-from 1`.
      src = File.read(File.join(__DIR__, "../../..", "src/gori/cli/run.cr"))
      seed = src[src.index!("def self.seed_bindings")..src.index!("def self.bind_from_nothing_bound")]
      seed.should contain("Env.take_unbound_overlay")
    end
  end
end

describe "R2 · --bind-from stops blaming an innocent rule" do
  it "keeps the three-innocent-things sentence when NO slot claims the rule" do
    with_store do |store|
      b = Gori::Bindings.load(store, Gori::SessionSlots.load(store))
      b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
      b.scoped_out.should be_empty
      msg = Gori::CLI::Run.bind_from_nothing_bound_for_spec(b, 7_i64, 200)
      msg.should contain("flow #7 replayed (HTTP 200)")
      msg.should contain("no extract rule matched its response")
      msg.should contain("host glob, condition and selector")
      # Nothing here is about slots, because nothing here IS about slots.
      msg.should_not contain("--slot")
    end
  end

  it "names the claiming SLOT when that is why the rule was never asked" do
    # The measured regression: `gori run session edit idA --rule SESSION` silently broke every
    # existing `--bind-from` playbook, and the surface sent the operator to re-check a host
    # glob, a condition and a selector that were all correct.
    with_store do |store|
      slots = Gori::SessionSlots.load(store)
      slots.save([Slot.new("idA", rules: ["SESSION"])])
      b = Gori::Bindings.load(store, slots)
      b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
      b.scoped_out.should eq([{"SESSION", ["idA"]}])

      msg = Gori::CLI::Run.bind_from_nothing_bound_for_spec(b, 7_i64, 200)
      msg.should contain("$SESSION (claimed by idA)")
      msg.should contain("skipped, not missed")
      # Both exits, each naming the slot the operator has to type.
      msg.should contain("--slot idA")
      msg.should contain("gori run session edit idA --clear-rules")
      # …and NOT the three innocent things, which is the whole point.
      msg.should_not contain("host glob, condition and selector")
    end
  end

  it "goes back to the generic sentence once the slot is the send context" do
    # `--slot idA` makes the claim irrelevant: the rule IS asked, so a miss is a real miss and
    # the host glob / condition / selector really are the things to check.
    with_store do |store|
      slots = Gori::SessionSlots.load(store)
      slots.save([Slot.new("idA", rules: ["SESSION"])])
      b = Gori::Bindings.load(store, slots)
      b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
      slots.activate("idA")
      b.scoped_out.should be_empty
      Gori::CLI::Run.bind_from_nothing_bound_for_spec(b, 7_i64, 200)
        .should contain("host glob, condition and selector")
    end
  end

  it "names every scoped-out rule, not just the first" do
    with_store do |store|
      slots = Gori::SessionSlots.load(store)
      slots.save([Slot.new("idA", rules: ["SESSION"]), Slot.new("idB", rules: ["CSRF"])])
      b = Gori::Bindings.load(store, slots)
      b.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
      b.add("CSRF", "", Gori::ExtractKind::Cookie, "csrf").should be_nil

      msg = Gori::CLI::Run.bind_from_nothing_bound_for_spec(b, 7_i64, nil)
      msg.should contain("flow #7 replayed (HTTP ?)")
      msg.should contain("$SESSION (claimed by idA)")
      msg.should contain("$CSRF (claimed by idB)")
      msg.should contain("the rules that would have bound are")
    end
  end
end
