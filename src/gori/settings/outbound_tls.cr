require "json"
require "../host_pattern"
require "./tls_presets"
# The validator for `groups` / `sigalgs` / `ciphersuites` / `alpn` asks the OpenSSL that will
# consume them, rather than re-implementing four grammars here — see ClientShape.
require "../proxy/tls/client_shape"

# OUTBOUND TLS section (settings.json "outbound_tls"): per-destination TLS policy for the
# connections gori MAKES — a client certificate to present, and the protocol/cipher floor to
# negotiate with. See settings.cr for the load/save/serialize orchestration.
#
# Deliberately a SEPARATE table from `upstream_rules` rather than more columns on it. Both are
# keyed by destination host pattern, but they answer different questions ("how do I reach this
# host" vs "how do I speak TLS to it") and both are FIRST-MATCH ordered lists. Folding them
# together makes the common shape inexpressible: "everything through the corporate proxy, plus
# a client certificate for one host" would need the proxy address duplicated onto that host's
# row, because a single first-match table can only apply one row per host.
module Gori::Settings
  # Protocol bounds, lowest first. "" = leave OpenSSL/Crystal's default alone. Used for
  # BOTH `min_version` (the floor) and `max_version` (the ceiling).
  #
  # This matters more than it looks: Crystal's OpenSSL::SSL::Context::Client.new adds
  # NO_TLS_V1 | NO_TLS_V1_1 in its constructor, so gori CANNOT reach a TLS 1.0/1.1-only
  # appliance out of the box, and `verify_upstream: false` does not help — that turns off
  # certificate VERIFICATION, not protocol negotiation. Lowering the floor is the only way,
  # which is why this exists.
  TLS_VERSIONS = ["tls1.0", "tls1.1", "tls1.2", "tls1.3"]

  # One outbound-TLS rule. `host` is a HostPattern (the dialect shared with scope host rules
  # and upstream_rules); "*" is the catch-all. First match wins.
  #
  # Certificates are FILE PATHS, in PEM, not inline material: a private key does not belong in
  # settings.json (which is shareable/exportable — #439), and gori already speaks PEM for its
  # own CA. A PASSPHRASE-PROTECTED key is not supported: OpenSSL would prompt on a terminal
  # gori has taken over, so outbound_tls_error rejects one at save time instead.
  # `min_version` is a FLOOR and `max_version` a CEILING; either alone is legal. The ceiling
  # is not symmetry for its own sake — without it `min_version` could not express a
  # negotiation at all, only a lower bound that every modern origin answers with TLS 1.3,
  # and `ciphers` (which OpenSSL's SSL_CTX_set_cipher_list applies to TLS 1.2 AND BELOW
  # ONLY) was therefore unreachable: the two knobs together could not say "negotiate TLS 1.2
  # with AES128-SHA", which is the test they exist for. Nor could an operator ask "does this
  # target still accept TLS 1.0?", because gori could not be made to OFFER only that.
  # The FINGERPRINT half of the record, added for #822. `ciphers` above governs TLS 1.2 and
  # below; everything here is what an anti-bot stack actually reads off the ClientHello:
  #
  #   `preset`          — a named browser approximation (see tls_presets.cr). Fields set on the
  #                       rule itself WIN over it, so a preset is a starting point.
  #   `groups`          — supported_groups / key_share order, e.g. "X25519:P-256:P-384".
  #   `sigalgs`         — signature_algorithms order.
  #   `ciphersuites`    — the TLS 1.3 suites, which `ciphers` CANNOT reach.
  #   `alpn`            — the ordered ALPN list. Today's single-protocol offer is already a tell:
  #                       a browser offers `h2` AND `http/1.1`.
  #   `session_tickets` — nil = OpenSSL's default (on). false adds SSL_OP_NO_TICKET, dropping
  #                       the `session_ticket` extension from the hello.
  #   `ocsp_stapling`   — nil = OpenSSL's default (off). true adds `status_request`, which every
  #                       browser sends and stock OpenSSL does not.
  #
  # The two booleans are NILABLE and that is not decoration: with a preset in play, "the
  # operator did not say" and "the operator said false" have to be different answers, or a
  # preset would override an explicit `false` (or an explicit `false` could never be
  # distinguished from the field's default and so could never override a preset's `true`).
  record OutboundTlsRule,
    host : String,
    client_cert : String = "",
    client_key : String = "",
    min_version : String = "",
    max_version : String = "",
    ciphers : String = "",
    permissive : Bool = false,
    preset : String = "",
    groups : String = "",
    sigalgs : String = "",
    ciphersuites : String = "",
    alpn : Array(String) = [] of String,
    session_tickets : Bool? = nil,
    ocsp_stapling : Bool? = nil do
    # Whether this rule asks for mutual TLS. Both halves are required — OpenSSL needs the
    # chain and the key, and a half-configured pair would fail the handshake with a message
    # that points at the origin rather than at the settings file.
    def client_auth? : Bool
      !client_cert.empty? && !client_key.empty?
    end

    # The named preset this rule builds on, or nil. An unknown name resolves to nil rather
    # than raising: `parse_outbound_tls` already drops one, and the save-time validator is
    # where a typo is reported.
    def preset_profile : TlsPreset?
      TLS_PRESETS[preset]?
    end

    # ── effective values ───────────────────────────────────────────────────────────────────
    #
    # What actually reaches the SSL context: the rule's own value when it set one, else the
    # named preset's, else OpenSSL's default. Read these, never the raw fields, anywhere the
    # handshake or a report is built — the raw fields are what the operator TYPED, and the
    # difference between the two is exactly what a preset is for.

    def effective_ciphers : String
      ciphers.presence || preset_profile.try(&.ciphers) || ""
    end

    def effective_groups : String
      groups.presence || preset_profile.try(&.groups) || ""
    end

    def effective_sigalgs : String
      sigalgs.presence || preset_profile.try(&.sigalgs) || ""
    end

    def effective_ciphersuites : String
      ciphersuites.presence || preset_profile.try(&.ciphersuites) || ""
    end

    # `dup` on the preset branch: a `TlsPreset`'s `alpn` is one array shared by every preset
    # that names it, and this value travels out through `ClientShape.alpn_offer` (which returns
    # it verbatim on the h2 leg) into the CLI report. One `sort!`/`uniq!`/`<<` added downstream
    # would rewrite every preset's ALPN for the whole process, and contexts already cached
    # under the old `cache_key` would keep serving the old offer.
    def effective_alpn : Array(String)
      return alpn unless alpn.empty?
      preset_profile.try(&.alpn.dup) || [] of String
    end

    # `stated` first, and only then the preset — see the record's note on why these two are
    # nilable. `|| default` would be wrong here: it cannot tell a preset's explicit `false`
    # from "the preset said nothing".
    def effective_session_tickets? : Bool
      stated = session_tickets
      return stated unless stated.nil?
      profile = preset_profile
      profile ? profile.session_tickets : true # OpenSSL offers session tickets by default
    end

    def effective_ocsp_stapling? : Bool
      stated = ocsp_stapling
      return stated unless stated.nil?
      profile = preset_profile
      profile ? profile.ocsp_stapling : false # OpenSSL does not request stapling by default
    end

    # ── per-send fingerprint override (#844) ───────────────────────────────────────────────
    #
    # This same rule, with its ClientHello SHAPE replaced by `name`'s preset — what a Repeater
    # tab or a fuzz run asks for when the operator picks a fingerprint for THAT send. The
    # destination table is not touched, and neither is any other tab dialing the same host.
    #
    # It NARROWS rather than replaces, and the split is field by field:
    #
    #   kept   `client_cert` / `client_key` — the destination's mutual-TLS IDENTITY. An
    #          override says what the hello should look like, not who gori is; dropping the
    #          certificate would turn "chrome vs curl" into "authenticated vs anonymous" and
    #          answer a different question than the one asked.
    #   kept   `min_version` / `max_version` — the version range is a reachability fact about
    #          that destination (a TLS 1.0-only appliance stays reachable under any preset).
    #   kept   `permissive` — a security-level-0 / renegotiation decision about that
    #          destination, and the one knob that WIDENS what gori will accept. An override
    #          must not be able to grant it, and must not be able to take it away either:
    #          without it a legacy destination's own preset would stop applying mid-A/B.
    #   kept   `host` — identity of the row; never reaches a context.
    #
    #   taken  `preset`, `groups`, `sigalgs`, `ciphersuites`, `ciphers`, `alpn`,
    #          `session_tickets`, `ocsp_stapling` — the whole ClientHello shape, REPLACED and
    #          not merged. Merging would leave the destination's own `groups` winning (rule
    #          fields beat a preset — see `effective_groups`), so the override could not change
    #          the one thing it exists to change. `ciphers` goes with them: it is the TLS 1.2
    #          cipher list and its ORDER, which is a primary JA3 input.
    #
    # `name` is kept VERBATIM even when unknown, for the reason `parse_tls_preset` gives —
    # nothing here folds a typo to "no override". Surfaces refuse an unknown name before the
    # send (`Settings.tls_preset_error`); if one ever reaches here, `preset_profile` resolves
    # to nil, nothing is applied, and `cache_key` still separates it from every other value.
    def with_fingerprint(name : String) : OutboundTlsRule
      OutboundTlsRule.new(
        host: host,
        client_cert: client_cert,
        client_key: client_key,
        min_version: min_version,
        max_version: max_version,
        ciphers: "",
        permissive: permissive,
        preset: name,
        groups: "",
        sigalgs: "",
        ciphersuites: "",
        alpn: [] of String,
        session_tickets: nil,
        ocsp_stapling: nil,
      )
    end

    # True when the rule changes nothing, so the shared default context can be reused.
    def default? : Bool
      !client_auth? && min_version.empty? && max_version.empty? && ciphers.empty? &&
        !permissive && preset.empty? && groups.empty? && sigalgs.empty? &&
        ciphersuites.empty? && alpn.empty? && session_tickets.nil? && ocsp_stapling.nil?
    end

    # A stable identity for this policy, used as part of the TLS context cache key. Contexts
    # are shared per distinct policy, so this MUST cover every field that mutates the context —
    # a field left out here means an edit silently reuses the first context built, and (since
    # #822) that two destinations configured with DIFFERENT FINGERPRINTS would quietly share
    # one SSL_CTX and send the same ClientHello to both.
    #
    # Joined on a NUL escape, which no path or cipher string can contain, so two distinct
    # policies can never collide into one key. The booleans are three-valued because they are
    # three-valued on the record. Built with join, not string interpolation: inside a `record`
    # block body the interpolation form does not compile here.
    def cache_key : String
      return "" if default?
      [client_cert, client_key, min_version, max_version, ciphers, permissive.to_s,
       preset, groups, sigalgs, ciphersuites, alpn_key,
       tristate(session_tickets), tristate(ocsp_stapling)].join('\0')
    end

    # `alpn` flattened LENGTH-PREFIXED rather than joined on a delimiter. An ALPN identifier is
    # an arbitrary byte string and a hand-edited file is not required to hold to
    # `ClientShape::ALPN_SUPPORTED` — so `["h2,http/1.1"]` (one bogus protocol) and
    # `["h2", "http/1.1"]` (two real ones) would flatten to the same comma-joined text, share
    # one SSL context, and send one of them the other's ClientHello. That is precisely the
    # collision this whole method exists to make impossible, so no delimiter is chosen at all.
    private def alpn_key : String
      String.build { |io| alpn.each { |p| io << p.bytesize << ':' << p } }
    end

    private def tristate(value : Bool?) : String
      value.nil? ? "" : value.to_s
    end
  end

  @@outbound_tls : Array(OutboundTlsRule) = [] of OutboundTlsRule
  @@outbound_tls_compiled : Array({HostPattern::Compiled, OutboundTlsRule}) = [] of {HostPattern::Compiled, OutboundTlsRule}
  # The policy used when no rule matches: OpenSSL's defaults, nothing applied.
  DEFAULT_OUTBOUND_TLS = OutboundTlsRule.new("*")

  def self.outbound_tls : Array(OutboundTlsRule)
    @@outbound_tls
  end

  def self.outbound_tls=(rules : Array(OutboundTlsRule)) : Array(OutboundTlsRule)
    @@outbound_tls = rules
    @@outbound_tls_compiled = rules.map { |r| {HostPattern::Compiled.new(r.host), r} }
    rules
  end

  # The TLS policy for `dest_host` — the first matching rule, else the all-defaults policy,
  # narrowed by a per-send fingerprint `override` when the operator set one on this tab or
  # this run (#844). Called once per TLS dial, so the patterns are precompiled (see the
  # setter above).
  #
  # ONE resolution path, and that is the point (P1): the override is not a second TLS policy
  # source that a dial has to consult beside this one — it is this same `OutboundTlsRule`,
  # narrowed. Everything downstream (`apply_outbound_tls`, `cache_key`, the fingerprint
  # report) keeps reading exactly one record and cannot tell where its shape came from.
  #
  # A nil/blank `override` returns the matched rule UNCHANGED — byte-identical to the
  # pre-#844 behaviour, including the same `cache_key` and therefore the same cached context.
  def self.outbound_tls_for(dest_host : String, override : String? = nil) : OutboundTlsRule
    rule =
      if @@outbound_tls_compiled.empty?
        DEFAULT_OUTBOUND_TLS
      else
        bare = HostPattern.bare(dest_host.downcase)
        match = @@outbound_tls_compiled.find { |(pattern, _)| pattern.matches_bare?(bare) }
        match ? match[1] : DEFAULT_OUTBOUND_TLS
      end
    # Through `tls_preset_normalize`, not a second `strip.downcase` here: this is the
    # function that decides which spellings are ONE policy, and a copy of that decision is a
    # copy that drifts — the two would then disagree about whether `"Chrome "` shares a cache
    # key with `"chrome"`, which is exactly the collision the key exists to prevent.
    name = tls_preset_normalize(override)
    name ? rule.with_fingerprint(name) : rule
  end

  # nil if `name` can be used as a per-send fingerprint override; the operator-facing refusal
  # otherwise. Every surface that accepts one (`gori run repeater/fuzz --tls-preset`, MCP
  # `send_request`/`fuzz_start`, the Repeater tab's persisted value on restore) calls this
  # BEFORE the send, for the reason `parse_tls_preset` spells out at length: an unknown name
  # applies nothing, so gori would dial with its bare OpenSSL hello while the operator
  # believed Chrome's was going out — and unlike the destination table, a per-send override
  # has no startup warning to catch it. A blank/absent name is "no override" and passes.
  def self.tls_preset_error(name : String?) : String?
    n = name.try(&.strip.downcase)
    return nil if n.nil? || n.empty?
    return nil if TLS_PRESETS.has_key?(n)
    "unknown TLS fingerprint preset #{name.inspect} — expected one of #{TLS_PRESET_NAMES.join(", ")}"
  end

  # `name` normalised to the form the dial and the cache key see, or nil for "no override".
  # Surfaces store and report THIS, so a tab persisted as `"Chrome "` and one persisted as
  # `"chrome"` are one policy rather than two contexts.
  def self.tls_preset_normalize(name : String?) : String?
    n = name.try(&.strip.downcase)
    n && !n.empty? ? n : nil
  end

  # Tolerant parse, like every other section: an entry with no host is dropped, an
  # out-of-range min_version falls back to "" (OpenSSL's default) rather than failing the
  # load, and a non-array node keeps the current value.
  private def self.parse_outbound_tls(node : JSON::Any?) : Array(OutboundTlsRule)
    arr = node.try(&.as_a?)
    return outbound_tls unless arr
    out = [] of OutboundTlsRule
    arr.each do |e|
      next unless o = e.as_h?
      host = o["host"]?.try(&.as_s?).try(&.strip)
      next if host.nil? || host.empty?
      out << OutboundTlsRule.new(
        host,
        o["client_cert"]?.try(&.as_s?).try(&.strip) || "",
        o["client_key"]?.try(&.as_s?).try(&.strip) || "",
        parse_version(o["min_version"]?),
        parse_version(o["max_version"]?),
        o["ciphers"]?.try(&.as_s?).try(&.strip) || "",
        o["permissive"]?.try(&.as_bool?) || false,
        parse_tls_preset(o["preset"]?),
        o["groups"]?.try(&.as_s?).try(&.strip) || "",
        o["sigalgs"]?.try(&.as_s?).try(&.strip) || "",
        o["ciphersuites"]?.try(&.as_s?).try(&.strip) || "",
        parse_alpn_list(o["alpn"]?),
        o["session_tickets"]?.try(&.as_bool?),
        o["ocsp_stapling"]?.try(&.as_bool?),
      )
    end
    out
  end

  # One protocol-bound node, normalised. An out-of-range value degrades to "" (leave OpenSSL's
  # default alone) rather than failing the whole load — the same tolerance every other section
  # applies to a hand-edited file, and the save-time validator is where a typo is reported.
  private def self.parse_version(node : JSON::Any?) : String
    v = node.try(&.as_s?).try(&.strip.downcase) || ""
    TLS_VERSIONS.includes?(v) ? v : ""
  end

  # A preset NAME, normalised — and kept VERBATIM even when gori does not know it.
  #
  # Deliberately NOT `parse_version`'s shape, which folds an unknown value to "". Doing that
  # here would delete the only evidence a typo ever existed: the rule would load as
  # all-defaults, `outbound_tls_warnings` would have nothing to report, and gori would dial the
  # host with its bare OpenSSL hello while the operator believed Chrome's was going out. An
  # unknown name is the one case where silence is worse than a wrong value, because the whole
  # point of the field is that you cannot see its effect. `preset_profile` still resolves to
  # nil (so nothing is applied) and the startup warning names it.
  private def self.parse_tls_preset(node : JSON::Any?) : String
    node.try(&.as_s?).try(&.strip.downcase) || ""
  end

  # The ALPN list. A JSON array is the documented form; a plain STRING is also accepted and
  # split on commas/whitespace, because `"alpn": "h2, http/1.1"` is what a hand-edit reaches
  # for and silently loading it as "no ALPN configured" would be the section's own
  # silent-no-op failure. Entries are NOT case-folded — an ALPN identifier is a byte string,
  # and `H2` is not `h2` on the wire.
  private def self.parse_alpn_list(node : JSON::Any?) : Array(String)
    return [] of String unless node
    if arr = node.as_a?
      return arr.compact_map { |e| e.as_s?.try(&.strip.presence) }
    end
    (node.as_s? || "").split(/[,\s]+/).compact_map(&.strip.presence)
  end

  # Factory reset for this section (dispatched by Settings.reset_to_factory). Through the
  # SETTER, so the compiled host patterns go with the rules and `outbound_tls_for` falls
  # back to DEFAULT_OUTBOUND_TLS again.
  private def self.reset_outbound_tls : Nil
    self.outbound_tls = [] of OutboundTlsRule
  end

  # Omit when empty so an untouched install never writes "outbound_tls": [].
  private def self.serialize_outbound_tls(j : JSON::Builder) : Nil
    return if outbound_tls.empty?
    j.field "outbound_tls" do
      j.array do
        outbound_tls.each do |r|
          j.object do
            j.field "host", r.host
            j.field "client_cert", r.client_cert unless r.client_cert.empty?
            j.field "client_key", r.client_key unless r.client_key.empty?
            j.field "min_version", r.min_version unless r.min_version.empty?
            j.field "max_version", r.max_version unless r.max_version.empty?
            j.field "ciphers", r.ciphers unless r.ciphers.empty?
            j.field "permissive", r.permissive if r.permissive
            serialize_outbound_tls_fingerprint(j, r)
          end
        end
      end
    end
  end

  # Every configured rule gori would not be able to apply, as operator-facing lines.
  #
  # Consulted at STARTUP, and that is the point: this table is the one section with no in-app
  # editor — `gori settings --edit` opens the JSON — so `outbound_tls_error` had no save to run
  # at, and a typo in `groups` (or a client certificate that has since been deleted) showed up
  # only as every dial to that host failing, with an OpenSSL message that reads like the
  # ORIGIN's TLS leg refusing. A warning is the right severity: the rest of the table, and the
  # rest of gori, still work.
  def self.outbound_tls_warnings : Array(String)
    outbound_tls.compact_map do |rule|
      err = outbound_tls_error(rule) rescue nil
      err ? "#{err} — the rule for #{rule.host}; TLS dials to that destination will fail" : nil
    end
  rescue
    # This runs before the proxy binds, on both startup paths. A warning that can take the app
    # down is worse than the problem it reports — the sibling it is modelled on
    # (`Upstream.trust_store_warning`) is guarded at every level for the same reason.
    [] of String
  end

  # The #822 ClientHello-shaping half of one row, split out so `serialize_outbound_tls` stays
  # one loop rather than one loop and thirteen conditionals.
  private def self.serialize_outbound_tls_fingerprint(j : JSON::Builder, r : OutboundTlsRule) : Nil
    j.field "preset", r.preset unless r.preset.empty?
    j.field "groups", r.groups unless r.groups.empty?
    j.field "sigalgs", r.sigalgs unless r.sigalgs.empty?
    j.field "ciphersuites", r.ciphersuites unless r.ciphersuites.empty?
    unless r.alpn.empty?
      j.field "alpn" do
        j.array { r.alpn.each { |p| j.string p } }
      end
    end
    # Written only when STATED. Emitting the effective value would bake a preset's choice into
    # the file as if the operator had typed it, and the next release's preset edit would then
    # be silently overridden by its own former self.
    r.session_tickets.try { |v| j.field "session_tickets", v }
    r.ocsp_stapling.try { |v| j.field "ocsp_stapling", v }
  end

  # nil if `rule` is usable; an error message otherwise. Checked at save time so a
  # half-configured pair or a missing file surfaces here rather than as a handshake failure
  # that reads like the ORIGIN's fault.
  def self.outbound_tls_error(rule : OutboundTlsRule) : String?
    return "settings: outbound TLS rule needs a host pattern" if rule.host.strip.empty?
    if err = protocol_range_error(rule)
      return err
    end
    if err = fingerprint_error(rule)
      return err
    end
    cert = rule.client_cert
    key = rule.client_key
    if cert.empty? != key.empty?
      # One half alone can never work, and OpenSSL's error would point at the handshake.
      return "settings: outbound TLS needs BOTH client_cert and client_key (or neither)"
    end
    return nil if cert.empty?
    return "settings: client_cert not readable: #{cert}" unless file_readable?(cert)
    return "settings: client_key not readable: #{key}" unless file_readable?(key)
    # An encrypted key would make OpenSSL prompt for a passphrase on a terminal the TUI owns —
    # the process would appear to hang with no visible prompt. Refuse it here, where the
    # message can say what to do, rather than at the first dial.
    return "settings: client_key is passphrase-protected; decrypt it first (openssl pkey -in #{key} -out key.pem)" if encrypted_key?(key)
    nil
  end

  # The ClientHello-shaping half of outbound_tls_error (#822). Every check here asks the
  # OpenSSL that will consume the value (see `Tls::ClientShape`), so it answers for THIS build
  # rather than for a grammar re-implemented in the settings layer.
  #
  # TWO passes, and they are not the same question. The first asks about the strings the
  # OPERATOR typed and names the setting; the second asks about the values a PRESET
  # contributes, and names the preset. Checking only the raw fields would leave a preset
  # unvalidated on the build that has to run it — and a preset that this OpenSSL refuses
  # raises at the first dial, on a host the operator chose it for, with a message that reads
  # like the origin's TLS leg refusing. `effective_*` equals the raw value whenever the rule
  # set one, so the second pass only ever exercises what the preset actually supplied.
  #
  # `permissive` is threaded through because `Upstream.apply_outbound_tls` drops the security
  # level to 0 BEFORE these knobs; a validator that did not would answer for a different
  # context than the dial builds.
  #
  # `ciphers` is NOT validated. It is the one pre-existing field, it predates this check, and
  # refusing input the dial accepts is worse for it than saying nothing.
  private def self.fingerprint_error(rule : OutboundTlsRule) : String?
    unless rule.preset.empty? || TLS_PRESETS.has_key?(rule.preset)
      return "settings: outbound TLS preset must be one of #{TLS_PRESET_NAMES.join(", ")} " \
             "(got #{rule.preset.inspect})"
    end
    if err = shape_error(rule, rule.groups, rule.sigalgs, rule.ciphersuites, rule.alpn)
      return err
    end
    return nil unless rule.preset_profile
    err = shape_error(rule, rule.effective_groups, rule.effective_sigalgs,
      rule.effective_ciphersuites, rule.effective_alpn)
    err ? "settings: the #{rule.preset.inspect} outbound TLS preset is not usable on this " \
          "OpenSSL build — #{err.lchop("settings: ")}" : nil
  end

  # The four shape checks in one place, so the raw pass and the preset pass cannot drift.
  private def self.shape_error(rule : OutboundTlsRule, groups : String, sigalgs : String,
                               ciphersuites : String, alpn : Array(String)) : String?
    permissive = rule.permissive
    Proxy::Tls::ClientShape.groups_error(groups, permissive) ||
      Proxy::Tls::ClientShape.sigalgs_error(sigalgs, permissive) ||
      Proxy::Tls::ClientShape.ciphersuites_error(ciphersuites, permissive) ||
      Proxy::Tls::ClientShape.alpn_error(alpn)
  end

  # The floor/ceiling half of outbound_tls_error, split out so neither method carries the
  # whole rule's validation.
  #
  # The third check is the one that is not just a spelling test: an inverted pair (min tls1.3
  # / max tls1.2) offers NO protocol version at all, so OpenSSL would fail every handshake for
  # the host with an error that names the ORIGIN rather than the two settings fields that
  # disagree.
  private def self.protocol_range_error(rule : OutboundTlsRule) : String?
    lo = rule.min_version
    hi = rule.max_version
    return "settings: outbound TLS min_version must be one of #{TLS_VERSIONS.join(", ")}" unless version_ok?(lo)
    return "settings: outbound TLS max_version must be one of #{TLS_VERSIONS.join(", ")}" unless version_ok?(hi)
    lo_rank = TLS_VERSIONS.index(lo)
    hi_rank = TLS_VERSIONS.index(hi)
    return nil unless lo_rank && hi_rank && lo_rank > hi_rank
    "settings: outbound TLS min_version (#{lo}) is above max_version (#{hi})"
  end

  # "" (leave the default alone) or a known version. Empty deliberately passes: both bounds
  # are independently optional.
  private def self.version_ok?(version : String) : Bool
    version.empty? || TLS_VERSIONS.includes?(version)
  end

  private def self.file_readable?(path : String) : Bool
    File.file?(path) && File::Info.readable?(path)
  rescue
    false
  end

  # A PEM private key that carries a passphrase: either the PKCS#8 "ENCRYPTED PRIVATE KEY"
  # header, or a traditional-format key with the legacy `Proc-Type: 4,ENCRYPTED` line. Reads
  # only the head of the file — enough for both markers, and it avoids pulling a key into
  # memory just to classify it.
  private def self.encrypted_key?(path : String) : Bool
    buf = Bytes.new(4096)
    n = File.open(path, &.read(buf))
    head = String.new(buf[0, n])
    head.includes?("ENCRYPTED PRIVATE KEY") || head.includes?("Proc-Type: 4,ENCRYPTED")
  rescue
    false # unreadable was already reported above; never fail the save on a classification error
  end
end
