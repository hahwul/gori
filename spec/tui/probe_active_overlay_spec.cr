require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def tmp_store(&)
  path = File.tempname("gori-pao", ".db")
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

private def flow(store, method, target) : Gori::Store::FlowDetail
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: "h.test", port: 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: h.test\r\n\r\n".to_slice, body: nil))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, content_type: "text/html"))
  store.get_flow(id).not_nil!
end

private def est(id : String) : Gori::Probe::Analyzer::ActiveEstimate
  info = Gori::Probe::RuleInfo.new(id, id, "desc", Gori::Probe::Category::ACTIVE)
  Gori::Probe::Analyzer::ActiveEstimate.new(info, 1..1)
end

describe Gori::Tui::ProbeActiveOverlay do
  it "hides the unsafe row when safe and unsafe estimates match (GET flow)" do
    tmp_store do |store|
      d = flow(store, "GET", "/s?q=1")
      same = [est("reflected_param")]
      ov = ProbeActiveOverlay.new(d, same, same)
      # rows: [0]=notify, [1]=run — no unsafe opt-in offered.
      ov.on_run_row?.should be_true # starts on Run
      ov.allow_unsafe?.should be_false
      ov.estimate_empty?.should be_false
      ov.move(-1) # notify row
      ov.on_run_row?.should be_false
      ov.move(-1) # clamped — there is no unsafe row to land on
      ov.on_run_row?.should be_false
    end
  end

  it "offers an off-by-default unsafe opt-in for an unsafe-method flow (POST)" do
    tmp_store do |store|
      d = flow(store, "POST", "/submit?q=1")
      safe = [] of Gori::Probe::Analyzer::ActiveEstimate # nothing runs safe-only on a POST
      unsafe = [est("reflected_param")]                  # the opt-in surfaces the reflected-param check
      ov = ProbeActiveOverlay.new(d, safe, unsafe)

      # Default: opt-in OFF, so the safe (empty) estimate is selected → nothing to send.
      ov.allow_unsafe?.should be_false
      ov.estimate_empty?.should be_true

      # rows: [0]=notify, [1]=unsafe, [2]=run. Move onto the unsafe row and flip it on.
      ov.move(-1) # from Run(2) → unsafe(1)
      ov.toggle
      ov.allow_unsafe?.should be_true
      ov.estimate_empty?.should be_false # the widened estimate now has a check to send
      ov.total_label.should eq("1 request")

      # ‹/› also toggles it back off.
      ov.adjust(-1)
      ov.allow_unsafe?.should be_false
    end
  end

  it "renders without crashing and hit-tests all three rows for a POST flow" do
    tmp_store do |store|
      d = flow(store, "POST", "/submit?q=1")
      ov = ProbeActiveOverlay.new(d, [] of Gori::Probe::Analyzer::ActiveEstimate, [est("reflected_param")])
      screen = Screen.new(MemoryBackend.new(80, 24))
      area = Rect.new(0, 0, 80, 24)
      ov.render(screen, area)
      box = ov.overlay_box(area).not_nil!
      # notify + unsafe + run are all hit-testable (row_at maps their y bands to 0/1/2).
      rows = (box.y...box.bottom).compact_map { |y| ov.row_at(box, box.x + 3, y) }.uniq!.sort!
      rows.should eq([0, 1, 2])
    end
  end
end
