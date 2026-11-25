require "../spec_helper"
require "../support/fake_context"
require "../support/fake_host"
require "../support/tui_contract"

include Gori::Tui

# Send flow to… → Repeater over a hold (loop.md #5), the review round: what the seed refuses,
# where the row sits on the card, what keeps the hold from being reaped while its tab is open,
# and the 80-column budget of every sentence it can leave on the status line.

private def with_queue(& : Gori::Interceptor, InterceptController ->)
  TuiContract.with_session("intercept-send-repeater") do |session|
    ic = session.interceptor
    ic.toggle
    ctl = InterceptController.new(TuiContract::Host.new(session))
    yield ic, ctl
  end
end

describe "Send flow to… → Repeater from Intercept" do
  # A head-only h2 hold's `raw` is the head alone: the body streams past the gate. Seeded, the
  # tab held a bodyless POST, auto-CL rewrote `content-length: 5000` to 0, and `^R` sent a
  # request the client never sent, marked as evidence.
  it "refuses a head-only HTTP/2 hold, and one whose head has no exact text form" do
    with_queue do |ic, ctl|
      head_only = ic.enqueue_request("POST /u HTTP/2\r\nhost: acme.test\r\ncontent-length: 5000\r\n\r\n".to_slice,
        method: "POST", target: "/u", host: "acme.test", port: 443, scheme: "https",
        head_only: true, http2: true).not_nil!
      inexact = ic.enqueue_request("GET /x HTTP/2\r\nhost: acme.test\r\n\r\n".to_slice,
        method: "GET", target: "/x", host: "acme.test", port: 443, scheme: "https",
        edit_refusal: "a header value carries a CR/LF", http2: true).not_nil!
      buffered = ic.enqueue_request("POST /b HTTP/2\r\nhost: acme.test\r\ncontent-length: 2\r\n\r\nhi".to_slice,
        method: "POST", target: "/b", host: "acme.test", port: 443, scheme: "https", http2: true).not_nil!
      ctl.on_enter
      ctl.repeater_seed(head_only.id).should eq(InterceptController::SEED_HEAD_ONLY)
      ctl.repeater_seed(inexact.id).should eq(InterceptController::SEED_INEXACT)
      seed = ctl.repeater_seed(buffered.id).as(InterceptController::HeldSeed)
      seed.text.should end_with("\r\n\r\nhi") # a buffered h2 body is whole, so it is sent
      seed.id.should eq(buffered.id)
    end
  end

  # Orchestrator decision: the row joins the card without moving Forward held off the top, so
  # a reflex `space ↵` forwards exactly as it did before.
  it "keeps Forward held as the card's first row, with `r` and `>` still on it" do
    ctx = FakeExecContext.new
    ctx.intercept_selected = 3_i64
    ctx.current_tab = :intercept
    menu = SpaceMenu.new(Gori::Verbs.registry)
    menu.open(Gori::Verb::Scope::Intercept, :common, ctx)
    menu.selected_verb.try(&.id).should eq("intercept.forward")
    menu.entries.compact_map(&.verb).first.id.should eq("intercept.forward")
    menu.entry_for('r').try(&.verb).try(&.id).should eq("intercept.repeater")
    menu.entry_for('>').try(&.family).should eq(Gori::Verbs::SEND_FLOW)
  end

  # The reaper forwards a hold nobody has watched for 30 s once an agent is attached, and
  # `goto_tab(:repeater)` is what starts that clock: "still held" went false while the operator
  # worked the tab. A hold with an open seeded tab is watched, like the one mid-edit.
  it "counts a hold with an open seeded Repeater tab as watched" do
    TuiContract.with_session("intercept-send-reap") do |session|
      rc = RepeaterController.new(FakeHost.new(session))
      rc.repeater_from_request("http://h.test", "GET / HTTP/1.1\r\nHost: h.test\r\n\r\n", false, nil)
      rc.held_source_ids.should be_empty # an ordinary tab watches no hold
      rc.repeater_held("http://h.test", "GET /h HTTP/1.1\r\n\r\n", "GET /h HTTP/1.1\r\n\r\n", false, true, 7_i64)
      rc.held_source_ids.should eq(Set{7_i64})

      Runner.reap_exempt?(7_i64, nil, rc.held_source_ids).should be_true
      Runner.reap_exempt?(8_i64, nil, rc.held_source_ids).should be_false
      Runner.reap_exempt?(8_i64, 8_i64, rc.held_source_ids).should be_true # mid-edit, as before
    end
  end

  # 59 cells is what an 80-column status line leaves a toast (see unbound_key_hint_spec).
  it "says every outcome inside the 80-column toast budget" do
    sentences = [
      InterceptController::SEED_GONE, InterceptController::SEED_WS, InterceptController::SEED_NO_FLOW,
      InterceptController::SEED_HEAD_ONLY, InterceptController::SEED_INEXACT,
      Runner::HELD_OPENED, Runner::HELD_RESPONSE,
      Runner.held_batch_toast(Runner::BATCH_SUBTAB_CAP, 0),
      Runner.held_batch_toast(10, 10),
      Runner.held_batch_toast(1, Runner::BATCH_SUBTAB_CAP - 1),
      Runner.held_none_toast(Runner::BATCH_SUBTAB_CAP),
    ]
    sentences.each { |s| Screen.draw_width(s).should be <= 59, s }
  end

  it "confirms only what will open, and counts the skipped in the toast" do
    Runner.held_batch_toast(3, 2).should eq("still held · opened 3 tabs, 2 skipped (not saved)")
    Runner.held_batch_toast(2, 0).should eq("still held · opened 2 tabs (not saved)")
    body = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner", "intercept.cr"))
    confirm = body[/def intercept_repeater.*?\n  end/m].not_nil!
    confirm.should contain(".reject(String)") # refusals leave the batch before the count
    confirm.index(".reject(String)").not_nil!.should be < confirm.index("confirm(").not_nil!
    confirm.should contain("Open \#{seeds.size} held requests")
  end
end
