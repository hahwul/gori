require "../../spec_helper"

module Gori::CLI::Run
  # `repeater send`'s plan for session `rec` as `cmd_repeater_send` builds it.
  def self.repeater_send_plan_for_spec(store : Store, rec : Store::RepeaterRecord, headers : Array(String)) : Repeater::Plan
    req, pinned, evidence = session_send_request(store, rec, nil, headers, [] of String, false).as({Bytes?, Bool, Bool})
    Repeater::Plan.build(session_plan_options(rec, true, nil, request: req.not_nil!, pinned_cl: pinned,
      evidence: evidence, evidence_literals: seed_send_literals(rec, evidence)), ungated_outbound)
  end

  def self.build_single_flow_request_for_spec(head : Bytes, body : Bytes, headers : Array(String),
                                              body_override : String?, target_override : String?,
                                              removed : Array(String) = [] of String) : {Bytes, Bool}
    build_single_flow_request(head, body, headers, body_override, target_override, removed)
  end
end

# `gori run repeater <flow-id>` header editing: `-H` and `--rm-header`.
#
# The two shapes pinned here are ones an operator testing a target's header handling has to
# be able to produce, and neither was expressible before:
#
#   * TWO header lines with the SAME name. A second `-H "X: b"` used to overwrite the first
#     in a `Hash(String, String)`, so `-H` could emit at most one line per name — and how a
#     target resolves duplicate `Host`/`Content-Length`/`Cookie` lines is exactly the thing
#     under test. Repeating the flag now appends; a single flag still replaces.
#   * DELETING a header. There was no syntax at all (`-H "X"` with no colon was a silent
#     no-op), and `-H "X:"` means something different and equally wanted — send `X` with an
#     EMPTY value. So deletion needs its own flag rather than an overload.
#
# Deleting `Content-Length` or `Host` also has to switch OFF the machinery that would put it
# straight back (the body auto-resync, the `--target` Host sync) — otherwise the flag reads
# as doing nothing.
#
# The builder is driven directly (through the `*_for_spec` shim defined alongside the fix-#15
# examples in spec/repeater/repeater_bugfixes_spec.cr) rather than through a subprocess, so
# these assert the exact wire bytes — which is what the guarantee is about.
private HEAD = "POST /t HTTP/1.1\r\nHost: h\r\nX-Dup: one\r\nX-Dup: two\r\nContent-Length: 5\r\n\r\n"

private def build(headers : Array(String), removed = [] of String,
                  body_override : String? = nil, target : String? = nil) : String
  wire, _ = Gori::CLI::Run.build_single_flow_request_for_spec(
    HEAD.to_slice, "hello".to_slice, headers, body_override, target, removed)
  String.new(wire)
end

describe "gori run repeater — -H / --rm-header" do
  it "replaces every duplicate of a name with ONE line for a single -H" do
    # Unchanged behaviour, pinned: the h2 case (repeated cookie: lines) must not be left
    # half-overridden, so later duplicates are dropped, not kept.
    out = build(["X-Dup: three"])
    out.scan(/X-Dup: /).size.should eq(1)
    out.should contain("X-Dup: three\r\n")
    out.should_not contain("X-Dup: one")
  end

  it "emits ONE line per repeated -H of the same name, in flag order" do
    out = build(["X-Dup: three", "X-Dup: four"])
    out.should contain("X-Dup: three\r\nX-Dup: four\r\n")
    out.should_not contain("X-Dup: one")
    out.should_not contain("X-Dup: two")
  end

  it "appends duplicates for a name the captured head does not carry" do
    out = build(["X-New: a", "X-New: b"])
    out.should contain("X-New: a\r\n")
    out.should contain("X-New: b\r\n")
  end

  it "still distinguishes an EMPTY value from a deletion" do
    # `-H "X-Dup:"` is now emitted with the operator's exact spelling — colon, nothing after
    # it — instead of gori inserting a space it was never given. See the OWS example below.
    build(["X-Dup:"]).should contain("X-Dup:\r\n")
    build([] of String, ["X-Dup"]).should_not contain("X-Dup")
  end

  it "--rm-header deletes EVERY line with that name, case-insensitively" do
    out = build([] of String, ["x-DUP"])
    out.should_not contain("X-Dup")
    out.should contain("Host: h\r\n") # neighbours untouched
    out.should end_with("\r\n\r\nhello")
  end

  it "--rm-header Content-Length suppresses the auto-resync that would restore it" do
    # A body with no Content-Length and no Transfer-Encoding is a real framing test; the
    # resync must read the deletion as an intentional pin, exactly like an explicit -H CL.
    out = build([] of String, ["Content-Length"])
    out.should_not contain("Content-Length")
    out.should end_with("\r\n\r\nhello")
  end

  it "--rm-header Host suppresses the --target Host sync" do
    out = build([] of String, ["Host"], target: "http://other.example:8080")
    out.should_not contain("Host:")
  end

  it "leaves --target's Host sync alone when Host was not removed" do
    out = build([] of String, [] of String, target: "http://other.example:8080")
    out.should contain("Host: other.example:8080\r\n")
  end

  it "ignores an empty / whitespace-only --rm-header name" do
    out = build([] of String, ["", "   "])
    out.should contain("X-Dup: one\r\nX-Dup: two\r\n")
  end
