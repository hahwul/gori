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

      # One page of a cluster list: the clusters on it, and the paging facts about it.
      private record FuzzClusterPage, page : Array(Fuzz::Clusters::Cluster), total : Int32,
        offset : Int32, limit : Int32

      # A cluster listing's page: fewer and larger rows than a result page, so its own numbers.
      FUZZ_CLUSTER_LIMIT = PageLimit.new(50, 500)

      # `matched_only` keeps the clusters holding at least one matcher hit.
      private def fuzz_cluster_page(clusters : Fuzz::Clusters, args : FuzzClusterArgs,
                                    matched_only : Bool, req_off : Int64?, req_lim : Int64?) : FuzzClusterPage
        offset = clamp_nonneg(req_off)
        limit = clamp(req_lim, FUZZ_CLUSTER_LIMIT)
        list = clusters.sorted(args.order, matched_only)
        FuzzClusterPage.new(list[offset, limit]? || [] of Fuzz::Clusters::Cluster, list.size, offset, limit)
      end

      private def emit_fuzz_cluster_page(j : JSON::Builder, clusters : Fuzz::Clusters, pg : FuzzClusterPage,
                                         args : FuzzClusterArgs, matched_only : Bool,
                                         req_off : Int64?, req_lim : Int64?,
                                         &row : Fuzz::Result ->) : Nil
        last = pg.offset + pg.page.size
        j.field("clusters") do
          j.array do
            pg.page.each do |c|
              Fuzz::Clusters.emit(j, c, ->(t : String) { Serialize.text(t) }) { |rep| row.call(rep) }
            end
          end
        end
        j.field "cluster_order", args.order.label
        j.field "returned", pg.page.size
        j.field "offset", pg.offset
        j.field "limit", pg.limit
        emit_clamp(j, req_off, pg.offset, req_lim, pg.limit)
        j.field "total_available", pg.total
        j.field "has_more", last < pg.total
        j.field "page_complete", last >= pg.total
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
          picked.sort_by! { |i| {rows[i].index, i} } # index order, as `fuzz_results` pages (#1432)
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
        # History evidence) rides along; the cluster's metrics-only copy otherwise. The page's
        # flow ids are validated in one Store read, not one per cluster.
        pg = fuzz_cluster_page(fjob.clusters, args, matched_only, req_off, req_lim)
        cached = {} of Int64 => Int32
        rows.each_with_index { |r, i| cached[r.index] = i }
        positions = pg.page.compact_map { |c| cached[c.representative.index]? }
        flow_of = positions.zip(validated_fuzz_flow_ids(fjob, positions)).to_h
        Result.new(JSON.build do |j|
          j.object do
            emit_fuzz_cluster_page(j, fjob.clusters, pg, args, matched_only, req_off, req_lim) do |rep|
              if pos = cached[rep.index]?
                Serialize.fuzz_result(j, rows[pos], flow_of[pos]?)
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
        clusters = Fuzz::Persistence.clusters(store, run.id)
        Result.new(JSON.build do |j|
          j.object do
            j.field("run") { Serialize.saved_fuzz_run(j, run, store.fuzz_result_count(run.id)) }
            matched_only = bool_arg(h, "matched_only", false)
            req_off = optional_int_arg(h, "offset")
            req_lim = optional_int_arg(h, "limit")
            pg = fuzz_cluster_page(clusters, args, matched_only, req_off, req_lim)
            emit_fuzz_cluster_page(j, clusters, pg, args, matched_only, req_off, req_lim) do |rep|
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
        limit = clamp(req_lim, caps.include_content ? FUZZ_RUN_CONTENT_ROWS_LIMIT : FUZZ_RUN_ROWS_LIMIT)
        clusters, page, seen = Fuzz::Persistence.cluster_members(store, run.id, id, matched_only, offset, limit)
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
