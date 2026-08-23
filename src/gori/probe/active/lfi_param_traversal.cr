require "uri"
require "./types"
require "./insertion_points"
require "../../miner/types"
require "../../proxy/codec/http1"
require "../../proxy/codec/content_decode"

module Gori
  module Probe
    module Active
      # Active parameter path-traversal / LFI probe (a self-referential byte differential, sibling of
      # NginxAliasTraversal but keyed on a PARAMETER value instead of the URL path). When a
      # parameter names a file the server reads off disk (`?file=doc.pdf`, `?page=home.html`), an
      # un-canonicalized read resolves `..` segments — the local-file-inclusion / path-traversal
      # class. Passive analysis cannot tell such a parameter apart from any other string.
      #
      # For one in-scope flow whose captured response was a 2xx with a body, it re-fetches THE SAME
      # resource through a folded `..` in the parameter value:
      #     file=doc.pdf  ->  file=x/../doc.pdf   (and an encoded  x/%2e%2e/  variant)
      # plus a CONTROL that cannot normalize back:
      #     file=x/zzznope/doc.pdf
      # On a vulnerable server the folded value resolves to the very same file and returns
      # byte-identical content to the captured baseline, while the control (a real, non-existent
      # subdirectory) does NOT. That control is the crucial guard a bare byte-diff on a *value* needs:
      # a catch-all / SPA router that returns the same page for EVERY value would byte-match the fold
      # with no traversal bug — but it also matches the control, so `control != baseline` suppresses it.
      #
      # Non-intrusive: it re-reads a file the browser already fetched (no `/etc/passwd`). Gated hard:
      #   * GET by default (the confirmation compares BODIES → HEAD out); Options#allow_unsafe widens
      #     to other body-bearing methods for a deliberate manual/AGGRESSIVE run.
      #   * 2xx captured status with a non-empty body — there must be a real served resource + baseline.
      #   * a PATH-LIKE parameter (value holds a `/` or a file extension, or a known file-ish name) whose
      #     value does not already contain `..` — so arbitrary params aren't probed.
      # Insertion points come from the shared `InsertionPoints` model (query today).
      class LfiParamTraversal < Rule
        FOLD     = "x/../"      # value -> x/../value          (literal ..)
        ENC_FOLD = "x/%2e%2e/"  # value -> x/%2e%2e/value      (encoded .. — defeats a literal-".." filter)
        CONTROL  = "x/zzznope/" # value -> x/zzznope/value     (a real subdir that cannot normalize back)

        # Param names that conventionally carry a filesystem path/filename — and little else.
        # `name`, `url`, `view`, `page`, and `load` were dropped: `?name=John`, `?view=grid`, and
        # `?page=2` are ordinary application parameters, and this name list is checked REGARDLESS
        # of the value, so each of them alone sent three probes at a large share of all traffic.
        # Nothing is lost by dropping them — a genuinely file-shaped value under any name still
        # qualifies through the `/` or file-extension tests below.
        KNOWN_FILE_PARAMS = Set{"file", "filename", "filepath", "path", "template", "doc",
                                "document", "download", "include", "dir", "folder"}
        # File-extension tells. The extension must not be followed by another word character, so
        # `.js` no longer matches inside `.json` and `.md` no longer matches inside `.mdx` — the
        # old plain `includes?` treated both as file-like.
        FILE_EXT = /\.(?:pdf|js|css|png|jpe?g|gif|svg|txt|json|xml|html?|php|log|csv|md|ya?ml|ini|conf)(?![0-9a-z])/i
        # A value that is only digits is an identifier, never a traversal-useful filename. Guards
        # the NAME-based branch, where the value is otherwise unconstrained (`?doc=1234`).
        NUMERIC_VALUE = /\A\d+\z/

        def info : RuleInfo
          RuleInfo.new("lfi_param_traversal", "Parameter path traversal",
            "Re-fetches a file parameter through a folded `..` (file=x/../doc) and flags a byte-identical hit.",
            Category::ACTIVE)
        end

        def requests_per_flow : Range(Int32, Int32)
          3..3 # fold + encoded-fold + control
        end

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          s, slot = gate(detail, opts) || return nil
          InsertionPoints.dedup_key("lfi_param_traversal", detail, s.method, s.path, [slot])
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          s, slot = gate(detail, opts) || return nil
          fold = InsertionPoints.build(detail, [{slot, InsertionPoints::Change.new(prefix: FOLD)}])
          followups = [
            InsertionPoints.build(detail, [{slot, InsertionPoints::Change.new(prefix: ENC_FOLD)}]),
            InsertionPoints.build(detail, [{slot, InsertionPoints::Change.new(prefix: CONTROL)}]),
          ]
          key = InsertionPoints.dedup_key("lfi_param_traversal", detail, s.method, s.path, [slot])
          Plan.new(fold, [Param.new(slot.loc.label, slot.name, "")], key, followups)
        end

        # The differential: flag High iff a folded variant (literal or encoded `..`) returned
        # byte-identical content to the CAPTURED baseline AND the control did not. results = [fold,
        # enc-fold, control].
        def detections_all(plan : Plan, results : Array(Repeater::Result), detail : Store::FlowDetail) : Array(Detection)
          base = decoded_body(detail.response_head, detail.response_body)
          return [] of Detection if base.nil? || base.empty?
          control = results[2]?
          return [] of Detection unless control && control.ok?
          control_body = decoded_body(control.head, control.body)
          # A catch-all that already serves the baseline for the control (a nonexistent subdir) has no
          # traversal signal — the byte-match below would fire on everything, so suppress it here.
          return [] of Detection if control_body && control_body == base
          hit = matching_fold(results, base) || return [] of Detection

          name = plan.params.first?.try(&.name) || "?"
          [Detection.new("lfi_param_traversal", Category::ACTIVE, detail.row.host, detail.row.url,
            "Parameter path traversal (file read via folded `..`)", Store::Severity::High,
            "param `#{name}`: folded `..` (#{hit}) returned byte-identical content; control differs"[0, 120],
            detail.row.id)]
        rescue
          [] of Detection
        end

        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          detections_all(plan, [result], detail)
        end

        # The label of the first folded variant (literal or encoded `..`) whose 2xx response
        # byte-matches the captured baseline, or nil if neither did.
        private def matching_fold(results : Array(Repeater::Result), base : Bytes) : String?
          [{results[0]?, FOLD}, {results[1]?, ENC_FOLD}].each do |(r, label)|
            next unless r && r.ok?
            next unless (200..299).includes?(probe_status(r))
            b = decoded_body(r.head, r.body)
            return label if b && b == base
          end
          nil
        end

        # Shared gate for plan + dedup_key. Returns {surface, the first path-like slot (name
        # scrubbed for PCRE/evidence safety)} for an eligible flow, else nil. The scrub stays here
        # rather than in InsertionPoints: `path_like?` runs PCRE (`FILE_EXT`/`NUMERIC_VALUE`) over
        # the value, and Crystal's Regex RAISES on non-UTF-8; the module keeps values UNSCRUBBED so
        # rules that re-send them (all the others) preserve bytes, and lfi scrubs at the point of use.
        private def gate(detail : Store::FlowDetail, opts : Options) : {InsertionPoints::Surface, InsertionPoints::Slot}?
          s = InsertionPoints.enumerate(detail, opts, InsertionPoints::DEFAULT_LOCATIONS) || return nil
          return nil unless diff_method_allowed?(s.method, opts)
          status = detail.row.status
          return nil unless status && (200..299).includes?(status)
          rb = detail.response_body
          return nil if rb.nil? || rb.empty?
          found = s.slots.find do |slot|
            next false if slot.raw_value.empty?
            v = slot.value.scrub
            next false if v.includes?("..") # already-traversing / degenerate
            path_like?(slot.name.scrub, v)
          end
          return nil unless found
          {s, found.copy_with(name: found.name.scrub)}
        end

        # Path-like: the value carries a `/` or a file-extension tell, or the name is a conventional
        # file/path parameter AND the value is not a bare identifier.
        private def path_like?(name : String, value : String) : Bool
          return true if value.includes?('/')
          return true if FILE_EXT.matches?(value)
          KNOWN_FILE_PARAMS.includes?(name.downcase) && !NUMERIC_VALUE.matches?(value)
        end

        private def probe_status(result : Repeater::Result) : Int32
          if r = result.response
            return r.status
          end
          Proxy::Codec::Http1.parse_response_head(result.head).status
        rescue
          0
        end

        # Inflate + cap at BODY_CAP for a byte-comparable buffer (both sides capped identically, so a
        # capture-truncated baseline compares against an equally-capped probe). nil when no body.
        private def decoded_body(head : Bytes?, body : Bytes?) : Bytes?
          return nil if body.nil? || body.empty?
          decoded, _ = Proxy::Codec::ContentDecode.decode(head, body, BODY_CAP)
          b = decoded || body
          b[0, {b.size, BODY_CAP}.min]
        end
      end
    end
  end
end
