require "./spec_helper"

# A request that holds a NUL is ordinary here: a gRPC/protobuf frame, a gzip'd POST, a
# multipart upload carrying a PNG. `^F` seeds the Fuzzer template from a capture verbatim,
# deliberately unscrubbed, because a capture is evidence.
private def nul_request : String
  String.build do |s|
    s << "POST /api HTTP/1.1\r\n\r\nHEAD"
    s.write_byte(0_u8)
    s << "TAIL-AFTER-NUL"
  end
end

private def nul_text(head : String, tail : String) : String
  String.build do |s|
    s << head
    s.write_byte(0_u8)
    s << tail
  end
end

# A column holding OPERATOR or WIRE bytes must be read back as a BLOB. The driver reads a
# TEXT-storage column through a NUL-terminated pointer, so `rs.read(String)` stops at the
# first 0x00 while the write side binds the full bytesize — the bytes reach the disk and the
# READ throws them away. `repeaters.request` was migrated for exactly this in V2; these
# columns were still on the broken shape.
describe "NUL-bearing columns round-trip" do
  it "keeps a fuzz session template whole past an embedded NUL" do
    with_store do |store|
      body = nul_request
      id = store.insert_fuzz_session("t", body, false, nil, "{}", nil, 0)

      store.get_fuzz_session(id).not_nil!.template.should eq(body)
      store.fuzz_sessions.first.template.should eq(body)
    end
  end

  # The comparison that decides "did a peer session change?" tests the in-memory template
  # against this read. While the read truncated, the two could never be equal, so the
  # reconcile path overwrote the operator's live request with the truncated one.
  it "lets a re-read template compare equal to what was written" do
    with_store do |store|
      body = nul_request
      id = store.insert_fuzz_session("t", body, false, nil, "{}", nil, 0)
      store.update_fuzz_session(id, "t", body, false, nil, "{}")

      store.get_fuzz_session(id).not_nil!.template.should eq(body)
    end
  end

  # A rewrite rule is the operator's control (strip an Authorization header, redact a token
  # before it leaves). MCP `create_rule` can carry a real NUL: JSON permits a backslash-u-0000 escape,
  # and Crystal materialises it as an actual 0x00 in the String.
  it "keeps a match rule's pattern and replacement whole past an embedded NUL" do
    with_store do |store|
      pattern = nul_text("AAA", "BBB")
      replacement = nul_text("XXX", "YYY")
      store.insert_rule(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        pattern, replacement)

      rule = store.match_rules.first
      rule.pattern.should eq(pattern)
      rule.replacement.should eq(replacement)
    end
  end
end
