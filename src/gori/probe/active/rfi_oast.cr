require "uri"
require "./types"
require "../out_of_band"
require "./insertion_points"
require "../../fuzz/content_length"
require "../../proxy/codec/http1"

module Gori
  module Probe
    module Active
      # Active remote-file-inclusion probe, OUT-OF-BAND. When an include/require path is
      # assembled from a request parameter, replacing an existing path-like value with an
      # attacker-controlled remote resource can make the target fetch (and, on vulnerable
      # runtimes, execute) code from outside the application. The request sent to the target
      # does not carry a reliable in-band proof: a successful include can return the same page,
      # suppress errors, or execute in a background path. The OAST callback is therefore the
      # confirmation seam, just as it is for blind SSRF.
      #
      # The probe deliberately stays close to the captured surface:
      #   * it runs only with a registered OAST minter, so a project without a listener does not
      #     spend requests on a check it cannot confirm;
      #   * it considers only an existing include-shaped slot — a URL/path/filename value, or a
      #     conventional file/page/template/lang parameter — and probes the first one only;
      #   * the default method gate is GET/HEAD, while unsafe methods require the same explicit
      #     opt-in as SsrfOast; eligible form/JSON body slots are covered when that gate passes;
      #   * the generated URL carries a marker and a language-shaped wrapper in its query. A
      #     custom OAST resource that echoes or serves that marker can distinguish execution from
      #     a bare fetch; the generic callback still remains the provider-agnostic proof path.
      class RfiOast < Rule
        # Names commonly used for a file, view, template, locale or include target. This list is
        # intentionally narrower than a generic parameter wordlist: every member costs an OAST
        # payload on every qualifying flow.
        RFI_PARAMS = Set{"file", "filename", "file_name", "filepath", "path", "page", "template",
                         "tmpl", "include", "inc", "view", "layout", "module", "resource",
                         "document", "doc", "load", "source", "src", "lang", "locale"}

        # A value that already names a likely remote/local resource. A URL under a conventional
        # include name is an RFI candidate; an arbitrary URL stays with SsrfOast so one URL slot
        # does not plant two indistinguishable OAST probes. A path or known filename extension is
        # useful evidence even when the application calls the parameter something less obvious.
        FILE_EXT      = /\.(?:php[0-9]*|phtml|inc|jsp|jspx|asp|aspx|cfm|cfc|shtml|html?|txt|xml|ya?ml|ini|conf|log|csv|md)(?:[\/?#]|\z)/i
        NUMERIC_VALUE = /\A\d+\z/
        LANGUAGE_EXT  = /\.(php[0-9]*|phtml|jsp|jspx|asp|aspx)(?:[\/?#]|\z)/i

        def info : RuleInfo
          RuleInfo.new("rfi_oast", "Remote file inclusion (out-of-band)",
            "Points one include-shaped parameter at a language-marked OAST resource and flags the finding when the server calls back.",
            Category::ACTIVE)
        end

        def requests_per_flow : Range(Int32, Int32)
          1..1
        end

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          # No minter means no plan, so the cheap pre-plan key must be nil as well. `gate` does
          # not mint and is shared with `plan`, preserving the analyzer's equivalence invariant.
          return nil unless opts.oob
          surface, slot = gate(detail, opts) || return nil
          InsertionPoints.dedup_key("rfi_oast", detail, surface.method, surface.path, [slot])
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          minter = opts.oob || return nil
          surface, slot = gate(detail, opts) || return nil
          payload, token, session_id = minter.mint || return nil
          injected = inject_url(payload, token, slot.value)
          change = InsertionPoints::Change.new(replace: injected)
          request = InsertionPoints.build(detail, [{slot, change}])
          # InsertionPoints rebuilds bodies and synchronizes their Content-Length. Keep this
          # explicit alongside SsrfOast: it documents why a body-bearing HTTP/2 capture is safe
          # to replay through the HTTP/1.1 sender, while query-only probes remain unchanged.
          request = Fuzz::ContentLength.sync(request, true) unless slot.loc.query?
          marker = marker_for(token)
          candidate = OutOfBand::Candidate.new(
            token: token, payload: payload, session_id: session_id,
            code: "rfi_oast",
            title: "Remote file inclusion (server included an attacker-controlled remote resource)",
            severity: Store::Severity::High,
            evidence: "#{slot.loc.label} param `#{slot.name.scrub}` carried an RFI marker `#{marker}`"[0, 120])
          key = InsertionPoints.dedup_key("rfi_oast", detail, surface.method, surface.path, [slot])
          Plan.new(request, [Param.new(slot.loc.label, slot.name.scrub, token)], key, oob: [candidate])
        end

        # Blind by construction: the response on the sending socket cannot reliably tell a
        # remote fetch from a remote include. Promotion happens in `OutOfBand.sweep` after the
        # OAST listener receives the callback.
        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          [] of Detection
        end

        # Shared structural gate for `dedup_key` and `plan`. It offers the same query/form/JSON
        # surfaces as SSRF, but admits only slots whose existing value or name suggests a file
        # inclusion sink. Body parsing stays bounded and refuses ambiguous framing/encoding.
        private def gate(detail : Store::FlowDetail, opts : Options) : {InsertionPoints::Surface, InsertionPoints::Slot}?
          method, _, malformed = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          return nil if malformed || !method_allowed?(method.upcase, opts)
          locations = body_eligible?(detail) ? InsertionPoints::DEFAULT_LOCATIONS : [Miner::Location::Query]
          surface = InsertionPoints.enumerate(detail, opts, locations) || return nil
          slot = surface.slots.first(opts.max_params).find do |candidate|
            rfi_shaped?(candidate.name.scrub, candidate.value.scrub)
          end
          slot ? {surface, slot} : nil
        end

        private def body_eligible?(detail : Store::FlowDetail) : Bool
          body = detail.request_body || return false
          return false if body.empty? || body.size > BODY_CAP || detail.request_body_truncated?
          return false if Proxy::Codec::Http1.obfuscated_header?(detail.request_head)
          req = Proxy::Codec::Http1.parse_request_head(detail.request_head)
          return false if req.malformed? || req.headers.get?("Transfer-Encoding")
          return false unless req.headers.get_all("Content-Encoding").all? { |v| v.strip.downcase == "identity" }
          types = req.headers.get_all("Content-Type")
          return false unless types.size == 1
          injectable_type?(types.first)
        end

        private def injectable_type?(value : String) : Bool
          media = value.split(';', 2).first.strip.downcase
          media == "application/x-www-form-urlencoded" || media == "application/json" ||
            (media.starts_with?("application/") && media.ends_with?("+json"))
        end

        private def rfi_shaped?(name : String, value : String) : Bool
          return false if value.empty?
          known_name = RFI_PARAMS.includes?(name.downcase)
          return known_name if Active.url_authority(value)
          return true if path_like?(value)
          known_name && !NUMERIC_VALUE.matches?(value)
        end

        private def path_like?(value : String) : Bool
          value.starts_with?('/') || value.starts_with?("./") || value.starts_with?("../") ||
            value.includes?('/') || value.includes?('\\') || FILE_EXT.matches?(value)
        end

        # The marker is intentionally in the URL's query rather than appended to a provider
        # path: custom-http listeners often expose one exact polling endpoint, and webhook.site /
        # postbin payloads already use their path for the provider's own correlation id. A server
        # configured to echo or execute the remote resource can use the marker/code pair; all
        # providers still retain the original token so OutOfBand can attribute the callback.
        private def inject_url(payload : String, token : String, original : String) : String
          url = payload.includes?("://") ? payload : "http://#{payload}"
          ext = language_extension(original)
          marker = marker_for(token)
          wrapper = language_wrapper(ext, marker)
          add_query(url, [
            {"gori_rfi_file", "#{marker}#{ext}"},
            {"gori_rfi_marker", marker},
            {"gori_rfi_code", wrapper},
          ] of {String, String})
        end

        private def marker_for(token : String) : String
          # Provider tokens are generated from URL-safe nonces and remain untouched for OAST
          # matching.
          "gori-rfi-#{token}"
        end

        private def language_extension(value : String) : String
          text = value.scrub
          if match = LANGUAGE_EXT.match(text)
            ext = match[1].downcase
            return ".#{ext.starts_with?("php") ? "php" : ext}"
          end
          case text.downcase
          when "php", "phtml" then ".php"
          when "jsp", "jspx"  then ".jsp"
          when "asp", "aspx"  then ".asp"
          else                     ".php"
          end
        end

        private def language_wrapper(extension : String, marker : String) : String
          case extension
          when ".jsp", ".jspx" then "<% out.print(\"#{marker}\"); %>"
          when ".asp", ".aspx" then "<% Response.Write(\"#{marker}\") %>"
          else                      "<?php echo \"#{marker}\"; ?>"
          end
        end

        # Append marker parameters before a fragment (fragments never reach the remote server),
        # while preserving a provider's existing query and its original payload verbatim.
        private def add_query(url : String, fields : Array({String, String})) : String
          fragment = ""
          base = url
          if hash = base.index('#')
            fragment = base[hash..]
            base = base[0...hash]
          end
          separator = if base.includes?('?')
                        base.ends_with?('?') || base.ends_with?('&') ? "" : "&"
                      else
                        "?"
                      end
          query = fields.map { |(key, value)| "#{key}=#{URI.encode_www_form(value, space_to_plus: false)}" }.join('&')
          "#{base}#{separator}#{query}#{fragment}"
        end
      end
    end
  end
end
