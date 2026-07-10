require "../issue"
require "../../store"
require "../../replay/engine"

module Gori
  module Prism
    # The lightweight active scan: each rule builds ONE probe per in-scope flow, the analyzer
    # sends it, and the rule interprets the response. Pure: rules depend only on the codec, the
    # body decoder, and the Fuzz sender — no Store/TUI. One rule per file under `active/`;
    # register new ones in `Active::RULES` (active.cr).
    module Active
      BODY_CAP   = 64 * 1024
      MAX_PARAMS = 50 # don't probe pathological param sets (request-size / canary budget)

      # Only methods WITHOUT side effects are probed. The active scan runs automatically over
      # captured traffic, so re-sending a POST/PUT/PATCH/DELETE with canary values would cause
      # real server-side mutations (duplicate records, messages, deletions). Reflected-XSS via
      # query parameters — the common case — is fully covered by GET/HEAD.
      SAFE_METHODS = Set{"GET", "HEAD"}

      record Param, location : String, name : String, canary : String

      # A built probe: the canary-stuffed request bytes, the canary↔param map, and the dedup key
      # the analyzer uses to probe each (rule, host, method, path, param-set) only once.
      record Plan, request : Bytes, params : Array(Param), dedup_key : String

      # Strip a scheme://authority prefix so an absolute-form (forward-proxy) target becomes
      # origin-form; an already-origin-form target passes through unchanged. The authority
      # ends at the FIRST '/', '?', or '#', so a pathless absolute-URI carrying a query
      # ("http://h?q=v") normalizes to "/?q=v" — the query (and its reflectable params) is
      # preserved, not silently dropped to "/" — and a '/' that appears only INSIDE the query
      # ("http://h?next=/x") is never mistaken for the start of the path.
      def self.origin_form(target : String) : String
        return target unless target.starts_with?("http://") || target.starts_with?("https://")
        scheme_end = target.index("://") || return target
        rest = target[(scheme_end + 3)..]
        cut = rest.index(/[\/?#]/) || return "/"
        seg = rest[cut..]
        seg.starts_with?('/') ? seg : "/#{seg}"
      end

      # An active rule: build a probe for one flow (nil if nothing to test), then turn the
      # probe's response into Detections. The analyzer owns the send between the two calls.
      abstract class Rule
        abstract def plan(detail : Store::FlowDetail) : Plan?
        abstract def detections(plan : Plan, result : Replay::Result, detail : Store::FlowDetail) : Array(Detection)
      end
    end
  end
end
