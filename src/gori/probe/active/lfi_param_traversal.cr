require "uri"
require "./types"
require "../../miner/inject"
require "../../fuzz/content_length"
require "../../proxy/codec/http1"
require "../../proxy/codec/content_decode"

module Gori
  module Probe
    module Active
      # Active parameter path-traversal / LFI probe (a self-referential byte differential, sibling of
      # NginxAliasTraversal but keyed on a PARAMETER value instead of the URL path). When a query
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
      class LfiParamTraversal < Rule
        FOLD     = "x/../"      # value -> x/../value          (literal ..)
        ENC_FOLD = "x/%2e%2e/"  # value -> x/%2e%2e/value      (encoded .. — defeats a literal-".." filter)
        CONTROL  = "x/zzznope/" # value -> x/zzznope/value     (a real subdir that cannot normalize back)

        # Query-param names that conventionally carry a filesystem path/filename — and little else.
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
          g = gate(detail, opts) || return nil
          key_string(detail, g[0], g[1], g[4])
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          g = gate(detail, opts) || return nil
          method_up, path, pairs, idx, name = g
          body = detail.request_body
          fold = rebuild_query(detail.request_head, body, path, with_prefix(pairs, idx, FOLD))
          followups = [
            rebuild_query(detail.request_head, body, path, with_prefix(pairs, idx, ENC_FOLD)),
            rebuild_query(detail.request_head, body, path, with_prefix(pairs, idx, CONTROL)),
          ]
          Plan.new(fold, [Param.new("query", name, "")], key_string(detail, method_up, path, name), followups)
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

        # Shared gate for plan + dedup_key. Returns {METHOD, path, all query pairs verbatim, the index
        # of the first path-like pair, its DECODED name} for an eligible GET with such a param, else nil.
        private def gate(detail : Store::FlowDetail, opts : Options) : {String, String, Array(String), Int32, String}?
          method, target, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed
          method_up = method.upcase
          return nil unless diff_method_allowed?(method_up, opts)
          status = detail.row.status
          return nil unless status && (200..299).includes?(status)
          rb = detail.response_body
          return nil if rb.nil? || rb.empty?
          path, query = split_target(Active.origin_form(target))
          return nil if query.empty?
          pairs = query.split('&')
          found = first_pathlike(pairs) || return nil
          {method_up, path, pairs, found[0], found[1]}
        end

        # {index, decoded name} of the first path-like query pair whose value does not already contain
        # `..`, or nil.
        private def first_pathlike(pairs : Array(String)) : {Int32, String}?
          pairs.each_with_index do |pair, i|
            next if pair.empty?
            eq = pair.index('=')
            next unless eq
            raw_name = pair[0...eq]
            next if raw_name.empty?
            raw_value = pair[(eq + 1)..]
            next if raw_value.empty?
            dvalue = decode(raw_value)
            next if dvalue.includes?("..") # already-traversing / degenerate
            dname = decode(raw_name)
            return {i, dname} if path_like?(dname, dvalue)
          end
          nil
        end

        # rule + host:PORT + METHOD + path + param name (a traversal is per-parameter). Length-prefix
        # the name so an odd char can't collide with the path segment.
        private def key_string(detail : Store::FlowDetail, method_upcase : String, path : String, name : String) : String
          "lfi_param_traversal|#{detail.row.host}:#{detail.row.port}|#{method_upcase}|#{path}|#{name.bytesize}:#{name}"
        end

        # Path-like: the value carries a `/` or a file-extension tell, or the name is a conventional
        # file/path parameter AND the value is not a bare identifier.
        private def path_like?(name : String, value : String) : Bool
          return true if value.includes?('/')
          return true if FILE_EXT.matches?(value)
          KNOWN_FILE_PARAMS.includes?(name.downcase) && !NUMERIC_VALUE.matches?(value)
        end

        # A copy of the query pairs with pair `idx`'s value prefixed (name kept verbatim, every other
        # segment untouched).
        private def with_prefix(pairs : Array(String), idx : Int32, prefix : String) : String
          dup = pairs.dup
          pair = dup[idx]
          if eq = pair.index('=')
            dup[idx] = "#{pair[0...eq]}=#{prefix}#{pair[(eq + 1)..]}"
          end
          dup.join('&')
        end

        private def decode(s : String) : String
          URI.decode_www_form(s)
        rescue
          s
        end

        # {path, query-without-'?'} — query is "" when the target has none.
        private def split_target(target : String) : {String, String}
          qi = target.index('?')
          return {target, ""} unless qi
          {target[0...qi], target[(qi + 1)..]}
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

        # Reassemble the request with a new query on the request line, preserving the body and
        # re-syncing Content-Length (mirrors ReflectedParam#rebuild / BackslashPowered#rebuild_query).
        private def rebuild_query(orig_head : Bytes, body : Bytes?, path : String, new_query : String) : Bytes
          head, _, eol = Miner::Inject.split(orig_head)
          lines = String.new(head).split(eol)
          unless lines.empty?
            parts = lines[0].split(' ')
            if parts.size == 3
              target = new_query.empty? ? path : "#{path}?#{new_query}"
              lines[0] = "#{parts[0]} #{target} #{parts[2]}"
            end
          end
          io = IO::Memory.new
          io << lines.join(eol) << eol << eol
          b = body || Bytes.empty
          io.write(b) unless b.empty?
          Fuzz::ContentLength.sync(io.to_slice, false)
        end
      end
    end
  end
end
