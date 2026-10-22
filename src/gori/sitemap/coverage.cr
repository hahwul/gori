module Gori
  module Sitemap
    # Which active tools (`FlowSource::Kind#active?`) left a record of testing each endpoint,
    # and how much: the `touched_by` map MCP `list_sitemap` and `gori run sitemap` print, and
    # what their `untested` filter drops on.
    #
    # Two records count, because those are the only two gori keeps: a flow an active tool
    # RECORDED in History (`Store#endpoint_coverage`), and a result of a SAVED Fuzzer run
    # (`Store#fuzz_run_coverage`). A sweep that was neither recorded nor saved, or a Miner,
    # Sequencer or Authorize run, leaves nothing in the project to count.
    #
    # An endpoint is the origin, the method and the node path WITHOUT its query (`path_of`).
    # The query is left out because a fuzz sweep over `?q=` sends a new target per payload
    # while the request it started from keeps its own: keyed on the full target, the captured
    # `/search?q=test` stayed "untested" after a thousand-payload sweep of `/search`.
    class Coverage
      alias Key = {String, String, Int32, String, String} # scheme, host, port, method, path

      def initialize(entries : Enumerable(Store::CoverageEntry), runs : Enumerable(Store::FuzzRunCoverage) = [] of Store::FuzzRunCoverage)
        @counts = {} of Key => Hash(String, Int64)
        entries.each do |e|
          by = @counts[{e.scheme, e.host, e.port, e.method, Coverage.path_of(e.path)}] ||= {} of String => Int64
          by[e.source] = by.fetch(e.source, 0_i64) + e.count
        end
        add_runs(runs)
      end

      def self.load(store : Store) : Coverage
        new(store.endpoint_coverage, store.fuzz_run_coverage)
      end

      # Saved-run results join the `fuzzer` count as the LARGER of the two records, not their
      # sum: a sweep both recorded and saved is in both, and summing would count it twice.
      private def add_runs(runs : Enumerable(Store::FuzzRunCoverage)) : Nil
        token = FlowSource::Kind::Fuzzer.token
        saved = {} of Key => Int64
        runs.each do |r|
          next unless key = Coverage.run_key(r.origin, r.request_line)
          saved[key] = saved.fetch(key, 0_i64) + r.count
        end
        saved.each do |key, n|
          by = @counts[key] ||= {} of String => Int64
          by[token] = {by.fetch(token, 0_i64), n}.max
        end
      end

      # A saved run's `scheme://host:port` target (every surface writes it in that shape, the
      # host bare) and its request line → the endpoint key, or nil for bytes that are not one.
      # The line arrives cut at its query (`Store#fuzz_run_coverage`), so the version is there
      # only when the target had no query.
      def self.run_key(origin : String, line : Bytes) : Key?
        return nil unless (sep = origin.index("://")) && (colon = origin.rindex(':')) && colon > sep + 3
        port = origin[colon + 1..].to_i?
        text = String.new(line).rstrip("\r\n")
        return nil unless port && (sp = text.index(' ')) && sp > 0
        target = text[sp + 1..]
        if (last = target.rindex(' ')) && target[last + 1..].starts_with?("HTTP/")
          target = target[0...last]
        end
        return nil if target.empty?
        {origin[0...sep], origin[sep + 3...colon], port, text[0...sp], path_of(target)}
      end

      # A target's coverage key: the tree's node path (absolute form reduced, trailing slash
      # dropped), cut at its query.
      def self.path_of(target : String) : String
        path = Sitemap.node_path(target)
        (q = path.index('?')) ? path[0...q] : path
      end

      # Active tool token → count for one endpoint; nil when none touched it.
      def touched_by(scheme : String, host : String, port : Int32, method : String, target : String) : Hash(String, Int64)?
        @counts[{scheme, host, port, method, Coverage.path_of(target)}]?
      end

      def touched?(scheme : String, host : String, port : Int32, method : String, target : String) : Bool
        @counts.has_key?({scheme, host, port, method, Coverage.path_of(target)})
      end

      # Stamp `Node#touched_by` across an origin tree, summed over each endpoint node's
      # methods. A query fold answers for its path with its variants' verbs; an id or numeric
      # fold is synthetic and stays bare, as it stays untagged.
      def stamp!(hosts : Array(Node)) : Nil
        hosts.each do |h|
          next unless o = h.origin
          Sitemap.post_order(h) do |n|
            next if n.grouped && !n.query_fold
            methods = n.query_fold ? n.fold_methods : n.methods
            sum = {} of String => Int64
            methods.each do |m|
              touched_by(o.scheme, o.host, o.port, m, n.path).try &.each { |src, c| sum[src] = sum.fetch(src, 0_i64) + c }
            end
            n.touched_by = sum unless sum.empty?
          end
        end
      end
    end
  end
end
