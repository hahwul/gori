require "./triage_filter"
require "./probe/issue" # FILTER_CATEGORIES — the one list `category:` and `--category` share

module Gori
  module Probe
    # An in-memory predicate over Probe issues, parsed from a Issues-like filter string.
    # Issues are already grouped (one row per code+host) and live wholly in memory, so —
    # like Issues::Filter — this matches Crystal-side. Terms are whitespace-separated and
    # AND-joined; a leading `-` negates a field term; a bare/unrecognised token is free text
    # over title + host + code.
    #
    #   reflected                  → free text "reflected" in title/host/code
    #   category:tech sev:>=high   → tech issues at High or Critical
    #   -status:resolved host:api  → not-resolved AND host contains "api"
    class Filter
      # The bar's whole vocabulary: canonical name => every spelling `build_term` dispatches
      # on. ONE table for the same reason `Issues::Filter::ALIASES` is one — the completion
      # list and the highlighter's "do I implement this field" predicate are the same
      # knowledge, and an alias missing from the second paints `sev:>=high` (the spelling
      # this class's own doc comment uses) as a typo. `probe_query_spec` pins every entry
      # against `build_term`.
      ALIASES = {
        "severity" => ["severity", "sev"],
        "status"   => ["status", "st"],
        "category" => ["category", "cat"],
        "host"     => ["host"],
        "code"     => ["code"],
      }

      include TriageFilter

      # What each field means ON THIS BAR — not `QL::FIELD_HELP`, for the reason
      # `Issues::Filter::FIELD_HELP` spells out: `status:` here is a triage state, not an HTTP
      # code, and QL's `host:` line advertises a `host~` regex this parser refuses.
      FIELD_HELP = {
        "severity" => "info low medium high critical — takes >= <= > <",
        "status"   => "triage state — open confirmed fp resolved (closed = any non-open)",
        "category" => "which check found it — #{FILTER_CATEGORIES.join(" ")}",
        "host"     => "the finding's host — substring",
        "code"     => "the rule's code — substring",
      }

      # This backend's own SYNTAX / WORTH KNOWING for the `?` reference, for the reason
      # `Issues::Filter::SYNTAX_HELP` gives: the boolean grammar is shared `FilterAst`, the
      # fields and the regex are not.
      SYNTAX_HELP = [
        {"category:tech severity:high", "space = AND (both must hold)"},
        {"host:api OR host:cdn", "OR; NOT > AND > OR, ( ) to group"},
        {"-category:tech", "leading - excludes — so does NOT category:tech"},
        {"NOT (severity:info OR severity:low)", "NOT or -( negates a whole group"},
        {"severity:>=high", ">= <= > < = on severity"},
        {"code:\"missing csp\"", "quotes keep spaces inside one term"},
        {"reflected", "a bare word searches title, host and code"},
      ]

      CAVEATS = [
        {"there is no regex", "code~x-frame free-texts the whole token — see known_field?"},
        {"status:closed", "any non-open triage state: confirmed, fp or resolved"},
        {"no status: term", "the list shows OPEN findings only — name a status to see the rest"},
        {"an empty value passes all", "even negated: -host: filters nothing, so a half-typed exclusion cannot blank the list"},
        {"one row per code+host", "findings are grouped before this filter ever sees them"},
      ]

      # ↹ candidates for the token under `cx` — field names until a `:` is typed, then values.
      # Punctuation rides through on `FilterAst::Cursor`, so `-cat` → `-category:`, which the
      # old `[/\S*\z/]` tokenizer could not complete. `hosts` and `codes` are the caller's
      # pools, read off the in-memory issue list.
      def self.suggestions(query : String, cx : Int32, hosts : Array(String) = [] of String,
                           codes : Array(String) = [] of String) : Array(String)
        complete(query, cx) { |field| value_pool(field, hosts, codes) }
      end

      # nil when the field has no closed vocabulary to offer — a name that completes over an
      # EMPTY value list reads as a closed field with nothing in it.
      #
      # `category:` completes from `FILTER_CATEGORIES`, the one list the CLI and the MCP tools
      # already validate against, rather than a copy: this bar and `--category` must not come
      # to disagree about which lenses exist.
      private def self.value_pool(field : String, hosts : Array(String),
                                  codes : Array(String)) : Array(String)?
        case CANONICAL[field]?
        when "severity" then SEVERITY_VALUES + SEVERITY_SAMPLES
        when "status"   then STATUS_VALUES
        when "category" then FILTER_CATEGORIES
        when "host"     then hosts
        when "code"     then codes
        end
      end

      # True when the query explicitly constrains status (status:/st:, possibly negated),
      # so the list view skips its default open-only restriction and honours the user's
      # explicit choice of statuses instead. Anywhere in the tree counts — a status term
      # inside an OR branch is still the user asking about status.
      def has_status_term? : Bool
        @tree.try(&.leaves.any? { |t| t.kind == :status }) || false
      end

      # Either shape: the Probe tab filters its list projection (`ProbeIssueRow`), and every
      # field a term reads is on both.
      def apply(issues : Array(T)) : Array(T) forall T
        return issues if @tree.nil?
        issues.select { |i| matches?(i) }
      end

      def matches?(i : Store::AnyProbeIssue) : Bool
        tree = @tree
        return true unless tree
        eval(tree, i)
      end

      # Never drops a term; an empty value is resolved in match_term, which here makes
      # even a NEGATED empty term (`-host:`) filter nothing — deliberately unlike
      # Issues::Filter, so a half-typed negation can't blank the whole list.
      private def self.build_term(t : FilterAst::Term) : Term
        tok = t.text
        negate = t.negate?
        if colon = tok.index(':')
          field = tok[0...colon].downcase
          value = tok[(colon + 1)..]
          case field
          when "severity", "sev"
            op, text = split_op(value)
            return Term.new(:severity, op, text.downcase, negate)
          when "status", "st"    then return Term.new(:status, :eq, value.downcase, negate)
          when "category", "cat" then return Term.new(:category, :eq, value.downcase, negate)
          when "host"            then return Term.new(:host, :eq, value.downcase, negate)
          when "code"            then return Term.new(:code, :eq, value.downcase, negate)
          end
        end
        Term.new(:text, :eq, tok.downcase, negate)
      end

      private def match_term(t : Term, i : Store::AnyProbeIssue) : Bool
        # An incomplete term (e.g. mid-typing `host:` or `-host:`) filters nothing — match all.
        # (Previously a NEGATED empty term matched nothing and blanked the whole list.)
        return true if t.text.empty?
        hit = case t.kind
              when :severity then match_severity(t, i.severity)
              when :status   then match_status(t.text, i.status)
              when :category then i.category.downcase.includes?(t.text)
              when :host     then i.host.downcase.includes?(t.text)
              when :code     then i.code.downcase.includes?(t.text)
              else                free_text(t.text, i)
              end
        t.negate ? !hit : hit
      end

      private def free_text(text : String, i : Store::AnyProbeIssue) : Bool
        return true if text.empty?
        i.title.downcase.includes?(text) || i.host.downcase.includes?(text) || i.code.downcase.includes?(text)
      end
    end
  end
end
