require "../spec_helper"

# `SafeRegexp` answers a literal pattern with a byte search instead of PCRE2 (see the
# file for why — it is 10x, and QL compiles every `header:` and index-free `body:` to
# one). These examples pin the thing that makes that safe: the fast path must never be a
# SECOND definition of what matches. Every one of them asserts the answer the PCRE2 path
# gives, so a divergence fails here rather than silently narrowing a search.
private def old_answer(pattern : String, hay : Bytes) : Bool
  # What the callback did before the fast path existed: scrub, then PCRE2.
  Regex.new(pattern).matches?(String.new(hay).scrub)
rescue
  false
end

private def fast_answer(pattern : String, hay : Bytes) : Bool?
  lit = Gori::SafeRegexp.literal(pattern)
  return nil unless lit
  Gori::SafeRegexp.literal_match?(hay.to_unsafe, hay.size, lit)
end

private def agree(pattern : String, hay : String | Bytes) : Nil
  bytes = hay.is_a?(String) ? hay.to_slice : hay
  got = fast_answer(pattern, bytes)
  return if got.nil? # deliberately deferred to PCRE2 — that IS the agreement
  got.should eq(old_answer(pattern, bytes))
end

describe Gori::SafeRegexp do
  describe "literal extraction" do
    it "takes the shapes QL compiles `:` and a literal `~` into" do
      # `header:`/`body:` (>=3 chars) => `(?i)<Regex.escape(needle)>`; `body~admin` is bare.
      Gori::SafeRegexp.literal("(?i)#{Regex.escape("Set-Cookie")}").should_not be_nil
      Gori::SafeRegexp.literal("admin").should_not be_nil
      Gori::SafeRegexp.literal(Regex.escape("/api/v1?x=1")).should_not be_nil
    end

    it "declines anything that is not a plain ASCII literal" do
      # A metacharacter, a class escape, and a backslash with nothing behind it: all real
      # regexes (or errors), and PCRE2 owns every one of them.
      Gori::SafeRegexp.literal("secret[a-z]+").should be_nil
      Gori::SafeRegexp.literal("secret\\d").should be_nil
      Gori::SafeRegexp.literal("a|b").should be_nil
      Gori::SafeRegexp.literal("^host").should be_nil
      Gori::SafeRegexp.literal("trailing\\").should be_nil
      # Non-ASCII: `(?i)` over these is Unicode's fold table, not `| 0x20`.
      Gori::SafeRegexp.literal("(?i)café").should be_nil
      Gori::SafeRegexp.literal("(?i)漢字").should be_nil
      # Empty (and `(?i)` alone) is a match-all; PCRE2 should say so, not a byte search.
      Gori::SafeRegexp.literal("").should be_nil
      Gori::SafeRegexp.literal("(?i)").should be_nil
    end
  end

  describe "agreement with the PCRE2 path" do
    it "matches case-sensitively when the pattern carries no (?i)" do
      agree("SeCrEt", "a SeCrEt token")
      agree("SeCrEt", "a secret token")
      agree("secret", "a SeCrEt token")
      fast_answer("SeCrEt", "a SeCrEt token".to_slice).should be_true
      fast_answer("SeCrEt", "a secret token".to_slice).should be_false
    end

    it "folds ASCII case behind (?i)" do
      %w[secret SECRET SeCrEt].each { |hay| agree("(?i)secret", "x #{hay} y") }
      fast_answer("(?i)secret", "a SECRET token".to_slice).should be_true
      fast_answer("(?i)secret", "a sekret token".to_slice).should be_false
    end

    it "reads past a NUL and over invalid UTF-8, like the byte-length haystack promises" do
      # The `body~ABC` case ql_spec pins end-to-end, at the callback's own level.
      hay = Bytes[0xFF, 0xFE, 0x00, 0x41, 0x42, 0x43]
      fast_answer("ABC", hay).should be_true
      agree("ABC", hay)
      agree("(?i)abc", hay)
    end

    it "defers to PCRE2 for the two codepoints (?i) folds onto an ASCII letter" do
      # U+017F 'ſ' folds to `s` and U+212A 'K' to `k` — the ENTIRE set (enumerated over the
      # codepoint space, see FOLD_ESCAPES). An ASCII byte fold cannot see them, so a MISS on
      # a needle carrying s/k is handed back as nil whenever the haystack could hold one,
      # and PCRE2 gives the real answer.
      fast_answer("(?i)sql", "a \u{017F}ql injection".to_slice).should be_nil
      fast_answer("(?i)kelvin", "a \u{212A}elvin reading".to_slice).should be_nil
      # A HIT never needs the deferral: ASCII folding is a subset of PCRE2's.
      fast_answer("(?i)sql", "a SQL injection".to_slice).should be_true
      # Nor does a miss with no lead byte in sight, or a needle without s/k.
      fast_answer("(?i)sql", "nothing here".to_slice).should be_false
      fast_answer("(?i)admin", "a \u{017F}ql injection".to_slice).should be_false
      # Case-SENSITIVE needles never fold at all, so `ſ` is irrelevant to them.
      fast_answer("sql", "a \u{017F}ql injection".to_slice).should be_false
    end
  end

  describe "through the query, where the answer has to hold end to end" do
    it "keeps `(?i)` finding ſ and K that no ASCII fold could" do
      with_store do |store|
        body = ->(text : String) do
          Gori::Store::CapturedRequest.new(
            created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
            method: "POST", target: "/", http_version: "HTTP/1.1",
            head: "POST / HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice,
            body: text.to_slice, source: Gori::FlowSource::Kind::Proxy)
        end
        long_s = store.insert_flow(body.call("a \u{017F}ql injection"))
        plain = store.insert_flow(body.call("a sql injection"))
        upper = store.insert_flow(body.call("A SQL INJECTION"))
        kelvin = store.insert_flow(body.call("5 \u{212A} units"))

        ids = ->(query : String, fts : Bool) do
          store.search(Gori::QL.parse(query, fts: fts), 50, raise_on_error: true).map(&.id).sort!
        end
        # `body:` without the FTS index is `body~` with an escaped needle (body_literal_cond),
        # the fast path's biggest caller — and it must still reach the ſ row.
        ids.call("body:sql", false).should eq([long_s, plain, upper].sort)
        ids.call("body:units", false).should eq([kelvin])
        ids.call("body~(?i)sql", true).should eq([long_s, plain, upper].sort)
        # `~` is case-sensitive, so these two split the rows byte-exactly.
        ids.call("body~sql", true).should eq([plain])
        ids.call("body~SQL", true).should eq([upper])

        # And the needle's LENGTH no longer changes the fold rule. A 1-2 char `body:` used
        # to be `instr` over ASCII case permutations, so `body:s` byte-matched s/S only
        # while `body:sql` (a `(?i)` REGEXP) also reached ſ — a shorter needle matching
        # FEWER rows than a longer one. Both spellings are the same clause now.
        ids.call("body:s", true).should contain(long_s)
        ids.call("body:sq", true).should eq(ids.call("body:sql", false))
      end
    end
  end
end
