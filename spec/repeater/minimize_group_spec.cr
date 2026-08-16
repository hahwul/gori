require "../spec_helper"

# `Repeater::Minimize.group_document?` — the predicate `gori run repeater minimize` and MCP
# `minimize` refuse on, and the headless half of the TUI's `RepeaterView#minimize_refusal`.
#
# `Minimize.run` reads its base text STRUCTURALLY as one request: head/body split, then
# header / cookie / param candidates. Handed a `%%%` group it therefore strips lines out of
# the operator's SECOND request and reports them as removals from the first. Reproduced
# end to end through the CLI on a saved two-request session:
#
#     $ gori run repeater minimize 1 --project sib --apply
#     minimized: removed 2 cookies, 3 params (8 sends) · 8 sends
#       - [cookie] sess
#       - [cookie] tracker
#       - [query] keep
#       - [query] junkA
#       - [param] %%%
#     GET /g2?other                 ← the operator's ENTIRE second request, as a body param
#     saved back to session #1
#     GET /g1 HTTP/1.1 …            ← request 1 alone is what the store now holds
#     exit=0
#
# 8 requests on the origin, the session overwritten irreversibly, reported as a clean
# optimisation. The TUI grew a refusal for this; these two surfaces cite
# `repeater_view.cr#minimizable?` in a comment and knew nothing about `%%%`.

describe Gori::Repeater::Minimize do
  describe ".group_document?" do
    it "is true for a lone %%% line, LF or CRLF" do
      Gori::Repeater::Minimize.group_document?(
        "GET /a HTTP/1.1\nHost: h\n\n%%%\nGET /b HTTP/1.1\nHost: h\n\n").should be_true
      # The stored bytes are CRLF — the `\r` must not stop the line matching.
      Gori::Repeater::Minimize.group_document?(
        "GET /a HTTP/1.1\r\nHost: h\r\n\r\n%%%\r\nGET /b HTTP/1.1\r\nHost: h\r\n\r\n").should be_true
    end

    it "tolerates surrounding whitespace on the separator line" do
      Gori::Repeater::Minimize.group_document?("GET /a HTTP/1.1\n\n  %%%\t\nGET /b HTTP/1.1\n\n").should be_true
    end

    it "is false for an ordinary single request" do
      Gori::Repeater::Minimize.group_document?(
        "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\n\r\nAAA").should be_false
    end

    # `%%%` only separates when it is the WHOLE line — the same rule the editor's split uses,
    # so a body or header that merely contains the characters is not a group.
    it "is false when %%% is not alone on its line" do
      Gori::Repeater::Minimize.group_document?(
        "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\nab%%%cd\r\n").should be_false
      Gori::Repeater::Minimize.group_document?(
        "POST /a HTTP/1.1\r\nX-Pct: %%% here\r\n\r\n").should be_false
    end

    it "matches the group the sibling spec sends through the TUI" do
      Gori::Repeater::Minimize.group_document?(
        "POST /plain1 HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\nPAYLOAD-A\r\n" \
        "%%%\r\nPOST /plain2 HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\nPAYLOAD-B\r\n").should be_true
    end
  end

  # The damage the predicate exists to stop, straight from the engine, so the refusal's
  # justification is pinned rather than asserted in a comment. A backend that answers every
  # variant identically makes every candidate look removable, which is the enumeration.
  describe "what run does to a group buffer when nothing stops it" do
    group = "GET /g1?keep=1&junkA=1 HTTP/1.1\nHost: h\nX-Junk-1: aaaa\nCookie: sess=abc; tracker=xyz\n\n" \
            "%%%\nGET /g2?other=2 HTTP/1.1\nHost: h\nX-Second-Only: bbbb\n\n"

    it "deletes the operator's second request and calls it a removed body param" do
      backend = SameResponseBackend.new(Gori::Fuzz::Origin.new("http", "h", 80))
      report = Gori::Repeater::Minimize.run(group, auto_cl: true,
        resolve: ->(t : String) { t.to_slice }, backend: backend) { |_| }
      report.removed.map(&.label).should contain("%%%\nGET /g2?other")
      report.minimized_text.should_not contain("/g2") # request 2 is gone
      report.aborted.should be_false                  # …and it reports success
    end

    # Why the refusal is STRUCTURAL and not scoped to auto-CL, unlike the `^R` one: with
    # auto-CL off the operator's own Content-Lengths are untouched and nothing is invented,
    # yet minimize still strips request 1's query params and leaves request 2 dangling
    # inside the "minimized request".
    it "is meaningless with auto-CL off too" do
      backend = SameResponseBackend.new(Gori::Fuzz::Origin.new("http", "h", 80))
      report = Gori::Repeater::Minimize.run(group, auto_cl: false,
        resolve: ->(t : String) { t.to_slice }, backend: backend) { |_| }
      report.removed.map(&.label).should contain("keep")
      report.minimized_text.should contain("/g2") # …and request 2 is still dangling in it
    end
  end
end

# Answers every probe identically, so no removal ever changes the response and the full
# candidate enumeration is visible. Never touches a socket.
private class SameResponseBackend < Gori::Fuzz::Backend
  getter origin : Gori::Fuzz::Origin

  def initialize(@origin : Gori::Fuzz::Origin)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    Gori::Repeater::Result.new("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice, "ok".to_slice, nil, 1_i64)
  end
end
