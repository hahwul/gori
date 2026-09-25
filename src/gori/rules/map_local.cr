require "uri"

module Gori
  module RuleStub
    # Map-local (#1237): a `respond: dir` short-circuit rule serves the file the request path
    # names from a local directory.
    #
    # The request target is the CLIENT's bytes. P7 keeps them verbatim on the wire and in History,
    # but here they would name a LOCAL FILE — a new sink — so the lookup is confined, and every
    # step below exists for that:
    #
    #   1. The path must be origin-form (`/…`), or the rule does not claim the request at all.
    #      The query and fragment are dropped, and `strip_prefix` is compared on the RAW bytes.
    #   2. Every `%` must introduce two hex digits: `URI.decode` passes a malformed escape
    #      through as text rather than refusing it. Then it decodes ONCE — `%252e` stays the
    #      literal name `%2e` — and not as a form, so `+` stays `+`.
    #   3. After decoding, a NUL, a `\` or any segment that STARTS WITH `.` is refused. That
    #      covers `.` and `..` however they were spelled (`%2e%2e`, `..%2f`), and also `.git`
    #      and `.env`: a mapped project directory must not hand its dotfiles to page script.
    #      This runs BEFORE any filesystem call, because `File.realpath` does not check for NUL
    #      and `File.info` raises on one.
    #   4. The candidate's `File.realpath` must sit under the root's. That is what stops a
    #      symlink inside the directory from pointing out of it.
    #
    # A refusal is never a fall-through: the rule claimed the request, so gori answers it (a
    # 404 marked `X-Gori-Short-Circuit: error`). Only a file that is simply ABSENT may fall
    # through, and only when the rule opted in.
    #
    # Out of scope, and documented rather than defended: someone who can WRITE to the mapped
    # directory can already change what it serves, so swapping a path component for a symlink
    # between the realpath and the read gains them nothing they did not have.
    module MapLocal
      enum Outcome
        # A regular file under the root — `path` is its realpath.
        Hit
        # Not there (or a directory without a trailing `/`). The rule's `fallthrough` decides.
        Missing
        # A path the confinement rules refuse — answered 404, never a fall-through.
        Refused
        # The root itself is unusable (gone, or not a directory) — a configuration error,
        # answered 502 and never a fall-through, like a missing `body_file`.
        Broken
        # Not this rule's request: not origin-form, or outside `strip_prefix`.
        NotClaimed
      end

      record Result, outcome : Outcome, path : String = "", rel : String = "", reason : String = ""

      # What a trailing `/` serves. There are no directory listings.
      INDEX = "index.html"

      # A fixed extension table rather than stdlib `MIME`: that one loads the host's
      # `mime.types` lazily — blocking file reads on the proxy fiber — and answers differently
      # from one machine to the next. A lookup, like the stub's reason phrase, so P4 holds; an
      # extension that is not here gets no Content-Type at all rather than a guess.
      CONTENT_TYPES = {
        "html"  => "text/html; charset=utf-8",
        "htm"   => "text/html; charset=utf-8",
        "js"    => "text/javascript; charset=utf-8",
        "mjs"   => "text/javascript; charset=utf-8",
        "css"   => "text/css; charset=utf-8",
        "json"  => "application/json",
        "map"   => "application/json",
        "txt"   => "text/plain; charset=utf-8",
        "xml"   => "application/xml",
        "svg"   => "image/svg+xml",
        "png"   => "image/png",
        "jpg"   => "image/jpeg",
        "jpeg"  => "image/jpeg",
        "gif"   => "image/gif",
        "webp"  => "image/webp",
        "ico"   => "image/x-icon",
        "wasm"  => "application/wasm",
        "woff"  => "font/woff",
        "woff2" => "font/woff2",
      }

      # How much of the served path a flow's provenance carries. It is the client's bytes, so it
      # is also neutralised (`display`).
      REF_PATH_MAX = 64

      # `root` is the directory's REALPATH (see `Rules#dir_root`); `target` the request target.
      # Never raises: whatever goes wrong is an outcome.
      def self.resolve(root : String, strip_prefix : String, target : String) : Result
        rest = claimed_rest(target, strip_prefix)
        return Result.new(Outcome::NotClaimed) unless rest
        rel = confined_rel(rest)
        return rel if rel.is_a?(Result)
        locate(root, rel)
      rescue ex
        refused("the path could not be resolved (#{ex.class.name})")
      end

      # The path after `strip_prefix` (still encoded), or nil when this rule does not claim it:
      # not origin-form, or outside the prefix. Steps 1 of the module doc.
      def self.claimed_rest(target : String, strip_prefix : String) : String?
        path = target.split('?', 2)[0].split('#', 2)[0]
        return nil unless path.starts_with?('/')
        return path[1..] if strip_prefix.empty?
        path.starts_with?(strip_prefix) ? path[strip_prefix.size..] : nil
      end

      # The relative file path the encoded remainder names, or the refusal — steps 2 and 3,
      # before anything touches the filesystem.
      private def self.confined_rel(rest : String) : String | Result
        return refused("malformed percent-encoding") unless percent_encoding_ok?(rest)
        decoded = URI.decode(rest)
        return refused("the path is not UTF-8") unless decoded.valid_encoding?
        return refused("the path carries a NUL or a backslash") if decoded.includes?('\0') || decoded.includes?('\\')
        segments = decoded.split('/').reject(&.empty?)
        return refused("the path names a dot segment or a dotfile") if segments.any?(&.starts_with?('.'))
        segments << INDEX if segments.empty? || decoded.ends_with?('/')
        segments.join('/')
      end

      # Step 4: the file under `root`, if there is one and it stays there.
      private def self.locate(root : String, rel : String) : Result
        candidate = File.join(root, rel)
        info = File.info?(candidate)
        unless info && info.file?
          # No local path in either sentence: it becomes the body of gori's own answer, which the
          # page under test can read, and the operator's home directory is not the target's
          # business. The rule names the directory already.
          return Result.new(Outcome::Broken, rel: rel, reason: "the mapped directory is gone or not a directory") unless File.directory?(root)
          return Result.new(Outcome::Missing, rel: rel, reason: "no file for #{rel} in the mapped directory")
        end
        real = File.realpath(candidate)
        base = root.ends_with?('/') ? root : "#{root}/"
        return refused("the path resolves outside the mapped directory", rel) unless real.starts_with?(base)
        Result.new(Outcome::Hit, path: real, rel: rel)
      end

      # The Content-Type for a served file, or nil when the extension is not in the table.
      def self.content_type(path : String) : String?
        ext = File.extname(path).lchop('.').downcase
        ext.empty? ? nil : CONTENT_TYPES[ext]?
      end

      # A served path as a flow's provenance can show it: control characters neutralised (the
      # terminal renders this) and clipped.
      def self.display(rel : String) : String
        s = rel.scrub
        s = String.build { |io| s.each_char { |c| io << (c.control? ? '·' : c) } } if s.each_char.any?(&.control?)
        s.size > REF_PATH_MAX ? "#{s[0, REF_PATH_MAX - 1]}…" : s
      end

      private def self.refused(reason : String, rel : String = "") : Result
        Result.new(Outcome::Refused, rel: rel, reason: reason)
      end

      private def self.percent_encoding_ok?(s : String) : Bool
        bytes = s.to_slice
        i = 0
        while i < bytes.size
          if bytes[i] == '%'.ord
            return false unless i + 2 < bytes.size && hex?(bytes[i + 1]) && hex?(bytes[i + 2])
            i += 3
          else
            i += 1
          end
        end
        true
      end

      private def self.hex?(b : UInt8) : Bool
        b.unsafe_chr.hex?
      end
    end
  end
end
