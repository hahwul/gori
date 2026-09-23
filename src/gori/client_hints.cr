require "./session_slot"

module Gori
  # The low-entropy User-Agent client hints Chrome sends on every HTTPS request —
  # `sec-ch-ua`, `sec-ch-ua-mobile`, `sec-ch-ua-platform` — owned by the `chrome` TLS preset
  # (#1174, DESIGN.md §7). A Chrome-shaped ClientHello with no hints is itself a tell, and
  # Firefox and Safari send none, so these belong to the preset rather than to `$GEN`.
  #
  # Nothing here is approximated. Every value is DERIVED from the User-Agent the same request
  # carries, by a port of the Chromium code that produces it, pinned to one revision:
  #
  #   chromium/src @ ab1ade5d1fa5f1c0b2bf80ab48d9b9cb25aa3c95
  #   components/embedder_support/user_agent_utils.cc
  #     GenerateBrandVersionList, GetGreasedUserAgentBrandVersion, GetRandomOrder,
  #     ShuffleBrandList, GetPlatformForUAMetadata, GetMobileBitForUAMetadata, GetUnifiedPlatform
  #   base/version_info/version_info.h                    GetOSType
  #   third_party/blink/common/user_agent/user_agent_metadata.cc  SerializeBrandVersionList
  #
  # The spec (spec/client_hints_spec.cr) replays the vectors of that revision's
  # components/embedder_support/user_agent_utils_unittest.cc.
  #
  # A User-Agent Chrome would not itself send gets no hints at all: Edge, Opera and every other
  # Chromium browser append their own product token and send their own brand, which no
  # Chromium source states, so they are not guessed (#1112: a made-up value is worse than none).
  module ClientHints
    # GetGreasedUserAgentBrandVersion's two tables, in their order.
    GREASEY_CHARS   = [" ", "(", ":", "-", ".", "/", ")", ";", "=", "?", "_"]
    GREASED_VERSION = ["8", "99", "24"]

    # GetRandomOrder's stable permutations for a three-entry list (a two-entry list is
    # `{seed % 2, (seed + 1) % 2}`). Four entries only arise from an experiment's additional
    # brand, which a shipping Chrome does not send.
    ORDERS_3 = [{0, 1, 2}, {0, 2, 1}, {1, 0, 2}, {1, 2, 0}, {2, 0, 1}, {2, 1, 0}]

    # `version_info::GetProductName()` for a GOOGLE_CHROME_BRANDING build.
    CHROME_BRAND = "Google Chrome"

    # The exact string Chrome's BuildUserAgentFromOSAndProduct writes —
    # "Mozilla/5.0 (%s) AppleWebKit/537.36 (KHTML, like Gecko) %s Safari/537.36", where the
    # product is `Chrome/<version>` plus " Mobile" on an Android phone. Anchored at both ends,
    # so a trailing `Edg/…` or `OPR/…` (another browser's brand) does not match.
    CHROME_UA = /\AMozilla\/5\.0 \(([^()]*)\) AppleWebKit\/537\.36 \(KHTML, like Gecko\) Chrome\/(\d{1,4})(?:\.\d+)* (Mobile )?Safari\/537\.36\z/

    CHROME_TOKEN = "Chrome/".to_slice

    # The three header lines, in the order Chrome writes them on a navigation.
    NAMES = {"sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform"}

    # GetGreasedUserAgentBrandVersion, major-version form.
    def self.greased_brand(seed : Int32) : {String, String}
      brand = "Not#{GREASEY_CHARS[seed % GREASEY_CHARS.size]}A#{GREASEY_CHARS[(seed + 1) % GREASEY_CHARS.size]}Brand"
      {brand, GREASED_VERSION[seed % GREASED_VERSION.size]}
    end

    # GenerateBrandVersionList (no additional brand): the GREASE entry, Chromium, and the
    # browser brand when there is one, placed by ShuffleBrandList — entry `i` lands at
    # `order[i]`, it is not read from it.
    def self.brand_list(seed : Int32, brand : String?, version : String) : Array({String, String})
      raise ArgumentError.new("negative seed") if seed < 0
      list = [greased_brand(seed), {"Chromium", version}]
      list << {brand, version} if brand
      order = list.size == 2 ? {seed % 2, (seed + 1) % 2} : ORDERS_3[seed % ORDERS_3.size]
      shuffled = list.dup
      list.each_with_index { |entry, i| shuffled[order[i]] = entry }
      shuffled
    end

    # SerializeBrandVersionList: an RFC 8941 list of strings, each with a `v` string parameter.
    def self.serialize(list : Array({String, String})) : String
      list.join(", ") { |(brand, version)| "#{sf_string(brand)};v=#{sf_string(version)}" }
    end

    # RFC 8941 §4.1.6: a quoted string escaping `"` and `\`. No brand Chromium generates has
    # either, but the serializer is the thing being ported.
    private def self.sf_string(s : String) : String
      %("#{s.gsub('\\', "\\\\").gsub('"', "\\\"")}")
    end

    # The platform `sec-ch-ua-platform` names for the OS section of a Chrome UA — the reverse
    # of GetUnifiedPlatform, answered by GetPlatformForUAMetadata / GetOSType. nil for an OS
    # section Chrome does not write, which then sends no hints rather than a guessed platform.
    def self.platform_for(os : String) : String?
      return "Windows" if os.starts_with?("Windows NT ")
      return "macOS" if os.starts_with?("Macintosh; ")
      return "Chrome OS" if os.starts_with?("X11; CrOS ")
      return "Android" if os.starts_with?("Linux; Android")
      return "Linux" if os.starts_with?("X11; Linux ")
      nil
    end

    # The hint lines for a User-Agent, as {name, value} in send order, or nil when it is not
    # one Chrome sends. The brand list is seeded and versioned by the UA's own major, so the
    # two can never disagree within a request.
    def self.for_user_agent(ua : String) : Array({String, String})?
      # scrub: the UA is wire bytes, and an invalid UTF-8 byte would make the PCRE match raise
      # in the sending fiber. U+FFFD is outside the pattern, so such a UA gets no hints.
      m = CHROME_UA.match(ua.scrub) || return
      platform = platform_for(m[1]) || return
      major = m[2].to_i
      # GetMobileBitForUAMetadata: true exactly when the Android UA carries " Mobile".
      mobile = !m[3]?.nil? && platform == "Android"
      [
        {NAMES[0], serialize(brand_list(major, CHROME_BRAND, major.to_s))},
        {NAMES[1], mobile ? "?1" : "?0"},
        {NAMES[2], sf_string(platform)},
      ]
    end

    # The request `wire` with the preset's hints written in, or `wire` itself (the same object)
    # when none apply. Applies only to an HTTPS request under the `chrome` preset — the family
    # the block yields, which `Env.client_hints` resolves from the dial exactly as
    # `$GEN.USER_AGENT` narrows — whose head holds ONE User-Agent that Chrome would send, and no
    # `sec-ch-ua*` header at all. An operator-typed hint means the operator owns the set (P7),
    # so none is added beside it. The block runs only for an HTTPS head that mentions `Chrome/`,
    # so a plaintext send, or a run that carries no Chrome UA, never pays the preset lookup.
    # A WebSocket handshake gets none: that Chromium sends hints there is not established from
    # its source. Header-only, before the User-Agent line, so the body and Content-Length never
    # move.
    #
    # Called on the final bytes, after `$NAME` expansion and the session-slot overlay, so the
    # UA it reads is the one on the wire whoever wrote it — a `$GEN.USER_AGENT` mint, the
    # slot's header, or a literal.
    def self.apply(wire : Bytes, dial_scheme : String?, & : -> String?) : Bytes
      return wire unless dial_scheme == "https"
      head_len = SessionSlot.head_length(wire)
      # A byte scan before the preset lookup: a head that never says `Chrome/` cannot carry a UA
      # this would read, so it costs neither the lookup nor a parse.
      return wire unless SessionSlot.index_of(wire[0, head_len], CHROME_TOKEN)
      return wire unless yield == "CHROME"
      lines = SessionSlot.split_head_lines(String.new(wire[0, head_len]))
      at = user_agent_line(lines) || return wire
      hints = for_user_agent(lines[at][0].split(':', 2)[1].strip) || return wire
      eol = lines[at][1].empty? ? "\r\n" : lines[at][1]
      lines.insert_all(at, hints.map { |(n, v)| {"#{n}: #{v}", eol} })
      io = IO::Memory.new(wire.size + 160)
      lines.each { |(content, term)| io << content << term }
      io.write(wire[head_len..]) if head_len < wire.size
      io.to_slice
    end

    # The index of the head's one User-Agent line, or nil when hints must not be added: no
    # User-Agent, two of them (no one value to agree with), any `sec-ch-ua*` header already
    # there (the operator's set), or an `Upgrade` (a WebSocket handshake).
    private def self.user_agent_line(lines : Array({String, String})) : Int32?
      at = nil
      lines.each_with_index do |(content, _), i|
        next if i == 0 # the request line
        break if content.empty?
        colon = content.index(':') || next
        name = content[0, colon].strip.downcase
        return nil if name.starts_with?("sec-ch-ua") || name == "upgrade"
        next unless name == "user-agent"
        return nil if at
        at = i
      end
      at
    end
  end
end
