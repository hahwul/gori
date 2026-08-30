require "./rule"

module Gori
  module Probe
    module Passive
      # An auto-generated directory index (category "infoleak"): the server, with no index file
      # to serve, listed the directory instead. That hands over a free file enumeration — backups
      # (`db.sql.gz`, `.env.bak`), editor leftovers, old releases, upload directories — the exact
      # inventory a tester would otherwise have to brute-force for.
      #
      # Anchored on the autoindex TITLE (`<title>Index of /…</title>`, which both Apache's
      # mod_autoindex and nginx's autoindex emit) AND a second structural marker from the same
      # page: the matching `<h1>`, Apache's "Parent Directory" link, or nginx's `<a href="../">`.
      # Requiring two markers keeps a page that merely SAYS "index of" in prose (a docs page, a
      # blog post, a search UI) out — the title alone was the only real FP risk here.
      class DirectoryListing < Rule
        def info : RuleInfo
          RuleInfo.new("directory_listing", "Directory listing",
            "Detects an Apache/nginx auto-generated directory index, which enumerates files for anyone who asks.",
            Category::INFOLEAK)
        end

        # Prefilter: both markers below require this literal, and an ordinary HTML page never
        # carries it, so the structural regex passes are skipped for essentially all traffic.
        # Case-sensitive on purpose — both servers emit exactly this casing.
        #
        # A REGEX, not a `String` tested with `includes?` — the point is scan SPEED, not
        # allocation. This gate runs on the body of every 2xx HTML response, and
        # `String#includes?` is a naive byte search where PCRE2 memchrs a plain literal
        # (~79µs vs ~19µs over a 64 KiB page). Same fix as the `includes?` prefilters removed
        # from `debug_mode_exposed` / `sourcemap` / `serialized_object` / `exposed_config`.
        # (`AsciiBytes` remains the right tool only for a SHORT or possibly-invalid-UTF-8
        # subject, where PCRE2 would raise; a scrubbed body text is neither.)
        NEEDLE = /Index of \//

        TITLE = /<title>\s*Index of \/[^<]*<\/title>/i
        # Second marker, any one of: the autoindex heading, Apache's parent link text, or the
        # `../` anchor nginx opens its <pre> block with.
        STRUCTURE = [
          /<h1>\s*Index of \//i,
          /Parent Directory/i,
          /<a href="\.\.\/?">/i,
        ]

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return unless resp = ctx.response
          return unless ctx.html?
          # Only a served listing counts; a 403/404 error page can carry the same words.
          return unless (200..299).includes?(resp.status)
          text = ctx.body_text
          return if text.nil? || !NEEDLE.matches?(text)
          return unless TITLE.matches?(text)
          return unless STRUCTURE.any?(&.matches?(text))
          acc << Detection.new("directory_listing", Category::INFOLEAK, ctx.host, ctx.url,
            "Directory listing enabled (auto-generated index)", Store::Severity::Low,
            "autoindex page", ctx.fid)
        end
      end
    end
  end
end
