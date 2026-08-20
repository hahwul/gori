require "../spec_helper"
require "file_utils"

# `Settings.rewriter_rules` — the GLOBAL half of the Match & Replace rule set, the library
# every project reads. The parse is the boundary a HAND-EDITED settings.json crosses on its way
# into the live rewrite engine, and hand-editing is a supported way to write these: the enum
# fields are stored as the same labels `gori run rewriter` prints, precisely so the file reads
# the way the CLI does.
#
# Which is what makes the SHAPE the parse's business too. The four enum fields are clamped
# INDEPENDENTLY, so `{op: "set_header", part: "ws"}` — a pair the CLI and MCP tools both REFUSE
# outright rather than normalize — used to arrive in the rule list intact. A header op acts by
# header NAME and only a head has header lines, so it can never fire; `Rules`' own `rewrites?`
# keeps it out of the counts and the select. This file pins the parse half: the entry is
# DROPPED, never coerced onto the head. Coercion is what `Rules.normalize_shape` calls "a
# different protocol, not a narrower shape" — and it would take a rule that does nothing and
# put it on every request head in every project, live, on the strength of a parse.
private def with_rewriter_home(&)
  dir = File.tempname("gori-rewriter-rules")
  Dir.mkdir_p(dir)
  prev_home = ENV["GORI_HOME"]?
  before = Gori::Settings.rewriter_rules
  counter = Gori::Settings.rewriter_next_rule_id
  begin
    ENV["GORI_HOME"] = dir
    Gori::Settings.rewriter_rules = [] of Gori::Settings::RewriterRule
    yield dir
  ensure
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    Gori::Settings.rewriter_rules = before
    Gori::Settings.rewriter_next_rule_id = counter
    FileUtils.rm_rf(dir)
  end
end

private def write_settings(json : String) : Nil
  File.write(Gori::Settings.path, json)
end

private def shapes : Array({String, String, String})
  Gori::Settings.rewriter_rules.map { |r| {r.op, r.target, r.part} }
end

describe "Gori::Settings rewriter rule shape" do
  it "drops a header op that names a part with no header lines" do
    with_rewriter_home do
      write_settings(<<-JSON)
        {"rewriter": {"rules": [
          {"id": 1, "enabled": true, "pattern": "X-Bad", "op": "set_header", "part": "ws", "target": "response"},
          {"id": 2, "enabled": true, "pattern": "X-Also-Bad", "op": "remove_header", "part": "body", "target": "request"}
        ]}}
        JSON
      Gori::Settings.load
      Gori::Settings.rewriter_rules.should be_empty
    end
  end

  # The neighbours in the same array survive — one impossible entry is not a reason to lose the
  # file, which is the whole disposition this parse is built on (see `clamp_field`).
  it "keeps every other rule in the array" do
    with_rewriter_home do
      write_settings(<<-JSON)
        {"rewriter": {"rules": [
          {"id": 1, "enabled": true, "pattern": "X-Bad", "op": "add_header", "part": "ws", "target": "request"},
          {"id": 2, "enabled": true, "pattern": "csp", "op": "remove_header", "part": "head", "target": "response"}
        ]}}
        JSON
      Gori::Settings.load
      shapes.should eq([{"remove_header", "response", "head"}])
      Gori::Settings.rewriter_rules.first.id.should eq(2)
    end
  end

  # Only the pair that cannot fire is touched. A `replace` rule means something on all three
  # parts (`ws` is a WebSocket message), and a `short_circuit` rule ignores its part and target
  # at match time — normalizing either here would be the coercion this drop exists to avoid.
  it "leaves every shape that can actually fire alone, ws included" do
    with_rewriter_home do
      write_settings(<<-JSON)
        {"rewriter": {"rules": [
          {"id": 1, "enabled": true, "pattern": "a", "op": "replace", "part": "ws", "target": "response"},
          {"id": 2, "enabled": true, "pattern": "b", "op": "replace", "part": "body", "target": "request"},
          {"id": 3, "enabled": true, "pattern": "/admin", "op": "short_circuit", "part": "head", "target": "request"}
        ]}}
        JSON
      Gori::Settings.load
      shapes.should eq([
        {"replace", "response", "ws"},
        {"replace", "request", "body"},
        {"short_circuit", "request", "head"},
      ])
    end
  end

  it "keeps a well-shaped rule's id, pattern, host and enabled state" do
    with_rewriter_home do
      write_settings(<<-JSON)
        {"rewriter": {"rules": [
          {"id": 7, "enabled": true, "name": "strip", "pattern": "X-Bad", "replacement": "v",
           "op": "remove_header", "part": "head", "target": "response", "host": "*.corp.internal"}
        ]}}
        JSON
      Gori::Settings.load
      rule = Gori::Settings.rewriter_rules.first
      rule.id.should eq(7)
      rule.enabled.should be_true
      rule.name.should eq("strip")
      rule.pattern.should eq("X-Bad")
      rule.host.should eq("*.corp.internal")
    end
  end
end
