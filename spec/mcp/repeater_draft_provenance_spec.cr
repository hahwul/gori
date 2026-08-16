require "../spec_helper"

# MCP used to run `Env.mask_secrets` over the request bytes it PERSISTS, so an author who
# typed a value gori can recognise — a project env var, or a LIVE session-binding value —
# had gori rewrite it to `$NAME` in the stored repeater row. No other writer does that: the
# TUI editor and `gori run repeater` store what the author typed.
#
# The consequence was not cosmetic. `update_repeater` leaves `flow_id` alone, the TUI reads
# `flow_id` as `RepeaterView#evidence?`, and an evidence tab deliberately does NOT expand
# `$NAME` (a capture's `$filter` is a byte the origin saw, not a reference). So one stored row
# put `Authorization: Bearer $CTOK` on the wire from the TUI and the real value from MCP and
# the CLI — three surfaces, two different requests, `✓ sent → 200` on all of them.
#
# The fix is at the write: store the author's bytes, mask only on the way out. `masking_vars`
# is one table (`Env.effective_vars` + `Bindings#held_values`), so an env var and a bound
# session value take the identical path through `mask_secrets`; these drive the env-var half
# because a live binding value exists only in the process that observed it and the MCP server
# rebinds `Env.layer` from the store at bind time (`Tools#bind_binding_layer`).

private def with_store(&)
  path = File.tempname("gori-draftprov", ".db")
  store = Gori::Store.open(path)
  prev_env = Gori::Settings.project_env_vars
  begin
    yield store
  ensure
    Gori::Settings.project_env_vars = prev_env
    Gori::Env.bump_highlight_rev
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def drive(store, *lines) : Array(JSON::Any)
  input = IO::Memory.new(lines.join('\n') + "\n")
  output = IO::Memory.new
  Gori::MCP::Server.new(store, allow_actions: true, verify_upstream: false,
    input: input, output: output).run
  output.to_s.each_line.reject(&.strip.empty?).map { |l| JSON.parse(l) }.to_a
end

private def tool_payload(resp : JSON::Any) : JSON::Any
  JSON.parse(resp["result"]["content"][0]["text"].as_s)
end

SECRET = "MCPSECRET4242"

private def set_secret_call : String
  %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"set_env_var","arguments":) +
    %({"key":"CTOK","value":"#{SECRET}"}}})
end

