require "../embedded_list"
require "../wordlist_catalog"

module Gori::Miner
  # The candidate parameter names. The built-in list is baked into the binary at
  # compile time (gori ships no runtime asset dir); an optional user file is merged in
  # at load time by `WordlistCatalog.load`.
  module Wordlist
    # read_file takes a compile-time string; "#{__DIR__}/…" resolves relative to THIS
    # source file, so the embed works regardless of the process's working directory.
    BUILTIN_RAW = {{ read_file("#{__DIR__}/wordlists/params.txt") }}

    @@builtin : Array(String)?

    def self.builtin : Array(String)
      @@builtin ||= EmbeddedList.parse(BUILTIN_RAW)
    end

    def self.load(user_path : String? = nil) : Array(String)
      WordlistCatalog.load(builtin, user_path, tool: "mine")
    end
  end
end
