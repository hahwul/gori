require "../spec_helper"
require "socket"

private alias F = Gori::Fuzz

# Records, per accepted connection, WHEN each request on it became complete (full head plus
# any declared body), tagged `warmup?` and a monotonic sequence number shared across every
# connection. The sequence is what the warm-up-ordering spec needs — a total ORDER, not a
# wall-clock threshold, across fibers a single-threaded scheduler interleaves.
#
# `max_accepts`, when set, closes the listener after that many connections — the deterministic
# way to make a LATER dial in `Sender#send_race`'s sequential assembly loop fail, without any
# wall-clock racing.
private class RaceOrigin
  record Event, conn_id : Int32, warmup : Bool, seq : Int32, at : Time::Instant

  getter port : Int32
  getter events = [] of Event

  # `fail_warmup`, when true, drops connection 0's warm-up request (reads it, then closes
  # without answering) instead of serving it — the deterministic way to make ONE connection's
  # warm-up exchange fail without any wall-clock racing.
  def initialize(@warmup_path : String = "/warmup", @max_accepts : Int32? = nil,
                 @fail_warmup : Bool = false)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    @seq = 0
    @conn_counter = 0
    spawn { accept_loop }
  end

  def close : Nil
    @server.close rescue nil
  end

  private def accept_loop : Nil
    while conn = @server.accept?
      id = @conn_counter
      @conn_counter += 1
      spawn { serve(conn, id) }
      if (m = @max_accepts) && @conn_counter >= m
        @server.close rescue nil
        break
      end
    end
  rescue
    # server closed
  end

  private def serve(conn : TCPSocket, id : Int32) : Nil
    loop do
      head = begin
        Gori::Proxy::Codec::Http1.read_head(conn)
      rescue IO::Error
        # The race harness deliberately abandons a connection mid-request (a held-back byte
        # that never arrives, on the "too few live connections" / bad-warmup paths) — the
        # client-side close can surface here as a read error rather than a clean EOF.
        nil
      end
      break unless head
      req = Gori::Proxy::Codec::Http1.parse_request_head(head)
      if (cl = req.headers.get?("Content-Length")) && (n = cl.to_i?) && n > 0
        conn.read_fully?(Bytes.new(n))
      end
      is_warmup = req.target == @warmup_path
      break if is_warmup && @fail_warmup && id == 0 # drop it — no response, connection dies here
      events << Event.new(id, is_warmup, @seq, Time.instant)
      @seq += 1
      body = "ok"
      conn << "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n" << body
      conn.flush
    end
  ensure
    conn.close rescue nil
  end
end

private RACE_REQ = "GET /race HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice

private def race_jobs(n : Int32, bytes : Bytes = RACE_REQ) : Array(F::Job)
  Array.new(n) { |i| F::Job.new(i.to_i64, [] of String, nil, bytes) }
end

private def race_sender(origin : RaceOrigin, timeout : Time::Span? = nil) : F::Sender
  F::Sender.new(F::Origin.new("http", "127.0.0.1", origin.port), ungated_outbound,
    http2: false, verify: false, timeout: timeout)
end

