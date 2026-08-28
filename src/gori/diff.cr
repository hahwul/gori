require "./diff/keys"
require "./diff/snapshot"
require "./diff/compare"
require "./diff/report"
require "./diff/render"
require "./diff/record"

module Gori
  # The retest axis: diff two SNAPSHOTS at endpoint scale — "what changed since the last
  # engagement?" — as opposed to the Comparer's flow-vs-flow diff.
  #
  # Retesting is half of real engagement work and every surface that exists for it diffs
  # two messages. gori keeps a project's history, sitemap, issues and flows in one store
  # each, so "compare project A to project B" is a query rather than an export/import
  # dance: two grouped reads, one shared fold tree, no bodies, no network.
  #
  # Three commitments hold this together:
  #
  #   * **One notion of "the same endpoint".** Keys come from `Sitemap`'s existing fold
  #     passes (`Diff::Templates`), so a diff row names the row the Sitemap tab draws.
  #   * **One notion of "the same response".** `changed` is judged by `Gori::Tolerance`,
  #     the band `Repeater::Minimize` and `Miner::Baseline` already use — not byte
  #     equality, which would report every timestamped page as changed.
  #   * **Absence is reported as absence.** An endpoint missing from B is a coverage gap
  #     until B actually asked and got a 404; the two are different verdicts and the
  #     report says which is which beside every count.
  #
  # It sends nothing. Confirming that a finding still reproduces takes a request, and that
  # stays the operator's call through Repeater (DESIGN.md: gori is not a scanner).
  module Diff
  end
end
