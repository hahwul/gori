require "json"
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
      if has_body && json_object?(ct, body)
        applicable << Location::Json
        default << Location::Json
      end

      # Cookies/headers always apply; both default OFF (noisy, multiplies the
      # request budget, and infra often strips/echoes them).
      applicable << Location::Headers
      applicable << Location::Cookies

      Applicability.new(applicable, default)
    end

    # JSON location only when the ROOT is an object (named keys are injectable).
    private def self.json_object?(ct : String, body : Bytes) : Bool
      looks = ct.includes?("json") || body_looks_object?(body)
      return false unless looks
      !JSON.parse(String.new(body).scrub).as_h?.nil?
    rescue JSON::ParseException
      false
    end

    private def self.body_looks_object?(body : Bytes) : Bool
      String.new(body[0, {body.size, 64}.min]).scrub.lstrip.starts_with?('{')
    end
  end
end
