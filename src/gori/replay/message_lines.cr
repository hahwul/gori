require "../proxy/codec/content_decode"

module Gori
  module Replay
    # head + body → plain display lines, shared by the Replay response diff and the
    # Comparer tab so neither duplicates the decode/split logic. `decode` de-gzips/
    # de-chunks the body for a readable diff (responses only); request bytes are
    # passed through raw so a request comparison stays byte-faithful.
    module MessageLines
      extend self

      # NUL within the leading bytes ⇒ treat the body as binary (git/grep's detector).
      # Bounded so a multi-MiB body is O(1) to classify.
      BINARY_SNIFF_LIMIT = 8192

      # The head, a blank separator, then the body — each split into rstripped lines.
      # A BINARY body (NUL in its prefix) is shown as a one-line placeholder, never as
      # text: rendering raw non-UTF-8 bytes here (Comparer + the Replay response diff)
      # reintroduced PR#86's terminal corruption — accidental wide/emoji graphemes among
      # the bytes desync the terminal's cursor tracking. Text lines are scrubbed too.
      def of(head : Bytes?, body : Bytes?, *, decode : Bool) : Array(String)
        b = decode ? display_body(head, body) : body
        lines = bytes_to_lines(head)
        if b && !b.empty?
          lines << ""
          if binary?(b)
            lines << "— binary body (#{b.size} bytes) — not shown as text; press x for the hex view —"
          else
            lines.concat(bytes_to_lines(b))
          end
        end
        lines
      end

      private def binary?(bytes : Bytes) : Bool
        n = {bytes.size, BINARY_SNIFF_LIMIT}.min
        n.times { |i| return true if bytes[i] == 0u8 }
        false
      end

      # A body decoded for display (gzip/deflate/br/zstd + de-chunk), or the raw body
      # when there's nothing to decode.
      def display_body(head : Bytes?, body : Bytes?) : Bytes?
        decoded, _ = Proxy::Codec::ContentDecode.decode(head, body)
        decoded || body
      end

      def bytes_to_lines(bytes : Bytes?) : Array(String)
        return [] of String unless bytes
        # `.scrub` maps invalid UTF-8 to U+FFFD (width 1) so a stray non-UTF-8 byte in
        # an otherwise-text body can't smuggle a wide/emoji grapheme that desyncs the
        # terminal cursor (the same guard the History detail view applies).
        String.new(bytes).scrub.split('\n').map(&.rstrip('\r'))
      end
    end
  end
end
