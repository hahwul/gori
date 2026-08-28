require "./spec_helper"
require "compress/gzip"
require "json"
require "sarif"
require "../src/gori/issues_export"

private def gzip(data : String) : Bytes
  io = IO::Memory.new
  Compress::Gzip::Writer.open(io) { |w| w.print(data) }
  io.to_slice
end

private def with_store(&)
  path = File.tempname("gori-sarif", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# A GET flow with an optional response, the fixture every case below starts from.
private def seed_flow(store : Gori::Store, *, target : String = "/a", method : String = "GET",
                      req_head : String? = nil, req_body : Bytes? = nil,
                      resp_head : String? = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n",
                      resp_body : Bytes? = nil, status : Int32 = 200,
                      scheme : String = "https", port : Int32 = 443) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: scheme, host: "h.test", port: port,
    method: method, target: target, http_version: "HTTP/1.1",
    head: (req_head || "#{method} #{target} HTTP/1.1\r\nHost: h.test\r\n\r\n").to_slice,
    body: req_body, source: Gori::FlowSource::Kind::Proxy))
  if rh = resp_head
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: status, head: rh.to_slice, body: resp_body,
      reason: "OK", content_type: "text/plain", duration_us: 1_i64))
  end
  id
end

private def export(store : Gori::Store, project : String = "proj") : String
  Gori::Issues::Export.sarif(store.issues, store, project)
end

# The single result of a one-issue export, as parsed JSON.
private def only_result(store : Gori::Store) : JSON::Any
  JSON.parse(export(store))["runs"][0]["results"][0]
end

