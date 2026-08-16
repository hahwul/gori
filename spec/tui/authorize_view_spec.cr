require "../spec_helper"
require "../support/memory_backend"
require "../../src/gori/tui/authorize_view"

include Gori::Tui

private def flow(method = "GET", target = "/admin", host = "h.test") : Gori::Store::FlowDetail
  row = Gori::Store::FlowRow.new(1_i64, 1_i64, "https", method, host, 443, target,
    200, 100_i64, Gori::Store::FlowState::Complete, 50_i64, 1_i64, "text/plain")
  head = "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\nCookie: s=1\r\n\r\n".to_slice
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", head, nil, nil, nil)
end

private def trial(name : String, baseline : Bool, status : Int32,
                  verdict : Gori::Authorize::Verdict) : Gori::Authorize::Trial
  meta = Gori::Repeater::ExchangeMeta.of(status, 40_i64, 1_000_i64, nil)
  summary = Gori::Authorize::ResponseSummary.new(status, 40_i64, 0_u64)
  resp = "HTTP/1.1 #{status} OK\r\n\r\n".to_slice
  Gori::Authorize::Trial.new(name, baseline, meta, verdict, baseline ? nil : "Δ size same",
    summary, "req".to_slice, resp, "body".to_slice)
end

private def target(bypass : Bool) : Gori::Authorize::Target
  other = bypass ? Gori::Authorize::Verdict::Same : Gori::Authorize::Verdict::Different
  Gori::Authorize::Target.new(1_i64, "GET", "https://h.test/admin", [
    trial("as-captured", true, 200, Gori::Authorize::Verdict::Baseline),
    trial("anonymous", false, bypass ? 200 : 403, other),
  ])
end

private def render(v : AuthorizeView, w = 120, h = 30) : Nil
  v.render(Screen.new(MemoryBackend.new(w, h)), Rect.new(0, 0, w, h), true)
end

