module Gori::Fuzz
  # Streams concrete `Job`s for a template + payload sets under one attack mode.
  # Block-based and lazy — it never materializes the cross product, so a cluster bomb
  # of billions of requests costs O(1) memory. Set contract:
  #   Sniper / BatteringRam → exactly 1 shared set.
  #   Pitchfork / ClusterBomb → one set per position (set[i] → position i).
  # (the frontend builds that mapping; out-of-range positions fall back to set 0.)
  class Generator
    # `registry` (when given) applies each marked position's inline Convert chain to
    # its payload at render time — see Template#apply_chains. nil = no transforms
    # (keeps bare 3-arg callers and specs compiling).
    def initialize(@template : Template, @sets : Array(PayloadSet), @config : Config,
                   @registry : Convert::Registry? = nil)
    end

    def mode : Mode
      @config.mode
    end

    # Total request count, or nil when unknown / Int64-overflowing (→ confirm + cap
    # in every frontend). Pitchfork's total is an UPPER bound (min of the KNOWN set
    # sizes; an unknown-length set could end the lockstep sooner).
    def total : Int64?
      case @config.mode
      when .sniper?        then mul(@template.position_count.to_i64, set_size(0))
      when .battering_ram? then set_size(0)
      when .pitchfork?     then pitchfork_total
      when .cluster_bomb?  then cluster_total
      else                      nil
      end
    end

    # Capture the caller's block as a Proc and thread it through the mode methods —
    # `yield` is illegal inside the captured recursion/iteration closures below.
    def each(&block : Job ->) : Nil
      case @config.mode
      when .sniper?        then sniper(block)
      when .battering_ram? then battering(block)
      when .pitchfork?     then pitchfork(block)
      when .cluster_bomb?  then cluster(block)
      end
    end

    # The unmodified base request (all positions = their defaults), CL-synced — used
    # to seed the matcher baseline for anomaly diffing / auto-calibration.
    def baseline_request : Bytes
      raw = @template.render(chained(@template.default_payloads))
      @config.update_content_length? ? ContentLength.sync(raw, @config.add_content_length_when_missing?) : raw
    end

    # ── modes ────────────────────────────────────────────────────────────────────

    private def sniper(emit_to : Job ->) : Nil
      set = @sets[0]?
      return if set.nil?
      idx = 0_i64
      defaults = @template.default_payloads
      (0...@template.position_count).each do |p|
        set.each do |v|
          payloads = defaults.dup
          payloads[p] = v
          emit_to.call(emit(idx, payloads, p))
          idx += 1
        end
      end
    end

    private def battering(emit_to : Job ->) : Nil
      set = @sets[0]?
      return if set.nil?
      idx = 0_i64
      n = @template.position_count
      set.each do |v|
        emit_to.call(emit(idx, Array.new(n, v), nil))
        idx += 1
      end
    end

    private def pitchfork(emit_to : Job ->) : Nil
      count = @template.position_count
      return if count == 0
      iters = (0...count).map { |p| set_for(p).open_iterator }
      idx = 0_i64
      begin
        loop do
          payloads = [] of String
          iters.each do |it|
            v = it.next_value
            return if v.nil? # the shortest set ends the run
            payloads << v
          end
          emit_to.call(emit(idx, payloads, nil))
          idx += 1
        end
      ensure
        iters.each(&.close)
      end
    end

    private def cluster(emit_to : Job ->) : Nil
      count = @template.position_count
      return if count == 0
      idx = 0_i64
      acc = Array.new(count, "")
      combo = ->(payloads : Array(String)) do
        emit_to.call(emit(idx, payloads, nil))
        idx += 1
      end
      recurse(0, count, acc, combo)
    end

    private def recurse(level : Int32, count : Int32, acc : Array(String), emit_combo : Array(String) ->) : Nil
      if level == count
        emit_combo.call(acc.dup)
        return
      end
      set_for(level).each do |v|
        acc[level] = v
        recurse(level + 1, count, acc, emit_combo)
      end
    end

    # ── helpers ──────────────────────────────────────────────────────────────────

    private def emit(idx : Int64, payloads : Array(String), pos : Int32?) : Job
      raw = @template.render(chained(payloads))
      bytes = @config.update_content_length? ? ContentLength.sync(raw, @config.add_content_length_when_missing?) : raw
      Job.new(idx, payloads, pos, bytes) # keep the ORIGINAL payloads for reporting; only the wire bytes are transformed
    end

    # Apply each position's inline Convert chain to its payload (identity when no
    # registry was supplied). Kept separate so `render` stays a byte-verbatim splice.
    private def chained(payloads : Array(String)) : Array(String)
      (reg = @registry) ? @template.apply_chains(payloads, reg) : payloads
    end

    private def set_for(p : Int32) : PayloadSet
      @sets[p]? || @sets[0]
    end

    private def set_size(i : Int32) : Int64?
      @sets[i]?.try(&.size)
    end

    private def pitchfork_total : Int64?
      known = (0...@template.position_count).compact_map { |p| @sets[p]?.try(&.size) }
      known.empty? ? nil : known.min
    end

    private def cluster_total : Int64?
      return nil if @sets.empty?
      # Use set_for(p) (with the set-0 fallback) exactly like each()/recurse() do —
      # otherwise a run with fewer payload sets than positions reports an unknown
      # ('?') total and demands --force, even though it's perfectly bounded.
      acc = 1_i64.as(Int64?)
      (0...@template.position_count).each { |p| acc = mul(acc, set_for(p).size) }
      acc
    end

    private def mul(a : Int64?, b : Int64?) : Int64?
      return nil if a.nil? || b.nil?
      return 0_i64 if a == 0 || b == 0
      return nil if a > Int64::MAX // b
      a * b
    end
  end
end
