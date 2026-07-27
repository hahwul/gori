require "json"
require "../host_pattern"

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
  # Protocol floors, lowest first. "" = leave OpenSSL/Crystal's default alone.
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
  record OutboundTlsRule,
    host : String,
    client_cert : String = "",
    client_key : String = "",
    min_version : String = "",
    ciphers : String = "",
    permissive : Bool = false do
    # Whether this rule asks for mutual TLS. Both halves are required — OpenSSL needs the
    # chain and the key, and a half-configured pair would fail the handshake with a message
    # that points at the origin rather than at the settings file.
    def client_auth? : Bool
      !client_cert.empty? && !client_key.empty?
    end

    # True when the rule changes nothing, so the shared default context can be reused.
    def default? : Bool
      !client_auth? && min_version.empty? && ciphers.empty? && !permissive
    end

    # A stable identity for this policy, used as part of the TLS context cache key. Contexts
    # are shared per distinct policy, so this MUST cover every field that mutates the context —
    # a field left out here means an edit silently reuses the first context built.
    # Joined on a NUL escape, which no path or cipher string can contain, so two distinct
    # policies can never collide into one key. Built with join, not string interpolation:
    # inside a `record` block body the interpolation form does not compile here.
    def cache_key : String
      return "" if default?
      [client_cert, client_key, min_version, ciphers, permissive.to_s].join('\0')
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

  # The TLS policy for `dest_host` — the first matching rule, else the all-defaults policy.
  # Called once per TLS dial, so the patterns are precompiled (see the setter above).
  def self.outbound_tls_for(dest_host : String) : OutboundTlsRule
    return DEFAULT_OUTBOUND_TLS if @@outbound_tls_compiled.empty?
    bare = HostPattern.bare(dest_host.downcase)
    match = @@outbound_tls_compiled.find { |(pattern, _)| pattern.matches_bare?(bare) }
    match ? match[1] : DEFAULT_OUTBOUND_TLS
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
      version = o["min_version"]?.try(&.as_s?).try(&.strip.downcase) || ""
      version = "" unless TLS_VERSIONS.includes?(version)
      out << OutboundTlsRule.new(
        host,
        o["client_cert"]?.try(&.as_s?).try(&.strip) || "",
        o["client_key"]?.try(&.as_s?).try(&.strip) || "",
        version,
        o["ciphers"]?.try(&.as_s?).try(&.strip) || "",
        o["permissive"]?.try(&.as_bool?) || false,
      )
    end
    out
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
            j.field "ciphers", r.ciphers unless r.ciphers.empty?
            j.field "permissive", r.permissive if r.permissive
          end
        end
      end
    end
  end

  # nil if `rule` is usable; an error message otherwise. Checked at save time so a
  # half-configured pair or a missing file surfaces here rather than as a handshake failure
  # that reads like the ORIGIN's fault.
  def self.outbound_tls_error(rule : OutboundTlsRule) : String?
    return "settings: outbound TLS rule needs a host pattern" if rule.host.strip.empty?
    unless rule.min_version.empty? || TLS_VERSIONS.includes?(rule.min_version)
      return "settings: outbound TLS min_version must be one of #{TLS_VERSIONS.join(", ")}"
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
