require "../store"

module Gori::Tui
  # One row of the Probe findings list. The store keeps one finding per (check code, host), so
  # a check that fires on ten hosts was ten rows saying the same thing. With grouping on, a
  # code on 2+ hosts folds into one GROUP row, and its host rows are drawn under it only while
  # it is expanded. A view projection only: MCP `probe_issues` and `gori run probe` read the
  # store and never see it.
  struct ProbeRow
    # A host row's own finding, or a group's first (highest-ranked) member.
    getter issue : Store::ProbeIssueRow
    # Every member of a GROUP row, in list order; nil on a host row.
    getter members : Array(Store::ProbeIssueRow)?
    # A host row drawn under its expanded group.
    getter? child : Bool

    def initialize(@issue : Store::ProbeIssueRow, @members : Array(Store::ProbeIssueRow)? = nil, @child : Bool = false)
    end

    def group? : Bool
      !@members.nil?
    end

    def code : String
      @issue.code
    end

    # A group's highest severity; a host row's own.
    def severity : Store::Severity
      @members.try(&.max_of(&.severity)) || @issue.severity
    end

    # The `×N` the row draws: a host row's affected-URL count, summed over a group's hosts.
    def affected_count : Int32
      @members.try(&.sum(&.affected_count)) || @issue.affected_count
    end

    # The findings as list rows: one per finding with grouping off, else every code on 2+
    # hosts folded at its first member's place, with its hosts beneath while `expanded` holds
    # the code. Built from the FILTERED findings, so a group's host count is what survived the
    # lenses and the query.
    def self.build(findings : Array(Store::ProbeIssueRow), grouped : Bool, expanded : Set(String)) : Array(ProbeRow)
      return findings.map { |f| new(f) } unless grouped
      by_code = findings.group_by(&.code)
      rows = [] of ProbeRow
      findings.each do |f|
        members = by_code[f.code]
        next rows << new(f) if members.size < 2
        next unless members.first.id == f.id
        rows << new(f, members)
        members.each { |m| rows << new(m, child: true) } if expanded.includes?(f.code)
      end
      rows
    end
  end
end
