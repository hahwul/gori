require "../spec_helper"

private alias R = Gori::Repeater

# PROVENANCE PER NAME at the SEND seam — `Repeater::PlanOptions#evidence_literals`.
#
# `evidence?` switched the whole `$NAME` send pass off, and the env-var pass one layer up had
# already stopped doing that: `RepeaterView#operator_env_vars` subtracts the names the CAPTURE
# arrived with and expands the rest, so a ^R-from-History tab resolves an operator's own
# `$ENV.API` while leaving a captured `$filter` alone. The two SEND-TIME namespaces could not
# follow, and they are the ones with nowhere else to go: a binding resolves at the socket, and
# a `$GEN.RANDOM_HEX` MUST mint there. So a seeded tab offered `$GEN.RANDOM_HEX` in its
# completer, showed the format hint under the caret, and put those 15 bytes in the request
# line — then History recorded them, faithfully, because the recorder's whole job is to write
# what went out (`HistoryRecord#record`).
#
# The assertions are the invariant rather than the fix: what the socket read == what the row
# holds, with the capture's own tokens still byte-exact.

private class LiteralsSpecLayer < Gori::Env::Layer
  def declared : Array(String)
    ["TOKEN"]
  end

  def values : Hash(String, String)
    {"TOKEN" => "BOUNDVALUE"}
  end

  def rev : UInt64
    7_u64
  end
end

private def with_bindings(&)
  previous = Gori::Env.layer
  Gori::Env.layer = LiteralsSpecLayer.new
  begin
    yield
  ensure
    Gori::Env.layer = previous
  end
end

private def sender(*, evidence : Bool, literals : Set(String)?) : R::Sender
  R::Sender.new(ungated_outbound, scheme: "http", host: "example.test", port: 80,
    verify: false, evidence: evidence, evidence_literals: literals)
end

private def wired(draft : String, *, evidence : Bool, literals : Set(String)?) : String
  s = sender(evidence: evidence, literals: literals)
  String.new(s.wire(draft.to_slice))
end

# An origin that answers 200 and keeps every request head it read.
private def with_origin(&)
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  seen = [] of String
  spawn do
    while conn = server.accept?
      if head = Gori::Proxy::Codec::Http1.read_head(conn)
        seen << String.new(head)
      end
      conn << "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
      conn.flush rescue nil
      conn.close rescue nil
    end
  end
  begin
    yield port, seen
  ensure
    server.close
  end
end

