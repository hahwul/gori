# Shared numeric/brute/encode/case/hash/regex/rate/nonneg/regex_replace flag
# parsers used by BOTH `gori run fuzz` (./fuzz.cr) and `gori run discover`
# (./discover.cr) — kept together here instead of duplicated or hidden in fuzz.cr.
module Gori
  module CLI
    module Run
      private def self.parse_numbers(v : String) : Fuzz::NumberRange
        range_part, _, step_part = v.partition(':')
        from_s, _, to_s = range_part.partition('-')
        from = from_s.to_i64?
        to = to_s.to_i64?
        abort "gori run fuzz: invalid --numbers '#{v}' (use FROM-TO[:STEP])" unless from && to
        step = step_part.empty? ? 1_i64 : (step_part.to_i64? || abort("gori run fuzz: invalid --numbers step '#{step_part}'"))
        Fuzz::NumberRange.new(from, to, step)
      end

      private def self.parse_brute(v : String) : Fuzz::BruteForce
        charset, _, lens = v.rpartition(':')
        abort "gori run fuzz: invalid --brute '#{v}' (use CHARSET:MIN-MAX)" if charset.empty? || lens.empty?
        min_s, _, max_s = lens.partition('-')
        min = min_s.to_i?
        max = max_s.empty? ? min : max_s.to_i?
        abort "gori run fuzz: invalid --brute lengths '#{lens}' (use MIN-MAX)" unless min && max
        Fuzz::BruteForce.new(charset, min, max)
      end

      private def self.parse_encode(v : String) : Symbol
        case v.downcase
        when "url"    then :url
        when "urlall" then :url_all
        when "base64" then :base64
        when "hex"    then :hex
        else               abort "gori run fuzz: invalid --encode '#{v}' (url|urlall|base64|hex)"
        end
      end

      private def self.parse_case(v : String) : Symbol
        case v.downcase
        when "upper" then :upper
        when "lower" then :lower
        else              abort "gori run fuzz: invalid --case '#{v}' (upper|lower)"
        end
      end

      private def self.parse_hash(v : String) : Symbol
        case v.downcase
        when "md5"    then :md5
        when "sha1"   then :sha1
        when "sha256" then :sha256
        else               abort "gori run fuzz: invalid --hash '#{v}' (md5|sha1|sha256)"
        end
      end

      private def self.parse_regex(v : String) : Regex
        Regex.new(v)
      rescue ex
        abort "gori run fuzz: invalid regex '#{v}': #{ex.message}"
      end

      private def self.parse_rate(v : String) : Float64?
        n = v.to_f?
        abort "gori run fuzz: invalid --rate '#{v}' (a non-negative number)" unless n && n >= 0
        n == 0 ? nil : n
      end

      private def self.parse_nonneg(v : String, flag : String? = nil) : Int32
        n = v.to_i?
        abort "gori run: invalid #{flag || "count"} '#{v}' (expected a non-negative integer)" unless n && n >= 0
        n
      end

      private def self.parse_regex_replace(v : String) : Fuzz::RegexReplace
        abort "gori run fuzz: --regex-replace needs /pattern/replacement/" if v.size < 3
        delim = v[0]
        parts = v[1..].split(delim)
        abort "gori run fuzz: --regex-replace must be #{delim}pattern#{delim}replacement#{delim}" if parts.size < 2
        Fuzz::RegexReplace.new(parse_regex(parts[0]), parts[1])
      end
    end
  end
end
