require "./store"

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
      FIELDS = %w(severity: status: category: host: code:)

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

      # True when the query explicitly constrains status (status:/st:, possibly negated),
      # so the list view skips its default open-only restriction and honours the user's
      # explicit choice of statuses instead.
      def has_status_term? : Bool
        @terms.any? { |t| t.kind == :status }
      end

      def apply(issues : Array(Store::ProbeIssue)) : Array(Store::ProbeIssue)
        return issues if @terms.empty?
        issues.select { |i| matches?(i) }
      end

      def matches?(i : Store::ProbeIssue) : Bool
        @terms.all? { |t| match_term(t, i) }
      end

      private def self.build_term(tok : String, negate : Bool) : Term
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
