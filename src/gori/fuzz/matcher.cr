require "../proxy/codec/content_decode"
require "../intercept_filter"
require "../repeater/engine"

module Gori::Fuzz
  # Decoded-response metrics for one send.
  record Metrics,
    status : Int32?,
    length : Int64,
    words : Int32,
    lines : Int32,
    duration_us : Int64

  # Decides whether a response is "interesting" and extracts a value from it.
  # ffuf/Burp semantics: a result is MATCHED when every active matcher dimension
  # passes AND no filter dimension passes. Each dimension is a comma-list spec
  # supporting exact (`200`), range (`200-299`), comparator (`>=400`), and — for
  # status — class (`2xx`). Metrics are computed over the DECODED body (gzip/br/…),
  # falling back to the raw body when a codec isn't built in.
  class Matcher
    # Each match/filter spec string is set ONCE (CLI run.cr / TUI fuzzer_view.cr / MCP
    # tools.cr) and then evaluated on EVERY response. Keep the raw string (the TUI reads it
    # back verbatim for the config screen + JSON persist) but precompile it into a parsed
    # term list, so the per-response hot path does zero split/strip/to_i64 work and allocates
    # nothing. Recompiled on assignment, so a mid-run TUI re-apply stays correct. A blank ("")
    # or nil spec compiles to nil ⇒ treated as absent (the `default` is returned), exactly as
    # the old `spec.nil? || spec.blank?` guard — so a match dimension stays "unconstrained"
    # rather than flipping to "reject everything".
    macro num_spec(name)
      getter {{name.id}} : String?
      @{{name.id}}_c : Array(NumTerm)?

      def {{name.id}}=(v : String?)
        @{{name.id}} = v
        @{{name.id}}_c = (v && !v.blank?) ? Predicate.compile_num(v) : nil
      end
    end

    macro status_spec(name)
      getter {{name.id}} : String?
      @{{name.id}}_c : Array(StatusTerm)?

      def {{name.id}}=(v : String?)
        @{{name.id}} = v
        @{{name.id}}_c = (v && !v.blank?) ? Predicate.compile_status(v) : nil
      end
    end

    status_spec match_status
    status_spec filter_status
    num_spec match_size
    num_spec filter_size
    num_spec match_words
    num_spec filter_words
    num_spec match_lines
    num_spec filter_lines

    property match_regex : Regex?
    property filter_regex : Regex?
    property match_header : String? # substring over the response head
    property extract : Regex?
    property baseline : Metrics?
    property? auto_calibrate : Bool
    property keep_bodies : Symbol # :none | :matched | :all

    def initialize(@keep_bodies : Symbol = :matched, @auto_calibrate : Bool = false)
      @baseline = nil
    end

    # Build the metrics for a raw send WITHOUT deciding match (used to seed the
    # baseline from the unmodified request).
    def metrics(raw : Repeater::Result) : Metrics
      body = decode(raw)
      words, lines = count_metrics(body)
      Metrics.new(raw.response.try(&.status), body.size.to_i64, words, lines, raw.duration_us)
    end

    def build(job : Job, raw : Repeater::Result) : Result
      body = decode(raw)
      status = raw.response.try(&.status)
      length = body.size.to_i64
      words, lines = count_metrics(body)

      need_text = !@match_regex.nil? || !@filter_regex.nil? || !@extract.nil?
      text = need_text ? String.new(body).scrub : ""
      extracted = extract_value(text)
      matched = decide(raw, status, length, words, lines, text)
      keep = keep?(matched)

      Result.new(
        index: job.index, payloads: job.payloads, position: job.position,
        status: status, length: length, words: words, lines: lines,
        duration_us: raw.duration_us, error: raw.error, matched: matched,
        incomplete: raw.incomplete?, extracted: extracted,
        head: keep ? present(raw.head) : nil, body: keep ? raw.body : nil,
        request: keep ? present(job.bytes) : nil)
    end

    private def decide(raw : Repeater::Result, status : Int32?, length : Int64,
                       words : Int32, lines : Int32, text : String) : Bool
      return false unless raw.error.nil?
      return false if calibrated_out?(status, length, words)
      matchers_pass?(raw, status, length, words, lines, text) &&
        !filtered?(status, length, words, lines, text)
    end

    private def calibrated_out?(status : Int32?, length : Int64, words : Int32) : Bool
      return false unless @auto_calibrate
      b = @baseline
      return false unless b
      status == b.status && length == b.length && words == b.words
    end

    # Every active matcher dimension must pass.
    private def matchers_pass?(raw : Repeater::Result, status : Int32?, length : Int64,
                               words : Int32, lines : Int32, text : String) : Bool
      status_pass?(@match_status_c, status, default: true) &&
        num_pass?(@match_size_c, length, default: true) &&
        num_pass?(@match_words_c, words.to_i64, default: true) &&
        num_pass?(@match_lines_c, lines.to_i64, default: true) &&
        regex_pass?(@match_regex, text, default: true) &&
        header_pass?(raw)
    end

    # Any filter dimension that passes removes the result.
    private def filtered?(status : Int32?, length : Int64, words : Int32,
                          lines : Int32, text : String) : Bool
      status_pass?(@filter_status_c, status, default: false) ||
        num_pass?(@filter_size_c, length, default: false) ||
        num_pass?(@filter_words_c, words.to_i64, default: false) ||
        num_pass?(@filter_lines_c, lines.to_i64, default: false) ||
        regex_pass?(@filter_regex, text, default: false)
    end

    private def regex_pass?(re : Regex?, text : String, default : Bool) : Bool
      re ? re.matches?(text) : default
    rescue Regex::Error
      # A catastrophic-backtracking user regex (--mr / --fr) raises "match limit exceeded" on a
      # large response body instead of returning false; treat an un-evaluable pattern as no-match
      # so one runaway regex can't kill the fuzz worker fiber on every response.
      false
    end

    private def header_pass?(raw : Repeater::Result) : Bool
      h = @match_header
      return true unless h
      String.new(raw.head).scrub.downcase.includes?(h.downcase)
    end

    # `default` is returned when the spec is absent (compiled == nil, i.e. the raw spec was
    # nil or blank — see the status_spec/num_spec setters): a matcher with no spec passes; a
    # filter with no spec never fires. When a spec IS present but the response has no status,
    # a status dimension can't match (false), mirroring the old behaviour.
    private def status_pass?(compiled : Array(StatusTerm)?, status : Int32?, default : Bool) : Bool
      return default if compiled.nil?
      (s = status) ? compiled.any?(&.matches?(s)) : false
    end

    private def num_pass?(compiled : Array(NumTerm)?, value : Int64, default : Bool) : Bool
      return default if compiled.nil?
      compiled.any?(&.matches?(value))
    end

    private def extract_value(text : String) : String?
      re = @extract
      return nil if re.nil? || text.empty?
      md = re.match(text)
      return nil unless md
      md[1]? || md[0]
    rescue Regex::Error
      nil # a runaway --extract regex yields no capture rather than a dead worker (see regex_pass?)
    end

    private def decode(raw : Repeater::Result) : Bytes
      decoded, _ = Proxy::Codec::ContentDecode.decode(raw.head, raw.body)
      decoded || raw.body || Bytes.empty
    end

    private def keep?(matched : Bool) : Bool
      case @keep_bodies
      when :all     then true
      when :matched then matched
      else               false
      end
    end

    private def present(head : Bytes) : Bytes?
      head.empty? ? nil : head
    end

    # Word count (whitespace transitions) AND line count (0x0a bytes) over the decoded body
    # in ONE allocation-free pass. 0x0a is already a whitespace byte in the word scan, so
    # counting lines inside that same branch is bit-identical to two separate traversals.
    private def count_metrics(body : Bytes) : {Int32, Int32}
      words = 0
      lines = 0
      in_word = false
      body.each do |b|
        if b == 0x20_u8 || b == 0x09_u8 || b == 0x0a_u8 || b == 0x0d_u8
          in_word = false
          lines += 1 if b == 0x0a_u8
        elsif !in_word
          in_word = true
          words += 1
        end
      end
      {words, lines}
    end
  end

  # A precompiled numeric predicate term — parsed once from a comma-spec, evaluated per
  # response with plain integer comparisons. Mirrors the old Predicate.term? decision exactly.
  enum NumKind : UInt8
    Exact
    Range
    Ge
    Le
    Gt
    Lt
    Never # a comparator/bare term whose number failed to parse — never matches (was `false`)
  end

  struct NumTerm
    getter kind : NumKind
    getter a : Int64
    getter b : Int64

    def initialize(@kind : NumKind, @a : Int64 = 0_i64, @b : Int64 = 0_i64)
    end

    def matches?(v : Int64) : Bool
      case kind
      in NumKind::Exact then v == a
      in NumKind::Range then v >= a && v <= b
      in NumKind::Ge    then v >= a
      in NumKind::Le    then v <= a
      in NumKind::Gt    then v > a
      in NumKind::Lt    then v < a
      in NumKind::Never then false
      end
    end
  end

  # A precompiled status term: either an inclusive `lo-hi` range, or a raw term delegated to
  # InterceptFilter.status_match? at eval time (exact / `Nxx` class / comparator forms). The
  # comma-split is done ONCE at compile; eval allocates nothing. Ranges keep Int64 bounds so a
  # range wider than Int32 can't overflow (status is small; the compare promotes to Int64).
  struct StatusTerm
    getter a : Int64
    getter b : Int64
    getter raw : String?

    def initialize(@a : Int64, @b : Int64, @raw : String? = nil)
    end

    def self.range(lo : Int64, hi : Int64) : StatusTerm
      new(lo, hi)
    end

    def self.delegate(term : String) : StatusTerm
      new(0_i64, 0_i64, term)
    end

    def matches?(status : Int32) : Bool
      if r = @raw
        InterceptFilter.status_match?(status, r)
      else
        status >= @a && status <= @b
      end
    end
  end

  # Parses match/filter spec strings into evaluable terms — the single source of truth for spec
  # PARSING. The Matcher compiles each spec ONCE per run (on assignment) and evaluates the parsed
  # NumTerm/StatusTerm arrays per response, so no string is re-parsed or re-split on the hot path.
  module Predicate
    # Parse a comma-spec into evaluable numeric terms ONCE (mirrors the old per-call term?).
    def self.compile_num(spec : String) : Array(NumTerm)
      terms(spec).map { |t| classify_num(t) }
    end

    # Parse a comma-spec into evaluable status terms ONCE: a `lo-hi` range (inclusive) is
    # matched numerically; every other term delegates to InterceptFilter.status_match?, the
    # SAME decision order the old status_any? used (parse_range first, else class/exact match).
    def self.compile_status(spec : String) : Array(StatusTerm)
      terms(spec).map do |t|
        if range = parse_range(t)
          StatusTerm.range(range[0], range[1])
        else
          StatusTerm.delegate(t)
        end
      end
    end

    private def self.classify_num(t : String) : NumTerm
      {">=", "<=", ">", "<", "="}.each do |op|
        if t.starts_with?(op)
          n = t[op.size..].strip.to_i64?
          return NumTerm.new(NumKind::Never) unless n
          kind = case op
                 when ">=" then NumKind::Ge
                 when "<=" then NumKind::Le
                 when ">"  then NumKind::Gt
                 when "<"  then NumKind::Lt
                 else           NumKind::Exact # "="
                 end
          return NumTerm.new(kind, n)
        end
      end
      if range = parse_range(t)
        return NumTerm.new(NumKind::Range, range[0], range[1])
      end
      (n = t.to_i64?) ? NumTerm.new(NumKind::Exact, n) : NumTerm.new(NumKind::Never)
    end

    private def self.terms(spec : String) : Array(String)
      spec.split(',').map(&.strip).reject(&.empty?)
    end

    private def self.parse_range(t : String) : {Int64, Int64}?
      dash = t.index('-', 1) # not a leading minus
      return nil unless dash
      lo = t[0...dash].to_i64?
      hi = t[(dash + 1)..].to_i64?
      (lo && hi) ? {lo, hi} : nil
    end
  end
end
