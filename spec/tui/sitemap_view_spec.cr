require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def tmp_store(&)
  path = File.tempname("gori-sm", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def capture(store, host, method, target)
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: host, port: 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil))
end

describe Gori::Tui::SitemapView do
  it "builds and renders a literal host -> path tree" do
    tmp_store do |store|
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

  it "collapses and expands nodes" do
    tmp_store do |store|
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
    tmp_store do |store|
      view = SitemapView.new
      view.reload(store)
      backend = MemoryBackend.new(70, 14)
      view.render(Screen.new(backend), Rect.new(0, 0, 70, 14),
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
    tmp_store do |store|
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

  it "rejects an all-invalid QL query instead of showing the whole tree" do
    tmp_store do |store|
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
    tmp_store do |store|
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
    tmp_store do |store|
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
    tmp_store do |store|
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

  it "marks in-scope hosts with a scope glyph even when the ⇧S lens is off" do
    tmp_store do |store|
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
    tmp_store do |store|
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
    tmp_store do |store|
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
    tmp_store do |store|
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
    tmp_store do |store|
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
    tmp_store do |store|
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

  it "keeps an expanded fold open across reload (live capture poll)" do
    # Regression: apply_expand_depth! force-collapses every fold on every rebuild, and the
    # expand-state walk used to skip synthetic nodes entirely — so a fold the user opened
    # snapped shut on the next ~750ms poll and its subtree was unreadable during capture.
    tmp_store do |store|
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
    tmp_store do |store|
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
    tmp_store do |store|
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
    tmp_store do |store|
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

  it "refuses to tag a template fold" do
    tmp_store do |store|
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
    tmp_store do |store|
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
    tmp_store do |store|
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
    tmp_store do |store|
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
    tmp_store do |store|
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
    tmp_store do |store|
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
    tmp_store do |store|
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
    tmp_store do |store|
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
    tmp_store do |store|
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

  it "round-trips and clears a tag through the store" do
    tmp_store do |store|
      capture(store, "acme.test", "GET", "/api/users")
      store.set_sitemap_tag("acme.test", "/api", "memo")
      store.sitemap_tags[{"acme.test", "/api"}].should eq("memo")

      store.set_sitemap_tag("acme.test", "/api", "") # blank clears
      store.sitemap_tags.has_key?({"acme.test", "/api"}).should be_false
    end
  end
end
