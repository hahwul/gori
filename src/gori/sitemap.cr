require "uri"
require "./discover/url"

module Gori
  # The host → path-segment endpoint tree built from distinct (host, method,
  # target) rows — the data model + pure algorithms shared by the Sitemap TUI tab
  # (Tui::SitemapView, which layers scope markers / path tags / rendering on top)
  # and the headless `gori run sitemap`. Keeping the tree-building in ONE place
  # means the CLI report has the same shape (path normalisation, id folding,
  # path tags, endpoint counts) as the interactive tab. No terminal/Screen deps
  # here — pure values over the Store read-model. Every distinct segment keeps its
  # own node; folding is an explicit, reversible view choice (P3), never a
  # parse-time assumption.
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

    # Most path segments a single target contributes to the tree. Beyond this the target is
    # cut and the node it lands on is flagged `truncated` (see `add`, which carries the
    # measured memory curve that makes this necessary).
    #
    # The bound is on the DERIVED tree, never on the capture: the flow keeps its target
    # byte-exact and History renders it in full (P7). What a deeper target loses is only its
    # tail's separate nodes in this projection — the endpoint still appears, at the cut path.
    #
    # 128 is far past anything real (public APIs sit under ~30 segments) and still keeps the
    # adversarial case bounded: `Store::SITEMAP_MAX` caps the query at 10k endpoints, so even
    # 10k targets sharing no prefix at all cost megabytes here rather than gigabytes.
    MAX_DEPTH = 128

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
      # This node is where a target deeper than `Sitemap::MAX_DEPTH` segments was cut, so
      # its `path` is a PREFIX of the captured target rather than the whole of it, and its
      # methods are those of one or more deeper endpoints folded onto it. Display-only — the
      # captured request is untouched and History still shows the target verbatim (P7).
      property truncated : Bool

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
        @truncated = false
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
      path_only = qidx ? path[0...qidx] : path # local, not the `path_part` helper below
      suffix = qidx ? path[qidx..] : ""
      segments = path_only.split('/')
      segments.shift if segments.first? == "" # the mandatory leading-slash empty
      segments.pop if segments.last? == ""    # a trailing slash → same endpoint (normalized)
      # An INTERIOR empty (a literal "//") is kept, so //dup/a stays distinct from /dup/a.
      segments[-1] = "#{segments[-1]}#{suffix}" unless segments.empty? || suffix.empty?
      if segments.empty?
        leaf = suffix.empty? ? "/" : suffix
        node = host_node.child(leaf)
        node.path = suffix.empty? ? "/" : "/#{suffix}"
      else
        # MEASURED, and the reason MAX_DEPTH exists: every node stores its FULL path from
        # the root (`Node#path`, the durable tag key), so both this loop's `acc` and the
        # tree's memory are QUADRATIC in segment count. Sitemap.build alone, no walker:
        # 109 MB at 5k segments, 404 MB at 10k, 1.6 GB at 20k, 6.6 GB at 40k, 28 GB at 80k,
        # OOM-killed at 160k — reachable from ONE captured or imported request, and long
        # before any traversal runs out of stack.
        # The query rode onto the LAST segment above, so a cut target drops its query with
        # the tail it belonged to. That is the same loss as the rest of the tail, and the
        # `truncated` flag is what tells the operator the path is a prefix.
        truncated = segments.size > MAX_DEPTH
        segments = segments[0, MAX_DEPTH] if truncated
        acc = ""
        node = host_node
        segments.each do |seg|
          acc = "#{acc}/#{seg}"
          node = node.child(seg)
          node.path = acc # idempotent on revisits; the durable tag key
        end
        # Sticky: another target may reach this same node without being truncated itself,
        # and the node's path is a prefix either way once one of them was cut.
        node.truncated = true if truncated
      end
      node.methods << method unless node.methods.includes?(method)
    end

    # An absolute-form target ("https://host/p?q") → its path+query; an origin-form
    # target is returned unchanged. "/" for a bare root.
    def self.normalize_path(target : String) : String
      # `Url.absolute_form?` is the one home for this test, and it is case-INSENSITIVE
      # (RFC 3986 3.1). The hand-rolled pair missed `HTTP://host/p`, which then kept its
      # scheme+authority and got segmented into path nodes named `http:` and `host`.
      return target unless Url.absolute_form?(target)
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
      hosts.each do |h|
        host = h.label
        # Iterative (see post_order): the old `stamp_node_tags` recursed one frame per tree
        # level and overflowed the native stack on a pathologically deep path. Each node's
        # tag depends only on its OWN (host, path), so visit order is irrelevant here.
        #
        # A fold is synthetic: its `path` is "" and so is a HOST row's, so without this
        # guard a host tag would stamp onto every fold under it. Not reachable today
        # (tags stamp before folding at both call sites) — this keeps that ordering from
        # being load-bearing, since CLI text/JSON emit `tag` with no `grouped` guard.
        post_order(h) { |n| n.tag = n.grouped ? nil : tags[{host, n.path}]? }
      end
    end

    # Visit every node in `root`'s subtree exactly once, each node AFTER its whole subtree
    # (post-order), WITHOUT native recursion. The tree transforms below used to recurse one
    # stack frame per tree level, which a single very deep captured/imported path (tens of
    # thousands of segments) overflowed — SIGSEGV — on both the TUI Sitemap poll and
    # `gori run sitemap`; an explicit work-list has no such ceiling. Collect nodes
    # parent-before-child, then yield them in REVERSE — every node precedes its ancestors,
    # so it is handed to the block only after its whole subtree, matching the old
    # `children.each { recurse }; <body>` order. A transform may therefore reshape a node's
    # OWN children when yielded (wrap them in a fold): its descendants are already done, and
    # the new fold node is not in the collected list, so it is never re-visited.
    #
    # PUBLIC because the same ceiling applies to the TUI's own tree walks
    # (`Tui::SitemapView`'s expand-state snapshot/reapply), and a second copy of this
    # work-list next to them is the shape that left five of these walkers recursive after
    # the first fix. One home.
    def self.post_order(root : Node, & : Node ->) : Nil
      order = [root]
      i = 0
      while i < order.size
        order[i].children.each { |c| order << c }
        i += 1
      end
      # Index iteration (not `reverse_each`) keeps `yield` out of a block, which the compiler bars.
      i = order.size - 1
      while i >= 0
        yield order[i]
        i -= 1
      end
    end

    # Fold a node's opaque-id children into one collapsed node per class
    # (`{uuid}`/`{hex}`/`{date}`); siblings that aren't ids stay put. Same synthetic-
    # wrapper shape as `group_sequences!` — the real children keep their literal `path`,
    # so path tags, selection anchors, and endpoint counts are all unaffected.
    #
    # Runs BEFORE group_sequences!. Numerics are deliberately not classified here, so
    # the two passes partition the work instead of competing for the same children.
    def self.fold_templates!(node : Node) : Nil
      # Iterative post-order (see post_order): the old
      # `node.children.each { |c| fold_templates!(c) }` recursed one frame per tree level and
      # overflowed the native stack on a pathologically deep path. Each node is still folded
      # only after its subtree, so it sees a fully-folded child set exactly as before.
      post_order(node) { |n| fold_templates_node!(n) }
    end

    # Fold ONE node's opaque-id children (see fold_templates!). Descend THROUGH a fold — its
    # children are real and may hide further ids — but never re-fold a fold's OWN children,
    # which is what makes the pass idempotent.
    private def self.fold_templates_node!(node : Node) : Nil
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
      s = path_part(label)
      return nil if s.empty? # a bare-root request with a query → the leaf label is "?q=1"
      return nil if numeric_label?(s)
      # A captured target is raw bytes off the wire — `Http1.parse_request_head` builds it
      # with `String.new(Bytes)`, which does NOT validate — so a legacy-encoded (EUC-KR,
      # latin-1) or fuzzed path reaches here as invalid UTF-8. PCRE2 RAISES on such a
      # subject rather than returning false, and this runs on the sitemap poll with no
      # rescue between here and the run loop, so one such request tore down the TUI. All
      # three patterns below are ASCII-only, so a non-ASCII segment could never match
      # anyway: the guard is exact, and it also keeps every CJK path off PCRE2 entirely.
      # (`Gori::SafeRegexp` exists for this same reason on the store side.)
      return nil unless s.ascii_only?
      # Size gates next: most real segments ("api", "users") never reach a regex.
      return "{date}" if s.size == DATE_LEN && Discover::Url::DATE.matches?(s) && real_date?(s)
      return "{uuid}" if s.size == UUID_LEN && Discover::Url::UUID.matches?(s)
      return "{hex}" if s.size >= HEX_MIN && Discover::Url::HEX.matches?(s)
      nil
    end

    # `Url::DATE` is only a SHAPE (\d{4}-\d{2}-\d{2}), so `1234-56-78` and `9999-99-99`
    # matched it. Folding those is arguably right — they are opaque ids — but labelling
    # them `{date}` tells the reader something false about the route. Range-check the
    # parts and let a non-date fall through to `{hex}`/literal instead.
    private def self.real_date?(s : String) : Bool
      month = s[5, 2].to_i
      day = s[8, 2].to_i
      1 <= month <= 12 && 1 <= day <= 31
    end

    # Fold a node's pure-numeric children into one collapsed `[1, 2, 3 … +N]` group
    # when they exceed the threshold; non-numeric siblings stay put. Visits deepest-first
    # (post_order) so nested sequences fold too. Sorting by (length, lexicographic) is
    # numeric order without parsing (handles arbitrarily long ids, no overflow).
    def self.group_sequences!(node : Node) : Nil
      # Iterative post-order (see post_order): the old
      # `node.children.each { |c| group_sequences!(c) }` recursion SIGSEGV'd on a very deep
      # tree. Same shared work-list, same per-node transform below.
      post_order(node) { |n| group_sequences_node!(n) }
    end

    # Group ONE node's pure-numeric children (see group_sequences!). Same idempotency guard
    # as fold_templates! — descend through a fold, never re-fold its own children (without
    # this, a {hex} fold of long numerics grows a nested [1000… +N] inside it, and a second
    # call nests one more level).
    private def self.group_sequences_node!(node : Node) : Nil
      return if node.grouped
      # Count first, materialise second. The overwhelming majority of nodes have no numeric
      # children at all, and `select` used to allocate the result Array for every one of them
      # before the threshold check below could reject it — on a tree rebuilt each poll frame.
      count = 0
      node.children.each { |c| count += 1 if !c.grouped && numeric_label?(c.label) }
      return if count <= SEQUENCE_GROUP_THRESHOLD
      numeric = Array(Node).new(count)
      rest = Array(Node).new(node.children.size - count)
      node.children.each do |c|
        (!c.grouped && numeric_label?(c.label)) ? (numeric << c) : (rest << c)
      end
      numeric.sort_by! { |c| p = path_part(c.label); {p.size, p} }
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

    # The path side of a leaf label. `add` appends the query to the LAST segment, so
    # `/items/7?ref=home` arrives here as the label `7?ref=home`. Every classifier has to
    # look past that or an id stops being recognisable the moment it carries a query —
    # which is exactly when a listing page explodes the tree.
    def self.path_part(label : String) : String
      (qi = label.index('?')) ? label[0, qi] : label
    end

    def self.numeric_label?(label : String) : Bool
      s = path_part(label)
      return false if s.empty?
      # Byte loop rather than `each_char.all?`: the block-less each_char returns a CharIterator,
      # which is a CLASS, so that form heap-allocated an iterator per call — and this runs a few
      # times per node on a tree that is rebuilt from scratch on every sitemap poll. ASCII digits
      # are single-byte, and any multi-byte char has all bytes >= 0x80, so a byte test rejects
      # non-digits exactly as the char test did.
      s.each_byte { |b| return false unless 0x30_u8 <= b <= 0x39_u8 }
      true
    end

    # "[1, 2, 3 … +47]" — the first three values then a remainder count.
    def self.group_label(nodes : Array(Node)) : String
      head = nodes.first(3).map { |n| path_part(n.label) }.join(", ")
      nodes.size > 3 ? "[#{head} … +#{nodes.size - 3}]" : "[#{head}]"
    end

    # # of captured endpoints under a node: descendant nodes carrying ≥1 method
    # (= distinct (host, path) pairs, incl. folder-with-methods nodes like /api/users).
    def self.endpoint_count(node : Node) : Int32
      # Iterative (see post_order): the old recursion spent one frame per tree level and
      # overflowed the native stack on a pathologically deep path — and unlike the fold
      # passes this one runs on EVERY sitemap reload (SitemapView#reload, `gori run sitemap`),
      # so it was the likeliest of the seven walkers to actually be hit.
      n = 0
      post_order(node) { |x| n += 1 unless x.methods.empty? }
      n
    end

    # Apply the settings:layout expand-depth policy after build/grouping.
    # depth < 0 → fully expanded (factory default). depth N → nodes with tree-depth < N
    # are expanded (0 = hosts collapsed so only host rows show). Grouped sequence folds
    # stay collapsed (they're noise until the user opens them).
    def self.apply_expand_depth!(hosts : Array(Node), depth : Int32) : Nil
      hosts.each { |h| apply_expand_depth_node!(h, 0, depth) }
    end

    # Explicit stack rather than `post_order`, because this walk threads state DOWN
    # (`node_depth`) instead of combining results up, and post_order carries no depth. Each
    # node's verdict depends only on its own depth, so the visit order is irrelevant — but
    # the native recursion this replaces overflowed the stack on a pathologically deep path,
    # and like `endpoint_count` it runs on EVERY sitemap reload.
    private def self.apply_expand_depth_node!(root : Node, root_depth : Int32, depth : Int32) : Nil
      stack = [{root, root_depth}]
      while entry = stack.pop?
        node, node_depth = entry
        if node.grouped
          node.expanded = false
        elsif depth < 0
          node.expanded = true
        else
          node.expanded = node_depth < depth
        end
        node.children.each { |c| stack << {c, node_depth + 1} }
      end
    end
  end
end
