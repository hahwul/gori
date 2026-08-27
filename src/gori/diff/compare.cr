require "../tolerance"
require "./keys"
require "./snapshot"

module Gori::Diff
  # What the diff says about one endpoint.
  #
  # Five verdicts, not the obvious four, because "absent from B" is TWO different facts
  # and only one of them is a finding. An endpoint B never requested is a COVERAGE gap —
  # gori has no evidence either way. An endpoint B did request and got 404/410 from is
  # evidence it is gone. Collapsing those into one "removed" bucket would report a
  # thinner retest as a wave of fixes.
  enum Verdict
    Added     # captured in B, never captured in A
    Removed   # captured in A, NOT REQUESTED in B — unknown, not gone (see `Report#coverage_note`)
    Gone      # captured in both; every answer B got was 404/410 where A was reachable
    Changed   # captured in both; ≥1 axis moved beyond tolerance
    Unchanged # captured in both; equivalent

    # The MACHINE name — the `--verdict` token and the JSON discriminator. `Removed` keeps
    # that spelling because it is the bucket callers ask for by name, but no human-facing
    # surface prints the bare word: `Render.heading` and the TUI's row tag both say "not
    # seen", because "removed" is a claim about the target and this is a fact about the
    # retest. The two vocabularies are deliberate, not drift.
    def label : String
      to_s.downcase
    end
  end

  # A response axis that moved. `from`/`to` are display strings — the exact statuses, the
  # content types, the byte sizes — so a report can say what changed and not merely that
  # something did.
  enum Axis
    Status
    Auth
    ContentType
    Size

    def label : String
      case self
      in .status?       then "status"
      in .auth?         then "auth"
      in .content_type? then "content-type"
      in .size?         then "size"
      end
    end
  end

  record Change, axis : Axis, from : String, to : String do
    def to_s(io : IO) : Nil
      io << axis.label << ": " << from << " → " << to
    end
  end

  # One endpoint's row in the report. `a`/`b` are nil on the side that never saw it.
  record Row,
    key : Key,
    verdict : Verdict,
    a : Facts?,
    b : Facts?,
    changes : Array(Change)

  # Compares two snapshots at endpoint scale. Pure: it sends nothing, and it reads no
  # bodies — this diffs CAPTURED data (the scanner axis is deliberately out of gori's
  # scope). A row that deserves a closer look carries `sample_flow_id` on each side, which
  # is what the flow-level Comparer (`gori run compare`, the Comparer tab) takes.
  module Compare
    # The floor under the size band, as a divisor of the response size: 1/10, i.e. 10%.
    #
    # `Gori::Tolerance`'s own floor is 1%, which is right for what its two callers do —
    # send the same request twice, seconds apart, and ask whether the answer moved. A
    # retest asks the same question of two captures MONTHS apart, where a rotating banner,
    # a re-minified asset or one more row in a listing move a page by a few percent with
    # nothing behind it. At 1% those all report `changed`, and four real findings end up
    # buried under three hundred rows of churn — the failure this feature exists to avoid.
    #
    # The formula is unchanged (still `Tolerance.band`, still 2x the observed jitter when
    # there IS jitter to observe); only the floor is loosened, and only here.
    SIZE_FLOOR_DIVISOR = 10

    # How far a response's size may move before the move counts as a real change: 2x
    # either side's own observed jitter, never less than SIZE_FLOOR_DIVISOR of its size.
    # A dynamic page whose length wanders between captures therefore reads `unchanged`,
    # which is the point — byte equality would report every timestamped page as changed.
    def self.size_changed?(a : Facts, b : Facts) : Bool
      # Nothing measured on one side (every capture there is still pending, or errored):
      # there is no comparison to make, so this axis stays silent rather than guessing.
      range_a = a.size_range || return false
      range_b = b.size_range || return false
      # `Facts#size_mid` is the one definition of the centre — the same number `Render` and
      # the TUI print beside this row, so the readout and the verdict cannot drift.
      mid_a = a.size_mid || return false
      mid_b = b.size_mid || return false
      tol = {size_band(range_a, mid_a), size_band(range_b, mid_b)}.max
      (mid_a - mid_b).abs > tol
    end

    private def self.size_band(range : {Int64, Int64}, mid : Int64) : Int64
      floor = {Tolerance::LENGTH_FLOOR, mid // SIZE_FLOOR_DIVISOR}.max
      Tolerance.band(range[0], range[1], mid, floor)
    end

    # The axes that moved between two sides of one endpoint, most significant first.
    def self.changes(a : Facts, b : Facts) : Array(Change)
      out = [] of Change
      # Auth leads: "it asks for credentials now" is the finding an operator scans for, and
      # it is a status move whose meaning the class comparison alone would not name.
      if a.auth_required? != b.auth_required?
        out << Change.new(Axis::Auth, auth_label(a), auth_label(b))
      end
      # CLASSES, not exact statuses — a 200 that became a 201 is not a retest finding. The
      # `from`/`to` still print the exact set, so nothing is hidden by the tolerance.
      if a.status_classes != b.status_classes
        out << Change.new(Axis::Status, status_label(a), status_label(b))
      end
      if a.content_types != b.content_types
        out << Change.new(Axis::ContentType, ct_label(a), ct_label(b))
      end
      if size_changed?(a, b)
        out << Change.new(Axis::Size, size_label(a), size_label(b))
      end
      out
    end

    # The verdict for an endpoint both sides captured.
    def self.verdict(a : Facts, b : Facts, changes : Array(Change)) : Verdict
      # Evidence of removal, and the only kind a capture can carry: A reached it, every
      # answer B got was "not here".
      return Verdict::Gone if a.reachable? && b.absent?
      changes.empty? ? Verdict::Unchanged : Verdict::Changed
    end

    # Diff two sides. Rows come back ordered by host, then path, then method — the same
    # ordering the Sitemap reads in — so two runs over the same pair are byte-identical.
    def self.rows(a_facts : Hash(Key, Facts), b_facts : Hash(Key, Facts)) : Array(Row)
      out = [] of Row
      a_facts.each do |key, a|
        if b = b_facts[key]?
          ch = changes(a, b)
          out << Row.new(key, verdict(a, b, ch), a, b, ch)
        else
          out << Row.new(key, Verdict::Removed, a, nil, [] of Change)
        end
      end
      b_facts.each do |key, b|
        out << Row.new(key, Verdict::Added, nil, b, [] of Change) unless a_facts.has_key?(key)
      end
      out.sort_by! { |r| {r.key.host, r.key.path, r.key.method} }
      out
    end

    def self.auth_label(f : Facts) : String
      f.auth_required? ? "required" : "not required"
    end

    # The exact statuses, as a report prints them (the VERDICT compares classes). Public
    # because `Render` prints the same set beside a row that did NOT change status, and a
    # second spelling of "how a status set reads" is how two lines of one report disagree.
    def self.status_label(f : Facts) : String
      parts = f.sorted_statuses.map(&.to_s)
      parts << "pending" if f.pending?
      parts.empty? ? "—" : parts.join(", ")
    end

    def self.ct_label(f : Facts) : String
      cts = f.sorted_content_types
      cts.empty? ? "—" : cts.join(", ")
    end

    def self.size_label(f : Facts) : String
      lo, hi = f.size_range || return "—"
      lo == hi ? "#{lo} B" : "#{lo}–#{hi} B"
    end
  end
end
