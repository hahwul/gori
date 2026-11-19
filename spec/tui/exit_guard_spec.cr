require "../spec_helper"

private class ExitCommitProbe
  property? saved = true
  getter calls = 0

  def commit : Bool
    @calls += 1
    @saved
  end

  def save_all : Bool
    commit
  end

  def commit_on_exit : Bool
    commit
  end
end

private class SaveExitHarness
  include Gori::Tui::ExitGuard

  getter outcome = :running
  getter? quit_armed = true
  getter? stopped = false
  getter errors = [] of String
  property discard : Proc(Nil)?
  {% for name in %w[notes project repeater fuzzer miner sequencer issues decoder rewriter] %}
    getter {{ name.id }}_controller = ExitCommitProbe.new
  {% end %}

  def exit_to(outcome : Symbol) : Nil
    finish_exit(outcome)
  end

  private def stop_all_jobs : Nil
    @stopped = true
  end

  def confirm(title : String, message : String, *, confirm_label : String, danger : Bool, &action : -> Nil) : Nil
    @discard = action
  end

  def status(message : String, kind : Symbol) : Nil
    @errors << message if kind == :error
  end
end

describe Gori::Tui::ExitGuard do
  it "keeps both exit paths open on a failed save, then exits after retry succeeds" do
    [:quit, :back].each do |outcome|
      shell = SaveExitHarness.new
      shell.notes_controller.saved = false
      shell.exit_to(outcome)
      shell.outcome.should eq(:running)
      shell.stopped?.should be_false
      shell.quit_armed?.should be_false
      shell.errors.last.should contain("Notes")
      shell.rewriter_controller.calls.should eq(1)
      shell.notes_controller.saved = true
      shell.exit_to(outcome)
      shell.outcome.should eq(outcome)
    end
  end

  it "reports every failed editor and still tries all saves" do
    shell = SaveExitHarness.new
    shell.notes_controller.saved = false
    shell.decoder_controller.saved = false
    shell.exit_to(:quit)
    shell.outcome.should eq(:running)
    shell.errors.last.should contain("Notes, Decoder")
    shell.rewriter_controller.calls.should eq(1)
  end

  it "allows either exit when all saves succeed" do
    [:quit, :back].each do |outcome|
      shell = SaveExitHarness.new
      shell.exit_to(outcome)
      shell.outcome.should eq(outcome)
      shell.errors.should be_empty
    end
  end
end

describe "explicit discard after a refused exit" do
  it "stops jobs and exits only when the operator accepts discarding the failed buffers" do
    [:quit, :back].each do |outcome|
      shell = SaveExitHarness.new
      shell.notes_controller.saved = false
      shell.exit_to(outcome)
      shell.outcome.should eq(:running)
      shell.stopped?.should be_false
      shell.discard.not_nil!.call
      shell.outcome.should eq(outcome)
      shell.stopped?.should be_true
    end
  end
end