end

# `--header`'s own help advertises an explicit Content-Length as honored verbatim for
# CL-mismatch testing — but `Content-Length:\t5`, `Content-Length: 5 ` and `Content-Length:5`
# are the OWS-obfuscation half of that same probe class (RFC 9112 §5.1), and stripping the
# whitespace and re-inserting exactly one space after the colon made all three unreachable
# from this flag. Only the dedup/override KEY is folded, so a captured header is still found
# and replaced regardless of how either side spelled it.
describe "gori run repeater — -H keeps the operator's spelling" do
  it "keeps surrounding OWS in the value, and the absence of it" do
    out = build(["Content-Length:  0011  ", "X-NoSpace:tight"])
    out.should contain("Content-Length:  0011  \r\n")
    out.should contain("X-NoSpace:tight\r\n")
  end

  it "keeps a TAB after the colon" do
    build(["X-Tab:\tv"]).should contain("X-Tab:\tv\r\n")
  end

  it "keeps the operator's NAME casing when it replaces a differently-cased captured line" do
    out = build(["content-length: 7"])
    out.should contain("content-length: 7\r\n")
    out.should_not contain("Content-Length: 5")
  end

  it "still keys the override on the folded name, so the captured line is replaced not doubled" do
    out = build(["  CoNtEnT-lEnGtH  : 7"])
    out.scan(/[Cc]ontent-[Ll]ength/i).size.should eq(1)
    out.should contain("  CoNtEnT-lEnGtH  : 7\r\n")
  end
end

# A captured head may be terminated with bare LFs (a front-end/back-end desync primitive the
# store keeps byte-exact) or MIXED. Re-emitting everything as CRLF quietly promoted the probe
# into an ordinary conformant request on a path whose whole point is faithfulness.
private LF_HEAD = "POST /lf HTTP/1.1\nHost: h\nContent-Length: 5\n\n"

