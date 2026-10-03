require "json"
require "../../store"
require "../serialize"

module Gori
  module MCP
    class Tools
      # Permanent saved-run readers remain available in --read-only mode. Only deletion is an
      # action; live fuzz_start/status/results keep their existing action gate.
      FUZZ_RUNS_LIMIT = PageLimit.new(50, 200)

      @[Tool("list_fuzz_runs")]
      private def list_fuzz_runs(h) : Result
        pg = page_args(h, FUZZ_RUNS_LIMIT)
        session_id = optional_int_arg(h, "session_id")
        return err("session_id must be positive", "INVALID_ARGUMENT", field: "session_id") if session_id && session_id <= 0

        runs = store.fuzz_runs(session_id, pg.limit, pg.offset)
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
            emit_page(j, pg, runs.size, total, "total_available")
          end
        end)
      end

      # Metrics rows, and the smaller page a row carrying its request/response BLOBs gets.
      FUZZ_RUN_ROWS_LIMIT         = PageLimit.new(100, 1000)
      FUZZ_RUN_CONTENT_ROWS_LIMIT = PageLimit.new(25, 25)

      @[Tool("get_fuzz_run")]
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
        caps = SavedFuzzCaps.new(include_content, include_sensitive, body_cap, head_cap, message_source_cap)
        # `clusters` / `cluster` (#1351): a cluster page, or that cluster's members.
        get_fuzz_run_clusters(run, h, caps).try { |clustered| return clustered }
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

        # Content rows retain multiple request/response BLOBs and are deliberately capped at
        # 25 per response. Metrics can page farther, but still use the scalar Store projection.
        pg = page_args(h, include_content ? FUZZ_RUN_CONTENT_ROWS_LIMIT : FUZZ_RUN_ROWS_LIMIT)
        matched_only = bool_arg(h, "matched_only", false)
        total = store.fuzz_result_count(run_id, matched_only)
        returned = 0
        Result.new(JSON.build do |j|
          j.object do
            j.field("run") { Serialize.saved_fuzz_run(j, run, store.fuzz_result_count(run_id)) }
            j.field("results") do
              j.array do
                if include_content
                  store.each_fuzz_result_preview_page(run_id, pg.limit, pg.offset,
                    message_source_cap, head_cap + 1, Serialize::SAVED_SOURCE_BYTES,
                    message_source_cap, matched_only) do |preview|
                    Serialize.saved_fuzz_result(j, preview, include_sensitive, body_cap, head_cap)
                    returned += 1
                  end
                else
                  store.each_fuzz_result_summary_page(run_id, pg.limit, pg.offset, matched_only) do |row|
                    Serialize.saved_fuzz_result(j, row)
                    returned += 1
                  end
                end
              end
            end
            emit_page(j, pg, returned, total, "total_available")
            j.field "matched_only", matched_only
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

      @[Tool("delete_fuzz_run", gated: true, agent_action: true, permission: "write")]
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
          s.field "limit", limitprop("runs to return", FUZZ_RUNS_LIMIT)
        end

        tool j, "get_fuzz_run",
          "Get one permanent fuzz run and page every stored result. A run whose stop_on ended it (status condition_met) names the result it tripped on as run.stop_index — fetch that row with result_index; null when not recorded (a run saved before gori recorded it). Metrics, including result_index, use a scalar-only projection. Set include_content:true for at most 25 SQLite-capped content rows; max_head_bytes and max_body_bytes bound redacted previews before retained BLOBs enter the process. include_sensitive:true adds exact capped prefix bytes and never bypasses those limits." do |s|
          s.field "run_id", intprop("permanent run id"), required: true
          s.field "result_index", intprop("optional exact result index (zero-based)")
          s.field "offset", intprop("result rows to skip (default 0)")
          # Prose, not `limitprop`: three modes, three sets of numbers (see fuzz_results).
          s.field "limit", intprop("rows to return (default #{FUZZ_RUN_ROWS_LIMIT.default}, max #{FUZZ_RUN_ROWS_LIMIT.max}; " \
                                   "with include_content: default and max #{FUZZ_RUN_CONTENT_ROWS_LIMIT.max}; " \
                                   "a cluster listing: default #{FUZZ_CLUSTER_LIMIT.default}, max #{FUZZ_CLUSTER_LIMIT.max})")
          s.field "matched_only", boolprop("only matcher hits (default false; with clusters:true, only clusters holding a match)")
          s.field "clusters", boolprop("return one entry per RESPONSE SHAPE instead of rows (default false), aggregated over every stored row with the same fields fuzz_results{clusters} emits; paged by offset/limit (default 50, max 500). A run saved before shapes were recorded clusters by status/error/words/lines and marks those clusters approximate:true; a keep:interesting run clusters only the rows it kept (run.filtered).")
          s.field "cluster", strprop("a cluster id from clusters:true — page that cluster's member rows (the default row shape; include_content applies)")
          s.field "cluster_order", enumprop("order of clusters:true (default rare = smallest first; common; first)", Fuzz::Clusters::Order.names)
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
