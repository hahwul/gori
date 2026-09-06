require "levenshtein"

module Gori
  module MCP
    # `gori mcp --tools=SPEC` — which of the 160 tools this server advertises.
    #
    # The whole catalogue is ~172 KB of JSON, or roughly 43,000 tokens, and an MCP client
    # loads it into the model's context before the first question is asked and keeps it there
    # for the session. `--read-only` was the only lever, and it cuts one specific way (down to
    # 53 tools / ~12k tokens) — there was no way to say "history and flows, plus send_request,
    # and none of the fuzz/mine/discover/authorize workbench", which is most of what an agent
    # attached to a capture actually needs.
    #
    # SPEC is a comma-separated list of tool names and `*` globs, evaluated left to right; a
    # term prefixed with `-` subtracts. Globs mean the prefix families the tools are already
    # named for (`list_*`, `intercept_*`, `fuzz_*`) are groups for free, with no catalogue to
    # drift out of step with the registry:
    #
    #     --tools='list_*,get_*,ql_*,send_request'      only those
    #     --tools='-fuzz_*,-mine_*,-discover_*'         everything except the async workbench
    #     --tools='*,-intercept_*'                      same idea, spelled explicitly
    #
    # A spec whose first term subtracts starts from EVERYTHING; otherwise it starts from
    # nothing and adds. A term matching no known tool is a startup ABORT rather than a silent
    # narrowing: the failure mode this is meant to prevent is a server that quietly serves
    # three tools because a name was misspelled, which reads to the agent exactly like a
    # feature that does not exist.
    struct ToolFilter
      getter spec : String
      @allowed : Set(String)

      private def initialize(@spec, @allowed)
      end

      # Parses SPEC against `known` (the registry's full name list, already narrowed by
      # --read-only where that applies). Returns the filter, or the message to abort with.
      def self.parse(spec : String, known : Enumerable(String)) : ToolFilter | String
        terms = spec.split(',').map(&.strip).reject(&.empty?)
        return "--tools: no tool patterns given" if terms.empty?

        all = known.to_a
        # Leading subtraction means "everything, except…" — the common shape, and the one that
        # keeps working when a later gori adds a tool the operator never listed.
        selected = terms.first.starts_with?('-') ? all.to_set : Set(String).new
        terms.each do |term|
          subtract = term.starts_with?('-')
          pattern = subtract ? term[1..] : term
          return "--tools: empty pattern in #{spec.inspect}" if pattern.empty?
          hits = all.select { |name| matches?(pattern, name) }
          if hits.empty?
            return "--tools: #{pattern.inspect} matches no tool#{suggestion(pattern, all)}"
          end
          subtract ? selected.subtract(hits) : selected.concat(hits)
        end
        if selected.empty?
          return "--tools: #{spec.inspect} selects no tools; the server would advertise nothing"
        end
        new(spec, selected)
      end

      # The "did you mean" tail, spelled the way `QL.suggest_field` spells its own: a
      # SUBSTRING sweep first (a caller who typed `history` means the family), then edit
      # distance for a genuine typo, which is what `list_hisotry` needs and a substring
      # search can never find.
      private def self.suggestion(pattern : String, all : Array(String)) : String
        stem = pattern.delete('*')
        unless stem.empty?
          near = all.select(&.includes?(stem)).first(5)
          return " — did you mean #{near.join(", ")}?" unless near.empty?
        end
        if close = Levenshtein.find(stem, all, stem.size < 6 ? 2 : 3)
          return " — did you mean #{close}?"
        end
        " (see `gori mcp` tools/list, or try a glob like 'list_*')"
      end

      # Shell-style `*` only — the one metacharacter the prefix families need. Anchored at
      # both ends so `list_*` cannot also match `x_list_y`, and matched case-sensitively
      # because every tool name is lowercase.
      private def self.matches?(pattern : String, name : String) : Bool
        return true if pattern == "*"
        return pattern == name unless pattern.includes?('*')
        parts = pattern.split('*')
        pos = 0
        parts.each_with_index do |part, i|
          next if part.empty?
          if i == 0
            return false unless name.starts_with?(part)
            pos = part.size
          elsif i == parts.size - 1
            return false unless name.ends_with?(part) && name.size - part.size >= pos
            pos = name.size
          else
            idx = name.index(part, pos)
            return false unless idx
            pos = idx + part.size
          end
        end
        true
      end

      def allows?(name : String) : Bool
        @allowed.includes?(name)
      end

      def size : Int32
        @allowed.size
      end

      # The names kept, sorted — for the startup banner, so the operator can see on stderr
      # what the client is about to be shown.
      def names : Array(String)
        @allowed.to_a.sort!
      end
    end
  end
end
