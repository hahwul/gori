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
# testable without a Host double — the reason `.literal_bindings` is), keyed on
# `RepeaterView#markers_active?` so a capture's own inert `§` is not refused. Its natural
# home is `RepeaterView#group_sendable?`, whose comment already names MARK alongside hex /
# gRPC / WS / decode; that file is owned elsewhere this round.

private def group_tmp_store(&)
  path = File.tempname("gori-gs", ".db")
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

MARKED_GROUP = "POST /one HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\n§PAYLOAD-A¦base64-encode§\r\n" \
               "%%%\r\nPOST /two HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\n§PAYLOAD-B¦base64-encode§\r\n"

PLAIN_GROUP = "POST /plain1 HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\nPAYLOAD-A\r\n" \
              "%%%\r\nPOST /plain2 HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\nPAYLOAD-B\r\n"

describe "Gori::Tui::RepeaterController.group_marker_refusal" do
  it "refuses, by name and with the way out, while markers are live" do
    reason = RepeaterController.group_marker_refusal(true)
    reason.should_not be_nil
    reason.not_nil!.should contain("§…§")
    reason.not_nil!.should contain("^R") # the send that DOES render them
  end

  it "proceeds when no marker is live" do
    RepeaterController.group_marker_refusal(false).should be_nil
  end
end

# The predicate the controller feeds it, over the buffers that reach a real tab.
describe "the group-send decision on a real RepeaterView" do
  it "refuses a draft whose §value¦chain§ the pipeline would ship literally" do
    view = RepeaterView.new
    view.restore("http://127.0.0.1", MARKED_GROUP, false, true) # a ^N draft: markers are live
    view.markers_active?.should be_true
    RepeaterController.group_marker_refusal(view.markers_active?).should_not be_nil
  end

  it "refuses a chain-less §value§ too — it is equally unrendered on this path" do
    view = RepeaterView.new
    view.restore("http://127.0.0.1", "POST /a HTTP/1.1\r\nHost: h\r\n\r\n§PAYLOAD§", false, true)
    RepeaterController.group_marker_refusal(view.markers_active?).should_not be_nil
  end

  it "refuses the unrunnable chain the single send already refuses, instead of sending it" do
    # Round 6's `refuse_bad_chains` covers `^R` only; before this the group path sent
    # `§PAYLOAD-A¦no-such-conv§` verbatim and reported "2/2 ok on one connection".
    view = RepeaterView.new
    view.restore("http://127.0.0.1", "POST /bad1 HTTP/1.1\r\nHost: h\r\n\r\n§PAYLOAD-A¦no-such-conv§", false, true)
    RepeaterController.group_marker_refusal(view.markers_active?).should_not be_nil
  end

  it "lets an ordinary %%% group through untouched" do
    view = RepeaterView.new
    view.restore("http://127.0.0.1", PLAIN_GROUP, false, true)
    view.markers_active?.should be_false
    RepeaterController.group_marker_refusal(view.markers_active?).should be_nil
  end

  # PROVENANCE, the other half: a `§…§` pair the ORIGIN sent is data, not marker syntax
  # (see the `§ in a CAPTURED body` block in repeater_view_spec). It is inert, so
  # `pipeline_requests` puts it on the wire exactly as `^R` does — there is nothing to
  # render and nothing to refuse, and refusing would block a group send that was never
  # wrong.
  it "does NOT refuse a capture whose own § the operator never declared as markers" do
    group_tmp_store do |store|
      body = %({"note":"§ 5 Abs. 2 §","q":"x"}).to_slice
      head = ("POST /seed HTTP/1.1\r\nHost: h.test\r\n" \
              "Content-Type: application/json\r\nContent-Length: #{body.size}\r\n\r\n").to_slice
      id = store.insert_flow(Gori::Store::CapturedRequest.new(
        created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
        method: "POST", target: "/seed", http_version: "HTTP/1.1",
        head: head, body: body))
      view = RepeaterView.new
      view.load(store.get_flow(id).not_nil!)
      view.evidence?.should be_true
      view.markers_active?.should be_false
      RepeaterController.group_marker_refusal(view.markers_active?).should be_nil
      # …and the § really is still there, so this is the inert case and not an empty buffer.
      view.request_text.should contain("§ 5 Abs. 2 §")
    end
  end
end

