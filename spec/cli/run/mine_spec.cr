require "../../spec_helper"

# Round 8 item 2: `gori run mine --locations json` against a request whose body EXISTS but is
# not valid UTF-8 used to route through the generic
#
#   gori run mine: json: not applicable to this request (no matching existing body), skipping
#
# — the wrong reason for a body that plainly IS there. `Detect`/`Inject` correctly refuse to
# OFFER Json for such a body (round 7, miner/inject.cr's `json_object_node_count` — it cannot
# round-trip through `JSON::Any`), but "no matching existing body" tells the operator the wrong
# thing. The CLI now gives that one case its own sentence.
#
# The CLI's wording lives behind `private def self.` (nothing outside `gori run` may phrase
# it), so it is reached through a shim in the same module — the pattern
# `env_unresolved_error_for_spec` (spec/cli/run/bind_from_disabled_rule_spec.cr) already uses.
module Gori::CLI::Run
  def self.mine_inapplicable_reason_for_spec(loc : Miner::Location, request : Bytes) : String
    mine_inapplicable_reason(loc, request)
  end
end

private alias M = Gori::Miner

# Byte-exact fixture per the round-8 rule: build the non-UTF-8 body from a raw `Bytes`
# literal, never a String literal (a Crystal String literal must itself be valid UTF-8).
private def request_with_body(body : Bytes, content_type : String? = "application/json") : Bytes
  head_lines = ["POST / HTTP/1.1", "Host: x"]
  head_lines << "Content-Type: #{content_type}" if content_type
  head_lines << "Content-Length: #{body.size}"
  head = (head_lines.join("\r\n") + "\r\n\r\n").to_slice
  io = IO::Memory.new(head.size + body.size)
  io.write(head)
  io.write(body)
  io.to_slice
end

describe "Gori::CLI::Run — mine inapplicable-location wording" do
  it "gives JSON its own accurate reason when the body exists but is not valid UTF-8" do
    request = request_with_body(Bytes[0xFF, 0xFE, 0x01, 0x02])
    reason = Gori::CLI::Run.mine_inapplicable_reason_for_spec(M::Location::Json, request)
    reason.should contain("not valid UTF-8")
    reason.should_not contain("no matching existing body")
  end

  it "keeps the generic reason for JSON when there is genuinely no body (complement)" do
    request = "GET / HTTP/1.1\r\nHost: x\r\n\r\n".to_slice
    reason = Gori::CLI::Run.mine_inapplicable_reason_for_spec(M::Location::Json, request)
    reason.should eq("not applicable to this request (no matching existing body)")
  end

  it "keeps the generic reason for JSON when the body is present and valid UTF-8 (complement)" do
    request = request_with_body(%({"a":1}).to_slice)
    reason = Gori::CLI::Run.mine_inapplicable_reason_for_spec(M::Location::Json, request)
    reason.should eq("not applicable to this request (no matching existing body)")
  end

  it "keeps the generic reason for a non-JSON location regardless of body encoding (complement)" do
    request = request_with_body(Bytes[0xFF, 0xFE, 0x01, 0x02], content_type: nil)
    reason = Gori::CLI::Run.mine_inapplicable_reason_for_spec(M::Location::Form, request)
    reason.should eq("not applicable to this request (no matching existing body)")
  end
end
