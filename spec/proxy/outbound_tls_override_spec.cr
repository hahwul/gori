require "../spec_helper"
require "openssl"

include Gori::Proxy::Tls

# #844 — the PER-SEND TLS fingerprint override: a Repeater tab or a fuzz run naming a
# fingerprint for one send, without touching the destination table.
#
# Two things are being pinned here, and only one of them is about presets:
#
#   * the NARROWING RULE — field by field, what an override may and may not change on an
#     `OutboundTlsRule`. A client certificate configured for that host must still be
#     presented, or "chrome vs curl" silently becomes "authenticated vs anonymous".
#   * the CACHE KEY, which #822's own review called the most likely bug in that issue and
#     which an override reintroduces from a new direction. If the override does not reach
#     `cache_key`, two sends with different fingerprints share one SSL_CTX and the operator
#     compares two responses that came out of ONE handshake — the exact experiment this
#     feature exists to make possible, silently not performed.

private def reset_outbound_tls : Nil
  Gori::Settings.outbound_tls = [] of Gori::Settings::OutboundTlsRule
end

private def tls_rule(host : String, cert : String = "", key : String = "",
                     min_version : String = "", max_version : String = "",
                     ciphers : String = "", permissive : Bool = false,
                     preset : String = "", groups : String = "", sigalgs : String = "",
                     ciphersuites : String = "", alpn : Array(String) = [] of String,
                     session_tickets : Bool? = nil,
                     ocsp_stapling : Bool? = nil) : Gori::Settings::OutboundTlsRule
  Gori::Settings::OutboundTlsRule.new(host, cert, key, min_version, max_version, ciphers,
    permissive, preset, groups, sigalgs, ciphersuites, alpn, session_tickets, ocsp_stapling)
end

# host + per-send override → rule → context: the exact chain `Upstream.dial_tls_result` walks.
private def context_for_send(host : String, override : String? = nil,
                             alpn : String? = "h2") : OpenSSL::SSL::Context::Client
  Gori::Proxy::Upstream.context_for_policy(
    Gori::Settings.outbound_tls_for(host, override), verify: false, alpn: alpn)
end

