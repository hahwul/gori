require "uri"
require "base64"
require "digest/md5"
require "digest/sha1"
require "digest/sha256"

module Gori::Fuzz
  # A pull-based, closeable cursor over one payload set. Custom (not Iterator(String))
  # so file-backed sets close their fd even when a Pitchfork run stops at the shortest
  # set before reaching EOF.
  abstract class SetIterator
    abstract def next_value : String? # nil = exhausted

    def close : Nil
    end
  end

  # A source of payload strings. Re-iterable AND lazy: `each` re-opens from the start
  # (Cluster-bomb inner loops re-iterate), `open_iterator` gives a fresh single-pass
  # cursor (Pitchfork lockstep), `size` is the count (nil = unknown / Int64 overflow).
  abstract class PayloadSource
    abstract def open_iterator : SetIterator
    abstract def size : Int64?

    def each(& : String ->) : Nil
      it = open_iterator
      begin
        while v = it.next_value
          yield v
        end
      ensure
        it.close
      end
    end
  end

  # Inline values (a comma list or a hand-typed set).
  class InlineList < PayloadSource
    def initialize(@values : Array(String))
    end

    def size : Int64?
      @values.size.to_i64
    end

    def open_iterator : SetIterator
      ArrayIterator.new(@values)
    end

    private class ArrayIterator < SetIterator
      def initialize(@values : Array(String))
        @i = 0
      end

      def next_value : String?
        return nil if @i >= @values.size
        v = @values[@i]
        @i += 1
        v
      end
    end
  end

  # A wordlist file, read lazily line by line (never materialized). `size` counts
  # lines once and caches — which doubles as a pre-flight open check, so a missing /
  # unreadable file raises before any worker fiber spawns.
  class WordlistFile < PayloadSource
    getter path : String

    def initialize(@path : String)
      @count = nil.as(Int64?)
      @counted = false
    end

    def size : Int64?
      unless @counted
        n = 0_i64
        File.each_line(@path) { n += 1 }
        @count = n
        @counted = true
      end
      @count
    end

    def open_iterator : SetIterator
      LineIterator.new(@path)
    end

    private class LineIterator < SetIterator
      def initialize(path : String)
        @file = File.open(path)
      end

      def next_value : String?
        if line = @file.gets(chomp: true)
          line
        else
          close
          nil
        end
      end

      def close : Nil
        @file.close unless @file.closed?
      end
    end
  end

  # Generated numbers: from..to by step, decimal or hex, optionally zero-padded.
  class NumberRange < PayloadSource
    def initialize(@from : Int64, @to : Int64, @step : Int64 = 1_i64,
                   @base : Symbol = :dec, @pad : Int32 = 0)
      @step = 1_i64 if @step == 0
    end

    def size : Int64?
      return 0_i64 if (@step > 0 && @from > @to) || (@step < 0 && @from < @to)
      count = ((@to - @from) // @step).abs
      count == Int64::MAX ? nil : count + 1 # +1 would overflow → unknown
    rescue OverflowError
      nil
    end

    def open_iterator : SetIterator
      NumberIterator.new(@from, @to, @step, @base, @pad)
    end

    private class NumberIterator < SetIterator
      def initialize(@cur : Int64, @to : Int64, @step : Int64, @base : Symbol, @pad : Int32)
      end

      def next_value : String?
        return nil if (@step > 0 && @cur > @to) || (@step < 0 && @cur < @to)
        v = format(@cur)
        @cur += @step
        v
      end

      private def format(n : Int64) : String
        s = @base == :hex ? n.to_s(16) : n.to_s
        @pad > 0 ? s.rjust(@pad, '0') : s
      end
    end
  end

  # N empty payloads — Burp's "null payloads", to measure a position's baseline
  # effect (e.g. how the app responds when a parameter is blanked N times).
  class NullPayloads < PayloadSource
    def initialize(@count : Int32)
    end

    def size : Int64?
      @count.to_i64
    end

    def open_iterator : SetIterator
      NullIterator.new(@count)
    end

    private class NullIterator < SetIterator
      def initialize(@remaining : Int32)
      end

      def next_value : String?
        return nil if @remaining <= 0
        @remaining -= 1
        ""
      end
    end
  end

  # Brute-force: every string of length min..max over a charset (odometer). `size`
  # saturates to nil on Int64 overflow so the run is gated by a cap.
  class BruteForce < PayloadSource
    def initialize(charset : String, min : Int32, max : Int32)
      @chars = charset.chars
      @min = min < 1 ? 1 : min
      @max = max < @min ? @min : max
    end

    def size : Int64?
      base = @chars.size.to_i64
      return 0_i64 if base == 0
      total = 0_i64
      (@min..@max).each do |len|
        pw = 1_i64
        len.times do
          return nil if pw > Int64::MAX // base
          pw *= base
        end
        return nil if total > Int64::MAX - pw
        total += pw
      end
      total
    end

    def open_iterator : SetIterator
      BruteIterator.new(@chars, @min, @max)
    end

    private class BruteIterator < SetIterator
      @idx : Array(Int32)
      @len : Int32

      def initialize(@chars : Array(Char), @min : Int32, @max : Int32)
        @len = @min
        @idx = Array.new(@min, 0)
        @exhausted = @chars.empty?
      end

      def next_value : String?
        return nil if @exhausted
        s = String.build { |io| @idx.each { |k| io << @chars[k] } }
        advance
        s
      end

      private def advance : Nil
        i = @len - 1
        while i >= 0
          @idx[i] += 1
          return if @idx[i] < @chars.size
          @idx[i] = 0
          i -= 1
        end
        @len += 1
        if @len > @max
          @exhausted = true
        else
          @idx = Array.new(@len, 0)
        end
      end
    end
  end

  # ── Processing pipeline (1:1 per payload, so set size is preserved) ──────────────

  abstract struct Processor
    abstract def apply(s : String) : String
  end

  struct Prefix < Processor
    def initialize(@text : String)
    end

    def apply(s : String) : String
      "#{@text}#{s}"
    end
  end

  struct Suffix < Processor
    def initialize(@text : String)
    end

    def apply(s : String) : String
      "#{s}#{@text}"
    end
  end

  struct RegexReplace < Processor
    def initialize(@pattern : Regex, @replacement : String)
    end

    def apply(s : String) : String
      s.gsub(@pattern, @replacement)
    end
  end

  # :url (percent-encode reserved chars), :url_all (percent-encode every byte),
  # :base64, :hex.
  struct Encode < Processor
    def initialize(@kind : Symbol)
    end

    def apply(s : String) : String
      case @kind
      when :url     then URI.encode_www_form(s, space_to_plus: false)
      when :url_all then String.build { |io| s.to_slice.each { |b| io << '%' << b.to_s(16).rjust(2, '0').upcase } }
      when :base64  then Base64.strict_encode(s)
      when :hex     then s.to_slice.hexstring
      else               s
      end
    end
  end

  struct Case < Processor
    def initialize(@kind : Symbol) # :upper | :lower
    end

    def apply(s : String) : String
      @kind == :upper ? s.upcase : s.downcase
    end
  end

  struct Hasher < Processor
    def initialize(@algo : Symbol) # :md5 | :sha1 | :sha256
    end

    def apply(s : String) : String
      case @algo
      when :md5    then Digest::MD5.hexdigest(s)
      when :sha1   then Digest::SHA1.hexdigest(s)
      when :sha256 then Digest::SHA256.hexdigest(s)
      else              s
      end
    end
  end

  # A payload source plus an ordered processing pipeline.
  class PayloadSet
    getter source : PayloadSource
    getter pipeline : Array(Processor)

    def initialize(@source : PayloadSource, @pipeline : Array(Processor) = [] of Processor)
    end

    def size : Int64?
      @source.size
    end

    def each(& : String ->) : Nil
      @source.each { |raw| yield apply(raw) }
    end

    def open_iterator : SetIterator
      ProcessedIterator.new(@source.open_iterator, @pipeline)
    end

    private def apply(raw : String) : String
      @pipeline.reduce(raw) { |acc, p| p.apply(acc) }
    end

    private class ProcessedIterator < SetIterator
      def initialize(@inner : SetIterator, @pipeline : Array(Processor))
      end

      def next_value : String?
        v = @inner.next_value
        return nil if v.nil?
        @pipeline.reduce(v) { |acc, p| p.apply(acc) }
      end

      def close : Nil
        @inner.close
      end
    end
  end
end
