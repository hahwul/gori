require "json"
require "./types"
require "./shape"

module Gori
  module Fuzz
    # A run's rows grouped by response shape (issue #1351) — the ONE aggregation every surface
    # uses: the TUI's grouped RESULTS view, MCP `fuzz_results` / `get_fuzz_run` with
    # `clusters:true`, and `gori run fuzz show --clusters`. Live runs feed it every Result as it
    # arrives; saved runs feed it the Store's keyset-paged scalar stream, so neither path
    # holds more than one entry per distinct shape.
    #
    # Clustering is a READ projection. It never changes a row, its index or its matcher
    # verdict; it only counts them.
    #
    # Bounded: at most `max_clusters` distinct shapes are tracked. A target whose every answer
    # is unique (the realistic worst case: a nonce the normalizer does not recognise) fills the
    # table, and every later NEW shape is counted in `overflow_rows` instead — reported, never
    # silently dropped.
    class Clusters
      MAX_CLUSTERS = 4096
      # Member indices kept per cluster: the LOWEST ones, so a cluster's sample does not depend
      # on the order concurrent results arrived in.
      SAMPLE_INDICES = 20

      # How a cluster list is ordered. Ties always break on the representative's index, so an
      # offset page is deterministic.
      enum Order
        # Smallest cluster first: the rare answers are the ones worth reading.
        Rare
        # Largest cluster first.
        Common
        # By the representative's index — the order the shapes first appear in the run.
        First

        def label : String
          case self
          in Rare   then "rare"
          in Common then "common"
          in First  then "first"
          end
        end

        def self.names : Array(String)
          %w[rare common first]
        end

        def self.parse?(token : String?) : Order?
          case token.try(&.strip.downcase)
          when "rare", "rare-first", "rare_first" then Rare
          when "common", "size", "largest"        then Common
          when "first", "index", "first-seen"     then First
          end
        end
      end

      # One shape's aggregate. `representative` is the member with the LOWEST index, held as a
      # metrics-only copy: live results arrive out of order and a saved run is read in index
      # order, so the lowest index is the one rule under which both pick the same row.
      class Cluster
        getter id : Int64
        getter count : Int64 = 0_i64
        getter matched : Int64 = 0_i64
        getter errored : Int64 = 0_i64
        getter incomplete : Int64 = 0_i64
        getter representative : Result
        getter first_matched_index : Int64?
        # The lowest-index MATCHED member, metrics-only — what a matched-only view heads the
        # cluster with, so it never shows a row the lens would have hidden.
        getter matched_representative : Result?
        getter length_min : Int64
        getter length_max : Int64
        getter words_min : Int32
        getter words_max : Int32
        getter lines_min : Int32
        getter lines_max : Int32
        getter duration_min : Int64
        getter duration_max : Int64
        getter samples : Array(Int64)
        # Keyed by `Shape.approximate` — a row saved before shapes were recorded.
        getter? approximate : Bool

        def initialize(@id : Int64, r : Result, @approximate : Bool)
          @representative = Clusters.metrics_only(r)
          @length_min = @length_max = r.length
          @words_min = @words_max = r.words
          @lines_min = @lines_max = r.lines
          @duration_min = @duration_max = r.duration_us
          @samples = [] of Int64
        end

        def add(r : Result) : Nil
          @count += 1
          @errored += 1 if r.error
          @incomplete += 1 if r.incomplete?
          if r.matched?
            @matched += 1
            first = @first_matched_index
            if first.nil? || r.index < first
              @first_matched_index = r.index
              @matched_representative = Clusters.metrics_only(r)
            end
          end
          @representative = Clusters.metrics_only(r) if r.index < @representative.index
          widen(r)
          sample(r.index)
        end

        private def widen(r : Result) : Nil
          @length_min = r.length if r.length < @length_min
          @length_max = r.length if r.length > @length_max
          @words_min = r.words if r.words < @words_min
          @words_max = r.words if r.words > @words_max
          @lines_min = r.lines if r.lines < @lines_min
          @lines_max = r.lines if r.lines > @lines_max
          @duration_min = r.duration_us if r.duration_us < @duration_min
          @duration_max = r.duration_us if r.duration_us > @duration_max
        end

        # Every member is in `samples`.
        def sample_complete? : Bool
          @samples.size.to_i64 >= @count
        end

        def status : Int32?
          @representative.status
        end

        def error_class : Shape::ErrorClass?
          Shape.error_class(@representative.error)
        end

        def hex : String
          Shape.hex(@id)
        end

        private def sample(index : Int64) : Nil
          return if @samples.size >= SAMPLE_INDICES && index >= @samples.last
          at = @samples.bsearch_index { |v| v >= index } || @samples.size
          return if @samples[at]? == index
          @samples.insert(at, index)
          @samples.pop if @samples.size > SAMPLE_INDICES
        end
      end

      getter rows : Int64 = 0_i64
      # Rows whose shape arrived after the table was full. Not in any cluster.
      getter overflow_rows : Int64 = 0_i64
      getter overflow_matched : Int64 = 0_i64
      getter max_clusters : Int32

      def initialize(@max_clusters : Int32 = MAX_CLUSTERS)
        raise ArgumentError.new("max_clusters must be positive") if @max_clusters <= 0
        @by_id = {} of Int64 => Cluster
      end

      # The cluster key of a row, and whether it is the approximate one.
      def self.key(r : Result) : {Int64, Bool}
        if shape = r.shape
          {shape, false}
        else
          {Shape.approximate(r.status, r.grpc_status, r.error, r.incomplete?, r.timed_out?,
            r.ws_close_code, r.words, r.lines), true}
        end
      end

      def add(r : Result) : Nil
        @rows += 1
        id, approximate = Clusters.key(r)
        cluster = @by_id[id]?
        unless cluster
          if @by_id.size >= @max_clusters
            @overflow_rows += 1
            @overflow_matched += 1 if r.matched?
            return
          end
          cluster = Cluster.new(id, r, approximate)
          @by_id[id] = cluster
        end
        cluster.add(r)
      end

      def size : Int32
        @by_id.size
      end

      def truncated? : Bool
        @overflow_rows > 0
      end

      def []?(id : Int64) : Cluster?
        @by_id[id]?
      end

      # `matched_only` keeps the clusters holding at least one matcher hit — the one filter
      # every surface's matched-only lens applies to a cluster list.
      def sorted(order : Order = Order::Rare, matched_only : Bool = false) : Array(Cluster)
        list = @by_id.values
        list.select! { |c| c.matched > 0 } if matched_only
        case order
        in Order::Rare   then list.sort_by! { |c| {c.count, c.representative.index} }
        in Order::Common then list.sort_by! { |c| {-c.count, c.representative.index} }
        in Order::First  then list.sort_by!(&.representative.index)
        end
        list
      end

      # The row as a cluster holds it: every metric and flag, no captured bytes.
      def self.metrics_only(r : Result) : Result
        return r if r.head.nil? && r.body.nil? && r.request.nil? && r.wire.nil?
        Result.new(r.index, r.payloads, r.position, r.status, r.length, r.words, r.lines,
          r.duration_us, r.error, r.matched?, r.incomplete?, r.extracted, nil, nil, nil,
          r.retried?, r.chain_error, r.grpc_status, r.grpc_message, r.timed_out?,
          r.resent_count, nil, ws_close_code: r.ws_close_code, ws_frames_in: r.ws_frames_in,
          stop_hit: r.stop_hit?, shape: r.shape)
      end

      # One cluster's fields — the one spelling MCP and the CLI emit. `text` is the surface's
      # own sanitizer for captured/operator text (MCP `Serialize.text`, the CLI's scrub); the
      # block writes the representative ROW in the surface's existing row shape, so a caller
      # reads it exactly as it reads a `fuzz_results` row.
      def self.emit(j : JSON::Builder, c : Cluster, text : String -> String, & : Result ->) : Nil
        j.object do
          j.field "id", c.hex
          j.field "count", c.count
          j.field "matched", c.matched
          j.field "errored", c.errored
          j.field "incomplete", c.incomplete
          j.field "status", c.status
          j.field("grpc_status", c.representative.grpc_status) if c.representative.grpc_status
          j.field("ws_close_code", c.representative.ws_close_code) if c.representative.ws_close_code
          j.field("error_class", c.error_class.try(&.label)) if c.error_class
          j.field "representative_index", c.representative.index
          j.field "first_matched_index", c.first_matched_index
          j.field("length") { range(j, c.length_min, c.length_max) }
          j.field("words") { range(j, c.words_min, c.words_max) }
          j.field("lines") { range(j, c.lines_min, c.lines_max) }
          j.field("duration_us") { range(j, c.duration_min, c.duration_max) }
          j.field("sample_indices") { j.array { c.samples.each { |i| j.number i } } }
          j.field "sample_complete", c.sample_complete?
          j.field("approximate", true) if c.approximate?
          j.field("representative_payloads") { j.array { c.representative.payloads.each { |p| j.string text.call(p) } } }
          j.field("representative") { yield c.representative }
        end
      end

      # The whole-run fields that qualify a cluster page: how many rows were grouped, and
      # whether the table overflowed.
      def self.emit_summary(j : JSON::Builder, clusters : Clusters) : Nil
        j.field "clustered_rows", clusters.rows
        j.field "cluster_count", clusters.size
        j.field "clusters_truncated", clusters.truncated?
        if clusters.truncated?
          j.field "overflow_rows", clusters.overflow_rows
          j.field "overflow_matched", clusters.overflow_matched
        end
      end

      private def self.range(j : JSON::Builder, lo, hi) : Nil
        j.object do
          j.field "min", lo
          j.field "max", hi
        end
      end
    end
  end
end
