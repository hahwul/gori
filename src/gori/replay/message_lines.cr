require "../proxy/codec/content_decode"

module Gori
  module Replay
    # head + body → plain display lines, shared by the Replay response diff and the
    # Comparer tab so neither duplicates the decode/split logic. `decode` de-gzips/
    # de-chunks the body for a readable diff (responses only); request bytes are
    # passed through raw so a request comparison stays byte-faithful.
    module MessageLines
      extend self

      # The head, a blank separator, then the body — each split into rstripped lines.
      def of(head : Bytes?, body : Bytes?, *, decode : Bool) : Array(String)
        b = decode ? display_body(head, body) : body
        lines = bytes_to_lines(head)
        if b && !b.empty?
          lines << ""
          lines.concat(bytes_to_lines(b))
        end
        lines
      end

      # A body decoded for display (gzip/deflate/br/zstd + de-chunk), or the raw body
      # when there's nothing to decode.
      def display_body(head : Bytes?, body : Bytes?) : Bytes?
        decoded, _ = Proxy::Codec::ContentDecode.decode(head, body)
        decoded || body
      end

      def bytes_to_lines(bytes : Bytes?) : Array(String)
        return [] of String unless bytes
        String.new(bytes).split('\n').map(&.rstrip('\r'))
      end
    end
  end
end
