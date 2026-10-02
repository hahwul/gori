require "json"

module Gori
  module MCP
    class Tools
      # --- unified async job management (list/get/stop across fuzz + mine) -----

      @[Tool("list_jobs", gated: true, read_only: true, permission: "send")]
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
                    j.field "requests", f.requests
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

      # Each async kind's id prefix (`fuzz_start` mints `fz_1`, `mine_start` `mn_2`, …) — the
      # same dispatch `get_job` does on the maps, spelled for an id no map holds any more.
      JOB_ID_PREFIXES = {"fz_" => "fuzz", "mn_" => "mine", "ds_" => "discover",
                         "sq_" => "sequence", "az_" => "authorize"}

      # The kind of job `id` names: the map that holds it, else its prefix, else nil.
      private def job_kind_of(id : String) : String?
        return "fuzz" if @jobs.has_key?(id)
        return "mine" if @mine_jobs.has_key?(id)
        return "discover" if @discover_jobs.has_key?(id)
        return "sequence" if @sequence_jobs.has_key?(id)
        return "authorize" if @authorize_jobs.has_key?(id)
        JOB_ID_PREFIXES.find { |prefix, _| id.starts_with?(prefix) }.try(&.[1])
      end

      # The NOT_FOUND for a `<kind>_<verb>` call whose id this kind's map does not hold. When
      # the id names ANOTHER kind — a mine id handed to fuzz_results, the mistake a caller
      # polling several jobs makes — say which tool reads it, instead of "no fuzz job mn_2"
      # about a job that exists one tool over.
      private def job_not_found(id : String, kind : String, verb : String) : Result
        other = job_kind_of(id)
        if other && other != kind
          return err("no #{kind} job #{id} — #{id} is a #{other} job: use #{other}_#{verb} " \
                     "(or get_job / stop_job, which take any kind)", "NOT_FOUND",
            field: "job_id", details: JSON.parse({"job_kind" => other}.to_json))
        end
        not_found("no #{kind} job #{id}")
      end

      # The `kind` job `job_id` names in `jobs`, or the error Result the caller returns as-is.
      # `missing_field` is the field a missing `job_id` refusal names: only authorize names it.
      private def lookup_job(h, jobs : Hash(String, T), kind : String, verb : String,
                             missing_field : String? = nil) : T | Result forall T
        id = str(h, "job_id")
        return err("missing required 'job_id'", "INVALID_ARGUMENT", field: missing_field) if id.nil? || id.empty?
        job = jobs[id]?
        return job_not_found(id, kind, verb) unless job
        job_project_mismatch(job) || job
      end

      # A job started before a switch_project is still LISTED (so an agent can see why an id
      # it remembers now refuses), but flagged — its *_results/*_status read PROJECT_CHANGED.
      private def emit_job_project(j : JSON::Builder, job : Job) : Nil
        return if job.db_path == @db_path
        j.field "project_changed", true
        j.field "job_db_path", job.db_path
      end

      # Unified status for a fuzz, mine, discover, sequence, or authorize job (dispatch by the
      # id prefix), so a caller polling many jobs needs one tool. Delegates to the per-engine status
      # serializers, which already carry counts/audit/incomplete_reason.
      @[Tool("get_job", gated: true, read_only: true, permission: "send")]
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
      @[Tool("stop_job", gated: true, agent_action: true, permission: "send")]
      private def stop_job(h) : Result
        id = str(h, "job_id")
        return err("missing required 'job_id'", "INVALID_ARGUMENT", field: "job_id") if id.nil? || id.empty?
        job = @jobs[id]? || @mine_jobs[id]? || @discover_jobs[id]? || @sequence_jobs[id]? || @authorize_jobs[id]?
        return not_found("no job #{id}") unless job
        if mismatch = job_project_mismatch(job)
          return mismatch
        end
        # Both read BEFORE the stop: `job.stop` is irreversible, and an argument refused after
        # it tells the caller its call FAILED while the job is already stopping — so an agent
        # concludes the run is still going and keeps polling a job nothing will restart.
        wait = bool_arg(h, "wait", false)
        budget = optional_int_arg(h, "wait_timeout_ms").try(&.clamp(1_i64, 60_000_i64)) || 10_000_i64
        return emit_stop_result(job, already_finished: true) unless request_stop(job)
        waited_out = false
        if wait
          deadline = Time.utc.to_unix_ms + budget
          while job.status == :running
            if Time.utc.to_unix_ms >= deadline
              waited_out = true
              break
            end
            sleep 20.milliseconds
          end
        end
        emit_stop_result(job, waited_out)
      end

      # `job.stop` plus the honest answer, for the five per-kind stop tools
      # (fuzz_stop / mine_stop / discover_stop / sequence_stop / authorize_stop).
      #
      # Each of those used to hard-code `status: "stopping"` without ever reading the job
      # back — a state a run that had already reached `done` / `budget_exhausted`, or that an
      # earlier call stopped, is not in and will never enter. An agent reads that as "I
      # aborted a run that was in flight" and reports a COMPLETE run as cancelled, or its
      # results as partial. `stop_job` has always re-read the status; this is the same read,
      # so all six stop surfaces now answer the same way.
      private def stop_and_report(job : Job) : Result
        emit_stop_result(job, already_finished: !request_stop(job))
      end

      # Ask a RUNNING job to stop, and answer whether it was running. A job that already
      # reached a terminal state is left alone: `job.stop` stamps `stop_requested_at`, so
      # stopping a finished run used to report `stop_requested: true` with a request time
      # LATER than `stopped_at` — a stop that "happened" after the run it claims to have
      # ended. The reply then says `already_finished` instead (`emit_stop_result`).
      private def request_stop(job : Job) : Bool
        return false unless job.status == :running
        job.stop
        true
      end

      # The stop reply itself, shared by `stop_job` (which may have waited first) and the
      # five per-kind tools. Read AFTER the stop and any wait, never assumed.
      private def emit_stop_result(job : Job, waited_out : Bool = false, *, already_finished : Bool = false) : Result
        status = job.status.to_s
        stopped_at = job.ended_at_ms
        requested = job.stop_requested_at_ms
        Result.new(JSON.build do |j|
          j.object do
            j.field "job_id", job.id
            j.field "status", status
            # Whether a stop was ever asked of this run — false when it ended on its own and
            # this call found it over. A repeat stop of a run an earlier call stopped reads true.
            j.field "stop_requested", !requested.nil?
            j.field "stopped", status != "running"
            # This call found the run already terminal and changed nothing.
            j.field "already_finished", true if already_finished
            j.field "timed_out", true if waited_out
            if sr = requested
              j.field "stop_requested_at", sr
            end
            j.field "stopped_at", stopped_at
          end
        end)
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
