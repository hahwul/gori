require "../store/models"

module Gori
  # A static catalog of response-modification presets for the Rewriter (#821). Each preset is
  # the Burp-style one-click option every tester writes by hand every engagement — unhide
  # hidden fields, enable disabled controls, strip length limits and validation, drop CSP and
  # security headers, disable SRI — expressed as ordinary `Store::MatchRule` shapes.
  #
  # A preset is a STARTING POINT, not a capability: gori's Match&Replace already expresses all
  # of these. Installing a preset writes plain, visible, editable, disable-able rules through
  # the same rule-write path as manual authoring (P1) — nothing hidden, nothing magic (P4).
  # Once installed they are indistinguishable from a rule the operator typed, and can be
  # edited, toggled, moved or deleted like any other.
  #
  # This is a static catalog, not a templating engine (P0): the specs are literal below, and
  # the only work at install time is looping `RuleSpec` rows into `insert_rule` /
  # `Settings.add_rewriter_rule`. Every surface (TUI picker, `gori run rewriter preset`, the
  # MCP `create_rule_from_preset`) reads THIS list, so a preset means the identical rule set
  # everywhere.
  #
  # The catalog holds ONLY `Replace` (literal/regex) and `RemoveHeader` rules. It never emits a
  # `Pipe` op: a `Pipe` runs an external command (`Gori::ProcessHook`), so a preset that
  # installed one would be gori running a command the operator never wrote (#818). The
  # regex-over-markup rules accept the known limits of that approach — a `disabled` inside a
  # quoted attribute value is stripped too — and stay conservative rather than reaching for a
  # DOM parser (out of scope). All patterns compile through the proxy's `Store::SafeRegexp`
  # like every other rule.
  module RulePresets
    # One rule a preset installs. The fields line up with `insert_rule` / `Rules#add` exactly,
    # so a surface can splat a spec straight into either. `name` is the RULE's label (not the
    # preset's) — carried so an installed rule says which preset it came from and is findable
    # in the list, which is what makes "added twice" visible and deletable rather than silent.
    #
    # A `Replace` body rule's `replacement` uses Crystal's native `\1`/`\2` backreferences, not
    # the Caido-style `$1`: the `$`→`\` translation only runs when the operator's configured
    # env prefix appears in the string, so a literal `\1` is the spelling that holds whatever
    # the prefix is set to.
    struct RuleSpec
      getter target : Store::RuleTarget
      getter part : Store::RulePart
      getter op : Store::RuleOp
      getter match_kind : Store::MatchKind
      getter pattern : String
      getter replacement : String
      getter name : String

      def initialize(@target, @part, @op, @match_kind, @pattern, @replacement, @name)
      end
    end

    # A named preset: a stable `key` (what the CLI and MCP address it by), a human `name` and
    # `description` for the picker, and the rules it installs.
    struct Preset
      getter key : String
      getter name : String
      getter description : String
      getter rules : Array(RuleSpec)

      def initialize(@key, @name, @description, @rules)
      end

      # Rows this preset would install, joined for a one-line CLI/MCP summary.
      def summary : String
        "#{rules.size} rule#{rules.size == 1 ? "" : "s"}"
      end
    end

    private RESPONSE = Store::RuleTarget::Response
    private HEAD     = Store::RulePart::Head
    private BODY     = Store::RulePart::Body
    private REPLACE  = Store::RuleOp::Replace
    private DROP     = Store::RuleOp::RemoveHeader
    private REGEX    = Store::MatchKind::Regex
    private LITERAL  = Store::MatchKind::Literal

    # A body Replace rule over the response entity, matched by regex.
    private def self.body_rx(pattern : String, replacement : String, name : String) : RuleSpec
      RuleSpec.new(RESPONSE, BODY, REPLACE, REGEX, pattern, replacement, name)
    end

    # A RemoveHeader rule dropping a response header by exact (case-insensitive) name.
    private def self.drop_header(header : String, name : String) : RuleSpec
      RuleSpec.new(RESPONSE, HEAD, DROP, LITERAL, header, "", name)
    end

    # `<input type="hidden">` → `type="text"`, so the field renders and can be edited. Anchored
    # to an `<input` tag (`[^>]*?` stays inside the tag) and to a real `type` attribute (the
    # `(?<![\w-])` guard keeps it off `data-type`), with the value matched quoted, single-quoted
    # or bare and the closing delimiter checked by lookahead so `type="hiddenx"` is not touched.
    UNHIDE = Preset.new(
      "unhide-hidden-fields", "Unhide hidden form fields",
      %(Rewrite <input type="hidden"> to type="text" so the field is visible and editable.),
      [body_rx(
        %q((?i)(<input\b[^>]*?(?<![\w-])type\s*=\s*)(["']?)hidden\2(?=[\s/>])),
        "\\1\\2text\\2", "Unhide hidden form fields")])

    # Strip `disabled` / `readonly` from a control so it submits and can be edited. Matches the
    # bare attribute and the `=…` form (quoted, single-quoted or bare); `\b` keeps it off
    # `data-disabled` / `aria-disabled`. Removes the one leading space with it so the tag stays
    # well-formed.
    ENABLE = Preset.new(
      "enable-disabled-fields", "Enable disabled fields",
      "Strip disabled and readonly attributes so form controls submit and accept input.",
      [body_rx(
        %q((?i)\s(?:disabled|readonly)\b(\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'>]+))?),
        "", "Enable disabled/readonly fields")])

    # Drop `maxlength=…` so an input accepts arbitrary length.
    MAXLENGTH = Preset.new(
      "remove-length-limits", "Remove input length limits",
      "Strip maxlength attributes so inputs accept values of any length.",
      [body_rx(
        %q((?i)\smaxlength\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'>]+)),
        "", "Remove maxlength")])

    # Strip HTML5 client-side validation: the `required` and `pattern=` input attributes and
    # the `onsubmit`/`onchange`/`oninput` inline handlers. Three rules so each can be toggled
    # off on its own — one may be doing useful work while the others are in the way.
    VALIDATION = Preset.new(
      "strip-validation", "Strip client-side validation",
      "Remove required, pattern= and on{submit,change,input}= handlers that block form submission.",
      [
        body_rx(%q((?i)\srequired\b(\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'>]+))?),
          "", "Strip required attribute"),
        body_rx(%q((?i)\spattern\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'>]+)),
          "", "Strip pattern= attribute"),
        body_rx(%q((?i)\son(?:submit|change|input)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'>]+)),
          "", "Strip on{submit,change,input}= handlers"),
      ])

    # Drop the Content-Security-Policy response header AND its `-Report-Only` variant. Two
    # rules, because a header op matches by EXACT name (`head_remove_header`) — one name per
    # rule — and because dropping one but not the other is a legitimate thing to want.
    CSP = Preset.new(
      "remove-csp", "Remove CSP",
      "Drop Content-Security-Policy and Content-Security-Policy-Report-Only response headers.",
      [
        drop_header("Content-Security-Policy", "Remove Content-Security-Policy"),
        drop_header("Content-Security-Policy-Report-Only", "Remove Content-Security-Policy-Report-Only"),
      ])

    # Drop the common hardening headers, each as its own rule so the operator can keep one and
    # drop the others (the issue calls this out explicitly — "each individually toggleable").
    SECURITY_HEADERS = Preset.new(
      "remove-security-headers", "Remove security headers",
      "Drop X-Frame-Options, X-Content-Type-Options and Strict-Transport-Security (each a separate rule).",
      [
        drop_header("X-Frame-Options", "Remove X-Frame-Options"),
        drop_header("X-Content-Type-Options", "Remove X-Content-Type-Options"),
        drop_header("Strict-Transport-Security", "Remove Strict-Transport-Security"),
      ])

    # Strip Subresource Integrity from `<script>` / `<link>` so a swapped-out resource is not
    # rejected by the browser. Byte-level like the rest: `integrity=` is only ever an SRI
    # attribute, so no tag anchor is needed.
    SRI = Preset.new(
      "disable-sri", "Disable SRI",
      "Strip integrity= attributes so subresource-integrity checks no longer block modified assets.",
      [body_rx(
        %q((?i)\sintegrity\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'>]+)),
        "", "Disable Subresource Integrity")])

    # The catalog, in the order the picker and `preset list` show it.
    CATALOG = [UNHIDE, ENABLE, MAXLENGTH, VALIDATION, CSP, SECURITY_HEADERS, SRI]

    def self.all : Array(Preset)
      CATALOG
    end

    # The preset with this key, or nil. Case-insensitive so `gori run rewriter preset add
    # Remove-CSP` finds `remove-csp`.
    def self.find(key : String) : Preset?
      k = key.downcase
      CATALOG.find { |p| p.key == k }
    end

    # The keys, for an error message / usage line that has to list what is available.
    def self.keys : Array(String)
      CATALOG.map(&.key)
    end
  end
end
