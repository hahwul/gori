require "../issue"
require "../../store"
require "../../repeater/engine"

module Gori
  module Probe
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
        # Find the authority terminator with Char index, not a regex: `target` derives from a
        # captured request and can be invalid UTF-8, which would make a PCRE `index(/[\/?#]/)`
        # raise on the active-probe planning path (only partly rescued). index(Char) is byte-safe
        # and preserves the target's bytes for the re-sent probe. Mirrors from_repeater.cr's idiom.
        cut = [rest.index('/'), rest.index('?'), rest.index('#')].compact.min? || return "/"
        seg = rest[cut..]
        seg.starts_with?('/') ? seg : "/#{seg}"
      end

      # An active rule: build a probe for one flow (nil if nothing to test), then turn the
      # probe's response into Detections. The analyzer owns the send between the two calls.
      abstract class Rule
        # The probe's dedup key WITHOUT building the probe — same value as `plan(detail).dedup_key`
        # (nil exactly when `plan` returns nil). The analyzer checks this against the seen-set
        # BEFORE calling `plan`, so a repeat surface (the common case in steady browsing) skips
        # the expensive canary generation + request rebuild that `plan` does. MUST stay identical
        # to the key `plan` produces or the seen-set would re-probe / skip (see the equivalence spec).
        abstract def dedup_key(detail : Store::FlowDetail) : String?
        abstract def plan(detail : Store::FlowDetail) : Plan?
        abstract def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)

        # Static identity for the Rules sub-tab (list + per-rule enable/disable). One RuleInfo
        # per class; the analyzer skips a rule when its `info.id` is in the project disabled set.
        abstract def info : RuleInfo
      end
    end
  end
end
