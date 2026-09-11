require "json"
require "openssl/hmac"
require "uri"
require "./media_type"
require "./redact/matcher"

module Gori
  # Safe evidence export: the sanitized DERIVATIVE of a captured message — the thing an
  # operator pastes into an issue, a report, a CI log or an agent transcript — with the values
  # that must not travel replaced by placeholders (#1035).
  #
  # ## The boundary
  #
  # gori stores the exact captured octets and keeps storing them: History, the Repeater and
  # the Comparer read the wire truth (P7), because replay and byte-level analysis are what
  # they are for. Redaction happens on the way OUT, in the surfaces that hand bytes to
  # somebody else, and it is the COPY that is sanitized. Nothing in this module writes to the
  # store, and no engine reads it: a redacted body has never been re-sent, and a replay after
  # an export is byte-identical to one before it.
  #
  # ## Why a placeholder is keyed, not blank
  #
  # `[REDACTED]` everywhere destroys the one property a report still needs: whether the token
  # in request A is the token in request B. So every placeholder carries a short tag derived
  # from the value (`[REDACTED:3f1c9ab4]`), and equal values get equal tags — correlation
  # survives, disclosure does not.
  #
  # The tag is an HMAC under a per-install secret (`Redact.salt`), NOT a plain digest, and
  # that is the whole security of it: a truncated SHA-256 of a 4-digit PIN, a 9-digit national
  # id, or a password out of any wordlist is recovered by a reader in milliseconds, which
  # would make the placeholder itself the disclosure. Under a secret salt the same tag is
  # stable across every export this install writes and means nothing to anyone else.
  module Redact
    # The tag length, in hex characters, on the end of a placeholder. 8 hex = 32 bits: two
    # DIFFERENT values colliding would read as "the same secret twice", which is a wrong
    # conclusion in a report, so this is a real trade against placeholder legibility. 32 bits
    # holds a collision under ~1-in-a-million for the ~90 distinct values a realistic evidence
    # bundle carries (birthday bound), and the correlation claim a reader draws from it is
    # always checkable against the profile that produced the export.
    TAG_HEX = 8

    # `Settings.redaction_salt` assigns this at first use (see settings/redaction.cr): the
    # secret behind every placeholder tag, minted once per install and persisted, so an
    # export written today correlates with one written next month.
    #
    # Deliberately NOT defaulted to a constant. An empty salt means nothing has minted one,
    # and `tag` refuses rather than quietly handing back plain-digest tags an operator would
    # reasonably read as protected — see `Redact::SaltMissing`.
    class_property salt : String = ""

    # No salt has been minted, so no placeholder can be. Raised rather than degraded because
    # the degraded answer (a plain truncated digest) LOOKS identical in the output and is
    # brute-forceable, and the only surface that could tell the operator so is this one.
    class SaltMissing < Gori::Error
      def initialize(message = "redaction: no placeholder salt has been minted for this install")
        super(message)
      end
    end

    # One named set of redaction rules. Four kinds, because that is what bodies actually look
    # like and each answers a question the others cannot:
    #
    #   * `json_fields`   — an object member NAME, matched case-insensitively at ANY depth.
    #                       The workhorse: "whatever it is nested in, a member called
    #                       `password` does not leave this machine".
    #   * `json_pointers` — an RFC 6901 pointer, matched at exactly one location
    #                       (`/data/user/ssn`). For the field name too generic to blanket —
    #                       `id` under one parent and nowhere else. The array token `-`, which
    #                       RFC 6901 reserves for "past the last element" and which can never
    #                       name an element that exists, is read here as "any index":
    #                       `/users/-/token` covers the whole array.
    #   * `form_keys`     — an `application/x-www-form-urlencoded` key, case-insensitive.
    #   * `patterns`      — a regex over the body text, and over each JSON string leaf and each
    #                       decoded form value. With a capture group, group 1 is what gets
    #                       replaced and the rest is context you matched on (`account=(\d+)`
    #                       keeps `account=` and takes the digits); with no group, the whole
    #                       match goes. Compiled case-INSENSITIVELY, like the three name lists
    #                       above: over-matching is the safe direction here, and an operator
    #                       should not have to guess which case the target chose.
    #
    # `description` exists for the preview, which has to say WHY a value is going.
    record Profile,
      name : String,
      description : String = "",
      json_fields : Array(String) = [] of String,
      json_pointers : Array(String) = [] of String,
      form_keys : Array(String) = [] of String,
      patterns : Array(String) = [] of String do
      # Nothing to match — a profile that would sanitize nothing. Surfaces refuse to label an
      # export "sanitized" on one of these, because the label would be a lie.
      def empty? : Bool
        json_fields.empty? && json_pointers.empty? && form_keys.empty? && patterns.empty?
      end

      # --- the one JSON codec ------------------------------------------------
      #
      # A profile is persisted in TWO places (settings.json and a project's settings row —
      # `Settings.parse_redaction` and `Redact::Policy`), and a second hand-written reader or
      # writer is a second answer to "what is a profile" that has to agree with the first
      # forever. It would not: adding a fifth rule kind means editing every copy, and a profile
      # `redact set --global` wrote would then round-trip differently from one `redact set`
      # wrote. Both scopes call these.

      # nil when the object carries no usable `name` — the tolerant-parse contract every list
      # section in settings.json has: a junk entry is dropped, never raised over.
      def self.from_json_object(node : JSON::Any?) : Profile?
        o = node.try(&.as_h?) || return nil
        name = o["name"]?.try(&.as_s?).try(&.strip)
        return nil if name.nil? || name.empty?
        Profile.new(
          name: name,
          description: o["description"]?.try(&.as_s?) || "",
          json_fields: string_list(o["json_fields"]?),
          json_pointers: string_list(o["json_pointers"]?),
          form_keys: string_list(o["form_keys"]?),
          patterns: string_list(o["patterns"]?))
      end

      # Every profile of a JSON array, junk entries dropped.
      def self.list_from_json(node : JSON::Any?) : Array(Profile)
        arr = node.try(&.as_a?) || return [] of Profile
        arr.compact_map { |e| from_json_object(e) }
      end

      # A JSON array of strings, with anything that is not a non-empty string dropped.
      def self.string_list(node : JSON::Any?) : Array(String)
        arr = node.try(&.as_a?) || return [] of String
        arr.compact_map(&.as_s?.try(&.strip).presence)
      end

      # The inverse. Empty lists are omitted, so a round trip through either scope is a fixed
      # point and an untouched rule kind leaves nothing behind in the file.
      def build_json(j : JSON::Builder) : Nil
        j.object do
          j.field "name", name
          j.field "description", description unless description.empty?
          {"json_fields" => json_fields, "json_pointers" => json_pointers,
           "form_keys" => form_keys, "patterns" => patterns}.each do |key, values|
            next if values.empty?
            j.field key do
              j.array { values.each { |v| j.string v } }
            end
          end
        end
      end
    end

    # One replacement that happened. `path` locates it the way the shape does — a JSON
    # Pointer, a form key, or `body` for a text-pattern hit — and `rule` says which entry of
    # the profile fired, which is what makes a preview auditable rather than a number.
    record Hit, path : String, rule : String, placeholder : String

    # What the body turned out to be, and therefore which pass ran over it.
    enum Shape
      Empty     # no body at all
      Json      # parsed as JSON, walked structurally
      Form      # application/x-www-form-urlencoded, walked key by key
      Text      # valid UTF-8 that is neither, so the pattern pass ran
      Multipart # a multipart form: withheld whole, see `withhold_reason`
      Binary    # not valid UTF-8: withheld whole
    end

    # A sanitized body plus everything a surface has to SAY about it.
    #
    # `text` is always present and always emittable — a withheld body carries the sentence
    # that says so, not nil — so no caller has a "body vanished" branch to get wrong.
    # `withheld?` is how a caller tells a sanitized body from a suppressed one.
    record Result,
      text : String,
      hits : Array(Hit),
      shape : Shape,
      fell_back : Bool = false do
      def count : Int32
        hits.size
      end

      def redacted? : Bool
        !hits.empty?
      end

      # Derived from `shape` rather than carried beside it. A flag AND a shape is two fields
      # that have to be kept in sync by hand on the record every surface reads to decide
      # whether a body was suppressed — and a suppressed body reporting `withheld? == false`
      # is the export claiming it sanitized bytes it never looked at. There is one shape test,
      # so a new withheld shape cannot be added with the wrong flag.
      def withheld? : Bool
        shape.multipart? || shape.binary?
      end

      # The sanitized body as bytes, which is what every caller that rebuilds a message wants.
      def bytes : Bytes
        text.to_slice
      end
    end

    # The built-in profile, used when nothing else is configured. Names only — no patterns —
    # because a shipped regex that fires on the wrong thing costs an operator a mangled report
    # and no warning, while a shipped NAME that fires on the wrong thing costs one value that
    # was probably worth losing anyway.
    #
    # The list is deliberately broad on credentials and identifiers and silent on everything
    # else: a default profile that redacted, say, every `email` would quietly wreck the
    # evidence for the class of finding where the email IS the finding. Operators who want
    # that add it to a profile of their own, where they can see it.
    DEFAULT_PROFILE = Profile.new(
      name: "default",
      description: "credentials, tokens and common government/financial identifiers, by field name",
      json_fields: %w[
        password passwd pwd old_password new_password current_password password_confirmation
        secret client_secret api_secret private_key privatekey secret_key secretkey
        token access_token refresh_token id_token auth_token authtoken session_token
        api_key apikey x_api_key authorization auth credentials credential
        session sessionid session_id sid jsessionid phpsessid csrf_token xsrf_token
        otp otp_code one_time_password pin passcode mfa_code totp
        ssn social_security_number national_id tax_id
        card_number cardnumber pan credit_card creditcard cvv cvc cvv2 security_code
        account_number accountnumber iban bic routing_number sort_code
      ],
      form_keys: %w[
        password passwd pwd old_password new_password current_password password_confirmation
        secret client_secret api_secret private_key secret_key
        token access_token refresh_token id_token auth_token session_token
        api_key apikey authorization auth
        session sessionid session_id sid csrf_token xsrf_token
        otp pin passcode mfa_code totp
        ssn national_id card_number cvv cvc account_number iban
      ],
    )

    # Every profile gori ships. A list, not a lone constant, because `Settings` searches it by
    # name and prints it as the set an operator can pick from or override.
    BUILTIN_PROFILES = [DEFAULT_PROFILE]

    # Credential SHAPES that are unambiguous enough to redact wherever they appear — inside a
    # JSON string leaf under a member name nobody listed, inside a form value, and inside a
    # body that could not be parsed at all. These are the only rules gori applies without
    # being asked, and the bar for adding one is that a false positive is close to impossible:
    #
    #   * a JWS/JWE compact serialization always opens `eyJ` (base64url of `{"`), so a run of
    #     base64url-with-dots that starts that way is a token and nothing else;
    #   * a PEM PRIVATE KEY block says what it is on its first line.
    #
    # Everything softer — "a long hex run", "a high-entropy word" — is deliberately absent: a
    # response hash, a request id and a git SHA all look like that, and silently replacing them
    # would corrupt exactly the identifiers a report correlates on. Those belong in a profile
    # the operator can see.
    BUILTIN_PATTERNS = [
      {/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*/, "builtin jwt"},
      {/-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----[\s\S]*?-----END (?:[A-Z0-9 ]+ )?PRIVATE KEY-----/,
       "builtin pem-private-key"},
    ]

    # A placeholder for `value`: the same value always yields the same one, and no value is
    # recoverable from it. See the module header for why the tag is an HMAC.
    def self.placeholder(value : String) : String
      "[REDACTED:#{tag(value)}]"
    end

    # The correlation tag itself. Raises `SaltMissing` rather than falling back to an
    # unsalted digest — see `Redact.salt`.
    def self.tag(value : String) : String
      key = salt
      raise SaltMissing.new if key.empty?
      OpenSSL::HMAC.hexdigest(:sha256, key, value)[0, TAG_HEX]
    end
  end
end