describe "Gori::Repeater send-seam provenance per name" do
  describe "the namespaced grammar" do
    # The reported case: a tab seeded from a capture that mentions no token at all, so every
    # `$GEN.`/`$BIND.` in it is the operator's.
    it "resolves an operator's generator and binding in a seeded tab" do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        with_bindings do
          draft = "GET /$GEN.RANDOM_HEX HTTP/1.1\r\nHost: example.test\r\n" \
                  "X-Token: $BIND.TOKEN\r\n\r\n"
          out = wired(draft, evidence: true, literals: Set(String).new)
          out.should match(%r{\AGET /[0-9a-f]{32} HTTP/1\.1\r\n})
          out.should contain("X-Token: BOUNDVALUE\r\n")
        end
      end
    end

    # …and the half that must not move: a name the CAPTURE brought is a byte the origin sent.
    it "leaves a name the capture arrived with literal" do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        with_bindings do
          seed = "GET /a?q=$BIND.TOKEN HTTP/1.1\r\nHost: example.test\r\n\r\n"
          draft = "GET /a?q=$BIND.TOKEN HTTP/1.1\r\nHost: example.test\r\n" \
                  "X-Mine: $GEN.UUID\r\n\r\n"
          out = wired(draft, evidence: true, literals: Gori::Env.literal_keys(seed))
          out.should contain("q=$BIND.TOKEN ")
          out.should match(/X-Mine: [0-9a-f-]{36}\r\n/)
        end
      end
    end

    # A name shared across two namespaces is two references: withholding the capture's
    # `$ENV.TOKEN` must not also withhold the operator's `$BIND.TOKEN`.
    it "withholds per namespace, not per bare name" do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        with_bindings do
          seed = "GET /?a=$ENV.TOKEN HTTP/1.1\r\nHost: example.test\r\n\r\n"
          draft = "GET /?a=$BIND.TOKEN HTTP/1.1\r\nHost: example.test\r\n\r\n"
          wired(draft, evidence: true, literals: Gori::Env.literal_keys(seed))
            .should contain("a=BOUNDVALUE ")
        end
      end
    end

    # The escape rides with the CAPTURE, not with the narrowing: under this grammar the pass
    # consumes its own namespaces' escapes, so a narrowed pass that consumed them would edit
    # a `$$BIND.x` the origin sent into `$BIND.x`.
    it "consumes no escape while narrowed" do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        with_bindings do
          draft = "GET /?a=$$BIND.TOKEN HTTP/1.1\r\nHost: example.test\r\n\r\n"
          wired(draft, evidence: true, literals: Set(String).new).should contain("a=$$BIND.TOKEN ")
          # A DRAFT tab is the unchanged contract: last pass before the socket, escape consumed.
          wired(draft, evidence: false, literals: nil).should contain("a=$BIND.TOKEN ")
        end
      end
    end
  end

  # BARE keeps its own spelling: the capture's `$filter` is the withheld name and the
  # operator's `$TOKEN` resolves, which is the env-var pass's rule arriving at the send seam.
  it "narrows by bare name under the bare grammar" do
    with_env_syntax(Gori::Env::Syntax::Bare) do
      with_bindings do
        seed = "GET /api?$filter=x HTTP/1.1\r\nHost: example.test\r\n\r\n"
        draft = "GET /api?$filter=x HTTP/1.1\r\nHost: example.test\r\nX-T: $TOKEN\r\n\r\n"
        out = wired(draft, evidence: true, literals: Gori::Env.literal_keys(seed))
        out.should contain("?$filter=x ")
        out.should contain("X-T: BOUNDVALUE\r\n")
      end
    end
  end

  # nil is every headless caller (`gori run repeater <flow-id>` replaying a capture whole,
  # MCP's flow path, `--bind-from`): no seed to answer per name, so the blanket skip stands.
  it "keeps the blanket skip when the surface knows no names" do
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      with_bindings do
        draft = "GET /$GEN.RANDOM_HEX HTTP/1.1\r\nHost: example.test\r\nX-T: $BIND.TOKEN\r\n\r\n"
        out = wired(draft, evidence: true, literals: nil)
        out.should contain("GET /$GEN.RANDOM_HEX ")
        out.should contain("X-T: $BIND.TOKEN\r\n")
      end
    end
  end

  # `--verbatim` is the other reason the pass stops, and it is not provenance: the operator
  # said these bytes are the message, so knowing whose names they are changes nothing.
  it "stays off under verbatim even with a literal set" do
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      with_bindings do
        s = R::Sender.new(ungated_outbound, scheme: "http", host: "example.test", port: 80,
          verify: false, evidence: true, expand_bindings: false,
          evidence_literals: Set(String).new)
        String.new(s.wire("GET /$GEN.UUID HTTP/1.1\r\nHost: example.test\r\n\r\n".to_slice))
          .should contain("GET /$GEN.UUID ")
      end
    end
  end

  # THE reported symptom, end to end on the TUI's own shape (`RepeaterController#repeater_plan`
  # → `wire_bytes` → `send_wire` → `HistoryRecord.record`): the head the origin read is the
  # head the row holds, and neither is the token.
  it "records the generated request line the origin actually read" do
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      with_store do |store|
        with_origin do |port, seen|
          req = "GET /$GEN.RANDOM_HEX HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\n\r\n"
          plan = R::Plan.build(R::PlanOptions.new([req.to_slice],
            expand_request: false, auto_content_length: false, evidence: true,
            evidence_literals: Set(String).new,
            target: "http://127.0.0.1:#{port}/", verify: false), ungated_outbound)
          wire = plan.wire_bytes
          result = plan.send_wire(wire)
          result.error.should be_nil
          fid = R::HistoryRecord.record(store, plan, result, Time.utc.to_unix_ms * 1000_i64,
            wire, surface: Gori::FlowSource::Surface::Tui)

          detail = store.get_flow(fid).not_nil!
          detail.row.target.should match(%r{\A/[0-9a-f]{32}\z})
          String.new(detail.request_head).lines.first.should eq(seen.first.lines.first)
        end
      end
    end
  end
end
