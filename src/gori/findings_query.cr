require "./store"

module Gori
  module Findings
    # An in-memory predicate over findings, parsed from a History-like filter
    # string. Findings live wholly in memory (a small severity-sorted list), so —
    # unlike History's QL→SQL — this matches Crystal-side. Terms are whitespace-
    # separated and AND-joined; a leading `-` negates a field term; an unrecognised
    # or bare token is free text over the title + host.
    #
    #   open                      → free text "open" in title/host
    #   status:open sev:>=high    → only OPEN findings at High or Critical
    #   -status:resolved host:api → not-resolved AND host contains "api"
    class Filter
      # One parsed clause. `op` only matters for ordinal (severity) comparisons.
      private record Term, kind : Symbol, op : Symbol, text : String, negate : Bool

      def self.parse(query : String) : Filter
        terms = [] of Term
        query.split.each do |raw|
          next if raw.empty?
          negate = false
          tok = raw
          if tok.starts_with?('-') && tok.size > 1
            negate = true
            tok = tok[1..]
          end
          terms << build_term(tok, negate)
        end
        new(terms)
      end

      def initialize(@terms : Array(Term))
      end

      def empty? : Bool
        @terms.empty?
      end

      # Keep store order; every term must match (AND). An empty filter passes all.
      def apply(findings : Array(Store::Finding)) : Array(Store::Finding)
        return findings if @terms.empty?
        findings.select { |f| matches?(f) }
      end

      def matches?(f : Store::Finding) : Bool
        @terms.all? { |t| match_term(t, f) }
      end

      # --- parsing -------------------------------------------------------------

      private def self.build_term(tok : String, negate : Bool) : Term
        if (colon = tok.index(':'))
          field = tok[0...colon].downcase
          value = tok[(colon + 1)..]
          case field
          when "severity", "sev"
            op, text = split_op(value)
            return Term.new(:severity, op, text.downcase, negate)
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

      # Peel a leading comparison operator (>= <= > < =) off a severity value.
      private def self.split_op(value : String) : {Symbol, String}
        return {:ge, value[2..]} if value.starts_with?(">=")
        return {:le, value[2..]} if value.starts_with?("<=")
        return {:gt, value[1..]} if value.starts_with?(">")
        return {:lt, value[1..]} if value.starts_with?("<")
        return {:eq, value[1..]} if value.starts_with?("=")
        {:eq, value}
      end

      # --- matching ------------------------------------------------------------

      private def match_term(t : Term, f : Store::Finding) : Bool
        # An empty value (mid-type "status:" / "sev:>=") matches all, so the list
        # doesn't blank out until a value is typed — uniform across every field
        # kind (host:/title: already do this via includes?("")).
        return !t.negate if t.text.empty?
        hit = case t.kind
              when :severity then match_severity(t, f.severity)
              when :status   then match_status(t.text, f.status)
              when :host     then (f.host || "").downcase.includes?(t.text)
              when :title    then f.title.downcase.includes?(t.text)
              else                free_text(t.text, f)
              end
        t.negate ? !hit : hit
      end

      private def free_text(text : String, f : Store::Finding) : Bool
        return true if text.empty?
        f.title.downcase.includes?(text) || (f.host || "").downcase.includes?(text)
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
        when "closed"               then !status.open? # any non-open triage state
        else                             false
        end
      end
    end
  end
end