describe "gori run repeater — head terminators survive an edit" do
  it "hands back the stored bytes untouched when no flag edits the message" do
    wire, explicit = Gori::CLI::Run.build_single_flow_request_for_spec(
      LF_HEAD.to_slice, "hello".to_slice, [] of String, nil, nil, [] of String)
    String.new(wire).should eq(LF_HEAD + "hello")
    explicit.should be_false
  end

  it "keeps every surviving line's own terminator when a flag DOES edit the message" do
    wire, _ = Gori::CLI::Run.build_single_flow_request_for_spec(
      LF_HEAD.to_slice, "hello".to_slice, ["X-New: 1"], nil, nil, [] of String)
    out = String.new(wire)
    out.should start_with("POST /lf HTTP/1.1\nHost: h\nContent-Length: 5\n")
    out.should contain("X-New: 1\n")
    out.should_not contain("\r\n")
    out.should end_with("\n\nhello")
  end

  # P7 again: a head with no terminating blank line, or none at all, is somebody's test case.
  # The rebuild would put a terminator on it that the capture never had.
  it "hands back a head with no terminator, and an EMPTY head, exactly as stored" do
    ["GET / HTTP/1.1", ""].each do |head|
      wire, _ = Gori::CLI::Run.build_single_flow_request_for_spec(
        head.to_slice, Bytes.empty, [] of String, nil, nil, [] of String)
      String.new(wire).should eq(head)
    end
  end

  # An unterminated last line used to swallow whatever an edit appended after it.
  it "terminates a line the head just ends on before an edit appends after it" do
    {"GET / HTTP/1.1\r\nHost: h" => "GET / HTTP/1.1\r\nHost: h\r\nX-Test: 1\r\n\r\n",
     "GET / HTTP/1.1"            => "GET / HTTP/1.1\r\nX-Test: 1\r\n\r\n",
     "GET / HTTP/1.1\nHost: h"   => "GET / HTTP/1.1\nHost: h\nX-Test: 1\n\n"}.each do |head, want|
      wire, _ = Gori::CLI::Run.build_single_flow_request_for_spec(
        head.to_slice, Bytes.empty, ["X-Test: 1"], nil, nil, [] of String)
      String.new(wire).should eq(want)
    end
  end

  it "keeps a MIXED head mixed" do
    head = "POST /m HTTP/1.1\r\nHost: h\nX-Old: a\r\n\r\n"
    wire, _ = Gori::CLI::Run.build_single_flow_request_for_spec(
      head.to_slice, Bytes.empty, ["X-Old: b"], nil, nil, [] of String)
    String.new(wire).should eq("POST /m HTTP/1.1\r\nHost: h\nX-Old: b\r\n\r\n")
  end
end

# The OPERATOR half of `PlanOptions#evidence?`.
#
# `Repeater::Plan` no longer expands anything on a flow replay, because it cannot tell the
# capture's bytes from the operator's once they are one merged wire — a project defining an
# ordinary name (`filter`, `top`, `where`) rewrote the STORED request and re-framed its
# Content-Length to match. So expansion moved to the merge itself, which is the last point
# where the two are still distinguishable. These pin that it really happens here, since the
# builder will not do it any more: without them the `-H`/`-b`/`--target` values would ship
# with their `$KEY` characters on the wire and the origin's 401 would look like a target
# verdict rather than an unexpanded variable (#519's failure, one seam over).
#
# The refusal for an UNRESOLVED token in the same three flags is `refuse_unresolved_overrides`
# and runs before this, so nothing that reaches `Env.expand` here can be left literal — except
# a DECLARED session binding, which `Env.expand` leaves for `Env.expand_bindings` at the send.
private def with_vars(pairs : Array({String, String}), &)
  saved = Gori::Settings.env_vars
  saved_p = Gori::Settings.project_env_vars
  saved_x = Gori::Settings.env_prefix
  Gori::Settings.env_vars = pairs
  Gori::Settings.project_env_vars = [] of {String, String}
  Gori::Settings.env_prefix = "$"
  yield
ensure
  Gori::Settings.env_vars = saved || [] of {String, String}
  Gori::Settings.project_env_vars = saved_p || [] of {String, String}
  Gori::Settings.env_prefix = saved_x || "$"
end

describe "gori run repeater — operator overrides expand at the merge seam" do
  it "expands a $KEY in a -H VALUE" do
    with_vars([{"TOK", "s3cr3t"}]) do
      build(["Authorization: Bearer $TOK"]).should contain("Authorization: Bearer s3cr3t")
    end
  end

  it "expands a $KEY in -b AND frames Content-Length over the EXPANDED body" do
    with_vars([{"TOK", "s3cr3t"}]) do
      out = build([] of String, body_override: "tok=$TOK")
      out.should end_with("tok=s3cr3t")
      # 10 bytes, not the 9 of the pre-expansion `tok=$TOK`: the resync that used to happen
      # in `Repeater::Plan` after a whole-wire expansion now has nothing left to correct.
      out.should contain("Content-Length: 10\r\n")
    end
  end

  it "expands a $KEY in --target before deriving the Host: header from it" do
    with_vars([{"HOSTV", "api.test:8443"}]) do
      build([] of String, target: "http://$HOSTV").should contain("Host: api.test:8443\r\n")
    end
  end

  # The complement of every case above: the CAPTURED bytes are next to the merged overrides
  # in the same wire, and none of this may touch them.
  it "leaves a colliding $KEY in the CAPTURED head and body untouched" do
    with_vars([{"Dup", "PWNED"}, {"TOK", "s3cr3t"}]) do
      head = "POST /t HTTP/1.1\r\nHost: h\r\nX-Dup: $Dup\r\nContent-Length: 8\r\n\r\n"
      wire, _ = Gori::CLI::Run.build_single_flow_request_for_spec(
        head.to_slice, "b=$Dup\r\n".to_slice, ["Authorization: Bearer $TOK"], nil, nil,
        [] of String)
      out = String.new(wire)
      out.should contain("X-Dup: $Dup\r\n")              # capture: literal
      out.should end_with("b=$Dup\r\n")                  # capture: literal
      out.should contain("Content-Length: 8\r\n")        # capture: not re-framed
      out.should contain("Authorization: Bearer s3cr3t") # override: expanded
      out.should_not contain("PWNED")
    end
  end

  # A `$` in a header NAME can only ever be a typo — `$` is not a tchar — and folding it into
  # the dedup key would make `-H '$H: a' -H 'X: b'` collide the moment `$H` resolved to `X`.
  it "does not expand a $KEY in a header NAME" do
    with_vars([{"H", "X-Dup"}]) do
      build(["$H: v"]).should contain("$H: v\r\n")
    end
  end
