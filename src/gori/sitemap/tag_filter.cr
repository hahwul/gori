require "../filter_ast"

module Gori
  module Sitemap
    # A sitemap query's `tag:` terms, cut off the QL the rest of it compiles to. `tag:` is a
    # SITEMAP field, not a flow field: a tag is the operator's memo on a (host, path) node
    # (`Store#sitemap_tags`, V17), keyed on no flow, so there is no column for QL to compile it
    # to and it filters the built tree instead. The TUI Sitemap bar, `gori run sitemap` and MCP
    # `list_sitemap` all read a query through `split_tag_terms`, so the three agree on it.
    #
    # `positives` / `negatives` are the lowercased keywords of the `tag:x` and `-tag:x` (or
    # `NOT tag:x`) terms. `residual` is the query with those terms cut out, for QL.
    record TagTerms, positives : Array(String), negatives : Array(String), residual : String do
      # Whether the query carries any tag term at all.
      def filtering? : Bool
        !positives.empty? || !negatives.empty?
      end

      # The residual as the query a QL caller should compile and validate: nil when it holds no
      # term (see `Sitemap.residual_terms?`), so a tag-only query — or one that left a bare `OR`
      # behind — filters nothing and is refused for nothing.
      def ql : String?
        Sitemap.residual_terms?(residual) ? residual : nil
      end
    end

    # Whether a residual still carries a term. `QL.reject_empty?` reads a non-blank query
    # that compiled to nothing as "every term was invalid". That is right for what the
    # operator typed, but the residual is what is LEFT after the tag terms were cut out, so
    # `tag:a OR tag:b` hands it the bare word `OR` — no terms at all — and the whole sitemap
    # blanked behind an "invalid filter" note. Only a residual that still carries a term
    # can be invalid.
    def self.residual_terms?(residual : String) : Bool
      !FilterAst.terms(FilterAst.parse(residual)).empty?
    end

    # Split `tag:` terms out of `query`. Cut with the SHARED lexer, not `String#split`:
    # hand-tokenising saw no quotes (`tag:"my tag"` became `tag:"my` + `tag"`) and no
    # `NOT` (`NOT tag:done` filed `done` as a POSITIVE and then blanked the tree on the
    # leftover `NOT`), while the bar above it was already highlighting all of that as
    # real grammar. Negation rides the same `Term#negate?` every other filter uses, so
    # `-tag:x` and `NOT tag:x` are the same thing here too.
    #
    # Every tag term is ANDed with the rest (`FilterAst.partition` keeps no boolean
    # structure): `tag:a OR tag:b` asks for a tag carrying both keywords.
    def self.split_tag_terms(query : String) : TagTerms
      positives = [] of String
      negatives = [] of String
      # A half-typed `tag:` (no value yet) stays in the residual, so the TUI tree doesn't
      # blank out mid-keystroke.
      taken, residual = FilterAst.partition(query) { |t| !tag_token_value(t.text).nil? }
      taken.each do |t|
        if v = tag_token_value(t.text)
          (t.negate? ? negatives : positives) << v
        end
      end
      TagTerms.new(positives, negatives, residual)
    end

    # The keyword of a `tag:x` term, or nil if this isn't one (or has no value yet). Matching
    # is a case-insensitive SUBSTRING of the memo, so the keyword is lowercased here once.
    private def self.tag_token_value(text : String) : String?
      return nil unless text.downcase.starts_with?("tag:")
      v = text[4..].downcase
      v.empty? ? nil : v
    end

    # Prune a STAMPED tree (`stamp_tags!` first) to tag matches: a node survives a positive
    # term if it (or an ancestor) carries a tag containing every positive keyword, or any
    # descendant does (so a tagged folder shows its subtree + the path to it). A negative term
    # drops the matched subtree. A synthetic fold carries no tag, so run this before folding.
    def self.filter_by_tags!(hosts : Array(Node), positives : Array(String), negatives : Array(String)) : Nil
      hosts.select! { |h| keep_for_tags?(h, positives, false) } unless positives.empty?
      hosts.select! { |h| !exclude_for_tags?(h, negatives) } unless negatives.empty?
    end

    # The FLAT twin of `filter_by_tags!`, for a surface that lists endpoint rows rather than
    # drawing the tree (MCP `list_sitemap`): the rows whose endpoint node survives the tree
    # filter when the tree is built from exactly these rows. Building it, rather than asking
    # "is an ancestor tagged" per row, is what keeps the descendant half of the rule — an
    # endpoint `/api` is kept when `/api/users` under it matched, as the tree keeps it — and
    # roots keyed the way the tree keys them.
    #
    # The block maps a row to what `build` takes: a `Store::SitemapOriginEntry` for the origin
    # tree every surface draws, or a bare (host, method, target) triple for a host-level one.
    def self.select_by_tags(rows : Array(T), tags : Hash({String, String}, String),
                            terms : TagTerms, & : T -> E) : Array(T) forall T, E
      return rows unless terms.filtering?
      # Index iteration (not `map`) keeps `yield` out of a block, as `post_order` does.
      keys = [] of E
      i = 0
      while i < rows.size
        keys << yield rows[i]
        i += 1
      end
      hosts = build(keys)
      stamp_tags!(hosts, tags)
      filter_by_tags!(hosts, terms.positives, terms.negatives)
      kept = Set({String, String}).new
      hosts.each do |h|
        post_order(h) { |n| kept << {h.label, n.path} unless n.methods.empty? }
      end
      selected = [] of T
      rows.each_with_index { |r, j| selected << r if kept.includes?(row_key(keys[j])) }
      selected
    end

    private def self.row_key(e : Store::SitemapOriginEntry) : {String, String}
      {Origin.new(e.scheme, e.host, e.port).label, node_path(e.target)}
    end

    private def self.row_key(e : {String, String, String}) : {String, String}
      {e[0], node_path(e[2])}
    end

    # Returns true if `node` survives; prunes non-surviving children in place. `inside`
    # = an ancestor already matched all positives ⇒ keep the whole subtree.
    #
    # Two explicit passes rather than native recursion (see `post_order` for the
    # SIGSEGV this class of walk caused): this one threads `within` DOWN and combines
    # `kept_child` UP, which no single-direction work-list expresses. Pass 1 collects nodes
    # parent-before-child with their `within`; pass 2 walks that list in REVERSE, so every
    # node is pruned only after its whole subtree — exactly the order the recursion had.
    # `verdict` is keyed by Node identity (`Node` overrides neither `==` nor `hash`, so Hash
    # falls back to reference equality).
    private def self.keep_for_tags?(root : Node, positives : Array(String), inside : Bool) : Bool
      order = [{root, inside || tag_has_all?(root, positives)}]
      i = 0
      while i < order.size
        node, within = order[i]
        node.children.each { |c| order << {c, within || tag_has_all?(c, positives)} }
        i += 1
      end

      verdict = {} of Node => Bool
      i = order.size - 1
      while i >= 0
        node, within = order[i]
        kept_child = false
        node.children.select! do |c|
          keep = verdict[c]
          kept_child ||= keep
          keep
        end
        verdict[node] = within || kept_child
        i -= 1
      end
      verdict[root]
    end

    # Returns true if `node`'s subtree should be dropped (it carries a negative tag);
    # otherwise prunes any dropped descendants in place.
    #
    # Iterative for the same reason as `keep_for_tags?`. A node that matches is dropped
    # whole and never descended into, so this is just "reject matching children, then
    # descend into the survivors" — no verdict has to travel back up.
    private def self.exclude_for_tags?(root : Node, negatives : Array(String)) : Bool
      return true if tag_has_any?(root, negatives)
      stack = [root]
      while node = stack.pop?
        node.children.reject! { |c| tag_has_any?(c, negatives) }
        node.children.each { |c| stack << c }
      end
      false
    end

    private def self.tag_has_all?(node : Node, keywords : Array(String)) : Bool
      t = node.tag
      return false unless t
      down = t.downcase
      keywords.all? { |kw| down.includes?(kw) }
    end

    private def self.tag_has_any?(node : Node, keywords : Array(String)) : Bool
      t = node.tag
      return false unless t
      down = t.downcase
      keywords.any? { |kw| down.includes?(kw) }
    end
  end
end
