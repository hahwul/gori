require "../payload_from"
require "./payload"

module Gori::Fuzz
  # A payload set read from the project's own captured data (#1352): a QL-selected flow set
  # projected into values (`PayloadFrom`), consumed like any other set — it composes with the
  # other sets in every mode and runs through the same processing pipeline and the same
  # position-specific encoding as a wordlist would.
  #
  # Built by a surface from its own syntax (`--payload-from`, MCP `payload_from`, the payload
  # editor's Project type) with NOTHING resolved: it is just the normalized `Spec`. The plan
  # builder resolves it (`Fuzz::Plan.build` — the one place a store is read for a run), so the
  # rules for what a source may read, the caps, the secret policy and the preflight count are
  # the same on every surface. Until then `size`/`open_iterator` refuse, rather than answering
  # from data nobody read.
  #
  # Re-iterable and lazy in the way `PresetSource` is: resolved once, into a bounded in-memory
  # list (`PayloadFrom` caps its count and bytes), then served from it — a cluster-bomb inner
  # loop re-iterates a set many times and must not re-read the project each time.
  class ProjectSource < PayloadSource
    getter spec : PayloadFrom::Spec
    getter report : PayloadFrom::Report? = nil

    def initialize(@spec : PayloadFrom::Spec)
      @resolved = nil.as(InlineList?)
    end

    # This source under a run-wide policy — the surfaces parse their descriptors as they meet
    # them and fill the shared `--payload-from-*` knobs after, so the policy is applied once
    # everything is known.
    def with_policy(policy : PayloadFrom::Policy) : ProjectSource
      ProjectSource.new(@spec.apply(policy))
    end

    # Read the project. Idempotent. An EMPTY answer is refused: a Fuzzer set with no values
    # sends no requests, exits clean, and reads as "nothing there" — the report says why
    # instead (no flows matched, nothing of that kind in them, everything withheld as sensitive).
    def resolve!(store : Store, *, drain_fts : Bool = true, stop : -> Bool = -> { false }) : PayloadFrom::Report
      if (r = @report) && @resolved
        return r
      end
      resolved = PayloadFrom.resolve(store, @spec, drain_fts: drain_fts, stop: stop)
      if resolved.values.empty?
        raise PayloadFrom::Error.new("payload source produced no values — #{resolved.report.summary}")
      end
      @report = resolved.report
      @resolved = InlineList.new(resolved.values)
      resolved.report
    end

    def size : Int64?
      resolved.size
    end

    def open_iterator : SetIterator
      resolved.open_iterator
    end

    private def resolved : InlineList
      @resolved || raise PayloadFrom::Error.new(
        "payload source #{@spec.label.inspect} was never resolved — the plan builder reads the project for it")
    end
  end
end