describe "outbound TLS per-send override (#844)" do
  describe "preset name validation" do
    it "accepts every shipped preset, in any case, with surrounding space" do
      Gori::Settings::TLS_PRESET_NAMES.each do |name|
        Gori::Settings.tls_preset_error(name).should be_nil
        Gori::Settings.tls_preset_error("  #{name.upcase}  ").should be_nil
        Gori::Settings.tls_preset_normalize("  #{name.upcase}  ").should eq(name)
      end
    end

    it "treats absent and blank as no override" do
      Gori::Settings.tls_preset_error(nil).should be_nil
      Gori::Settings.tls_preset_error("").should be_nil
      Gori::Settings.tls_preset_error("   ").should be_nil
      Gori::Settings.tls_preset_normalize(nil).should be_nil
      Gori::Settings.tls_preset_normalize("   ").should be_nil
    end

    # An unknown name applies NOTHING, so a send under one would go out with gori's bare
    # OpenSSL hello while the operator believed a browser's was going out. Unlike the
    # destination table there is no startup warning to catch it, so every surface refuses it
    # up front — and the message has to name the alternatives, or the operator cannot act.
    it "refuses an unknown name and names the ones that exist" do
      err = Gori::Settings.tls_preset_error("chromee")
      err.should_not be_nil
      err.not_nil!.should contain("chromee")
      Gori::Settings::TLS_PRESET_NAMES.each { |n| err.not_nil!.should contain(n) }
    end
  end

  describe "what an override may change" do
    # The whole ClientHello SHAPE is REPLACED, not merged. Merged would leave the
    # destination's own fields winning (a rule's fields beat its preset — see
    # `effective_groups`), so an override could not change the one thing it exists to change.
    it "replaces every ClientHello-shaping field with the named preset's" do
      dest = tls_rule("h", preset: "firefox", groups: "P-521", sigalgs: "rsa_pkcs1_sha256",
        ciphers: "AES128-SHA", ciphersuites: "TLS_AES_256_GCM_SHA384",
        alpn: ["http/1.1"], session_tickets: false, ocsp_stapling: false)
      sent = dest.with_fingerprint("chrome")
      chrome = Gori::Settings::TLS_PRESETS["chrome"]

      sent.preset.should eq("chrome")
      sent.effective_groups.should eq(chrome.groups)
      sent.effective_sigalgs.should eq(chrome.sigalgs)
      sent.effective_ciphers.should eq(chrome.ciphers)
      sent.effective_ciphersuites.should eq(chrome.ciphersuites)
      sent.effective_alpn.should eq(chrome.alpn)
      sent.effective_session_tickets?.should eq(chrome.session_tickets)
      sent.effective_ocsp_stapling?.should eq(chrome.ocsp_stapling)
    end

    # The acceptance criterion in its own words: "an override does not suppress a client
    # certificate configured for that destination". An override says what the hello should
    # LOOK like, not who gori IS.
    it "still presents the destination's client certificate" do
      dest = tls_rule("h", cert: "/etc/gori/client.pem", key: "/etc/gori/client.key")
      sent = dest.with_fingerprint("chrome")
      sent.client_cert.should eq("/etc/gori/client.pem")
      sent.client_key.should eq("/etc/gori/client.key")
      sent.client_auth?.should be_true
    end

    # The version range is a reachability fact about that destination (a TLS 1.0-only
    # appliance stays reachable under any preset), and `permissive` is the one knob that
    # WIDENS what gori accepts — an override must be able neither to grant it nor to revoke it.
    it "keeps the destination's protocol range and permissive flag" do
      dest = tls_rule("h", min_version: "tls1.0", max_version: "tls1.2", permissive: true)
      sent = dest.with_fingerprint("curl")
      sent.min_version.should eq("tls1.0")
      sent.max_version.should eq("tls1.2")
      sent.permissive.should be_true
      sent.host.should eq("h")
    end

    # An unknown name is kept VERBATIM rather than folded to "no override" — the same
    # reasoning `Settings.parse_tls_preset` gives for the destination table. The surfaces
    # refuse it before the send; if one ever reaches here it must still be a distinct policy,
    # never one that quietly aliases the un-overridden rule.
    it "keeps an unknown name verbatim and still separates it from no override" do
      dest = tls_rule("h", preset: "chrome")
      sent = dest.with_fingerprint("chromee")
      sent.preset.should eq("chromee")
      sent.preset_profile.should be_nil
      sent.effective_groups.should eq("") # nothing applied — that is why it is refused up front
      sent.cache_key.should_not eq(dest.cache_key)
    end
  end

  describe "resolution" do
    it "returns the matched rule untouched when there is no override" do
      Gori::Settings.outbound_tls = [tls_rule("a.test", preset: "firefox")]
      base = Gori::Settings.outbound_tls_for("a.test")
      # nil, "" and whitespace all mean "no override", and all three must be the SAME policy
      # as the un-overridden one — including the cache key, so no-override behaviour is
      # byte-identical to what it was before #844 and reuses the very same context.
      [nil, "", "   "].each do |none|
        r = Gori::Settings.outbound_tls_for("a.test", none)
        r.should eq(base)
        r.cache_key.should eq(base.cache_key)
      end
    ensure
      reset_outbound_tls
    end

    it "narrows a host with no rule at all" do
      reset_outbound_tls
      r = Gori::Settings.outbound_tls_for("nothing.test", "chrome")
      r.preset.should eq("chrome")
      r.default?.should be_false
      Gori::Settings.outbound_tls_for("nothing.test").default?.should be_true
    end

    it "normalises the name so one intent is one policy" do
      Gori::Settings.outbound_tls_for("h", "  CHROME ").cache_key
        .should eq(Gori::Settings.outbound_tls_for("h", "chrome").cache_key)
    end
  end

  # THE TRAP. Not "the keys differ" but "the CONTEXTS differ, and the bytes they produce
  # differ" — a cache_key that is right for the wrong reason still has to fail this.
  describe "context cache" do
    it "does not let two different overrides on ONE host share an SSL context" do
      reset_outbound_tls
      a = context_for_send("same.test", "chrome")
      b = context_for_send("same.test", "curl")
      a.should_not be(b)

      fa = Fingerprint.of_context(a).not_nil!
      fb = Fingerprint.of_context(b).not_nil!
      fa.ja3.should_not eq(fb.ja3)
      fa.ja4_r.should_not eq(fb.ja4_r)

      # …and the cache still IS a cache: the same host with the same override is one context.
      context_for_send("same.test", "chrome").should be(a)
    end

    # The other direction, and the one an operator actually hits: the host HAS a standing
    # rule, and the tab overrides it for one send. The overridden send must not be served the
    # standing rule's context, and the un-overridden send must not be served the override's.
    it "does not let an overridden send share the destination rule's context" do
      Gori::Settings.outbound_tls = [tls_rule("std.test", preset: "chrome")]
      standing = context_for_send("std.test")
      overridden = context_for_send("std.test", "curl")
      standing.should_not be(overridden)
      Fingerprint.of_context(standing).not_nil!.ja3
        .should_not eq(Fingerprint.of_context(overridden).not_nil!.ja3)

      # An override naming what the rule already says IS the same policy, so sharing is
      # correct there — the key separates POLICIES, not requests.
      context_for_send("std.test", "chrome").should be(standing)
    ensure
      reset_outbound_tls
    end

    # Every preset gets its own context, pairwise — the sweep the single-pair test above
    # cannot make: a key that folded two of four presets together would still pass that one.
    it "gives every preset its own context on one host" do
      reset_outbound_tls
      ctxs = Gori::Settings::TLS_PRESET_NAMES.map { |n| context_for_send("sweep.test", n) }
      ctxs.map(&.object_id).uniq.size.should eq(ctxs.size)
      keys = Gori::Settings::TLS_PRESET_NAMES.map { |n| Gori::Settings.outbound_tls_for("sweep.test", n).cache_key }
      keys.uniq.size.should eq(keys.size)
    end

    # The client certificate rides the key too, so two hosts with different mTLS identities
    # under the SAME override are still two contexts. Without this an override would be the
    # one path on which a certificate could leak across destinations.
    it "keeps two destinations' client certificates apart under one override" do
      Gori::Settings.outbound_tls = [
        tls_rule("one.test", cert: "/a.pem", key: "/a.key"),
        tls_rule("two.test", cert: "/b.pem", key: "/b.key"),
      ]
      Gori::Settings.outbound_tls_for("one.test", "chrome").cache_key
        .should_not eq(Gori::Settings.outbound_tls_for("two.test", "chrome").cache_key)
    ensure
      reset_outbound_tls
    end
  end

  # The narrowing has to reach the WIRE, not just the record — the same standard #822 held
  # itself to. Two overrides on one host produce demonstrably different ClientHellos.
  describe "the hello that actually goes out" do
    it "sends the override's shape, not the destination rule's" do
      Gori::Settings.outbound_tls = [tls_rule("wire.test", preset: "firefox")]
      # Firefox is the one preset offering the ffdhe groups, so its supported_groups list is
      # longer than Chrome's — a difference readable off the parsed hello without pinning any
      # exact digest (these are approximations, and this spec must not imply otherwise).
      as_firefox = Fingerprint.parse(Fingerprint.hello_bytes(context_for_send("wire.test"))).not_nil!
      as_chrome = Fingerprint.parse(Fingerprint.hello_bytes(context_for_send("wire.test", "chrome"))).not_nil!
      as_firefox.groups.should_not eq(as_chrome.groups)
      as_chrome.groups.size.should be < as_firefox.groups.size
    ensure
      reset_outbound_tls
    end
  end
end
