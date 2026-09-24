require "http/status"
require "../proxy/head_rewriter"
require "../store/models"

module Gori
  # The canned response half of a short-circuit rule (#511).
  #
  # A `ShortCircuit` rule carries its response in the same `replacement` field the other ops
  # use, authored as a raw HTTP response:
  #
  #     200 OK
  #     Content-Type: application/json
  #
  #     {"isAdmin": true}
  #
  # The first line is the status line (`200`, `200 OK` and `HTTP/1.1 200 OK` are all accepted;
  # the reason defaults to the registered phrase). Lines up to the first blank line are
  # headers. Everything after it is the inline body, kept byte-for-byte as typed — a stub is
  # the operator's bytes, so nothing is normalised into it (P7). When the rule names a
  # `body_file`, that file's bytes are the body instead and the inline body is ignored; that
  # is what makes a large or binary stub practical.
  #
  # `Content-Length` and `Transfer-Encoding` are DROPPED here, never trusted: ClientConn
  # re-derives the framing from the bytes it actually sends. A stub that declares a length it
  # doesn't have would desync the next request on a keep-alive connection.
  module RuleStub
    # Ceiling on a `body_file`. A stub body is held whole in memory (it has to be — the length
    # has to be known before the head is written), and this is a proxy hot path, so a rule
    # pointed at a multi-GiB file must fail loudly rather than take the process down.
    MAX_BODY_FILE_BYTES = 8_i64 * 1024 * 1024

    # How many distinct files stay cached. A `body_file` rule set is tiny, but a `respond: dir`
    # rule (#1237) serves a whole directory — a page's worth of scripts and styles — so the
    # count is sized for that, and `MAX_CACHED_BYTES` is what actually bounds the memory.
    MAX_CACHED_FILES = 256

    # Total bytes the cache may hold. Each file is already capped at `MAX_BODY_FILE_BYTES`; this
    # keeps 256 of them from adding up to 2 GiB.
    MAX_CACHED_BYTES = 64_i64 * 1024 * 1024

    # A parsed stub head: the wire bytes plus the status, which ClientConn needs in order to
    # decide whether the response may carry a body at all.
    record Head, bytes : Bytes, status : Int32

    # Parse the authored head of a stub. Returns nil when it cannot be parsed — an empty or
    # non-numeric status line, or a header line with no colon. Shared by the live proxy path
    # and by every surface's validity check, so a rule that would fail at request time cannot
    # be saved in the first place.
    def self.parse_head(text : String) : Head?
      head_text, _ = split(text)
      lines = head_text.split('\n').map(&.chomp('\r'))
      first = lines.shift?
      return nil unless first
      parsed = status_line(first)
      return nil unless parsed
      status, reason = parsed
      io = IO::Memory.new(head_text.bytesize + 32)
      io << "HTTP/1.1 " << status
      io << ' ' << reason unless reason.empty?
      io << "\r\n"
      lines.each do |line|
        next if line.blank?
        colon = line.index(':')
        return nil unless colon && colon > 0
        name = line[0, colon].strip
        return nil if name.empty?
        # Framing is ClientConn's to derive from the bytes actually sent — see the module
        # docs. Silently dropped rather than rejected, because a stub pasted from a real
        # response will carry them and refusing that would be hostile for no gain.
        next if name.compare("content-length", case_insensitive: true) == 0 ||
                name.compare("transfer-encoding", case_insensitive: true) == 0
        io << name << ": " << line[(colon + 1)..].strip << "\r\n"
      end
      Head.new(io.to_slice, status)
    end

    # Whether a parsed head (`Head#bytes`) carries a header `name` (case-insensitive).
    def self.header?(head : Bytes, name : String) : Bool
      String.new(head).each_line.skip(1).any? do |line|
        colon = line.index(':')
        colon && line[0, colon].strip.compare(name, case_insensitive: true) == 0
      end
    end

    # The inline body — everything after the first blank line, verbatim. Empty when the stub
    # is head-only.
    def self.inline_body(text : String) : Bytes
      _, body = split(text)
      body.to_slice
    end

    # Whether a stub could be honoured as authored. A `body_file` is deliberately NOT checked
    # here: it is read at request time, so an exists-at-save-time test would only be a guess
    # about the future — and a stub file that is written later is a normal way to work.
    def self.valid?(text : String) : Bool
      !parse_head(text).nil?
    end

    # Why a short-circuit rule's answer could not be honoured as authored, or nil when it can —
    # the ONE validator for the #1237 sub-kinds, which `gori run rewriter`, MCP
    # `create_rule`/`update_rule` and the TUI editor's Save row all call, so a rule that would
    # only fail at request time cannot be saved. Like `valid?`, it checks the SHAPE and never
    # the filesystem: a stub file or a mapped directory that appears later is a normal way to
    # work, and the proxy fails closed when it is still missing.
    def self.respond_error(respond : Store::RespondKind, replacement : String, body_file : String,
                           respond_args : String) : String?
      args = Store::RespondArgs.parse(respond_args)
      return args if args.is_a?(String)
      unless respond.dir?
        return "strip prefix is only for a dir rule" unless args.strip_prefix.empty?
        return "fall-through is only for a dir rule" if args.fallthrough?
      end
      return "a fault kind is only for a fault rule" if args.fault && !respond.fault?
      if args.hang_ms != Store::RespondArgs::DEFAULT_HANG_MS && args.fault != Store::FaultKind::Hang
        return "a hang bound is only for a hang fault"
      end
      case respond
      in .inline?
        return "write a stub response" unless valid?(replacement)
        return "an inline stub takes no body file (use the file source)" unless body_file.empty?
      in .file?
        return "write a stub response head" unless valid?(replacement)
        return "name the body file" if body_file.empty?
      in .dir?
        return "name the directory to serve" if body_file.empty?
        unless replacement.strip.empty?
          return "the response head template does not parse" unless valid?(replacement)
          return "a dir rule's body comes from the directory — keep the template head-only" unless inline_body(replacement).empty?
        end
        prefix = args.strip_prefix
        unless prefix.empty? || (prefix.starts_with?('/') && prefix.ends_with?('/'))
          return "strip prefix must start and end with / (e.g. /static/)"
        end
      in .fault?
        return "pick a fault: close, reset or hang" unless args.fault
        return "a fault answers nothing — leave the response empty" unless replacement.strip.empty?
        return "a fault takes no body file" unless body_file.empty?
      end
      nil
    end

    # A one-line summary of a stub for a list row ("200 OK · 42B" / "404 · file:…").
    def self.summary(text : String, body_file : String) : String
      head = parse_head(text)
      return "(unparseable stub response)" unless head
      status_line = String.new(head.bytes).lines.first?.try(&.lchop("HTTP/1.1 ").strip) || ""
      body = body_file.empty? ? "#{inline_body(text).size}B inline" : "file:#{body_file}"
      "#{status_line} · #{body}"
    end

    # The same summary, knowing the sub-kind (#1237): `dir:~/work/js (fallthrough)`,
    # `fault:reset +500ms`, or the stub summary above — each with its delay, when it has one.
    def self.summary(rule : Store::MatchRule) : String
      return "(#{rule.inert_reason})" if rule.op.short_circuit? && rule.inert?
      args = rule.args
      out =
        case rule.respond
        in .inline?, .file?
          summary(rule.replacement, rule.body_file)
        in .dir?
          prefix = args.strip_prefix.empty? ? "" : "#{args.strip_prefix} → "
          "#{prefix}dir:#{rule.body_file}#{args.fallthrough? ? " (fallthrough)" : ""}"
        in .fault?
          kind = args.fault.try(&.label) || "?"
          hang = args.fault.try(&.hang?) ? " ≤#{args.hang_ms}ms" : ""
          "fault:#{kind}#{hang}"
        end
      args.delay_ms > 0 ? "#{out} +#{args.delay_ms}ms" : out
    end

    # Split the authored text into {head, inline body} on the FIRST blank line, in either
    # spelling. Without one, the whole text is the head and the body is empty (a head-only
    # stub).
    #
    # The earliest of the two wins; preferring `\r\n\r\n` wherever it appears made the stub's
    # own BODY able to move the boundary. A stub authored in the TUI is LF-joined
    # (`TextArea#text`), so a body carrying a CRLFCRLF of its own — a captured message, a
    # multipart part, a raw mail — put the CRLF hit AFTER the real separator and swallowed the
    # first body lines into the head. The operator then saw "unparseable stub response" (a
    # body line has no colon) or, worse, a body line that happened to look like a header
    # silently became one.
    private def self.split(text : String) : {String, String}
      crlf = text.index("\r\n\r\n")
      lf = text.index("\n\n")
      if crlf && (lf.nil? || crlf < lf)
        {text[0, crlf], text[(crlf + 4)..]}
      elsif lf
        {text[0, lf], text[(lf + 2)..]}
      else
        {text, ""}
      end
    end

    # `{status, reason}` from a status line. Accepts a bare code, a code + reason, or a full
    # `HTTP/1.1 <code> <reason>` (which is what pasting a captured response gives you). An
    # absent reason falls back to the registered phrase — a lookup, not an inference about
    # intent, so P4 holds.
    private def self.status_line(line : String) : {Int32, String}?
      rest = line.strip
      rest = rest.split(' ', 2)[1]? || "" if rest.starts_with?("HTTP/")
      code_s, _, reason = rest.partition(' ')
      code = code_s.to_i?
      return nil unless code && 100 <= code <= 599
      reason = reason.strip
      reason = HTTP::Status.new(code).description || "" if reason.empty?
      {code, reason}
    end
  end

  # Caches `body_file` contents so a stub does not re-read the file on every request, while
  # still letting the operator edit that file and see the change on the next request — which
  # is most of why a file source is worth having.
  #
  # Validation is a `File.info` (one stat) per request compared against the cached mtime AND
  # size: mtime alone misses an edit that lands inside the filesystem's timestamp granularity,
  # and size alone misses a same-length edit. A stat per short-circuited request is nothing
  # next to the read it replaces.
  class RuleStubBodyCache
    record Entry, mtime : Time, size : Int64, bytes : Bytes

    MAX_ENTRIES = RuleStub::MAX_CACHED_FILES
    MAX_BYTES   = RuleStub::MAX_CACHED_BYTES

    def initialize
      @mutex = Mutex.new
      @entries = {} of String => Entry
      @bytes = 0_i64
    end

    # The file's bytes. Raises `Gori::Error` when the path is unreadable, is not a regular
    # file, or exceeds `RuleStub::MAX_BODY_FILE_BYTES` — the caller turns that into a recorded
    # failure rather than a fall-through to the origin.
    def read(path : String) : Bytes
      info = begin
        File.info(path)
      rescue ex : File::Error
        raise Gori::Error.new("stub body file unreadable: #{path} (#{ex.message})")
      end
      raise Gori::Error.new("stub body file is not a regular file: #{path}") unless info.file?
      size = info.size
      if size > RuleStub::MAX_BODY_FILE_BYTES
        raise Gori::Error.new("stub body file too large: #{path} (#{size} bytes > #{RuleStub::MAX_BODY_FILE_BYTES})")
      end
      mtime = info.modification_time
      @mutex.synchronize do
        if (hit = @entries[path]?) && hit.mtime == mtime && hit.size == size
          return hit.bytes
        end
      end
      bytes = load(path, size.to_i32)
      @mutex.synchronize do
        if (old = @entries[path]?)
          @bytes -= old.bytes.size
        elsif @entries.size >= MAX_ENTRIES || @bytes + bytes.size > MAX_BYTES
          # No LRU, on purpose: the set a page re-requests refills in one load, and a clear is
          # the one policy that cannot be wrong about which entry was stale.
          @entries.clear
          @bytes = 0_i64
        end
        @entries[path] = Entry.new(mtime, size, bytes)
        @bytes += bytes.size
      end
      bytes
    end

    def clear : Nil
      @mutex.synchronize do
        @entries.clear
        @bytes = 0_i64
      end
    end

    # Read up to `size` bytes. A file that shrank between the stat and the read yields a short
    # read; the slice is trimmed rather than padded with NULs, so the body is always bytes
    # that were really in the file.
    private def load(path : String, size : Int32) : Bytes
      buf = Bytes.new(size)
      read = 0
      File.open(path) do |f|
        while read < buf.size
          n = f.read(buf[read..])
          break if n == 0
          read += n
        end
      end
      read == buf.size ? buf : buf[0, read].dup
    rescue ex : File::Error | IO::Error
      raise Gori::Error.new("stub body file unreadable: #{path} (#{ex.message})")
    end
  end
end
