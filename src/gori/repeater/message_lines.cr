require "digest/sha256"
require "../proxy/codec/content_decode"
require "../env"

module Gori
  module Repeater
    # head + body → plain display lines, shared by the Repeater response diff and the
    # Comparer tab so neither duplicates the decode/split logic. `decode` de-gzips/
    # de-chunks the body for a readable diff (responses only); request bytes are
    # passed through raw so a request comparison stays byte-faithful.
    module MessageLines
      extend self

      # NUL within the leading bytes ⇒ treat the body as binary (git/grep's detector).
      # Bounded so a multi-MiB body is O(1) to classify.
      BINARY_SNIFF_LIMIT = 8192

      # No "press x"/hex-view pointer here, unlike the History detail pane's placeholder:
      # this text is shared by the Comparer tab (no hex view; `x` there selects the diff
      # row instead — see `comparer.select-line`) and by the non-interactive CLI/MCP
      # `compare` output, where no keypress applies at all.

      # The head, a blank separator, then the body — each split into rstripped lines.
      # A BINARY body (NUL in its prefix) is shown as a one-line placeholder, never as
      # text: rendering raw non-UTF-8 bytes here (Comparer + the Repeater response diff)
      # reintroduced PR#86's terminal corruption — accidental wide/emoji graphemes among
      # the bytes desync the terminal's cursor tracking. Text lines are scrubbed too.
      #
      # `error` (a flow's `state: error` reason — Sandbox-blocked, connection refused, etc.)
      # is prepended as its own line, same placement as `gori run show`'s "error: …" line.
      # Without it, an errored flow has no head/body at all and this returns an empty array,
      # so a diff against it renders as an unexplained "response removed" — every line of the
      # OTHER side deleted, with no hint why — instead of showing the actual, more useful fact.
      def of(head : Bytes?, body : Bytes?, *, decode : Bool, error : String? = nil) : Array(String)
        b = decode ? display_body(head, body) : body
        lines = error ? ["error: #{error}"] : [] of String
        lines.concat(head_lines(head))
        if b && !b.empty?
          # Only when the head did not already end in one — see `head_lines`. A source that
          # hands the WHOLE message over as `head` (a Repeater send, a fuzz row: one wire blob,
          # `body` nil) carries its own separator, and a source that splits the two does now
          # as well, so both shapes of the SAME message produce the same lines. They did not:
          # a captured request diffed against the Repeater re-send of it reported two changed
          # lines — both of them blank — over byte-identical requests.
          lines << "" unless lines.last?.try(&.empty?)
          if binary?(b)
            lines << "— binary body (#{b.size} bytes, sha256 #{short_digest(b)}) — not shown as text —"
          else
            text = String.new(b)
            lines.concat(text_lines(text))
            # `.scrub` maps every invalid byte to the same U+FFFD, so two bodies differing only
            # in those bytes would split to identical lines. The digest line is what tells them
            # apart; a valid-UTF-8 body never gets one.
            unless text.valid_encoding?
              lines << "— body is not valid UTF-8 (shown with �), sha256 #{short_digest(b)} —"
            end
          end
        end
        lines
      end

      # These lines are a DISPLAY projection, and every diff consumer (Comparer, CLI/MCP
      # `compare`) decides equality on them. So wherever the projection drops bytes — a binary
      # body collapsed to one placeholder, invalid UTF-8 scrubbed to U+FFFD — the line has to
      # carry the bytes' identity, or two different bodies of one size compare as "no
      # differences" (#1162). 16 hex digits: an identity for a diff, not a security claim.
      private def short_digest(bytes : Bytes) : String
        Digest::SHA256.hexdigest(bytes)[0, 16]
      end

      # A whole wire message as {head, body}, split at the one shared boundary, for a source
      # that holds the request as a single blob (a Repeater send, a fuzz row). Without it the
      # blob's body reaches `of` as part of the HEAD and skips the binary / UTF-8 handling a
      # split source's body gets. Deliberately NOT applied inside `of`: a captured head that
      # simply has no body can hold a bare-LF blank line INSIDE it (the proxy ends a head only
      # at CRLFCRLF), and splitting there would misread the rest of that head as a body.
      def split_wire(blob : Bytes) : {Bytes, Bytes?}
        at = Env.head_body_boundary(blob)
        at < blob.size ? {blob[0, at], blob[at..]} : {blob, nil}
      end

      # The head's lines, WITHOUT the empty trailing field `split` leaves behind for its final
      # newline. That field is an artifact of the split, not a line of the message; dropping it
      # leaves the head's own terminating BLANK LINE as the last entry, which is exactly the
      # head/body separator — so it is stated once instead of three times (blank line, split
      # artifact, appended separator).
      private def head_lines(head : Bytes?) : Array(String)
        hl = bytes_to_lines(head)
        hl.pop if head && !head.empty? && head[head.size - 1] == 0x0Au8 && !hl.empty?
        hl
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
        text_lines(String.new(bytes))
      end

      # `.scrub` maps invalid UTF-8 to U+FFFD (width 1) so a stray non-UTF-8 byte in
      # an otherwise-text body can't smuggle a wide/emoji grapheme that desyncs the
      # terminal cursor (the same guard the History detail view applies).
      private def text_lines(text : String) : Array(String)
        text.scrub.split('\n').map(&.rstrip('\r'))
      end
    end
  end
end
