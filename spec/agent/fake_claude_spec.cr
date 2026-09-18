require "../spec_helper"
require "../support/fake_claude"

private FIXTURES_DIR = File.expand_path("../fixtures/agent", __DIR__)

# Reads `io` line by line off a dedicated fiber into a channel, so a test can `select` on
# the next line with a timeout instead of blocking the whole example on a child that never
# writes one — which is exactly the behaviour `:hang` is there to prove. `nil` on the
# channel means EOF, sent once, after which the fiber stops.
private def read_lines(io : IO) : Channel(String?)
  ch = Channel(String?).new(64)
  spawn do
    loop do
      line = io.gets(chomp: true)
      ch.send(line)
      break if line.nil?
    end
  rescue
    ch.send(nil)
  end
  ch
end

# One line off `ch`, bounded by `within`. The first element tells a "no line arrived in
# time" timeout (false) apart from an actual EOF (true, with a nil line) — collapsing them
# would make the ":hang stays silent" assertions indistinguishable from a flaky timeout.
private def next_line(ch : Channel(String?), within : Time::Span = 2.seconds) : {Bool, String?}
  select
  when line = ch.receive
    {true, line}
  when timeout(within)
    {false, nil}
  end
end

# `Process#wait` exactly once, off the main fiber — calling it twice is undefined once the
# first call has reaped the child, so every test goes through this single channel instead.
private def wait_status(process : Process) : Channel(Process::Status)
  ch = Channel(Process::Status).new(1)
  spawn { ch.send(process.wait) rescue nil }
  ch
end

private def wait_for(ch : Channel(Process::Status), within : Time::Span = 2.seconds) : Process::Status?
  select
  when status = ch.receive
    status
  when timeout(within)
    nil
  end
end

# Every example's child is force-killed and reaped here regardless of how the body ends —
# an assertion failure must not leak a process (a lingering `sleep 300` most of all).
private def with_process(path : String, &)
  process = Process.new(path, [] of String, input: :pipe, output: :pipe, error: :pipe, shell: false)
  wait_ch = wait_status(process)
  begin
    yield process, wait_ch
  ensure
    process.terminate(graceful: false) rescue nil
    wait_for(wait_ch, within: 1.second)
  end
end

describe FakeClaude do
  describe ":replay" do
    it "replays two_turns.ndjson as two turns, each ending in one result frame, init first" do
      fixture = File.join(FIXTURES_DIR, "two_turns.ndjson")
      FakeClaude.with_script(:replay, fixture) do |path|
        with_process(path) do |process, wait_ch|
          process.input.puts("turn one")
          process.input.puts("turn two")
          process.input.close

          out_ch = read_lines(process.output)
          lines = [] of String
          loop do
            found, line = next_line(out_ch, within: 3.seconds)
            found.should be_true
            break if line.nil?
            lines << line
          end

          result_lines = lines.select(&.includes?(%q("type":"result")))
          result_lines.size.should eq 2

          first_init = lines.index(&.includes?("\"subtype\":\"init\""))
          first_result = lines.index(&.includes?("\"type\":\"result\""))
          first_init.should_not be_nil
          first_result.should_not be_nil
          first_init.not_nil!.should be < first_result.not_nil!

          status = wait_for(wait_ch)
          status.should_not be_nil
          status.not_nil!.success?.should be_true
        end
      end
    end
  end

  describe ":replay with permission_allow.ndjson" do
    it "blocks at the control_request for its control_response, then finishes with a result" do
      fixture = File.join(FIXTURES_DIR, "permission_allow.ndjson")
      FakeClaude.with_script(:replay, fixture) do |path|
        with_process(path) do |process, _wait_ch|
          process.input.puts("turn one")

          out_ch = read_lines(process.output)
          control_request_seen = false
          loop do
            found, line = next_line(out_ch, within: 3.seconds)
            found.should be_true
            break if line.nil?
            if line.includes?(%q("type":"control_request"))
              control_request_seen = true
              break
            end
          end
          control_request_seen.should be_true

          # The script is now blocked on its OWN `read` for the control_response: no further
          # line should show up in a short window.
          found, _line = next_line(out_ch, within: 300.milliseconds)
          found.should be_false

          process.input.puts("control_response_one")

          # Stop AT the result, same as a real caller reading one turn: the script never
          # closes its own stdout mid-session, so waiting for EOF here would wait forever —
          # it is back at its own `read` for the NEXT turn, which this example never sends.
          saw_result = false
          loop do
            found2, line2 = next_line(out_ch, within: 3.seconds)
            found2.should be_true
            break if line2.nil?
            if line2.includes?(%q("type":"result"))
              saw_result = true
              break
            end
          end
          saw_result.should be_true
        end
      end
    end
  end

  describe ":replay with permission_deny.ndjson" do
    it "blocks the same way, then still finishes with a result after the deny response" do
      fixture = File.join(FIXTURES_DIR, "permission_deny.ndjson")
      FakeClaude.with_script(:replay, fixture) do |path|
        with_process(path) do |process, _wait_ch|
          process.input.puts("turn one")

          out_ch = read_lines(process.output)
          control_request_seen = false
          loop do
            found, line = next_line(out_ch, within: 3.seconds)
            found.should be_true
            break if line.nil?
            if line.includes?(%q("type":"control_request"))
              control_request_seen = true
              break
            end
          end
          control_request_seen.should be_true

          found, _line = next_line(out_ch, within: 300.milliseconds)
          found.should be_false

          process.input.puts("control_response_one")

          saw_result = false
          loop do
            found2, line2 = next_line(out_ch, within: 3.seconds)
            found2.should be_true
            break if line2.nil?
            if line2.includes?(%q("type":"result"))
              saw_result = true
              break
            end
          end
          saw_result.should be_true
        end
      end
    end
  end

  describe ":hang" do
    it "stays silent, then a TERM ends it at exit 143 within 2s — proving stop never blocks" do
      FakeClaude.with_script(:hang) do |path|
        with_process(path) do |process, wait_ch|
          process.input.puts("turn one")
          process.input.close

          out_ch = read_lines(process.output)
          found, _line = next_line(out_ch, within: 300.milliseconds)
          found.should be_false # sleeping, nothing written

          process.terminate # default graceful: true → SIGTERM, the trap this proves

          status = wait_for(wait_ch, within: 2.seconds)
          status.should_not be_nil
          status.not_nil!.exit_code?.should eq 143
        end
      end
    end
  end

  describe ":crash" do
    it "exits 1 without reading stdin, and stderr says why" do
      FakeClaude.with_script(:crash) do |path|
        with_process(path) do |process, wait_ch|
          process.input.close
          err = process.error.gets_to_end

          status = wait_for(wait_ch, within: 2.seconds)
          status.should_not be_nil
          status.not_nil!.exit_code?.should eq 1
          err.should contain "boom"
        end
      end
    end
  end

  describe ":silent_exit" do
    it "reads one turn, prints nothing, and exits 0 — a child that died mid-turn" do
      FakeClaude.with_script(:silent_exit) do |path|
        with_process(path) do |process, wait_ch|
          process.input.puts("turn one")
          process.input.close

          out_ch = read_lines(process.output)
          found, line = next_line(out_ch, within: 2.seconds)
          found.should be_true
          line.should be_nil # EOF: nothing was printed

          status = wait_for(wait_ch, within: 2.seconds)
          status.should_not be_nil
          status.not_nil!.exit_code?.should eq 0
        end
      end
    end
  end
end
