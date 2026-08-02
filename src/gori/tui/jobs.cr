module Gori::Tui
  # Registry of background jobs for the bottom-bar activity indicator (and, on finish,
  # notifications). The FIRST consumer is the Miner, but it's generic — any long-running
  # feature (scans, big repeaters) can register a job.
  #
  # INVARIANT: mutated ONLY on the main fiber, from the run loop's controller `drain_*`
  # methods. Background engine fibers never touch this; they push results through a
  # Channel the controller drains. So there are NO locks. Ephemeral per open project
  # (a fresh Runner is built per project), like repeater results.
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
    KIND_LABELS = {:miner => "mining", :scan => "scanning", :fuzz => "fuzzing", :discover => "discovering", :minimize => "minimizing", :sequence => "sequencing", :oast => "listening"}

    CAP = 50 # cap finished jobs kept (running ones are never pruned)

    # Kinds `active_summary` names before the tail collapses to "+N more". A hard bound,
    # not a nicety: `ConfirmDialog` clamps its card at 60 columns and ellipsises anything
    # wider, and the line it ate first was the exit confirm's own verb. Two named kinds
    # plus the tail is 41 cells at the worst count this registry can hold (CAP), three is
    # 46 — both inside the 54 a card line gets. Only the 4th kind onward collapses, so the
    # ordinary one- and two-engine cases read in full.
    SUMMARY_KINDS = 2

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
      return unless j.running? # first terminal state wins: an engine that emits ErrorEvent
      #                          then a trailing DoneEvent must stay :error, not flip to :done
      j.state = state
      j.note = summary if summary
    end

    # True once a job has been finished with :error — lets a controller's DoneEvent handler
    # skip its success side effects (log/notification/status) when an ErrorEvent already fired.
    def errored?(id : Int32) : Bool
      (j = find(id)) ? j.state == :error : false
    end

    def active : Array(Job)
      @jobs.select(&.running?)
    end

    def any_active? : Bool
      @jobs.any?(&.running?)
    end

    # The live jobs per kind, for an EXIT prompt: "discovering 1 · fuzzing 2". nil when
    # nothing is active, so a caller can keep its no-jobs wording byte-identical rather
    # than growing a "0 jobs" clause. Shares KIND_LABELS with activity_label so the prompt
    # names the work exactly as the status-bar chip already does.
    #
    # Unlike the chip it never collapses to "jobs:N": an exit prompt is the one place the
    # operator has to decide with, and "leaving stops them" is only actionable if it says
    # WHAT it is stopping. The inventory alone — the SENTENCE around it belongs to the
    # caller, which is also what keeps each line inside ConfirmDialog's 60-column card.
    def active_summary : String?
      a = active
      return nil if a.empty?
      parts = a.group_by(&.kind).map { |kind, js| "#{KIND_LABELS.fetch(kind, "jobs")} #{js.size}" }
      return parts.join(" · ") if parts.size <= SUMMARY_KINDS + 1
      "#{parts.first(SUMMARY_KINDS).join(" · ")} · +#{parts.size - SUMMARY_KINDS} more"
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