end

# `gori run repeater h2 --fields FILE` accepts two shapes, and the BARE ARRAY is the one the
# help text advertises first. Reading the optional body keys off `doc` unconditionally CRASHED
# on it — `JSON::Any#[]?(String)` raises on an array rather than returning nil — so the
# documented primary form was an unhandled exception while the object form worked.
module Gori::CLI::Run
  def self.parse_h2_fields_file_for_spec(text : String) : {Array({String, String}), Bytes?}
    parse_h2_fields_file(text)
  end
end

describe "gori run repeater h2 — --fields parsing" do
  it "accepts a bare [[name,value],…] array (no body)" do
    fields, body = Gori::CLI::Run.parse_h2_fields_file_for_spec(
      %([[":method","GET"],[":method","POST"],[":scheme","http"],["X-Up","  lead"]]))
    fields.should eq([{":method", "GET"}, {":method", "POST"}, {":scheme", "http"}, {"X-Up", "  lead"}])
    body.should be_nil
  end

  it "keeps duplicates, order, case and leading whitespace — the fields ARE the payload" do
    fields, _ = Gori::CLI::Run.parse_h2_fields_file_for_spec(
      %([["x-b","2"],[":path","/late-pseudo"],["X-MiXeD","  v  "]]))
    # A pseudo AFTER a regular field, an uppercase name, and a value with leading AND trailing
    # spaces: each is illegal h2 and each is a conformance probe. Nothing normalizes them.
    fields.should eq([{"x-b", "2"}, {":path", "/late-pseudo"}, {"X-MiXeD", "  v  "}])
  end

  it "accepts the object form with a plain body" do
    fields, body = Gori::CLI::Run.parse_h2_fields_file_for_spec(
      %({"fields":[[":method","POST"]],"body":"hi"}))
    fields.should eq([{":method", "POST"}])
    String.new(body.not_nil!).should eq("hi")
  end

  it "accepts the object form with body_base64, for bytes JSON cannot carry" do
    _, body = Gori::CLI::Run.parse_h2_fields_file_for_spec(
      %({"fields":[[":method","POST"]],"body_base64":"AAECgP8="}))
    body.not_nil!.to_a.should eq([0x00, 0x01, 0x02, 0x80, 0xFF])
  end
end

