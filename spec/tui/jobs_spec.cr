require "../spec_helper"

include Gori::Tui

describe Gori::Tui::Jobs do
  it "tracks an active job and labels the activity chip" do
    jobs = Jobs.new
    id = jobs.start(:miner, "GET /api")
    jobs.any_active?.should be_true
    jobs.active.size.should eq(1)
    jobs.activity_label.should eq("mining 1")

    jobs.progress(id, 10, 100, "2 found")
    jobs.active.first.note.should eq("2 found")

    jobs.finish(id, :done, "3 found")
    jobs.any_active?.should be_false
    jobs.activity_label.should be_nil
  end

  it "collapses mixed kinds to a generic jobs:N label" do
    jobs = Jobs.new
    jobs.start(:miner, "a")
    jobs.start(:scan, "b")
    jobs.activity_label.should eq("jobs:2")
  end
end

describe Gori::Tui::Notifications do
  it "pushes notes, counts unread, and marks them read" do
    n = Notifications.new
    n.empty?.should be_true
    n.push(:success, "Miner: 3 params found", Jobs::Goto.new(:miner, 7_i64))
    n.push(:error, "Miner: failed")
    n.unread.should eq(2)
    # newest-first
    n.all.first.message.should eq("Miner: failed")
    n.all.last.message.should eq("Miner: 3 params found")
    n.all.last.goto.try(&.session_id).should eq(7_i64)

    n.mark_all_read
    n.unread.should eq(0)
    n.clear
    n.empty?.should be_true
  end

  it "rings the buffer at the cap" do
    n = Notifications.new
    (Notifications::CAP + 10).times { |i| n.push(:info, "m#{i}") }
    n.all.size.should eq(Notifications::CAP)
    # the oldest were dropped; the newest survives at the front
    n.all.first.message.should eq("m#{Notifications::CAP + 9}")
  end
end
