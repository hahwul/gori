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
