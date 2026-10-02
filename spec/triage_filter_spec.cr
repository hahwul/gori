require "./spec_helper"
require "../src/gori/issues_query"
require "../src/gori/probe_query"

# Characterization of the two triage filter bars, `Issues::Filter` and `Probe::Filter`, which
# share most of their machinery. Every row runs through BOTH, so a shared piece that drifts
# for one of them shows up as a changed line, and the rows where they differ by design
# (`-status:` none vs all, cvss vs category/code) stay visible side by side.

private def issue(id, title, sev, status, host, cvss) : Gori::Store::Issue
  Gori::Store::Issue.new(id.to_i64, 0_i64, 0_i64, title, sev, host, nil, "", status, cvss)
end

private def probe(id, code, category, host, title, sev, status) : Gori::Store::ProbeIssue
  Gori::Store::ProbeIssue.new(id.to_i64, code, category, host, title, sev, status, 1_i64,
    [] of String, nil, nil, 1_i64, 1_i64)
end

private def row(p : Gori::Store::ProbeIssue) : Gori::Store::ProbeIssueRow
  Gori::Store::ProbeIssueRow.new(p.id, p.code, p.category, p.host, p.title, p.severity, p.status,
    p.hit_count, 0, nil, nil, 1_i64, 1_i64)
end

private ISSUES = [
  issue(1, "Reflected XSS in search", Gori::Store::Severity::High, Gori::Store::Status::Open, "app.example.com", "7.5"),
  issue(2, "SQL injection in login", Gori::Store::Severity::Critical, Gori::Store::Status::Confirmed, "api.example.com",
    "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"),
  issue(3, "Verbose error page", Gori::Store::Severity::Low, Gori::Store::Status::Resolved, "app.example.com", nil),
  issue(4, "Missing security header", Gori::Store::Severity::Info, Gori::Store::Status::FalsePositive, "cdn.example.net",
    "CVSS:9.9/AV:N"),
  issue(5, "Open redirect", Gori::Store::Severity::Medium, Gori::Store::Status::Open, nil, "3.1"),
]

private PROBES = [
  probe(1, "missing_csp", "headers", "app.example.com", "Missing CSP", Gori::Store::Severity::Low, Gori::Store::Status::Open),
  probe(2, "reflected_param", "injection", "api.example.com", "Reflected parameter", Gori::Store::Severity::High,
    Gori::Store::Status::Confirmed),
  probe(3, "tech_nginx", "tech-stack", "cdn.example.net", "Nginx detected", Gori::Store::Severity::Info,
    Gori::Store::Status::Resolved),
  probe(4, "cookie_no_secure", "cookies", "app.example.com", "Cookie without Secure", Gori::Store::Severity::Medium,
    Gori::Store::Status::FalsePositive),
  probe(5, "sqli_error", "injection", "API.Example.com", "SQL error message", Gori::Store::Severity::Critical,
    Gori::Store::Status::Open),
]

private QUERIES = [
  "", "   ", "open", "status:open", "st:conf", "STATUS:fp", "status:done", "status:closed", "status:zzz",
  "status:=open", "-status:resolved",
  "sev:high", "SEV:HIGH", "severity:>=high", "sev:>medium", "sev:<=low", "sev:<medium", "sev:=high", "sev:med",
  "sev:crit", "sev:bogus", "sev:>=bogus", "sev:>", "sev:>=", "-sev:>=", "-severity:high",
  "status:", "-status:", "host:", "-host:", "title:", "-title:", "cvss:", "-cvss:", "category:", "-category:",
  "code:", "-code:", "cat:",
  "host:api", "host:>api", "-host:app", "HOST:API",
  "title:sql", "title:\"sql injection\"", "title~admin",
  "cvss:>=7.0", "cvss:<4.0", "cvss:>3.1", "cvss:>=high", "cvss:3.1", "cvss:7.5", "cvss:av:n", "-cvss:>=7.0",
  "category:inj", "cat:TECH", "-category:tech", "code:csp", "code:CSP", "-code:csp",
  "sevrity:high", "catgory:inj", ":foo", "foo:", "reflected", "-reflected", "nginx",
  "status:open OR status:confirmed", "host:api OR host:cdn", "(host:api OR host:cdn) -sev:info",
  "NOT (severity:info OR severity:low)", "-(sev:high OR sev:crit)", "sql AND sev:crit", "sql or crit",
  "(sev:high", "OR", "NOT",
]

