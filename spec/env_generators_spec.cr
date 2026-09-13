require "./spec_helper"

private def with_generators(&)
  with_env_syntax(Gori::Env::Syntax::Namespaced) { yield }
end

private def generated(text : String) : String
  Gori::Env.expand_bindings(text)
end

private class GeneratorSpecLayer < Gori::Env::Layer
  def declared : Array(String)
    ["TOKEN"]
  end

  def values : Hash(String, String)
    {"TOKEN" => "bound"}
  end

  def rev : UInt64
    1_u64
  end
end

# An `Outbound` that answers every gate the way the waived one does, and REMEMBERS what it was
# asked about — the only way to see whether a gate judged the bytes that went on the wire.
private class RecordingOutbound < Gori::Outbound
  getter seen = [] of String

  def initialize
    super(nil, Gori::Outbound::Gate::Waived, Gori::Outbound::Reason::NoProject)
  end

  def sweep_block(scheme : String, host : String, target : String, port : Int32) : String?
    @seen << target
    nil
  end
end

private UUID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/

private def uuids_in(text : String) : Array(String)
  text.scan(UUID_RE).map(&.[0])
end

private def with_layer(layer : Gori::Env::Layer?, &)
  previous = Gori::Env.layer
  Gori::Env.layer = layer
  begin
    yield
  ensure
    Gori::Env.layer = previous
  end
end

private def with_generator_binding_layer(&)
  previous = Gori::Env.layer
  Gori::Env.layer = GeneratorSpecLayer.new
  begin
    yield
  ensure
    Gori::Env.layer = previous
  end
end

