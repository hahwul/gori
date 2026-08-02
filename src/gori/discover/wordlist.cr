module Gori::Discover
  # The candidate directory/path names for the brute-forcer. The built-in list is baked
  # into the binary at compile time (gori ships no runtime asset dir); an optional user
  # file is merged in at load time. De-duplicated, order-preserving (built-in first).
  # Copies Miner::Wordlist verbatim in shape.
  module Wordlist
    # read_file takes a compile-time string; "#{__DIR__}/…" resolves relative to THIS
    # source file, so the embed works regardless of the process's working directory.
    BUILTIN_RAW = {{ read_file("#{__DIR__}/wordlists/paths.txt") }}

    @@builtin : Array(String)?

    def self.builtin : Array(String)
      @@builtin ||= parse(BUILTIN_RAW)
    end

    # Built-in paths, then the optional user file (read at runtime). De-duped, order
    # preserved. A missing/unreadable user path raises File::Error → the frontend reports it.
    def self.load(user_path : String? = nil) : Array(String)
      names = builtin.dup
      if path = user_path.try(&.strip)
        unless path.empty?
          merge_user_file(path) { |line| names << line }
        end
      end
      dedup(names)
    end

    # The user merge file is operator MATERIAL, not a curated gori asset: a leading or
    # trailing space/tab in a path SEGMENT is a real test (the classic IIS/ASP.NET
    # trailing-space / trailing-dot access-control bypass pair), and the rest of the
    # pipeline already carries it to the wire byte-exact once it survives the loader —
    # only the loader was destroying it. So this reads with `chomp: true` (line-ending
    # only, same fidelity as `Fuzz::WordlistFile#next_value`, payload.cr) and keeps the
    # BLANK-LINE and `#`-COMMENT conventions (both standard for a line-oriented wordlist
    # file, and neither is expressible any other way in the format) — but classifies
    # blank/comment on the TRIMMED copy, never on the entry it yields, so
    # `"zzadmin "` / `" zzadmin"` / `"zzTRAILTAB\t"` each survive as distinct, unstripped
    # entries instead of being silently trimmed and then DEDUPED away against the
    # trimmed twin (round 7, h1-seams.md FINDING 4).
    private def self.merge_user_file(path : String, & : String ->) : Nil
      File.each_line(path, chomp: true) do |line|
        trimmed = line.strip
        next if trimmed.empty? || trimmed.starts_with?('#')
        yield line
      end
    end

    private def self.parse(raw : String) : Array(String)
      out = [] of String
      raw.each_line do |line|
        stripped = line.strip
        out << stripped unless stripped.empty? || stripped.starts_with?('#')
      end
      out
    end

    private def self.dedup(list : Array(String)) : Array(String)
      seen = Set(String).new
      list.select { |n| seen.add?(n) }
    end
  end
end
