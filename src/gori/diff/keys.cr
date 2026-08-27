require "../sitemap"

module Gori::Diff
  # The endpoint identity the whole diff is keyed on: a host, a verb, and a path
  # TEMPLATE — `/users/{uuid}/orders`, not `/users/3f2a…/orders`.
  #
  # Identity is the crux of a retest diff. Two engagements never capture the same ids,
  # so a diff keyed on literal paths reports every row twice (once "removed", once
  # "added") and says nothing. The folding that fixes that already exists and is already
  # what the operator is looking at — `Sitemap`'s `fold_templates!` / `group_sequences!` /
  # `fold_queries!` passes — so this module reuses those rather than inventing a second
  # normalization. A key that disagreed with the Sitemap tab would make the diff and the
  # tab describe different endpoints (P3).
  record Key, host : String, method : String, path : String do
    # "GET /users/{uuid}" — the row label, host omitted (rows group under their host).
    def label : String
      "#{method} #{path}"
    end

    def to_s(io : IO) : Nil
      io << method << ' ' << host << path
    end
  end

  # Derives folded path templates for a set of captured endpoints.
  #
  # Folds the UNION of BOTH sides at once, deliberately. Every fold pass has a count
  # threshold (`SEQUENCE_GROUP_THRESHOLD`, `TEMPLATE_GROUP_THRESHOLD`), so folding each
  # side alone lets the SAME route fold on the side that happened to capture more ids and
  # stay literal on the other — which is precisely the added/removed noise the folding is
  # here to remove. One tree, one set of fold decisions, both sides keyed by it.
  class Templates
    # The literal `Sitemap::Node#path` a fold's children are absorbed into, per host.
    @by_host : Hash(String, Hash(String, String))

    # The label a numeric-run fold contributes to a template. `group_sequences!` labels
    # its fold with the VALUES it captured (`[1, 2, 3 … +47]`), which is a fine thing to
    # read in a tree and a useless key across two engagements — the values differ, so the
    # label differs, so the route would not match itself. The id folds' own labels
    # (`{uuid}`/`{hex}`/`{date}`) are already value-independent and are kept verbatim.
    NUMERIC_LABEL = "{n}"

    def initialize(entries : Enumerable({String, String, String}))
      @by_host = {} of String => Hash(String, String)
      hosts = Sitemap.build(entries)
      hosts.each do |host|
        # The same three passes, in the same order, as `gori run sitemap` and the TUI tree.
        Sitemap.fold_templates!(host)
        Sitemap.group_sequences!(host)
        Sitemap.fold_queries!(host)
        @by_host[host.label] = map_host(host)
      end
    end

    # The folded template for one captured (host, target), or the target's own tree path
    # when this host contributed nothing to the tree (a caller asking about an endpoint
    # from the other side, or a target so deep `Sitemap` cut it — see `Sitemap.node_path`).
    def template(host : String, target : String) : String
      path = Sitemap.node_path(target)
      @by_host[host]?.try(&.[path]?) || path
    end

    def key(host : String, method : String, target : String) : Key
      Key.new(host, method, template(host, target))
    end

    # Walk one host's folded tree, accumulating the template path down each branch, and
    # record it for every REAL node's literal path.
    #
    # A fold contributes its label as one segment and its children contribute NOTHING —
    # `/users/<uuid-a>` and `/users/<uuid-b>` are both `/users/{uuid}`, while a
    # GRANDchild keeps going (`/users/{uuid}/orders`). That is the same collapse the
    # collapsed tree row draws.
    private def map_host(host : Sitemap::Node) : Hash(String, String)
      out = {} of String => String
      # Explicit stack rather than `Sitemap.post_order`: this walk threads state DOWN
      # (the accumulated template, and whether the parent absorbed its children), which
      # post_order's collect-then-yield shape cannot carry. Iterative for the reason every
      # walk in Sitemap is — one pathologically deep captured path overflows the native
      # stack (see `Sitemap.post_order`).
      stack = [] of {Sitemap::Node, String, Bool}
      host.children.each { |c| stack << {c, "", false} }
      while entry = stack.pop?
        node, parent_tpl, absorbed = entry
        tpl = absorbed ? parent_tpl : extend_template(parent_tpl, node)
        out[node.path] = tpl unless node.grouped || node.path.empty?
        node.children.each { |c| stack << {c, tpl, node.grouped} }
      end
      out
    end

    # `parent_tpl` plus this node's own segment.
    private def extend_template(parent_tpl : String, node : Sitemap::Node) : String
      seg = segment_label(node)
      # The bare-root node's label IS "/" (see `Sitemap.add`), so appending it with a
      # separator would spell "//".
      return "/" if seg == "/"
      "#{parent_tpl}/#{seg}"
    end

    private def segment_label(node : Sitemap::Node) : String
      return Sitemap.path_part(node.label) unless node.grouped
      # A query fold's label is a real path segment; an id fold's is already a placeholder;
      # only the numeric run needs its value-bearing label replaced.
      return node.label if node.query_fold || node.template?
      NUMERIC_LABEL
    end
  end
end
