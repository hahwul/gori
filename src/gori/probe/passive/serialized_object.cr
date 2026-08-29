require "uri"
require "./rule"

module Gori
  module Probe
    module Passive
      # Native-serialization blobs carried in client-controllable data (category "infoleak").
      # A Java/.NET/PHP object graph round-tripping through a cookie, a parameter, or an ASP.NET
      # ViewState field is the classic insecure-deserialization surface: if the server hands the
      # blob back to a native deserializer without integrity protection, a crafted object graph
      # is remote code execution (ysoserial, ViewState gadgets, PHP POP chains). Passive
      # analysis cannot prove the sink deserializes it — that is what the manual loop is for —
      # but it can point the operator straight at the surface.
      #
      # PRECISION over recall, like the sibling `exposed_config`. Every signature is a serialized
      # stream's MAGIC PREFIX matched in a VALUE POSITION (a cookie value, a query/body parameter
      # value, a hidden-field value), never a keyword scanned across a whole body. The magics are
      # so distinctive — `rO0AB` is base64 for Java's `AC ED 00 05` stream header, `AAEAAAD/////`
      # is base64 for the .NET BinaryFormatter record header — that a value-position prefix match
      # is effectively zero-FP. `/wE` (base64 `FF 01`) is shorter, so it is only ever read as a
      # serialized surface when it sits in a value position AND is followed by a base64 run, and
      # an ENCRYPTED ViewState (opaque base64 that does not begin `/wE`) is deliberately NOT
      # flagged — encryption is the fix, so flagging it would punish the secure configuration.
      class SerializedObject < Rule
        def info : RuleInfo
          RuleInfo.new("serialized_object", "Serialized object exposure",
            "Detects native-serialization blobs (Java, .NET BinaryFormatter/ViewState, PHP) in " \
            "cookies, parameters, and hidden fields — the insecure-deserialization attack surface.",
            Category::INFOLEAK)
        end

        # base64( AC ED 00 05 ) — the Java serialization stream magic + version. Every Java
        # `ObjectOutputStream` byte stream, and every ysoserial payload, begins with it.
        JAVA_B64 = "rO0AB"
        # The same stream hex-encoded (some frameworks hex a serialized cookie); anchored at the
        # start so a hex blob merely CONTAINING these bytes later does not match.
        JAVA_HEX = /\Aaced0005/i
        # base64( 00 01 00 00 00 FF FF FF FF ) — the .NET BinaryFormatter SerializationHeaderRecord.
        NET_BINFMT = "AAEAAAD/////"
        # An ASP.NET / JSF LosFormatter ViewState value: base64( FF 01 … ) → `/wE…`. The trailing
        # base64 run keeps a literal value of `/wE` (or a path like `/web`) from matching.
        VIEWSTATE = /\A\/wE[A-Za-z0-9+\/]{8,}={0,2}/
        # A PHP `serialize()`d object: `O:<len>:"ClassName":<count>:{`. The full structural shape
        # (class-name length, quoted name, property count, brace) is what a prose `O:` cannot fake.
        PHP_OBJECT = /\AO:\d{1,5}:"[^"]{1,256}":\d{1,6}:\{/

        # An `<input …>` that both names itself a ViewState field AND carries a value, capturing
        # the value. Two orderings (name-before-value and value-before-name) are both covered
        # because the leading `[^>]*` scans the whole tag up to whichever attribute it needs.
        VIEWSTATE_INPUT =
          /<input\b(?=[^>]*\bname\s*=\s*["'](?:__VIEWSTATE|javax\.faces\.ViewState)["'])[^>]*\bvalue\s*=\s*["']([^"']*)["']/i

        def check(ctx : Context, acc : Array(Detection)) : Nil
          # evidence => severity, deduped within the flow (a cookie echoed in both the request
          # and the response would otherwise report twice); keep the higher severity per label.
          hits = {} of String => Store::Severity

          scan_request(ctx, hits)
          scan_response(ctx, hits)

          hits.each do |evidence, sev|
            acc << Detection.new("serialized_object", Category::INFOLEAK, ctx.host, ctx.url,
              "Serialized object exposed", sev, evidence, ctx.fid)
          end
        end

        # Request side is CLIENT-CONTROLLABLE — the operator supplied the bytes, so if a sink
        # deserializes them this is the exploitable direction. Scored Medium.
        private def scan_request(ctx : Context, hits : Hash(String, Store::Severity)) : Nil
          if cookie = ctx.req.headers.get?("Cookie")
            each_pair(cookie, ';') do |name, value|
              if fmt = classify(value)
                mark(hits, fmt, "cookie '#{name}'", Store::Severity::Medium)
              end
            end
          end

          query_pairs(ctx.req.target).each do |name, value|
            if fmt = classify(value)
              mark(hits, fmt, "parameter '#{display(name)}'", Store::Severity::Medium)
            end
          end

          if urlencoded_request?(ctx) && (body = ctx.request_body_text)
            each_pair(body, '&') do |name, value|
              if fmt = classify(value)
                mark(hits, fmt, "parameter '#{display(name)}'", Store::Severity::Medium)
              end
            end
          end
        end

        # Response side is a SURFACE INDICATOR: the server emits the blob (a Set-Cookie, an
        # unencrypted ViewState hidden field) and the client posts it back, so it points at a
        # deserializer without proving the operator can drive it yet. Scored Low.
        private def scan_response(ctx : Context, hits : Hash(String, Store::Severity)) : Nil
          return unless resp = ctx.response

          resp.headers.get_all("Set-Cookie").each do |raw|
            nv = raw.split(';', 2)[0]
            eq = nv.index('=') || next
            name = nv[0...eq].strip
            if fmt = classify(nv[(eq + 1)..].strip)
              mark(hits, fmt, "Set-Cookie '#{name}'", Store::Severity::Low)
            end
          end

          if (body = ctx.body_text) && (body.includes?("VIEWSTATE") || body.includes?("ViewState"))
            field = body.includes?("javax.faces.ViewState") ? "javax.faces.ViewState" : "__VIEWSTATE"
            body.scan(VIEWSTATE_INPUT) do |m|
              if fmt = classify(m[1])
                mark(hits, fmt, "#{field} field", Store::Severity::Low)
              end
            end
          end
        end

        # Classify one VALUE by its serialized magic, trying the raw form and — for the query /
        # body params that arrive percent-encoded — a decoded form. nil when nothing matches.
        private def classify(raw : String) : String?
          {raw, percent_decode(raw)}.each do |v|
            v = v.lstrip
            next if v.empty?
            return "Java serialized object" if v.starts_with?(JAVA_B64)
            return ".NET BinaryFormatter object" if v.starts_with?(NET_BINFMT)
            return "ASP.NET ViewState (unencrypted)" if VIEWSTATE.matches?(v)
            return "PHP serialized object" if PHP_OBJECT.matches?(v)
            return "Java serialized object" if JAVA_HEX.matches?(v)
          end
          nil
        end

        private def mark(hits : Hash(String, Store::Severity), fmt : String,
                         location : String, sev : Store::Severity) : Nil
          evidence = "#{fmt} in #{location}"
          cur = hits[evidence]?
          hits[evidence] = sev if cur.nil? || sev > cur
        end

        # Split a `name=value; name=value` (cookies) or `name=value&…` (form) list, yielding each
        # trimmed pair. Valueless segments are skipped — a serialized blob is always a value.
        private def each_pair(raw : String, sep : Char, & : String, String ->) : Nil
          raw.split(sep) do |pair|
            eq = pair.index('=') || next
            name = pair[0...eq].strip
            next if name.empty?
            yield name, pair[(eq + 1)..].strip
          end
        end

        # Query pairs from the request target (same shape as SecretInUrl.query_pairs).
        private def query_pairs(target : String) : Array({String, String})
          target = target.scrub
          qi = target.index('?')
          return [] of {String, String} unless qi
          target[(qi + 1)..].split('&').compact_map do |pair|
            next if pair.empty?
            eq = pair.index('=')
            eq ? {pair[0...eq], pair[(eq + 1)..]} : nil
          end
        end

        private def urlencoded_request?(ctx : Context) : Bool
          ct = ctx.req.headers.get?("Content-Type")
          !ct.nil? && ct.downcase.includes?("application/x-www-form-urlencoded")
        end

        # scrub: percent-decoding can RE-introduce invalid UTF-8 (`%80`), which PCRE refuses;
        # a real serialized magic is ASCII, so scrubbing cannot hide a match. `URI.decode` (not
        # decode_www_form) so a base64 `+` is not turned into a space.
        private def percent_decode(s : String) : String
          URI.decode(s).scrub
        rescue
          s
        end

        private def display(name : String) : String
          percent_decode(name)
        end
      end
    end
  end
end
