require "./spec_helper"

# Build a Probe issue directly. The sibling probe_spec make_issue only emits Low/Open/headers,
# so this file-local helper takes severity/status/category/title/host explicitly.
private def make_issue(code : String,
                       severity : Gori::Store::Severity = Gori::Store::Severity::Low,
                       status : Gori::Store::Status = Gori::Store::Status::Open,
                       category : String = "headers",
                       title : String = "Issue title",
                       host : String = "acme.test") : Gori::Store::ProbeIssue
  Gori::Store::ProbeIssue.new(1_i64, code, category, host, title, severity, status, 1_i64,
    [] of String, nil, nil, 1_i64, 1_i64)
end

# Parse a query and match it against one issue. Named `hits?` (not `matches?`) so it
# never shadows the method under test.
private def hits?(query : String, issue : Gori::Store::ProbeIssue) : Bool
  Gori::Probe::Filter.parse(query).matches?(issue)
end

# One issue per severity rung, so ordinal comparisons can be checked at every boundary.
private def info_issue : Gori::Store::ProbeIssue
  make_issue("c_info", Gori::Store::Severity::Info)
end

private def low_issue : Gori::Store::ProbeIssue
  make_issue("c_low", Gori::Store::Severity::Low)
end

private def med_issue : Gori::Store::ProbeIssue
  make_issue("c_med", Gori::Store::Severity::Medium)
end

private def high_issue : Gori::Store::ProbeIssue
  make_issue("c_high", Gori::Store::Severity::High)
end

private def crit_issue : Gori::Store::ProbeIssue
  make_issue("c_crit", Gori::Store::Severity::Critical)
end