# #1670 review: `repeater send` on an untouched flow seed keeps it evidence and expands only the
# operator's own `-H` (`per_send_request(expand: true)`), the way a flow replay merges them. The
# captured tokens around them stay as captured; an unresolved `$ENV` the OPERATOR typed is refused.
describe "gori run repeater send -H on an evidence session" do
  it "expands the operator's -H value only, and refuses its unresolved $ENV token" do
    saved = Gori::Settings.env_vars
    Gori::Settings.env_vars = [{"TOKEN", "abc123"}]
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      wire = "GET / HTTP/1.1\r\nHost: h\r\nX-E: $ENV.TOKEN\r\nX-N: $ENV.NOPE\r\n\r\n".to_slice
      bytes, _ = Gori::CLI::Run.per_send_request(wire, ["Y: $ENV.TOKEN"], [] of String, expand: true).as({Bytes, Bool})
      sent = String.new(bytes)
      sent.should contain("Y: abc123\r\n")
      sent.should contain("X-E: $ENV.TOKEN\r\n")
      sent.should contain("X-N: $ENV.NOPE\r\n")
      expect_raises(Gori::Repeater::PlanError, /\$ENV\.NOPE/) do
        Gori::CLI::Run.per_send_request(wire, ["Y: $ENV.NOPE"], [] of String, expand: true)
      end
      # A draft leaves the whole merge to the plan, which expands (and checks) it all.
      draft, _ = Gori::CLI::Run.per_send_request(wire, ["Y: $ENV.TOKEN"], [] of String).as({Bytes, Bool})
      String.new(draft).should contain("Y: $ENV.TOKEN\r\n")
    end
  ensure
    Gori::Settings.env_vars = saved || [] of {String, String}
  end
end

# Round 2 of the #1670 review: the session stays evidence under the operator's `-H`, but only the
# capture's own names stay literal at the send seam; a `$GEN` the operator added still mints.
describe "gori run repeater send -H on an evidence session, end to end" do
  it "keeps the captured $ENV/$GEN literal and mints the operator's $GEN" do
    with_store_env do |store|
      saved = Gori::Settings.env_vars
      Gori::Settings.env_vars = [{"TOKEN", "abc123"}]
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        fid = store.insert_flow(Gori::Store::CapturedRequest.new(
          created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
          method: "GET", target: "/ev", http_version: "HTTP/1.1",
          head: "GET /ev HTTP/1.1\r\nHost: h.test\r\nX-E: $ENV.TOKEN\r\nX-G: $GEN.UUID\r\n\r\n".to_slice,
          body: nil, source: Gori::FlowSource::Kind::Import))
        seed = Gori::Repeater::FlowRequest.build(store.get_flow(fid).not_nil!).bytes
        id = store.insert_repeater("http://h.test", seed, false, true, fid, 0)
        rec = store.get_repeater(id).not_nil!
        wire = String.new(Gori::CLI::Run.repeater_send_plan_for_spec(store, rec, ["Z: $GEN.RANDOM_HEX", "Y: $ENV.TOKEN"]).wire_bytes)
        wire.should contain("X-E: $ENV.TOKEN\r\n")
        wire.should contain("X-G: $GEN.UUID\r\n")
        wire.should contain("Y: abc123\r\n")
        wire.should match(/\r\nZ: [0-9a-f]{32}\r\n/)
      end
    ensure
      Gori::Settings.env_vars = saved || [] of {String, String}
    end
  end
end

# A race or timing group rides one plan, so a seed beside a draft is refused (#1670), as the TUI
# race and MCP `race_requests` refuse it, worded for the command that sends it.
describe "gori run repeater race/timing — mixed provenance" do
  it "refuses a group mixing an untouched seed and a draft, unless --verbatim" do
    a = Gori::Store::RepeaterRecord.new(1_i64, "http://h.test", "GET /a HTTP/1.1\r\n\r\n".to_slice, false, true, 9_i64, 0)
    b = Gori::Store::RepeaterRecord.new(2_i64, "http://h.test", "GET /b HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)
    loaded = [{1_i64, a}, {2_i64, b}]
    race = Gori::CLI::Run.race_provenance_refusal(loaded, Set{1_i64}, false, "gori run repeater race").not_nil!
    race.should start_with("gori run repeater race: the sessions mix captured requests")
    race.should contain("a race needs one provenance")
    Gori::CLI::Run.race_provenance_refusal(loaded, Set{1_i64}, false, "gori run repeater timing").not_nil!
      .should contain("a timing run needs one provenance")
    Gori::CLI::Run.race_provenance_refusal(loaded, Set{1_i64}, true, "gori run repeater race").should be_nil
    Gori::CLI::Run.race_provenance_refusal(loaded, Set{1_i64, 2_i64}, false, "gori run repeater race").should be_nil
    Gori::CLI::Run.race_provenance_refusal(loaded, Set(Int64).new, false, "gori run repeater race").should be_nil
  end
end
