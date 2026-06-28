require "uri"
require "./types"
require "./inject"
require "./fingerprint"
require "./baseline"
require "../fuzz/engine"

module Gori::Miner
  # Drives a parameter-mining run: calibrate a baseline, then for each location stuff
  # candidate names into buckets, diff vs baseline, and BINARY-SEARCH each interesting
  # bucket to isolate the responsible name. Concurrency = level-synchronized BFS per
  # location: the current frontier of buckets runs concurrently through a bounded worker
  # pool, children (bisection halves) are collected, then the next frontier runs.
  #
  # Single-threaded fiber scheduler (no -Dpreview_mt): plain ivar increments and array
  # appends never yield mid-op, so the counters and per-round outcome array need no locks.
  class Engine
    MAX_CONCURRENCY = 100

    enum State : UInt8
      Running
      Paused
      Stopped
    end

    # One unit of work: test these names at this location (a bucket, or a bisection half).
    record Task, location : Location, names : Array(String)

    getter events : Channel(Event)

    @concurrency : Int32
    @state : State
    @wake : Channel(Nil)
    @report : Baseline::Report?
    @seen : Set({Location, String})
    @sent : Int64
    @found : Int32
    @errors : Int64
    @names_done : Int64
    @names_total : Int64
    @last_dispatch : Time::Instant

    def initialize(@base : Bytes, @http2 : Bool, @names : Array(String),
                   @backend : Fuzz::Backend, @config : Config)
      @concurrency = @config.concurrency.clamp(1, MAX_CONCURRENCY)
      @state = State::Running
      @wake = Channel(Nil).new(1)
      @events = Channel(Event).new(256)
      @report = nil
      @seen = Set({Location, String}).new
      @sent = 0_i64
      @found = 0
      @errors = 0_i64
      @names_done = 0_i64
      @names_total = 0_i64
      @last_dispatch = Time.instant
    end

    # The number of distinct (name × location) tests this run will perform — the stable
    # progress denominator. Computed up front (also surfaces an empty wordlist early).
    def total_names : Int64
      @config.locations.sum(0_i64) { |loc| valid_names_for(loc).size.to_i64 }
    end

    def start : Nil
      spawn(name: "miner") { orchestrate }
    end

    # Blocking drain — for synchronous consumers (CLI, the MCP background fiber).
    def run(& : Event ->) : Nil
      start
      while ev = @events.receive?
        yield ev
      end
    end

    def stop : Nil
      @state = State::Stopped
      poke
    end

    def pause : Nil
      @state = State::Paused
    end

    def resume : Nil
      @state = State::Running
      poke
    end

    def stopped? : Bool
      @state == State::Stopped
    end

    # ── orchestration ───────────────────────────────────────────────────────────────

    private def orchestrate : Nil
      @names_total = total_names
      report = Baseline.new(@backend, @base, @config).calibrate(@config.locations)
      @report = report
      @events.send(BaselineEvent.new(report.stable, report.warning))

      @config.locations.each do |loc|
        break if @state.stopped?
        frontier = initial_buckets(loc, valid_names_for(loc))
        until frontier.empty? || @state.stopped?
          frontier = run_round(frontier).flat_map { |children| children }
        end
      end
      @events.send(DoneEvent.new(snapshot, @state.stopped?))
    rescue ex
      @events.send(ErrorEvent.new(ex.message || "miner error"))
      @events.send(DoneEvent.new(snapshot, @state.stopped?))
    ensure
      @events.close
    end

    # Run one frontier concurrently; returns each task's children (next frontier).
    private def run_round(tasks : Array(Task)) : Array(Array(Task))
      outcomes = [] of Array(Task)
      return outcomes if tasks.empty?
      jobs = Channel(Task).new(@concurrency)
      finished = Channel(Nil).new(@concurrency)
      interval = pace_interval

      spawn(name: "miner-dispatch") do
        begin
          tasks.each do |task|
            break if @state.stopped?
            park_if_paused
            break if @state.stopped?
            break if (cap = @config.max_requests) && cap > 0 && @sent >= cap
            pace(interval)
            jobs.send(task)
          end
        ensure
          jobs.close
        end
      end

      @concurrency.times do |i|
        spawn(name: "miner-worker-#{i}") do
          begin
            while task = jobs.receive?
              outcomes << process_bucket(task)
            end
          ensure
            finished.send(nil)
          end
        end
      end

      @concurrency.times { finished.receive }
      outcomes
    end

    # ── the bucketing + bisection core ──────────────────────────────────────────────

    # Test one bucket; emit any findings; return the bisection children to test next.
    private def process_bucket(task : Task) : Array(Task)
      canaries = Hash(String, String).new # name => canary
      task.names.each { |n| canaries[n] = Canary.fresh }
      raw = send_with_retries(Inject.apply(@base, task.location, canaries.to_a, @config.add_content_length_when_missing?))
      @sent += 1
      if raw.error
        @errors += 1
        mark_done(task.names.size) # keep the bar monotonic; this bucket is inconclusive
        return [] of Task
      end

      probe = Fingerprint.probe(raw)
      inv = Hash(String, String).new
      canaries.each { |name, canary| inv[canary] = name }
      decision = Miner.decide(report, probe, inv, task.location)

      # Reflection is self-identifying — resolve those names with no bisection.
      decision.reflected.each_value do |name|
        confirmed = confirm(name, task.location, Evidence::Reflection, canaries[name]?)
        record_finding(confirmed) if confirmed
        mark_done(1)
      end
      remaining = task.names - decision.reflected.values

      children = [] of Task
      if decision.kind.none? || remaining.empty?
        mark_done(remaining.size) # no residual signal → these names are clean
      elsif remaining.size == 1
        confirmed = confirm(remaining[0], task.location, evidence_of(decision.kind), nil)
        record_finding(confirmed) if confirmed
        mark_done(1)
      else
        mid = remaining.size // 2
        children << Task.new(task.location, remaining[0...mid])
        children << Task.new(task.location, remaining[mid..])
      end
      children
    end

    # Re-test an isolated name alone with fresh canaries; Confirmed only if it
    # reproduces a majority of rounds AND the baseline is stable AND the location isn't
    # reflection-only. Drops a name that no longer reproduces (bucket-interaction FP).
    private def confirm(name : String, location : Location,
                        evidence : Evidence, canary : String?) : Finding?
      r = report
      rounds = @config.confirm_rounds
      if rounds <= 0
        return Finding.new(name, location, evidence, confidence_for(true, location), canary, nil, 0_i64)
      end

      hits = 0
      last_status = nil.as(Int32?)
      last_delta = 0_i64
      last_canary = canary
      rounds.times do
        c = Canary.fresh
        raw = send_with_retries(Inject.apply(@base, location, [{name, c}], @config.add_content_length_when_missing?))
        @sent += 1
        next if raw.error
        probe = Fingerprint.probe(raw)
        last_status = probe.metrics.status
        last_delta = probe.metrics.length - r.base_length
        decision = Miner.decide(r, probe, {c => name}, location)
        if matches_evidence?(decision, evidence, name)
          hits += 1
          last_canary = c if evidence.reflection?
        end
      end
      return nil if hits == 0
      Finding.new(name, location, evidence, confidence_for(hits >= (rounds + 1) // 2, location),
        last_canary, last_status, last_delta)
    end

    private def confidence_for(reproduced : Bool, location : Location) : Confidence
      r = report
      (reproduced && r.stable && !r.reflection_only[location]?) ? Confidence::Confirmed : Confidence::Tentative
    end

    private def matches_evidence?(decision : Decision, evidence : Evidence, name : String) : Bool
      if evidence.reflection?
        decision.reflected.has_value?(name)
      else
        decision.kind == diffkind_of(evidence)
      end
    end

    private def evidence_of(kind : DiffKind) : Evidence
      case kind
      in DiffKind::Status then Evidence::Status
      in DiffKind::Length then Evidence::Length
      in DiffKind::Words  then Evidence::Words
      in DiffKind::Lines  then Evidence::Lines
      in DiffKind::None   then Evidence::Length
      end
    end

    private def diffkind_of(evidence : Evidence) : DiffKind
      case evidence
      in Evidence::Reflection then DiffKind::None
      in Evidence::Status     then DiffKind::Status
      in Evidence::Length     then DiffKind::Length
      in Evidence::Words      then DiffKind::Words
      in Evidence::Lines      then DiffKind::Lines
      end
    end

    # ── buckets + name filtering ────────────────────────────────────────────────────

    private def initial_buckets(loc : Location, names : Array(String)) : Array(Task)
      cap = @config.bucket_for(loc)
      url_loc = loc.query? || loc.form?
      byte_budget = url_loc ? Inject::MAX_URL_BYTES : Int32::MAX
      buckets = [] of Task
      cur = [] of String
      cur_bytes = 0
      names.each do |n|
        # Count the ENCODED size for query/form — a name with reserved chars (e.g. "v2/x")
        # expands under URI.encode_www_form, so the raw bytesize would under-budget the URL
        # and a bucket could overflow MAX_URL_BYTES → 414. (One-time cost during bucketing.)
        nb = (url_loc ? URI.encode_www_form(n).bytesize : n.bytesize) + Canary::LEN + 2
        if !cur.empty? && (cur.size >= cap || cur_bytes + nb > byte_budget)
          buckets << Task.new(loc, cur)
          cur = [] of String
          cur_bytes = 0
        end
        cur << n
        cur_bytes += nb
      end
      buckets << Task.new(loc, cur) unless cur.empty?
      buckets
    end

    private def valid_names_for(loc : Location) : Array(String)
      case loc
      when Location::Headers then @names.select { |n| Inject.valid_header_name?(n) }
      when Location::Cookies then @names.select { |n| Inject.valid_cookie_name?(n) }
      else                        @names
      end
    end

    # ── counters / events ───────────────────────────────────────────────────────────

    private def report : Baseline::Report
      @report || raise("baseline not calibrated")
    end

    private def record_finding(finding : Finding) : Nil
      key = {finding.location, finding.name}
      return if @seen.includes?(key)
      @seen << key
      @found += 1
      @events.send(FindingEvent.new(finding)) # blocking — never drop a finding
    end

    private def mark_done(n : Int32) : Nil
      @names_done += n
      emit_progress
    end

    private def emit_progress : Nil
      ev = ProgressEvent.new(snapshot)
      select
      when @events.send(ev)
      else
      end
    end

    private def snapshot : Progress
      Progress.new(@names_total, @names_done, @sent, @found, @errors)
    end

    # ── sending / pacing ────────────────────────────────────────────────────────────

    private def send_with_retries(bytes : Bytes) : Replay::Result
      attempts = 0
      loop do
        raw = @backend.send(bytes)
        return raw if raw.error.nil? || attempts >= @config.retries
        attempts += 1
        sleep @config.retry_pause
      end
    end

    private def pace_interval : Time::Span?
      if (rps = @config.rps) && rps > 0
        (1.0 / rps).seconds
      elsif (t = @config.throttle_ms) && t > 0
        t.milliseconds
      else
        nil
      end
    end

    private def pace(interval : Time::Span?) : Nil
      if interval
        now = Time.instant
        target = @last_dispatch + interval
        sleep(target - now) if now < target
        @last_dispatch = Time.instant
      end
      sleep(rand(@config.jitter_ms).milliseconds) if @config.jitter_ms > 0
    end

    private def park_if_paused : Nil
      while @state == State::Paused
        @wake.receive
      end
    end

    private def poke : Nil
      select
      when @wake.send(nil)
      else
      end
    end
  end
end
