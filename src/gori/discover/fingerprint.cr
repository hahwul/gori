require "../proxy/codec/content_decode"

module Gori::Discover
  # A cheap, O(body) content fingerprint used two ways:
  #   * per-directory soft-404 calibration (is this probe's body the same as a known 404?),
  #   * duplicate-content trap prevention (a paginated/faceted listing renders N near-
  #     identical pages → one cluster → stop expanding it).
  # 64-bit SimHash over alnum tokens, SKIPPING dynamic tokens (pure-numeric / long-hex /
  # uuid-ish) so timestamps/CSRF/ids don't move the hash. Byte-level, no per-token String.
  module Fingerprint
    MAX_TOKENS = 200_000 # bound the cost on a hostile body

    # FNV-1a 64-bit seed/prime.
    FNV_OFFSET = 0xcbf29ce484222325_u64
    FNV_PRIME  = 0x00000100000001b3_u64

    # How many tokens the bit-sliced accumulator below may fold in before it must be drained
    # into `votes`. Eight planes count to 2**8 - 1, and the 256th token would carry out of the
    # top plane and be lost — so the drain happens ON 255, not after it.
    PLANE_FULL = 255

    # 64-bit SimHash. Counts, per bit position, how many token hashes set it; the output bit is
    # set when that is a strict majority.
    #
    # The count is kept BIT-SLICED — eight UInt64 "planes", where bit j of plane i is bit i of
    # the counter for column j — so folding a token in is eight register-only half-adds of the
    # whole 64-column counter at once, instead of 64 separate loop iterations. That inner loop
    # was ~90% of this function: it read, compared and wrote one `Int32` per BIT per token, and
    # branched on an FNV output bit, which is ~50/50 and therefore the branch predictor's worst
    # case. On a 155 KB body it ran 20k tokens x 64 = 1.3M times.
    #
    # `distill` calls this on EVERY response — a brute-force pass is ~315 sends per directory —
    # and the scheduler is single-threaded (no -Dpreview_mt), so this CPU is taken from the same
    # thread the orchestrator dispatches on.
    #
    # Counting ONES rather than the old ±1 votes is what makes the planes work, and it is exact
    # rather than approximate: the old `votes = ones - (tokens - ones) = 2*ones - tokens`, so
    # `votes > 0` iff `2*ones > tokens`, ties falling the same way in both. `discover_fingerprint_bench`
    # pins the equality over a corpus, 2000 random bodies and the token-class edge cases.
    def self.simhash(body : Bytes) : UInt64
      votes = StaticArray(Int32, 64).new(0)
      # The vertical counter. Locals rather than an array so they stay in registers — a
      # StaticArray is a value type and passing one to a helper would copy it per token.
      p0 = 0_u64
      p1 = 0_u64
      p2 = 0_u64
      p3 = 0_u64
      p4 = 0_u64
      p5 = 0_u64
      p6 = 0_u64
      p7 = 0_u64
      pending = 0
      tokens = 0
      i = 0
      n = body.size
      while i < n && tokens < MAX_TOKENS
        # skip non-alnum
        while i < n && !body.unsafe_fetch(i).unsafe_chr.ascii_alphanumeric?
          i += 1
        end
        start = i
        while i < n && body.unsafe_fetch(i).unsafe_chr.ascii_alphanumeric?
          i += 1
        end
        len = i - start
        next if len == 0
        next if dynamic?(body, start, len)
        tokens += 1
        # Add 1 to every column whose bit is set, in parallel: `c` is the carry mask, and each
        # plane is a half-add (sum = plane ^ carry, carry out = plane & carry). The top plane
        # drops its carry, which is why `pending` never reaches 256.
        c = fnv1a(body, start, len)
        t = p0 & c; p0 ^= c; c = t
        t = p1 & c; p1 ^= c; c = t
        t = p2 & c; p2 ^= c; c = t
        t = p3 & c; p3 ^= c; c = t
        t = p4 & c; p4 ^= c; c = t
        t = p5 & c; p5 ^= c; c = t
        t = p6 & c; p6 ^= c; c = t
        p7 ^= c
        pending += 1
        if pending == PLANE_FULL
          drain(votes.to_unsafe, p0, p1, p2, p3, p4, p5, p6, p7)
          p0 = p1 = p2 = p3 = p4 = p5 = p6 = p7 = 0_u64
          pending = 0
        end
      end
      drain(votes.to_unsafe, p0, p1, p2, p3, p4, p5, p6, p7) if pending > 0
      out = 0_u64
      bit = 0
      while bit < 64
        # `2 * ones > tokens` — the old `votes > 0`, restated for a ones-only count.
        out |= (1_u64 << bit) if votes.to_unsafe[bit] &* 2 > tokens
        bit += 1
      end
      out
    end

    # Add the bit-sliced counters back into the per-column totals and leave the planes to be
    # zeroed by the caller. Runs once per PLANE_FULL tokens, so its 64 iterations amortize to
    # well under one per token.
    private def self.drain(votes : Int32*, p0 : UInt64, p1 : UInt64, p2 : UInt64, p3 : UInt64,
                           p4 : UInt64, p5 : UInt64, p6 : UInt64, p7 : UInt64) : Nil
      bit = 0
      while bit < 64
        v = (p0 >> bit) & 1_u64
        v |= ((p1 >> bit) & 1_u64) << 1
        v |= ((p2 >> bit) & 1_u64) << 2
        v |= ((p3 >> bit) & 1_u64) << 3
        v |= ((p4 >> bit) & 1_u64) << 4
        v |= ((p5 >> bit) & 1_u64) << 5
        v |= ((p6 >> bit) & 1_u64) << 6
        v |= ((p7 >> bit) & 1_u64) << 7
        votes[bit] += v.to_i32
        bit += 1
      end
    end

    # `popcount` is one instruction on every target gori builds for; the loop it replaces ran
    # once per DIFFERING bit, which for two unrelated fingerprints is ~32 iterations with an
    # unpredictable trip count. That matters because of who calls it: `ClusterMap#observe`
    # linear-scans up to MAX_CLUSTERS representatives per crawl page, and `Calibrate.hit?`
    # runs it over the baseline set for every probe.
    def self.hamming(a : UInt64, b : UInt64) : Int32
      (a ^ b).popcount.to_i32
    end

    # A token is "dynamic" (skipped) when it's all digits, or a long all-hex run — i.e. an
    # id / timestamp / hash / uuid fragment (a dashed uuid splits into hex runs at the
    # dashes, each caught here).
    private def self.dynamic?(body : Bytes, start : Int32, len : Int32) : Bool
      all_digits = true
      all_hex = true
      k = 0
      while k < len
        b = body.unsafe_fetch(start + k)
        digit = b >= 0x30_u8 && b <= 0x39_u8
        hex = digit || (b >= 0x61_u8 && b <= 0x66_u8) || (b >= 0x41_u8 && b <= 0x46_u8)
        all_digits = false unless digit
        all_hex = false unless hex
        break unless all_digits || all_hex
        k += 1
      end
      all_digits || (all_hex && len >= 12)
    end

    # FNV-1a over the token bytes, lowercasing A-Z so case doesn't fork the hash.
    private def self.fnv1a(body : Bytes, start : Int32, len : Int32) : UInt64
      h = FNV_OFFSET
      k = 0
      while k < len
        b = body.unsafe_fetch(start + k)
        b |= 0x20_u8 if b >= 0x41_u8 && b <= 0x5a_u8 # lower A-Z
        h = (h ^ b.to_u64) &* FNV_PRIME
        k += 1
      end
      h
    end
  end

  # A bounded map of content-fingerprint clusters. observe() returns the cluster's distinct
  # count after adding `fp`: the FIRST representative within `distance` hamming, else a new
  # cluster. Bounded (LRU-ish drop of the oldest) so a hostile site can't grow it without
  # limit; real sites have few clusters, so the linear scan is effectively O(1).
  class ClusterMap
    MAX_CLUSTERS = 4096

    def initialize
      @reps = [] of {UInt64, Int32} # {representative fingerprint, distinct count}
    end

    def observe(fp : UInt64, distance : Int32) : Int32
      @reps.each_with_index do |(rep, count), i|
        if Fingerprint.hamming(fp, rep) <= distance
          nc = count + 1
          @reps[i] = {rep, nc}
          return nc
        end
      end
      @reps.shift if @reps.size >= MAX_CLUSTERS
      @reps << {fp, 1}
      1
    end
  end
end