describe "Fuzz::Sender#send_race" do
  it "holds every connection's warm-up ahead of every connection's race request" do
    origin = RaceOrigin.new
    n = 6
    warmup = "GET /warmup HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice
    results = race_sender(origin).send_race(race_jobs(n), warmup: warmup)

    results.size.should eq(n)
    results.all? { |r| r.error.nil? }.should be_true
    warmup_seqs = origin.events.select(&.warmup).map(&.seq)
    race_seqs = origin.events.reject(&.warmup).map(&.seq)
    warmup_seqs.size.should eq(n)
    race_seqs.size.should eq(n)
    # A total order, not a timing threshold: EVERY warm-up completed before ANY race request
    # did, because the release barrier (Sender#send_race's assembly loop) does not begin
    # releasing a single held-back byte until every connection has reached it.
    warmup_seqs.max.should be < race_seqs.min
    origin.close
  end

  it "sends exactly one request per connection when no warm-up is configured" do
    origin = RaceOrigin.new
    n = 4
    race_sender(origin).send_race(race_jobs(n))
    origin.events.size.should eq(n)
    origin.events.none?(&.warmup).should be_true
    origin.close
  end

  it "excludes a connection that fails to dial, and still races the rest" do
    origin = RaceOrigin.new(max_accepts: 4)
    n = 5
    results = race_sender(origin).send_race(race_jobs(n))

    results.size.should eq(n)
    results.count { |r| r.error.nil? }.should eq(4)
    dial_failed = results.select { |r| r.error.try(&.starts_with?("race: dial failed")) }
    dial_failed.size.should eq(1)
    origin.close
  end

  it "refuses the whole group, without releasing, when fewer than 2 connections survive assembly" do
    origin = RaceOrigin.new(max_accepts: 1)
    n = 3
    results = race_sender(origin).send_race(race_jobs(n))

    results.size.should eq(n)
    results.none?(&.error.nil?).should be_true # nothing raced — every slot is an error
    # The ONE connection that DID assemble reports the group-level refusal; the other two
    # never got a connection at all, and keep their own specific dial-failure reason.
    results.count { |r| r.error.try(&.includes?("could not assemble enough live connections")) }.should eq(1)
    results.count { |r| r.error.try(&.starts_with?("race: dial failed")) }.should eq(2)
    # The one connection that DID dial only ever received the held-back head — the release
    # (final byte) was never written, so no complete request reached the origin at all.
    origin.events.size.should eq(0)
    origin.close
  end

  it "retires a connection whose warm-up gets no response, without corrupting the rest" do
    # Connection 0's warm-up is read and then dropped (no response) — that connection must be
    # excluded rather than have the race request written onto a socket with no framing to
    # trust, and the OTHER connections must still race normally.
    origin = RaceOrigin.new(fail_warmup: true)
    n = 3
    warmup = "GET /warmup HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_slice
    results = race_sender(origin).send_race(race_jobs(n), warmup: warmup)

    results.size.should eq(n)
    results.count { |r| r.error.try(&.starts_with?("race: warmup failed")) }.should eq(1)
    results.count(&.error.nil?).should eq(2)
    origin.close
  end

  it "reaches the real synchronized path through a CappedBackend wrapper, not the degraded default" do
    # `race: dial failed` is a string ONLY `Sender#send_race`'s own dial loop produces.
    # `Backend`'s inherited default (what a MISSING `CappedBackend#send_race` override would
    # silently fall back to) degrades to N independent `send()` calls, whose error text on a
    # dial failure carries no such prefix — so this assertion fails loudly if that override
    # is ever accidentally removed, without depending on any timing measurement.
    origin = RaceOrigin.new(max_accepts: 3)
    n = 4
    capped = F::CappedBackend.new(race_sender(origin), nil)
    results = capped.send_race(race_jobs(n))

    results.size.should eq(n)
    results.count { |r| r.error.try(&.starts_with?("race: dial failed")) }.should eq(1)
    results.count { |r| r.error.nil? }.should eq(3)
    capped.sent.should eq(n)
    origin.close
  end
end

describe "Fuzz::Engine race_count" do
  it "emits exactly N ResultEvents, index 0..N-1, and a DoneEvent reporting them all sent" do
    origin = RaceOrigin.new
    n = 6
    tmpl = F::Template.parse(String.new(RACE_REQ))
    cfg = F::Config.new(race_count: n, timeout: 2.seconds)
    sender = race_sender(origin, timeout: 2.seconds)
    engine = F::Engine.new(F::Generator.new(tmpl, [] of F::PayloadSet, cfg), F::Matcher.new, sender, cfg)
    results = [] of F::Result
    done = nil.as(F::DoneEvent?)
    engine.run do |ev|
      results << ev.result if ev.is_a?(F::ResultEvent)
      done = ev if ev.is_a?(F::DoneEvent)
    end

    results.size.should eq(n)
    results.map(&.index).sort!.should eq((0...n).to_a.map(&.to_i64))
    results.all? { |r| r.status == 200 }.should be_true
    ev = done.should_not be_nil
    ev.progress.sent.should eq(n)
    ev.progress.total.should eq(n)
    origin.close
  end

  # `spec/fuzz/conn_pool_spec.cr` already documents (see its own `--concurrency > 1`
  # comment) that an in-process, single-fiber-accept test origin can drop connections
  # under real N-way concurrency and was deliberately never driven past that here — "measured
  # out-of-process instead... recording it so nobody re-adds a spec that reproduces the
  # harness, not the code." The SAME limitation applies to a live ordinary-`--concurrency`
  # baseline for comparison: `send_race`'s own assembly dials one connection at a time (never
  # stresses the harness this way, which is exactly why ITS spread is asserted directly
  # below), but firing N ordinary Fuzz::Engine workers at this harness at once is the one
  # shape it cannot be trusted to measure reliably. Measured by hand instead, against a real
  # target (`crystal build src/main.cr`, then `gori run fuzz --race=8` vs a plain
  # `--concurrency=8` sweep against a local HTTP server): the race group's requests land
  # within tens of microseconds of each other; the ordinary sweep's spread was consistently
  # in the low milliseconds — the two to three orders of magnitude this feature exists to buy.
  it "achieves a tight absolute release spread" do
    n = 8
    origin = RaceOrigin.new
    cfg = F::Config.new(race_count: n, timeout: 2.seconds)
    sender = race_sender(origin, timeout: 2.seconds)
    tmpl = F::Template.parse(String.new(RACE_REQ))
    engine = F::Engine.new(F::Generator.new(tmpl, [] of F::PayloadSet, cfg), F::Matcher.new, sender, cfg)
    engine.run { }
    times = origin.events.map(&.at)
    origin.close

    times.size.should eq(n)
    spread = (times.max - times.min).total_microseconds
    spread.should be < 100_000 # 100ms — generous for a localhost run under CI load
  end
end
