module Gori
  module Sitemap
    # Which active tools (`FlowSource::Kind#active?`) sent flows to each endpoint, and how
    # many: the `touched_by` map MCP `list_sitemap` and `gori run sitemap` print, and what
    # their `untested` filter drops on.
    #
    # An endpoint is the origin, the method and the node path WITHOUT its query (`path_of`).
    # The query is left out because a fuzz sweep over `?q=` sends a new target per payload
    # while the request it started from keeps its own: keyed on the full target, the captured
    # `/search?q=test` stayed "untested" after a thousand-payload sweep of `/search`.
    class Coverage
      EMPTY = {} of String => Int64

      def initialize(entries : Enumerable(Store::CoverageEntry))
        @counts = {} of {String, String, Int32, String, String} => Hash(String, Int64)
        entries.each do |e|
          by = @counts[{e.scheme, e.host, e.port, e.method, Coverage.path_of(e.path)}] ||= {} of String => Int64
          by[e.source] = by.fetch(e.source, 0_i64) + e.count
        end
      end

      def self.load(store : Store) : Coverage
        new(store.endpoint_coverage)
      end

      # A target's coverage key: the tree's node path (absolute form reduced, trailing slash
      # dropped), cut at its query.
      def self.path_of(target : String) : String
        path = Sitemap.node_path(target)
        (q = path.index('?')) ? path[0...q] : path
      end

      # Active tool token → flow count for one endpoint; empty when none touched it.
      def touched_by(scheme : String, host : String, port : Int32, method : String, target : String) : Hash(String, Int64)
        @counts[{scheme, host, port, method, Coverage.path_of(target)}]? || EMPTY
      end

      def touched?(scheme : String, host : String, port : Int32, method : String, target : String) : Bool
        !touched_by(scheme, host, port, method, target).empty?
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
              touched_by(o.scheme, o.host, o.port, m, n.path).each { |src, c| sum[src] = sum.fetch(src, 0_i64) + c }
            end
            n.touched_by = sum unless sum.empty?
          end
        end
      end
    end
  end
end
