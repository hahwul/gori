require "./spec_helper"
require "../src/gori/issues_query"

include Gori

private def fnd(title : String, severity : Store::Severity, status : Store::Status = Store::Status::Open,
                host : String? = nil) : Store::Issue
  Store::Issue.new(1_i64, 0_i64, 0_i64, title, severity, host, nil, "", status)
end

private def filtered(query : String, list : Array(Store::Issue)) : Array(Store::Issue)
  Issues::Filter.parse(query).apply(list)
end

describe Gori::Issues::Filter do
  list = [
    fnd("Reflected XSS in search", Store::Severity::High, Store::Status::Open, "app.example.com"),
    fnd("SQL injection in login", Store::Severity::Critical, Store::Status::Confirmed, "api.example.com"),
    fnd("Verbose error page", Store::Severity::Low, Store::Status::Resolved, "app.example.com"),
    fnd("Missing security header", Store::Severity::Info, Store::Status::FalsePositive, "cdn.example.net"),
  ]

  it "passes everything for an empty query" do
    filtered("", list).size.should eq(4)
    Issues::Filter.parse("").empty?.should be_true
  end

  it "filters by exact triage status" do
    filtered("status:open", list).map(&.title).should eq(["Reflected XSS in search"])
    filtered("st:confirmed", list).size.should eq(1)
    filtered("status:fp", list).size.should eq(1)
  end

  it "treats status:closed as any non-open state" do
    filtered("status:closed", list).map(&.severity)
      .should eq([Store::Severity::Critical, Store::Severity::Low, Store::Severity::Info])
  end

  it "compares severity ordinally" do
    filtered("sev:>=high", list).map(&.title).should eq(["Reflected XSS in search", "SQL injection in login"])
    filtered("severity:critical", list).size.should eq(1)
    filtered("sev:<medium", list).size.should eq(2) # low + info
    filtered("sev:crit", list).size.should eq(1)    # abbreviation
  end

  it "matches host and title substrings, case-insensitively" do
    filtered("host:api", list).size.should eq(1)
    filtered("title:XSS", list).size.should eq(1)
    filtered("example.com", list).size.should eq(3) # free text over host; the .net row is excluded
  end

  it "negates a field term with a leading -" do
    filtered("-status:open", list).size.should eq(3)
    filtered("-host:example.com", list).map(&.host).should eq(["cdn.example.net"])
  end

  it "ANDs multiple terms" do
    filtered("status:open sev:>=high", list).size.should eq(1)
    filtered("host:example.com severity:critical", list).map(&.title).should eq(["SQL injection in login"])
  end

  it "falls back to free text for an unknown field" do
    filtered("login", list).size.should eq(1)
    filtered("nope:zzz", list).size.should eq(0)
  end

  it "matches all for an empty field value (incremental typing), respecting negation" do
    filtered("status:", list).size.should eq(4) # mid-type — don't blank the list
    filtered("sev:>=", list).size.should eq(4)
    filtered("host:", list).size.should eq(4)
    filtered("-status:", list).size.should eq(0) # negated empty → match none
  end

  cvss_list = [
    Store::Issue.new(1_i64, 0_i64, 0_i64, "Crit Issue", Store::Severity::Critical, "api.test", nil, "", Store::Status::Open, "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"),
    Store::Issue.new(2_i64, 0_i64, 0_i64, "High Issue", Store::Severity::High, "app.test", nil, "", Store::Status::Open, "7.5"),
    Store::Issue.new(3_i64, 0_i64, 0_i64, "Med Issue", Store::Severity::Medium, "app.test", nil, "", Store::Status::Open, "5.0"),
    Store::Issue.new(4_i64, 0_i64, 0_i64, "No CVSS", Store::Severity::Low, "cdn.test", nil, "", Store::Status::Open, nil),
  ]

  it "filters by CVSS numeric comparisons" do
    filtered("cvss:>=7.0", cvss_list).map(&.title).should eq(["Crit Issue", "High Issue"])
    filtered("cvss:>9.0", cvss_list).map(&.title).should eq(["Crit Issue"])
    filtered("cvss:<=5.0", cvss_list).map(&.title).should eq(["Med Issue"])
    filtered("cvss:<5.0", cvss_list).should be_empty
  end

  it "matches CVSS vector substring or exact score" do
    filtered("cvss:3.1", cvss_list).map(&.title).should eq(["Crit Issue"])
    filtered("cvss:7.5", cvss_list).map(&.title).should eq(["High Issue"])
  end

  it "supports negative CVSS filters" do
    filtered("-cvss:>=7.0", cvss_list).map(&.title).should eq(["Med Issue", "No CVSS"])
  end
