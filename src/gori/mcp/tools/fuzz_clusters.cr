require "json"
require "../../fuzz"
require "../serialize"

module Gori
  module MCP
    class Tools
      # Response-shape clusters (issue #1351) for `fuzz_results` (a live job) and
      # `get_fuzz_run` (a saved run). Both group through `Fuzz::Clusters` — the aggregator the
      # TUI and `gori run fuzz show --clusters` use — and emit it with `Fuzz::Clusters.emit`,
      # so the three surfaces cannot come to disagree about what a cluster is.
      #
      # Two opt-in modes on each tool, beside the unchanged row mode:
      #   * `clusters: true`  — one entry per shape, paged with the same offset/limit contract;
      #   * `cluster: "<id>"` — that shape's member ROWS, in the tool's existing row shape.

      # A cluster request, parsed and validated once for both tools.
      private record FuzzClusterArgs, summary : Bool, id : Int64?, order : Fuzz::Clusters::Order do
        def requested? : Bool
          summary || !id.nil?
        end
      end

      private def fuzz_cluster_args(h) : FuzzClusterArgs | Result
        summary = bool_arg(h, "clusters", false)
        raw_id = str(h, "cluster").try(&.presence)
        order = closed_filter(h, "cluster_order", Fuzz::Clusters::Order.names)
        return order if order.is_a?(Result)
        id = nil.as(Int64?)
        if text = raw_id
          id = Fuzz::Shape.parse_hex?(text)
          return err("invalid \"cluster\" #{text.inspect} (expected a 16-hex-digit cluster id from clusters:true)",
            "INVALID_ARGUMENT", field: "cluster") unless id
        end
        if summary && id
          return err("pass clusters:true for the summary or cluster:\"<id>\" for one cluster's members, not both",
            "INVALID_ARGUMENT", field: "cluster")
        end
        FuzzClusterArgs.new(summary, id,
          Fuzz::Clusters::Order.parse?(order) || Fuzz::Clusters::Order::Rare)
      end

      # The cluster list page. `matched_only` keeps the clusters holding at least one matcher hit.
      private def emit_fuzz_cluster_page(j : JSON::Builder, clusters : Fuzz::Clusters,
                                         args : FuzzClusterArgs, matched_only : Bool,
                                         req_off : Int64?, req_lim : Int64?,
                                         &row : Fuzz::Result ->) : Nil
        offset = clamp_nonneg(req_off)
        limit = clamp(req_lim, 50, 500)
        list = clusters.sorted(args.order)
        list.select! { |c| c.matched > 0 } if matched_only
        last = offset < list.size ? Math.min(offset + limit, list.size) : offset
        j.field("clusters") do
          j.array do
            (offset...last).each do |k|
              Fuzz::Clusters.emit(j, list[k], ->(t : String) { Serialize.text(t) }) { |rep| row.call(rep) }
            end
          end
        end
        j.field "cluster_order", args.order.label
        j.field "returned", last - offset
        j.field "offset", offset
        j.field "limit", limit
        emit_clamp(j, req_off, offset, req_lim, limit)
        j.field "total_available", list.size
        j.field "has_more", last < list.size
        j.field "page_complete", last >= list.size
        j.field "matched_only", matched_only
        Fuzz::Clusters.emit_summary(j, clusters)
      end

      # `fuzz_results{clusters|cluster}` on a live job. The job's aggregator saw EVERY result;
      # the row cache behind `fuzz_results` keeps only `interesting?` rows, so a cluster of
      # ordinary answers may have no member rows here at all — the page says so, and points at
      # the saved run that does keep them.
      private def fuzz_results_clusters(fjob : FuzzJob, h, args : FuzzClusterArgs) : Result
        matched_only = bool_arg(h, "matched_only", false)
        req_off = optional_int_arg(h, "offset")
        req_lim = optional_int_arg(h, "limit")
        rows = fjob.results
        if id = args.id
          cluster = fjob.clusters[id]?
          return not_found("no cluster #{Fuzz::Shape.hex(id)} in fuzz job #{fjob.id}") unless cluster
          picked = (0...rows.size).select { |i| Fuzz::Clusters.key(rows[i])[0] == id }
          picked.select! { |i| rows[i].matched? } if matched_only
          offset = clamp_nonneg(req_off)
          limit = clamp(req_lim, 100, 1000)
          last = offset < picked.size ? Math.min(offset + limit, picked.size) : offset
          page = picked[offset...last]? || [] of Int32
          flow_ids = validated_fuzz_flow_ids(fjob, page)
          return Result.new(JSON.build do |j|
            j.object do
              j.field("cluster") do
                Fuzz::Clusters.emit(j, cluster, ->(t : String) { Serialize.text(t) }) do |rep|
                  Serialize.fuzz_result(j, rep)
                end
              end
              j.field("results") do
                j.array { page.each_with_index { |pos, k| Serialize.fuzz_result(j, rows[pos], flow_ids[k]) } }
              end
              j.field "returned", page.size
              j.field "offset", offset
              j.field "limit", limit
              emit_clamp(j, req_off, offset, req_lim, limit)
              j.field "total_available", picked.size
              j.field "has_more", last < picked.size
              j.field "matched_only", matched_only
              # Members this job's row cache holds, against the cluster's whole count.
              j.field "members_retained", rows.count { |r| Fuzz::Clusters.key(r)[0] == id }
              if cluster.count > picked.size && !matched_only
                j.field "members_note", fuzz_members_note(fjob)
              end
              j.field "job_complete", fjob.status != :running
              j.field "incomplete_reason", incomplete_reason(fjob.status)
              emit_fuzz_save_state(j, fjob)
            end
          end)
        end

        # The representative's row from the cache when it is there, so its flow_id (the
        # History evidence) rides along; the cluster's metrics-only copy otherwise.
        cached = {} of Int64 => Int32
        rows.each_with_index { |r, i| cached[r.index] = i }
        Result.new(JSON.build do |j|
          j.object do
            emit_fuzz_cluster_page(j, fjob.clusters, args, matched_only, req_off, req_lim) do |rep|
              if pos = cached[rep.index]?
                Serialize.fuzz_result(j, rows[pos], validated_fuzz_flow_ids(fjob, [pos]).first)
              else
                Serialize.fuzz_result(j, rep)
              end
            end
            j.field "job_complete", fjob.status != :running
            j.field "incomplete_reason", incomplete_reason(fjob.status)
            j.field "results_truncated", fjob.truncated?
            emit_fuzz_save_state(j, fjob)
          end
        end)
      end

      private def fuzz_members_note(fjob : FuzzJob) : String
        where = fjob.persistence.try { |p| "get_fuzz_run{run_id:#{p.run_id}, cluster} pages every member" } ||
                "start the job with save_results:true to keep every member row"
        "this live job keeps only interesting rows (matched, errored, re-sent, truncated); " \
        "sample_indices names the lowest members, and #{where}"
      end

      # The content knobs `get_fuzz_run` already parsed, handed on whole.
      private record SavedFuzzCaps, include_content : Bool, include_sensitive : Bool,
        body_cap : Int32, head_cap : Int32, message_source_cap : Int32

      # `get_fuzz_run{clusters|cluster}`. One keyset-paged scalar stream of the run's rows
      # feeds the aggregator (and, for `cluster`, picks the page's members in the same pass),
      # so neither mode holds more than one entry per shape plus one page of rows. nil when the
      # call asked for neither, so `get_fuzz_run` goes on to its row modes.
      private def get_fuzz_run_clusters(run : Store::FuzzRunRecord, h, caps : SavedFuzzCaps) : Result?
        args = fuzz_cluster_args(h)
        return args if args.is_a?(Result)
        return nil unless args.requested?
        if present?(h, "result_index")
          return err("result_index names one row; drop it to page clusters or a cluster's members",
            "INVALID_ARGUMENT", field: "result_index")
        end
        if id = args.id
          return saved_fuzz_cluster_members(run, h, id, caps)
        end
        clusters = Fuzz::Clusters.new
        store.each_fuzz_result_summary(run.id) { |rec| clusters.add(Fuzz::Persistence.result(rec)) }
        Result.new(JSON.build do |j|
          j.object do
            j.field("run") { Serialize.saved_fuzz_run(j, run, store.fuzz_result_count(run.id)) }
            emit_fuzz_cluster_page(j, clusters, args, bool_arg(h, "matched_only", false),
              optional_int_arg(h, "offset"), optional_int_arg(h, "limit")) do |rep|
              j.object { Serialize.fuzz_result_fields(j, rep) }
            end
          end
        end)
      end

      # One cluster's members in index order. The same stream aggregates the cluster (for its
      # summary) and picks this page's rows, so nothing past one page is held.
      private def saved_fuzz_cluster_members(run : Store::FuzzRunRecord, h, id : Int64,
                                             caps : SavedFuzzCaps) : Result
        matched_only = bool_arg(h, "matched_only", false)
        req_off = optional_int_arg(h, "offset")
        req_lim = optional_int_arg(h, "limit")
        offset = clamp_nonneg(req_off)
        limit = clamp(req_lim, caps.include_content ? 25 : 100, caps.include_content ? 25 : 1000)
        clusters = Fuzz::Clusters.new
        page = [] of Store::FuzzResultRecord
        seen = 0
        store.each_fuzz_result_summary(run.id) do |rec|
          result = Fuzz::Persistence.result(rec)
          clusters.add(result)
          next unless Fuzz::Clusters.key(result)[0] == id
          next if matched_only && !rec.matched?
          page << rec if seen >= offset && page.size < limit
          seen += 1
        end
        cluster = clusters[id]?
        return not_found("no cluster #{Fuzz::Shape.hex(id)} in saved fuzz run #{run.id}") unless cluster
        Result.new(JSON.build do |j|
          j.object do
            j.field("run") { Serialize.saved_fuzz_run(j, run, store.fuzz_result_count(run.id)) }
            j.field("cluster") do
              Fuzz::Clusters.emit(j, cluster, ->(t : String) { Serialize.text(t) }) do |rep|
                j.object { Serialize.fuzz_result_fields(j, rep) }
              end
            end
            j.field("results") { j.array { page.each { |rec| emit_saved_fuzz_member(j, run, rec, caps) } } }
            j.field "returned", page.size
            j.field "offset", offset
            j.field "limit", limit
            emit_clamp(j, req_off, offset, req_lim, limit)
            j.field "total_available", seen
            j.field "has_more", offset.to_i64 + page.size < seen
            j.field "matched_only", matched_only
          end
        end)
      end

      # A member row in `get_fuzz_run`'s own row shape: scalar, or the bounded content preview.
      private def emit_saved_fuzz_member(j : JSON::Builder, run : Store::FuzzRunRecord,
                                         rec : Store::FuzzResultRecord, caps : SavedFuzzCaps) : Nil
        preview = if caps.include_content
                    store.get_fuzz_result_preview(run.id, rec.idx, caps.message_source_cap,
                      caps.head_cap + 1, Serialize::SAVED_SOURCE_BYTES, caps.message_source_cap)
                  end
        if preview
          Serialize.saved_fuzz_result(j, preview, caps.include_sensitive, caps.body_cap, caps.head_cap)
        else
          Serialize.saved_fuzz_result(j, rec)
        end
      end
    end
  end
end