private SUGGEST_QUERIES = [
  {"", 0}, {" ", 1}, {"s", 1}, {"-sev", 4}, {"(cat", 4}, {"sev:", 4}, {"sev:>", 5}, {"sev:h", 5},
  {"status:", 7}, {"st:c", 4}, {"host:", 5}, {"host:a", 6}, {"-host:MY", 9}, {"host:\"my", 8}, {"title:", 6},
  {"cvss:", 5}, {"category:", 9}, {"cat:in", 6}, {"code:", 5}, {"code:r", 6}, {":x", 2}, {"zz", 2}, {"c", 1},
  {"h", 1}, {"sev:high st", 11}, {"sev:high host:a", 3}, {"title:x co", 2},
]

private NAMES = %w[severity sev SEV st status host title cvss category cat code sevrity stauts catgory titl cod hots
  cvs foo req.host acme.test] + [""]

private HOSTS = ["api.example.com", "My Host"]
private CODES = ["missing_csp", "Reflected Param"]

private def ids(list) : String
  list.map(&.id).inspect
end

private def report : String
  String.build do |io|
    QUERIES.each do |q|
      fi = Gori::Issues::Filter.parse(q)
      fp = Gori::Probe::Filter.parse(q)
      io << q.inspect << " issues=" << ids(fi.apply(ISSUES)) << " probe=" << ids(fp.apply(PROBES))
      io << " rows=" << ids(fp.apply(PROBES.map { |p| row(p) }))
      io << " empty=" << fi.empty? << "/" << fp.empty? << " status_term=" << fp.has_status_term? << "\n"
    end
    SUGGEST_QUERIES.each do |(q, cx)|
      io << "suggest " << q.inspect << "@" << cx
      io << " issues=" << Gori::Issues::Filter.suggestions(q, cx, HOSTS).inspect
      io << " probe=" << Gori::Probe::Filter.suggestions(q, cx, HOSTS, CODES).inspect << "\n"
    end
    io << "suggest default pools issues=" << Gori::Issues::Filter.suggestions("host:", 5).inspect
    io << " probe=" << Gori::Probe::Filter.suggestions("code:", 5).inspect << "\n"
    {% for k in [Gori::Issues::Filter, Gori::Probe::Filter] %}
      NAMES.each do |n|
        io << {{ k.stringify }} << " " << n.inspect << " known=" << {{ k }}.known_field?(n) << "/" << {{ k }}.known_field?(n, regex: true)
        io << " suggest=" << {{ k }}.suggest_field(n).inspect << " help=" << {{ k }}.field_help(n).inspect
        io << " proc=" << ({{ k }}::FIELD_HELP_PROC.call(n) == {{ k }}.field_help(n))
        io << " shaped=" << {{ k }}::FIELD_SHAPED.call(n, ':', "x") << "/" << {{ k }}::FIELD_SHAPED.call(n, ':', "//e") << "\n"
      end
      io << {{ k.stringify }} << " FIELDS=" << {{ k }}::FIELDS.inspect << "\n"
      io << {{ k.stringify }} << " KNOWN=" << {{ k }}::KNOWN.to_a.inspect << "\n"
      io << {{ k.stringify }} << " CANDIDATE_FIELDS=" << {{ k }}::CANDIDATE_FIELDS.inspect << "\n"
      io << {{ k.stringify }} << " CANONICAL=" << {{ k }}::CANONICAL.inspect << "\n"
      io << {{ k.stringify }} << " HINT_FIELDS=" << {{ k }}::HINT_FIELDS.inspect << "\n"
      io << {{ k.stringify }} << " ALSO_ACCEPTED=" << {{ k }}::ALSO_ACCEPTED.inspect << "\n"
      io << {{ k.stringify }} << " SEVERITY_VALUES=" << {{ k }}::SEVERITY_VALUES.inspect << "\n"
      io << {{ k.stringify }} << " STATUS_VALUES=" << {{ k }}::STATUS_VALUES.inspect << "\n"
      io << {{ k.stringify }} << " SEVERITY_SAMPLES=" << {{ k }}::SEVERITY_SAMPLES.inspect << "\n"
    {% end %}
    io << "CVSS_SAMPLES=" << Gori::Issues::Filter::CVSS_SAMPLES.inspect << "\n"
  end
