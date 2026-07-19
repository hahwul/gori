require "uri"
require "./discover/url"

module Gori
  # The host → path-segment endpoint tree built from distinct (host, method,
  # target) rows — the data model + pure algorithms shared by the Sitemap TUI tab
  # (Tui::SitemapView, which layers scope markers / path tags / rendering on top)
  # and the headless `gori run sitemap`. Keeping the tree-building in ONE place
  # means the CLI report has the same shape (path normalisation, id folding,
  # path tags, endpoint counts) as the interactive tab. No terminal/Screen deps
  # here — pure values over the Store read-model.
  module Sitemap
    # Pure-numeric siblings beyond this count under one parent fold into a single
    # `[1, 2, 3 … +N]` group node (path-param explosion like /users/1,2,3…).
    SEQUENCE_GROUP_THRESHOLD = 10

    # Opaque-id siblings ({uuid}/{hex}) fold as soon as there are this many. A UUID is
    # self-evidently an id at ANY count, unlike a number where /v1 and /v2 are real
    # distinct routes — hence the 5× lower bar than SEQUENCE_GROUP_THRESHOLD.
    TEMPLATE_GROUP_THRESHOLD = 2

    # Segment lengths that gate the classifier's regexes (see `template_class`).
    DATE_LEN = 10 # 2026-07-19
    UUID_LEN = 36 # 8-4-4-4-12 with dashes
    HEX_MIN  = 12 # Url::HEX's floor

    # Joins a fold's parent path to its label to form `Node#fold_key`. NUL can't appear
    # in a request target, so a fold key can never collide with a real `path` — including
    # a literal `/users/{uuid}` segment, which captured traffic really does contain when
    # a client ships an un-interpolated template.
    FOLD_SEP = '\0'

    # The labels `fold_templates!` gives its synthetic nodes. A fold carrying one of these
    # is an ID fold, as opposed to a numeric-run fold from `group_sequences!` — the CLI
    # text renderer and the JSON discriminator both have to tell the two apart.
    TEMPLATE_LABELS = {"{uuid}", "{hex}", "{date}"}

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
      # A synthetic fold node: its children are the real siblings it collapsed — a
      # numeric run `[1, 2, 3 … +N]` from `group_sequences!`, or an opaque-id class
      # `{uuid}`/`{hex}`/`{date}` from `fold_templates!`. Not a real path — never tagged.
      property grouped : Bool
      # On a fold node, the `path` of the parent it was inserted under. `path` itself
      # stays "" (a fold is not a real endpoint), so this plus `label` is the fold's
      # only durable identity — what keeps a user-expanded fold open across a reload,
      # and what Discover uses as the container to scan ("/users", not one uuid child).
      property fold_parent : String?
      # On a fold node, the union of its folded children's OWN methods — what lets a
      # COLLAPSED row still answer "which verbs does /users/{uuid} take". Deliberately
      # kept out of `methods`: `endpoint_count` treats any node carrying a method as an
      # endpoint, so putting them there would inflate every host's path count, and the
      # flat `paths` output would start emitting synthetic rows.
      property fold_methods : Array(String)

      # Build-time label→child index so `child` is O(1) instead of a linear sibling scan —
      # a path-param explosion (thousands of `/users/<id>` siblings under one parent) made
      # the old `@children.find` O(n²) over a whole build. `@children` stays an ordered Array
      # (insertion order = render order, unchanged), so the index only accelerates lookup and
      # is never read after `build` (group_sequences! reshapes @children directly).
      def initialize(@label : String)
        @children = [] of Node
        @child_index = {} of String => Node
        @methods = [] of String
        @expanded = true
        @in_scope = false
        @endpoints = 0
        @path = ""
        @tag = nil
        @grouped = false
        @fold_parent = nil
        @fold_methods = [] of String
      end

      # The durable key for a fold node (nil on a real node). FOLD_SEP can't occur in a
      # request target, so this never collides with a real `path`.
      def fold_key : String?
        (fp = @fold_parent) ? "#{fp}#{FOLD_SEP}#{@label}" : nil
      end

      def child(label : String) : Node
        @child_index[label] ||= begin
          node = Node.new(label)
          @children << node
          node
        end
      end

      def leaf? : Bool
        @children.empty?
      end

      # An ID fold from `fold_templates!` (vs a numeric-run fold from `group_sequences!`).
      def template? : Bool
        @grouped && TEMPLATE_LABELS.includes?(@label)
      end
    end

    # Build the host-rooted tree from distinct (host, method, target) endpoints
    # (e.g. Store#sitemap_entries). Every distinct path segment is its own node; the
    # tree `build` returns is always literal. Folding is separate and opt-in, in two
    # passes run in this order: `fold_templates!` (opaque ids) then `group_sequences!`
    # (numeric runs). Both WRAP their children rather than rewriting any node's `path`.
    def self.build(entries : Enumerable({String, String, String})) : Array(Node)
      hosts = [] of Node
      host_index = {} of String => Node # O(1) host lookup (a scan can surface thousands of hosts)
      entries.each { |(host, method, target)| add(hosts, host, normalize_path(target), method, host_index) }
      hosts
    end

    # Insert one endpoint into `hosts`, creating host/segment nodes as needed. The
    # accumulated absolute path is stamped on each node (the durable tag key). `host_index`
    # (optional) accelerates the host lookup to O(1); without it the host is found by scan.
    def self.add(hosts : Array(Node), host : String, path : String, method : String,
                 host_index : Hash(String, Node)? = nil) : Nil
      host_node =
        if host_index
          host_index[host] ||= begin
            node = Node.new(host)
            hosts << node
            node
          end
        else
          hosts.find { |h| h.label == host } || begin
            node = Node.new(host)
            hosts << node
            node
          end
        end
      # Segment the PATH only: an unencoded '/' in a query VALUE (e.g. ?redirect=/a/b)
      # must not fabricate path-tree nodes. The query rides on the leaf so /x?a=1 and
      # /x?a=2 stay distinct endpoints without corrupting the tree.
      qidx = path.index('?')
      path_part = qidx ? path[0...qidx] : path
      suffix = qidx ? path[qidx..] : ""
      segments = path_part.split('/')
      segments.shift if segments.first? == "" # the mandatory leading-slash empty
      segments.pop if segments.last? == ""    # a trailing slash → same endpoint (normalized)
      # An INTERIOR empty (a literal "//") is kept, so //dup/a stays distinct from /dup/a.
      segments[-1] = "#{segments[-1]}#{suffix}" unless segments.empty? || suffix.empty?
      if segments.empty?
        leaf = suffix.empty? ? "/" : suffix
        node = host_node.child(leaf)
        node.path = suffix.empty? ? "/" : "/#{suffix}"
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
      # A fold is synthetic: its `path` is "" and so is a HOST row's, so without this
      # guard a host tag would stamp onto every fold under it. Not reachable today
      # (tags stamp before folding at both call sites) — this keeps that ordering from
      # being load-bearing, since CLI text/JSON emit `tag` with no `grouped` guard.
      node.tag = node.grouped ? nil : tags[{host, node.path}]?
      node.children.each { |c| stamp_node_tags(c, host, tags) }
    end

    # Fold a node's opaque-id children into one collapsed node per class
    # (`{uuid}`/`{hex}`/`{date}`); siblings that aren't ids stay put. Same synthetic-
    # wrapper shape as `group_sequences!` — the real children keep their literal `path`,
    # so path tags, selection anchors, and endpoint counts are all unaffected.
    #
    # Runs BEFORE group_sequences!. Numerics are deliberately not classified here, so
    # the two passes partition the work instead of competing for the same children.
    def self.fold_templates!(node : Node) : Nil
      node.children.each { |c| fold_templates!(c) }
      # Descend THROUGH a fold — its children are real and may hide further ids — but
      # never re-fold a fold's OWN children. This is what makes the pass idempotent.
      return if node.grouped
      buckets = {} of String => Array(Node)
      node.children.each do |c|
        next if c.grouped
        if cls = template_class(c.label)
          (buckets[cls] ||= [] of Node) << c
        end
      end
      buckets.reject! { |cls, kids| kids.size < template_threshold(cls) }
      return if buckets.empty?
      folded = Set(UInt64).new
      buckets.each_value { |kids| kids.each { |k| folded << k.object_id } }
      rest = node.children.reject { |c| folded.includes?(c.object_id) }
      node.children.clear
      node.children.concat(rest)
      # Sorted so the tree shape is stable regardless of which id was captured first.
      buckets.keys.sort!.each do |cls|
        group = Node.new(cls)
        group.grouped = true
        group.expanded = false
        group.fold_parent = node.path
        group.fold_methods = fold_method_union(buckets[cls])
        buckets[cls].each { |c| group.children << c }
        node.children << group
      end
    end

    # The methods a fold stands in for: the union of its folded children's OWN verbs,
    # first-seen order (entries arrive ORDER BY host, target, so this is deterministic).
    # Only the direct children — a grandchild like /users/<uuid>/orders is its own row.
    private def self.fold_method_union(kids : Array(Node)) : Array(String)
      verbs = [] of String
      kids.each { |k| k.methods.each { |m| verbs << m unless verbs.includes?(m) } }
      verbs
    end

    # Minimum sibling count for a class to fold. An opaque id is self-evidently an id at
    # ANY count; a date is meaningful CONTENT, and collapsing /reports/2026-07-18 with
    # /reports/2026-07-19 would hide a real range — so dates need the same explosion the
    # numeric fold demands before they collapse.
    private def self.template_threshold(cls : String) : Int32
      cls == "{date}" ? SEQUENCE_GROUP_THRESHOLD + 1 : TEMPLATE_GROUP_THRESHOLD
    end

    # A path segment that is self-evidently an opaque id → its placeholder label; nil for
    # a segment that should stay literal.
    #
    # Deliberately does NOT reuse `Url.fold_segment`: its passthrough branch returns the
    # DOWNCASED segment, which is right for crawl-trap dedup but would merge /Users and
    # /users in a display tree. Only the regexes are shared.
    #
    # Numerics are excluded on purpose: `Url::HEX` is /\A[0-9a-f]{12,}\z/i, so a 13-digit
    # ms timestamp or a Snowflake id would classify as {hex} and be stolen from
    # `group_sequences!` — `fold_segment` only escapes that by testing NUM first.
    def self.template_class(label : String) : String?
      # A leaf carries its query on the last segment (see `add`), so classify the path part.
      s = (qi = label.index('?')) ? label[0, qi] : label
      return nil if s.empty? # a bare-root request with a query → the leaf label is "?q=1"
      return nil if numeric_label?(s)
      # Size gates first: most real segments ("api", "users") never reach a regex.
      return "{date}" if s.size == DATE_LEN && Discover::Url::DATE.matches?(s)
      return "{uuid}" if s.size == UUID_LEN && Discover::Url::UUID.matches?(s)
      return "{hex}" if s.size >= HEX_MIN && Discover::Url::HEX.matches?(s)
      nil
    end

    # Fold a node's pure-numeric children into one collapsed `[1, 2, 3 … +N]` group
    # when they exceed the threshold; non-numeric siblings stay put. Recurses first
    # so nested sequences fold too. Sorting by (length, lexicographic) is numeric
    # order without parsing (handles arbitrarily long ids, no overflow).
    def self.group_sequences!(node : Node) : Nil
      node.children.each { |c| group_sequences!(c) }
      # Same idempotency guard as fold_templates! — recurse through a fold, never re-fold
      # its own children (without this, a {hex} fold of long numerics grows a nested
      # [1000… +N] inside it, and a second call nests one more level).
      return if node.grouped
      numeric = node.children.select { |c| !c.grouped && numeric_label?(c.label) }
      return if numeric.size <= SEQUENCE_GROUP_THRESHOLD
      numeric.sort_by! { |c| {c.label.size, c.label} }
      rest = node.children.select { |c| c.grouped || !numeric_label?(c.label) }
      group = Node.new(group_label(numeric))
      group.grouped = true
      group.expanded = false
      group.fold_parent = node.path
      group.fold_methods = fold_method_union(numeric)
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

    # Apply the settings:layout expand-depth policy after build/grouping.
    # depth < 0 → fully expanded (factory default). depth N → nodes with tree-depth < N
    # are expanded (0 = hosts collapsed so only host rows show). Grouped sequence folds
    # stay collapsed (they're noise until the user opens them).
    def self.apply_expand_depth!(hosts : Array(Node), depth : Int32) : Nil
      hosts.each { |h| apply_expand_depth_node!(h, 0, depth) }
    end

    private def self.apply_expand_depth_node!(node : Node, node_depth : Int32, depth : Int32) : Nil
      if node.grouped
        node.expanded = false
      elsif depth < 0
        node.expanded = true
      else
        node.expanded = node_depth < depth
      end
      node.children.each { |c| apply_expand_depth_node!(c, node_depth + 1, depth) }
    end
  end
end
