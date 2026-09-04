require "json"
require "../../store"
require "../serialize"

module Gori
  module MCP
    class Tools
      # Permanent saved-run readers remain available in --read-only mode. Only deletion is an
      # action; live fuzz_start/status/results keep their existing action gate.
      private def list_fuzz_runs(h) : Result
        req_off = optional_int_arg(h, "offset")
        req_lim = optional_int_arg(h, "limit")
        offset = clamp_nonneg(req_off)
        limit = clamp(req_lim, 50, 200)
        session_id = optional_int_arg(h, "session_id")
        return err("session_id must be positive", "INVALID_ARGUMENT", field: "session_id") if session_id && session_id <= 0

        runs = store.fuzz_runs(session_id, limit, offset)
        counts = store.fuzz_result_counts(runs.map(&.id))
        total = store.fuzz_run_count(session_id)
        Result.new(JSON.build do |j|
          j.object do
            j.field("runs") do
              j.array do
                runs.each do |run|
                  Serialize.saved_fuzz_run(j, run, counts[run.id]? || 0_i64)
                end
              end
            end
            j.field "returned", runs.size
            j.field "offset", offset
            j.field "limit", limit
            emit_clamp(j, req_off, offset, req_lim, limit)
            j.field "total_available", total
            j.field "has_more", offset.to_i64 + runs.size < total
          end
        end)
      end

      private def get_fuzz_run(h) : Result
        run_id = optional_int_arg(h, "run_id")
        return err("missing required 'run_id'", "INVALID_ARGUMENT", field: "run_id") unless run_id
        return err("run_id must be positive", "INVALID_ARGUMENT", field: "run_id") if run_id <= 0
        run = store.get_fuzz_run(run_id)
        return not_found("no saved fuzz run #{run_id}") unless run

        include_content = bool_arg(h, "include_content", false)
        include_sensitive = bool_arg(h, "include_sensitive", false)
        body_cap = clamp(optional_int_arg(h, "max_body_bytes"), BODY_PREVIEW_BYTES, Serialize::MAX_TEXT)
        head_cap = clamp(optional_int_arg(h, "max_head_bytes"),
          Serialize::SAVED_HEAD_PREVIEW_BYTES, Serialize::MAX_TEXT)
        message_source_cap = head_cap + Serialize::SAVED_SOURCE_BYTES + 4
        if idx = optional_int_arg(h, "result_index")
          return err("result_index must be non-negative", "INVALID_ARGUMENT", field: "result_index") if idx < 0
          if include_content
            preview = store.get_fuzz_result_preview(run_id, idx, message_source_cap,
              head_cap + 1, Serialize::SAVED_SOURCE_BYTES, message_source_cap)
            return not_found("no result #{idx} in saved fuzz run #{run_id}") unless preview
            return saved_fuzz_result_detail(run, preview, include_sensitive, body_cap, head_cap)
          end
          row = store.get_fuzz_result_summary(run_id, idx)
          return not_found("no result #{idx} in saved fuzz run #{run_id}") unless row
          return saved_fuzz_result_detail(run, row)
        end

        req_off = optional_int_arg(h, "offset")
        req_lim = optional_int_arg(h, "limit")
        offset = clamp_nonneg(req_off)
        # Content rows retain multiple request/response BLOBs and are deliberately capped at
        # 25 per response. Metrics can page farther, but still use the scalar Store projection.
        limit = clamp(req_lim, include_content ? 25 : 100,
          include_content ? 25 : 1000)
        matched_only = bool_arg(h, "matched_only", false)
        total = store.fuzz_result_count(run_id, matched_only)
        returned = 0
        Result.new(JSON.build do |j|
          j.object do
            j.field("run") { Serialize.saved_fuzz_run(j, run, store.fuzz_result_count(run_id)) }
            j.field("results") do
              j.array do
                if include_content
                  store.each_fuzz_result_preview_page(run_id, limit, offset,
                    message_source_cap, head_cap + 1, Serialize::SAVED_SOURCE_BYTES,
                    message_source_cap, matched_only) do |preview|
                    Serialize.saved_fuzz_result(j, preview, include_sensitive, body_cap, head_cap)
                    returned += 1
                  end
                else
                  store.each_fuzz_result_summary_page(run_id, limit, offset, matched_only) do |row|
                    Serialize.saved_fuzz_result(j, row)
                    returned += 1
                  end
                end
              end
            end
            j.field "returned", returned
            j.field "offset", offset
            j.field "total_available", total
            j.field "matched_only", matched_only
            j.field "limit", limit
            emit_clamp(j, req_off, offset, req_lim, limit)
            j.field "has_more", offset.to_i64 + returned < total
          end
        end)
      end

      private def saved_fuzz_result_detail(run : Store::FuzzRunRecord,
                                           row : Store::FuzzResultRecord) : Result
        Result.new(JSON.build do |j|
          j.object do
            j.field("run") { Serialize.saved_fuzz_run(j, run, store.fuzz_result_count(run.id)) }
            j.field("result") { Serialize.saved_fuzz_result(j, row) }
          end
        end)
      end

      private def saved_fuzz_result_detail(run : Store::FuzzRunRecord,
                                           preview : Store::FuzzResultPreview,
                                           include_sensitive : Bool,
                                           body_cap : Int32, head_cap : Int32) : Result
        Result.new(JSON.build do |j|
          j.object do
            j.field("run") { Serialize.saved_fuzz_run(j, run, store.fuzz_result_count(run.id)) }
            j.field("result") do
              Serialize.saved_fuzz_result(j, preview, include_sensitive, body_cap, head_cap)
            end
          end
        end)
      end

      private def delete_fuzz_run(h) : Result
        run_id = optional_int_arg(h, "run_id")
        return err("missing required 'run_id'", "INVALID_ARGUMENT", field: "run_id") unless run_id
        return err("run_id must be positive", "INVALID_ARGUMENT", field: "run_id") if run_id <= 0
        run = store.get_fuzz_run(run_id)
        return not_found("no saved fuzz run #{run_id}") unless run
        force_stale = bool_arg(h, "force_stale", false)
        if @jobs.each_value.any? { |job| job.status == :running && job.persistence.try(&.run_id) == run_id }
          return busy("saved fuzz run #{run_id} is still being written by this server; stop/wait for its job first")
        end
        deleted = store.delete_fuzz_run_result(run_id, allow_active: force_stale)
        case deleted.status
        in Store::FuzzRunDeleteStatus::Deleted
          Result.new({deleted: true, run_id: run_id,
                      deleted_results: deleted.deleted_results}.to_json)
        in Store::FuzzRunDeleteStatus::NotFound
          not_found("no saved fuzz run #{run_id}")
        in Store::FuzzRunDeleteStatus::Active
          busy("saved fuzz run #{run_id} is still #{run.status}; if its writer crashed, retry " \
               "with force_stale:true (never use it while another gori is saving)")
        in Store::FuzzRunDeleteStatus::WriteFailed
          busy("saved fuzz run #{run_id} was not deleted (project busy)")
        end
      end

      private def list_fuzz_run_tools(j : JSON::Builder) : Nil
        tool j, "list_fuzz_runs",
          "List permanent fuzz runs in the current project, newest first. These survive MCP jobs and process restarts." do |s|
          s.field "session_id", intprop("optional TUI fuzz-session id filter")
          s.field "offset", intprop("runs to skip (default 0)")
          s.field "limit", intprop("runs to return (default 50, max 200)")
        end

        tool j, "get_fuzz_run",
          "Get one permanent fuzz run and page every stored result. Metrics, including result_index, use a scalar-only projection. Set include_content:true for at most 25 SQLite-capped content rows; max_head_bytes and max_body_bytes bound redacted previews before retained BLOBs enter the process. include_sensitive:true adds exact capped prefix bytes and never bypasses those limits." do |s|
          s.field "run_id", intprop("permanent run id"), required: true
          s.field "result_index", intprop("optional exact result index (zero-based)")
          s.field "offset", intprop("result rows to skip (default 0)")
          s.field "limit", intprop("rows to return (default 100 metrics / 25 with content; max 1000 / 25)")
          s.field "matched_only", boolprop("only matcher hits (default false)")
          s.field "include_content", boolprop("include request/wire/response content summaries (default false)")
          s.field "include_sensitive", boolprop("include unredacted exact raw request/wire/head base64 when content is requested (default false)")
          s.field "max_body_bytes", intprop("decoded body/raw inline cap (default 2048, max #{Serialize::MAX_TEXT})")
          s.field "max_head_bytes", intprop("request/response head inline cap (default #{Serialize::SAVED_HEAD_PREVIEW_BYTES}, max #{Serialize::MAX_TEXT})")
        end

        return unless @allow_actions
        tool j, "delete_fuzz_run",
          "Delete one terminal permanent fuzz run and all of its stored results. Refuses a live writer. force_stale:true recovers a running/saving row left by a crashed process; never use it while another gori is saving." do |s|
          s.field "run_id", intprop("permanent run id"), required: true
          s.field "force_stale", boolprop("delete a running/saving row believed to have no live writer (default false)")
        end
      end
    end
  end
end
