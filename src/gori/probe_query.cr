require "./store"
require "./filter_ast"
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

      # Canonical names, separator included, in completion order — what `ProbeView` splices
      # over a half-typed token on ↹.
      FIELDS = ALIASES.keys.map { |n| "#{n}:" }

      KNOWN = ALIASES.values.flatten.to_set

      # Does this backend implement `name`, with this separator? The predicate
      # `FilterAst.spans` asks before painting a token as a FIELD (see its `known` argument).
      # `regex` is always false here: only QL and the intercept gate implement `~`, so a
      # `title~admin` is free-texted whole and must not be coloured as a match nobody performs.
      def self.known_field?(name : String, regex : Bool = false) : Bool
        !regex && KNOWN.includes?(name.downcase)
      end

      # Canonical name for a spelling — `cat` is `category`. Same reason as
      # `Issues::Filter::CANONICAL`: the completion row asks for help by the name the operator
      # typed, so a table keyed only by canonical names leaves every alias undescribed.
      CANONICAL = begin
        h = {} of String => String
        ALIASES.each { |canon, spellings| spellings.each { |sp| h[sp] = canon } }
        h
      end

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

      # Built once — the bar draws it every frame while the filter is being edited.
      FIELD_HELP_PROC = ->(f : String) do
        canon = CANONICAL[f.downcase]?
        canon ? FIELD_HELP[canon]? : nil
      end

      def self.field_help(name : String) : String?
        FIELD_HELP_PROC.call(name)
      end

      # All five fit a one-row hint, so this is the whole vocabulary rather than a sample.
      HINT_FIELDS = ALIASES.keys

      # ALSO ACCEPTED on the `?` reference — the identity entries in `CANONICAL` dropped.
      ALSO_ACCEPTED = CANONICAL.reject { |from, to| from == to }

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

      # Spelled the way `severity_value` / `match_status` below match them; only the canonical
      # spelling of each is offered (`med`, `crit`, `conf`, `fp`, `done` still parse).
      SEVERITY_VALUES = %w[info low medium high critical]
      STATUS_VALUES   = %w[open confirmed false-positive resolved closed]

      # Comparison samples, so the bar can show that `severity:` takes an operator at all —
      # completion offers NAMES until a `:` is typed and can never teach this.
      SEVERITY_SAMPLES = %w[>=medium >=high >=critical]

      # ↹ candidates for the token under `cx` — field names until a `:` is typed, then values.
      # Punctuation rides through on `FilterAst::Cursor`, so `-cat` → `-category:`, which the
      # old `[/\S*\z/]` tokenizer could not complete. `hosts` and `codes` are the caller's
      # pools, read off the in-memory issue list.
      def self.suggestions(query : String, cx : Int32, hosts : Array(String) = [] of String,
                           codes : Array(String) = [] of String) : Array(String)
        cur = FilterAst.token_at(query, cx)
        return [] of String if cur.core.empty?
        if (colon = cur.core.index(':')) && colon > 0
          field = cur.core[0...colon].downcase
          prefix = FilterAst.unquote_prefix(cur.core[(colon + 1)..])
          suggest_values(field, prefix, hosts, codes).map { |v| "#{cur.prefix}#{field}:#{FilterAst.quote(v)}" }
        else
          FIELDS.select(&.starts_with?(cur.core.downcase)).map { |f| "#{cur.prefix}#{f}" }
        end
      end

      private def self.suggest_values(field : String, prefix : String, hosts : Array(String),
                                      codes : Array(String)) : Array(String)
        values = value_pool(field, hosts, codes)
        return [] of String unless values
        p = prefix.downcase
        values.select(&.downcase.starts_with?(p))
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

      private record Term, kind : Symbol, op : Symbol, text : String, negate : Bool

      def self.parse(query : String) : Filter
        new(FilterAst.build(FilterAst.parse(query)) { |t| build_term(t) })
      end

      def initialize(@tree : FilterAst::Tree(Term)?)
      end

      def empty? : Bool
        @tree.nil?
      end

      # True when the query explicitly constrains status (status:/st:, possibly negated),
      # so the list view skips its default open-only restriction and honours the user's
      # explicit choice of statuses instead. Anywhere in the tree counts — a status term
      # inside an OR branch is still the user asking about status.
      def has_status_term? : Bool
        @tree.try(&.leaves.any? { |t| t.kind == :status }) || false
      end

      def apply(issues : Array(Store::ProbeIssue)) : Array(Store::ProbeIssue)
        return issues if @tree.nil?
        issues.select { |i| matches?(i) }
      end

      def matches?(i : Store::ProbeIssue) : Bool
        tree = @tree
        return true unless tree
        eval(tree, i)
      end

      private def eval(tree : FilterAst::Tree(Term), i : Store::ProbeIssue) : Bool
        case tree.op
        in .leaf? then match_term(tree.leaf, i)
        in .not?  then !eval(tree.children.first, i)
        in .and?  then tree.children.all? { |c| eval(c, i) }
        in .or?   then tree.children.any? { |c| eval(c, i) }
        end
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

      private def self.split_op(value : String) : {Symbol, String}
        return {:ge, value[2..]} if value.starts_with?(">=")
        return {:le, value[2..]} if value.starts_with?("<=")
        return {:gt, value[1..]} if value.starts_with?(">")
        return {:lt, value[1..]} if value.starts_with?("<")
        return {:eq, value[1..]} if value.starts_with?("=")
        {:eq, value}
      end

      private def match_term(t : Term, i : Store::ProbeIssue) : Bool
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

      private def free_text(text : String, i : Store::ProbeIssue) : Bool
        return true if text.empty?
        i.title.downcase.includes?(text) || i.host.downcase.includes?(text) || i.code.downcase.includes?(text)
      end

      private def match_severity(t : Term, sev : Store::Severity) : Bool
        target = severity_value(t.text)
        return false unless target
        cmp = sev.value <=> target
        case t.op
        when :ge then cmp >= 0
        when :gt then cmp > 0
        when :le then cmp <= 0
        when :lt then cmp < 0
        else          cmp == 0
        end
      end

      private def severity_value(name : String) : Int32?
        case name
        when "info"             then 0
        when "low"              then 1
        when "medium", "med"    then 2
        when "high"             then 3
        when "critical", "crit" then 4
        else                         nil
        end
      end

      private def match_status(name : String, status : Store::Status) : Bool
        case name
        when "open"                 then status.open?
        when "confirmed", "conf"    then status.confirmed?
        when "false-positive", "fp" then status.false_positive?
        when "resolved", "done"     then status.resolved?
        when "closed"               then !status.open?
        else                             false
        end
      end
    end
  end
end
