require "../proxy/codec/content_decode"
require "../intercept_filter"
require "../repeater/engine"
require "../ascii_bytes"

module Gori::Fuzz
  # Decoded-response metrics for one send.
  record Metrics,
    status : Int32?,
    length : Int64,
    words : Int32,
    lines : Int32,
    duration_us : Int64

  # One auto-calibration sample: the metrics of a synthetic (nonce-payloaded) baseline
  # response, tagged with how much payload text was injected across every marked
  # position for THAT sample. `payload_len` is what lets Matcher.reflects_length?
  # tell "this target's response length legitimately tracks payload length" (reflection)
  # apart from "this target's response length is just noisy" (needs a wider sample set).
  record BaselineSample, metrics : Metrics, payload_len : Int32

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
    # Substring over the response head. Cache the lowercased needle ONCE on assignment
    # (like the num_spec/status_spec setters) so the per-response check neither re-lowercases
    # the needle nor materializes a downcased head String — it byte-scans the raw head.
    getter match_header : String?
    @match_header_lc : Bytes?

    def match_header=(v : String?)
      @match_header = v
      @match_header_lc = (v && !v.empty?) ? v.downcase.to_slice : nil
    end

    property extract : Regex?
    # The active calibration set (see Engine#calibrate_baseline). Empty = "no
    # calibration collected" (auto-calibration off, or the calibration sends all
    # failed) — calibrated_out? treats that identically to auto_calibrate being off.
    getter baseline : Array(BaselineSample)
    # Cached alongside `baseline` (recomputed only when the set changes, never on the
    # per-response hot path) — see Matcher.reflects_length? for what it detects.
    getter? reflects_length : Bool = false
    property? auto_calibrate : Bool
    property keep_bodies : Symbol # :none | :matched | :all

    def initialize(@keep_bodies : Symbol = :matched, @auto_calibrate : Bool = false)
      @baseline = [] of BaselineSample
    end

    def baseline=(samples : Array(BaselineSample)) : Nil
      @baseline = samples
      @reflects_length = Matcher.reflects_length?(samples)
    end

    # A generous per-pair slack (bytes) for the length-tracks-payload check below — covers
    # HTML-entity re-encoding of a few nonce characters, off-by-one wrapper text, etc.
    # without being wide enough to misclassify genuinely-noisy (non-reflecting) targets.
    LENGTH_TOLERANCE = 4_i64

    # Detects a target that reflects the substituted payload back into its response body:
    # the calibration samples deliberately inject STAGGERED payload lengths (see
    # Generator#calibration_requests), so if response byte length grows in lockstep with
    # payload length across every pair of samples, comparing raw length can never repeat —
    # every distinct real attack payload has its own length, so no finite baseline set
    # would ever exact-match it (the second proven-broken scenario: 100/100 false
    # positives with a single-sample baseline). `baseline_matches?` then substitutes
    # word/line counts for length.
    #
    # Conservative by design: EVERY pair with a different payload length must show the
    # tracking relationship, or this returns false and length stays in the (safe, if
    # sometimes less effective) exact-match comparison — a target that just happens to be
    # noisy must never be misread as "reflecting".
    #
    # What this does NOT catch: partial reflection (the target truncates, HTML-escapes, or
    # otherwise transforms the payload before embedding it, so growth isn't ~1:1) reads as
    # "not reflecting" and falls through to stricter exact-length matching — under-
    # suppressing rather than over-suppressing, the safe failure direction for a security
    # tool. A target whose word/line count ALSO happens to shift with an opaque nonce
    # (e.g. it reflects the payload on its own line, adding a line each time) likewise
    # isn't calibrated out — again a missed suppression, never a missed finding.
    def self.reflects_length?(samples : Array(BaselineSample)) : Bool
      pairs = 0
      tracked = 0
      samples.each_with_index do |a, i|
        samples.each_with_index do |b, j|
          next unless j > i
          dp = (b.payload_len - a.payload_len).to_i64
          next if dp == 0
          dl = b.metrics.length - a.metrics.length
          pairs += 1
          tracked += 1 if (dl - dp).abs <= LENGTH_TOLERANCE
        end
      end
      pairs > 0 && tracked == pairs
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
      return false if calibrated_out?(status, length, words, lines)
      matchers_pass?(raw, status, length, words, lines, text) &&
        !filtered?(status, length, words, lines, text)
    end

    # A response is "noise" when it matches ANY collected baseline sample — not just a
    # single exact snapshot. That's what lets a target that legitimately rotates between
    # a handful of response shapes (a rotating banner, an A/B variant, …) get every
    # sampled shape recognized as noise, instead of only whichever one shape a single
    # lucky/unlucky baseline call happened to catch (the original bug: with one sample,
    # 3 of 4 rotating shapes were reported as false-positive hits).
    private def calibrated_out?(status : Int32?, length : Int64, words : Int32, lines : Int32) : Bool
      return false unless @auto_calibrate
      samples = @baseline
      return false if samples.empty?
      samples.any? { |b| baseline_matches?(b.metrics, status, length, words, lines) }
    end

    # Status is always compared exactly — a genuine anomaly that flips status (e.g. a
    # seeded 500) must never calibrate out, regardless of body-size heuristics. When
    # `reflects_length?` is set (see Matcher.reflects_length?), raw byte length is
    # dropped from the comparison since it legitimately varies with EVERY distinct
    # payload (no finite sample set would ever exact-match it); word/line counts are
    # used instead, since an opaque alphanumeric nonce substitution — unlike its byte
    # length — rarely changes how many whitespace-delimited words or lines a page has.
    private def baseline_matches?(b : Metrics, status : Int32?, length : Int64,
                                  words : Int32, lines : Int32) : Bool
      return false unless status == b.status
      return words == b.words && lines == b.lines if reflects_length?
      length == b.length && words == b.words
    end

    # Every active matcher dimension must pass.
    private def matchers_pass?(raw : Repeater::Result, status : Int32?, length : Int64,
                               words : Int32, lines : Int32, text : String) : Bool
      status_pass?(@match_status_c, status, default: true) &&
        num_pass?(@match_size_c, length, default: true) &&
        num_pass?(@match_words_c, words.to_i64, default: true) &&
        num_pass?(@match_lines_c, lines.to_i64, default: true) &&
        # header_pass? (an allocation-free byte scan over the short head) before regex_pass?
        # (a PCRE match over the whole body): both are pure predicates, so `&&` short-circuits
        # identically either way, but this order lets a failing --mh skip the body match.
        header_pass?(raw) &&
        regex_pass?(@match_regex, text, default: true)
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
      needle = @match_header_lc
      return true unless needle
      # ASCII case-insensitive substring scan over the raw head bytes — no per-response
      # `String.new(raw.head).scrub.downcase` allocation. Header field tokens are ASCII, so
      # this equals the old downcased-substring test for any ASCII/ISO-8859-1 head + needle.
      AsciiBytes.contains_ci?(raw.head, needle)
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
