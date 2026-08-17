require "../../spec_helper"

# argv is whatever bytes the OS handed us — Crystal builds those Strings without validating
# UTF-8 — and `split_ql_negations` matched a PCRE2 regex straight against them. PCRE2 does not
# fail to match on a bad subject, it RAISES `ArgumentError: Regex match error: UTF-8 error`,
# and neither `Run.dispatch` (rescues IO::Error) nor `CLI.run` (rescues Gori::Error) catches
# that, so `gori run history $'\xff'` printed a Crystal backtrace out of `main` before any
# store was even opened. Reachable from a plain shell, and realistically from a wrapper script
# interpolating a latin-1 term captured off the wire.
#
# The remedy is the one `read_token_list` in src/gori/cli/run/sequence.cr already uses: scrub
# the SUBJECT of the match, never the value. What gets pushed into the returned arrays is the
# original `a`, so the operator's query bytes reach QL exactly as typed (P7) — the assertions
# below check both halves, because scrubbing the stored value would be the easy wrong fix.
#
# The two sibling sites, `parse_duration` (`--for`) and `parse_numbers` (`--numbers`), took the
# same one-word change, but both end in `abort` on a value that does not match and so cannot be
# exercised in-process; `split_ql_negations` returns, so it carries the behavioural pin.
module Gori::CLI::Run
  def self.split_ql_negations_for_spec(args : Array(String))
    split_ql_negations(args)
  end
end

private def raw(bytes : Bytes) : String
  String.new(bytes)
end

describe "CLI::Run.split_ql_negations — non-UTF-8 argv" do
  it "classifies an invalid-UTF-8 term instead of raising out of main" do
    junk = raw(Bytes[0xff])
    junk.valid_encoding?.should be_false
    neg, rest = Gori::CLI::Run.split_ql_negations_for_spec([junk])
    neg.should be_empty
    rest.size.should eq(1)
    rest[0].to_slice.should eq(junk.to_slice)
  end

  it "keeps the query term byte-exact — the scrub is the match subject, not the value" do
    # "-host:" + 0xff: a negation term whose VALUE carries the junk byte.
    junk = raw(Bytes[0x2d, 0x68, 0x6f, 0x73, 0x74, 0x3a, 0xff])
    neg, rest = Gori::CLI::Run.split_ql_negations_for_spec([junk])
    rest.should be_empty
    neg.size.should eq(1)
    neg[0].to_slice.should eq(junk.to_slice)
    neg[0].valid_encoding?.should be_false # not silently repaired on its way through
  end

  it "still splits ordinary terms the same way" do
    neg, rest = Gori::CLI::Run.split_ql_negations_for_spec(["host:x", "-path:/b", "-n50", "-k"])
    neg.should eq(["-path:/b"])
    rest.should eq(["host:x", "-n50", "-k"])
  end

  it "classifies a dotted-field negation as a QL term, not an unknown option" do
    neg, rest = Gori::CLI::Run.split_ql_negations_for_spec(
      ["host:x", "-resp.body:secret", "-req.header:Cookie", "-n50"])
    neg.should eq(["-resp.body:secret", "-req.header:Cookie"])
    rest.should eq(["host:x", "-n50"])
  end
end