describe AuthorizeView do
  it "starts empty with the two built-in identities and renders the empty state" do
    v = AuthorizeView.new
    v.any_requests?.should be_false
    v.identities.size.should eq(2)
    v.identities.first.baseline?.should be_true
    v.identities.last.name.should eq("anonymous")
    render(v)
  end

  it "loads MANY requests, one entry each, selecting the newest" do
    v = AuthorizeView.new
    id1 = v.add(flow("GET", "/a"))
    id2 = v.add(flow("POST", "/b"))
    v.size.should eq(2)
    id1.should_not eq(id2)
    v.selected_entry.not_nil!.method.should eq("POST") # newest selected
    v.label.should contain("2 req")
    render(v)
  end

  it "applies per-request results by entry id and reports an aggregate verdict" do
    v = AuthorizeView.new
    a = v.add(flow("GET", "/admin"))
    b = v.add(flow("GET", "/public"))
    v.apply_result(a, target(bypass: true))
    v.apply_result(b, target(bypass: false))
    v.entry_by_id(a).not_nil!.verdict.should eq(:bypass)
    v.entry_by_id(b).not_nil!.verdict.should eq(:enforced)
    v.bypass_total.should eq(1)
    render(v)
  end

  it "marks queued entries running and clears the flag on result" do
    v = AuthorizeView.new
    a = v.add(flow)
    v.mark_running(Set{a})
    v.entry_by_id(a).not_nil!.state.should eq(:running)
    v.entry_by_id(a).not_nil!.verdict.should eq(:running)
    v.apply_result(a, target(bypass: false))
    v.entry_by_id(a).not_nil!.state.should eq(:done)
  end

  it "moves the request cursor and the identity sub-cursor independently" do
    v = AuthorizeView.new
    a = v.add(flow("GET", "/a"))
    v.add(flow("GET", "/b"))
    v.apply_result(a, target(bypass: true))
    v.move_row(-1) # back to the first request
    v.selected_entry.not_nil!.method.should eq("GET")
    v.move_trial(1) # onto the anonymous identity
    v.selected_trial.not_nil!.identity.should eq("anonymous")
    render(v)
  end

  it "clears back to the empty state" do
    v = AuthorizeView.new
    v.add(flow)
    v.clear
    v.any_requests?.should be_false
    v.selected_entry.should be_nil
  end

  # An entry id is what a finished run's outcome carries back. `clear`/`remove` must never let
  # one be reused, or an outcome still in flight from the previous batch lands on a new row.
  it "never recycles an entry id, not even after clear" do
    v = AuthorizeView.new
    first = v.add(flow)
    v.clear
    v.add(flow).should be > first
  end

  describe "run-mode batches" do
    it "counts an entry with no result as pending, including one whose send errored" do
      v = AuthorizeView.new
      never = v.add(flow("GET", "/never"))
      errored = v.add(flow("GET", "/errored"))
      finished = v.add(flow("GET", "/done"))
      v.apply_error(errored, "connection refused")
      v.apply_result(finished, target(bypass: false))

      pending = v.pending_entries.map(&.id)
      pending.should contain(never)
      pending.should contain(errored) # no verdict yet ⇒ unfinished work
      pending.should_not contain(finished)
      v.pending_count.should eq(2)
      v.completed_count.should eq(1)
    end

    it "excludes an in-flight entry from both pending and runnable" do
      v = AuthorizeView.new
      a = v.add(flow("GET", "/a"))
      v.add(flow("GET", "/b"))
      v.mark_running(Set{a})
      v.pending_entries.map(&.id).should_not contain(a)
      v.runnable.map(&.id).should_not contain(a)
    end

    it "runnable keeps already-done entries (that is what Run all re-sends)" do
      v = AuthorizeView.new
      done = v.add(flow)
      v.apply_result(done, target(bypass: true))
      v.runnable.map(&.id).should contain(done)
      v.pending_entries.map(&.id).should_not contain(done)
    end
  end

  describe "stop settling" do
    it "restores a stopped row to done when it already held a result" do
      v = AuthorizeView.new
      id = v.add(flow)
      v.apply_result(id, target(bypass: true)) # a previous run
      v.mark_running(Set{id})                  # Run all picked it up again
      v.settle_running(Set{id})
      # NOT :pending — the master row would read "pending" while the detail pane still drew
      # the old trials table.
      v.entry_by_id(id).not_nil!.state.should eq(:done)
    end

    it "restores a stopped row that never ran to pending" do
      v = AuthorizeView.new
      id = v.add(flow)
      v.mark_running(Set{id})
      v.settle_running(Set{id})
      v.entry_by_id(id).not_nil!.state.should eq(:pending)
    end

    it "restores a stopped row whose previous send errored to error" do
      v = AuthorizeView.new
      id = v.add(flow)
      v.apply_error(id, "connection refused")
      v.mark_running(Set{id})
      v.settle_running(Set{id})
      v.entry_by_id(id).not_nil!.state.should eq(:error)
    end

    it "leaves rows outside the batch alone" do
      v = AuthorizeView.new
      mine = v.add(flow("GET", "/a"))
      other = v.add(flow("GET", "/b"))
      v.mark_running(Set{mine, other})
      v.settle_running(Set{mine})
      v.entry_by_id(other).not_nil!.state.should eq(:running)
    end

    it "tracks the stop flag and resets it on demand" do
      v = AuthorizeView.new
      v.stop_requested?.should be_false
      v.request_stop
      v.stop_requested?.should be_true
      v.reset_stop
      v.stop_requested?.should be_false
    end
  end

  # A run summary describes THAT run. Counting queue-wide credited a three-request batch with
  # every result the queue happened to hold ("ran 6"), which a live run showed plainly.
  describe "batch-scoped counts" do
    it "counts only the batch's completed entries and bypasses" do
      v = AuthorizeView.new
      old = v.add(flow("GET", "/old"))
      fresh = v.add(flow("GET", "/fresh"))
      v.apply_result(old, target(bypass: true))   # an earlier run
      v.apply_result(fresh, target(bypass: true)) # this run

      batch = Set{fresh}
      v.completed_in(batch).should eq(1)
      v.bypasses_in(batch).should eq(1)
      # the queue-wide totals still see both
      v.completed_count.should eq(2)
      v.bypass_total.should eq(2)
    end

    it "counts nothing for a batch whose entries never produced a result" do
      v = AuthorizeView.new
      a = v.add(flow)
      v.completed_in(Set{a}).should eq(0)
      v.bypasses_in(Set{a}).should eq(0)
    end
  end

  # Changing the identity set invalidates every result already on screen: those verdicts were
  # produced under the OLD set. Without this, an operator who fixes a session cookie and
  # presses ^R is told "every request already has a result" and nothing goes out.
  describe "identity revisions" do
    it "makes a finished entry pending again when the identities change" do
      v = AuthorizeView.new
      id = v.add(flow)
      v.apply_result(id, target(bypass: false))
      v.pending_entries.should be_empty

      v.identities = [Gori::Authorize::Identity.new("new-session", set_headers: [{"Cookie", "x"}])]
      v.pending_entries.map(&.id).should eq([id])
      v.pending_count.should eq(1)
    end

    it "keeps the old verdict on screen while it waits to be re-run" do
      v = AuthorizeView.new
      id = v.add(flow)
      v.apply_result(id, target(bypass: true))
      v.identities = [Gori::Authorize::Identity.new("other")]
      # still readable — it is what those identities saw, just no longer current
      v.entry_by_id(id).not_nil!.verdict.should eq(:bypass)
      render(v)
    end

    it "does not bump the revision when the set is assigned an equal list" do
      v = AuthorizeView.new
      id = v.add(flow)
      v.apply_result(id, target(bypass: false))
      v.identities = AuthorizeView.default_identities # same content
      v.pending_entries.should be_empty
    end

    it "counts a re-run under the new set as current again" do
      v = AuthorizeView.new
      id = v.add(flow)
      v.apply_result(id, target(bypass: false))
      v.identities = [Gori::Authorize::Identity.new("other")]
      v.apply_result(id, target(bypass: false))
      v.pending_entries.should be_empty
    end
  end

  # Passive replay can be on and yet do nothing — most often because the project has no
  # scope include rule. The status line that says so is transient and the operator is usually
  # in a browser, so the tab itself has to carry the answer.
  describe "the passive note" do
    it "replaces the empty state's headline while passive is on" do
      v = AuthorizeView.new
      b = MemoryBackend.new(100, 30)
      v.render(Screen.new(b), Rect.new(0, 0, 100, 30), true)
      b.contains?("no requests queued").should be_true

      v.passive_note = "passive replay on — add a scope include rule to replay anything"
      b2 = MemoryBackend.new(100, 30)
      v.render(Screen.new(b2), Rect.new(0, 0, 100, 30), true)
      b2.contains?("add a scope include rule").should be_true
      b2.contains?("no requests queued").should be_false
    end

    it "goes back to the plain headline when passive is switched off" do
      v = AuthorizeView.new
      v.passive_note = "passive replay on — waiting for authenticated GETs"
      v.passive_note = nil
      b = MemoryBackend.new(100, 30)
      v.render(Screen.new(b), Rect.new(0, 0, 100, 30), true)
      b.contains?("no requests queued").should be_true
    end
  end

  # Review findings, each pinned where it broke.
  describe "re-run eligibility" do
    # A manual ^R is the operator asking again, and a request that raised is exactly what they
    # might want retried.
    it "still offers a raised entry to a manual run" do
      v = AuthorizeView.new
      id = v.add(flow)
      v.apply_error(id, "boom")
      v.pending_entries.map(&.id).should contain(id)
    end

    # ...but passive asks on every drain tick with nobody watching, so an entry that raises by
    # construction would be re-dispatched forever, one fiber and one Jobs row per tick.
    it "keeps a raised entry out of passive's unattended re-run" do
      v = AuthorizeView.new
      id = v.add(flow)
      v.apply_error(id, "boom")
      v.auto_pending_entries.map(&.id).should_not contain(id)
    end

    it "offers it to passive again once the identity set changes" do
      v = AuthorizeView.new
      id = v.add(flow)
      v.apply_error(id, "boom")
      v.identities = [Gori::Authorize::Identity.new("other", set_headers: [{"Cookie", "x"}])]
      v.auto_pending_entries.map(&.id).should contain(id)
    end

    it "offers a never-run entry to both" do
      v = AuthorizeView.new
      id = v.add(flow)
      v.pending_entries.map(&.id).should contain(id)
      v.auto_pending_entries.map(&.id).should contain(id)
    end
  end

  # Sandbox or an EXCLUDE rule refuses every send before the socket. Reporting that as "no
  # identity matched the baseline" claims a result for traffic that never left.
  describe "gate refusals" do
    it "reports a request whose every send the gate refused" do
      v = AuthorizeView.new
      id = v.add(flow)
      errored = Gori::Repeater::ExchangeMeta.of(nil, nil, nil, "sandbox: blocked")
      summary = Gori::Authorize::ResponseSummary.new(nil, nil, 0_u64, error: "sandbox: blocked")
      trials = [
        Gori::Authorize::Trial.new("as-captured", true, errored, Gori::Authorize::Verdict::Baseline,
          nil, summary, "req".to_slice, nil, nil),
        Gori::Authorize::Trial.new("anon", false, errored, Gori::Authorize::Verdict::Error,
          nil, summary, "req".to_slice, nil, nil),
      ]
      v.apply_result(id, Gori::Authorize::Target.new(1_i64, "GET", "https://h.test/a", trials,
        2_i64, "sandbox: blocked"))
      v.blocked_in(Set{id}).should eq(1)
      v.blocked_reason_in(Set{id}).should eq("sandbox: blocked")
    end

    it "does not call a normal run blocked" do
      v = AuthorizeView.new
      id = v.add(flow)
      v.apply_result(id, target(bypass: false))
      v.blocked_in(Set{id}).should eq(0)
      v.blocked_reason_in(Set{id}).should be_nil
    end
  end

  # `short_pane_clamp_spec` pins this for the EMPTY state; the populated view had no such
  # guard and drew a request row over the hint line on a 3-row body.
  it "never draws a request row below its pane, at any height the app supports" do
    (2..20).each do |h|
      v = AuthorizeView.new
      3.times { |i| v.add(flow("GET", "/r#{i}")) }
      margin = 6
      b = MemoryBackend.new(80, h + margin)
      v.render(Screen.new(b), Rect.new(0, 0, 80, h), true)
      (h...(h + margin)).each do |y|
        b.row(y).strip.should eq(""), "spilled onto row #{y} at 80x#{h}"
      end
    end
  end

  describe "queue editing" do
    it "removes the cursor entry and clamps the cursor" do
      v = AuthorizeView.new
      v.add(flow("GET", "/a"))
      b = v.add(flow("GET", "/b")) # cursor lands here
      v.remove_selected.should be_true
      v.size.should eq(1)
      v.entry_by_id(b).should be_nil
      v.selected_entry.not_nil!.host_path.should contain("/a")
    end

    it "refuses to remove a row that is mid-run" do
      v = AuthorizeView.new
      a = v.add(flow)
      v.mark_running(Set{a})
      v.remove_selected.should be_false
      v.size.should eq(1)
    end

    it "reports the queued flow ids for dedup" do
      v = AuthorizeView.new
      v.add(flow)
      v.queued_flow_ids.should eq(Set{1_i64})
    end
  end
end
