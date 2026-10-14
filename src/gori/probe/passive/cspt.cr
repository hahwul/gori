require "./rule"
require "./js_scan"

module Gori
  module Probe
    module Passive
      # Client-side path traversal suspicion (category "client"): a page/bundle script builds a
      # request URL from a URL-controlled value without encoding it — `fetch(`/api/u/${id}`)` with
      # `id` from the hash or a router param. A `../` in that value re-points the request at
      # another same-origin endpoint with the victim's cookies, and with a state-changing method
      # it is CSRF that SameSite and anti-CSRF tokens do not stop (Doyensec, CSPT2CSRF). Same
      # heuristic standing as `dom_xss`: one statement, no dataflow through variables.
      class Cspt < Rule
        def info : RuleInfo
          RuleInfo.new("cspt", "Client-side path traversal (suspected)",
            "Flags a URL-controlled value (location.hash, a router param, …) placed unencoded in the URL " \
            "argument of a request call (fetch, XMLHttpRequest, axios, jQuery.ajax) in a page/bundle script.",
            Category::CLIENT)
        end

        # A message listener, read from the comment-stripped view (the event name is a string).
        # Only then does `e.data` count as postMessage data.
        MESSAGE_LISTENER = Utf8.tolerant(/addEventListener\s*\(\s*["'`]message["'`]|\bonmessage\b/)

        def check(ctx : Context, acc : Array(Detection)) : Nil
          scripts = ctx.client_code
          return if scripts.empty? # before the Set: most flows carry no script
          seen = Set({String, String}).new
          scripts.each_with_index do |code, i|
            index = ctx.client_source_index[i]
            messages = index.any? { |(_, label)| label == "postMessage data" } &&
                       MESSAGE_LISTENER.matches?(ctx.client_scripts_nocomment[i])
            JsScan.request_source_pairs(code, index, messages, ctx.client_scripts_nocomment[i]).each do |(src, sink)|
              next unless seen.add?({src, sink})
              acc << Detection.new("cspt_suspected", Category::CLIENT, ctx.host, ctx.url,
                "Possible client-side path traversal (#{sink})", Store::Severity::Low,
                "#{src} → #{sink}", ctx.fid)
            end
          end
        end
      end
    end
  end
end
