require "./spec_helper"

# `Gori::SessionSlot` — the type an Authorize identity and a session slot BOTH are.
#
# The overlay half is exercised from the Authorize side already (`spec/authorize/identity_spec.cr`,
# which drives it through the alias); what is pinned here is what slots added and what a slot
# must never do: the `rules` membership field, its ON-DISK compatibility in both directions,
# and the header-only invariant that lets a slot be applied to bytes the operator did not author.

private alias Slot = Gori::SessionSlot

private def head(*lines : String) : Bytes
  (lines.join("\r\n") + "\r\n\r\n").to_slice
end

describe Gori::SessionSlot do
  describe "extract-rule membership" do
    it "claims a rule by binding name, case-sensitively" do
      slot = Slot.new("admin", rules: ["SESSION", "CSRF"])
      slot.claims?("SESSION").should be_true
      slot.claims?("CSRF").should be_true
      slot.claims?("session").should be_false
      slot.claims?("OTHER").should be_false
    end

    it "claims nothing by default, which is what every identity written before slots is" do
      Slot.new("anon", remove_headers: ["Cookie"]).rules.should be_empty
      Slot.as_captured.rules.should be_empty
    end

    it "carries membership through with_baseline and the overlay through with_rules" do
      slot = Slot.new("admin", set_headers: [{"Cookie", "s=1"}], rules: ["SESSION"])
      slot.with_baseline(true).rules.should eq(["SESSION"])
      slot.with_baseline(true).set_headers.should eq([{"Cookie", "s=1"}])
      slot.with_rules(["A", "B"]).set_headers.should eq([{"Cookie", "s=1"}])
      slot.with_rules(["A", "B"]).rules.should eq(["A", "B"])
    end
  end

  describe ".serialize / .parse_json" do
    it "round-trips a slot with headers and rule membership" do
      slots = [
        Slot.as_captured,
        Slot.new("admin", set_headers: [{"Cookie", "session=AAA"}], rules: ["SESSION"]),
        Slot.new("anon", remove_headers: ["Cookie", "Authorization"]),
      ]
      back = Slot.parse_json(Slot.serialize(slots))
      back.map(&.name).should eq(["as-captured", "admin", "anon"])
      back[1].rules.should eq(["SESSION"])
      back[1].set_headers.should eq([{"Cookie", "session=AAA"}])
      back[2].rules.should be_empty
      back.count(&.baseline?).should eq(1)
    end

    # FORWARD compatibility, and the reason `rules` is omitted when empty: an older gori
    # reading this blob has to see the identities it always saw, and a `rules` key it does
    # not know would be one more thing its tolerant reader has to skip.
    it "omits the rules key entirely when a slot claims nothing" do
      json = Slot.serialize([Slot.new("anon", remove_headers: ["Cookie"])])
      json.includes?("rules").should be_false
      json.includes?("remove").should be_true
    end

    # BACKWARD compatibility: the blob every existing project already has on disk.
    it "reads a pre-slot identities blob as slots that claim nothing" do
      legacy = %([{"name":"admin","baseline":false,"set":[{"name":"Cookie","value":"s=1"}],"remove":[]}])
      back = Slot.parse_json(legacy)
      back.size.should eq(1)
      back[0].name.should eq("admin")
      back[0].set_headers.should eq([{"Cookie", "s=1"}])
      back[0].rules.should be_empty
    end

    it "degrades a malformed blob to no slots rather than raising" do
      Slot.parse_json("not json").should be_empty
      Slot.parse_json("{}").should be_empty
      Slot.parse_json(nil).should be_empty
      Slot.parse_json("").should be_empty
    end

    it "skips a malformed entry and keeps the rest" do
      raw = %([{"set":[]},{"name":"ok","rules":["A","",7]}])
      back = Slot.parse_json(raw)
      back.map(&.name).should eq(["ok"])
      # An empty name and a non-string are dropped; the readable ones survive.
      back[0].rules.should eq(["A"])
    end
  end

  describe ".overlay_wire" do
    # THE invariant the whole feature rests on. A slot is applied to bytes the operator did
    # not author — a captured replay, a fuzz template with its payload already spliced — so
    # anything that could move the body's framing would make it unsafe there.
    it "is header-only: the body is byte-exact and Content-Length does not move" do
      wire = ("POST /x HTTP/1.1\r\nHost: h\r\nContent-Length: 11\r\n\r\n" + "a=1&b=\x80\xff").to_slice
      slot = Slot.new("admin", set_headers: [{"Cookie", "s=1"}], remove_headers: ["Authorization"])
      sent = Gori::SessionSlot.overlay_wire(wire, slot)
      text = String.new(sent)
      text.should contain("Content-Length: 11")
      text.should contain("Cookie: s=1")
      # The body octets, including the two that are not valid UTF-8, arrive unchanged.
      sent[sent.size - 10, 10].should eq(wire[wire.size - 10, 10])
    end

    it "returns the SAME slice for a passthrough slot (as-captured is the no-overlay baseline)" do
      wire = "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
      sent = Gori::SessionSlot.overlay_wire(wire, Slot.as_captured)
      sent.to_unsafe.should eq(wire.to_unsafe)
    end

    it "leaves the request line alone, so a scope gate reads the same target either way" do
      wire = "GET /admin?x=1 HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
      slot = Slot.new("admin", set_headers: [{"Cookie", "s=1"}])
      String.new(Gori::SessionSlot.overlay_wire(wire, slot))
        .lines.first.should eq("GET /admin?x=1 HTTP/1.1")
    end

    it "treats a buffer with no blank line as all head (a header-only request still overlays)" do
      wire = "GET / HTTP/1.1\r\nHost: h".to_slice
      slot = Slot.new("admin", set_headers: [{"X-Role", "admin"}])
      String.new(Gori::SessionSlot.overlay_wire(wire, slot)).should contain("X-Role: admin")
    end
  end

  describe "#resolve_values" do
    it "expands a reference in a header VALUE and never in a header NAME" do
      slot = Slot.new("admin", set_headers: [{"Authorization", "Bearer $SESSION"}, {"X-$A", "plain"}])
      resolved = slot.resolve_values(&.sub("$SESSION", "TOK"))
      resolved.set_headers.should eq([{"Authorization", "Bearer TOK"}, {"X-$A", "plain"}])
      # Everything else about the slot survives the rewrite.
      resolved.name.should eq("admin")
    end

    it "is the identity for a slot that sets no header" do
      slot = Slot.new("anon", remove_headers: ["Cookie"])
      slot.resolve_values { |_| "X" }.set_headers.should be_empty
    end
  end

  it "reports as-captured as passthrough and summarizes header NAMES only" do
    Slot.as_captured.passthrough?.should be_true
    Slot.as_captured.summary.should eq("as captured")
    slot = Slot.new("admin", set_headers: [{"Cookie", "session=SECRETVALUE"}], remove_headers: ["X-Debug"])
    slot.passthrough?.should be_false
    slot.summary.should eq("sets Cookie · drops X-Debug")
    slot.summary.should_not contain("SECRETVALUE")
  end
