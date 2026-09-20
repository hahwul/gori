require "uri"
require "./rule"

module Gori
  module Probe
    module Passive
      # A framework session identifier carried in the request URL (category "infoleak"). Unlike a
      # generic `session`/`sid` param (which `secret_in_url` owns), these are the EXACT cookie
      # names a specific stack issues — PHPSESSID, JSESSIONID, ASP.NET_SessionId, … — so their
      # presence in a query string is a strong session-in-URL / session-fixation signal: the live
      # session token leaks through logs, browser history, and the Referer header, and a link that
      # sets it can fix a victim's session.
      #
      # A whitelist of well-known names only (not an entropy/shape heuristic), so this stays
      # essentially FP-free and DISJOINT from `secret_in_url` (which owns the generic
      # token/JWT/credential and session/sid names). Names compare case-insensitively; the value
      # is NEVER recorded.
      class SessionIdInUrl < Rule
        def info : RuleInfo
          RuleInfo.new("session_id_in_url", "Session identifier in URL",
            "Flags a known framework session identifier (PHPSESSID, JSESSIONID, ASP.NET_SessionId, …) " \
            "carried in the request URL, where it leaks via logs, history, and Referer.",
            Category::INFOLEAK)
        end

        # Exact framework session-cookie names (lower-cased). Kept disjoint from secret_in_url's
        # generic session/sessionid/sid set so the two rules never double-report one parameter.
        # ASPSESSIONID carries a random suffix (ASPSESSIONIDSCASBQTC), matched by prefix below.
        SESSION_NAMES = Set{"phpsessid", "jsessionid", "asp.net_sessionid", ".aspxauth", "aspxauth",
                            "cfid", "cftoken", "connect.sid", "laravel_session", "ci_session"}

        def check(ctx : Context, acc : Array(Detection)) : Nil
          target = ctx.req.target
          # '?' (0x3f) is always a standalone byte in UTF-8, so a query-less URL early-outs here
          # without the full-URL scrub (this rule runs on every flow).
          return unless target.to_slice.index(0x3f_u8)
          scrubbed = target.scrub
          qi = scrubbed.index('?')
          return unless qi
          query = scrubbed[(qi + 1)..]
          return if query.empty?
          query.split('&').each do |pair|
            next if pair.empty?
            eq = pair.index('=')
            raw = eq ? pair[0...eq] : pair
            next if raw.empty?
            name = decode(raw).downcase
            next unless session_name?(name)
            acc << Detection.new("session_id_in_url", Category::INFOLEAK, ctx.host, ctx.url,
              "Session identifier in URL", Store::Severity::Medium, name, ctx.fid)
            return # one per flow is enough
          end
        end

        private def session_name?(name : String) : Bool
          SESSION_NAMES.includes?(name) || name.starts_with?("aspsessionid")
        end

        private def decode(name : String) : String
          URI.decode_www_form(name).scrub
        rescue
          name
        end
      end
    end
  end
end