end

private def with_cvss(id : Int64, severity : Store::Severity, cvss : String?) : Store::Issue
  Store::Issue.new(id, 0_i64, 0_i64, "t#{id}", severity, nil, nil, "", Store::Status::Open, cvss)
end

describe "Issues::Filter — cvss:" do
  scored = with_cvss(1_i64, Store::Severity::High, "7.5")
  vector = with_cvss(2_i64, Store::Severity::Critical, "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")
  none = with_cvss(3_i64, Store::Severity::Low, nil)
  # An unscorable string: legacy or imported, and the surfaces refuse to write new ones.
  legacy = with_cvss(4_i64, Store::Severity::Low, "CVSS:9.9/AV:N")
  all = [scored, vector, none, legacy]

  # WHICH reading `cvss:` takes is decided by the OPERATOR, not by whether the operand happens
  # to look like a number. Branching on the operand let `cvss:>=high` — the obvious transfer
  # from the documented `sev:>=high` — quietly become a substring search and report matches as
  # if the comparison had been honoured.
  it "answers a comparison numerically or not at all" do
    filtered("cvss:>=7.0", all).map(&.id).should eq([1_i64, 2_i64])
    filtered("cvss:<4.0", all).should be_empty
    filtered("cvss:>3.1", all).map(&.id).should eq([1_i64, 2_i64])
    filtered("cvss:>=high", all).should be_empty # not a number: no comparison to make
  end

  # Bare `cvss:` still reads both ways — the score when the operand is one, else a substring of
  # the stored vector. An unscorable value is reachable through the substring half; the old
  # code bailed on the missing score before ever trying the text.
  it "matches a bare term by score or by vector substring" do
    filtered("cvss:9.8", all).map(&.id).should eq([2_i64])
    filtered("cvss:3.1", all).map(&.id).should eq([2_i64]) # the version, as a substring
    legacy.cvss_score.should be_nil
    filtered("cvss:9.9", all).map(&.id).should eq([4_i64])
    filtered("cvss:4.0", all).should be_empty
  end

  it "leaves an issue with no cvss out of every positive term" do
    filtered("cvss:7.5", all).map(&.id).should eq([1_i64])
    filtered("-cvss:>=7.0", all).map(&.id).should eq([3_i64, 4_i64])
  end
end

