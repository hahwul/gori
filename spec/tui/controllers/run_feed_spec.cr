require "../../spec_helper"

include Gori::Tui

describe RunFeed do
  describe "#deliver" do
    it "blocks on a full channel while attached, and delivers once the reader takes a slot" do
      feed = RunFeed.new
      ch = Channel(Int32).new(1)
      feed.deliver(ch, 1).should be_true
      result = Channel(Bool).new(1)
      spawn { result.send(feed.deliver(ch, 2)) }
      Fiber.yield
      select
      when result.receive
        fail("a delivery to a full channel returned before the reader took one")
      else
      end
      ch.receive.should eq(1)
      result.receive.should be_true
      ch.receive.should eq(2)
    end

    it "wakes a sender parked on a full channel with false when detached" do
      feed = RunFeed.new
      ch = Channel(Int32).new(1)
      feed.deliver(ch, 1)
      result = Channel(Bool).new(1)
      spawn { result.send(feed.deliver(ch, 2)) }
      Fiber.yield
      feed.detach
      result.receive.should be_false
      ch.receive.should eq(1)
      select
      when v = ch.receive
        fail("the woken delivery still enqueued #{v}")
      else
      end
    end

    it "returns false at once and enqueues nothing once detached" do
      feed = RunFeed.new
      ch = Channel(Int32).new(4)
      feed.detach
      feed.detach # idempotent: stop_all may run twice
      feed.detached?.should be_true
      feed.deliver(ch, 1).should be_false
      select
      when ch.receive
        fail("a detached delivery was enqueued")
      else
      end
    end
  end

  describe "#offer" do
    it "drops a value the full channel has no room for" do
      feed = RunFeed.new
      ch = Channel(Int32).new(1)
      feed.offer(ch, 1)
      feed.offer(ch, 2)
      ch.receive.should eq(1)
      select
      when v = ch.receive
        fail("an offer to a full channel was kept: #{v}")
      else
      end
    end

    it "enqueues nothing once detached" do
      feed = RunFeed.new
      ch = Channel(Int32).new(4)
      feed.detach
      feed.offer(ch, 1)
      select
      when ch.receive
        fail("a detached offer was enqueued")
      else
      end
    end
  end
end