describe Gori::Probe::Filter do
  describe "#match_severity (ordinal comparison over Info..Critical)" do
    it "sev:>=high matches High and Critical only (boundary at High)" do
      hits?("sev:>=high", info_issue).should be_false
      hits?("sev:>=high", low_issue).should be_false
      hits?("sev:>=high", med_issue).should be_false # boundary: Medium excluded
      hits?("sev:>=high", high_issue).should be_true
      hits?("sev:>=high", crit_issue).should be_true
    end

    it "sev:>medium is strict — excludes Medium itself, matches High and Critical" do
      hits?("sev:>medium", low_issue).should be_false
      hits?("sev:>medium", med_issue).should be_false # boundary: strict > excludes equal
      hits?("sev:>medium", high_issue).should be_true
      hits?("sev:>medium", crit_issue).should be_true
    end

    it "sev:<=low matches Info and Low, excludes Medium (boundary at Low)" do
      hits?("sev:<=low", info_issue).should be_true
      hits?("sev:<=low", low_issue).should be_true
      hits?("sev:<=low", med_issue).should be_false # boundary: Medium excluded
      hits?("sev:<=low", high_issue).should be_false
    end

    it "sev:<medium is strict — matches Info and Low, excludes Medium" do
      hits?("sev:<medium", info_issue).should be_true
      hits?("sev:<medium", low_issue).should be_true
      hits?("sev:<medium", med_issue).should be_false # boundary: strict < excludes equal
      hits?("sev:<medium", high_issue).should be_false
    end

    it "sev:=high matches exactly High" do
      hits?("sev:=high", med_issue).should be_false
      hits?("sev:=high", high_issue).should be_true
      hits?("sev:=high", crit_issue).should be_false
    end

    it "bare sev:high behaves identically to sev:=high" do
      hits?("sev:high", low_issue).should be_false
      hits?("sev:high", high_issue).should be_true
      hits?("sev:high", crit_issue).should be_false
    end

    it "abbreviation med == medium (rung 2)" do
      hits?("sev:med", med_issue).should be_true
      hits?("sev:=med", med_issue).should be_true
      hits?("sev:>=med", low_issue).should be_false
      hits?("sev:>=med", med_issue).should be_true
      hits?("sev:>=med", high_issue).should be_true
    end

    it "abbreviation crit == critical (top rung 4, boundary)" do
      hits?("sev:crit", crit_issue).should be_true
      hits?("sev:crit", high_issue).should be_false
      hits?("sev:>=crit", crit_issue).should be_true # top rung is the ceiling
      hits?("sev:>=crit", high_issue).should be_false
      hits?("sev:>crit", crit_issue).should be_false # nothing above Critical
    end

    it "the severity value is matched case-insensitively (sev:HIGH, sev:MED)" do
      hits?("sev:HIGH", high_issue).should be_true
      hits?("sev:>=MED", high_issue).should be_true
      hits?("sev:>=MED", low_issue).should be_false
    end

    it "a truncated op (sev:>= , sev:>) leaves an empty value → matches all (never blanks the list)" do
      # split_op strips the operator; the residual empty value hits match_term's empty guard.
      hits?("sev:>=", info_issue).should be_true
      hits?("sev:>=", crit_issue).should be_true
      hits?("sev:>", low_issue).should be_true
      hits?("sev:", high_issue).should be_true
    end
  end

  describe "#match_severity unknown severity" do
    it "sev:bogus matches NOTHING (unknown rung → false, not match-all)" do
      # severity_value returns nil → match_severity is false for every issue.
      hits?("sev:bogus", info_issue).should be_false
      hits?("sev:bogus", low_issue).should be_false
      hits?("sev:bogus", med_issue).should be_false
      hits?("sev:bogus", high_issue).should be_false
      hits?("sev:bogus", crit_issue).should be_false
    end

    it "sev:>=bogus (an operator on an unknown rung) also matches nothing" do
      hits?("sev:>=bogus", crit_issue).should be_false
    end
  end

  describe "#match_status" do
    it "open matches only Open" do
      hits?("status:open", make_issue("c", status: Gori::Store::Status::Open)).should be_true
      hits?("status:open", make_issue("c", status: Gori::Store::Status::Confirmed)).should be_false
      hits?("status:open", make_issue("c", status: Gori::Store::Status::Resolved)).should be_false
    end

    it "confirmed and its abbreviation conf both match Confirmed" do
      confirmed = make_issue("c", status: Gori::Store::Status::Confirmed)
      hits?("status:confirmed", confirmed).should be_true
      hits?("status:conf", confirmed).should be_true
      hits?("status:confirmed", make_issue("c", status: Gori::Store::Status::Open)).should be_false
    end

    it "false-positive and fp both match FalsePositive" do
      fp = make_issue("c", status: Gori::Store::Status::FalsePositive)
      hits?("status:false-positive", fp).should be_true
      hits?("status:fp", fp).should be_true
      hits?("status:fp", make_issue("c", status: Gori::Store::Status::Resolved)).should be_false
    end

    it "resolved and done both match Resolved" do
      resolved = make_issue("c", status: Gori::Store::Status::Resolved)
      hits?("status:resolved", resolved).should be_true
      hits?("status:done", resolved).should be_true
      hits?("status:done", make_issue("c", status: Gori::Store::Status::Open)).should be_false
    end

    it "closed matches every non-open status and never Open" do
      hits?("status:closed", make_issue("c", status: Gori::Store::Status::Open)).should be_false
      hits?("status:closed", make_issue("c", status: Gori::Store::Status::Confirmed)).should be_true
      hits?("status:closed", make_issue("c", status: Gori::Store::Status::FalsePositive)).should be_true
      hits?("status:closed", make_issue("c", status: Gori::Store::Status::Resolved)).should be_true
    end

    it "an unknown status token (status:zzz) matches nothing" do
      hits?("status:zzz", make_issue("c", status: Gori::Store::Status::Open)).should be_false
      hits?("status:zzz", make_issue("c", status: Gori::Store::Status::Resolved)).should be_false
    end

    it "the st: alias resolves the same field, matched case-insensitively" do
      hits?("st:OPEN", make_issue("c", status: Gori::Store::Status::Open)).should be_true
      hits?("st:CLOSED", make_issue("c", status: Gori::Store::Status::Resolved)).should be_true
    end
  end

  describe "#match_term category / code (substring, case-insensitive)" do
    it "category matches on substring (category:head hits 'headers', category:tech does not)" do
      headers = make_issue("c", category: "headers")
      hits?("category:head", headers).should be_true
      hits?("category:headers", headers).should be_true
      hits?("category:tech", headers).should be_false
    end

    it "the cat: alias behaves like category:" do
      hits?("cat:head", make_issue("c", category: "headers")).should be_true
    end

    it "code matches on substring (code:csp hits 'missing_csp')" do
      csp = make_issue("missing_csp")
      hits?("code:missing_csp", csp).should be_true
      hits?("code:csp", csp).should be_true
      hits?("code:hsts", csp).should be_false
    end

    it "code is matched case-insensitively (code:CSP vs code missing_csp)" do
      hits?("code:CSP", make_issue("missing_csp")).should be_true
      hits?("code:MISSING", make_issue("missing_csp")).should be_true
    end

    it "category is matched case-insensitively (category:TECH vs category tech-stack)" do
      hits?("category:TECH", make_issue("c", category: "tech-stack")).should be_true
    end

    it "host matches on substring, case-insensitively" do
      hits?("host:acme", make_issue("c", host: "api.acme.test")).should be_true
      hits?("host:ACME", make_issue("c", host: "api.acme.test")).should be_true
      hits?("host:other", make_issue("c", host: "api.acme.test")).should be_false
    end
  end

  describe "#free_text (DIVERGENCE from Issues: also searches code)" do
    it "a bare token matching ONLY the code still hits (Issues would search title+host only)" do
      # NOTE: Issues::Filter free-texts title+host only; Probe adds code. We assert Probe's
      # behavior directly (no Issues::Filter instantiation) — the code-only hit is the proof.
      code_only = make_issue("missing_hsts", title: "no match here", host: "example.com")
      hits?("hsts", code_only).should be_true
    end

    it "a bare token matches title or host as well" do
      hits?("title", make_issue("c", title: "Issue title", host: "h.test")).should be_true
      hits?("acme", make_issue("c", title: "t", host: "acme.test")).should be_true
    end

    it "a bare token present in none of title/host/code does not hit" do
      hits?("absent", make_issue("missing_csp", title: "t", host: "acme.test")).should be_false
    end

    it "free text is case-insensitive across all three fields" do
      hits?("HSTS", make_issue("missing_hsts", title: "t", host: "h.test")).should be_true
      hits?("TITLE", make_issue("c", title: "Nice Title", host: "h.test")).should be_true
    end
  end

  describe "negation of a non-empty term (-field:value)" do
    it "-code:csp keeps issues whose code lacks 'csp'" do
      hits?("-code:csp", make_issue("missing_csp")).should be_false
      hits?("-code:csp", make_issue("missing_hsts")).should be_true
    end

    it "-severity:high drops High and keeps everything else" do
      hits?("-severity:high", high_issue).should be_false
      hits?("-severity:high", low_issue).should be_true
      hits?("-severity:high", crit_issue).should be_true
    end

    it "-status:open drops Open and keeps the rest" do
      hits?("-status:open", make_issue("c", status: Gori::Store::Status::Open)).should be_false
      hits?("-status:open", make_issue("c", status: Gori::Store::Status::Resolved)).should be_true
    end

    it "a negated bare token excludes matches over title/host/code" do
      hits?("-hsts", make_issue("missing_hsts")).should be_false
      hits?("-hsts", make_issue("missing_csp")).should be_true
    end
  end

  describe "empty-value DIVERGENCE (-host: matches ALL, unlike Issues)" do
    it "a bare incomplete term (host:) matches everything" do
      # match_term: `return true if t.text.empty?` fires before any field logic.
      hits?("host:", make_issue("c", host: "acme.test")).should be_true
      hits?("code:", make_issue("missing_csp")).should be_true
      hits?("category:", make_issue("c", category: "headers")).should be_true
    end

    it "a NEGATED incomplete term (-host:) STILL matches everything (Probe's deliberate divergence)" do
      # Probe returns true on empty BEFORE the negate flip, so a half-typed negation can't
      # blank the whole list. Issues::Filter returns `!t.negate` here → would match nothing.
      hits?("-host:", make_issue("c", host: "acme.test")).should be_true
      hits?("-code:", make_issue("missing_csp")).should be_true
      hits?("-status:", make_issue("c", status: Gori::Store::Status::Open)).should be_true
      hits?("-severity:", high_issue).should be_true
    end
  end

  describe "implicit AND (whitespace intersects terms)" do
    it "'category:headers sev:>=medium' requires both" do
      q = "category:headers sev:>=medium"
      hits?(q, make_issue("c", severity: Gori::Store::Severity::High, category: "headers")).should be_true
      # right category, too-low severity → excluded
      hits?(q, make_issue("c", severity: Gori::Store::Severity::Low, category: "headers")).should be_false
      # high enough, wrong category → excluded
      hits?(q, make_issue("c", severity: Gori::Store::Severity::High, category: "tech")).should be_false
    end

    it "a field term ANDs with a free-text token" do
      q = "status:open csp"
      hits?(q, make_issue("missing_csp", status: Gori::Store::Status::Open)).should be_true
      hits?(q, make_issue("missing_csp", status: Gori::Store::Status::Resolved)).should be_false
      hits?(q, make_issue("missing_hsts", status: Gori::Store::Status::Open)).should be_false
    end
  end

  describe "OR / parentheses / NOT (FilterAst boolean grammar)" do
    it "'code:csp OR code:hsts' matches either code (exercises the .or? arm)" do
      q = "code:csp OR code:hsts"
      hits?(q, make_issue("missing_csp")).should be_true
      hits?(q, make_issue("missing_hsts")).should be_true
      hits?(q, make_issue("missing_x_frame_options")).should be_false
    end

    it "'(host:a OR host:b) -category:tech' groups the OR then ANDs a negated category" do
      q = "(host:a OR host:b) -category:tech"
      # host contains 'a', category has no 'tech' → matches
      hits?(q, make_issue("c", category: "headers", host: "a.test")).should be_true
      # host contains 'b', but category has 'tech' → excluded by the negation
      hits?(q, make_issue("c", category: "tech-stack", host: "b.test")).should be_false
      # host matches neither 'a' nor 'b' → OR branch fails
      hits?(q, make_issue("c", category: "headers", host: "c.test")).should be_false
    end

    it "an explicit uppercase AND behaves like whitespace" do
      q = "status:open AND sev:>=high"
      hits?(q, make_issue("c", severity: Gori::Store::Severity::High, status: Gori::Store::Status::Open)).should be_true
      hits?(q, make_issue("c", severity: Gori::Store::Severity::Low, status: Gori::Store::Status::Open)).should be_false
    end

    it "NOT over a group excludes the whole group" do
      q = "NOT (code:csp OR code:hsts)"
      hits?(q, make_issue("missing_csp")).should be_false
      hits?(q, make_issue("missing_hsts")).should be_false
      hits?(q, make_issue("cookie_no_secure")).should be_true
    end

    it "lowercase 'or' is free text, not the operator" do
      # Keywords are UPPERCASE-only; 'or' here is a bare token searched in title+host+code.
      hits?("or", make_issue("c", title: "vendor report", host: "h.test")).should be_true
      hits?("or", make_issue("c", title: "clean", host: "h.test")).should be_false
    end
  end

  describe "#apply / #empty? / #has_status_term?" do
    it "apply selects the matching subset, preserving order" do
      issues = [info_issue, low_issue, med_issue, high_issue, crit_issue]
      filter = Gori::Probe::Filter.parse("sev:>=high")
      filter.apply(issues).map(&.code).should eq(["c_high", "c_crit"])
    end

    it "an empty query is empty? and matches every issue (apply returns the input)" do
      filter = Gori::Probe::Filter.parse("")
      filter.empty?.should be_true
      filter.matches?(high_issue).should be_true
      issues = [low_issue, high_issue]
      filter.apply(issues).should eq(issues)
    end

    it "a whitespace-only query is also empty?" do
      Gori::Probe::Filter.parse("   ").empty?.should be_true
    end

    it "has_status_term? is true only when a status/st term appears (even inside OR/negation)" do
      Gori::Probe::Filter.parse("status:open").has_status_term?.should be_true
      Gori::Probe::Filter.parse("-st:resolved").has_status_term?.should be_true
      Gori::Probe::Filter.parse("code:csp OR status:done").has_status_term?.should be_true
      Gori::Probe::Filter.parse("code:csp sev:>=high").has_status_term?.should be_false
      Gori::Probe::Filter.parse("").has_status_term?.should be_false
    end
  end

  describe "unicode / multibyte inputs" do
    it "matches CJK host/category/title substrings, case-folded where applicable" do
      issue = make_issue("missing_csp", title: "世界 title", category: "헤더", host: "안녕.example")
      hits?("host:안녕", issue).should be_true
      hits?("category:헤더", issue).should be_true
      hits?("世界", issue).should be_true # free text over title
      hits?("host:없음", issue).should be_false
    end

    it "matches an emoji token appearing in the title via free text" do
      issue = make_issue("c", title: "leak 🔑 found", host: "h.test")
      hits?("🔑", issue).should be_true
      hits?("🔒", issue).should be_false
    end

    it "matches an accented (multibyte) host substring" do
      issue = make_issue("c", host: "café.test")
      hits?("host:café", issue).should be_true
      hits?("host:zzz", issue).should be_false
    end
  end

  describe "adversarial / boundary inputs (all substring — no regex, no backtracking)" do
    it "a deeply nested / very long boolean query parses and matches quickly" do
      # 2000-way OR chain plus 200 nested parens: the forgiving parser must not blow up.
      chain = Array.new(2000) { |i| "code:c#{i}" }.join(" OR ")
      query = ("(" * 200) + chain + " OR code:target" + (")" * 200)
      elapsed = Time.measure do
        Gori::Probe::Filter.parse(query).matches?(make_issue("target")).should be_true
      end
      elapsed.should be < 2.seconds
    end

    it "a pathological run of negations and empty terms stays match-all and fast" do
      query = (["-code:"] * 500).join(" ")
      elapsed = Time.measure do
        Gori::Probe::Filter.parse(query).matches?(make_issue("missing_csp")).should be_true
      end
      elapsed.should be < 1.second
    end

    it "an unclosed group closes at end-of-input rather than blanking (forgiving parse)" do
      hits?("(code:csp OR code:hsts", make_issue("missing_csp")).should be_true
      hits?("(code:csp OR code:hsts", make_issue("cookie_no_secure")).should be_false
    end

    it "a lone dangling operator is ignored" do
      Gori::Probe::Filter.parse("AND").empty?.should be_true
      hits?("code:csp OR", make_issue("missing_csp")).should be_true
    end

    it "a quoted phrase keeps its spaces as one token" do
      issue = make_issue("c", title: "two words here", host: "h.test")
      hits?(%("two words"), issue).should be_true
      hits?(%("two zzz"), issue).should be_false
    end

    it "a single-element severity boundary (Info is rung 0, the floor)" do
      hits?("sev:<=info", info_issue).should be_true
      hits?("sev:<info", info_issue).should be_false # nothing below Info
      hits?("sev:>=info", crit_issue).should be_true # floor comparison holds for the top rung
    end
  end
end