describe Gori::Issues::Export do
  describe ".sarif" do
    it "produces a document the library itself parses and validates" do
      with_store do |store|
        fid = seed_flow(store)
        store.insert_issue("Reflected XSS in q", Gori::Store::Severity::High, "h.test", fid)

        json = export(store)
        log = Sarif.parse!(json) # raises on a schema violation
        Sarif::Validator.new.validate(log).valid?.should be_true

        doc = JSON.parse(json)
        doc["version"].as_s.should eq("2.1.0")
        doc["$schema"].as_s.should_not be_empty
        driver = doc["runs"][0]["tool"]["driver"]
        driver["name"].as_s.should eq("gori")
        driver["version"].as_s.should eq(Gori::VERSION)
        driver["informationUri"].as_s.should eq(Gori::REPOSITORY_URL)
      end
    end

    it "emits an explicit empty results array for a project with no issues" do
      # `Sarif::Builder` drops an empty array to nil, and a MISSING `results` means "the tool
      # may not have run" to a consumer, while `[]` means "it ran and found nothing" — the
      # difference between a red CI gate and a green one.
      with_store do |store|
        doc = JSON.parse(export(store))
        doc["runs"][0]["results"].as_a.should be_empty
        Sarif::Validator.new.validate(Sarif.parse!(export(store))).valid?.should be_true
      end
    end

    it "keeps the 5-way severity recoverable from SARIF's 4 levels" do
      # Critical and High both collapse to `error`; without `rank` and the rule's
      # `security-severity` they would arrive at a dashboard indistinguishable.
      expected = {
        Gori::Store::Severity::Critical => {"error", 100.0, "9.0"},
        Gori::Store::Severity::High     => {"error", 75.0, "7.0"},
        Gori::Store::Severity::Medium   => {"warning", 50.0, "5.0"},
        Gori::Store::Severity::Low      => {"note", 25.0, "3.0"},
        Gori::Store::Severity::Info     => {"note", 0.0, "0.0"},
      }
      expected.each do |severity, (level, rank, security)|
        with_store do |store|
          store.insert_issue("t #{severity}", severity, "h.test", nil)
          doc = JSON.parse(export(store))
          res = doc["runs"][0]["results"][0]
          res["level"].as_s.should eq(level)
          res["rank"].as_f.should eq(rank)
          res["properties"]["gori/severity"].as_s.should eq(severity.label)
          rule = doc["runs"][0]["tool"]["driver"]["rules"][0]
          rule["properties"]["security-severity"].as_s.should eq(security)
          rule["properties"]["tags"].as_a.map(&.as_s).should contain("security")
        end
      end
    end

    it "badges a shared rule with the WORST severity that cites it" do
      # Two issues with the same title share one rule; a dashboard lists that rule once, and
      # an operator triaging from the list needs it to read as the Critical, not the Info.
      with_store do |store|
        store.insert_issue("same finding", Gori::Store::Severity::Info, "h.test", nil)
        store.insert_issue("same finding", Gori::Store::Severity::Critical, "h.test", nil)
        doc = JSON.parse(export(store))
        rules = doc["runs"][0]["tool"]["driver"]["rules"].as_a
        rules.size.should eq(1) # grouped, not duplicated
        rules[0]["properties"]["security-severity"].as_s.should eq("9.0")
      end
    end

    it "does not let a SUPPRESSED result badge the rule its live sibling shares" do
      # GitHub applies `security-severity` per ALERT, not just in the rules list. A Critical
      # triaged to false-positive was stamping 9.0 onto the one open Info alert beside it.
      with_store do |store|
        store.insert_issue("same finding", Gori::Store::Severity::Info, "h.test", nil)
        crit = store.insert_issue("same finding", Gori::Store::Severity::Critical, "h.test", nil)
        store.update_issue(crit, status: Gori::Store::Status::FalsePositive)
        doc = JSON.parse(export(store))
        doc["runs"][0]["tool"]["driver"]["rules"][0]["properties"]["security-severity"].as_s.should eq("0.0")
      end
    end

    it "still badges a rule whose results are ALL suppressed, rather than defaulting to info" do
      with_store do |store|
        id = store.insert_issue("all dismissed", Gori::Store::Severity::Critical, "h.test", nil)
        store.update_issue(id, status: Gori::Store::Status::Resolved)
        doc = JSON.parse(export(store))
        doc["runs"][0]["tool"]["driver"]["rules"][0]["properties"]["security-severity"].as_s.should eq("9.0")
      end
    end

    it "slugs the title into a stable rule id and links every result to it" do
      with_store do |store|
        store.insert_issue("Reflected XSS in ?q=", Gori::Store::Severity::High, "h.test", nil)
        doc = JSON.parse(export(store))
        rule = doc["runs"][0]["tool"]["driver"]["rules"][0]
        rule["id"].as_s.should eq("gori/issue/reflected-xss-in-q")
        rule["shortDescription"]["text"].as_s.should eq("Reflected XSS in ?q=")
        res = doc["runs"][0]["results"][0]
        res["ruleId"].as_s.should eq("gori/issue/reflected-xss-in-q")
        res["ruleIndex"].as_i.should eq(0) # the library linked it
      end
    end

    it "cross-references every result to the rule its ruleId names" do
      # `sarif` links results to rules ITSELF now (`rule_index`), because the library's
      # `find_rule_index` is a linear scan of the rules array per result — rules × results on the
      # TUI's UI fiber. Taking the linking over means pinning the invariant it used to provide:
      # `results[i].ruleIndex` must address the descriptor whose `id` is `results[i].ruleId`, for
      # a whole document rather than for the one-rule case.
      with_store do |store|
        titles = ["Reflected XSS in ?q=", "IDOR on /orders", "Reflected XSS in ?q=", "취약점 발견"]
        titles.each { |t| store.insert_issue(t, Gori::Store::Severity::High, "h.test", nil) }
        json = export(store)
        Sarif::Validator.new.validate(Sarif.parse!(json)).valid?.should be_true
        doc = JSON.parse(json)
        rules = doc["runs"][0]["tool"]["driver"]["rules"].as_a
        rules.size.should eq(3) # the repeated title shares its rule
        results = doc["runs"][0]["results"].as_a
        results.size.should eq(4)
        results.each do |res|
          rules[res["ruleIndex"].as_i]["id"].as_s.should eq(res["ruleId"].as_s)
        end
      end
    end

    it "slugs a non-Latin title instead of deleting it" do
      # An ASCII-only character class deleted a Korean/Japanese title outright, collapsing
      # EVERY finding in a non-Latin engagement into one meaningless `untitled` rule wearing
      # whichever title landed first — and this project ships Korean docs.
      with_store do |store|
        store.insert_issue("취약점 발견", Gori::Store::Severity::High, "h.test", nil)
        store.insert_issue("다른 취약점", Gori::Store::Severity::Low, "h.test", nil)
        doc = JSON.parse(export(store))
        ids = doc["runs"][0]["tool"]["driver"]["rules"].as_a.map(&.["id"].as_s)
        ids.should eq(["gori/issue/취약점-발견", "gori/issue/다른-취약점"])
      end
    end

    it "gives two title-less issues two rules, not one shared bucket" do
      # "???" and "———" have nothing to do with each other; a single `untitled` rule would
      # group them, so the fallback is keyed on the title's own digest.
      with_store do |store|
        store.insert_issue("???", Gori::Store::Severity::Low, "h.test", nil)
        store.insert_issue("———", Gori::Store::Severity::Low, "h.test", nil)
        ids = JSON.parse(export(store))["runs"][0]["tool"]["driver"]["rules"].as_a.map(&.["id"].as_s)
        ids.size.should eq(2)
        ids.each &.should match(%r{\Agori/issue/untitled-[0-9a-f]{8}\z})
        ids.uniq.size.should eq(2)
      end
    end

    it "keeps two long titles apart when only their first 60 characters agree" do
      # SLUG_CAP is a length limit, and the comment above `rule_id` called a collision "benign"
      # on the strength of "XSS!" vs "XSS?". A PREFIX cap merges any two titles that agree for 60
      # characters — and what tells two findings apart (the parameter, the endpoint) usually sits
      # at the END of the sentence, so the merge lands on exactly the pairs a dashboard must keep
      # apart. The empty-slug path already appends a digest for this reason; the cut path now does
      # too, inside the cap rather than beyond it.
      with_store do |store|
        store.insert_issue("SQL injection in the user profile update endpoint (parameter id)",
          Gori::Store::Severity::High, "h.test", nil)
        store.insert_issue("SQL injection in the user profile update endpoint (parameter name)",
          Gori::Store::Severity::Critical, "h.test", nil)
        rules = JSON.parse(export(store))["runs"][0]["tool"]["driver"]["rules"].as_a
        ids = rules.map(&.["id"].as_s)
        ids.uniq.size.should eq(2)
        ids.each &.should match(%r{\Agori/issue/sql-injection-.*-[0-9a-f]{8}\z})
        # …still inside the cap the constant promises.
        ids.each { |id| id.lchop("gori/issue/").size.should be <= 60 }
        # The two severities land on their OWN rules rather than one badge for both.
        rules.map(&.["properties"]["security-severity"].as_s).sort!.should eq(["7.0", "9.0"])
      end
    end

    it "gives one title one rule however long it is" do
      # The digest is of the WHOLE title, so grouping repeats of one finding — the feature the
      # cap must not cost — still works past 60 characters.
      with_store do |store|
        long = "Server-side request forgery reachable from the avatar import endpoint parameter url"
        2.times { store.insert_issue(long, Gori::Store::Severity::High, "h.test", nil) }
        doc = JSON.parse(export(store))
        doc["runs"][0]["tool"]["driver"]["rules"].as_a.size.should eq(1)
        doc["runs"][0]["results"].as_a.map(&.["ruleIndex"].as_i).should eq([0, 0])
      end
    end

    it "suppresses a false-positive and a resolved issue, but not an open or confirmed one" do
      # A false-positive arriving at a dashboard as an OPEN finding is worse than not
      # exporting it at all — `suppressions` is how SARIF says "triaged away".
      {Gori::Store::Status::Open, Gori::Store::Status::Confirmed}.each do |status|
        with_store do |store|
          id = store.insert_issue("t", Gori::Store::Severity::Low, "h.test", nil)
          store.update_issue(id, status: status)
          res = only_result(store)
          res["suppressions"]?.should be_nil
          res["properties"]["gori/status"].as_s.should eq(status.label)
        end
      end

      {
        Gori::Store::Status::FalsePositive => "marked false-positive in gori",
        Gori::Store::Status::Resolved      => "resolved in gori",
      }.each do |status, justification|
        with_store do |store|
          id = store.insert_issue("t", Gori::Store::Severity::Low, "h.test", nil)
          store.update_issue(id, status: status)
          res = only_result(store)
          sup = res["suppressions"][0]
          sup["kind"].as_s.should eq("external")
          sup["status"].as_s.should eq("accepted")
          sup["justification"].as_s.should eq(justification)
          # The raw label still rides along, so nothing is lost to the collapse.
          res["properties"]["gori/status"].as_s.should eq(status.label)
        end
      end
    end

    it "locates a finding at its flow's URL, falling back to the host, then to nothing" do
      with_store do |store|
        fid = seed_flow(store, target: "/search?q=1")
        store.insert_issue("with flow", Gori::Store::Severity::Low, "h.test", fid)
        uri = only_result(store)["locations"][0]["physicalLocation"]["artifactLocation"]["uri"].as_s
        uri.should eq("https://h.test/search?q=1")
      end

      with_store do |store|
        store.insert_issue("host only", Gori::Store::Severity::Low, "api.test", nil)
        uri = only_result(store)["locations"][0]["physicalLocation"]["artifactLocation"]["uri"].as_s
        uri.should eq("https://api.test/")
      end

      with_store do |store|
        # No flow and no host: omit the location rather than invent one.
        store.insert_issue("no location", Gori::Store::Severity::Low, nil, nil)
        only_result(store)["locations"]?.should be_nil
      end
    end

    it "carries the linked flow's exchange as webRequest/webResponse" do
      with_store do |store|
        fid = seed_flow(store,
          method: "POST", target: "/login",
          req_head: "POST /login HTTP/1.1\r\nHost: h.test\r\nContent-Type: application/json\r\n\r\n",
          req_body: %({"u":"admin"}).to_slice,
          resp_head: "HTTP/1.1 401 Unauthorized\r\nServer: nginx\r\n\r\n",
          resp_body: "denied".to_slice, status: 401)
        store.insert_issue("auth bypass", Gori::Store::Severity::High, "h.test", fid)

        res = only_result(store)
        req = res["webRequest"]
        req["method"].as_s.should eq("POST")
        req["target"].as_s.should eq("https://h.test/login")
        req["protocol"].as_s.should eq("https")
        req["version"].as_s.should eq("1.1") # the protocol version alone, not "HTTP/1.1"
        req["headers"]["Content-Type"].as_s.should eq("application/json")
        req["body"]["text"].as_s.should eq(%({"u":"admin"}))

        resp = res["webResponse"]
        resp["statusCode"].as_i.should eq(401)
        resp["headers"]["Server"].as_s.should eq("nginx")
        resp["body"]["text"].as_s.should eq("denied")
      end
    end

    it "folds repeated headers into one comma-joined value" do
      # SARIF's `headers` is a JSON object but HTTP allows repeats (Set-Cookie above all);
      # dropping all but one would lose evidence.
      with_store do |store|
        fid = seed_flow(store,
          resp_head: "HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\n")
        store.insert_issue("cookies", Gori::Store::Severity::Info, "h.test", fid)
        only_result(store)["webResponse"]["headers"]["Set-Cookie"].as_s.should eq("a=1, b=2")
      end

      # Field names are case-insensitive (RFC 9110 §5.1), so `set-cookie` and `Set-Cookie` are
      # ONE field with two values — keying the fold on the raw name emitted two JSON keys.
      with_store do |store|
        fid = seed_flow(store,
          resp_head: "HTTP/1.1 200 OK\r\nset-cookie: a=1\r\nSet-Cookie: b=2\r\n\r\n")
        store.insert_issue("cookies", Gori::Store::Severity::Info, "h.test", fid)
        headers = only_result(store)["webResponse"]["headers"].as_h
        headers.keys.count { |k| k.downcase == "set-cookie" }.should eq(1)
        headers["set-cookie"].as_s.should eq("a=1, b=2") # first casing seen on the wire
      end
    end

    it "omits an empty reasonPhrase rather than emitting one" do
      # HTTP/2 has no reason phrase by design, and an h1 status line may omit it.
      with_store do |store|
        fid = seed_flow(store, resp_head: "HTTP/1.1 200\r\nContent-Type: text/plain\r\n\r\n")
        store.insert_issue("no reason", Gori::Store::Severity::Low, "h.test", fid)
        only_result(store)["webResponse"]["reasonPhrase"]?.should be_nil
      end
    end

    it "says so explicitly when a flow never got a response" do
      with_store do |store|
        fid = seed_flow(store, resp_head: nil)
        store.insert_issue("aborted", Gori::Store::Severity::Low, "h.test", fid)
        res = only_result(store)
        res["webResponse"]["noResponseReceived"].as_bool.should be_true
        res["webResponse"]["body"]?.should be_nil
      end
    end

    it "inflates a gzipped response body rather than dropping it as binary" do
      with_store do |store|
        fid = seed_flow(store,
          resp_head: "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n",
          resp_body: gzip("<html>secret</html>"))
        store.insert_issue("leak", Gori::Store::Severity::Medium, "h.test", fid)
        only_result(store)["webResponse"]["body"]["text"].as_s.should eq("<html>secret</html>")
      end
    end

    it "omits a binary body instead of emitting mojibake" do
      with_store do |store|
        fid = seed_flow(store, resp_body: Bytes[0x00, 0xFF, 0xFE, 0x01])
        store.insert_issue("binary", Gori::Store::Severity::Low, "h.test", fid)
        only_result(store)["webResponse"]["body"]?.should be_nil
      end
    end

    it "caps a huge body and says how much was cut" do
      with_store do |store|
        cap = Gori::Issues::Export::EVIDENCE_CAP
        big = "a" * (cap + 4096)
        fid = seed_flow(store, resp_body: big.to_slice)
        store.insert_issue("big", Gori::Store::Severity::Low, "h.test", fid)
        text = only_result(store)["webResponse"]["body"]["text"].as_s
        # A consumer reading 64 KiB of a larger response must not think it has the whole thing.
        text.should contain("body truncated, #{big.bytesize} bytes total")
        text.size.should be < big.bytesize
      end
    end

    it "stays valid UTF-8 when the capture carried a raw byte" do
      # Titles, hosts, targets and HEADER BYTES all originate outside gori (an h2 `:path` or an
      # obs-text header value can be invalid UTF-8). One unscrubbed byte makes the whole
      # document fail `valid_encoding?` and breaks it for a strict consumer — the same gap
      # `Export.json` closes for its own fields.
      with_store do |store|
        raw = String.new(Bytes[0x2f, 0x80, 0x61]) # "/\x80a"
        fid = seed_flow(store, target: raw,
          req_head: String.new("GET /x HTTP/1.1\r\nHost: h.test\r\nX-Bad: ".to_slice + Bytes[0xFF_u8] + "\r\n\r\n".to_slice))
        store.insert_issue(String.new(Bytes[0x74, 0x80, 0x74]), Gori::Store::Severity::High, raw, fid)

        json = export(store)
        json.valid_encoding?.should be_true
        JSON.parse(json)   # still parseable
        Sarif.parse!(json) # and still a valid SARIF log
      end
    end

    it "keeps a title's embedded newline off the message's first line" do
      with_store do |store|
        store.insert_issue("pwn\n## FAKE HEADING", Gori::Store::Severity::High, "h.test", nil)
        res = only_result(store)
        res["message"]["text"].as_s.lines[0].should eq("pwn ## FAKE HEADING")
      end
    end

    it "mirrors the Markdown report in message.markdown, notes and links included" do
      with_store do |store|
        primary = seed_flow(store)
        linked = seed_flow(store, target: "/other")
        iid = store.insert_issue("has context", Gori::Store::Severity::Medium, "h.test", primary)
        store.update_issue(iid, notes: "found via param fuzzing")
        store.add_link(Gori::Store::LinkOwnerKind::Issue, iid, Gori::Store::LinkRefKind::Flow, linked)

        res = only_result(store)
        md = res["message"]["markdown"].as_s
        # The same block `Export.markdown` writes for this issue…
        md.should contain("## [medium] has context")
        md.should contain("found via param fuzzing")
        md.should contain("### Related")
        Gori::Issues::Export.markdown(store.issues, store, "proj").should contain(md)
        # …MINUS the evidence fences: the request and response are already on this result as
        # webRequest/webResponse, and carrying them twice roughly doubled the document.
        md.should_not contain("### Request")
        md.should_not contain("```http")
        res["webRequest"]["target"].as_s.should eq("https://h.test/a")

        res["message"]["text"].as_s.should contain("found via param fuzzing")
        link = res["properties"]["gori/links"][0]
        link["kind"].as_s.should eq("flow")
        link["ref_id"].as_i64.should eq(linked)
        link["url"].as_s.should eq("https://h.test/other")
      end
    end

    it "fingerprints an issue by both its row id and its content" do
      # `gori/issueId` addresses THIS project DB; `gori/finding` survives a re-created one,
      # which is what lets a dashboard track the same finding across engagements.
      with_store do |store|
        id = store.insert_issue("t", Gori::Store::Severity::Low, "h.test", nil)
        fps = only_result(store)["partialFingerprints"]
        fps["gori/issueId"].as_s.should eq(id.to_s)
        fps["gori/finding"].as_s.size.should eq(64) # SHA-256 hex
      end

      # Same title/host/severity in a DIFFERENT store ⇒ the same content fingerprint.
      digests = [] of String
      2.times do
        with_store do |store|
          store.insert_issue("t", Gori::Store::Severity::Low, "h.test", nil)
          digests << only_result(store)["partialFingerprints"]["gori/finding"].as_s
        end
      end
      digests[0].should eq(digests[1])
    end

    it "fingerprints two findings at DIFFERENT locations differently" do
      # The other half of the property above, and the one the spec did not ask for: "same ⇒ same"
      # is satisfied by a constant. `gori/finding` exists so a dashboard can recognise a finding
      # across a re-created DB, which means DEDUPLICATING on it — and title+host+severity alone
      # made two separate IDORs, on /one and /two, one fingerprint. The location was already in
      # hand: `sarif_location` writes the same URI onto the result.
      with_store do |store|
        one = seed_flow(store, target: "/one")
        two = seed_flow(store, target: "/two")
        store.insert_issue("IDOR", Gori::Store::Severity::High, "h.test", one)
        store.insert_issue("IDOR", Gori::Store::Severity::High, "h.test", two)
        results = JSON.parse(export(store))["runs"][0]["results"].as_a
        fps = results.map(&.["partialFingerprints"]["gori/finding"].as_s)
        fps.uniq.size.should eq(2)
        # …and the fingerprint still says WHICH location, matching the result's own.
        results.map(&.["locations"][0]["physicalLocation"]["artifactLocation"]["uri"].as_s)
          .sort!.should eq(["https://h.test/one", "https://h.test/two"])
      end
    end

    it "folds an obs-fold continuation into the header above it instead of inventing one" do
      # RFC 9112 §5.2: a line starting with SP/HTAB continues the PREVIOUS field's value.
      # `one_line(h.name)` strips the very byte that says so, so `  X-Fake: part2` arrived as a
      # header of its own — a webRequest reporting a field the wire never carried, beside a
      # truncated version of the one it did. The curl export invented the same header and the
      # JSON-Lines export reported it as `"  X-Fake"`: three surfaces, three header sets, one
      # head. A finding ABOUT a header-parsing difference must not be reported through one.
      with_store do |store|
        head = "GET /a HTTP/1.1\r\nHost: h.test\r\nX-Long: part1\r\n  X-Fake: part2\r\nX-Last: z\r\n\r\n"
        fid = seed_flow(store, req_head: head,
          resp_head: "HTTP/1.1 200 OK\r\nX-Csp: default-src 'self';\r\n\tscript-src 'none'\r\n\r\n")
        store.insert_issue("t", Gori::Store::Severity::Low, "h.test", fid)
        res = only_result(store)
        headers = res["webRequest"]["headers"].as_h
        headers.has_key?("X-Fake").should be_false
        headers["X-Long"].as_s.should eq("part1 X-Fake: part2")
        headers["X-Last"].as_s.should eq("z")
        # A COLON-LESS continuation is a different (and smaller) loss: `Http1.parse_headers`
        # drops any line without a colon, so it never reaches this writer at all and the value
        # arrives short. Pinned as it is rather than wished away — the fold this file can see is
        # the one that INVENTS a field, and that one is gone.
        res["webResponse"]["headers"]["X-Csp"].as_s.should eq("default-src 'self';")
      end
    end

    it "carries the project and the issue's timestamps as readable properties" do
      with_store do |store|
        fid = seed_flow(store)
        id = store.insert_issue("t", Gori::Store::Severity::Low, "h.test", fid)
        props = only_result(store)["properties"]
        props["gori/project"].as_s.should eq("proj")
        props["gori/issueId"].as_i64.should eq(id)
        props["gori/host"].as_s.should eq("h.test")
        props["gori/flowId"].as_i64.should eq(fid)
        # RFC 3339 UTC, not raw unix micros a human can't read in a dashboard.
        props["gori/createdAt"].as_s.should match(/\A\d{4}-\d{2}-\d{2}T[\d:]{8}Z\z/)
        Time.parse_rfc3339(props["gori/updatedAt"].as_s).should be_a(Time)
      end
    end

    it "carries CVSS in result properties and uses CVSS score for rule security-severity" do
      with_store do |store|
        store.insert_issue("SQLi in login", Gori::Store::Severity::Critical, "h.test", nil,
          cvss: "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")

        doc = JSON.parse(export(store))
        res = doc["runs"][0]["results"][0]
        res["properties"]["gori/cvss"].as_s.should eq("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H")
        res["properties"]["gori/cvssScore"].as_f.should eq(9.8)

        rule = doc["runs"][0]["tool"]["driver"]["rules"][0]
        rule["properties"]["security-severity"].as_s.should eq("9.8")
      end
    end

    # The badge is per RULE, and the rule's promise is "the worst under it". Ranking a CVSS
    # score against a bare severity meant an unscored Critical could be badged as its scored
    # Low sibling — the exact reading this property exists to prevent. Both halves fold to a
    # number first (an unscored issue contributes its band floor), so the worst still wins.
    it "does not let a scored Low outrank an unscored Critical on the same rule" do
      with_store do |store|
        store.insert_issue("SQLi in login", Gori::Store::Severity::Critical, "a.test", nil)
        store.insert_issue("SQLi in login", Gori::Store::Severity::Low, "b.test", nil, cvss: "3.0")

        doc = JSON.parse(export(store))
        rules = doc["runs"][0]["tool"]["driver"]["rules"].as_a
        rules.size.should eq(1) # one title, one rule
        rules[0]["properties"]["security-severity"].as_s.should eq("9.0")
      end
    end

    # …and the score still beats the floor when it belongs to the worst one, which is the
    # whole reason for carrying it.
    it "prefers a real score over the band floor when it is the highest" do
      with_store do |store|
        store.insert_issue("SQLi in login", Gori::Store::Severity::Critical, "a.test", nil, cvss: "9.8")
        store.insert_issue("SQLi in login", Gori::Store::Severity::Medium, "b.test", nil)

        doc = JSON.parse(export(store))
        doc["runs"][0]["tool"]["driver"]["rules"][0]["properties"]["security-severity"].as_s.should eq("9.8")
      end
    end

    # An issue can carry a cvss AND a severity the operator raised above it — the issue form
    # supports exactly that and keeps the vector. Taking the score alone would badge the rule
    # at the technical number while the result beside it ships level:error / rank 100, and
    # GitHub reads THIS property for the alert's severity.
    it "does not let a low cvss erase a severity the operator raised above it" do
      with_store do |store|
        store.insert_issue("business-critical bypass", Gori::Store::Severity::Critical, "a.test", nil, cvss: "3.5")
        doc = JSON.parse(export(store))
        doc["runs"][0]["tool"]["driver"]["rules"][0]["properties"]["security-severity"].as_s.should eq("9.0")
        doc["runs"][0]["results"][0]["properties"]["gori/cvssScore"].as_f.should eq(3.5)
      end
    end

    # A log with no cvss anywhere must be byte-identical to what it was before the column
    # existed: the floors are the same numbers, printed the same way.
    it "keeps the band floors for a log with no cvss at all" do
      with_store do |store|
        store.insert_issue("no score here", Gori::Store::Severity::Medium, "h.test", nil)
        doc = JSON.parse(export(store))
        doc["runs"][0]["tool"]["driver"]["rules"][0]["properties"]["security-severity"].as_s.should eq("5.0")
      end
    end
  end
end
