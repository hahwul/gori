require "./mode"
require "./issue"
require "./passive"
require "./active"
require "./event"
require "../store"
require "../scope"
require "../fuzz/engine"

module Gori
  module Prism
    # Orchestrates passive + active scanning. Owned by Session; runs two fibers off all hot
    # paths: a passive fiber draining flow-completion events (analyze → upsert issues) and a
    # single active-worker fiber that probes new in-scope flows for reflected params. The
    # store writer only does an extra non-blocking publish to feed us; the TUI render loop
    # is never touched. Single-threaded scheduler ⇒ plain ivars need no locks.
    class Analyzer
      ANALYZED_CAP    = 10_000     # bound the seen-flow set (memory plateaus on long runs)
      ACTIVE_SEEN_CAP =  5_000     # bound the active dedup set
      ACTIVE_QUEUE    =    128     # bounded active task queue (drop on overflow)
      ACTIVE_TIMEOUT  = 10.seconds # per-probe socket timeout

      getter events : Channel(Event)

      private record ActiveTask, rule : Active::Rule, plan : Active::Plan, detail : Store::FlowDetail

      def initialize(@store : Store, @scope : Scope, @input : Channel(Store::FlowEvent),
                     @mode : Mode, @verify_upstream : Bool)
        @analyzed = Set(Int64).new
        @active_seen = Set(String).new
        @active_jobs = Channel(ActiveTask).new(ACTIVE_QUEUE)
        @events = Channel(Event).new(256)
        @running = false
        @stopped = false
      end

      def mode : Mode
        @mode
      end

      # Update the live mode AND persist it to the project DB (single source of truth).
      def set_mode(m : Mode) : Nil
        @mode = m
        @store.set_prism_mode(m)
      end

      def start : Nil
        return if @running
        @running = true
        spawn(name: "gori-prism") { passive_loop }
        spawn(name: "gori-prism-active") { active_loop }
      end

      # Winds the analyzer down BEFORE the store/channels close: stop accepting active work,
      # close the active queue so its worker exits, and close the input feed so the passive
      # fiber unblocks and exits (this analyzer is the channel's only consumer; the store's
      # publish side is non-blocking and guards against the close). Idempotent.
      def stop : Nil
        @stopped = true
        @input.close
        @active_jobs.close
      rescue Channel::ClosedError
      end

      # --- passive fiber ----------------------------------------------------------------

      private def passive_loop : Nil
        loop do
          ev = @input.receive?
          break if ev.nil?
          next if @stopped
          next unless @mode.scanning?
          next unless ev.kind == :updated # analyze when the response side exists
          next if @analyzed.includes?(ev.id)
          begin
            detail = @store.get_flow(ev.id)
            next unless detail
            @analyzed << ev.id
            trim(@analyzed, ANALYZED_CAP)
            process(detail)
          rescue DB::Error | SQLite3::Exception
            # A transient store error (e.g. SQLITE_BUSY) must NOT kill the scanner for the rest
            # of the session — skip this flow and keep draining. On real shutdown the input
            # channel is closed, so the next receive? returns nil and the loop exits cleanly.
            next
          end
        end
      rescue Channel::ClosedError
        # input closed during shutdown — exit quietly
      end

      private def process(detail : Store::FlowDetail) : Nil
        detections = Passive.analyze(detail)
        unless detections.empty?
          detections.each { |d| @store.upsert_prism_issue(d) }
          emit(IssueEvent.new(detail.row.host))
        end
        maybe_enqueue_active(detail)
      rescue ex : DB::Error | SQLite3::Exception
        raise ex # bubble to passive_loop's per-flow rescue (skip this flow, keep scanning)
      rescue
        # a single flow's analysis blew up — skip it, keep scanning the rest
      end

      private def maybe_enqueue_active(detail : Store::FlowDetail) : Nil
        return if @stopped
        return unless @mode.active?
        row = detail.row
        url = "#{row.scheme}://#{row.host}#{row.target}"
        # Active probes ONLY configured+enabled in-scope hosts (in_scope_url? is permissive
        # when scope is inactive, so gate on active? first) — the user's "in-scope only" rule.
        return unless @scope.active? && @scope.in_scope_url?(url, row.host)
        Active::RULES.each { |rule| enqueue_probe(rule, detail) }
      rescue Channel::ClosedError
      end

      private def enqueue_probe(rule : Active::Rule, detail : Store::FlowDetail) : Nil
        plan = rule.plan(detail)
        return unless plan
        return if @active_seen.includes?(plan.dedup_key)
        select
        when @active_jobs.send(ActiveTask.new(rule, plan, detail))
          # Record the dedup key ONLY once the task is actually queued, so a target dropped on
          # a full queue is re-probed when its next flow arrives (not suppressed forever).
          @active_seen << plan.dedup_key
          trim(@active_seen, ACTIVE_SEEN_CAP)
        else
          # queue full — drop without recording; the next matching flow re-attempts.
        end
      end

      # --- active fiber -----------------------------------------------------------------

      private def active_loop : Nil
        loop do
          task = @active_jobs.receive?
          break if task.nil?
          run_active(task)
        end
      rescue Channel::ClosedError
      end

      private def run_active(task : ActiveTask) : Nil
        return if @stopped # don't fire outbound probes while winding down
        row = task.detail.row
        origin = Fuzz::Origin.new(row.scheme, row.host, row.port)
        http2 = task.detail.http_version.starts_with?("HTTP/2")
        sender = Fuzz::Sender.new(origin, http2, @verify_upstream, timeout: ACTIVE_TIMEOUT)
        result = sender.send(task.plan.request)
        detections = task.rule.detections(task.plan, result, task.detail)
        return if detections.empty?
        detections.each { |d| @store.upsert_prism_issue(d) }
        summary = detections.first.evidence
        emit(IssueEvent.new(row.host, "reflected param on #{row.host} (#{summary})"))
      rescue DB::Error | SQLite3::Exception
        # store closing — stop quietly (the worker will exit when the queue closes)
      rescue ex
        emit(ErrorEvent.new("Prism active scan: #{ex.message}"))
      end

      # --- helpers ----------------------------------------------------------------------

      # Non-blocking best-effort emit (mirrors Store#publish): drop when no drainer / full so
      # a headless run never stalls the analyzer.
      private def emit(event : Event) : Nil
        select
        when @events.send(event)
        else
        end
      rescue Channel::ClosedError
      end

      # Bound a seen-set to `cap` by dropping its oldest entries (Set keeps insertion order).
      private def trim(set : Set(Int64), cap : Int32) : Nil
        return if set.size <= cap
        set.first(set.size - cap).each { |x| set.delete(x) }
      end

      private def trim(set : Set(String), cap : Int32) : Nil
        return if set.size <= cap
        set.first(set.size - cap).each { |x| set.delete(x) }
      end
    end
  end
end
