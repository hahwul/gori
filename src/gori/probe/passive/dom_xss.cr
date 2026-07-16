require "./rule"
require "./js_scan"

module Gori
  module Probe
    module Passive
      # DOM-based XSS suspicion (category "client"). For each inline/loaded script (already
      # stripped of comments and string literals by JsScan, so noise inside strings/comments is
      # gone) it correlates a DOM taint SOURCE (location.hash, document.URL, postMessage data, …)
      # with an HTML/JS execution SINK (innerHTML, document.write, eval, …) that occur in the
      # SAME statement. This is a heuristic — not sound taint tracking — so it deliberately does
      # NOT flag a bare sink, and it can't follow a source through an intermediate variable.
      class DomXss < Rule
        def info : RuleInfo
          RuleInfo.new("dom_xss", "DOM-based XSS (suspected)",
            "Flags a DOM taint source (location.hash, document.URL, postMessage data, …) flowing into an execution sink (innerHTML, document.write, eval, …) in the same statement of a page/bundle script.",
            Category::CLIENT)
        end

        def check(ctx : Context, acc : Array(Detection)) : Nil
          scripts = ctx.client_code
          return if scripts.empty?
          seen = Set(String).new
          scripts.each do |code|
            JsScan.source_sink_pairs(code).each do |(src, sink)|
              # One detection per distinct source->sink shape on the host (grouping is by
              # (code, host); the pair only needs to surface once).
              next unless seen.add?("#{src} #{sink}")
              acc << Detection.new("dom_xss", Category::CLIENT, ctx.host, ctx.url,
                "Possible DOM-based XSS (#{sink} sink)", Store::Severity::Medium,
                "#{src} → #{sink}", ctx.fid)
            end
          end
        end
      end
    end
  end
end
