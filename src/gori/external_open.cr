require "file_utils"
require "./media_type"
require "./paths"
require "./proxy/codec/content_decode"

module Gori
  # Hands a captured RESPONSE BODY to the desktop — the terminal's way out of not having a
  # renderer. The operator picks a flow and gets the real thing in a real viewer: an HTML page
  # laid out, a PNG on screen, a PDF paginated, a 4 MB JSON in something that can fold it.
  #
  # Burp ships this ("Show response in browser") from inside a GUI that ALREADY renders; a
  # terminal proxy needs it more, not less, and gori had no path to it at all — `browser.cr`
  # launches a proxied browser to GENERATE traffic, which is the opposite direction.
  #
  # Split like `ExternalEditor`: everything here is pure (decode, name, write, prune) and the
  # spawn lives in the Runner, which owns the terminal. Nothing in this module runs a process.
  #
  # ## What it writes, and what it deliberately does not
  #
  # The DECODED body (P7's display rule — `ContentDecode`), because a `file://` URL carries no
  # `Content-Encoding` and a browser handed gzip bytes shows garbage. The body ALONE: headers
  # are already on screen in the pane the operator invoked this from, and "render" means the
  # document, not the exchange.
  #
  # No `<base href>` injection. It would make an HTML page's relative `<script>`/`<link>`
  # resolve to the live origin — a nicer render, bought with requests to the target that the
  # operator did not ask for and cannot see (P4). So a page whose assets are relative renders
  # unstyled, and that is the honest trade: this shows you what the RESPONSE said, not what the
  # site looks like. Point the proxied browser at the URL when you want the latter.
  #
  # ## The extension is ours, never the target's
  #
  # The suffix comes from a fixed allowlist keyed on the response's own media type, and an
  # unrecognised type falls to `.txt`/`.bin`. The file NAME is built from the flow id and a
  # timestamp. No byte of either comes from the response, so a hostile `Content-Type` (or a
  # filename in a `Content-Disposition` this module never reads) cannot pick the extension the
  # desktop will dispatch on.
  #
  # Opening a target's HTML in a browser runs the target's JavaScript, from a `file://` origin
  # that cannot reach the target's cookies. That is the same bargain Burp's version makes and
  # it is the operator's to make — the verb is explicit, and the status line says the page is
  # live. gori does not strip scripts: a neutered render is a different document from the one
  # under test, which is the whole thing this is for.
  module ExternalOpen
    # Where previews land: gori-owned, 0700 (`Paths.ensure_dir`), and swept by `prune`. Under
    # GORI_HOME rather than the system temp dir so the files are findable when a viewer wants
    # a path typed at it, and so a wipe of GORI_HOME takes them with it.
    def self.dir : String
      File.join(Paths.home_dir, "preview")
    end

    # How many preview files to keep. A sweep runs on every write, so the directory is bounded
    # by USE rather than by a cleanup nobody remembers to run. Generous enough that the file
    # from ten flows ago is still openable from a viewer's recent list.
    KEEP = 32

    # Cap on what is written out. `ContentDecode`'s own bomb ceiling already bounds the inflate;
    # this bounds the WRITE, so a legitimately huge body cannot fill a home directory because
    # someone pressed a key. A truncated preview still renders — HTML and JSON both degrade
    # readably — and `Result#truncated` lets the caller say so.
    #
    # Equal to `ContentDecode::MAX_OUT` on purpose (this is the same ceiling seen from the
    # other side), which used to make `truncated` unreachable for a compressed body: the
    # inflate stopped AT the ceiling and `size > MAX_BYTES` was then false by one byte. The
    # native decoders now stop one buffer PAST their cap (see `Brotli.decode_full`), so a body
    # that really had more to give lands above this and is reported as cut.
    MAX_BYTES = 32 * 1024 * 1024

    # What the caller shows and what the Runner spawns against.
    #
    # `truncated` is "this file is NOT the whole document", from any of the three ways that
    # happens: the capture cap cut the stored body before it reached us (`body_truncated`, the
    # default 2 MiB `DEFAULT_CAPTURE_MAX_MIB` makes this the ordinary case, not an edge one),
    # the decompressor never reached end-of-stream, or `MAX_BYTES` cut the write. All three
    # produce a partial file that renders, so all three are one flag — the caller says
    # "(truncated)" and the operator knows not to read the tail as the document's end.
    record Result, path : String, media : String?, bytes : Int32, truncated : Bool

    # Media type → suffix. An ALLOWLIST: a type absent here never picks its own extension.
    #
    # Keyed on `MediaType.essence` (folded, parameters dropped), plus the structured-suffix
    # fallbacks below for the `+json` / `+xml` families, which is how a vendor type
    # (`application/vnd.api+json`) still opens as what it is.
    SUFFIXES = {
      "text/html"                         => ".html",
      "application/xhtml+xml"             => ".xhtml",
      "text/plain"                        => ".txt",
      "text/css"                          => ".css",
      "text/csv"                          => ".csv",
      "text/markdown"                     => ".md",
      "text/javascript"                   => ".js",
      "application/javascript"            => ".js",
      "application/x-javascript"          => ".js",
      "application/json"                  => ".json",
      "application/manifest+json"         => ".json",
      "text/xml"                          => ".xml",
      "application/xml"                   => ".xml",
      "image/png"                         => ".png",
      "image/jpeg"                        => ".jpg",
      "image/gif"                         => ".gif",
      "image/webp"                        => ".webp",
      "image/avif"                        => ".avif",
      "image/bmp"                         => ".bmp",
      "image/svg+xml"                     => ".svg",
      "image/x-icon"                      => ".ico",
      "image/vnd.microsoft.icon"          => ".ico",
      "application/pdf"                   => ".pdf",
      "application/zip"                   => ".zip",
      "application/wasm"                  => ".wasm",
      "font/woff2"                        => ".woff2",
      "audio/mpeg"                        => ".mp3",
      "video/mp4"                         => ".mp4",
      "application/x-www-form-urlencoded" => ".txt",
    }

    # The suffix for a response head. `body` decides only the LAST resort, where there is no
    # usable media type at all: text-shaped bytes open as `.txt` (a viewer will show them),
    # anything else as `.bin` (a viewer will not pretend to).
    #
    # Hand it the body that will actually be WRITTEN — the decoded one. Judging the shape of
    # the still-compressed wire bytes answers the wrong question: a gzip stream's header holds
    # NULs, so a perfectly readable inflated document with no (or an unknown) `Content-Type`
    # scored as binary and opened as `.bin`, which most desktop openers decline to render.
    def self.suffix_for(head : Bytes?, body : Bytes?) : String
      if e = MediaType.essence_of(head)
        if s = SUFFIXES[e]?
          return s
        end
        # The `+suffix` families, checked AFTER the exact table so `image/svg+xml` keeps `.svg`
        # rather than collapsing to `.xml`.
        return ".json" if e.ends_with?("+json")
        return ".xml" if e.ends_with?("+xml")
        return ".txt" if e.starts_with?("text/")
      end
      text_shaped?(body) ? ".txt" : ".bin"
    end

    # Write `body` (decoded against `head`) into the preview dir and return where it went.
    # `stem` names the source — "flow-1234", "repeater-7" — and is the caller's to build from
    # ids, never from captured bytes.
    #
    # `body_truncated` is the SOURCE's own verdict — `FlowDetail#response_body_truncated?` for
    # a stored flow — and it is not an exotic case: with `DEFAULT_CAPTURE_MAX_MIB` at 2, every
    # response over 2 MiB is stored cut. Every other surface reads that flag (`gori history`
    # prints `[response body truncated]`, the MCP serializer and the HAR export both carry
    # it); this one had no way to be told, so it wrote a partial document and said "opened".
    #
    # Raises `Gori::Error` when there is nothing to show or the write fails; the caller turns
    # that into a status line. Never partially succeeds: the sweep runs after the write, so a
    # failed write cannot take older previews with it.
    #
    # Refuses rather than writing when a declared coding did not come off. `ContentDecode`
    # returns the still-COMPRESSED entity in that case (that is its display contract — the
    # note beside it says what happened), so the old `decoded || body` handed the deflate
    # stream straight to `File.write`, named it `.html` from the response's `Content-Type`,
    # and reported a successful open of a file no viewer can render. The note is the honest
    # message and it is exactly what History renders one key away, so it IS the refusal.
    def self.write(stem : String, head : Bytes?, body : Bytes?, body_truncated : Bool = false) : Result
      raise Gori::Error.new("no response body to open") if body.nil? || body.empty?
      decoded, note, complete = Proxy::Codec::ContentDecode.decode_full(head, body)
      raise Gori::Error.new(note || "the response body could not be decoded") if Proxy::Codec::ContentDecode.decode_failed?(note)
      bytes = decoded || body
      # AFTER the decode, not only before it. The entry guard above tests the stored bytes;
      # a body that decodes to nothing (a stream cut before its first output byte) still got
      # past it, and a 0-byte file was written and announced as an open document.
      raise Gori::Error.new("the response body decodes to nothing to show") if bytes.empty?
      cut = bytes.size > MAX_BYTES
      bytes = bytes[0, MAX_BYTES] if cut
      # Three sources, one flag — see `Result`. `complete` is `decode_full`'s end-of-stream
      # report, which the previous `decode` call discarded along with the note.
      truncated = cut || !complete || body_truncated
      root = dir
      # `ensure_dir` inside the rescue as much as the write: it converts only the
      # occupied-path case to `Gori::Error` itself, so a read-only or full GORI_HOME raised
      # `File::AccessDeniedError` straight through the verb dispatch — past a caller whose
      # contract is that every refusal is a status line.
      path = ""
      begin
        Paths.ensure_dir(root)
        # `bytes`, not `body` — the decoded slice is what lands in the file, so it is what
        # the last-resort text/binary test has to read. See `suffix_for`.
        path = File.join(root, "#{sanitize_stem(stem)}-#{stamp}#{suffix_for(head, bytes)}")
        # 0600, like every other file gori writes that holds captured data (the store, the
        # settings file, the project registry, the CA key). A preview holds a WHOLE response
        # body — session tokens, PII, whatever the target returned — it lives under GORI_HOME
        # rather than in a project directory, and deleting the project does not take it with
        # it. The 0700 dir is not the whole guard: these outlive the session that made them.
        File.write(path, bytes, perm: File::Permissions.new(0o600))
      rescue ex : Gori::Error
        raise ex # already phrased for an operator (the occupied-path case)
      rescue ex
        raise Gori::Error.new("could not write the preview file: #{ex.message}")
      end
      prune(root)
      Result.new(path, MediaType.essence_of(head), bytes.size, truncated)
    end

    # Will a browser RUN code out of this document? The status line says so when it will,
    # because the verb is one keystroke and the bytes are the target's.
    #
    # Keyed on the suffix that was actually written (not on the media type), since the suffix
    # is what the desktop dispatches on and therefore what decides whether a script engine is
    # involved at all. SVG is in the list on purpose: it is an XML image that carries
    # `<script>`, and a browser handed one as a top-level document executes it.
    def self.executes?(result : Result) : Bool
      case File.extname(result.path)
      when ".html", ".xhtml", ".svg" then true
      else                                false
      end
    end

    # {program, args} for handing a path to the desktop. nil where there is no opener to call,
    # which is every platform but macOS and Linux today — the caller then says so rather than
    # spawning something that does not exist.
    #
    # `xdg-open` is not assumed to be installed: a bare Linux box or a minimal container has
    # none, and `Process.run` would raise `File::NotFoundError` from inside the spawn. The
    # caller checks; this only names the command.
    def self.opener(path : String) : {String, Array(String)}?
      {% if flag?(:darwin) %}
        {"open", [path]}
      {% elsif flag?(:linux) %}
        {"xdg-open", [path]}
      {% else %}
        nil
      {% end %}
    end

    # Keep the newest `KEEP` entries and delete the rest. Best-effort by design: a preview that
    # will not delete (a viewer holding it open on a platform that locks) must not fail the
    # write that triggered the sweep — the operator asked to SEE something, not to tidy up.
    #
    # Every entry, not only the regular files. gori writes files, but the DESKTOP writes back:
    # hand macOS a `.zip` preview and `open` passes it to Archive Utility, which unpacks the
    # tree beside it, IN here. A `File.file?` filter dropped those directories out of the sweep
    # entirely, so they were never counted against `keep` and never deleted — a dir per archive
    # preview, accumulating under GORI_HOME forever, while the doc promises a bounded sweep.
    def self.prune(root : String, keep : Int32 = KEEP) : Nil
      entries = Dir.children(root).compact_map do |name|
        p = File.join(root, name)
        # `follow_symlinks: false`: a dangling link raises under a following stat and would
        # drop out of the sweep the same way a directory did, permanently.
        {p, File.info(p, follow_symlinks: false).modification_time}
      rescue
        nil
      end
      return if entries.size <= keep
      entries.sort_by! { |(_, mtime)| mtime }
      entries[0, entries.size - keep].each { |(p, _)| delete_entry(p) }
    rescue
      # An unreadable preview dir is not a reason to lose the preview just written.
    end

    # Delete one swept entry, whatever it is. The directory case is a tree (an unpacked
    # archive), so it needs `rm_rf` — decided on the LINK's own type, never a followed one, so
    # a symlink that happens to point at a directory has the link removed rather than its
    # target's contents.
    private def self.delete_entry(path : String) : Nil
      if File.info(path, follow_symlinks: false).directory?
        FileUtils.rm_rf(path)
      else
        File.delete(path)
      end
    rescue
      # Best-effort, as above.
    end

    # Does the body look like text a viewer should try to render? Deliberately crude and
    # deliberately CONSERVATIVE about the answer it gives for free: a NUL in the first block
    # is the one signal that is never a false positive on real text, and everything else is
    # left to open as `.bin`. This decides an extension, not an encoding.
    private def self.text_shaped?(body : Bytes?) : Bool
      return false unless body && !body.empty?
      body[0, {body.size, 1024}.min].none?(&.zero?)
    end

    # Belt-and-braces on a stem the caller builds from ids. Every production caller already
    # passes `[a-z]+-[0-9]+`; this makes a future one that forgets unable to write a path
    # separator, a `..`, or a leading dot into the name.
    private def self.sanitize_stem(stem : String) : String
      # The class already excludes `.` and `/`, so a leading dot or a `..` cannot survive it —
      # the substitution is the whole guard, not a first pass over one.
      cleaned = stem.gsub(/[^A-Za-z0-9_-]/, "_")
      cleaned.empty? ? "preview" : cleaned[0, 64]
    end

    # Monotonic tiebreaker for `stamp`. A wall clock at millisecond resolution is NOT enough
    # on its own: two writes inside one millisecond produce the same name, and the second
    # overwrites the first — which is precisely the stale-render failure the timestamp is
    # there to prevent (open a repeater response, re-send, open again, and the viewer is
    # handed a path it may still have cached). Rare from a keyboard, certain from a script or
    # a spec, and a counter costs nothing.
    @@seq = Atomic(UInt32).new(0_u32)

    # Sortable, unique within a process, and readable in a file listing.
    private def self.stamp : String
      n = @@seq.add(1_u32)
      "#{Time.utc.to_s("%Y%m%d-%H%M%S-%L")}-#{n}"
    end
  end
end
