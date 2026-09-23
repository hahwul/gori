require "../embedded_list"
require "./payload"

module Gori::Fuzz
  # Curated, built-in payload sets — one per common injection class — baked into the
  # binary at compile time (gori ships no runtime asset dir). Addressable by name so a
  # run can select one without a file on disk, and mergeable with an optional user file.
  #
  # Copies the shape of `Discover::Wordlist` / `Miner::Wordlist` verbatim: `read_file`
  # embeds each set, a load-time merge appends the user file, and the result is
  # de-duplicated and order-preserving (built-in first). The sets are a fast-start
  # convenience, not a wordlist manager — keep them focused, not exhaustive.
  module Presets
    # name → embedded raw text. `read_file` takes a compile-time string; "#{__DIR__}/…"
    # resolves relative to THIS source file, so the embed works regardless of the
    # process's working directory. Every entry here needs a matching payloads/NAME.txt.
    BUILTIN_RAW = {
      "sqli"              => {{ read_file("#{__DIR__}/payloads/sqli.txt") }},
      "xss"               => {{ read_file("#{__DIR__}/payloads/xss.txt") }},
      "traversal"         => {{ read_file("#{__DIR__}/payloads/traversal.txt") }},
      "format-string"     => {{ read_file("#{__DIR__}/payloads/format-string.txt") }},
      "bad-strings"       => {{ read_file("#{__DIR__}/payloads/bad-strings.txt") }},
      "command-injection" => {{ read_file("#{__DIR__}/payloads/command-injection.txt") }},
    }

    @@cache = {} of String => Array(String)

    # The preset names, sorted for a stable enumeration across the TUI / CLI / MCP.
    def self.names : Array(String)
      BUILTIN_RAW.keys.to_a.sort!
    end

    # Whether `name` (case/space-normalized) names a built-in preset — for a surface to
    # reject a typo up front with a listed alternative, before a run is built.
    def self.exists?(name : String) : Bool
      BUILTIN_RAW.has_key?(normalize(name))
    end

    # The parsed built-in list for `name`, cached. Raises on an unknown name.
    def self.builtin(name : String) : Array(String)
      key = normalize(name)
      raw = BUILTIN_RAW[key]? || raise Gori::Error.new(unknown_message(name))
      @@cache[key] ||= EmbeddedList.parse(raw)
    end

    # Built-in payloads, then the optional user file (read at runtime). De-duped, order
    # preserved (built-in first) — the same contract as `Discover::Wordlist.load`. An
    # unknown preset name, or a missing / unreadable merge file, raises `Gori::Error`.
    def self.load(name : String, user_path : String? = nil) : Array(String)
      values = builtin(name).dup
      if path = user_path.try(&.strip)
        unless path.empty?
          raise Gori::Error.new("preset merge file not found: #{path}") unless File.exists?(path)
          raise Gori::Error.new("preset merge file is a directory, not a file: #{path}") if File.directory?(path)
          raise Gori::Error.new("preset merge file not readable: #{path}") unless File::Info.readable?(path)
          # The user merge file is operator MATERIAL, not a curated gori asset: read it
          # with the SAME fidelity as `WordlistFile` (payload.cr, `gets(chomp: true)`) —
          # chomp the line ending only, keeping leading/trailing whitespace, `#`-leading
          # lines (a SQL `#` comment, `#{7*7}` SSTI, a `#!/bin/sh` shebang are all valid
          # payloads) and blank lines (an intentional empty payload, sent by `-w` too).
          # The strip + comment/blank skip in `EmbeddedList.parse` is correct ONLY for the
          # built-in `.txt` sets, whose headers document `#`/blank as comments.
          File.each_line(path, chomp: true) do |line|
            values << line
          end
        end
      end
      EmbeddedList.dedup(values)
    end

    private def self.normalize(name : String) : String
      name.strip.downcase
    end

    private def self.unknown_message(name : String) : String
      "unknown payload preset: #{name.strip.inspect} (available: #{names.join(", ")})"
    end
  end

  # A built-in preset (see `Presets`) as a `PayloadSource`, so it composes with every
  # other set (inline / file / numbers / …) in cluster-bomb and pitchfork runs unchanged.
  # Resolved lazily and cached: an unknown preset name or an unreadable merge file raises
  # a clean `Gori::Error` from `size` / `open_iterator` — the same pre-flight contract
  # `WordlistFile` has, so a bad set is caught before any worker fiber spawns.
  class PresetSource < PayloadSource
    getter name : String
    getter user_path : String?

    def initialize(@name : String, @user_path : String? = nil)
      @resolved = nil.as(InlineList?)
    end

    private def resolved : InlineList
      @resolved ||= InlineList.new(Presets.load(@name, @user_path))
    end

    def size : Int64?
      resolved.size
    end

    def open_iterator : SetIterator
      resolved.open_iterator
    end
  end
end
