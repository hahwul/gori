require "./store"
require "./filter_ast"

module Gori
  # What the two triage filter bars, `Issues::Filter` and `Probe::Filter`, share: one
  # in-memory predicate over a short list, parsed by `FilterAst`, with the same severity and
  # status vocabularies. An includer supplies its own field table (`ALIASES`, `FIELD_HELP`),
  # `build_term`, `match_term`, `value_pool` and public `suggestions`; everything derived from
  # those is pasted in by `included`, because a constant in a plain module resolves against
  # the MODULE, never the class that includes it.
  #
  # `match_term` stays with each includer on purpose: the empty-value rule is where the two
  # bars deliberately differ (`-status:` matches none on Issues, all on Probe).
  module TriageFilter
    macro included
      # Canonical names, separator included, in completion order — what the view splices
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

      # The vocabulary a typo is measured against: every spelling `build_term` dispatches on,
      # bare (no separator), because `FilterAst.suggest` compares NAMES. The completion list
      # `FIELDS` carries its `:` and canonical names only, so suggesting out of it would both
      # miss `sev` and hand back a name with punctuation glued on.
      CANDIDATE_FIELDS = ALIASES.values.flatten

      # The spelling a name this bar does not implement most likely meant — `FilterAst.suggest`
      # over the pool above. Shared rule, OWN vocabulary: `QL.suggest_field` answers out of QL's
      # fields, which hold nothing near `sevrity` or `catgory`, so a bar that borrowed it would
      # stay silent about its own fields — and would name QL fields this bar cannot filter on.
      def self.suggest_field(name : String) : String?
        return nil if name.empty? || known_field?(name)
        FilterAst.suggest(name.downcase, CANDIDATE_FIELDS)
      end

      # The span highlighter's shape — see `QL::FIELD_SHAPED`, including why the operator is
      # not part of the SHAPE question. No namespaces: this bar has no dotted field, so a
      # dotted name is an authority (`acme.test:8443`) and never a namespace guess.
      FIELD_SHAPED = ->(f : String, _op : Char, v : String) do
        FilterAst.field_shaped?(f, v, known_field?(f)) { suggest_field(f) }
      end

      # Canonical name for a spelling — `sev` is `severity`. The completion row asks for help
      # by the name the OPERATOR typed (`QuerySuggest.field_of`), so a table keyed only by
      # canonical names would leave every alias in `ALIASES` undescribed.
      CANONICAL = begin
        h = {} of String => String
        ALIASES.each { |canon, spellings| spellings.each { |sp| h[sp] = canon } }
        h
      end

      # As a proc, built once: the bar draws this every frame while the filter is being
      # edited, and an inline closure at the call site allocates one per frame.
      FIELD_HELP_PROC = ->(f : String) do
        canon = CANONICAL[f.downcase]?
        canon ? FIELD_HELP[canon]? : nil
      end

      def self.field_help(name : String) : String?
        FIELD_HELP_PROC.call(name)
      end

      # The subset a one-row cold hint samples — see `QL::HINT_FIELDS` for why a hint samples
      # at all. All five fit, so this is the whole vocabulary rather than a sample.
      HINT_FIELDS = ALIASES.keys

      # The spellings the `?` reference lists under ALSO ACCEPTED. `CANONICAL` maps every
      # spelling including the canonical one to itself, and a page saying `severity: =
      # severity:` is noise, so the identity entries go.
      ALSO_ACCEPTED = CANONICAL.reject { |from, to| from == to }

      # The closed value vocabularies, spelled the way `severity_value` and `match_status`
      # actually match them. Only the CANONICAL spelling of each is offered: `med`, `crit`,
      # `conf`, `fp` and `done` still parse, but a completion list carrying both spellings
      # spends the whole row saying one thing twice.
      SEVERITY_VALUES = %w[info low medium high critical]
      STATUS_VALUES   = %w[open confirmed false-positive resolved closed]

      # Comparison samples, so the bar can show that `severity:` takes an operator at all —
      # completion offers NAMES until a `:` is typed and can never teach this.
      SEVERITY_SAMPLES = %w[>=medium >=high >=critical]

      # ↹ candidates for the token under `cx`: field names until a `:` is typed, then the
      # values `pool` yields for that field (nil = no closed vocabulary to offer). Punctuation
      # rides through on `FilterAst::Cursor`, so `-sev` → `-severity:`.
      private def self.complete(query : String, cx : Int32, & : String -> Array(String)?) : Array(String)
        cur = FilterAst.token_at(query, cx)
        return [] of String if cur.core.empty?
        if (colon = cur.core.index(':')) && colon > 0
          field = cur.core[0...colon].downcase
          prefix = FilterAst.unquote_prefix(cur.core[(colon + 1)..]).downcase
          values = yield(field) || [] of String
          values.select(&.downcase.starts_with?(prefix)).map { |v| "#{cur.prefix}#{field}:#{FilterAst.quote(v)}" }
        else
          FIELDS.select(&.starts_with?(cur.core.downcase)).map { |f| "#{cur.prefix}#{f}" }
        end
      end

      # One parsed clause. `op` only matters for ordinal comparisons.
      private record Term, kind : Symbol, op : Symbol, text : String, negate : Bool

      def self.parse(query : String) : {{ @type }}
        new(FilterAst.build(FilterAst.parse(query)) { |t| build_term(t) })
      end

      def initialize(@tree : FilterAst::Tree(Term)?)
      end

      def empty? : Bool
        @tree.nil?
      end

      private def eval(tree : FilterAst::Tree(Term), x) : Bool
        case tree.op
        in .leaf? then match_term(tree.leaf, x)
        in .not?  then !eval(tree.children.first, x)
        in .and?  then tree.children.all? { |c| eval(c, x) }
        in .or?   then tree.children.any? { |c| eval(c, x) }
        end
      end

      # Peel a leading comparison operator (>= <= > < =) off an ordinal field's value.
      private def self.split_op(value : String) : {Symbol, String}
        return {:ge, value[2..]} if value.starts_with?(">=")
        return {:le, value[2..]} if value.starts_with?("<=")
        return {:gt, value[1..]} if value.starts_with?(">")
        return {:lt, value[1..]} if value.starts_with?("<")
        return {:eq, value[1..]} if value.starts_with?("=")
        {:eq, value}
      end
    end

    private def match_severity(t, sev : Store::Severity) : Bool
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
      end
    end

    private def match_status(name : String, status : Store::Status) : Bool
      case name
      when "open"                 then status.open?
      when "confirmed", "conf"    then status.confirmed?
      when "false-positive", "fp" then status.false_positive?
      when "resolved", "done"     then status.resolved?
      when "closed"               then !status.open? # any non-open triage state
      else                             false
      end
    end
  end
end
