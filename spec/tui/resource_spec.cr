require "../spec_helper"

include Gori::Tui

# Runs `block` with the resource meter forced on/off, restoring the previous setting.
private def with_meter(enabled : Bool, &)
  prev = Gori::Settings.resource_meter?
  Gori::Settings.resource_meter = enabled
  begin
    yield
  ensure
    Gori::Settings.resource_meter = prev
  end
end

describe Gori::Tui::ResourceMeter do
  it "samples nothing while disabled" do
    with_meter(false) do
      m = ResourceMeter.new
      m.tick(Time.instant).should be_false
      m.label.should be_nil
    end
  end

  it "produces a CPU/MEM label on the first tick" do
    with_meter(true) do
      m = ResourceMeter.new
      m.tick(Time.instant).should be_true
      label = m.label
      label.should_not be_nil
      # Unpadded integer percent (one space after CPU, always), then a rounded MiB/GiB
      # memory figure.
      label.not_nil!.should match(/\ACPU \d{1,3}% MEM \d+(\.\d)?[MG]\z/)
    end
  end

  it "reports 0% on the first tick rather than a lifetime average" do
    with_meter(true) do
      m = ResourceMeter.new
      m.tick(Time.instant)
      # No previous sample to difference against, so the window is undefined → 0%, not a
      # startup spike computed from process-lifetime CPU.
      m.label.not_nil!.should start_with("CPU 0%")
    end
  end

  it "does not re-sample before the interval elapses" do
    with_meter(true) do
      m = ResourceMeter.new
      t0 = Time.instant
      m.tick(t0).should be_true
      m.tick(t0 + ResourceMeter::INTERVAL - 1.millisecond).should be_false
    end
  end

  # The idle-zero-CPU invariant: a re-sample must only report `dirty` when the string the
  # status bar actually draws has changed, so a parked gori never repaints on a timer.
  it "reports a change only when the rendered string differs" do
    with_meter(true) do
      m = ResourceMeter.new
      t0 = Time.instant
      m.tick(t0)
      before = m.label
      changed = m.tick(t0 + ResourceMeter::INTERVAL)
      changed.should eq(before != m.label)
    end
  end

  it "drops the label once on the disable edge, then stays quiet" do
    m = ResourceMeter.new
    with_meter(true) { m.tick(Time.instant).should be_true }
    with_meter(false) do
      m.tick(Time.instant).should be_true # the edge itself clears the chip
      m.label.should be_nil
      m.tick(Time.instant).should be_false # …and nothing after it
    end
  end

  # Re-enabling must measure a fresh window, not average across the disabled stretch —
  # otherwise the meter reads as a phantom spike the moment it comes back.
  it "restarts the CPU baseline after a disable/re-enable cycle" do
    m = ResourceMeter.new
    t0 = Time.instant
    with_meter(true) { m.tick(t0) }
    with_meter(false) { m.tick(t0 + 1.second) }
    with_meter(true) do
      m.tick(t0 + 1.hour).should be_true
      m.label.not_nil!.should start_with("CPU 0%")
    end
  end
end
