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
          File.each_line(path) do |line|
            stripped = line.strip
            names << stripped unless stripped.empty? || stripped.starts_with?('#')
          end
        end
      end
      dedup(names)
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
