require "uri"
require "./types"
require "./inject"
require "./fingerprint"
require "./baseline"
require "../fuzz/engine"

module Gori::Miner
  # The hard-cap wrapper (baseline calibration + bucket probes + confirmation rounds all
  # count against `--max-requests`) lives with the send seam it wraps: Fuzz::CappedBackend.

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

    # Per-request growth ceiling for the Json location. A JSON candidate is injected into EVERY
    # object node, so a deeply-nested body could otherwise balloon one request to megabytes; this
    # shrinks Json buckets (in initial_buckets) instead. A single-object body (node count 1) is
    # unaffected and buckets exactly as before.
    MAX_JSON_INJECT_BYTES = 128 * 1024

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
    @backend : Fuzz::CappedBackend
    @report : Baseline::Report?
    @seen : Set({Location, String})
    @found : Int32
    @errors : Int64
    @names_done : Int64
    @names_total : Int64
    @last_dispatch : Time::Instant

    def initialize(@base : Bytes, @http2 : Bool, @names : Array(String),
                   backend : Fuzz::Backend, @config : Config)
      # Wrap the backend so max_requests is enforced at every real send (baseline,
      # bucket, and confirm), not just as a racy pre-dispatch check.
      @backend = Fuzz::CappedBackend.new(backend, @config.max_requests)
      @concurrency = @config.concurrency.clamp(1, MAX_CONCURRENCY)
      @state = State::Running
      @wake = Channel(Nil).new(1)
      @events = Channel(Event).new(256)
      @report = nil
      @seen = Set({Location, String}).new
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
      # Never spawn more workers than there are tasks: the tail bisection/isolation rounds carry
      # 1–2 tasks, so a fixed pool of @concurrency (up to 100) would spawn dozens of fibers that
      # only see the closed channel and exit. Capping keeps full parallelism with no idle churn.
      workers = {@concurrency, tasks.size}.min
      jobs = Channel(Task).new(workers)
      finished = Channel(Nil).new(workers)
      interval = pace_interval

      spawn(name: "miner-dispatch") do
        begin
          tasks.each do |task|
            break if @state.stopped?
            park_if_paused
            break if @state.stopped?
            # Early-out once the hard cap is hit — the CappedBackend also refuses any
            # send that slips past this racy check, so the network count never exceeds it.
            break if @backend.cap_reached?
            pace(interval)
            jobs.send(task)
          end
        ensure
          jobs.close
        end
      end

      workers.times do |i|
        spawn(name: "miner-worker-#{i}") do
          begin
            while task = jobs.receive?
              next if @state.stopped? # drain buffered tasks without sending on stop
              outcomes << process_bucket(task)
            end
          ensure
            finished.send(nil)
          end
        end
      end

      workers.times { finished.receive }
      outcomes
    end

    # ── the bucketing + bisection core ──────────────────────────────────────────────

    # Test one bucket; emit any findings; return the bisection children to test next.
    private def process_bucket(task : Task) : Array(Task)
      # One {name, canary} pair per candidate — the SAME array feeds the injector and the
      # detector (decide), so no per-bucket name→canary / canary→name hashes are built.
      pairs = task.names.map { |n| {n, Canary.fresh} }
      raw = send_with_retries(Inject.apply(@base, task.location, pairs, @config.add_content_length_when_missing?))
      if raw.error
        @errors += 1
        mark_done(task.names.size) # keep the bar monotonic; this bucket is inconclusive
        return [] of Task
      end

      probe = Fingerprint.probe(raw)
      decision = Miner.decide(report, probe, pairs, task.location)

      # Reflection is self-identifying — resolve those names with no bisection. `reflected`
      # maps canary → name, so the confirming canary is in hand without a name→canary lookup.
      decision.reflected.each do |canary, name|
        confirmed = confirm(name, task.location, Evidence::Reflection, canary)
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

      # Once `majority` matching rounds land, `reproduced` is locked true and no further round
      # can change the verdict — so stop re-sending. Saves the tail confirm requests for every
      # finding whose signal reproduces early (the common case, e.g. confirm_rounds=2 → 1 round);
      # the classification is identical, and a run that never reaches majority still runs them all.
      majority = (rounds + 1) // 2
      hits = 0
      last_status = nil.as(Int32?)
      last_delta = 0_i64
      last_canary = canary
      rounds.times do
        c = Canary.fresh
        raw = send_with_retries(Inject.apply(@base, location, [{name, c}], @config.add_content_length_when_missing?))
        next if raw.error
        probe = Fingerprint.probe(raw)
        decision = Miner.decide(r, probe, [{name, c}], location)
        if matches_evidence?(decision, evidence, name)
          hits += 1
          # Only record status/delta from a round that actually reproduced the signal, so a
          # Confirmed finding's reported evidence can't come from a non-matching (flaky) round.
          last_status = probe.metrics.status
          last_delta = probe.metrics.length - r.base_length
          last_canary = c if evidence.reflection?
          break if hits >= majority
        end
      end
      return nil if hits == 0
      Finding.new(name, location, evidence, confidence_for(hits >= majority, location),
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
      # JSON injects each candidate into EVERY object node, so a name's real byte cost is the
      # per-name cost × node count. Derive the count ONCE from @base (fixed → the node set never
      # varies with bucket size, so bisection/confirm stay valid) and bound per-request growth.
      json_nodes = loc.json? ? {Inject.json_object_node_count(Inject.split(@base)[1], Inject::MAX_JSON_NODES), 1}.max : 1
      byte_budget = if url_loc
                      Inject::MAX_URL_BYTES
                    elsif loc.json?
                      MAX_JSON_INJECT_BYTES
                    else
                      Int32::MAX
                    end
      buckets = [] of Task
      cur = [] of String
      cur_bytes = 0
      names.each do |n|
        # Count the ENCODED size for query/form — a name with reserved chars (e.g. "v2/x")
        # expands under URI.encode_www_form, so the raw bytesize would under-budget the URL
        # and a bucket could overflow MAX_URL_BYTES → 414. For Json, multiply by the node count.
        # (One-time cost during bucketing.)
        nb = ((url_loc ? URI.encode_www_form(n).bytesize : n.bytesize) + Canary::LEN + 2) * (loc.json? ? json_nodes : 1)
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
      when Location::Headers   then @names.select { |n| Inject.valid_header_name?(n) }
      when Location::Cookies   then @names.select { |n| Inject.valid_cookie_name?(n) }
      when Location::Multipart then @names.select { |n| Inject.valid_multipart_name?(n) }
      else                          @names
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
      Progress.new(@names_total, @names_done, @backend.sent, @found, @errors)
    end

    # ── sending / pacing ────────────────────────────────────────────────────────────

    private def send_with_retries(bytes : Bytes) : Repeater::Result
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