# The vocabulary the filter bar PAINTS with must be the vocabulary the parser DISPATCHES on.
# They were two lists, and only the parser's had the aliases: `hsot:acme` rendered in the same
# confident blue as a real field while the whole token free-texted and matched nothing, which
# is the one visible signal an operator has while typing.
describe Gori::Issues::Filter do
  describe ".known_field?" do
    it "answers for every spelling `build_term` dispatches on, and no other" do
      Issues::Filter::KNOWN.each { |name| Issues::Filter.known_field?(name).should be_true }
      Issues::Filter.known_field?("SEV").should be_true # names are matched case-insensitively
      Issues::Filter.known_field?("hsot").should be_false
      Issues::Filter.known_field?("resp.status").should be_false
      # Only QL and the intercept gate implement `~`; this backend free-texts `title~admin`.
      Issues::Filter.known_field?("title", regex: true).should be_false
    end

    # The pin, so the two cannot drift: a KNOWN name with an empty value is a field term, and
    # `match_term` passes every issue for one. An unknown name is not a field at all — the
    # whole `foo:` token free-texts over title+host and matches nothing here.
    it "agrees with `build_term` on which names are fields" do
      issue = fnd("Reflected XSS in search", Store::Severity::High, Store::Status::Open, "app.example.com")
      Issues::Filter::KNOWN.each do |name|
        Issues::Filter.parse("#{name}:").matches?(issue).should be_true
      end
      Issues::Filter.parse("hsot:").matches?(issue).should be_false
    end

    it "keeps FIELDS a completion list of canonical names only" do
      Issues::Filter::FIELDS.should eq(["severity:", "status:", "host:", "title:", "cvss:"])
    end
  end

  # The completion row is the only place most operators ever read this grammar, so the table
  # it reads from has to stay in step with the table `build_term` dispatches on — the same
  # reason `ALIASES` is pinned against `build_term` above. A field with no help entry renders
  # a bright candidate and a blank explanation; a help entry with no field describes a term
  # the parser free-texts.
  describe "the completion help table" do
    it "describes every canonical field, and nothing else" do
      Issues::Filter::FIELD_HELP.keys.sort!.should eq(Issues::Filter::ALIASES.keys.sort!)
      Issues::Filter::FIELD_HELP.each_value(&.should_not(be_empty))
    end

    it "answers for every spelling build_term dispatches on, canonical or alias" do
      Issues::Filter::KNOWN.each do |spelling|
        Issues::Filter.field_help(spelling).should_not be_nil
      end
    end

    it "declines a field this backend does not implement" do
      # `QuerySuggest.describe_for` asks by the name the OPERATOR typed, so a table that
      # answered for QL's vocabulary would explain a term that compiles to free text.
      Issues::Filter.field_help("path").should be_nil
      Issues::Filter.field_help("dur").should be_nil
    end

    it "keeps ALSO_ACCEPTED to the aliases, never the canonical spellings" do
      # The `?` reference prints these as `from: = to:`; an identity row is noise.
      Issues::Filter::ALSO_ACCEPTED.each { |from, to| from.should_not eq(to) }
      Issues::Filter::ALSO_ACCEPTED.each_value { |to| Issues::Filter::ALIASES.has_key?(to).should be_true }
      expected = Issues::Filter::ALIASES.flat_map { |canon, sp| sp.reject { |x| x == canon } }.sort!
      Issues::Filter::ALSO_ACCEPTED.keys.sort!.should eq(expected)
    end
  end

  describe ".suggestions" do
    it "completes a field name, carrying the grammar's punctuation through" do
      # The old `[/\S*\z/]` tokenizer tested the WHOLE chunk, so `-sev` never matched
      # `"severity:".starts_with?` and a negated field had no completion at all.
      Issues::Filter.suggestions("sev", 3).should eq(["severity:"])
      Issues::Filter.suggestions("-sev", 4).should eq(["-severity:"])
      Issues::Filter.suggestions("(sev", 4).should eq(["(severity:"])
      Issues::Filter.suggestions("st", 2).should eq(["status:"])
    end

    it "completes VALUES once a `:` is typed — which it could not do before at all" do
      Issues::Filter.suggestions("status:", 7).should eq(
        ["status:open", "status:confirmed", "status:false-positive", "status:resolved", "status:closed"])
      Issues::Filter.suggestions("status:c", 8).should eq(["status:confirmed", "status:closed"])
      Issues::Filter.suggestions("severity:h", 10).should eq(["severity:high"])
    end

    it "offers only values `match_status` and `severity_value` actually accept" do
      # The test is that each offered value MATCHES an issue in that very state. A bogus
      # spelling free-texts over title + host, matches nothing, and would sail past any
      # weaker check that merely asserted "does not match this one issue".
      states = {
        "open"           => Store::Status::Open,
        "confirmed"      => Store::Status::Confirmed,
        "false-positive" => Store::Status::FalsePositive,
        "resolved"       => Store::Status::Resolved,
      }
      Issues::Filter::STATUS_VALUES.each do |v|
        next if v == "closed" # a CLASS of states rather than one of them — asserted below
        Issues::Filter.parse("status:#{v}").matches?(fnd("x", Store::Severity::High, states[v])).should be_true
      end
      sevs = {
        "info"     => Store::Severity::Info,
        "low"      => Store::Severity::Low,
        "medium"   => Store::Severity::Medium,
        "high"     => Store::Severity::High,
        "critical" => Store::Severity::Critical,
      }
      Issues::Filter::SEVERITY_VALUES.each do |v|
        Issues::Filter.parse("severity:#{v}").matches?(fnd("x", sevs[v])).should be_true
      end
      Issues::Filter.parse("status:closed").matches?(fnd("x", Store::Severity::High, Store::Status::Resolved)).should be_true
      Issues::Filter.parse("status:closed").matches?(fnd("x", Store::Severity::High, Store::Status::Open)).should be_false
    end

    it "teaches the comparison operators completion can never reach" do
      # ↹ offers NAMES until a `:` is typed, so without these samples nothing on the bar ever
      # shows that these two fields take an operator.
      Issues::Filter.suggestions("severity:>", 10).should eq(["severity:>=medium", "severity:>=high", "severity:>=critical"])
      Issues::Filter.suggestions("cvss:>", 6).should eq(["cvss:>=4.0", "cvss:>=7.0", "cvss:>=9.0"])
    end

    it "completes host: from the caller's pool and title: from nothing" do
      hosts = ["api.example.com", "app.example.com"]
      Issues::Filter.suggestions("host:a", 6, hosts).should eq(["host:api.example.com", "host:app.example.com"])
      # `title:` is free text. A name that completes over an EMPTY value list reads as a
      # closed field with nothing in it, so it must offer none at all.
      Issues::Filter.suggestions("title:", 6, hosts).should be_empty
    end

    it "offers nothing on blank space" do
      Issues::Filter.suggestions("", 0).should be_empty
      Issues::Filter.suggestions("host:a ", 7).should be_empty
    end
  end

  describe "the ? reference page" do
    it "states this backend's grammar, not QL's" do
      body = (Issues::Filter::SYNTAX_HELP + Issues::Filter::CAVEATS).map { |(a, b)| "#{a} #{b}" }.join("\n")
      # Every one of these is a QL axis this parser does not have; naming any of them is the
      # defect b28aaaaa fixed, arriving from the reference page instead of the hint row.
      %w[dur: respsize: reqsize: resp.body: req.header: scope: src:].each do |absent|
        body.should_not contain(absent)
      end
      # …and it says so about the one an operator is most likely to try.
      body.should contain("no regex")
    end

    # The examples an operator copies off this page must PARSE on this backend. Derived, not
    # listed: the absent-list above is a denylist and cannot catch a field nobody thought to
    # name — `title:"missing header"` shipped in Probe's SYNTAX_HELP and `title` is not a Probe
    # field, which is precisely the defect class ("a filter bar naming a field it does not
    # have") these tables exist to end.
    #
    # Only the EXAMPLE half is scanned. The meaning half is English, and says things like "any
    # non-open triage state: confirmed, fp or resolved" — there `state:` is prose.
    it "teaches only fields this backend actually parses" do
      offenders = [] of String
      (Gori::Issues::Filter::SYNTAX_HELP + Gori::Issues::Filter::CAVEATS).each do |(example, _)|
        example.scan(/(?:^|[\s("\-])-?([a-z][a-z0-9.]*):/) do |m|
          name = m[1]
          offenders << "#{name}: in #{example.inspect}" unless Gori::Issues::Filter.known_field?(name)
        end
      end
      offenders.should be_empty
    end
  end
end
