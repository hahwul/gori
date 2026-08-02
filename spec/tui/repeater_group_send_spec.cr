require "../spec_helper"

include Gori::Tui

# Repeater "send group" (space → g, the `%%%` pipeline) versus §…§ markers.
#
# `RepeaterView#request_bytes` routes a marked request through `marked_request_bytes` →
# `render_marked(refuse: true)`, which applies each marker's inline Decoder chain and
# REFUSES a chain that cannot run. `pipeline_requests` never reaches either: it goes
# straight to `finalize_wire(expanded_text_to_bytes(…))`. So the group send put the marker
# syntax itself on the wire — reproduced against a recording origin at base:
#
#     POST /one HTTP/1.1
#     Content-Length: 28
#
#     §PAYLOAD-A¦base64-encode§        (c2 a7 … c2 a6 … c2 a7)
#
# while the editor showed `Content-Length: 12` for the rendered `UEFZTE9BRC1B`, under a
# status line reading "send group: 2/2 ok on one connection". The same divergence took the
# `¦chain` refusal off this path: `^R` refuses `§PAYLOAD-A¦no-such-conv§` by name, and
# space→g sent it.
#
# The refusal lives in `RepeaterController.group_marker_refusal` (pure + `self.`, so it is
# testable without a Host double — the reason `.literal_bindings` is). Its natural home is
# `RepeaterView#group_sendable?`, whose comment already names MARK alongside hex / gRPC /
# WS / decode; that file is owned elsewhere this round.

describe "Gori::Tui::RepeaterController.group_marker_refusal" do
  it "refuses a group send while a §value¦chain§ marker is present" do
    text = "POST /one HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\n§PAYLOAD-A¦base64-encode§\r\n" \
           "%%%\r\nPOST /two HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\n§PAYLOAD-B¦base64-encode§\r\n"
    reason = RepeaterController.group_marker_refusal(text)
    reason.should_not be_nil
    reason.not_nil!.should contain("§…§")
    reason.not_nil!.should contain("^R")
  end

  it "refuses a chain-less §value§ marker too — it is equally unrendered on this path" do
    RepeaterController.group_marker_refusal(
      "POST /a HTTP/1.1\r\nHost: h\r\n\r\n§PAYLOAD§").should_not be_nil
  end

  it "refuses the unrunnable chain the single send already refuses, instead of sending it" do
    # Round 6's `refuse_bad_chains` covers `^R` only; before this the group path sent
    # `§PAYLOAD-A¦no-such-conv§` verbatim and reported "2/2 ok".
    RepeaterController.group_marker_refusal(
      "POST /bad1 HTTP/1.1\r\nHost: h\r\n\r\n§PAYLOAD-A¦no-such-conv§").should_not be_nil
  end

  it "lets an ordinary %%% group through untouched" do
    text = "POST /plain1 HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\nPAYLOAD-A\r\n" \
           "%%%\r\nPOST /plain2 HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\nPAYLOAD-B\r\n"
    RepeaterController.group_marker_refusal(text).should be_nil
  end

  it "lets an UNPAIRED § through — it is not marker syntax and must reach the wire" do
    # A captured German/legal body carrying one `§ 5 Abs. 2` is data, not a template;
    # `marker_regions` is empty for it, so the group send stays byte-exact.
    RepeaterController.group_marker_refusal(
      "POST /a HTTP/1.1\r\nHost: h\r\nContent-Length: 12\r\n\r\n{\"n\":\"§ 5\"}").should be_nil
  end
end

# The bytes the refusal exists to stop, straight from the view: this is what
# `pipeline_requests` hands the pipeline, and why a refusal (rather than a shrug) is the
# only acceptable outcome until the group path learns to render.
describe "Gori::Tui::RepeaterView#pipeline_requests with markers" do
  it "emits the marker syntax as literal bytes, disagreeing with the editor's own Content-Length" do
    view = RepeaterView.new
    req = "POST /one HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\n§PAYLOAD-A¦base64-encode§\r\n" \
          "%%%\r\nPOST /two HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\n§PAYLOAD-B¦base64-encode§\r\n"
    view.restore("http://127.0.0.1", req, false, true) # auto-CL on, as the tab ships

    wire = String.new(view.pipeline_requests[0][1])
    wire.should contain("§PAYLOAD-A¦base64-encode§") # NOT `UEFZTE9BRC1B`
    wire.should contain("Content-Length: 28")        # the literal marker's length…
    # …while the editor is showing the RENDERED body's 12, because the CL reflection runs
    # through `render_marked` and the send does not. The two disagree, which is exactly
    # what `render_marked`'s own comment says the shared render exists to prevent.
    view.request_text.should contain("Content-Length: 12")

    # And the same text through the SINGLE send is rendered, as it always was.
    single = String.new(view.request_bytes)
    single.should contain("UEFZTE9BRC1B")
    single.should_not contain("¦base64-encode")
  end

  it "is untouched for a group with no markers" do
    view = RepeaterView.new
    req = "POST /plain1 HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\nPAYLOAD-A\r\n" \
          "%%%\r\nPOST /plain2 HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\nPAYLOAD-B\r\n"
    view.restore("http://127.0.0.1", req, false, true)
    reqs = view.pipeline_requests
    reqs.size.should eq(2)
    String.new(reqs[0][1]).should eq("POST /plain1 HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\nPAYLOAD-A")
    String.new(reqs[1][1]).should eq("POST /plain2 HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\nPAYLOAD-B")
  end
end
