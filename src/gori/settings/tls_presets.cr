module Gori::Settings
  # Named browser-shaped outbound-TLS profiles for `outbound_tls[].preset`.
  #
  # READ THIS BEFORE TRUSTING A PRESET. These are APPROXIMATIONS, not impersonations, and the
  # gap is not a matter of filling in more fields — it is structural:
  #
  #   * EXTENSION ORDER is OpenSSL's, and OpenSSL emits its own fixed order. Browsers use a
  #     different one (Chrome shuffles it per install). JA3 hashes the order, so a JA3 taken
  #     from a preset will NOT equal the browser's JA3, ever, from stock OpenSSL.
  #   * GREASE (RFC 8701) placement is OpenSSL's. It is stripped by both fingerprints, but the
  #     reserved values a browser injects sit at positions OpenSSL chooses differently.
  #   * POST-QUANTUM key shares (X25519MLKEM768) that current Chrome and Firefox offer FIRST
  #     are deliberately absent from `groups`: they exist only on OpenSSL 3.5+, and a preset
  #     that fails to apply on an older build is worse than one that is honestly incomplete.
  #     Add it to a rule's own `groups` where the linked OpenSSL has it.
  #   * SHA-1 SIGNATURE ALGORITHMS (`ecdsa_sha1`, `rsa_pkcs1_sha1`), which Firefox and Safari
  #     still list last as legacy fallbacks, are absent for the same reason and it is not
  #     hypothetical: Debian and Ubuntu ship OpenSSL with SHA-1 signatures disabled at the
  #     default security level, so `SSL_CTX_set1_sigalgs_list` REFUSES the whole list and every
  #     dial to that destination raises. They are the cheapest entries to lose — no modern
  #     origin selects one — and `permissive: true` is not the answer, because buying two dead
  #     sigalgs with security level 0 and renegotiation is a far worse trade than the gap.
  #
  # What a preset DOES get right is every value-level field an origin's classifier reads:
  # the cipher list and its order, the TLS 1.3 suites, the named groups, the signature
  # algorithms, the ALPN list, and whether `session_ticket` / `status_request` appear at all.
  # That is enough to stop looking like a bare OpenSSL client, which is the problem operators
  # actually hit. It is not enough to claim to BE Chrome, and gori never says it is —
  # `gori settings tls-fingerprint` prints the JA3/JA4 that really goes out, so the claim can
  # be checked rather than believed.
  #
  # A rule's own fields OVERRIDE the preset it names, so a preset is a starting point, not a
  # lock. See `OutboundTlsRule#effective_groups` and friends.
  record TlsPreset,
    name : String,
    summary : String,
    groups : String = "",
    sigalgs : String = "",
    ciphers : String = "",
    ciphersuites : String = "",
    alpn : Array(String) = [] of String,
    session_tickets : Bool = true,
    ocsp_stapling : Bool = false

  # ALPN every modern browser offers, in the order they offer it.
  private BROWSER_ALPN = ["h2", "http/1.1"]

  # The TLS 1.3 suites, in each client's own preference order. All three are mandatory-ish and
  # present on every OpenSSL build gori can link, so no preset needs a fallback.
  private TLS13_AES_FIRST  = "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256"
  private TLS13_CHACHA_MID = "TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384"

  TLS_PRESETS = {
    "chrome" => TlsPreset.new(
      name: "chrome",
      summary: "Chromium-family desktop (Chrome, Edge, Brave, Opera)",
      groups: "X25519:P-256:P-384",
      sigalgs: "ecdsa_secp256r1_sha256:rsa_pss_rsae_sha256:rsa_pkcs1_sha256:" \
               "ecdsa_secp384r1_sha384:rsa_pss_rsae_sha384:rsa_pkcs1_sha384:" \
               "rsa_pss_rsae_sha512:rsa_pkcs1_sha512",
      ciphers: "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:" \
               "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:" \
               "ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:" \
               "ECDHE-RSA-AES128-SHA:ECDHE-RSA-AES256-SHA:" \
               "AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA:AES256-SHA",
      ciphersuites: TLS13_AES_FIRST,
      alpn: BROWSER_ALPN,
      ocsp_stapling: true,
    ),
    "firefox" => TlsPreset.new(
      name: "firefox",
      summary: "Firefox desktop — note the ffdhe groups, which no other client offers",
      groups: "X25519:P-256:P-384:P-521:ffdhe2048:ffdhe3072",
      sigalgs: "ecdsa_secp256r1_sha256:ecdsa_secp384r1_sha384:ecdsa_secp521r1_sha512:" \
               "rsa_pss_rsae_sha256:rsa_pss_rsae_sha384:rsa_pss_rsae_sha512:" \
               "rsa_pkcs1_sha256:rsa_pkcs1_sha384:rsa_pkcs1_sha512",
      ciphers: "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:" \
               "ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:" \
               "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:" \
               "ECDHE-ECDSA-AES256-SHA:ECDHE-ECDSA-AES128-SHA:" \
               "ECDHE-RSA-AES128-SHA:ECDHE-RSA-AES256-SHA:" \
               "AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA:AES256-SHA",
      ciphersuites: TLS13_CHACHA_MID,
      alpn: BROWSER_ALPN,
      ocsp_stapling: true,
    ),
    "safari" => TlsPreset.new(
      name: "safari",
      summary: "Safari / any macOS or iOS app on Secure Transport",
      groups: "X25519:P-256:P-384:P-521",
      sigalgs: "ecdsa_secp256r1_sha256:rsa_pss_rsae_sha256:rsa_pkcs1_sha256:" \
               "ecdsa_secp384r1_sha384:rsa_pss_rsae_sha384:rsa_pkcs1_sha384:" \
               "rsa_pss_rsae_sha512:rsa_pkcs1_sha512",
      ciphers: "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-GCM-SHA256:" \
               "ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-AES256-GCM-SHA384:" \
               "ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-CHACHA20-POLY1305:" \
               "ECDHE-ECDSA-AES256-SHA:ECDHE-ECDSA-AES128-SHA:" \
               "ECDHE-RSA-AES256-SHA:ECDHE-RSA-AES128-SHA:" \
               "AES256-GCM-SHA384:AES128-GCM-SHA256:AES256-SHA:AES128-SHA",
      ciphersuites: TLS13_AES_FIRST,
      alpn: BROWSER_ALPN,
      ocsp_stapling: true,
    ),
    # Not a browser, and that is the point: curl built against OpenSSL sends OpenSSL's own
    # hello. The preset therefore configures NOTHING but the ALPN pair curl offers with
    # `--http2` — which makes it the honest baseline to compare a browser preset against, and
    # documents that "looks like curl" is what gori does by default.
    "curl" => TlsPreset.new(
      name: "curl",
      summary: "curl/libcurl on OpenSSL — this build's stock hello, plus curl's ALPN pair",
      alpn: BROWSER_ALPN,
    ),
  }

  # Listing order for the docs, the CLI and the settings validator's error message. DERIVED,
  # not a second literal: a Crystal Hash preserves insertion order, and a hand-written list
  # beside the table is a preset that can be added to one and forgotten in the other — live to
  # the loader, absent from the error message, and untouched by the specs that check every
  # preset against the linked OpenSSL.
  TLS_PRESET_NAMES = TLS_PRESETS.keys
end
