require "./rule"

module Gori
  module Probe
    module Passive
      # A response head that ends a line on a bare LF (category "headers"). RFC 9112 §2.2 lets a
      # recipient accept one, browsers do, and so does gori's response reader
      # (`Http1.read_response_head_result`), which is why the page renders through the proxy.
      # But it is still a parser differential: a CRLF-only recipient does not end the line (or
      # the head) there, one that also ends lines on a lone CR reads it differently again, and
      # which of them sits in front of the origin decides where this message's body starts. That
      # is the precondition for a response desync or response splitting, so the flow is marked
      # rather than silently normalised — gori keeps the bytes as they came (P7).
      #
      # Reads the stored head's bytes, not a parsed header, so it sees an LF terminator and an LF
      # inside a CRLFCRLF head alike. An h2 flow's head is gori's own CRLF synthesis and never
      # fires. One finding per host: the analyzer groups detections on code + host, and a device
      # that does this does it on every route.
      class BareLfResponse < Rule
        def info : RuleInfo
          RuleInfo.new("bare_lf_response", "Bare-LF response head",
            "Flags a response head that ends lines with a bare LF instead of CRLF, where parsers can disagree on the message's framing (a response desync / splitting precondition).",
            Category::HEADERS)
        end

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless resp = ctx.raw_response
          head = resp.raw_head
          return unless Proxy::Codec::Http1.bare_lf?(head)
          evidence = if Proxy::Codec::Http1.lf_terminated_head?(head)
                       "head ends on a bare-LF blank line (framed off the lenient LF reading)"
                     else
                       "bare LF inside a CRLF-terminated head"
                     end
          acc << Detection.new("bare_lf_response", Category::HEADERS, ctx.host, ctx.url,
            "Response head uses bare-LF line endings", Store::Severity::Low, evidence, ctx.fid)
        end
      end
    end
  end
end
