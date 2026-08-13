require "../spec_helper"

# A `Content-Type` is read straight off the wire (`Http1.parse_headers` builds header values
# with a bare `String.new`, and obs-text 0x80-0xFF is legal there), so a multipart boundary can
# carry a byte that is not valid UTF-8 — a Content-Type parser-differential payload, or just a
# client that picked its boundary out of a non-UTF-8 charset. PCRE RAISES on the first illegal
# byte instead of not matching, and the two probe call sites that reach `Graphql.from_body` are
# the only ones that hand it an unscrubbed value. The raise landed in `MediaType.boundary` and
# took out the whole flow's passive pass (Tech is RULES[0], and `scan_detail` swallows it), then
# the same shape came back through the TUI's "Run active scan" estimate, which had no rescue at
# all. Both are pinned here.

# `boundary=graphql\xFF`: multipart essence (so `from_body` takes the multipart branch) plus the
# `graphql` substring the Tech / GraphqlIntrospection byte gates open on.
private def hostile_ct : String
  "multipart/form-data; boundary=graphql" + String.new(Bytes[0xFF_u8])
end

private def with_store(&)
  path = File.tempname("gori-probe-ct", ".db")
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

# A captured POST whose request head carries `ct` verbatim, with a body (the GraphQL gates all
# require one). `target` stays off `/graphql` so the active rule's cheap path check cannot
# short-circuit the body branch that raised.
private def capture_ct_flow(store, ct : String, *, target = "/api", host = "acme.test") : Gori::Store::FlowDetail
  head = String.build do |io|
    io << "POST " << target << " HTTP/1.1\r\nHost: " << host << "\r\nContent-Type: " << ct << "\r\n\r\n"
  end
  req = Gori::Store::CapturedRequest.new(
    created_at: 1_000_i64, scheme: "https", host: host, port: 443,
    method: "POST", target: target, http_version: "HTTP/1.1",
    head: head.to_slice, body: %({"query":"{__schema{queryType{name}}}"}).to_slice)
  id = store.insert_flow(req)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nServer: nginx/1.18.0\r\n\r\n".to_slice,
    body: "<p>hi</p>".to_slice, reason: "OK", content_type: "text/html", duration_us: 1_i64))
  store.get_flow(id).not_nil!
end

# A rule whose gate blows up on every flow — the stand-in for "the next rule that raises", which
# is what the estimate loop had no answer for.
#
# Reopened inside `Active` rather than declared at the top of this file so each restriction can be
# spelled exactly as `Rule`'s abstract def spells it: Crystal matches an abstract def against its
# implementation by the restriction as WRITTEN, so the equivalent-but-fully-qualified
# `Gori::Store::FlowDetail` / `Gori::Probe::Active::Options` reads as a different signature and the
# subclass is rejected as not implementing it.
module Gori::Probe::Active
  # Not `private`: a private constant cannot be named through its full path from the describe
  # block below, which lives outside this module body.
  class SpecEstimateRaisingRule < Rule
    def info : RuleInfo
      RuleInfo.new("spec_raising_rule", "Spec raising rule",
        "Raises from its gate; exists only to pin the estimate's per-rule isolation.",
        Category::INFOLEAK)
    end

    def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
      raise ArgumentError.new("gate exploded")
    end

    def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
      nil
    end

    def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
      [] of Detection
    end
  end
end

describe "a Content-Type whose multipart boundary is not valid UTF-8" do
  it "still runs the whole passive pass (Tech is RULES[0], so its raise ate every later rule)" do
    with_store do |store|
      detail = capture_ct_flow(store, hostile_ct)
      codes = Gori::Probe::Passive.analyze(detail).map(&.code)
      codes.should_not be_empty
      # A rule that runs AFTER Tech: before the fix the flow was silently never scanned at all.
      codes.should contain("missing_hsts")
    end
  end

  it "lets the active GraphQL gate decide instead of raising" do
    with_store do |store|
      detail = capture_ct_flow(store, hostile_ct)
      Gori::Probe::Active::GraphqlIntrospection.new.dedup_key(detail).should be_nil
    end
  end

  it "keeps the Run-active-scan estimate alive" do
    with_store do |store|
      detail = capture_ct_flow(store, hostile_ct)
      a = Gori::Probe::Analyzer.new(store, Gori::Scope.load(store),
        Channel(Gori::Store::FlowEvent).new(1), Gori::Probe::Mode::Passive, true)
      a.active_estimate(detail).map(&.info.id).should_not contain("graphql_introspection")
    end
  end
end

# The estimate is called bare from the TUI's synchronous key path, where the run loop's
# catch-all ends the process on the third raise in ten seconds. An estimate is advisory, so a
# rule that cannot decide is omitted — the same isolation `Active.analyze` and `run_active_now`
# already have.
describe "Gori::Probe::Analyzer#active_estimate rule isolation" do
  it "omits a rule whose gate raises and keeps every other rule's estimate" do
    with_store do |store|
      detail = capture_ct_flow(store, "text/plain", target: "/search?q=hi")
      a = Gori::Probe::Analyzer.new(store, Gori::Scope.load(store),
        Channel(Gori::Store::FlowEvent).new(1), Gori::Probe::Mode::Passive, true)
      opts = Gori::Probe::Active::Options.new(allow_unsafe: true)
      baseline = a.active_estimate(detail, opts).map(&.info.id)
      baseline.should_not be_empty

      Gori::Probe::Active::RULES << Gori::Probe::Active::SpecEstimateRaisingRule.new
      begin
        a.active_estimate(detail, opts).map(&.info.id).should eq(baseline)
      ensure
        Gori::Probe::Active::RULES.pop
      end
    end
  end
end
