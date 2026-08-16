require "json"

module Gori
  module MCP
    class Tools
      # --- unified async job management (list/get/stop across fuzz + mine) -----

      private def list_jobs : Result
        Result.new(JSON.build do |j|
          j.object do
            j.field "count", @jobs.size + @mine_jobs.size + @discover_jobs.size + @sequence_jobs.size + @authorize_jobs.size
            j.field("jobs") do
              j.array do
                @jobs.each_value do |f|
                  j.object do
                    j.field "job_id", f.id
                    j.field "kind", "fuzz"
                    j.field "status", f.status.to_s
                    j.field "sent", f.sent
                    j.field "total", f.total
                    j.field "matched", f.matched
                    j.field "target", Serialize.text(f.audit.target)
                    emit_job_project(j, f)
                  end
                end
                @mine_jobs.each_value do |m|
                  j.object do
                    j.field "job_id", m.id
                    j.field "kind", "mine"
                    j.field "status", m.status.to_s
                    j.field "sent", m.sent
                    j.field "names_total", m.total
                    j.field "found", m.found
                    j.field "target", Serialize.text(m.audit.target)
                    emit_job_project(j, m)
                  end
                end
                @discover_jobs.each_value do |d|
                  j.object do
                    j.field "job_id", d.id
                    j.field "kind", "discover"
                    j.field "status", d.status.to_s
                    j.field "sent", d.sent
                    j.field "found", d.found
                    j.field "target", Serialize.text(d.audit.target)
                    emit_job_project(j, d)
                  end
                end
                @sequence_jobs.each_value do |s|
                  j.object do
                    j.field "job_id", s.id
                    j.field "kind", "sequence"
                    j.field "status", s.status.to_s
                    j.field "goal", s.goal
                    j.field "collected", s.collected
                    j.field "target", Serialize.text(s.audit.target)
                    emit_job_project(j, s)
                  end
                end
                @authorize_jobs.each_value do |a|
                  j.object do
                    j.field "job_id", a.id
                    j.field "kind", "authorize"
                    j.field "status", a.status.to_s
                    j.field "sent", a.sent
                    j.field "requests_total", a.planned
                    j.field "requests_replayed", a.replayed
                    # The finding, on the ROW: a caller scanning its jobs must be able to see
                    # that one of them found a bypass without opening each one's results.
                    j.field "bypass_count", a.bypasses
                    j.field "target", Serialize.text(a.audit.target)
                    emit_job_project(j, a)
                  end
                end
              end
            end
          end
        end)
      end

      # A job started before a switch_project is still LISTED (so an agent can see why an id
      # it remembers now refuses), but flagged — its *_results/*_status read PROJECT_CHANGED.
      private def emit_job_project(j : JSON::Builder, job : FuzzJob | MineJob | DiscoverJob | SequenceJob | AuthorizeJob) : Nil
        return if job.db_path == @db_path
        j.field "project_changed", true
        j.field "job_db_path", job.db_path
      end

      # Unified status for a fuzz, mine, discover, sequence, or authorize job (dispatch by the
      # id prefix), so a caller polling many jobs needs one tool. Delegates to the per-engine status
      # serializers, which already carry counts/audit/incomplete_reason.
      private def get_job(h) : Result
        id = str(h, "job_id")
        return err("missing required 'job_id'", "INVALID_ARGUMENT", field: "job_id") if id.nil? || id.empty?
        if @jobs.has_key?(id)
          fuzz_status(h)
        elsif @mine_jobs.has_key?(id)
          mine_status(h)
        elsif @discover_jobs.has_key?(id)
          discover_status(h)
        elsif @sequence_jobs.has_key?(id)
          sequence_status(h)
        elsif @authorize_jobs.has_key?(id)
          authorize_status(h)
        else
          not_found("no job #{id}")
        end
      end

      # Stop a fuzz, mine, discover, sequence, or authorize job. With wait:true, blocks (yielding to the runner
      # fiber via sleep) until the job reaches a terminal state or wait_timeout_ms
      # elapses, so a caller can stop-and-confirm in one call instead of polling.
      private def stop_job(h) : Result
        id = str(h, "job_id")
        return err("missing required 'job_id'", "INVALID_ARGUMENT", field: "job_id") if id.nil? || id.empty?
        job = @jobs[id]? || @mine_jobs[id]? || @discover_jobs[id]? || @sequence_jobs[id]? || @authorize_jobs[id]?
        return not_found("no job #{id}") unless job
        if mismatch = job_project_mismatch(job)
          return mismatch
        end
        job.stop
        wait = bool_arg(h, "wait", false)
        waited_out = false
        if wait
          budget = int(h, "wait_timeout_ms").try(&.clamp(1_i64, 60_000_i64)) || 10_000_i64
          deadline = Time.utc.to_unix_ms + budget
          while job_running?(job)
            if Time.utc.to_unix_ms >= deadline
              waited_out = true
              break
            end
            sleep 20.milliseconds
          end
        end
        status, stopped_at = job_status_and_end(job)
        Result.new(JSON.build do |j|
          j.object do
            j.field "job_id", id
            j.field "status", status
            j.field "stop_requested", true
            j.field "stopped", status != "running"
            j.field "timed_out", true if waited_out
            if sr = job_stop_requested(job)
              j.field "stop_requested_at", sr
            end
            j.field "stopped_at", stopped_at
          end
        end)
      end

      private def job_running?(job : FuzzJob | MineJob | DiscoverJob | SequenceJob | AuthorizeJob) : Bool
        job.status == :running
      end

      private def job_status_and_end(job : FuzzJob | MineJob | DiscoverJob | SequenceJob | AuthorizeJob) : {String, Int64?}
        {job.status.to_s, job.ended_at_ms}
      end

      private def job_stop_requested(job : FuzzJob | MineJob | DiscoverJob | SequenceJob | AuthorizeJob) : Int64?
        job.stop_requested_at_ms
      end

      # The tools/list schemas for the job-control tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_jobs_tools(j : JSON::Builder) : Nil
        return unless @allow_actions

        tool j, "list_jobs",
          "List all fuzz, mine, discover, sequence, and authorize jobs this session started " \
          "(job_id, kind, status, counts, target) — one call to see everything in flight. " \
          "An authorize row carries bypass_count, so an access-control finding is visible here." { }

        tool j, "get_job",
          "Full status of a fuzz, mine, discover, sequence, or authorize job by id (dispatches " \
          "by the id prefix), so you can poll any job with one tool." do |s|
          s.field "job_id", strprop("a fuzz (fz_*), mine (mn_*), discover (ds_*), sequence (sq_*), or authorize (az_*) job id"), required: true
        end

        tool j, "stop_job",
          "Stop a fuzz, mine, discover, sequence, or authorize job. With wait:true, block until it reaches a terminal " \
          "state (or wait_timeout_ms elapses) and report the final status + stopped_at, " \
          "so stop-and-confirm is one call. Without wait, returns immediately (stop is async)." do |s|
          s.field "job_id", strprop("a fuzz (fz_*), mine (mn_*), discover (ds_*), sequence (sq_*), or authorize (az_*) job id"), required: true
          s.field "wait", boolprop("block until the job actually stops (default false)")
          s.field "wait_timeout_ms", intprop("max ms to wait when wait:true (default 10000, max 60000)")
        end
      end
    end
  end
end