private def create_call(request : String, flow_id : Int64? = nil, id : Int32 = 2) : String
  args = %({"target":"http://127.0.0.1:1","request":#{request.to_json})
  args += %(,"flow_id":#{flow_id}) if flow_id
  %({"jsonrpc":"2.0","id":#{id},"method":"tools/call","params":{"name":"create_repeater","arguments":#{args}}}})
end

private def update_call(rid : Int64, request : String, id : Int32 = 3) : String
  %({"jsonrpc":"2.0","id":#{id},"method":"tools/call","params":{"name":"update_repeater","arguments":) +
    %({"id":#{rid},"request":#{request.to_json}}}})
end

private def seed_flow(store) : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "h", port: 80,
    method: "GET", target: "/seed", http_version: "HTTP/1.1",
    head: "GET /seed HTTP/1.1\r\nHost: h\r\n\r\n".to_slice, body: nil))
end

describe "MCP repeater drafts keep the author's bytes" do
  it "stores create_repeater's request verbatim when it carries a recognisable secret" do
    with_store do |store|
      req = "GET /a HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer #{SECRET}\r\n\r\n"
      res = drive(store, set_secret_call, create_call(req))
      payload = tool_payload(res[1])
      stored = String.new(store.get_repeater(payload["id"].as_i64).not_nil!.request)
      stored.should eq(req)
      stored.should_not contain("$CTOK")
      # …and the report SAYS gori recognised one, which the silent rewrite never did.
      payload["secrets_masked"].as_a.map(&.as_s).should eq(["CTOK"])
      payload["secrets_masked_note"].as_s.should contain("$CTOK")
    end
  end

  it "stores update_repeater's replacement verbatim, and says the flow link no longer means byte identity" do
    with_store do |store|
      flow = seed_flow(store)
      seed = "GET /seed HTTP/1.1\r\nHost: h\r\n\r\n"
      req = "GET /afterupdate HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer #{SECRET}\r\n\r\n"
      rid = tool_payload(drive(store, set_secret_call, create_call(seed, flow))[1])["id"].as_i64
      payload = tool_payload(drive(store, update_call(rid, req))[0])

      String.new(store.get_repeater(rid).not_nil!.request).should eq(req)
      payload["secrets_masked"].as_a.map(&.as_s).should eq(["CTOK"])
      # The row still advertises `flow_id`, which is the flag the TUI turns into
      # `evidence?`. Clearing the column needs a store change; until then it is STATED.
      payload["flow_id"].as_i64.should eq(flow)
      payload["derived_from_flow_note"].as_s.should contain("no longer holds that flow's bytes")
    end
  end

  # COMPLEMENT 1: a request with NO recognisable value must be byte-identical either way, and
  # must not grow a `secrets_masked` field — an "only when it FIRED" report that fires on
  # every call is noise an agent learns to ignore.
  it "leaves a request with no secret in it alone and reports nothing" do
    with_store do |store|
      req = "GET /clean HTTP/1.1\r\nHost: h\r\n\r\n"
      payload = tool_payload(drive(store, set_secret_call, create_call(req))[1])
      String.new(store.get_repeater(payload["id"].as_i64).not_nil!.request).should eq(req)
      payload.as_h.has_key?("secrets_masked").should be_false
      payload.as_h.has_key?("secrets_masked_note").should be_false
    end
  end

  # COMPLEMENT 2: an UNCHANGED request under update_repeater keeps its flow link meaning what
  # it says, so the note must not fire. It keys on "the bytes were replaced", not on
  # "update_repeater was called".
  it "does not claim a flow link is stale when the request was not replaced" do
    with_store do |store|
      flow = seed_flow(store)
      req = "GET /seed HTTP/1.1\r\nHost: h\r\n\r\n"
      rid = tool_payload(drive(store, create_call(req, flow))[0])["id"].as_i64
      # Rename only — `request` is absent, so it round-trips from the stored row.
      payload = tool_payload(drive(store,
        %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"update_repeater","arguments":) +
        %({"id":#{rid},"name":"renamed"}}}))[0])
      payload.as_h.has_key?("derived_from_flow_note").should be_false
    end
  end

  # COMPLEMENT 3: with NO env var and no binding at all the two paths are identical, so this
  # cannot be a behaviour difference for the overwhelmingly common call.
  it "is a no-op when nothing is set" do
    with_store do |store|
      req = "GET /x HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer #{SECRET}\r\n\r\n"
      payload = tool_payload(drive(store, create_call(req))[0])
      String.new(store.get_repeater(payload["id"].as_i64).not_nil!.request).should eq(req)
      payload.as_h.has_key?("secrets_masked").should be_false
    end
  end

  # The whole point: one stored row, one set of bytes, whoever sends it. The TUI's evidence
  # path applies `Env.normalize_wire` and nothing else; the CLI/MCP path applies
  # `Env.expand_wire` + `Env.expand_bindings` — and with the author's own bytes stored, both
  # produce the SAME request. Round 3's headline regression existed because nobody compared
  # the three surfaces against each other.
  it "gives the TUI evidence path and the CLI/MCP path the same wire bytes" do
    with_store do |store|
      req = "GET /a HTTP/1.1\r\nHost: h\r\nAuthorization: Bearer #{SECRET}\r\n\r\n"
      res = drive(store, set_secret_call, create_call(req))
      rid = tool_payload(res[1])["id"].as_i64
      stored = String.new(store.get_repeater(rid).not_nil!.request)
      Gori::Env.load_project(store)                                         # what every surface does on open
      evidence_wire = Gori::Env.normalize_wire(stored)                      # TUI, evidence tab
      draft_wire = Gori::Env.expand_bindings(Gori::Env.expand_wire(stored)) # CLI / MCP
      evidence_wire.should eq(draft_wire)
      String.new(evidence_wire).should contain("Bearer #{SECRET}")
    end
  end
end
