require "levenshtein"

module Gori
  module MCP
    # `gori mcp --tools=SPEC` — which of `Tools::TOOL_NAMES` this server advertises.
    #
    # An MCP client loads the whole catalogue into the model's context before the first
    # question is asked and keeps it there for the session; what that costs is measured, not
    # written down here — `gori mcp` weighs the catalogue it is about to serve on every start
    # (`Tools.catalogue_json`), and the guide's table is checked against the same number
    # (spec/mcp/catalogue_size_spec.cr). A count in this comment would be the drift #1137
    # found in four other places.
    #
    # `--read-only` was the only lever, and it cuts one specific way (to the tools that
    # neither write nor dial) — there was no way to say "history and flows, plus
    # send_request, and none of the fuzz/mine/discover/authorize workbench", which is most of
    # what an agent attached to a capture actually needs.
    #
    # The two flags are INDEPENDENT and compose: a spec is resolved against the whole
    # catalogue, whatever the gate is doing, so `--read-only --tools='…,send_request'` names
    # a tool that exists and is then withheld — it is not a misspelling. `gori mcp` refuses
    # the one combination that leaves nothing to serve, and `Tools.served_names` is the one
    # place the two are put together.
    #
    # SPEC is a comma-separated list of tool names and `*` globs, evaluated left to right; a
    # term prefixed with `-` subtracts. Globs mean the prefix families the tools are already
    # named for (`list_*`, `intercept_*`, `fuzz_*`) are groups for free, with no catalogue to
    # drift out of step with the registry:
    #
    #     --tools='list_*,get_*,ql_*,send_request'      only those
    #     --tools='-fuzz_*,-mine_*,-discover_*'         everything except the async workbench
    #     --tools='*,-intercept_*'                      same idea, spelled explicitly
    #     --tools=@recon                                a named profile (`PROFILES`)
    #     --tools='@minimal,send_request'               a profile, plus one tool
    #
    # A spec whose first term subtracts starts from EVERYTHING; otherwise it starts from
    # nothing and adds. A term matching no known tool is a startup ABORT rather than a silent
    # narrowing: the failure mode this is meant to prevent is a server that quietly serves
    # three tools because a name was misspelled, which reads to the agent exactly like a
    # feature that does not exist.
    struct ToolFilter
      # A named, curated catalogue: `--tools=@name` selects `tools`, and `-@name` takes them
      # away, so a profile composes with globs and names like any other term.
      record Profile, name : String, summary : String, tools : Array(String)

      # What an agent attached to a capture reads with, and the channel back to the operator.
      # `list_projects` + `switch_project` are here on purpose: a profile has to work on an
      # UNBOUND start too (outside a git workspace, `--no-project`, a database that would not
      # open), and a server with no picker cannot be repaired from the agent's side (#1136).
      MINIMAL = %w[project_info list_projects switch_project
        ql_reference list_history get_flow get_response_body_chunk
        get_current_context operator_messages reply_to_operator]

      # …plus the rest of the capture an agent maps a target from, the pure decoders it reads
      # tokens with, ONE request replayed, and the issues and notes it records findings in.
      # Not the workbench (fuzz/mine/discover/sequence/authorize, repeater tabs, rules): an
      # agent that needs those is the one the full catalogue is for.
      RECON = MINIMAL + %w[ql_explain list_sitemap list_scope compare_flows list_env
        decode jwt_decode
        probe_issues list_issues get_issue list_notes get_note
        send_request create_issue update_issue create_note update_note]

      # Explicit NAMES, never globs, and that is the design: a profile is a promise about
      # SIZE, and `list_*` would grow it with every lister the registry gains — the same
      # silent growth #1137 was filed about, moved inside the one lever meant to contain it.
      # A tool joins a profile by being written here. Every name is a real tool
      # (spec/mcp/tool_filter_spec.cr), and the guide's table reports each profile's count
      # and weight (spec/mcp/catalogue_size_spec.cr).
      PROFILES = [
        Profile.new("minimal", "read History and single flows; talk to the operator", MINIMAL),
        Profile.new("recon", "@minimal + sitemap, scope, findings, decoders, send_request, " \
                             "issue and note writes", RECON),
      ]

      getter spec : String
      @allowed : Set(String)

      private def initialize(@spec, @allowed)
      end

      # `@minimal, @recon` — for `--help` and every refusal that has to list them.
      def self.profile_names : String
        PROFILES.join(", ") { |p| "@#{p.name}" }
      end

      # Parses SPEC against `known` — the registry's full name list, and only ever that.
      # Returns the filter, or the message to abort with.
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
          if pattern.starts_with?('@')
            hits = profile(pattern[1..], all)
            return hits if hits.is_a?(String)
          else
            hits = all.select { |name| matches?(pattern, name) }
            if hits.empty?
              return "--tools: #{pattern.inspect} matches no tool#{suggestion(pattern, all)}"
            end
          end
          subtract ? selected.subtract(hits) : selected.concat(hits)
        end
        if selected.empty?
          return "--tools: #{spec.inspect} selects no tools; the server would advertise nothing"
        end
        new(spec, selected)
      end

      # A profile's tools, or the refusal. An unknown name is refused like an unmatched glob
      # and for the same reason, and the refusal lists every profile: there are few enough to
      # name, and "did you mean" alone cannot help someone guessing at `@read`.
      #
      # A member `known` lacks is a gori bug, not the operator's — the spec pins every member
      # to the registry — but it is still refused loudly rather than dropped: a profile that
      # quietly lost a tool is the silent narrowing this whole parser exists to prevent.
      private def self.profile(name : String, all : Array(String)) : Array(String) | String
        unless p = PROFILES.find { |pr| pr.name == name }
          near = Levenshtein.find(name, PROFILES.map(&.name), 2)
          hint = near ? " — did you mean @#{near}?" : ""
          return "--tools: unknown profile #{"@#{name}".inspect}#{hint} (profiles: #{profile_names})"
        end
        if missing = p.tools.find { |t| !all.includes?(t) }
          return "--tools: profile @#{p.name} names #{missing.inspect}, which this gori does not serve"
        end
        p.tools
      end

      # The "did you mean" tail, spelled the way `QL.suggest_field` spells its own: a
      # SUBSTRING sweep first (a caller who typed `history` means the family), then edit
      # distance for a genuine typo, which is what `list_hisotry` needs and a substring
      # search can never find.
      private def self.suggestion(pattern : String, all : Array(String)) : String
        # A profile's name without its sigil: `--tools=recon` is not a typo for any tool.
        return " — did you mean @#{pattern}?" if PROFILES.any? { |p| p.name == pattern }
        stem = pattern.delete('*')
        unless stem.empty?
          near = all.select(&.includes?(stem)).first(5)
          return " — did you mean #{near.join(", ")}?" unless near.empty?
        end
        if close = Levenshtein.find(stem, all, stem.size < 6 ? 2 : 3)
          return " — did you mean #{close}?"
        end
        " (see `gori mcp` tools/list, try a glob like 'list_*', or a profile: #{profile_names})"
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
