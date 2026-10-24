require "./spec_helper"

# `--verbatim` / `verbatim: true` means ONE thing on every surface that offers it: the
# operator's bytes go out untouched — no `$ENV`/`$BIND`/`$GEN` expansion (and no refusal of an
# unresolved one), no bare-LF-to-CRLF promotion, no Content-Length resync or insertion, no
# header-name case change, no client hints. The audit that produced these specs found the name
# meaning two different things (the Fuzzer's `--verbatim` once stopped only the Content-Length
# resync), so this file pins the three observable axes together: a drift on any surface, or a
# new surface that reads the flag more weakly, fails here.
#
# The CL-only subset has its OWN name — `--no-update-content-length` / `update_content_length:
# false` — and the one axis that tells them apart (a `$VAR` left literal vs expanded) is pinned
# too, so the two can never collapse back into one flag.

private UNRESOLVED = "GET /x?q=$ENV.NOT_SET HTTP/1.1\r\nHost: h.test\r\n\r\n"
private DISAGREE   = "POST /x HTTP/1.1\r\nHost: h.test\r\nContent-Length: 2\r\n\r\nhello"
private BARE_LF    = "GET /x HTTP/1.1\r\nHost: h.test\nX-A: 1\r\n\r\n"

# A Fuzzer template needs one real position, so a marker header goes in right after the request
# line (every entry has one), where the asserted substrings never reach.
private def with_marker(raw : String) : String
  raw.sub("HTTP/1.1\r\n", "HTTP/1.1\r\nX-Mark: §a§\r\n")
end

# What the Repeater's verbatim plan would put on the wire (its `Sender#wire`, no socket).
private def repeater_verbatim_wire(raw : String) : String
  plan = Gori::Repeater::Plan.build(
    Gori::Repeater::PlanOptions.new([raw.to_slice],
      expand_request: false, expand_bindings: false, auto_content_length: false,
      preserve_field_case: true, target: "http://h.test"),
    ungated_outbound)
  String.new(plan.wire_bytes)
end

# The Fuzzer's verbatim baseline (its `--verbatim` / `fuzz_start{verbatim}`), marker rendered.
private def fuzz_verbatim_baseline(raw : String) : String
  opts = Gori::Fuzz::PlanOptions.new(with_marker(raw), target: "http://h.test",
    sources: [Gori::Fuzz::InlineList.new(["v"]).as(Gori::Fuzz::PayloadSource)], verbatim: true)
  String.new(Gori::Fuzz::Plan.build(opts, ungated_outbound).generator.baseline_request)
end

# The Content-Length-only baseline: `--no-update-content-length`, everything else still applied.
private def fuzz_cl_only_baseline(raw : String) : String
  opts = Gori::Fuzz::PlanOptions.new(with_marker(raw), target: "http://h.test",
    sources: [Gori::Fuzz::InlineList.new(["v"]).as(Gori::Fuzz::PayloadSource)], verbatim: false)
  opts.config.update_content_length = false
  String.new(Gori::Fuzz::Plan.build(opts, ungated_outbound).generator.baseline_request)
end

describe "verbatim means the same on every surface" do
  it "leaves an unresolved $ENV literal and does not refuse the send" do
    repeater_verbatim_wire(UNRESOLVED).should contain("q=$ENV.NOT_SET")
    fuzz_verbatim_baseline(UNRESOLVED).should contain("q=$ENV.NOT_SET")
  end

  it "leaves a Content-Length that disagrees with the body" do
    repeater_verbatim_wire(DISAGREE).should contain("Content-Length: 2\r\n")
    fuzz_verbatim_baseline(DISAGREE).should contain("Content-Length: 2\r\n")
  end

  it "keeps a bare-LF header line unpromoted" do
    repeater_verbatim_wire(BARE_LF).should contain("Host: h.test\nX-A: 1")
    fuzz_verbatim_baseline(BARE_LF).should contain("Host: h.test\nX-A: 1")
  end
end

describe "the Content-Length-only switch is not verbatim" do
  # A disagreeing Content-Length stays (the CL half), but the head's bare LF is still promoted
  # to CRLF — the axis that separates it from verbatim, which keeps the LF.
  it "keeps the Content-Length but still promotes a bare-LF head" do
    raw = "POST /x HTTP/1.1\r\nHost: h.test\nContent-Length: 2\r\n\r\nhello"
    out = fuzz_cl_only_baseline(raw)
    out.should contain("Content-Length: 2\r\n")          # the CL half: untouched
    out.should contain("Host: h.test\r\nContent-Length") # the other axes: bare LF promoted
    out.should_not contain("Host: h.test\nContent-Length")
  end
end
