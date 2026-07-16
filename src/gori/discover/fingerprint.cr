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

    def self.simhash(body : Bytes) : UInt64
      votes = StaticArray(Int32, 64).new(0)
      tokens = 0
      i = 0
      n = body.size
      while i < n && tokens < MAX_TOKENS
        # skip non-alnum
        while i < n && !alnum?(body.unsafe_fetch(i))
          i += 1
        end
        start = i
        while i < n && alnum?(body.unsafe_fetch(i))
          i += 1
        end
        len = i - start
        next if len == 0
        next if dynamic?(body, start, len)
        tokens += 1
        h = fnv1a(body, start, len)
        bit = 0
        while bit < 64
          if (h >> bit) & 1_u64 == 1_u64
            votes.to_unsafe[bit] += 1
          else
            votes.to_unsafe[bit] -= 1
          end
          bit += 1
        end
      end
      out = 0_u64
      bit = 0
      while bit < 64
        out |= (1_u64 << bit) if votes.to_unsafe[bit] > 0
        bit += 1
      end
      out
    end

    def self.hamming(a : UInt64, b : UInt64) : Int32
      x = a ^ b
      c = 0
      while x != 0
        x &= x - 1
        c += 1
      end
      c
    end

    private def self.alnum?(b : UInt8) : Bool
      (b >= 0x30_u8 && b <= 0x39_u8) || # 0-9
        (b >= 0x41_u8 && b <= 0x5a_u8) || # A-Z
        (b >= 0x61_u8 && b <= 0x7a_u8)    # a-z
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
