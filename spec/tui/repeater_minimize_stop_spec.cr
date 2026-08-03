require "../spec_helper"

# `Repeater::Minimize` had no stop seam.
#
# `RepeaterController#stop_all` (leave project / quit) and `#close_repeater_tab` (^W) both did
# only `jobs.finish(...)`: the bottom-bar spinner and the run row disappeared and the
# leave-confirm reported the job stopped, while the background fiber kept issuing probes at the
# origin up to `Minimize::SEND_CAP` (250). The comment on `stop_all` conceded it —
# "Minimize has no `request_stop` seam (it is a capped, bounded probe run …), so finishing the
# job is the whole treatment here" — and that reasoning is what the fix rejects: a cap bounds a
# run, it does not end one, and a pentest tool must not keep talking to a target its operator
# believes it has disconnected from.
#
# `Minimize::Stop` is that seam, on the shape of `DiscoverRun#request_stop` → `Engine#stop`.
# It is checked immediately BEFORE every send, in both phases of the run.
#
# These examples drive the engine directly — no Host, no socket — because the engine is where
# the stop has to be OBSERVED. The controller's two call sites are asserted in
# repeater_refusal_inline_spec.cr, which already stands up a Host + Session.

# A `Fuzz::Backend` that counts calls and answers with one frozen response, so calibration
# succeeds, every variant reads as "unchanged", and every candidate would be removed if the run
# were allowed to walk all of them. `on_send` runs after the count, which is how an example
# stops the run from inside a specific send.
private class CountingBackend < Gori::Fuzz::Backend
  getter sends = 0

  def initialize(&@on_send : Int32 -> Nil)
  end

  def origin : Gori::Fuzz::Origin
    Gori::Fuzz::Origin.new("http", "127.0.0.1", 8080)
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    @sends += 1
    @on_send.call(@sends)
    Gori::Repeater::Result.new(
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\n".to_slice,
      "hello".to_slice, nil, 1_i64)
  end
end

# Twelve removable headers + eight query params = twenty candidates, so an unstopped run makes
# CALIBRATION_ROUNDS + 20 = 23 sends and the difference a stop makes is unmistakable.
private NOISY_REQUEST = String.build do |io|
  io << "GET /search?a=1&b=2&c=3&d=4&e=5&f=6&g=7&h=8 HTTP/1.1\n"
  io << "Host: example.test\n"
  %w(accept accept-encoding accept-language accept-charset user-agent referer
    origin dnt sec-gpc upgrade-insecure-requests cache-control pragma).each do |h|
    io << h << ": x\n"
  end
  io << "\n"
end

private def run_minimize(backend : Gori::Fuzz::Backend, stop : Gori::Repeater::Minimize::Stop?)
  Gori::Repeater::Minimize.run(NOISY_REQUEST,
    auto_cl: true,
    resolve: ->(t : String) { t.to_slice },
    backend: backend,
    stop: stop) { }
end

describe Gori::Repeater::Minimize::Stop do
  it "leaves a run that is never stopped exactly as it was — 3 calibration rounds + one send per candidate" do
    # The control. Without it, "the stopped run made 6 sends" proves nothing about a run that
    # would have made 6 anyway.
    backend = CountingBackend.new { }
    report = run_minimize(backend, Gori::Repeater::Minimize::Stop.new)
    backend.sends.should eq(Gori::Repeater::Minimize::CALIBRATION_ROUNDS + 20)
    report.removed.size.should eq(20)
    report.aborted.should be_false
  end

  it "stops issuing probes at the origin once the token is stopped mid-run" do
    stop = Gori::Repeater::Minimize::Stop.new
    # Stop on the 5th send: 3 calibration rounds + 1 probe have gone out, so the run is well
    # inside the candidate loop with 19 candidates still to try.
    backend = CountingBackend.new { |n| stop.stop if n == 5 }
    report = run_minimize(backend, stop)

    # THE assertion: the run ends here instead of walking the rest of the candidates. Five, not
    # 23 — and, in the shape this reproduces, not the 250 of SEND_CAP.
    backend.sends.should eq(5)
    # The stop cannot cancel a send already on the socket, so "one more may complete" is the
    # documented boundary — never a further one after that.
    report.sends.should eq(5)
    report.note.should contain("stopped")
    report.note.should contain("5 sends")
  end

  it "keeps the removals it already verified, exactly as the send cap does" do
    stop = Gori::Repeater::Minimize::Stop.new
    backend = CountingBackend.new { |n| stop.stop if n == 6 }
    report = run_minimize(backend, stop)

    # 3 calibration + 3 probes, each of which came back unchanged → 3 verified removals. They
    # are kept, and `aborted` is false: every one was individually checked against the frozen
    # baseline, so a partial stop is exactly as sound as a partial cap.
    report.removed.size.should eq(3)
    report.aborted.should be_false
    report.minimized_text.should_not eq(NOISY_REQUEST)
    # …and the removals really are gone from the text it hands back.
    report.removed.each { |r| report.minimized_text.should_not contain("#{r.label}:") }
  end

  it "reports an untouched request when the stop lands before the baseline is calibrated" do
    stop = Gori::Repeater::Minimize::Stop.new
    backend = CountingBackend.new { |n| stop.stop if n == 1 }
    report = run_minimize(backend, stop)

    # Calibration breaks out, and there is no verified removal to keep — so the request is
    # untouched and `aborted` says so, the same shape as an unreachable baseline.
    backend.sends.should eq(1)
    report.removed.should be_empty
    report.aborted.should be_true
    report.minimized_text.should eq(NOISY_REQUEST)
    report.note.should contain("stopped before the baseline")
  end

  it "is optional — a surface with no way to cancel still runs unchanged" do
    # The CLI and MCP minimize paths pass no `stop:`; a nil token must never look stopped.
    backend = CountingBackend.new { }
    report = run_minimize(backend, nil)
    backend.sends.should eq(Gori::Repeater::Minimize::CALIBRATION_ROUNDS + 20)
    report.aborted.should be_false
  end

  it "starts unstopped and latches once stopped" do
    stop = Gori::Repeater::Minimize::Stop.new
    stop.stopped?.should be_false
    stop.stop
    stop.stopped?.should be_true
    stop.stop # idempotent — close_repeater_tab and stop_all can both fire on one run
    stop.stopped?.should be_true
  end
end