# The bytes the refusal exists to stop, straight from the view: this is what
# `pipeline_requests` hands the pipeline, and why a refusal (rather than a shrug) is the
# only acceptable outcome until the group path learns to render.
describe "Gori::Tui::RepeaterView#pipeline_requests with live markers" do
  it "emits the marker syntax as literal bytes, disagreeing with the editor's own Content-Length" do
    view = RepeaterView.new
    view.restore("http://127.0.0.1", MARKED_GROUP, false, true) # auto-CL on, as the tab ships

    wire = String.new(view.pipeline_requests[0][1])
    wire.should contain("§PAYLOAD-A¦base64-encode§") # NOT `UEFZTE9BRC1B`
    wire.should contain("Content-Length: 28")        # the literal marker's length…
    # …while the editor is showing the RENDERED body's 12, because the CL reflection runs
    # through `render_marked` and the send does not. The two disagree, which is exactly
    # what `render_marked`'s own comment says the shared render exists to prevent.
    view.request_text.should contain("Content-Length: 12")
  end

  # `^R` renders the chain, as it always has — asserted on a marked request with NO `%%%`,
  # because a buffer that HAS one no longer reaches the render at all (next example).
  it "still renders the chain on the single send" do
    view = RepeaterView.new
    view.restore("http://127.0.0.1",
      "POST /one HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\n§PAYLOAD-A¦base64-encode§", false, true)
    single = String.new(view.request_bytes)
    single.should contain("UEFZTE9BRC1B")
    single.should_not contain("¦base64-encode")
  end

  # Where the two round-7 repeater fixes meet. On a MARKED `%%%` buffer both send buttons
  # now refuse, for different and independent reasons, so neither can put marker bytes on
  # the wire:
  #   * `space ▸ g` — `group_marker_refusal`: `pipeline_requests` does not render.
  #   * `^R`        — `RepeaterView#group_framing_refusal` (Fuzz::ChainError): the pane's
  #     Content-Length is chunk 1's, and a whole-buffer send would read it as the whole
  #     body's. `repeater_send`'s existing `rescue Fuzz::ChainError` surfaces it, which is
  #     the same rescue round 6's chain refusal already used.
  # Pinned because the two land from different branches and nothing else would notice if a
  # later change re-opened either one.
  it "refuses BOTH send buttons on a marked group buffer" do
    view = RepeaterView.new
    view.restore("http://127.0.0.1", MARKED_GROUP, false, true)

    RepeaterController.group_marker_refusal(view.markers_active?).should_not be_nil

    ex = expect_raises(Gori::Fuzz::ChainError) { view.request_bytes }
    ex.message.not_nil!.should contain("%%%")
  end
end

# `space ▸ M` is the third reader of the chunk-scoped pane, and the one the `^R` refusal did
# not reach: `minimizable?` has no `%%%` clause, and minimize's own `resolve` re-syncs
# Content-Length over the WHOLE buffer — the two-request-document-read-as-one framing `^R`
# now refuses, applied once per probe send instead of once. `repeater_minimize` therefore
# asks the view the same question through the same public route, and these pin that it
# refuses exactly where `^R` does and nowhere else.
describe "minimize on a live %%% group buffer" do
  group = "POST /g1 HTTP/1.1\r\nHost: h\r\nContent-Length: 99\r\n\r\nAAA\r\n" \
          "%%%\r\nPOST /g2 HTTP/1.1\r\nHost: h\r\nContent-Length: 99\r\n\r\nBB\r\n"

  it "is refused, because it is the same whole-buffer framing ^R is refused" do
    view = RepeaterView.new
    view.restore("http://127.0.0.1", group, false, true)
    # `minimizable?` alone does NOT stop it — this is why the gate is needed at all.
    view.minimizable?.should be_true
    view.request_text.should contain("Content-Length: 3")
    # What repeater_minimize's `resolve` would hand Repeater::Minimize.run for EVERY probe
    # send: the two-request document reframed as one.
    resolved = String.new(Gori::Repeater::FlowRequest.resync_content_length(Gori::Env.expand_wire(view.request_text)))
    resolved.should contain("Content-Length: 63")

    reason = RepeaterController.whole_buffer_refusal(view)
    reason.should_not be_nil
    reason.not_nil!.should contain("%%%")
  end

  # The complements: the gate must not refuse a minimize that was never wrong. Each is a
  # state in which nothing chunk-scoped is in the visible head.
  it "is allowed with auto-CL off — the numbers are the operator's" do
    view = RepeaterView.new
    view.restore("http://127.0.0.1", group, false, false)
    view.request_text.should contain("Content-Length: 99")
    RepeaterController.whole_buffer_refusal(view).should be_nil
  end

  it "is allowed on h2 — the pane is never chunked there" do
    view = RepeaterView.new
    view.restore("http://127.0.0.1", group, false, true)
    view.toggle_http2
    view.request_text.should contain("Content-Length: 63") # whole buffer, not chunk 1
    RepeaterController.whole_buffer_refusal(view).should be_nil
  end

  it "is allowed for an ordinary request with no %%%" do
    view = RepeaterView.new
    view.restore("http://127.0.0.1", "POST /p HTTP/1.1\r\nHost: h\r\nContent-Length: 99\r\n\r\nAAA", false, true)
    RepeaterController.whole_buffer_refusal(view).should be_nil
  end

  it "is untouched for a group with no markers" do
    view = RepeaterView.new
    view.restore("http://127.0.0.1", PLAIN_GROUP, false, true)
    reqs = view.pipeline_requests
    reqs.size.should eq(2)
    String.new(reqs[0][1]).should eq("POST /plain1 HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\nPAYLOAD-A")
    String.new(reqs[1][1]).should eq("POST /plain2 HTTP/1.1\r\nHost: h\r\nContent-Length: 9\r\n\r\nPAYLOAD-B")
  end
end
