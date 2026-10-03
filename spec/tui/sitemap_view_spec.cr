require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def capture(store, host, method, target)
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: host, port: 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
end

private def capture_at(store, scheme, host, port, target, method = "GET")
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: scheme, host: host, port: port,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
end

private def capture_image(store, host, target)
  id = capture(store, host, "GET", target)
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, content_type: "image/png",
    head: "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\n".to_slice,
    state: Gori::Store::FlowState::Complete))
  id
end

# Rows rendering the marked-row gutter bar ('▌'; the cursor row's is the thinner '▎').
private def marked_row_indexes(b)
  (0...20).select { |y| b.row(y).includes?("▌") }
end

describe Gori::Tui::SitemapView do
  it "builds and renders a literal host -> path tree" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/api/users/123")
      capture(store, "acme.test", "POST", "/api/orders")
      capture(store, "acme.test", "GET", "/")

      view = SitemapView.new
      view.reload(store)

      backend = MemoryBackend.new(70, 20)
      view.render(Screen.new(backend), Rect.new(0, 0, 70, 20))

      backend.contains?("acme.test").should be_true # host node
      backend.contains?("api").should be_true       # shared segment
      backend.contains?("users").should be_true
      backend.contains?("123").should be_true # literal id (not templated)
      backend.contains?("orders").should be_true
      backend.contains?("POST").should be_true # method annotation on leaf
    end
  end

  # A path deeper than the pane is wide (a crawler trap) must not draw past the pane.
  it "keeps a very deep row inside the pane" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/" + (1..40).map { |i| "s#{i}" }.join("/"))
      view = SitemapView.new
      view.reload(store)
      backend = MemoryBackend.new(60, 50)
      view.render(Screen.new(backend), Rect.new(0, 0, 40, 50))
      # From the first tree row: the header divider's `┤` joins the parent frame's border.
      (3...50).each { |y| backend.row(y)[40..].strip.should eq(""), "row #{y} ran past the pane" }
    end
  end

  it "collapses and expands nodes" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/api/users")
      view = SitemapView.new
      view.reload(store)

      # selection starts at the host node; collapsing it hides children
      view.collapse.should be_true
      backend = MemoryBackend.new(70, 20)
      view.render(Screen.new(backend), Rect.new(0, 0, 70, 20))
      backend.contains?("acme.test").should be_true
      backend.contains?("users").should be_false # hidden while host collapsed

      view.expand
      backend2 = MemoryBackend.new(70, 20)
      view.render(Screen.new(backend2), Rect.new(0, 0, 70, 20))
      backend2.contains?("users").should be_true
    end
  end

  it "renders an empty-state when nothing is captured" do
    with_store do |store|
      view = SitemapView.new
      view.reload(store)
      # 15 rows is the least the SITE MAP card fits in (9 interior + 2 borders + headline,
      # inside the tree rect below this view's chrome); below that TrafficEmptyState degrades
      # to plain lines, which keep the address and the hints but drop the card title.
      backend = MemoryBackend.new(70, 15)
      view.render(Screen.new(backend), Rect.new(0, 0, 70, 15),
        listen: {"127.0.0.1", 8070}, capturing: true)
      backend.contains?("no traffic captured").should be_true
      backend.contains?("localhost:8070").should be_true
      backend.contains?("Open browser").should be_true
      backend.contains?("SITE MAP").should be_true
      backend.contains?("HOST / PATH").should be_true
      backend.contains?("TAG").should be_true
      backend.contains?("METHODS").should be_true
    end
  end

  it "filters the tree with a QL query" do
    with_store do |store|
      capture(store, "api.acme.test", "GET", "/v1/users")
      capture(store, "cdn.acme.test", "GET", "/assets/app.js")

      view = SitemapView.new
      view.reload(store)
      b0 = MemoryBackend.new(70, 20)
      view.render(Screen.new(b0), Rect.new(0, 0, 70, 20))
      b0.contains?("api.acme.test").should be_true
      b0.contains?("cdn.acme.test").should be_true

      # type `host:api` into the QL bar and re-derive the tree
      view.start_query
      "host:api".each_char { |c| view.query_insert(c) }
      view.reload(store)

      b1 = MemoryBackend.new(70, 20)
      view.render(Screen.new(b1), Rect.new(0, 0, 70, 20))
      b1.contains?("api.acme.test").should be_true
      b1.contains?("cdn.acme.test").should be_false
    end
  end

  it "folds static assets out of the tree, and out of the Params flow set, while the lens is on" do
    with_store do |store|
      capture(store, "api.acme.test", "GET", "/v1/users")
      capture_image(store, "cdn.acme.test", "/img/logo.png")

      view = SitemapView.new
      view.set_hide_static(true)
      view.reload(store)
      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))
      b.contains?("api.acme.test").should be_true
      b.contains?("cdn.acme.test").should be_false
      b.contains?("static:hidden").should be_true
      view.params_filter.not_nil!.sql.should contain(Gori::QL.hide_static.sql)

      view.set_hide_static(false)
      view.reload(store)
      b2 = MemoryBackend.new(70, 20)
      view.render(Screen.new(b2), Rect.new(0, 0, 70, 20))
      b2.contains?("cdn.acme.test").should be_true
    end
  end

  it "shows the traffic empty state, not a lens sentence, for a project with no flows" do
    with_store do |store|
      view = SitemapView.new
      view.set_hide_static(true)
      view.reload(store)
      b = MemoryBackend.new(70, 15)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 15), listen: {"127.0.0.1", 8070}, capturing: true)
      b.contains?("no traffic captured").should be_true
      b.contains?("only static assets").should be_false

      capture_image(store, "cdn.acme.test", "/img/logo.png")
      view.reload(store)
      b2 = MemoryBackend.new(70, 15)
      view.render(Screen.new(b2), Rect.new(0, 0, 70, 15))
      b2.contains?("only static assets so far").should be_true
    end
  end

  # The same silence History carries, one tab over: an unknown `field:` free-texts the whole
  # token and matches nothing, which on an empty tree reads as "nothing was mapped".
  it "names a misspelled filter field in the empty-state" do
    with_store do |store|
      capture(store, "api.acme.test", "GET", "/v1/users")

      view = SitemapView.new
      view.reload(store)
      view.start_query
      "pth:/v1".each_char { |c| view.query_insert(c) }
      view.reload(store)

      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))
      rows = (0...20).map { |y| b.row(y) }.join("\n")
      rows.should contain("unknown field `pth:`")
      rows.should contain("did you mean `path:`")
    end
  end

  # `tag:` is this bar's own field and QL knows nothing about it, so a pool taken from QL alone
  # left the one field this surface adds as the one field it could never diagnose a typo of.
  it "suggests its own tag: field, which QL has never heard of" do
    with_store do |store|
      capture(store, "api.acme.test", "GET", "/v1/users")

      view = SitemapView.new
      view.reload(store)
      view.start_query
      "tagg:prod".each_char { |c| view.query_insert(c) }
      view.reload(store)

      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))
      (0...20).map { |y| b.row(y) }.join("\n").should contain("did you mean `tag:`")
    end
  end

  it "rejects an all-invalid QL query instead of showing the whole tree" do
    with_store do |store|
      capture(store, "api.acme.test", "GET", "/v1/users")
      capture(store, "cdn.acme.test", "GET", "/assets/app.js")

      view = SitemapView.new
      view.reload(store)
      view.start_query
      "dur:>2sec".each_char { |c| view.query_insert(c) } # every term invalid → match-all EMPTY
      view.reload(store)

      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))
      b.contains?("api.acme.test").should be_false # must NOT show the whole tree behind an "active" filter
      b.contains?("cdn.acme.test").should be_false
      rows = (0...20).map { |y| b.row(y) }.join("\n")
      rows.should contain("invalid filter")
    end
  end

  it "does NOT reject a tag:-only query (its QL residual is blank)" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/api/users")
      capture(store, "acme.test", "GET", "/static/app.js")
      store.set_sitemap_tag("acme.test", "/api", "payment")

      view = SitemapView.new
      view.reload(store)
      view.start_query
      "tag:pay".each_char { |c| view.query_insert(c) } # residual "" → EMPTY, but valid (tag filter)
      view.reload(store)

      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))
      b.contains?("acme.test").should be_true # the tag filter applies; NOT rejected as invalid
      b.contains?("users").should be_true
      rows = (0...20).map { |y| b.row(y) }.join("\n")
      rows.should_not contain("invalid filter")
    end
  end

  it "flags an invalid regex filter term in the empty-state" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/")
      view = SitemapView.new
      view.reload(store)
      view.start_query
      "path~[bad".each_char { |c| view.query_insert(c) } # unterminated class → never-match "0"
      view.reload(store)

      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))
      rows = (0...20).map { |y| b.row(y) }.join("\n")
      rows.should contain("invalid regex")
    end
  end

  it "renders the filter bar: scope chip + hint, then the filter prompt" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/")
      view = SitemapView.new
      view.reload(store)

      b0 = MemoryBackend.new(70, 20)
      view.render(Screen.new(b0), Rect.new(0, 0, 70, 20))
      b0.contains?("filter").should be_true
      b0.contains?("scope:off").should be_true

      view.start_query
      "host:acme".each_char { |c| view.query_insert(c) }
      b1 = MemoryBackend.new(70, 20)
      view.render(Screen.new(b1), Rect.new(0, 0, 70, 20))
      b1.contains?("filter ›").should be_true # active editing prompt (unified with Issues/Probe)
      b1.contains?("host:acme").should be_true
    end
  end

  it "uses live keys in the scope and grouping chips" do
    previous = Gori::Settings.keymap_overrides
    begin
      Gori::Settings.keymap_overrides = {"scope.toggle-lens"       => ["shift-s"],
                                         "sitemap.toggle-grouping" => ["shift-g"]}
      with_store do |store|
        view = SitemapView.new
        view.set_registry(Gori::Verbs.registry)
        view.reload(store)
        backend = MemoryBackend.new(90, 12)
        view.render(Screen.new(backend), Rect.new(0, 0, 90, 12))
        backend.contains?("⇧S scope:off").should be_true
        backend.contains?("⇧G:fold").should be_true
        backend.contains?("g:fold").should be_false
      end
    ensure
      Gori::Settings.keymap_overrides = previous
    end
  end

  it "completes a field name with Tab" do
    view = SitemapView.new
    view.start_query
    "met".each_char { |c| view.query_insert(c) }
    view.query_complete.should be_true
    view.querying?.should be_true

    b = MemoryBackend.new(70, 6)
    view.render(Screen.new(b), Rect.new(0, 0, 70, 6))
    b.contains?("method:").should be_true
  end

  it "marks in-scope hosts with a scope glyph even when the `s` lens is off" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/api/users")
      capture(store, "cdn.vendor.test", "GET", "/app.js")

      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test") # configured but NOT enabled (lens off)
      scope.active?.should be_false

      view = SitemapView.new
      view.set_scope(scope)
      view.reload(store)

      backend = MemoryBackend.new(70, 20)
      view.render(Screen.new(backend), Rect.new(0, 0, 70, 20))
      # Lens off ⇒ no filtering: both hosts are visible…
      backend.contains?("acme.test").should be_true
      backend.contains?("cdn.vendor.test").should be_true
      # …but only the in-scope host carries the filled-diamond marker.
      in_row = (0...20).find { |y| backend.row(y).includes?("acme.test") }.not_nil!
      out_row = (0...20).find { |y| backend.row(y).includes?("cdn.vendor.test") }.not_nil!
      backend.row(in_row).includes?('◆').should be_true
      backend.row(out_row).includes?('◆').should be_false
    end
  end

  it "shows an endpoint count on host rows" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/api/users")
      capture(store, "acme.test", "POST", "/api/orders")
      capture(store, "acme.test", "GET", "/health")

      view = SitemapView.new
      view.reload(store)
      backend = MemoryBackend.new(70, 20)
      view.render(Screen.new(backend), Rect.new(0, 0, 70, 20))
      backend.contains?("3 paths").should be_true
    end
  end

  it "colours method chips by verb on endpoint rows" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/users")

      view = SitemapView.new
      view.reload(store)
      backend = MemoryBackend.new(70, 20)
      view.render(Screen.new(backend), Rect.new(0, 0, 70, 20))
      backend.contains?("GET").should be_true
      y = (0...20).find { |yy| backend.row(yy).includes?("GET") }.not_nil!
      gx = backend.row(y).index("GET").not_nil!
      backend.fg_at(gx, y).should eq(Theme.method_color("GET")) # not muted
    end
  end

  it "draws tree guide lines for nested nodes" do
    with_store do |store|
      capture(store, "a.test", "GET", "/x/y") # nested + a following host ⇒ a │ guide
      capture(store, "b.test", "GET", "/z")

      view = SitemapView.new
      view.reload(store)
      backend = MemoryBackend.new(70, 20)
      view.render(Screen.new(backend), Rect.new(0, 0, 70, 20))
      backend.contains?("│").should be_true
    end
  end

  it "folds a long numeric sequence into a collapsed group; `g` unfolds it" do
    with_store do |store|
      (1001..1012).each { |i| capture(store, "acme.test", "GET", "/users/#{i}") } # 12 > threshold(10)

      view = SitemapView.new
      view.reload(store)
      b = MemoryBackend.new(70, 24)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 24))
      b.contains?("[1001, 1002, 1003").should be_true # the fold preview
      b.contains?("12 values").should be_true         # the folded-count chip
      b.contains?("1010").should be_false             # a folded value, hidden while collapsed

      view.toggle_grouping
      view.reload(store)
      b2 = MemoryBackend.new(70, 24)
      view.render(Screen.new(b2), Rect.new(0, 0, 70, 24))
      b2.contains?("[1001").should be_false # no group node
      b2.contains?("1010").should be_true   # every literal id back
    end
  end

  it "folds uuid siblings into a collapsed {uuid}; `g` unfolds it" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678")
      capture(store, "acme.test", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00")

      view = SitemapView.new
      view.reload(store)
      b = MemoryBackend.new(90, 24)
      view.render(Screen.new(b), Rect.new(0, 0, 90, 24))
      b.contains?("{uuid}").should be_true
      b.contains?("2 values").should be_true
      b.contains?("GET").should be_true       # the fold's stand-in verbs, while collapsed
      b.contains?("3f2a8b1c").should be_false # folded away while collapsed

      view.toggle_grouping
      view.reload(store)
      b2 = MemoryBackend.new(90, 24)
      view.render(Screen.new(b2), Rect.new(0, 0, 90, 24))
      b2.contains?("{uuid}").should be_false
      b2.contains?("3f2a8b1c").should be_true # every literal id back
    end
  end

  it "folds query-string variants into one path row; ⇧G unfolds them" do
    with_store do |store|
      capture(store, "shop.demo.test", "GET", "/search?q=widgets")
      capture(store, "shop.demo.test", "GET", "/search?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E")

      view = SitemapView.new
      view.reload(store)
      b = MemoryBackend.new(90, 24)
      view.render(Screen.new(b), Rect.new(0, 0, 90, 24))
      b.contains?("search").should be_true
      b.contains?("2 queries").should be_true # the folded-count chip, counted as queries
      b.contains?("GET").should be_true       # the fold's stand-in verbs, while collapsed
      b.contains?("script").should be_false   # the payload never becomes a row
      b.contains?("1 path").should be_true    # ...and the endpoint count agrees with the row

      view.fold_query?.should be_true
      view.toggle_fold_query
      view.fold_query?.should be_false
      view.reload(store)
      b2 = MemoryBackend.new(90, 24)
      view.render(Screen.new(b2), Rect.new(0, 0, 90, 24))
      b2.contains?("q=widgets").should be_true
      b2.contains?("2 paths").should be_true
    end
  end

  it "leaves a query-less path as one plain row" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/search")
      view = SitemapView.new
      view.reload(store)
      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))
      b.contains?("search").should be_true
      b.contains?("queries").should be_false
      b.contains?("1 path").should be_true
    end
  end

  it "keeps id folding on its own axis: `g` does not explode the query fold" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678")
      capture(store, "acme.test", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00")
      capture(store, "acme.test", "GET", "/search?q=widgets")
      capture(store, "acme.test", "GET", "/search?q=other")

      view = SitemapView.new
      view.reload(store)
      b = MemoryBackend.new(90, 24)
      view.render(Screen.new(b), Rect.new(0, 0, 90, 24))
      b.contains?("{uuid}").should be_true
      b.contains?("2 queries").should be_true

      view.toggle_grouping # id folding OFF — the query fold is untouched
      view.reload(store)
      b2 = MemoryBackend.new(90, 24)
      view.render(Screen.new(b2), Rect.new(0, 0, 90, 24))
      b2.contains?("3f2a8b1c").should be_true  # every literal id back
      b2.contains?("2 queries").should be_true # ...and the queries still folded
      b2.contains?("q=widgets").should be_false
    end
  end

  it "resolves the fold to a concrete captured target for Repeater, and to its path for scope" do
    with_store do |store|
      capture(store, "shop.demo.test", "GET", "/search?q=widgets")
      capture(store, "shop.demo.test", "GET", "/search?q=other")

      view = SitemapView.new
      view.reload(store)
      view.move(1) # host row → the /search fold
      # Repeater/open-flow look a flow up by exact equality on flows.target, so the fold has
      # to hand them a variant, not the path it displays.
      # ...the first variant under it, in the store's ORDER BY target order.
      origin = Gori::Sitemap::Origin.new("http", "shop.demo.test", 80)
      view.selected_endpoint.should eq({host: "shop.demo.test", method: "GET", target: "/search?q=other", origin: origin})
      # Scope/Discover instead mean the PATH — a query fold has a real one, unlike {uuid}.
      view.selected_scope_seed.should eq({match_type: "string", pattern: "shop.demo.test/search"})
      view.selected_endpoint(:container).should eq({host: "shop.demo.test", method: "GET", target: "/search", origin: origin})
    end
  end

  it "refuses to tag or mark a query fold, as it refuses an id fold" do
    with_store do |store|
      capture(store, "shop.demo.test", "GET", "/search?q=widgets")
      capture(store, "shop.demo.test", "GET", "/search?q=other")

      view = SitemapView.new
      view.reload(store)
      view.move(1)                     # the fold row
      view.toggle_mark.should be_false # synthetic: no (host, path) key to mark
      view.mark_count.should eq(0)
      view.start_tag.should be_false # ...and nothing taggable, exactly as on a {uuid} fold
    end
  end

  it "keeps an expanded fold open across reload (live capture poll)" do
    # Regression: apply_expand_depth! force-collapses every fold on every rebuild, and the
    # expand-state walk used to skip synthetic nodes entirely — so a fold the user opened
    # snapped shut on the next ~750ms poll and its subtree was unreadable during capture.
    with_store do |store|
      capture(store, "acme.test", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678")
      capture(store, "acme.test", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00")

      view = SitemapView.new
      view.reload(store)
      view.move(1) # users
      view.move(1) # {uuid}
      view.expand

      b = MemoryBackend.new(90, 24)
      view.render(Screen.new(b), Rect.new(0, 0, 90, 24))
      b.contains?("3f2a8b1c").should be_true # open

      capture(store, "acme.test", "GET", "/other") # external-change style tree growth
      view.reload(store)

      b2 = MemoryBackend.new(90, 24)
      view.render(Screen.new(b2), Rect.new(0, 0, 90, 24))
      b2.contains?("3f2a8b1c").should be_true # STILL open after the poll
    end
  end

  it "keeps the cursor on a fold row across reload" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678")
      capture(store, "acme.test", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00")

      view = SitemapView.new
      view.reload(store)
      view.move(1)
      view.move(1) # park on the {uuid} fold
      sel = view.@selected

      # Sorts AFTER /users, so the fold keeps its row index and only the anchor is on trial.
      capture(store, "acme.test", "GET", "/zzz")
      view.reload(store)

      view.@selected.should eq(sel) # not thrown back to the host row
    end
  end

  it "lands on the enclosing fold when a new sibling swallows the selected row" do
    # At the id-fold threshold this fires during ordinary browsing: the SECOND uuid of a
    # kind materialises the fold and hides the row the cursor was sitting on.
    with_store do |store|
      capture(store, "acme.test", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678")

      view = SitemapView.new
      view.reload(store)
      view.move(1) # users
      view.move(1) # the literal uuid (no fold yet — one is below the threshold)

      capture(store, "acme.test", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00")
      view.reload(store)

      view.@selected.should eq(2) # the {uuid} fold that swallowed it, not row 0
    end
  end

  it "resolves a fold to a descendant for Repeater and to the container for Discover" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678")
      capture(store, "acme.test", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00")

      view = SitemapView.new
      view.reload(store)
      view.move(1)
      view.move(1) # the {uuid} fold

      # Repeater/Sequencer need a CONCRETE target (exact equality on flows.target).
      ep = view.selected_endpoint.should_not be_nil
      ep[:target].should start_with("/users/")
      ep[:target].should_not eq("/users")
      ep[:method].should eq("GET")

      # Discover scans a subtree: "under /users", not under one uuid.
      view.selected_endpoint(:container).should_not be_nil
      view.selected_endpoint(:container).not_nil![:target].should eq("/users")
    end
  end

  it "seeds a scope rule from the cursor: host row -> host rule, path row -> host+path string" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/api/users")

      view = SitemapView.new
      view.reload(store)

      # Row 0 is the host: the whole site, so the precise `host` type (subdomain/glob aware).
      seed = view.selected_scope_seed.should_not be_nil
      seed[:match_type].should eq("host")
      seed[:pattern].should eq("acme.test")

      # Any path row narrows to a substring of scheme://host/target — Scope has no path type.
      view.move(1) # /api
      seed = view.selected_scope_seed.should_not be_nil
      seed[:match_type].should eq("string")
      seed[:pattern].should eq("acme.test/api")

      view.move(1) # /api/users
      view.selected_scope_seed.not_nil![:pattern].should eq("acme.test/api/users")
    end
  end

  it "seeds a fold's scope rule from its CONTAINER, not one folded child" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678")
      capture(store, "acme.test", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00")

      view = SitemapView.new
      view.reload(store)
      view.move(1)
      view.move(1) # the {uuid} fold

      seed = view.selected_scope_seed.should_not be_nil
      # A rule pinned to one uuid would scope out every OTHER user — and `{uuid}` is not a
      # real path, so it could never match at all.
      seed[:match_type].should eq("string")
      seed[:pattern].should eq("acme.test/users")
    end
  end

  it "refuses to tag a template fold" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678")
      capture(store, "acme.test", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00")

      view = SitemapView.new
      view.reload(store)
      view.move(1)
      view.move(1) # the {uuid} fold
      view.start_tag.should be_false
    end
  end

  it "leaves a short numeric sequence ungrouped" do
    with_store do |store|
      (1..5).each { |i| capture(store, "acme.test", "GET", "/a/#{i}") } # 5 <= threshold

      view = SitemapView.new
      view.reload(store)
      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))
      b.contains?("[1, 2, 3").should be_false
      b.contains?("5").should be_true # literal ids
    end
  end

  it "stamps and renders a persisted path tag" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/api/users")
      store.set_sitemap_tag("acme.test", "/api", "payment flow")

      view = SitemapView.new
      view.reload(store)
      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))
      b.contains?("# payment flow").should be_true
    end
  end

  it "keeps at least one blank column between a tag and method chips on the same row" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/api/users")
      store.set_sitemap_tag("acme.test", "/api/users", "memo")

      view = SitemapView.new
      view.reload(store)
      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))

      y = (0...20).find { |yy| b.row(yy).includes?("GET") && b.row(yy).includes?("# memo") }.not_nil!
      row = b.row(y)
      tag_end = row.index("# memo").not_nil! + "# memo".size - 1
      method_start = row.index("GET").not_nil!
      (method_start - tag_end).should be > 1
    end
  end

  it "filters the tree by a tag: query (folder tag keeps its subtree)" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/api/users")
      capture(store, "acme.test", "GET", "/static/app.js")
      store.set_sitemap_tag("acme.test", "/api", "payment")

      view = SitemapView.new
      view.reload(store)
      view.start_query
      "tag:pay".each_char { |c| view.query_insert(c) }
      view.reload(store)

      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))
      b.contains?("acme.test").should be_true # ancestor of the match kept
      b.contains?("users").should be_true     # the tagged folder's subtree kept
      b.contains?("static").should be_false   # untagged sibling pruned
    end
  end

  it "cuts tag: terms with the shared lexer, so quoting and NOT work" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/api/users")
      capture(store, "acme.test", "GET", "/static/app.js")
      store.set_sitemap_tag("acme.test", "/api", "my flow")

      # `String#split` tore this into `tag:"my` + `flow"`, so the tag never matched.
      view = SitemapView.new
      view.reload(store)
      view.start_query
      %(tag:"my flow").each_char { |c| view.query_insert(c) }
      view.reload(store)

      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))
      b.contains?("users").should be_true
      b.contains?("static").should be_false
    end
  end

  it "treats NOT tag:x as exclusion, like -tag:x" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/api/users")
      capture(store, "acme.test", "GET", "/static/app.js")
      store.set_sitemap_tag("acme.test", "/api", "done")

      # Hand-tokenising filed `tag:done` as a POSITIVE and then blanked the tree on the
      # leftover bare `NOT` — the exact inverse of what was asked.
      view = SitemapView.new
      view.reload(store)
      view.start_query
      "NOT tag:done".each_char { |c| view.query_insert(c) }
      view.reload(store)

      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))
      b.contains?("static").should be_true # the untagged sibling survives
      b.contains?("users").should be_false # the tagged subtree is excluded
    end
  end

  it "does not blank the tree when cutting tags leaves only an operator" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/api/users")
      store.set_sitemap_tag("acme.test", "/api", "payment")

      # `tag:a OR tag:b` hands QL the residual `OR`. That has no terms, so it cannot be
      # "every term was invalid" — it used to blank the whole sitemap behind that note.
      view = SitemapView.new
      view.reload(store)
      view.start_query
      "tag:payment OR tag:payment".each_char { |c| view.query_insert(c) }
      view.reload(store)

      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))
      b.contains?("users").should be_true
    end
  end

  it "re-anchors selection, scroll, and manual collapse across reload (live capture poll)" do
    # Regression: data_version polls used to zero @selected/@scroll every rebuild,
    # so navigating deep under live traffic kept jumping back to the top host.
    with_store do |store|
      capture(store, "acme.test", "GET", "/api/users/1")
      capture(store, "acme.test", "GET", "/api/users/2")
      capture(store, "other.test", "GET", "/x")

      view = SitemapView.new
      view.reload(store)
      # Walk down to a deep path row (not the host at index 0).
      5.times { view.move(1) }
      view.at_top?.should be_false
      sel_before = view.@selected
      # Collapse the host so children disappear — expand state must survive reload.
      view.move(-view.@selected) # back to top host row
      view.collapse.should be_true
      view.move(1) # land on the next host (other.test) while acme is collapsed
      other_sel = view.@selected

      capture(store, "acme.test", "GET", "/api/users/3") # external-change style tree growth
      view.reload(store)

      view.@selected.should eq(other_sel)
      # Collapsed acme should still hide its path children after reload.
      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))
      b.contains?("other.test").should be_true
      b.contains?("users").should be_false
    end
  end

  # --- marks (multi-select) -------------------------------------------------

  it "marks the cursor row with `t` and steps down, so a run of `t` marks consecutive rows" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/a")
      capture(store, "acme.test", "GET", "/b")

      view = SitemapView.new
      view.reload(store)
      view.mark_count.should eq(0)
      view.move(1) # off the host row, onto /a

      view.toggle_mark.should be_true
      view.toggle_mark.should be_true
      view.mark_count.should eq(2)
      view.marked_keys.should eq([{"http://acme.test", "/a"}, {"http://acme.test", "/b"}]) # tree order
      view.marked_hidden_count.should eq(0)

      # The step saturates at the last row, so a third `t` there clears what the second set.
      view.toggle_mark.should be_true
      view.marked?("http://acme.test", "/b").should be_false
      view.mark_count.should eq(1)
    end
  end

  # ⇧T, the `t`/⇧T pair every other marked list carries. It was held back on the argument that
  # a tree's mark-all "would sweep hosts and folders into the same batch as the endpoints under
  # them" — so the set is every row carrying a METHOD, which a host and a folder never do.
  it "marks every captured path `⇧T` can see, and never a host or a folder" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/api/users")
      capture(store, "acme.test", "GET", "/api/orders")
      capture(store, "acme.test", "GET", "/health")

      view = SitemapView.new
      view.reload(store)
      view.mark_all_visible.should eq(3)
      view.mark_count.should eq(3)
      view.marked_keys.should eq([{"http://acme.test", "/api/orders"}, {"http://acme.test", "/api/users"},
                                  {"http://acme.test", "/health"}])
      # The host row and the `/api` folder are on screen and neither is in the set.
      view.marked?("http://acme.test", "").should be_false
      view.marked?("http://acme.test", "/api").should be_false

      # Idempotent: a second press adds nothing rather than toggling the set off.
      view.mark_all_visible.should eq(0)
      view.mark_count.should eq(3)

      view.clear_marks
      view.mark_count.should eq(0)
    end
  end

  it "keeps a marked host from lighting up the id folds under it" do
    # Regression: a fold node keeps `path` empty, exactly like its host row, so a mark keyed on
    # (host, path) alone made `{"http://acme.test", ""}` mean BOTH — marking the host banded every
    # fold in the tree. A fold is not markable at all; only the host row may carry the band.
    with_store do |store|
      capture(store, "acme.test", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678")
      capture(store, "acme.test", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00")

      view = SitemapView.new
      view.reload(store)
      view.toggle_mark.should be_true # the host row (selection starts there)
      view.mark_count.should eq(1)
      view.marked?("http://acme.test", "").should be_true

      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))
      marked_rows = marked_row_indexes(b)
      marked_rows.size.should eq(1) # the host row and nothing else
      b.row(marked_rows.first).includes?("acme.test").should be_true

      # And the fold itself refuses the mark rather than keying on its host's empty path.
      view.move(2) # host → users → {uuid} fold
      view.toggle_mark.should be_false
      view.mark_count.should eq(1)
    end
  end

  it "keeps marks across a reload and counts the ones off-screen" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/api/users")

      view = SitemapView.new
      view.reload(store)
      2.times { view.move(1) } # host → api → users
      view.toggle_mark.should be_true
      view.mark_count.should eq(1)

      capture(store, "acme.test", "GET", "/api/orders") # a live-capture style poll
      view.reload(store)
      view.mark_count.should eq(1) # keyed by (host, path), not by row index
      view.marked?("http://acme.test", "/api/users").should be_true
      view.marked_hidden_count.should eq(0)

      # Collapsing the host takes the marked row off screen — the set is unchanged, and the
      # bar chip says how much of it you can't see.
      view.select_index(0)
      view.collapse.should be_true
      view.marked_hidden_count.should eq(1)
      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))
      b.contains?("1 marked ·1 hidden").should be_true
    end
  end

  it "extends a range with ⇧arrows, stepping over folds instead of marking them" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/users/3f2a8b1c-1234-5678-9abc-def012345678")
      capture(store, "acme.test", "GET", "/users/a1b2c3d4-5566-7788-99aa-bbccddeeff00")
      capture(store, "acme.test", "GET", "/orders")

      # Rows (the fold starts collapsed): acme.test / users / {uuid} fold / orders
      view = SitemapView.new
      view.reload(store)
      view.select_index(1) # `users`
      3.times { view.extend_marks(1) }
      # The whole range is swept — the cursor walked over the fold — but only the two real
      # paths in it end up marked. The host was never in range. (Siblings sort by path, so
      # /orders precedes /users in tree order.)
      view.marked_keys.should eq([{"http://acme.test", "/orders"}, {"http://acme.test", "/users"}])
      view.mark_count.should eq(2)
    end
  end

  it "hands back only the gesture's own marks when it ends" do
    with_store do |store|
      %w(/a /b /c /d).each { |p| capture(store, "acme.test", "GET", p) }

      view = SitemapView.new
      view.reload(store)
      view.select_index(1) # /a
      view.toggle_mark     # a deliberate `t` mark; the cursor steps to /b
      view.extend_marks(1) # range from /b over /c
      view.mark_count.should eq(3)

      view.end_mark_gesture.should eq(2) # the two the range added
      view.mark_count.should eq(1)       # the `t` mark stays — that's what makes a gap possible
      view.marked?("http://acme.test", "/a").should be_true
    end
  end

  it "tags every marked path from one editor, seeded from the cursor row's memo" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/a")
      capture(store, "acme.test", "GET", "/b")
      store.set_sitemap_tag("acme.test", "/a", "old")

      view = SitemapView.new
      view.reload(store)
      view.select_index(1) # /a
      view.toggle_mark     # marks /a, cursor → /b
      view.toggle_mark     # marks /b, cursor saturates there
      view.mark_count.should eq(2)

      # The cursor row wins the seed while it is itself a target (/b, untagged)…
      view.start_tag.should be_true
      view.tag_buffer.should eq("")
      view.cancel_tag
      # …and when the cursor sits outside the set, the first target in tree order does.
      view.select_index(0) # the host row — marked? no
      view.start_tag.should be_true
      view.tag_targets.should eq([{"http://acme.test", "/a"}, {"http://acme.test", "/b"}])
      view.tag_buffer.should eq("old")

      3.times { view.tag_backspace } # the seed is editable, like any pre-filled field
      "auth".each_char { |c| view.tag_insert(c) }
      # What SitemapController#commit_tag does: the key names the origin, the tag the bare host.
      view.tag_targets.each { |(key, path)| store.set_sitemap_tag(view.tag_host(key).not_nil!, path, view.tag_buffer) }
      view.apply_tag(view.tag_buffer)
      view.tagging?.should be_false

      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))
      (0...20).count { |y| b.row(y).includes?("# auth") }.should eq(2) # both rows stamped in place
      store.sitemap_tags[{"acme.test", "/a"}].should eq("auth")
      store.sitemap_tags[{"acme.test", "/b"}].should eq("auth")
    end
  end

  it "resolves the marked set to endpoints, and falls back to the cursor row with no marks" do
    with_store do |store|
      capture(store, "acme.test", "POST", "/api/orders")
      capture(store, "acme.test", "GET", "/api/users")

      view = SitemapView.new
      view.reload(store)
      # No marks: the cursor row IS the target set (one rule, no "batch mode").
      view.select_index(3) # host → api → orders → users
      view.target_keys.should eq([{"http://acme.test", "/api/users"}])
      view.target_endpoints.map(&.[](:target)).should eq(["/api/users"])

      view.select_index(2) # /api/orders
      view.toggle_mark
      view.select_index(3)
      view.toggle_mark
      eps = view.target_endpoints
      eps.map(&.[](:target)).should eq(["/api/orders", "/api/users"])
      eps.map(&.[](:method)).should eq(["POST", "GET"]) # per-node, GET-preferred
      eps.map(&.[](:host)).uniq.should eq(["acme.test"])
    end
  end

  it "round-trips and clears a tag through the store" do
    with_store do |store|
      capture(store, "acme.test", "GET", "/api/users")
      store.set_sitemap_tag("acme.test", "/api", "memo")
      store.sitemap_tags[{"acme.test", "/api"}].should eq("memo")

      store.set_sitemap_tag("acme.test", "/api", "") # blank clears
      store.sitemap_tags.has_key?({"acme.test", "/api"}).should be_false
    end
  end

  # The view's own tree walks (expand-state snapshot/reapply, the tag prune, and the
  # flatten in visible_rows) used to recurse one native stack frame per path segment, like
  # the Sitemap transforms before them. `reload` drives all of them, so one deep capture
  # covers the set. See spec/sitemap_depth_spec.cr for the measured overflow depths and why
  # this fixture is 2_000 rather than something dramatic: the tree itself is quadratic in
  # depth (1.6 GB at 20k), so a fixture deep enough to overflow these particular walks costs
  # gigabytes. What this pins is that a deep tree still renders correctly end to end.
  it "reloads, prunes and flattens a deep tree without overflowing the stack" do
    with_store do |store|
      deep = String.build { |io| 2_000.times { |i| io << "/s" << i } }
      capture(store, "deep.test", "GET", deep)
      capture(store, "deep.test", "GET", "/shallow")
      store.set_sitemap_tag("deep.test", "/s0", "keepme")

      view = SitemapView.new
      view.reload(store) # collect_expand_state + reapply_expand_state + visible_rows/collect

      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))
      b.contains?("deep.test").should be_true
      b.contains?("s0").should be_true

      # Positive tag prune (keep_for_tags?): the tagged branch survives WHOLE, so the
      # segments below the tagged node are still there. Asserted on `s1` rather than on the
      # sibling's absence: `/s0`'s 2000-row subtree pushes `shallow` off a 20-row viewport
      # either way, so "shallow is not on screen" would pass without the prune running.
      view.start_query
      "tag:keepme".each_char { |c| view.query_insert(c) }
      view.reload(store)
      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))
      b.contains?("s0").should be_true
      b.contains?("s1").should be_true

      # Negative tag prune (exclude_for_tags?): the mirror image — and here the sibling IS
      # a real signal, because `shallow` can only reach the viewport once the deep subtree
      # ahead of it has actually been dropped.
      view.cancel_query # Esc: drops the positive filter
      view.start_query
      "-tag:keepme".each_char { |c| view.query_insert(c) }
      view.reload(store)
      b = MemoryBackend.new(70, 20)
      view.render(Screen.new(b), Rect.new(0, 0, 70, 20))
      b.contains?("shallow").should be_true
      b.contains?("s0").should be_false
    end
  end

  # The OpenAPI export's target set (#1241): marks if any, else the cursor row — a host row
  # as the whole host, a path row as the endpoint paths under it, a marked row as its subtree.
  describe "#export_targets" do
    it "reads the cursor row: a host whole, a path as the endpoints under it" do
      with_store do |store|
        capture(store, "acme.test", "GET", "/api/users")
        capture(store, "acme.test", "GET", "/api/users/7")
        capture(store, "acme.test", "GET", "/about")
        view = SitemapView.new
        view.reload(store)
        targets, label = view.export_targets.not_nil!
        acme = Gori::Sitemap::Origin.new("http", "acme.test", 80)
        targets.should eq({acme => nil})
        label.should eq("http://acme.test")

        10.times do # walk down to the /api folder row, whatever order the tree draws it in
          break if view.export_targets.not_nil![1] == "http://acme.test/api"
          view.move(1)
        end
        targets, label = view.export_targets.not_nil!
        label.should eq("http://acme.test/api")
        targets[acme].should eq(Set{"/api/users", "/api/users/7"})
      end
    end

    it "unions marked subtrees per host, and a marked host row takes the whole host" do
      with_store do |store|
        capture(store, "acme.test", "GET", "/a")
        capture(store, "acme.test", "GET", "/b")
        capture(store, "other.test", "GET", "/c")
        view = SitemapView.new
        view.reload(store)
        view.move(1)     # acme.test /a
        view.toggle_mark # marks /a, steps to /b
        view.toggle_mark # marks /b, steps to the other.test host row
        view.toggle_mark # marks the other.test host row
        targets, label = view.export_targets.not_nil!
        targets.should eq({Gori::Sitemap::Origin.new("http", "acme.test", 80)  => Set{"/a", "/b"},
                           Gori::Sitemap::Origin.new("http", "other.test", 80) => nil})
        label.should eq("3 marked paths")
      end
    end
  end

  # #1371: a root is an ORIGIN. Keyed on the host label, `http://h:19021`, `http://h:19022` and
  # `https://h:8443` were one `h` row, and `/x` on two of them was one row too.
  describe "one root per origin" do
    it "draws each origin as its own root and keeps same-path rows apart" do
      with_store do |store|
        capture_at(store, "http", "h.test", 19021, "/x")
        capture_at(store, "http", "h.test", 19022, "/x")
        capture_at(store, "https", "h.test", 8443, "/only-tls")
        view = SitemapView.new
        view.reload(store)
        backend = MemoryBackend.new(70, 12)
        view.render(Screen.new(backend), Rect.new(0, 0, 70, 12))
        {"http://h.test:19021", "http://h.test:19022", "https://h.test:8443"}.each do |label|
          backend.contains?(label).should be_true
        end

        view.select_index(1) # /x under :19021
        view.toggle_mark
        view.marked_keys.should eq([{"http://h.test:19021", "/x"}])
        view.marked?("http://h.test:19022", "/x").should be_false
        ep = view.target_endpoints.first
        ep[:host].should eq("h.test")
        ep[:origin].should eq(Gori::Sitemap::Origin.new("http", "h.test", 19021))
        view.tag_host("http://h.test:19021").should eq("h.test") # a tag is keyed on the bare host

        view.clear_marks
        view.select_index(3) # /x under :19022
        view.selected_endpoint.not_nil![:origin].should eq(Gori::Sitemap::Origin.new("http", "h.test", 19022))
        view.selected_url.should eq("http://h.test:19022/x")
        view.select_index(2) # the :19022 root
        view.selected_url.should eq("http://h.test:19022")
        view.selected_scope_seed.should eq({match_type: "host", pattern: "h.test"})
      end
    end

    it "narrows the Params target and the export set to the row's origin" do
      with_store do |store|
        capture_at(store, "http", "h.test", 19021, "/a")
        capture_at(store, "http", "h.test", 19022, "/b")
        view = SitemapView.new
        view.reload(store)
        view.select_index(2) # the :19022 root
        t = view.selected_params_target.not_nil!
        {t.host, t.origin, t.label}.should eq({"h.test", Gori::Sitemap::Origin.new("http", "h.test", 19022), "http://h.test:19022"})
        targets, _ = view.export_targets.not_nil!
        targets.should eq({Gori::Sitemap::Origin.new("http", "h.test", 19022) => nil})
      end
    end

    # A tag is keyed on the bare host, so committing one stamps the path under every origin of
    # that host at once — as the next reload's stamp would — not only the row that was edited.
    it "stamps a committed tag on the same path under every origin of the host" do
      with_store do |store|
        capture_at(store, "http", "h.test", 19021, "/admin")
        capture_at(store, "https", "h.test", 8443, "/admin")
        capture_at(store, "http", "other.test", 80, "/admin")
        view = SitemapView.new
        view.reload(store)
        view.select_index(1) # /admin under http://h.test:19021
        view.start_tag.should be_true
        "memo".each_char { |c| view.tag_insert(c) }
        view.apply_tag(view.tag_buffer)
        b = MemoryBackend.new(80, 12)
        view.render(Screen.new(b), Rect.new(0, 0, 80, 12))
        (0...12).count { |y| b.row(y).includes?("memo") }.should eq(2) # both h.test origins, not other.test
      end
    end

    # The cursor row is pinned at start_tag; a reload that drops its root mid-edit must not leave
    # the commit without a host to write under.
    it "keeps a tag target's origin across a reload that hides its root" do
      with_store do |store|
        capture_at(store, "http", "h.test", 19021, "/a")
        capture_at(store, "http", "other.test", 80, "/b")
        view = SitemapView.new
        view.reload(store)
        view.select_index(1)
        view.start_tag.should be_true
        key = view.tag_targets.first[0]
        view.start_query
        "host:other".each_char { |c| view.query_insert(c) }
        view.stop_query
        view.reload(store)
        view.tag_host(key).should eq("h.test")
      end
    end

    # The mark key's origin must still name its bare host after a reload drops the root —
    # otherwise the tag commit would have nothing to write the memo under.
    it "remembers a marked origin across a reload that hides its root" do
      with_store do |store|
        capture_at(store, "http", "h.test", 19021, "/a")
        capture_at(store, "http", "other.test", 80, "/b")
        view = SitemapView.new
        view.reload(store)
        view.select_index(1)
        view.toggle_mark
        view.start_query
        "host:other".each_char { |c| view.query_insert(c) }
        view.stop_query
        view.reload(store)
        view.origin_for("http://h.test:19021").should eq(Gori::Sitemap::Origin.new("http", "h.test", 19021))
        view.clear_marks
        view.reload(store)
        view.origin_for("http://h.test:19021").should be_nil # no mark holds it any more
      end
    end
  end
end
