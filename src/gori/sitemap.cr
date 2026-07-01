require "uri"

module Gori
  # The host → path-segment endpoint tree built from distinct (host, method,
  # target) rows — the data model + pure algorithms shared by the Sitemap TUI tab
  # (Tui::SitemapView, which layers scope markers / path tags / rendering on top)
  # and the headless `gori run sitemap`. Keeping the tree-building in ONE place
  # means the CLI report has the same shape (path normalisation, numeric folding,
  # path tags, endpoint counts) as the interactive tab. No terminal/Screen deps
  # here — pure values over the Store read-model.
  module Sitemap
    # Pure-numeric siblings beyond this count under one parent fold into a single
    # `[1, 2, 3 … +N]` group node (path-param explosion like /users/1,2,3…).
    SEQUENCE_GROUP_THRESHOLD = 10

    # One tree node: a host (depth 0) or a path segment. Besides the structural
    # fields the builder always sets (label/children/methods/path), it carries
    # presentation state that consumers populate: `expanded`/`in_scope` (TUI render
    # only), `endpoints` (stamped by `endpoint_count`), `tag` (stamped by
    # `stamp_tags!`), `grouped` (set by `group_sequences!` on synthetic fold nodes).
    class Node
      getter label : String
      getter children : Array(Node)
      property methods : Array(String)
      property expanded : Bool
      # Scope state, meaningful only on host (depth-0) nodes (TUI marker/dimming).
      property in_scope : Bool
      property endpoints : Int32 # # of captured endpoints (nodes with methods) under it
      # Full URL path from the host root ("" on the host node, "/" for the bare root),
      # stamped during `add`. Stable regardless of how grouping later reshapes the tree,
      # so it's the durable key for a path tag.
      property path : String
      # Optional free-text memo pinned to this (host, path) (V17). nil = untagged.
      property tag : String?
      # A synthetic `[1, 2, 3 … +N]` fold node: its children are real numeric siblings
      # collapsed by `group_sequences!`. Not a real path — never tagged, never keyed.
      property grouped : Bool

      def initialize(@label : String)
        @children = [] of Node
        @methods = [] of String
        @expanded = true
        @in_scope = false
        @endpoints = 0
        @path = ""
        @tag = nil
        @grouped = false
      end

      def child(label : String) : Node
        @children.find { |c| c.label == label } || begin
          node = Node.new(label)
          @children << node
          node
        end
      end

      def leaf? : Bool
        @children.empty?
      end
    end

    # Build the host-rooted tree from distinct (host, method, target) endpoints
    # (e.g. Store#sitemap_entries). Every distinct path segment is its own node — no
    # ID templating; numeric folding is a separate opt-in step (`group_sequences!`).
    def self.build(entries : Enumerable({String, String, String})) : Array(Node)
      hosts = [] of Node
      entries.each { |(host, method, target)| add(hosts, host, normalize_path(target), method) }
      hosts
    end

    # Insert one endpoint into `hosts`, creating host/segment nodes as needed. The
    # accumulated absolute path is stamped on each node (the durable tag key).
    def self.add(hosts : Array(Node), host : String, path : String, method : String) : Nil
      host_node = hosts.find { |h| h.label == host } || begin
        node = Node.new(host)
        hosts << node
        node
      end
      segments = path.split('/').reject(&.empty?)
      if segments.empty?
        node = host_node.child("/")
        node.path = "/"
      else
        acc = ""
        node = host_node
        segments.each do |seg|
          acc = "#{acc}/#{seg}"
          node = node.child(seg)
          node.path = acc # idempotent on revisits; the durable tag key
        end
      end
      node.methods << method unless node.methods.includes?(method)
    end

    # An absolute-form target ("https://host/p?q") → its path+query; an origin-form
    # target is returned unchanged. "/" for a bare root.
    def self.normalize_path(target : String) : String
      return target unless target.starts_with?("http://") || target.starts_with?("https://")
      uri = URI.parse(target)
      path = uri.path
      path = "/" if path.empty?
      uri.query ? "#{path}?#{uri.query}" : path
    rescue
      target
    end

    # Pin each node's memo from the (host, path) ⇒ tag map (e.g. Store#sitemap_tags).
    # Hosts are matched by their label; deeper nodes by their stamped `path`.
    def self.stamp_tags!(hosts : Array(Node), tags : Hash({String, String}, String)) : Nil
      return if tags.empty?
      hosts.each { |h| stamp_node_tags(h, h.label, tags) }
    end

    private def self.stamp_node_tags(node : Node, host : String, tags : Hash({String, String}, String)) : Nil
      node.tag = tags[{host, node.path}]?
      node.children.each { |c| stamp_node_tags(c, host, tags) }
    end

    # Fold a node's pure-numeric children into one collapsed `[1, 2, 3 … +N]` group
    # when they exceed the threshold; non-numeric siblings stay put. Recurses first
    # so nested sequences fold too. Sorting by (length, lexicographic) is numeric
    # order without parsing (handles arbitrarily long ids, no overflow).
    def self.group_sequences!(node : Node) : Nil
      node.children.each { |c| group_sequences!(c) }
      numeric = node.children.select { |c| !c.grouped && numeric_label?(c.label) }
      return if numeric.size <= SEQUENCE_GROUP_THRESHOLD
      numeric.sort_by! { |c| {c.label.size, c.label} }
      rest = node.children.select { |c| c.grouped || !numeric_label?(c.label) }
      group = Node.new(group_label(numeric))
      group.grouped = true
      group.expanded = false
      numeric.each { |c| group.children << c }
      node.children.clear
      node.children.concat(rest)
      node.children << group
    end

    def self.numeric_label?(label : String) : Bool
      !label.empty? && label.each_char.all?(&.ascii_number?)
    end

    # "[1, 2, 3 … +47]" — the first three values then a remainder count.
    def self.group_label(nodes : Array(Node)) : String
      head = nodes.first(3).map(&.label).join(", ")
      nodes.size > 3 ? "[#{head} … +#{nodes.size - 3}]" : "[#{head}]"
    end

    # # of captured endpoints under a node: descendant nodes carrying ≥1 method
    # (= distinct (host, path) pairs, incl. folder-with-methods nodes like /api/users).
    def self.endpoint_count(node : Node) : Int32
      n = node.methods.empty? ? 0 : 1
      node.children.each { |c| n += endpoint_count(c) }
      n
    end
  end
end
