require "json"

module Gori
  module MCP
    class Tools
      # --- unified async job management (list/get/stop across fuzz + mine) -----

      private def list_jobs : Result
        Result.new(JSON.build do |j|
          j.object do
            j.field "count", @jobs.size + @mine_jobs.size + @discover_jobs.size + @sequence_jobs.size
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
                    j.field "target", f.audit.target
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
                    j.field "target", m.audit.target
                  end
                end
                @discover_jobs.each_value do |d|
                  j.object do
                    j.field "job_id", d.id
                    j.field "kind", "discover"
                    j.field "status", d.status.to_s
                    j.field "sent", d.sent
                    j.field "found", d.found
                    j.field "target", d.audit.target
                  end
                end
                @sequence_jobs.each_value do |s|
                  j.object do
                    j.field "job_id", s.id
                    j.field "kind", "sequence"
                    j.field "status", s.status.to_s
                    j.field "goal", s.goal
                    j.field "collected", s.collected
                    j.field "target", s.audit.target
                  end
                end
              end
            end
          end
        end)
      end

      # Unified status for a fuzz, mine, discover, or sequence job (dispatch by the id prefix),
      # so a caller polling many jobs needs one tool. Delegates to the per-engine status
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
        else
          not_found("no job #{id}")
        end
      end

      # Stop a fuzz, mine, discover, or sequence job. With wait:true, blocks (yielding to the runner
      # fiber via sleep) until the job reaches a terminal state or wait_timeout_ms
      # elapses, so a caller can stop-and-confirm in one call instead of polling.
      private def stop_job(h) : Result
        id = str(h, "job_id")
        return err("missing required 'job_id'", "INVALID_ARGUMENT", field: "job_id") if id.nil? || id.empty?
        job = @jobs[id]? || @mine_jobs[id]? || @discover_jobs[id]? || @sequence_jobs[id]?
        return not_found("no job #{id}") unless job
        job.stop
        wait = bool(h, "wait") || false
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

      private def job_running?(job : FuzzJob | MineJob | DiscoverJob | SequenceJob) : Bool
        job.status == :running
      end

      private def job_status_and_end(job : FuzzJob | MineJob | DiscoverJob | SequenceJob) : {String, Int64?}
        {job.status.to_s, job.ended_at_ms}
      end

      private def job_stop_requested(job : FuzzJob | MineJob | DiscoverJob | SequenceJob) : Int64?
        job.stop_requested_at_ms
      end
    end
  end
end
