require "./paths"
require "./durable_file"
require "./tty_path"
require "./embedded_list"

module Gori
  # The global wordlist catalog (#1353): named lists that live as plain files under
  # `Paths.wordlists_dir`, so a list saved once is selected BY NAME from the Fuzzer, the Miner,
  # Discover and Cookie cracking, on every surface, from any working directory.
  #
  # The contents stay FILES. Not settings.json and not a project database: a file keeps the
  # global-versus-project boundary (a project never silently inherits another's list — a global
  # name is something the operator typed), reads lazily (`Fuzz::WordlistFile` walks a multi-GB
  # list without materializing it), and is what an operator already drops in that directory by
  # hand. So this module is a NAMING and PLACEMENT layer over the directory and nothing more:
  #
  #   * `resolve` turns whatever a surface was handed (`common.txt`, `./common.txt`, an absolute
  #     path) into the path to open. It is the ONE place that rule lives; every consumer's
  #     loader calls it instead of re-deriving "cwd, then the global directory".
  #   * `list` / `info` / `preview` answer questions about the catalog from `stat` and BOUNDED
  #     reads, never a whole-file scan — a listing runs on the TUI's frame and on MCP's request
  #     path, and a multi-GB list must not cost either one a stall.
  #   * `save_*` / `rename` / `delete` are the only writers: atomic, owner-only, and they refuse
  #     an accidental overwrite (the refusal is decided on the directory entry itself, not on a
  #     check that a concurrent writer could beat).
  #
  # What it deliberately does NOT do is touch a list's bytes. A blank line or a line starting
  # with `#` is a legitimate Fuzzer payload (`Fuzz::WordlistFile` reads every line), while the
  # Miner and Discover read the same two shapes as file formatting (`load`, which only those
  # two call). Both are right for their tool, so the file is the raw source and each consumer
  # keeps its own documented line semantics — normalizing in `resolve` would decide one tool's
  # answer for all of them.
  module WordlistCatalog
    extend self

    # Why a catalog operation was refused. The message is written HERE, once, so a name reads
    # the same on the CLI, on MCP and in the TUI; a surface that needs a machine-readable answer
    # (an MCP error code, a toast colour) reads `reason`.
    class Error < Gori::Error
      enum Reason
        # The name does not fit the catalog's format (see `valid_name?`).
        InvalidName
        # No list of that name.
        NotFound
        # A list of that name is already there and the caller did not ask to replace it.
        Exists
        # The directory entry is not a plain file: a symlink a `save` must not write through,
        # or a directory.
        NotRegular
        # A value that cannot be one line of the file (it holds a CR or LF).
        BadValue
        # Nothing to save.
        Empty
        # The source or the destination could not be read or written (`detail` = the OS's words).
        Io
      end

      getter reason : Reason
      getter detail : String?

      def initialize(@reason : Reason, message : String, @detail : String? = nil)
        super(message)
      end
    end

    # A catalog name: a filename, never a path. Letters and digits of any script (a Korean
    # operator names a list in Korean), `_`, and `.` `+` `-` and an INNER space after the first
    # character. It cannot start with `.`, `-` or a space — a leading dot is a hidden file (and
    # gori's own in-flight temp file, `.NAME.gori….tmp`), a leading dash reads as an option on a
    # command line — and it cannot end in a space or a dot, which some filesystems drop.
    # No separator of either kind, no NUL and no control character can occur, so a name can
    # never name a path outside the directory.
    NAME_PATTERN = /\A[\p{L}\p{N}_][\p{L}\p{N}_.+\- ]*\z/

    # UTF-8 BYTES, not characters, because the filesystem's limit is on bytes (255) and the
    # staging file adds a `.` prefix and a `.gori<random>.tmp` suffix to the same component.
    NAME_MAX_BYTES = 200

    # Owner-only, like the directory (`Paths::DIR_MODE`). A list an operator keeps here can be
    # a credential list or a set of values lifted from a capture.
    FILE_MODE = File::Permissions.new(0o600)

    # Most entries one `list` returns. The catalog is a directory an operator (and other tools)
    # drop files into, so it has no size of its own to trust.
    LIST_MAX = 1000

    # Most bytes `line_count` reads. A count of a file past this is reported as "more than
    # this many bytes' worth", never as a number — the exact figure would cost a full pass over
    # a list the operator may have measured in gigabytes.
    LINE_SCAN_MAX = 32 * 1024 * 1024

    # Longest `preview` and its byte budget. A preview is an opt-in look at values, not a
    # transfer: both bounds hold however long the lines are.
    PREVIEW_LINES_MAX = 1000
    PREVIEW_BYTES_MAX = 256 * 1024

    # One list in the catalog: everything a listing knows from `stat` alone. `symlink` is true
    # when the directory entry is a link to a list elsewhere (an operator's dotfiles-managed or
    # SecLists checkout) — `bytes` and `modified` are then the TARGET's, and `delete` /
    # `rename` act on the link, never on what it points at.
    record Entry, name : String, path : String, bytes : Int64, modified : Time, symlink : Bool

    # `list`'s answer. `truncated` — more lists exist than `LIST_MAX`.
    record Listing, entries : Array(Entry), truncated : Bool

    # `info`'s answer: the entry plus a line count taken over at most `LINE_SCAN_MAX` bytes.
    # `lines_complete` — the count covers the whole file; otherwise `lines` is what the scanned
    # prefix held and the list is longer.
    record Info, entry : Entry, lines : Int64, lines_complete : Bool

    # `preview`'s answer: the first lines, as bytes-faithful Strings (a line that is not valid
    # UTF-8 stays those octets; the surface scrubs where it prints). `truncated` — the list has
    # more lines than are shown, or a bound cut the preview short.
    record Preview, lines : Array(String), truncated : Bool

    # Where `resolve` found a name.
    enum Source
      # The spec has a path shape (it names a directory component), so it is used as given.
      Explicit
      # A bare name that exists in the current directory.
      Cwd
      # A bare name that exists in the global catalog.
      Catalog
      # A bare name found in neither place: handed back as given, so the consumer reports it
      # in its own words (and, for a name the catalog would accept, adds the catalog's hint).
      Missing
    end

    record Resolution, path : String, source : Source

    # ── resolution ────────────────────────────────────────────────────────────

    # What to open for a wordlist argument.
    #
    # A spec containing a `/` is a PATH and is returned untouched, byte for byte — an absolute
    # or relative path behaves exactly as it always did, and so does every error message
    # naming it. Only a BARE name (no separator) is looked up: in the current directory first,
    # so a file the operator has right here still wins over a catalog list of the same name,
    # then in the global directory. A bare name found nowhere comes back unchanged and
    # `Source::Missing`: the consumer's own not-found error then names what the operator typed.
    #
    # A directory in the current directory does not count as a hit — `--wordlist common` with a
    # `./common/` beside a catalog list `common` means the list — and an in-catalog hit must be
    # a valid catalog name that is a regular file (or a link to one).
    #
    # Only `stat`s: nothing is opened or read, so it is safe to call on every construction.
    def resolve(spec : String) : Resolution
      return Resolution.new(spec, Source::Explicit) if spec.includes?('/')
      return Resolution.new(spec, Source::Missing) if spec.empty? || spec.includes?('\0')
      return Resolution.new(spec, Source::Cwd) if usable_file?(spec)
      if valid_name?(spec)
        path = File.join(Paths.wordlists_dir, spec)
        return Resolution.new(path, Source::Catalog) if File.file?(path)
      end
      Resolution.new(spec, Source::Missing)
    rescue File::Error
      Resolution.new(spec, Source::Missing)
    end

    # The path `resolve` picks — for a loader that has no use for where it came from.
    def resolve_path(spec : String) : String
      resolve(spec).path
    end

    # The Miner's and Discover's candidate list: `builtin`, then the optional user file (read at
    # runtime, a bare name resolved through the catalog). De-duped, order preserved. A
    # missing/unreadable user path raises File::Error → the frontend reports it. `tool` is the
    # `gori run` subcommand the terminal refusal names.
    def load(builtin : Array(String), user_path : String?, *, tool : String) : Array(String)
      names = builtin.dup
      # Open the STRIPPED path (the emptiness check used it too).
      if (path = user_path.try(&.strip)) && !path.empty?
        merge_user_file(resolve_path(path), tool) { |line| names << line }
      end
      EmbeddedList.dedup(names)
    end

    # The user merge file is operator MATERIAL, not a curated gori asset: a leading or
    # trailing space/tab in a parameter NAME or a path SEGMENT is a real test (a literal `"id "`
    # a backend framework trims before lookup; the classic IIS/ASP.NET trailing-space /
    # trailing-dot access-control bypass pair), and the rest of the pipeline already carries it
    # to the wire byte-exact once it survives the loader (`zzhash#x` -> `zzhash%23x`, interior
    # tab -> `%09`) — only the loader was destroying it. So this reads with `chomp: true`
    # (line-ending only, same fidelity as `Fuzz::WordlistFile#next_value`, payload.cr) and keeps
    # the BLANK-LINE and `#`-COMMENT conventions (both standard for a line-oriented wordlist
    # file, and neither is expressible any other way in the format) — but classifies
    # blank/comment on the TRIMMED copy, never on the entry it yields, so `"zzp "` / `" zzp"` /
    # `"zzTRAILTAB\t"` each survive as distinct, unstripped entries instead of being silently
    # trimmed and then DEDUPED away against the trimmed twin (round 7, h1-seams.md FINDING 4).
    private def merge_user_file(path : String, tool : String, & : String ->) : Nil
      # `IO::Error`, so it rides the same funnel a missing or unreadable path does and reaches
      # every surface as `wordlist error: …` rather than as a backtrace. A terminal never ends
      # and echoes every byte typed into the scrollback, so `--wordlist /dev/tty` hung (#1034).
      if Gori::TtyPath.terminal?(path)
        raise IO::Error.new("wordlist is a terminal, not a file: #{path} — pipe the list in " \
                            "(`generator | gori run #{tool} … --wordlist /dev/stdin`) or name a real path")
      end
      File.each_line(path, chomp: true) do |line|
        trimmed = line.strip
        next if trimmed.empty? || trimmed.starts_with?('#')
        yield line
      end
    end

    # The sentence a not-found error appends for a name that was looked up rather than
    # opened as a path: it says WHERE gori looked, which is the thing an operator who typed
    # `common.txt` and got "not found" cannot see. nil for a spec that was a path or was found.
    def missing_hint(resolution : Resolution) : String?
      return nil unless resolution.source.missing?
      return nil unless valid_name?(resolution.path)
      "a bare name is looked up in the current directory, then in #{Paths.wordlists_dir}"
    end

    # Anything a wordlist can be read from that is not a directory: a file, or a FIFO an
    # operator named in the current directory.
    private def usable_file?(path : String) : Bool
      File.exists?(path) && !File.directory?(path)
    end

    # ── names ─────────────────────────────────────────────────────────────────

    def valid_name?(name : String) : Bool
      return false if name.empty? || name.bytesize > NAME_MAX_BYTES
      # PCRE2 raises on invalid UTF-8, and a name from an argv or an MCP argument can be one.
      return false unless name.valid_encoding?
      return false if name.ends_with?(' ') || name.ends_with?('.')
      NAME_PATTERN.matches?(name)
    end

    # The name, or the refusal. `what` is the role the name plays ("name", "new name") so a
    # rename can say which of its two arguments is wrong.
    def check_name!(name : String, what : String = "name") : String
      return name if valid_name?(name)
      raise Error.new(Error::Reason::InvalidName,
        "invalid wordlist #{what} #{name.inspect}: use letters, digits, `_`, `.`, `+`, `-` and inner " \
        "spaces (at most #{NAME_MAX_BYTES} bytes), starting with a letter, digit or `_` — a name is a file " \
        "in #{Paths.wordlists_dir}, never a path", name)
    end

    # ── reads ─────────────────────────────────────────────────────────────────

    # The catalog's lists, name-sorted (case-insensitively, then exactly, so the order is the
    # same on every filesystem). Regular files and links to regular files whose NAME the
    # catalog accepts; a directory, a hidden file, a temp file mid-write and a file named in a
    # way the catalog cannot address are left out. `stat` only — no list is opened.
    #
    # A missing directory is an empty catalog, not an error: it is created at startup
    # (`Paths.ensure_dirs`), and a fresh `GORI_HOME` reaching here first is normal.
    def list(limit : Int32 = LIST_MAX) : Listing
      dir = Paths.wordlists_dir
      names = begin
        Dir.children(dir)
      rescue File::Error
        return Listing.new([] of Entry, false)
      end
      names = names.select { |n| valid_name?(n) }
      names.sort_by! { |n| {n.downcase, n} }
      cap = limit.clamp(1, LIST_MAX)
      entries = [] of Entry
      names.each do |n|
        next unless e = entry_at(n)
        return Listing.new(entries, true) if entries.size >= cap
        entries << e
      end
      Listing.new(entries, false)
    end

    # One list's `stat`, or nil when there is none (or it is not a plain file).
    def entry(name : String) : Entry?
      return nil unless valid_name?(name)
      entry_at(name)
    end

    private def entry_at(name : String) : Entry?
      path = File.join(Paths.wordlists_dir, name)
      link = File.symlink?(path)
      info = File.info?(path) # follows a link: a link to a list is a list
      return nil unless info && info.file?
      Entry.new(name, path, info.size, info.modification_time, link)
    rescue File::Error
      nil
    end

    # The entry plus its line count, or the refusal. The count is bounded (`LINE_SCAN_MAX`).
    def info(name : String) : Info
      e = fetch!(name)
      lines, complete = line_count(e.path)
      Info.new(e, lines, complete)
    end

    # Lines in `path`, counted over at most `cap` bytes: `{lines, whole file covered?}`. A line
    # is what `File.each_line` yields — newline-terminated, plus an unterminated last one — so
    # the number agrees with the count a Fuzzer preflight prints for the same file.
    def line_count(path : String, cap : Int64 = LINE_SCAN_MAX.to_i64) : {Int64, Bool}
      lines = 0_i64
      scanned = 0_i64
      last = 0_u8
      buf = Bytes.new(64 * 1024)
      File.open(path) do |f|
        while scanned < cap
          want = {buf.size.to_i64, cap - scanned}.min.to_i32
          n = f.read(buf[0, want])
          break if n == 0
          scanned += n
          n.times do |i|
            lines += 1 if buf[i] == 0x0a_u8
          end
          last = buf[n - 1]
        end
        # Complete when the scan stopped because the file ran out, not because the budget did.
        complete = scanned < cap || f.read(buf[0, 1]) == 0
        lines += 1 if scanned > 0 && last != 0x0a_u8 && complete
        {lines, complete}
      end
    rescue ex : IO::Error
      raise Error.new(Error::Reason::Io, "cannot read #{path}: #{ex.message}", ex.message)
    end

    # The first `lines` lines of a list, within `PREVIEW_BYTES_MAX`. An explicit look at values —
    # the surfaces gate it behind an opt-in and never call it for a listing.
    #
    # Lines are cut the way `File.each_line(chomp: true)` cuts them (LF, or CRLF; a lone CR
    # stays), so what is shown is what a Fuzzer run would send. A last line with no newline is
    # shown only when the whole file was read — after a byte cut it may be half a line.
    def preview(name : String, lines : Int32 = 20) : Preview
      e = fetch!(name)
      want = lines.clamp(1, PREVIEW_LINES_MAX)
      File.open(e.path) do |f|
        buf = Bytes.new(PREVIEW_BYTES_MAX)
        got = 0
        while got < buf.size
          n = f.read(buf[got, buf.size - got])
          break if n == 0
          got += n
        end
        more = got == buf.size && f.read(Bytes.new(1)) > 0 # the file goes on past the byte budget
        shown = [] of String
        start = 0
        while shown.size < want && start < got
          nl = buf[start, got - start].index(0x0a_u8)
          if nl
            len = nl > 0 && buf[start + nl - 1] == 0x0d_u8 ? nl - 1 : nl
            shown << String.new(buf[start, len])
            start += nl + 1
          else
            unless more
              shown << String.new(buf[start, got - start])
              start = got
            end
            break
          end
        end
        Preview.new(shown, more || start < got)
      end
    rescue ex : IO::Error
      raise Error.new(Error::Reason::Io, "cannot read wordlist #{name.inspect}: #{ex.message}", ex.message)
    end

    private def fetch!(name : String) : Entry
      check_name!(name)
      entry_at(name) || raise Error.new(Error::Reason::NotFound,
        "no wordlist named #{name.inspect} in #{Paths.wordlists_dir}", name)
    end

    # ── writes ────────────────────────────────────────────────────────────────

    # Does `value` hold a CR or LF — the one thing a one-value-per-line file cannot carry?
    def line_break?(value : String) : Bool
      value.includes?('\n') || value.includes?('\r')
    end

    # `values` without those a list file cannot hold, and how many that dropped. For a caller
    # that READS its values from a source it does not control (project data) and chooses to
    # leave them out and say so; `save_values` itself refuses the whole save instead. One
    # predicate, so what a file cannot carry is decided in one place.
    def one_per_line(values : Array(String)) : {Array(String), Int32}
      kept = values.reject { |v| line_break?(v) }
      {kept, values.size - kept.size}
    end

    # Save `values` as list `name`, one value per line, EXACTLY as given (a blank value is a
    # blank line, a value starting with `#` stays one, leading and trailing whitespace stays).
    # A value holding a CR or LF cannot be one line of the file and is refused rather than
    # split — splitting it would save more payloads than the caller counted.
    def save_values(name : String, values : Array(String), *, overwrite : Bool = false) : Entry
      count = 0
      values.each_with_index do |v, i|
        count += 1
        if line_break?(v)
          raise Error.new(Error::Reason::BadValue,
            "value #{i + 1} contains a line break — a wordlist file holds one value per line", (i + 1).to_s)
        end
      end
      raise Error.new(Error::Reason::Empty, "nothing to save: the list is empty") if count == 0
      publish(name, overwrite) do |io|
        values.each do |v|
          io << v << '\n'
        end
      end
    end

    # Save the bytes of the file at `source` as list `name` — a streamed, verbatim copy, so a
    # multi-GB list is never held in memory and no line is normalized. A terminal is refused
    # the way every wordlist reader refuses one (#1034).
    def save_file(name : String, source : String, *, overwrite : Bool = false) : Entry
      if TtyPath.terminal?(source)
        raise Error.new(Error::Reason::Io, "wordlist source is a terminal, not a file: #{source} — " \
                                           "pipe the list in (`generator | gori run wordlist save NAME --from -`) " \
                                           "or name a real path", source)
      end
      raise Error.new(Error::Reason::Io, "wordlist source is a directory, not a file: #{source}", source) if File.directory?(source)
      File.open(source) { |src| save_io(name, src, overwrite: overwrite) }
    rescue ex : IO::Error
      raise Error.new(Error::Reason::Io, "cannot read #{source}: #{ex.message}", ex.message)
    end

    # Save whatever `io` yields as list `name`, verbatim (see `save_file`).
    def save_io(name : String, io : IO, *, overwrite : Bool = false) : Entry
      publish(name, overwrite) do |file|
        IO.copy(io, file)
      end
    end

    # Remove list `name`. A link is removed, never its target.
    def delete(name : String) : Nil
      e = fetch!(name)
      begin
        File.delete(e.path)
      rescue File::NotFoundError
        raise Error.new(Error::Reason::NotFound, "no wordlist named #{name.inspect} in #{Paths.wordlists_dir}", name)
      rescue ex : File::Error
        raise Error.new(Error::Reason::Io, "cannot delete #{e.path}: #{ex.message}", ex.message)
      end
    end

    # Rename list `from` to `to`. Refuses to replace an existing list unless `overwrite`.
    # The refusal is exclusive on the directory entry: the new name is created with a
    # hard link (which fails if the name exists), then the old one is unlinked, so two
    # concurrent renames onto one name cannot both succeed. A filesystem without hard links
    # falls back to check-then-rename, and a symlink entry always does (a link is moved as a
    # link, never turned into a second name for its target).
    def rename(from : String, to : String, *, overwrite : Bool = false) : Entry
      src = fetch!(from)
      check_name!(to, "new name")
      dest = File.join(Paths.wordlists_dir, to)
      return src if src.path == dest
      # A case-only rename (`ids` → `IDS`) on a case-insensitive filesystem (macOS's default):
      # `dest` already "exists" because it IS the source entry, so the exclusive link would
      # refuse it as a clash. Renaming the one entry onto its new spelling is the whole job.
      if src.path.downcase == dest.downcase && File.exists?(dest) && File.same?(src.path, dest)
        File.rename(src.path, dest)
      elsif overwrite
        refuse_unreplaceable!(to, dest)
        File.rename(src.path, dest)
      else
        exclusive_move(src, dest, to)
      end
      entry_at(to) || raise Error.new(Error::Reason::Io, "renamed #{from.inspect} to #{to.inspect}, but the new list cannot be read back", to)
    rescue ex : File::Error
      raise Error.new(Error::Reason::Io, "cannot rename #{from.inspect} to #{to.inspect}: #{ex.message}", ex.message)
    end

    private def exclusive_move(src : Entry, dest : String, to : String) : Nil
      if src.symlink
        raise exists!(to) if File.exists?(dest) || File.symlink?(dest)
        File.rename(src.path, dest)
        return
      end
      begin
        File.link(src.path, dest)
      rescue File::AlreadyExistsError
        raise exists!(to)
      rescue File::Error
        # No hard links here (a network mount, an exFAT volume): the best available is a check.
        raise exists!(to) if File.exists?(dest) || File.symlink?(dest)
        File.rename(src.path, dest)
        return
      end
      begin
        File.delete(src.path)
      rescue ex : File::Error
        File.delete?(dest) rescue nil # both names would exist: undo the new one
        raise ex
      end
    end

    # A list to be replaced must be a plain file: replacing a directory is not a rename, and
    # a symlink's target is somebody else's file that a rename must not clobber.
    private def refuse_unreplaceable!(name : String, dest : String) : Nil
      return unless File.exists?(dest) || File.symlink?(dest)
      if File.symlink?(dest)
        raise Error.new(Error::Reason::NotRegular,
          "#{name.inspect} is a symlink — delete it first (a replace never writes through a link)", name)
      end
      unless File.file?(dest)
        raise Error.new(Error::Reason::NotRegular, "#{name.inspect} exists and is not a plain file", name)
      end
    end

    private def exists!(name : String) : Error
      Error.new(Error::Reason::Exists,
        "a wordlist named #{name.inspect} already exists — choose another name, or replace it explicitly", name)
    end

    # Stage the content the block writes, then install it atomically at `name`.
    #
    # `overwrite: false` installs with a hard link — the link fails when the name is taken —
    # and THAT refusal is the overwrite check: the `exists?` a few lines up only fails fast
    # before gigabytes are staged, and a concurrent save landing in the gap is still refused
    # here rather than replaced. `overwrite: true` is a rename over a plain file. Either way a
    # reader sees the old list or the whole new one, never a torn one, and the staged file is
    # owner-only from the moment it exists.
    private def publish(name : String, overwrite : Bool, &write : File ->) : Entry
      check_name!(name)
      dir = Paths.wordlists_dir
      target = File.join(dir, name)
      begin
        Paths.ensure_dir(dir)
        refuse_unreplaceable!(name, target) if overwrite
        raise exists!(name) if !overwrite && (File.exists?(target) || File.symlink?(target))
        tmp_path = ""
        staged = DurableFile.stage(target, perm: FILE_MODE, inherit: false) do |tmp, mode|
          tmp_path = tmp
          File.open(tmp, "w", perm: mode) do |f|
            write.call(f)
            f.flush
            f.fsync
          end
          # Refused before anything is installed: saving an empty stream must not replace a
          # list with nothing.
          if File.info(tmp).size == 0
            raise Error.new(Error::Reason::Empty, "nothing to save: the source is empty")
          end
        end
        install(staged, tmp_path, target, name, overwrite)
      rescue ex : Error
        raise ex
      rescue ex : Gori::Error
        # `Paths.ensure_dir` says what is in the way ("path exists and is not a directory").
        raise Error.new(Error::Reason::Io, "cannot write to #{dir}: #{ex.message}", ex.message)
      rescue ex : IO::Error
        raise Error.new(Error::Reason::Io, "cannot write #{target}: #{ex.message}", ex.message)
      end
      entry_at(name) || raise Error.new(Error::Reason::Io, "saved #{name.inspect}, but the new list cannot be read back", name)
    end

    private def install(staged : DurableFile::Staged, tmp : String, target : String, name : String, overwrite : Bool) : Nil
      if overwrite
        staged.commit
        return
      end
      begin
        File.link(tmp, target)
      rescue File::AlreadyExistsError
        staged.discard
        raise exists!(name)
      rescue File::Error
        # No hard links on this filesystem: a check, then the rename. Not exclusive against a
        # writer racing this very call — the best a link-less volume allows.
        if File.exists?(target) || File.symlink?(target)
          staged.discard
          raise exists!(name)
        end
        staged.commit
        return
      end
      staged.discard # the link is the list now; drop the staging name
    rescue ex : File::Error
      staged.discard # a rename that failed leaves the staged file behind otherwise
      raise ex
    end
  end
end
