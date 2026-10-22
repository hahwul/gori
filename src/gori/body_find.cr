require "./store/safe_regexp"
require "./utf8"

module Gori
  # Regex search inside ONE message body, so a caller can locate text without paging the
  # body to read it. The surfaces hand it the exact bytes their pager serves (MCP
  # `get_response_body_chunk{find}`, `gori run show --find`): every offset it returns is a
  # byte offset into those bytes, valid as the pager's `offset` under the same view.
  #
  # Matching is QL `body~`'s, not a second definition of it: the pattern is compiled with
  # the time budget (`SafeRegexp.budgeted`), and run over the scrubbed projection
  # (`Utf8.text`) in which every invalid byte reads as U+FFFD. Scrubbing makes each invalid
  # byte three, so a match position is mapped back to the raw byte it came from.
  module BodyFind
    CONTEXT_MAX = 200
    # The most of the MATCH a snippet carries: `.*` over a 2 MiB body is one match, and its
    # snippet must stay a snippet. `length` still reports the whole match.
    MATCH_SHOWN = 200
    # The `stopped` text both surfaces put on a page the budget cut.
    STOPPED = "regex time budget ran out before the end of the body; matches after those returned are unknown"

    record Match, offset : Int64, length : Int64, snippet : String

    # `next_offset` is where the next unreturned match starts (pass it back as the start
    # offset), or nil when there is none. `stopped` = the regex budget ran out (or PCRE2 gave
    # up) before the end of the body, so matches after those returned are unknown, not absent;
    # `next_offset` is then just past the last match returned, or nil when there was none.
    record Page, matches : Array(Match), next_offset : Int64?, stopped : Bool do
      def has_more? : Bool
        !next_offset.nil?
      end
    end

    # Matches starting at or after byte `from`, at most `max`, each with `context` bytes either
    # side. Raises ArgumentError for a pattern that does not compile.
    def self.run(bytes : Bytes, pattern : String, from : Int64, max : Int32, context : Int32) : Page
      rx = SafeRegexp.budgeted(pattern)
      context = context.clamp(0, CONTEXT_MAX)
      subject = Utf8.text(bytes)
      map = Unscrub.new(bytes, subject.bytesize != bytes.size)
      pos = map.to_subject(from.clamp(0_i64, bytes.size.to_i64).to_i)
      found = [] of Match
      SafeRegexp.within_budget(pattern, subject.bytesize) do
        while pos <= subject.bytesize
          m = rx.match_at_byte_index(subject, pos, Regex::MatchOptions::NO_UTF_CHECK) || break
          s, e = m.byte_begin(0), m.byte_end(0)
          start = map.to_raw(s)
          return Page.new(found, start.to_i64, false) if found.size >= max
          found << Match.new(start.to_i64, (map.to_raw(e) - start).to_i64, snippet(subject, s, e, context))
          # An empty match would be found again at the same place: step one character on.
          pos = e > s ? e : e + char_width(subject, e)
        end
      end
      Page.new(found, nil, false)
    rescue Regex::Error
      # Budget trip: what was found stands. A resume point is offered only past `from` (just
      # after the last match returned): handing back `from` itself would re-run the search that
      # just tripped, forever.
      resume = map.try(&.to_raw(pos || 0)).try(&.to_i64)
      Page.new(found || [] of Match, resume && resume > from ? resume : nil, true)
    end

    # The subject around [s, e), the match part capped at MATCH_SHOWN, every edge moved onto a
    # character boundary so the slice stays valid UTF-8.
    private def self.snippet(subject : String, s : Int32, e : Int32, context : Int32) : String
      from = boundary(subject, Math.max(s - context, 0))
      to = boundary(subject, Math.min(Math.min(e, s + MATCH_SHOWN) + context, subject.bytesize))
      subject.byte_slice(from, to - from)
    end

    # `i`, or the next character boundary after it (the subject is valid UTF-8).
    private def self.boundary(subject : String, i : Int32) : Int32
      while i < subject.bytesize && (subject.to_unsafe[i] & 0xC0) == 0x80
        i += 1
      end
      i
    end

    private def self.char_width(subject : String, i : Int32) : Int32
      i < subject.bytesize ? boundary(subject, i + 1) - i : 1
    end

    # Raw offset <-> scrubbed-subject offset, for a body `Utf8.text` had to scrub. Asked in
    # nondecreasing order, so it walks the body once however many matches there are; a valid
    # body is the identity and never walks.
    private class Unscrub
      def initialize(@bytes : Bytes, @scrubbed : Bool)
        @raw = 0
        @sub = 0
      end

      def to_raw(sub : Int32) : Int32
        return sub unless @scrubbed
        while @sub < sub && @raw < @bytes.size
          step
        end
        @raw
      end

      # The first character boundary at or after raw offset `raw`, as a subject offset.
      def to_subject(raw : Int32) : Int32
        unless @scrubbed
          while raw < @bytes.size && (@bytes[raw] & 0xC0) == 0x80
            raw += 1
          end
          return raw
        end
        while @raw < raw && @raw < @bytes.size
          step
        end
        @sub
      end

      private def step : Nil
        w = Utf8.width_at(@bytes.to_unsafe, @raw, @bytes.size)
        @raw += w == 0 ? 1 : w
        @sub += w == 0 ? 3 : w
      end
    end
  end
end
