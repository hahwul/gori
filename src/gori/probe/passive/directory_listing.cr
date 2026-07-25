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

        # Allocation-free prefilter: both markers below require this literal, and an ordinary HTML
        # page never carries it, so the regex passes are skipped for essentially all traffic.
        # Case-sensitive on purpose — both servers emit exactly this casing.
        NEEDLE = "Index of /"

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
          return if text.nil? || !text.includes?(NEEDLE)
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