end

describe "Issues::Filter and Probe::Filter" do
  it "answer every query, completion and name exactly as pinned" do
    report.chomp.should eq(EXPECTED)
  end
end

private EXPECTED = <<-TXT
  "" issues=[1, 2, 3, 4, 5] probe=[1, 2, 3, 4, 5] rows=[1, 2, 3, 4, 5] empty=true/true status_term=false
  "   " issues=[1, 2, 3, 4, 5] probe=[1, 2, 3, 4, 5] rows=[1, 2, 3, 4, 5] empty=true/true status_term=false
  "open" issues=[5] probe=[] rows=[] empty=false/false status_term=false
  "status:open" issues=[1, 5] probe=[1, 5] rows=[1, 5] empty=false/false status_term=true
  "st:conf" issues=[2] probe=[2] rows=[2] empty=false/false status_term=true
  "STATUS:fp" issues=[4] probe=[4] rows=[4] empty=false/false status_term=true
  "status:done" issues=[3] probe=[3] rows=[3] empty=false/false status_term=true
  "status:closed" issues=[2, 3, 4] probe=[2, 3, 4] rows=[2, 3, 4] empty=false/false status_term=true
  "status:zzz" issues=[] probe=[] rows=[] empty=false/false status_term=true
  "status:=open" issues=[] probe=[] rows=[] empty=false/false status_term=true
  "-status:resolved" issues=[1, 2, 4, 5] probe=[1, 2, 4, 5] rows=[1, 2, 4, 5] empty=false/false status_term=true
  "sev:high" issues=[1] probe=[2] rows=[2] empty=false/false status_term=false
  "SEV:HIGH" issues=[1] probe=[2] rows=[2] empty=false/false status_term=false
  "severity:>=high" issues=[1, 2] probe=[2, 5] rows=[2, 5] empty=false/false status_term=false
  "sev:>medium" issues=[1, 2] probe=[2, 5] rows=[2, 5] empty=false/false status_term=false
  "sev:<=low" issues=[3, 4] probe=[1, 3] rows=[1, 3] empty=false/false status_term=false
  "sev:<medium" issues=[3, 4] probe=[1, 3] rows=[1, 3] empty=false/false status_term=false
  "sev:=high" issues=[1] probe=[2] rows=[2] empty=false/false status_term=false
  "sev:med" issues=[5] probe=[4] rows=[4] empty=false/false status_term=false
  "sev:crit" issues=[2] probe=[5] rows=[5] empty=false/false status_term=false
  "sev:bogus" issues=[] probe=[] rows=[] empty=false/false status_term=false
  "sev:>=bogus" issues=[] probe=[] rows=[] empty=false/false status_term=false
  "sev:>" issues=[1, 2, 3, 4, 5] probe=[1, 2, 3, 4, 5] rows=[1, 2, 3, 4, 5] empty=false/false status_term=false
  "sev:>=" issues=[1, 2, 3, 4, 5] probe=[1, 2, 3, 4, 5] rows=[1, 2, 3, 4, 5] empty=false/false status_term=false
  "-sev:>=" issues=[] probe=[1, 2, 3, 4, 5] rows=[1, 2, 3, 4, 5] empty=false/false status_term=false
  "-severity:high" issues=[2, 3, 4, 5] probe=[1, 3, 4, 5] rows=[1, 3, 4, 5] empty=false/false status_term=false
  "status:" issues=[1, 2, 3, 4, 5] probe=[1, 2, 3, 4, 5] rows=[1, 2, 3, 4, 5] empty=false/false status_term=true
  "-status:" issues=[] probe=[1, 2, 3, 4, 5] rows=[1, 2, 3, 4, 5] empty=false/false status_term=true
  "host:" issues=[1, 2, 3, 4, 5] probe=[1, 2, 3, 4, 5] rows=[1, 2, 3, 4, 5] empty=false/false status_term=false
  "-host:" issues=[] probe=[1, 2, 3, 4, 5] rows=[1, 2, 3, 4, 5] empty=false/false status_term=false
  "title:" issues=[1, 2, 3, 4, 5] probe=[] rows=[] empty=false/false status_term=false
  "-title:" issues=[] probe=[1, 2, 3, 4, 5] rows=[1, 2, 3, 4, 5] empty=false/false status_term=false
  "cvss:" issues=[1, 2, 3, 4, 5] probe=[] rows=[] empty=false/false status_term=false
  "-cvss:" issues=[] probe=[1, 2, 3, 4, 5] rows=[1, 2, 3, 4, 5] empty=false/false status_term=false
  "category:" issues=[] probe=[1, 2, 3, 4, 5] rows=[1, 2, 3, 4, 5] empty=false/false status_term=false
  "-category:" issues=[1, 2, 3, 4, 5] probe=[1, 2, 3, 4, 5] rows=[1, 2, 3, 4, 5] empty=false/false status_term=false
  "code:" issues=[] probe=[1, 2, 3, 4, 5] rows=[1, 2, 3, 4, 5] empty=false/false status_term=false
  "-code:" issues=[1, 2, 3, 4, 5] probe=[1, 2, 3, 4, 5] rows=[1, 2, 3, 4, 5] empty=false/false status_term=false
  "cat:" issues=[] probe=[1, 2, 3, 4, 5] rows=[1, 2, 3, 4, 5] empty=false/false status_term=false
  "host:api" issues=[2] probe=[2, 5] rows=[2, 5] empty=false/false status_term=false
  "host:>api" issues=[] probe=[] rows=[] empty=false/false status_term=false
  "-host:app" issues=[2, 4, 5] probe=[2, 3, 5] rows=[2, 3, 5] empty=false/false status_term=false
  "HOST:API" issues=[2] probe=[2, 5] rows=[2, 5] empty=false/false status_term=false
  "title:sql" issues=[2] probe=[] rows=[] empty=false/false status_term=false
  "title:\\"sql injection\\"" issues=[2] probe=[] rows=[] empty=false/false status_term=false
  "title~admin" issues=[] probe=[] rows=[] empty=false/false status_term=false
  "cvss:>=7.0" issues=[1, 2] probe=[] rows=[] empty=false/false status_term=false
  "cvss:<4.0" issues=[5] probe=[] rows=[] empty=false/false status_term=false
  "cvss:>3.1" issues=[1, 2] probe=[] rows=[] empty=false/false status_term=false
  "cvss:>=high" issues=[] probe=[] rows=[] empty=false/false status_term=false
  "cvss:3.1" issues=[2, 5] probe=[] rows=[] empty=false/false status_term=false
  "cvss:7.5" issues=[1] probe=[] rows=[] empty=false/false status_term=false
  "cvss:av:n" issues=[2, 4] probe=[] rows=[] empty=false/false status_term=false
  "-cvss:>=7.0" issues=[3, 4, 5] probe=[1, 2, 3, 4, 5] rows=[1, 2, 3, 4, 5] empty=false/false status_term=false
  "category:inj" issues=[] probe=[2, 5] rows=[2, 5] empty=false/false status_term=false
  "cat:TECH" issues=[] probe=[3] rows=[3] empty=false/false status_term=false
  "-category:tech" issues=[1, 2, 3, 4, 5] probe=[1, 2, 4, 5] rows=[1, 2, 4, 5] empty=false/false status_term=false
  "code:csp" issues=[] probe=[1] rows=[1] empty=false/false status_term=false
  "code:CSP" issues=[] probe=[1] rows=[1] empty=false/false status_term=false
  "-code:csp" issues=[1, 2, 3, 4, 5] probe=[2, 3, 4, 5] rows=[2, 3, 4, 5] empty=false/false status_term=false
  "sevrity:high" issues=[] probe=[] rows=[] empty=false/false status_term=false
  "catgory:inj" issues=[] probe=[] rows=[] empty=false/false status_term=false
  ":foo" issues=[] probe=[] rows=[] empty=false/false status_term=false
  "foo:" issues=[] probe=[] rows=[] empty=false/false status_term=false
  "reflected" issues=[1] probe=[2] rows=[2] empty=false/false status_term=false
  "-reflected" issues=[2, 3, 4, 5] probe=[1, 3, 4, 5] rows=[1, 3, 4, 5] empty=false/false status_term=false
  "nginx" issues=[] probe=[3] rows=[3] empty=false/false status_term=false
  "status:open OR status:confirmed" issues=[1, 2, 5] probe=[1, 2, 5] rows=[1, 2, 5] empty=false/false status_term=true
  "host:api OR host:cdn" issues=[2, 4] probe=[2, 3, 5] rows=[2, 3, 5] empty=false/false status_term=false
  "(host:api OR host:cdn) -sev:info" issues=[2] probe=[2, 5] rows=[2, 5] empty=false/false status_term=false
  "NOT (severity:info OR severity:low)" issues=[1, 2, 5] probe=[2, 4, 5] rows=[2, 4, 5] empty=false/false status_term=false
  "-(sev:high OR sev:crit)" issues=[3, 4, 5] probe=[1, 3, 4] rows=[1, 3, 4] empty=false/false status_term=false
  "sql AND sev:crit" issues=[2] probe=[5] rows=[5] empty=false/false status_term=false
  "sql or crit" issues=[] probe=[] rows=[] empty=false/false status_term=false
  "(sev:high" issues=[1] probe=[2] rows=[2] empty=false/false status_term=false
  "OR" issues=[1, 2, 3, 4, 5] probe=[1, 2, 3, 4, 5] rows=[1, 2, 3, 4, 5] empty=true/true status_term=false
  "NOT" issues=[1, 2, 3, 4, 5] probe=[1, 2, 3, 4, 5] rows=[1, 2, 3, 4, 5] empty=true/true status_term=false
  suggest ""@0 issues=[] probe=[]
  suggest " "@1 issues=[] probe=[]
  suggest "s"@1 issues=["severity:", "status:"] probe=["severity:", "status:"]
  suggest "-sev"@4 issues=["-severity:"] probe=["-severity:"]
  suggest "(cat"@4 issues=[] probe=["(category:"]
  suggest "sev:"@4 issues=["sev:info", "sev:low", "sev:medium", "sev:high", "sev:critical", "sev:>=medium", "sev:>=high", "sev:>=critical"] probe=["sev:info", "sev:low", "sev:medium", "sev:high", "sev:critical", "sev:>=medium", "sev:>=high", "sev:>=critical"]
  suggest "sev:>"@5 issues=["sev:>=medium", "sev:>=high", "sev:>=critical"] probe=["sev:>=medium", "sev:>=high", "sev:>=critical"]
  suggest "sev:h"@5 issues=["sev:high"] probe=["sev:high"]
  suggest "status:"@7 issues=["status:open", "status:confirmed", "status:false-positive", "status:resolved", "status:closed"] probe=["status:open", "status:confirmed", "status:false-positive", "status:resolved", "status:closed"]
  suggest "st:c"@4 issues=["st:confirmed", "st:closed"] probe=["st:confirmed", "st:closed"]
  suggest "host:"@5 issues=["host:api.example.com", "host:\\"My Host\\""] probe=["host:api.example.com", "host:\\"My Host\\""]
  suggest "host:a"@6 issues=["host:api.example.com"] probe=["host:api.example.com"]
  suggest "-host:MY"@9 issues=["-host:\\"My Host\\""] probe=["-host:\\"My Host\\""]
  suggest "host:\\"my"@8 issues=["host:\\"My Host\\""] probe=["host:\\"My Host\\""]
  suggest "title:"@6 issues=[] probe=[]
  suggest "cvss:"@5 issues=["cvss:>=4.0", "cvss:>=7.0", "cvss:>=9.0"] probe=[]
  suggest "category:"@9 issues=[] probe=["category:headers", "category:cookies", "category:tech", "category:infoleak", "category:cors", "category:client", "category:active", "category:custom"]
  suggest "cat:in"@6 issues=[] probe=["cat:infoleak"]
  suggest "code:"@5 issues=[] probe=["code:missing_csp", "code:\\"Reflected Param\\""]
  suggest "code:r"@6 issues=[] probe=["code:\\"Reflected Param\\""]
  suggest ":x"@2 issues=[] probe=[]
  suggest "zz"@2 issues=[] probe=[]
  suggest "c"@1 issues=["cvss:"] probe=["category:", "code:"]
  suggest "h"@1 issues=["host:"] probe=["host:"]
  suggest "sev:high st"@11 issues=["status:"] probe=["status:"]
  suggest "sev:high host:a"@3 issues=["sev:high"] probe=["sev:high"]
  suggest "title:x co"@2 issues=[] probe=[]
  suggest default pools issues=[] probe=[]
  Gori::Issues::Filter "severity" known=true/false suggest=nil help="info low medium high critical — takes >= <= > <" proc=true shaped=true/true
  Gori::Issues::Filter "sev" known=true/false suggest=nil help="info low medium high critical — takes >= <= > <" proc=true shaped=true/true
  Gori::Issues::Filter "SEV" known=true/false suggest=nil help="info low medium high critical — takes >= <= > <" proc=true shaped=true/true
  Gori::Issues::Filter "st" known=true/false suggest=nil help="triage state — open confirmed fp resolved (closed = any non-open)" proc=true shaped=true/true
  Gori::Issues::Filter "status" known=true/false suggest=nil help="triage state — open confirmed fp resolved (closed = any non-open)" proc=true shaped=true/true
  Gori::Issues::Filter "host" known=true/false suggest=nil help="the issue's host — substring" proc=true shaped=true/true
  Gori::Issues::Filter "title" known=true/false suggest=nil help="the issue's title — substring" proc=true shaped=true/true
  Gori::Issues::Filter "cvss" known=true/false suggest=nil help="score, with >= <= > < — or a substring of the vector" proc=true shaped=true/true
  Gori::Issues::Filter "category" known=false/false suggest=nil help=nil proc=true shaped=true/false
  Gori::Issues::Filter "cat" known=false/false suggest=nil help=nil proc=true shaped=true/false
  Gori::Issues::Filter "code" known=false/false suggest=nil help=nil proc=true shaped=true/false
  Gori::Issues::Filter "sevrity" known=false/false suggest="severity" help=nil proc=true shaped=true/false
  Gori::Issues::Filter "stauts" known=false/false suggest="status" help=nil proc=true shaped=true/false
  Gori::Issues::Filter "catgory" known=false/false suggest=nil help=nil proc=true shaped=true/false
  Gori::Issues::Filter "titl" known=false/false suggest="title" help=nil proc=true shaped=true/false
  Gori::Issues::Filter "cod" known=false/false suggest=nil help=nil proc=true shaped=true/false
  Gori::Issues::Filter "hots" known=false/false suggest="host" help=nil proc=true shaped=true/false
  Gori::Issues::Filter "cvs" known=false/false suggest="cvss" help=nil proc=true shaped=true/false
  Gori::Issues::Filter "foo" known=false/false suggest=nil help=nil proc=true shaped=true/false
  Gori::Issues::Filter "req.host" known=false/false suggest=nil help=nil proc=true shaped=false/false
  Gori::Issues::Filter "acme.test" known=false/false suggest=nil help=nil proc=true shaped=false/false
  Gori::Issues::Filter "" known=false/false suggest=nil help=nil proc=true shaped=false/false
  Gori::Issues::Filter FIELDS=["severity:", "status:", "host:", "title:", "cvss:"]
  Gori::Issues::Filter KNOWN=["severity", "sev", "status", "st", "host", "title", "cvss"]
  Gori::Issues::Filter CANDIDATE_FIELDS=["severity", "sev", "status", "st", "host", "title", "cvss"]
  Gori::Issues::Filter CANONICAL={"severity" => "severity", "sev" => "severity", "status" => "status", "st" => "status", "host" => "host", "title" => "title", "cvss" => "cvss"}
  Gori::Issues::Filter HINT_FIELDS=["severity", "status", "host", "title", "cvss"]
  Gori::Issues::Filter ALSO_ACCEPTED={"sev" => "severity", "st" => "status"}
  Gori::Issues::Filter SEVERITY_VALUES=["info", "low", "medium", "high", "critical"]
  Gori::Issues::Filter STATUS_VALUES=["open", "confirmed", "false-positive", "resolved", "closed"]
  Gori::Issues::Filter SEVERITY_SAMPLES=[">=medium", ">=high", ">=critical"]
  Gori::Probe::Filter "severity" known=true/false suggest=nil help="info low medium high critical — takes >= <= > <" proc=true shaped=true/true
  Gori::Probe::Filter "sev" known=true/false suggest=nil help="info low medium high critical — takes >= <= > <" proc=true shaped=true/true
  Gori::Probe::Filter "SEV" known=true/false suggest=nil help="info low medium high critical — takes >= <= > <" proc=true shaped=true/true
  Gori::Probe::Filter "st" known=true/false suggest=nil help="triage state — open confirmed fp resolved (closed = any non-open)" proc=true shaped=true/true
  Gori::Probe::Filter "status" known=true/false suggest=nil help="triage state — open confirmed fp resolved (closed = any non-open)" proc=true shaped=true/true
  Gori::Probe::Filter "host" known=true/false suggest=nil help="the finding's host — substring" proc=true shaped=true/true
  Gori::Probe::Filter "title" known=false/false suggest=nil help=nil proc=true shaped=true/false
  Gori::Probe::Filter "cvss" known=false/false suggest=nil help=nil proc=true shaped=true/false
  Gori::Probe::Filter "category" known=true/false suggest=nil help="which check found it — headers cookies tech infoleak cors client active custom" proc=true shaped=true/true
  Gori::Probe::Filter "cat" known=true/false suggest=nil help="which check found it — headers cookies tech infoleak cors client active custom" proc=true shaped=true/true
  Gori::Probe::Filter "code" known=true/false suggest=nil help="the rule's code — substring" proc=true shaped=true/true
  Gori::Probe::Filter "sevrity" known=false/false suggest="severity" help=nil proc=true shaped=true/false
  Gori::Probe::Filter "stauts" known=false/false suggest="status" help=nil proc=true shaped=true/false
  Gori::Probe::Filter "catgory" known=false/false suggest="category" help=nil proc=true shaped=true/false
  Gori::Probe::Filter "titl" known=false/false suggest=nil help=nil proc=true shaped=true/false
  Gori::Probe::Filter "cod" known=false/false suggest="code" help=nil proc=true shaped=true/false
  Gori::Probe::Filter "hots" known=false/false suggest="host" help=nil proc=true shaped=true/false
  Gori::Probe::Filter "cvs" known=false/false suggest=nil help=nil proc=true shaped=true/false
  Gori::Probe::Filter "foo" known=false/false suggest=nil help=nil proc=true shaped=true/false
  Gori::Probe::Filter "req.host" known=false/false suggest=nil help=nil proc=true shaped=false/false
  Gori::Probe::Filter "acme.test" known=false/false suggest=nil help=nil proc=true shaped=false/false
  Gori::Probe::Filter "" known=false/false suggest=nil help=nil proc=true shaped=false/false
  Gori::Probe::Filter FIELDS=["severity:", "status:", "category:", "host:", "code:"]
  Gori::Probe::Filter KNOWN=["severity", "sev", "status", "st", "category", "cat", "host", "code"]
  Gori::Probe::Filter CANDIDATE_FIELDS=["severity", "sev", "status", "st", "category", "cat", "host", "code"]
  Gori::Probe::Filter CANONICAL={"severity" => "severity", "sev" => "severity", "status" => "status", "st" => "status", "category" => "category", "cat" => "category", "host" => "host", "code" => "code"}
  Gori::Probe::Filter HINT_FIELDS=["severity", "status", "category", "host", "code"]
  Gori::Probe::Filter ALSO_ACCEPTED={"sev" => "severity", "st" => "status", "cat" => "category"}
  Gori::Probe::Filter SEVERITY_VALUES=["info", "low", "medium", "high", "critical"]
  Gori::Probe::Filter STATUS_VALUES=["open", "confirmed", "false-positive", "resolved", "closed"]
  Gori::Probe::Filter SEVERITY_SAMPLES=[">=medium", ">=high", ">=critical"]
  CVSS_SAMPLES=[">=4.0", ">=7.0", ">=9.0"]
  TXT
