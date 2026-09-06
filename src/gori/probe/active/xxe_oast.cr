require "uri"
require "./types"
require "../../miner/inject"
require "../../fuzz/content_length"
require "../../proxy/codec/http1"

module Gori
  module Probe
    module Active
      # One external parameter entity in the captured XML document's prolog. Referencing it
      # inside the DTD tests external entity resolution without replacing application fields,
      # reading files, or trying a payload list. Only the OAST callback confirms a finding.
      # XML 1.0 §4.2.2 / §4.4.8: https://www.w3.org/TR/xml/
      class XxeOast < Rule
        # A bounded prolog recognizer, not an XML parser: never resolve captured entities
        # locally. Keep declarations, comments, namespace prefixes and body bytes intact.
        ROOT = /\A(\x{FEFF}?(?>[ \t\r\n]+|<\?.*?\?>|<!--.*?-->)*?)<([A-Za-z_][A-Za-z0-9_.:-]*)(?=[ \t\r\n\/>])/m

        def info : RuleInfo
          RuleInfo.new("xxe_oast", "XML external entity (out-of-band)",
            "Adds one external parameter entity to an XML body; an OAST callback confirms resolution. Needs unsafe opt-in.",
            Category::ACTIVE)
        end

        def dedup_key(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : String?
          return nil unless opts.oob
          gate(detail, opts) ? key_string(detail) : nil
        end

        def plan(detail : Store::FlowDetail, opts : Options = Options::DEFAULT) : Plan?
          minter = opts.oob || return nil
          body, prefix, root = gate(detail, opts) || return nil
          payload, token, session_id = minter.mint || return nil
          literal = system_literal(payload) || return nil
          dtd = "<!DOCTYPE #{root} [<!ENTITY % gori_xxe SYSTEM #{literal}>%gori_xxe;]>"
          injected = prefix + dtd + body.byte_slice(prefix.bytesize)
          request = rebuild(detail, injected)
          candidate = OutOfBand::Candidate.new(
            token: token, payload: payload, session_id: session_id,
            code: "xxe_oast", title: "XML external entity resolution (out-of-band)",
            severity: Store::Severity::High,
            evidence: "XML external parameter entity resolved an OAST payload")
          Plan.new(request, [Param.new("xml", root, token)], key_string(detail), oob: [candidate])
        end

        def detections(plan : Plan, result : Repeater::Result, detail : Store::FlowDetail) : Array(Detection)
          [] of Detection
        end

        # Explicit opt-in even for GET-with-XML: parsing the unchanged application document
        # may execute an operation. Never rewrite compressed/chunked, partial or large bodies,
        # existing DTDs, or encodings for which inserting ASCII could corrupt the document.
        private def gate(detail : Store::FlowDetail, opts : Options) : {String, String, String}?
          return nil unless opts.allow_unsafe
          bytes = detail.request_body || return nil
          return nil if bytes.empty? || bytes.size > BODY_CAP || detail.request_body_truncated?
          return nil unless xml_request?(detail.request_head)
          body = String.new(bytes)
          return nil unless supported_document?(body)
          match = ROOT.match(body) || return nil
          {body, match[1], match[2]}
        end

        private def xml_request?(head : Bytes) : Bool
          return false if Proxy::Codec::Http1.obfuscated_header?(head)
          req = Proxy::Codec::Http1.parse_request_head(head)
          return false if req.malformed? || req.method.upcase == "HEAD"
          return false if req.headers.has?("Transfer-Encoding")
          return false unless req.headers.get_all("Content-Encoding").all? { |v| v.strip.downcase == "identity" }
          types = req.headers.get_all("Content-Type")
          types.size == 1 && xml_type?(types.first)
        end

        private def supported_document?(body : String) : Bool
          return false unless body.valid_encoding?
          return false if body.includes?('\0') || body.includes?("<!DOCTYPE")
          if encoding = body.match(/\A\x{FEFF}?<\?xml\s[^?]*encoding\s*=\s*["']([^"']+)["']/)
            return false unless {"utf-8", "us-ascii"}.includes?(encoding[1].downcase)
          end
          true
        end

        private def xml_type?(value : String) : Bool
          parts = value.downcase.split(';').map(&.strip)
          media = parts.first
          return false unless media == "text/xml" || media == "application/xml" ||
                              (media.starts_with?("application/") && media.ends_with?("+xml"))
          parts.skip(1).all? do |part|
            name, _, encoding = part.partition('=')
            name.strip != "charset" || {"utf-8", "us-ascii"}.includes?(encoding.strip.strip('"'))
          end
        end

        # SystemLiteral is not an XML attribute: '&' in a provider URL must remain literal,
        # not '&amp;' (which would change the callback token). Choose an absent quote instead.
        private def system_literal(payload : String) : String?
          url = payload.includes?("://") ? payload : "http://#{payload}"
          uri = URI.parse(url)
          return nil unless {"http", "https"}.includes?(uri.scheme) && uri.host.presence
          return nil if uri.fragment || !url.valid_encoding? || url.each_byte.any? { |b| b <= 0x20 || b == 0x7f }
          return "\"#{url}\"" unless url.includes?('"')
          return "'#{url}'" unless url.includes?('\'')
          nil
        rescue URI::Error
          nil
        end

        private def key_string(detail : Store::FlowDetail) : String
          method, target, _ = Proxy::Codec::Http1.parse_request_line(detail.request_head)
          path = Active.origin_form(target).split('?', 2).first
          "xxe_oast|#{detail.row.scheme}://#{detail.row.host}:#{detail.row.port}|#{method.upcase}|#{path}"
        end

        private def rebuild(detail : Store::FlowDetail, body : String) : Bytes
          head, _, eol = Miner::Inject.split(detail.request_head)
          lines = String.new(head).split(eol)
          method, target, version = lines[0].split(' ')
          lines[0] = "#{method} #{Active.origin_form(target)} #{version}"
          Fuzz::ContentLength.sync((lines.join(eol) + eol + eol + body).to_slice, true)
        end
      end
    end
  end
end
