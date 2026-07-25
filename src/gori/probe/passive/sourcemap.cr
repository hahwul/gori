require "./rule"
require "../../proxy/codec/content_decode"

module Gori
  module Probe
    module Passive
      # Source maps shipped alongside a production script (category "infoleak"): a
      # `//# sourceMappingURL=…` comment (or a `SourceMap:` / `X-SourceMap:` response header)
      # hands anyone the recipe for reconstructing the ORIGINAL sources — pre-minification names,
      # developer comments, internal paths, dead code, sometimes whole unshipped modules.
      #
      # The reference itself is the binary signal, so the check is exact: either the comment/
      # header is there or it isn't. What passive analysis CANNOT do is fetch the `.map` to prove
      # it's actually served (many builds emit the comment but never deploy the file), so a plain
      # reference is Info, "verify the .map is reachable". An INLINE map (`data:` URI) needs no
      # such verification — the sources are embedded in the very response we captured — so that
      # one is Low.
      #
      # JS responses only. A CSS `sourceMappingURL` is the same class of exposure but a much
      # smaller one (a preprocessor's stylesheet), and is left out to keep the rule's signal high.
      class SourceMap < Rule
        def info : RuleInfo
          RuleInfo.new("sourcemap", "Source map exposure",
            "Flags production JavaScript that points at its source map, from which the original sources can be reconstructed.",
            Category::INFOLEAK)
        end

        # `//# sourceMappingURL=…`, the legacy `//@` form, and the block-comment `/*# … */` form.
        # The value stops at whitespace, a quote, or a `*` (the block comment's terminator).
        MARKER = /\/[\/*][#@]\s*sourceMappingURL\s*=\s*([^\s'"*]+)/
        # The regex opens on `//`, a byte pair that occurs constantly in a minified bundle (every
        # URL, every regex literal), so PCRE's first-byte optimization can't skip ahead. This
        # allocation-free literal test can, and a body without the word cannot match.
        NEEDLE = "sourceMappingURL"

        # The comment sits at the very END of a bundle, i.e. exactly where the shared body prefix
        # (Context::CLIENT_BODY_CAP) gets cut — the big production bundles that matter most would
        # be the ones systematically missed. So when the prefix scan comes up empty AND the shared
        # decode hit its cap (`ctx.body_capped?` — the body really is longer than what was
        # scanned), decode once more and look at the tail. Bounded three ways: JS responses only,
        # truncated bodies only, and only after the free prefix scan has already missed.
        TAIL_DECODE_CAP = 8 * 1024 * 1024
        TAIL_WINDOW     = 8 * 1024

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless resp = ctx.response
          # The header form, emitted instead of the comment by some bundlers/CDNs. It is a
          # response header, so it needs no body at all and is checked for any content type.
          if hdr = resp.headers.get?("SourceMap") || resp.headers.get?("X-SourceMap")
            return emit(ctx, acc, hdr)
          end
          return unless ctx.js?
          text = ctx.client_body_text
          return if text.nil? || text.empty?
          if text.includes?(NEEDLE) && (m = MARKER.match(text))
            return emit(ctx, acc, m[1])
          end
          return unless tail = tail_text(ctx)
          if tail.includes?(NEEDLE) && (m = MARKER.match(tail))
            emit(ctx, acc, m[1])
          end
        end

        private def emit(ctx : Context, acc : Array(Detection), reference : String) : Nil
          inline = reference.lstrip.starts_with?("data:")
          acc << Detection.new("sourcemap_exposed", Category::INFOLEAK, ctx.host, ctx.url,
            "Source map reference in a production script",
            inline ? Store::Severity::Low : Store::Severity::Info,
            inline ? "inline data: URI" : safe_ref(reference), ctx.fid)
        end

        # Last TAIL_WINDOW bytes of the fully decoded body, or nil when the prefix already covered
        # the whole file (nothing left to look at). Decoding is tolerant and never raises.
        private def tail_text(ctx : Context) : String?
          return nil unless ctx.body_capped?
          body = ctx.detail.response_body
          return nil if body.nil? || body.empty?
          decoded, _ = Proxy::Codec::ContentDecode.decode(ctx.detail.response_head, body, TAIL_DECODE_CAP)
          bytes = decoded || body
          return nil if bytes.size <= Context::CLIENT_BODY_CAP
          String.new(bytes[(bytes.size - TAIL_WINDOW)..]).scrub
        end

        # The reference is server-controlled text landing in stored evidence + the TUI: keep it
        # printable and short. A map reference is a URL/filename, so nothing real is lost.
        private def safe_ref(ref : String) : String
          cleaned = ref.scrub.gsub(/[^\x20-\x7e]/, "")
          cleaned = cleaned[0, 96] if cleaned.size > 96
          cleaned.empty? ? "sourceMappingURL" : cleaned
        end
      end
    end
  end
end
