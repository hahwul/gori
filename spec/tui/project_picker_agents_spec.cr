require "../spec_helper"

include Gori::Tui

# The project-picker half of agent presence (#815). The picker owns a live Termisu and cannot
# be built in a spec, so the composition rule lives in class methods (`meta_segments`,
# `agent_chip`) that are pinned here — the same shape ProjectMarks uses for the delete set.
describe "ProjectPicker.agent_chip" do
  it "is empty, singular, or a ×count" do
    ProjectPicker.agent_chip(0).should eq("")
    ProjectPicker.agent_chip(1).should eq("mcp")
    ProjectPicker.agent_chip(2).should eq("mcp×2")
    ProjectPicker.agent_chip(5).should eq("mcp×5")
  end
end

describe "ProjectPicker.meta_segments" do
  it "is byte-identical to the old single-segment meta when no agent is attached" do
    # The guarantee that a picker with no MCP clients renders exactly as it always did: one
    # segment, the idle time, in muted.
    ProjectPicker.meta_segments(false, nil, 0, "3m ago").should eq([{"3m ago", Theme.muted}])
  end

  it "keeps the capture chip as the sole segment when capturing and no agent" do
    status = Gori::CaptureStatus::Status.new("127.0.0.1", 8070, true)
    segs = ProjectPicker.meta_segments(true, status, 0, "3m ago")
    segs.size.should eq(1)
    segs[0][1].should eq(Theme.green)
    segs[0][0].should contain(":8070") # format_endpoint renders the host (127.0.0.1 → localhost)
  end

  it "leads with an accent mcp segment, keeping the right segment unchanged" do
    idle = ProjectPicker.meta_segments(false, nil, 1, "3m ago")
    idle.should eq([{"mcp", Theme.accent}, {"3m ago", Theme.muted}])

    # The capture chip keeps its exact bytes and colour; the mcp segment is simply prepended.
    status = Gori::CaptureStatus::Status.new("127.0.0.1", 8070, true)
    capturing = ProjectPicker.meta_segments(true, status, 2, "3m ago")
    capturing.size.should eq(2)
    capturing[0].should eq({"mcp×2", Theme.accent})
    capturing[1].should eq(ProjectPicker.meta_segments(true, status, 0, "3m ago")[0])
  end

  it "preserves the paused-capture segment beside the mcp chip" do
    status = Gori::CaptureStatus::Status.new("127.0.0.1", 8070, false)
    segs = ProjectPicker.meta_segments(true, status, 1, "3m ago")
    segs[0].should eq({"mcp", Theme.accent})
    segs[1][1].should eq(Theme.yellow)
    segs[1][0].should contain("off")
  end
end