describe "Gori::Env generators" do
  it "generates the security-testing catalog at the send seam" do
    with_generators do
      UUID.new(generated("$GEN.UUID")).version.should eq(UUID::Version::V4)
      generated("$GEN.RANDOM").should match(/\A\d+\z/)
      generated("$GEN.RANDOM_HEX").should match(/\A[0-9a-f]{32}\z/)
      generated("$GEN.TIMESTAMP").should match(/\A\d{10,}\z/)
      generated("$GEN.TIMESTAMP_MS").should match(/\A\d{13,}\z/)
      Time.parse_rfc3339(generated("$GEN.ISO8601"))
    end
  end

  it "reuses a generator within one request and mints it again for the next send" do
    with_generators do
      first = generated("a=$GEN.UUID&b=$GEN.UUID")
      a, b = first.split('&').map(&.split('=', 2)[1])
      a.should eq(b)
      generated("$GEN.UUID").should_not eq(a)
    end
  end

  it "shares time across the formats in one expansion context" do
    with_generators do
      out = generated("$GEN.TIMESTAMP/$GEN.TIMESTAMP_MS/$GEN.ISO8601")
      sec, ms, iso = out.split('/')
      (ms.to_i64 // 1000).should eq(sec.to_i64)
      Time.parse_rfc3339(iso).to_unix.should eq(sec.to_i64)
    end
  end

  it "shares one value across the head/body split while bindings are active" do
    with_generators do
      with_generator_binding_layer do
        wire = "POST / HTTP/1.1\r\nX-ID: $GEN.UUID\r\nX-Token: $BIND.TOKEN\r\n" \
               "Content-Length: 9\r\n\r\n$GEN.UUID"
        out = String.new(Gori::Env.expand_bindings(wire.to_slice))
        id = out.match(/X-ID: ([0-9a-f-]{36})\r\n/).not_nil![1]
        out.should end_with("\r\n\r\n#{id}")
        out.should contain("X-Token: bound")
        out.should contain("Content-Length: 36")
      end
    end
  end

  it "leaves unknown generators literal and consumes a GEN escape" do
    with_generators do
      generated("$GEN.NOPE/$$GEN.UUID").should eq("$GEN.NOPE/$GEN.UUID")
    end
  end

  it "does not interpret generators under the bare opt-out" do
    with_env_syntax(Gori::Env::Syntax::Bare) do
      generated("$GEN.UUID/$UUID").should eq("$GEN.UUID/$UUID")
    end
  end

  it "keeps payload spans verbatim and shifts Content-Length for the generated body" do
    with_generators do
      wire = "POST / HTTP/1.1\r\nContent-Length: 19\r\n\r\n$GEN.UUID/$GEN.UUID"
      out = String.new(Gori::Env.expand_bindings(wire.to_slice, [{wire.rindex('/').not_nil! + 1, wire.bytesize}]))
      body = out.split("\r\n\r\n", 2)[1]
      body.should match(/\A[0-9a-f-]{36}\/\$GEN\.UUID\z/)
      out.should contain("Content-Length: 46")
    end
  end

  it "treats registered generators as deferred for request text, but not for dial tuples" do
    with_generators do
      Gori::Env.unresolved("x=$GEN.UUID").should be_empty
      Gori::Env.unresolved("x=$GEN.NOPE").should eq(["GEN.NOPE"])
      Gori::Env.unresolved("https://$GEN.UUID.test", deferred: nil).should eq(["GEN.UUID"])
    end
  end

  # A request is ONE outbound message however many expansion passes build it: the request text,
  # and the active slot's header overlay applied after it. A context per pass put a different id
  # in each header of the same write.
  it "shares one value across the request text and the active slot's header overlay" do
    with_generators do
      with_store do |store|
        slots = Gori::SessionSlots.load(store)
        slots.save([Gori::SessionSlot.new("admin",
          set_headers: [{"X-Slot-A", "$GEN.UUID"}, {"X-Slot-B", "$GEN.UUID"}])])
        bindings = Gori::Bindings.load(store, slots)
        slots.activate("admin")
        with_layer(bindings) do
          outbound = ungated_outbound
          begin
            sender = Gori::Repeater::Sender.new(outbound, scheme: "http", host: "example.test",
              port: 80, verify: false)
            wire = String.new(sender.wire(
              "GET / HTTP/1.1\r\nHost: example.test\r\nX-Draft: $GEN.UUID\r\n\r\n".to_slice))
            ids = uuids_in(wire)
            ids.size.should eq(3)
            ids.uniq.size.should eq(1)
          ensure
            outbound.close
          end
        end
      end
    end
  end

  # Same rule for an Authorize identity, whose SET headers are resolved by their own pass.
  it "shares one value across an Authorize identity's headers" do
    with_generators do
      id = Gori::Authorize::Identity.new("admin",
        set_headers: [{"X-A", "$GEN.UUID"}, {"X-B", "$GEN.UUID"}])
      resolved = Gori::Authorize.resolve_without_report(id)
      ids = resolved.set_headers.map(&.[1])
      ids.map(&.matches?(UUID_RE)).should eq([true, true])
      ids.uniq.size.should eq(1)
    end
  end

  # The group gate ran the send seam once to read each target and AGAIN to build the bytes.
  # That is the same answer only while expansion is idempotent — a generated request line is
  # exactly where it is not, and the gate then judged a URL the socket never got.
  it "gates the pipeline on the bytes it will write" do
    with_generators do
      outbound = RecordingOutbound.new
      begin
        origin = Gori::Fuzz::Origin.new("http", "127.0.0.1", 1)
        sender = Gori::Fuzz::Sender.new(origin, outbound, false, true)
        reqs = ["GET /a?id=$GEN.UUID HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice,
                "GET /b?id=$GEN.UUID HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice]
        results = sender.send_pipeline(reqs, timeout: 1.second)

        # Nothing was sent (port 1 refuses), but every member was gated and wired.
        wired = results.map { |r| String.new(r.wire.not_nil!) }
        wired.map { |w| uuids_in(w).first }.uniq!.size.should eq(2) # one id per member
        outbound.seen.size.should eq(2)
        outbound.seen.each_with_index do |target, i|
          target.should eq(wired[i].lines.first.split(' ')[1])
        end
      ensure
        outbound.close
      end
    end
  end

  # `Env::Layer#overlay` carries the send seam's generation, and Crystal has no `override`
  # keyword: a subclass left at the one-argument spelling still COMPILES, and then never runs —
  # the overlay silently stops being applied. One spec double was exactly that for an hour, and
  # only a miner hook example noticed. Cheap source scan, in the repo's `shared_chrome_spec`
  # idiom, so the next one is a failure here rather than a missing header on the wire.
  it "keeps every Env::Layer#overlay override on the seam's signature" do
    roots = [File.join(__DIR__, "..", "src"), __DIR__]
    offenders = [] of String
    roots.each do |root|
      Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
        File.read(path).each_line do |line|
          next unless line.matches?(/^\s*def overlay\(wire\s*:\s*Bytes/)
          # `SessionSlots#overlay(wire, &)` is a different method on a different class — the
          # BLOCK is how the slot registry asks its caller to resolve each header value.
          next if line.includes?("generation") || line.includes?("&")
          offenders << "#{File.basename(path)} — #{line.strip}"
        end
      end
    end
    offenders.should be_empty
  end

  it "runs through the shared Repeater send seam and stays off for evidence or verbatim bytes" do
    with_generators do
      outbound = ungated_outbound
      begin
        draft = "GET / HTTP/1.1\r\nHost: example.test\r\nX-ID: $GEN.UUID\r\n\r\n".to_slice
        sender = Gori::Repeater::Sender.new(outbound, scheme: "http", host: "example.test",
          port: 80, verify: false)
        String.new(sender.wire(draft)).should match(/X-ID: [0-9a-f-]{36}\r\n/)

        evidence = Gori::Repeater::Sender.new(outbound, scheme: "http", host: "example.test",
          port: 80, verify: false, evidence: true)
        String.new(evidence.wire(draft)).should contain("X-ID: $GEN.UUID")

        verbatim = Gori::Repeater::Sender.new(outbound, scheme: "http", host: "example.test",
          port: 80, verify: false, expand_bindings: false)
        String.new(verbatim.wire(draft)).should contain("X-ID: $GEN.UUID")
      ensure
        outbound.close
      end
    end
  end
end
