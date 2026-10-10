require "./triage_filter"

module Gori
  module Issues
    # An in-memory predicate over issues, parsed from a History-like filter
    # string. Issues live wholly in memory (a small severity-sorted list), so —
    # unlike History's QL→SQL — this matches Crystal-side. Terms are whitespace-
    # separated and AND-joined; a leading `-` negates a field term; an unrecognised
    # or bare token is free text over the title + host.
    #
    #   open                      → free text "open" in title/host
    #   status:open sev:>=high    → only OPEN issues at High or Critical
    #   -status:resolved host:api → not-resolved AND host contains "api"
    class Filter
      # The bar's whole vocabulary: canonical name => every spelling `build_term` dispatches
      # on. ONE table, because the two questions asked of it drift apart otherwise — the
      # Tab-completion list and the highlighter's "do I implement this field" predicate are
      # the same knowledge, and an alias missing from the second paints `sev:>=high` (the
      # spelling this class's own doc comment uses) as a typo. `issues_query_spec` pins every
      # entry here against `build_term` rather than trusting the pair to stay in step.
      ALIASES = {
        "severity" => ["severity", "sev"],
        "status"   => ["status", "st"],
        "host"     => ["host"],
        "title"    => ["title"],
        "cvss"     => ["cvss"],
      }

      include TriageFilter

      # What each field means ON THIS BAR — deliberately NOT `QL::FIELD_HELP`, even though
      # `FilterAst` and two of the names are shared, and this is the reason the help source is
      # a parameter of `QuerySuggest.render` at all. QL describes `status:` as an HTTP code
      # with 5xx classes and comparisons; here it is a TRIAGE state, so QL's table would state
      # this field's meaning backwards on the one surface where the bar is the only place the
      # vocabulary is ever learned. `host:` would be nearly right and still wrong: QL's line
      # advertises `host~` for regex, which `known_field?` refuses outright.
      FIELD_HELP = {
        "severity" => "info low medium high critical — takes >= <= > <",
        "status"   => "triage state — open confirmed fp resolved (closed = any non-open)",
        "host"     => "the issue's host — substring",
        "title"    => "the issue's title — substring",
        "cvss"     => "score, with >= <= > < — or a substring of the vector",
      }

      # The `?` reference's SYNTAX section. `HelpView.query_rows` defaults to `QL::SYNTAX_HELP`
      # and more than half of it is untrue here: it teaches `body~secret\d+`, `dur:>1.5s` and
      # the `req.`/`resp.` side prefixes, none of which this parser has. What IS shared is the
      # boolean grammar, because it is literally the same `FilterAst`.
      SYNTAX_HELP = [
        {"severity:high status:open", "space = AND (both must hold)"},
        {"status:open OR status:confirmed", "OR; NOT > AND > OR, ( ) to group"},
        {"-status:resolved", "leading - excludes — so does NOT status:resolved"},
        {"NOT (severity:info OR severity:low)", "NOT or -( negates a whole group"},
        {"severity:>=high cvss:>=7.0", ">= <= > < = on severity and cvss"},
        {"title:\"sql injection\"", "quotes keep spaces inside one term"},
        {"login", "a bare word searches title and host"},
      ]

      # WORTH KNOWING, for this backend. Every entry is a rule written somewhere below in this
      # file, which is the point: the page states what the matcher does, not what QL's does.
      CAVEATS = [
        {"there is no regex", "title~admin free-texts the whole token — see known_field?"},
        {"status:closed", "any non-open triage state: confirmed, fp or resolved"},
        {"cvss: reads two ways", "with an operator it compares the score; bare, it also matches the vector"},
        {"an empty value passes all", "status: mid-type matches everything, so the list never blanks as you type"},
        {"-status: matches none", "the negation of \"matches all\" — deliberate, and spec-pinned"},
        {"matching is in memory", "issues are a small severity-sorted list, so there is no index and no size limit"},
      ]

      # Comparison samples for `cvss:`, as `SEVERITY_SAMPLES` are for `severity:`. No list can
      # be `cvss:`'s vocabulary — it is a float — so these exist to teach syntax, which
      # completion otherwise cannot: ↹ offers NAMES until a `:` is typed.
      CVSS_SAMPLES = %w[>=4.0 >=7.0 >=9.0]

      # ↹ candidates for the token under `cx`: field names until a `:` is typed, then that
      # field's values. The grammar's punctuation is carried through by `FilterAst::Cursor`,
      # so `-sev` → `-severity:` and `(sev` → `(severity:` — which the bar's old
      # `[/\S*\z/]` tokenizer could not do, so a negated field never completed at all.
      #
      # `hosts` is the caller's host pool. The view reads it straight off the in-memory issue
      # list, so unlike History there is no store round-trip here and no async cache to
      # invalidate.
      def self.suggestions(query : String, cx : Int32, hosts : Array(String) = [] of String) : Array(String)
        complete(query, cx) { |field| value_pool(field, hosts) }
      end

      # The pool for one field, or nil when the field has no closed vocabulary to offer
      # (`title:` is free text, and a name that completes over an EMPTY value list reads as a
      # closed field with nothing in it). Plain values lead the ordinal fields so ↹ on a bare
      # `severity:` takes a severity rather than an operator.
      private def self.value_pool(field : String, hosts : Array(String)) : Array(String)?
        case CANONICAL[field]?
        when "severity" then SEVERITY_VALUES + SEVERITY_SAMPLES
        when "status"   then STATUS_VALUES
        when "cvss"     then CVSS_SAMPLES
        when "host"     then hosts
        end
      end

      # Keep store order. An empty filter passes all.
      def apply(issues : Array(Store::Issue)) : Array(Store::Issue)
        return issues if @tree.nil?
        issues.select { |f| matches?(f) }
      end

      def matches?(f : Store::Issue) : Bool
        tree = @tree
        return true unless tree
        eval(tree, f)
      end

      # --- parsing -------------------------------------------------------------

      # Never drops a term: an empty value is kept and resolved in match_term, which
      # is where this filter's "`status:` matches all, `-status:` matches none" rule
      # lives (Probe deliberately differs — see Probe::Filter#match_term).
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
          when "cvss"
            op, text = split_op(value)
            return Term.new(:cvss, op, text.downcase, negate)
          when "status", "st"
            return Term.new(:status, :eq, value.downcase, negate)
          when "host"
            return Term.new(:host, :eq, value.downcase, negate)
          when "title"
            return Term.new(:title, :eq, value.downcase, negate)
          end
        end
        # Unrecognised prefix or bare token → free text (matched over title + host).
        Term.new(:text, :eq, tok.downcase, negate)
      end

      # --- matching ------------------------------------------------------------

      private def match_term(t : Term, f : Store::Issue) : Bool
        # An empty value (mid-type "status:" / "sev:>=") matches all, so the list
        # doesn't blank out until a value is typed — uniform across every field
        # kind (host:/title: already do this via includes?("")). Negation is honoured:
        # `status:` matches all, so its negation `-status:` matches none (spec-pinned).
        return !t.negate if t.text.empty?
        hit = case t.kind
              when :severity then match_severity(t, f.severity)
              when :cvss     then match_cvss(t, f)
              when :status   then match_status(t.text, f.status)
              when :host     then (f.host || "").downcase.includes?(t.text)
              when :title    then f.title.downcase.includes?(t.text)
              else                free_text(t.text, f)
              end
        t.negate ? !hit : hit
      end

      # `cvss:` reads two ways, and WHICH one is decided by the OPERATOR, not by whether the
      # operand happens to look like a number.
      #
      #   cvss:>=7.0   a comparison: numeric, and only issues that actually score
      #   cvss:3.1     bare: the score if the operand is one, else a substring of the vector
      #
      # Branching on the operand instead let `cvss:>=high` — the obvious transfer from the
      # documented `sev:>=high` — quietly become a substring search and report matches as if
      # the comparison had been honoured. It also dropped an issue whose stored string is not
      # scorable (a legacy or imported value) from `cvss:3.1`, even though the substring path
      # would have matched it: the numeric branch bailed on the missing score before ever
      # trying the text.
      private def match_cvss(t : Term, f : Store::Issue) : Bool
        cvss_str = f.cvss
        return false unless cvss_str
        target = t.text.to_f?
        if t.op != :eq
          return false unless target && (score = f.cvss_score)
          cmp = score <=> target
          return false unless cmp
          case t.op
          when :ge then cmp >= 0
          when :gt then cmp > 0
          when :le then cmp <= 0
          when :lt then cmp < 0
          else          false
          end
        else
          if target && (score = f.cvss_score)
            return true if score == target
            # A stored bare SCORE is only a score: as a substring `cvss:5` matched 7.5. A vector
            # keeps its substring reading (`cvss:3.1`, the version, as documented).
            return false if cvss_str.strip.to_f?
          end
          cvss_str.downcase.includes?(t.text)
        end
      end

      private def free_text(text : String, f : Store::Issue) : Bool
        return true if text.empty?
        f.title.downcase.includes?(text) || (f.host || "").downcase.includes?(text)
      end
    end
  end
end
