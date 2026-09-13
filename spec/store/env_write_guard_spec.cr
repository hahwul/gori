require "../spec_helper"

# The WRITE side of the token-grammar reconcile (`store/env_write_guard.cr`).
#
# The open-time reconcile makes a project single-grammar and stamps the marker. A LONG-LIVED process
# that missed the switch — a `gori mcp` server started under bare, a second TUI — then keeps writing
# rows in the grammar it was born under, and those rows are worse than wrong: the marker already
# says the other grammar, so the next reconcile finds `from == to` and skips them FOREVER. A bare
# `$SESSION` in a draft reads as literal text for the life of the project, with nothing saying so.
#
# So a write compares its own grammar with the marker and re-spells into the MARKER's. Every example
# here is that shape: a store marked one way, the process speaking the other, and the row that lands.
private def with_marked_store(marker : Gori::Env::Syntax,
                              process : Gori::Env::Syntax, &)
  with_store_env do |store|
    store.set_setting(Gori::Env::PROJECT_VARS_KEY,
      Gori::Env.serialize_vars([{"API", "api.example.com"}, {"id", "v"}]))
    store.insert_extract_rule("token", "", Gori::ExtractKind::Header, "set-cookie")
    store.set_setting(Gori::Env::PROJECT_SYNTAX_KEY, marker.to_s.downcase)
    store.flush
    with_env_syntax(process) { yield store }
  end
end

private BARE = Gori::Env::Syntax::Bare
private NS   = Gori::Env::Syntax::Namespaced

describe "Store env-grammar write guard" do
  it "re-spells a repeater a BARE process writes into a NAMESPACED database" do
    with_marked_store(NS, BARE) do |store|
      store.env_token_syntax.should eq(NS)
      id = store.insert_repeater("https://$API", "GET / HTTP/1.1\r\nX-A: $id\r\nX-B: $token\r\n\r\n".to_slice,
        false, true, nil, 0, sni: "$API")
      store.flush
      rec = store.get_repeater_full(id).not_nil!
      String.new(rec.request).should contain("X-A: $ENV.id\r\n")
      String.new(rec.request).should contain("X-B: $BIND.token\r\n")
      rec.target.should eq("https://$ENV.API")
      rec.sni.should eq("$ENV.API")

      # …and an UPDATE takes the same door, which is the one MCP's `update_repeater` and the TUI's
      # tab save both go through.
      store.update_repeater(id, "https://$API/p", "GET /p HTTP/1.1\r\nX-A: $id\r\n\r\n".to_slice,
        false, true).should be_true
      store.flush
      rec = store.get_repeater_full(id).not_nil!
      String.new(rec.request).should contain("X-A: $ENV.id\r\n")
      rec.target.should eq("https://$ENV.API/p")
    end
  end

  # EVIDENCE is the exception the reconcile already makes, for the same reason: a capture expands
  # nothing, so its `$id` is a byte the origin sent and re-spelling it edits the record.
  it "leaves an EVIDENCE row exactly as captured" do
    with_marked_store(NS, BARE) do |store|
      id = store.insert_repeater("https://api.example.com",
        "GET /?$id HTTP/1.1\r\nHost: api.example.com\r\n\r\n".to_slice, false, true, 7_i64, 0)
      store.flush
      String.new(store.get_repeater_full(id).not_nil!.request).should contain("GET /?$id ")
      # An update to the same tab keeps the provenance, so it is still not re-spelled.
      store.update_repeater(id, "https://api.example.com",
        "GET /?$id&x HTTP/1.1\r\nHost: api.example.com\r\n\r\n".to_slice, false, true).should be_true
      store.flush
      String.new(store.get_repeater_full(id).not_nil!.request).should contain("GET /?$id&x ")
    end
  end

  it "re-spells a rule replacement and leaves the pattern alone" do
    with_marked_store(NS, BARE) do |store|
      id = store.insert_rule(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "X-K: $id", "Bearer $token-$1", name: "r")
      store.flush
      rule = store.match_rules.find { |r| r.id == id }.not_nil!
      rule.replacement.should eq("Bearer $BIND.token-$1")
      rule.pattern.should eq("X-K: $id") # a needle, never expanded
      store.update_rule(id, Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "X-K: $id", "Bearer $token", name: "r").should be_true
      store.flush
      store.match_rules.find { |r| r.id == id }.not_nil!.replacement.should eq("Bearer $BIND.token")
    end
  end

  it "re-spells a session slot's header VALUES and not its keys" do
    with_marked_store(NS, BARE) do |store|
      slots = Gori::SessionSlots.load(store)
      slots.save([Gori::SessionSlot.new("admin",
        [{"Authorization", "Bearer $token"}, {"X-Key", "$API"}], [] of String, false, ["token"])])
        .should be_true
      store.flush
      got = Gori::SessionSlot.parse_json(store.setting(Gori::Store::SESSION_SLOTS_KEY))
      # `Kind::Slot`: the binding seam is the only pass over these bytes and it resolves BIND alone,
      # so the declared binding is re-spelled and the env-var NAME is not — it shipped as literal
      # text before the switch and it ships the same literal text after.
      got[0].set_headers.should eq([{"Authorization", "Bearer $BIND.token"}, {"X-Key", "$API"}])
      got[0].name.should eq("admin")
      got[0].rules.should eq(["token"]) # a claimed rule name is a table key, not a token
    end
  end

  # The other direction: a NAMESPACED process writing into a database a peer reverted to bare.
  it "re-spells the other way for a bare-marked database" do
    with_marked_store(BARE, NS) do |store|
      id = store.insert_repeater("https://$ENV.API", "GET / HTTP/1.1\r\nX-A: $ENV.id\r\n\r\n".to_slice,
        false, true, nil, 0)
      store.flush
      rec = store.get_repeater_full(id).not_nil!
      String.new(rec.request).should contain("X-A: $id\r\n")
      rec.target.should eq("https://$API")
    end
  end

  # And the common case costs nothing and changes nothing: the marker and the process agree.
  it "is a no-op when the process and the database agree" do
    with_marked_store(NS, NS) do |store|
      store.env_write.should be_nil
      id = store.insert_repeater("https://$API", "GET / HTTP/1.1\r\nX-A: $id\r\n\r\n".to_slice,
        false, true, nil, 0)
      store.flush
      rec = store.get_repeater_full(id).not_nil!
      String.new(rec.request).should contain("X-A: $id\r\n") # authored bytes, untouched
      rec.target.should eq("https://$API")
    end
  end
end
