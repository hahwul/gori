require "json"
require "mime/multipart"
require "./types"
require "./inject"

module Gori::Miner
  # Decides which locations are APPLICABLE to a request (and which to default-check),
  # so the config overlay shows only relevant checkboxes. Query/Cookies/Headers always
  # apply; Form/Json apply only when the body's content-type + shape support them.
  module Detect
    record Applicability, applicable : Array(Location), default : Array(Location)

    def self.detect(request : Bytes) : Applicability
      _, body, _ = Inject.split(request)
      ct = (Inject.header_value(request, "content-type") || "").downcase
      has_body = !body.empty?

      applicable = [Location::Query]
      default = [Location::Query]

      if has_body && ct.includes?("x-www-form-urlencoded")
        applicable << Location::Form
        default << Location::Form
      end
      # Multipart is applicable but default OFF: a captured file-upload re-sends its (possibly
      # multi-MB) file part on every bucket/bisect/confirm request. Opt in — as with Headers/Cookies.
      if has_body && multipart_form?(request, ct)
        applicable << Location::Multipart
      end
      if has_body && json_injectable?(ct, body)
        applicable << Location::Json
        default << Location::Json
      end

      # Cookies/headers always apply; both default OFF (noisy, multiplies the
      # request budget, and infra often strips/echoes them).
      applicable << Location::Headers
      applicable << Location::Cookies

      Applicability.new(applicable, default)
    end

    # JSON location when the body carries at least one injectable object node — a root object,
    # an object inside a root array, or a nested object. Shares Inject's node counter so Detect
    # and the injector never disagree about whether Json is applicable.
    private def self.json_injectable?(ct : String, body : Bytes) : Bool
      return false unless ct.includes?("json") || body_looks_json?(body)
      Inject.json_object_node_count(body, Inject::MAX_JSON_NODES) > 0
    end

    private def self.body_looks_json?(body : Bytes) : Bool
      head = String.new(body[0, {body.size, 64}.min]).scrub.lstrip
      head.starts_with?('{') || head.starts_with?('[')
    end

    # Multipart location when the body is multipart/form-data AND a boundary is extractable.
    # `ct_lower` is already down-cased; the boundary is re-read from the ORIGINAL-case header.
    private def self.multipart_form?(request : Bytes, ct_lower : String) : Bool
      return false unless ct_lower.lstrip.starts_with?("multipart/form-data")
      raw = Inject.header_value(request, "content-type")
      return false unless raw
      b = MIME::Multipart.parse_boundary(raw)
      !b.nil? && !b.empty?
    end
  end
end