end

# The alias is the decision, so it is pinned rather than assumed: an Authorize identity and a
# session slot must stay ONE type, or "the admin session" gets to mean two things.
describe Gori::Authorize::Identity do
  it "is Gori::SessionSlot" do
    Gori::Authorize::Identity.should eq(Gori::SessionSlot)
    Gori::Authorize::Identity.new("admin").should be_a(Gori::SessionSlot)
  end

  it "serializes through the Authorize entry points into the same blob" do
    list = [Gori::Authorize::Identity.new("admin", set_headers: [{"Cookie", "s=1"}])]
    Gori::Authorize.serialize(list).should eq(Gori::SessionSlot.serialize(list))
    Gori::Authorize.parse_json(Gori::SessionSlot.serialize(list)).map(&.name).should eq(["admin"])
  end

  it "overlays through the Authorize entry points identically" do
    h = head("GET / HTTP/1.1", "Host: x")
    id = Gori::Authorize::Identity.new("admin", set_headers: [{"Cookie", "s=1"}])
    Gori::Authorize.overlay_head(h, id).should eq(Gori::SessionSlot.overlay_head(h, id))
    Gori::Authorize.overlay_wire(h, id).should eq(Gori::SessionSlot.overlay_wire(h, id))
    Gori::Authorize.overlay_request(h, "b".to_slice, id)
      .should eq(Gori::SessionSlot.overlay_request(h, "b".to_slice, id))
  end
end
