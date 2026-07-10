require "../proxy/codec/content_decode"
require "../intercept_filter"
require "../replay/engine"

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
    property match_status : String?
    property filter_status : String?
    property match_size : String?
    property filter_size : String?
    property match_words : String?
    property filter_words : String?
    property match_lines : String?
    property filter_lines : String?
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
    def metrics(raw : Replay::Result) : Metrics
      body = decode(raw)
      Metrics.new(raw.response.try(&.status), body.size.to_i64, count_words(body), count_lines(body), raw.duration_us)
    end

    def build(job : Job, raw : Replay::Result) : Result
      body = decode(raw)
      status = raw.response.try(&.status)
      length = body.size.to_i64
      words = count_words(body)
      lines = count_lines(body)

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
        head: keep ? present(raw.head) : nil, body: keep ? raw.body : nil)
    end

    private def decide(raw : Replay::Result, status : Int32?, length : Int64,
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
    private def matchers_pass?(raw : Replay::Result, status : Int32?, length : Int64,
                               words : Int32, lines : Int32, text : String) : Bool
      status_pass?(@match_status, status, default: true) &&
        num_pass?(@match_size, length, default: true) &&
        num_pass?(@match_words, words.to_i64, default: true) &&
        num_pass?(@match_lines, lines.to_i64, default: true) &&
        regex_pass?(@match_regex, text, default: true) &&
        header_pass?(raw)
    end

    # Any filter dimension that passes removes the result.
    private def filtered?(status : Int32?, length : Int64, words : Int32,
                          lines : Int32, text : String) : Bool
      status_pass?(@filter_status, status, default: false) ||
        num_pass?(@filter_size, length, default: false) ||
        num_pass?(@filter_words, words.to_i64, default: false) ||
        num_pass?(@filter_lines, lines.to_i64, default: false) ||
        regex_pass?(@filter_regex, text, default: false)
    end

    private def regex_pass?(re : Regex?, text : String, default : Bool) : Bool
      re ? re.matches?(text) : default
    end

    private def header_pass?(raw : Replay::Result) : Bool
      h = @match_header
      return true unless h
      String.new(raw.head).scrub.downcase.includes?(h.downcase)
    end

    # `default` is returned when the spec is absent (a matcher with no spec passes;
    # a filter with no spec never fires). A BLANK spec ("" — the CLI/MCP `--ms=` etc.
    # set the property to an empty string, unlike the TUI's blank_nil) counts as absent:
    # otherwise `Predicate.any?("")` has no terms → false → a match dimension flips from
    # "unconstrained" to "reject everything", silently returning zero matches.
    private def status_pass?(spec : String?, status : Int32?, default : Bool) : Bool
      return default if spec.nil? || spec.blank?
      (s = status) ? Predicate.status_any?(spec, s) : false
    end

    private def num_pass?(spec : String?, value : Int64, default : Bool) : Bool
      return default if spec.nil? || spec.blank?
      Predicate.any?(spec, value)
    end

    private def extract_value(text : String) : String?
      re = @extract
      return nil if re.nil? || text.empty?
      md = re.match(text)
      return nil unless md
      md[1]? || md[0]
    end

    private def decode(raw : Replay::Result) : Bytes
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

    # Word count over decoded bytes, allocation-free (whitespace transitions).
    private def count_words(body : Bytes) : Int32
      count = 0
      in_word = false
      body.each do |b|
        if b == 0x20_u8 || b == 0x09_u8 || b == 0x0a_u8 || b == 0x0d_u8
          in_word = false
        elsif !in_word
          in_word = true
          count += 1
        end
      end
      count
    end

    private def count_lines(body : Bytes) : Int32
      n = 0
      body.each { |b| n += 1 if b == 0x0a_u8 }
      n
    end
  end

  # Numeric predicate over comma-listed terms; matches if ANY term matches.
  module Predicate
    def self.any?(spec : String, value : Int64) : Bool
      terms(spec).any? { |t| term?(t, value) }
    end

    # Status terms additionally support the `Nxx` class form via InterceptFilter.
    def self.status_any?(spec : String, status : Int32) : Bool
      terms(spec).any? do |t|
        if range = parse_range(t)
          status >= range[0] && status <= range[1]
        else
          InterceptFilter.status_match?(status, t)
        end
      end
    end

    private def self.terms(spec : String) : Array(String)
      spec.split(',').map(&.strip).reject(&.empty?)
    end

    private def self.term?(t : String, value : Int64) : Bool
      {">=", "<=", ">", "<", "="}.each do |op|
        if t.starts_with?(op)
          n = t[op.size..].strip.to_i64?
          return false unless n
          return case op
          when ">=" then value >= n
          when "<=" then value <= n
          when ">"  then value > n
          when "<"  then value < n
          else           value == n
          end
        end
      end
      if range = parse_range(t)
        return value >= range[0] && value <= range[1]
      end
      (n = t.to_i64?) ? value == n : false
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
