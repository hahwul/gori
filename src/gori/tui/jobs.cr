module Gori::Tui
  # Registry of background jobs for the bottom-bar activity indicator (and, on finish,
  # notifications). The FIRST consumer is the Miner, but it's generic — any long-running
  # feature (scans, big replays) can register a job.
  #
  # INVARIANT: mutated ONLY on the main fiber, from the run loop's controller `drain_*`
  # methods. Background engine fibers never touch this; they push results through a
  # Channel the controller drains. So there are NO locks. Ephemeral per open project
  # (a fresh Runner is built per project), like replay results.
  class Jobs
    # An immutable "jump to result" target for a finished job's notification.
    record Goto, tab : Symbol, session_id : Int64? = nil

    # One tracked job. A CLASS (not a record): state/sent/total/note mutate in place
    # while it lives in @jobs, and we need a `running?` predicate.
    class Job
      getter id : Int32
      getter kind : Symbol  # :miner | :scan | … (generic)
      getter label : String # human label, e.g. "GET /api/x"
      getter goto : Goto?
      getter started_at : Time::Instant
      property state : Symbol # :running | :done | :error
      property sent : Int32?
      property total : Int32?
      property note : String? # short progress/summary, e.g. "3 found"

      def initialize(@id, @kind, @label, @goto = nil)
        @started_at = Time.instant
        @state = :running
      end

      def running? : Bool
        @state == :running
      end
    end

    # Per-kind gerund for the activity chip when exactly one kind is active. A Hash (not
    # a case) keeps activity_label flat; unknown kinds fall back to "jobs".
    KIND_LABELS = {:miner => "mining", :scan => "scanning", :fuzz => "fuzzing"}

    CAP = 50 # cap finished jobs kept (running ones are never pruned)

    def initialize
      @jobs = [] of Job
      @next_id = 0
    end

    def start(kind : Symbol, label : String, goto : Goto? = nil) : Int32
      id = (@next_id += 1)
      @jobs << Job.new(id, kind, label, goto)
      prune
      id
    end

    def progress(id : Int32, sent : Int32?, total : Int32?, note : String? = nil) : Nil
      return unless j = find(id)
      j.sent = sent
      j.total = total
      j.note = note if note
    end

    def finish(id : Int32, state : Symbol, summary : String? = nil) : Nil
      return unless j = find(id)
      j.state = state
      j.note = summary if summary
    end

    def active : Array(Job)
      @jobs.select(&.running?)
    end

    def any_active? : Bool
      @jobs.any?(&.running?)
    end

    # The status-bar chip text (the Runner prepends a spinner glyph). nil → no chip.
    # One active kind → "mining 2"; mixed kinds → "jobs:3".
    def activity_label : String?
      a = active
      return nil if a.empty?
      kinds = a.map(&.kind).uniq!
      return "jobs:#{a.size}" if kinds.size != 1
      "#{KIND_LABELS.fetch(kinds.first, "jobs")} #{a.size}"
    end

    private def find(id : Int32) : Job?
      @jobs.find { |j| j.id == id }
    end

    # Drop the oldest FINISHED jobs once over CAP (running ones are always kept).
    private def prune : Nil
      return if @jobs.size <= CAP
      excess = @jobs.size - CAP
      @jobs.reject(&.running?).first(excess).each { |j| @jobs.delete(j) }
    end
  end
end
