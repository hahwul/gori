# Sitemap tree — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  def sitemap_move(delta : Int32) : Nil
    sitemap_controller.sitemap_move(delta)
  end

  def sitemap_toggle : Nil
    sitemap_controller.sitemap_toggle
  end

  def sitemap_expand : Nil
    sitemap_controller.sitemap_expand
  end

  def sitemap_collapse : Nil
    sitemap_controller.sitemap_collapse
  end

  def sitemap_query : Nil
    sitemap_controller.sitemap_query
  end

  def sitemap_tag : Nil
    sitemap_controller.sitemap_tag
  end

  # `⇧E` — the marked paths, else the cursor's host or subtree, as an OpenAPI 3.0.3 document
  # (#1241). The flow set is the tree's own (the `/` query, the scope and hide-static lenses),
  # so the file describes what the tree shows. The path comes from the export popup.
  def sitemap_export : Nil
    view = sitemap_controller.view
    unless picked = view.export_targets
      @toast = "select a host or path to export"
      return
    end
    unless filter = view.params_filter
      @toast = "the Sitemap query has no usable terms — fix it (/) before exporting"
      return
    end
    targets, label = picked
    base = if targets.size == 1
             "openapi-#{targets.keys.first.scrub.gsub(/[^A-Za-z0-9._-]/, "_")}.json"
           else
             "openapi.json"
           end
    open_export(:openapi, File.join(Dir.current, base)) do |path|
      sitemap_controller.export_openapi(path, filter, targets, label)
      true
    end
  end

  def sitemap_toggle_grouping : Nil
    sitemap_controller.sitemap_toggle_grouping
  end

  def sitemap_toggle_query_fold : Nil
    sitemap_controller.sitemap_toggle_query_fold
  end

  def sitemap_toggle_js_refs : Nil
    sitemap_controller.sitemap_toggle_js_refs
  end

  # `sitemap.js-scan` (#1243) — read the captured JS responses and HTML pages behind the tree's
  # own flow set that no scan has read, and store the endpoints they reference. Sends nothing;
  # the result lands as a toast and a rebuilt tree (`SitemapController#drain_js_scan`).
  def sitemap_js_scan : Nil
    unless filter = sitemap_controller.view.params_filter
      @toast = "the Sitemap query has no usable terms — fix it (/) before scanning"
      return
    end
    sitemap_controller.js_scan(filter)
  end

  # --- multi-select marks ---
  def sitemap_mark_toggle : Nil
    sitemap_controller.sitemap_mark_toggle
  end

  def sitemap_mark_all : Nil
    sitemap_controller.sitemap_mark_all
  end

  def sitemap_mark_clear : Nil
    sitemap_controller.sitemap_mark_clear
  end

  def sitemap_mark_extend(delta : Int32) : Nil
    sitemap_controller.sitemap_mark_extend(delta)
  end

  def sitemap_marked_count : Int32
    sitemap_controller.marked_node_count
  end

  # The cursor row: unchanged, and deliberately NOT routed through the marked-set path below —
  # `selected_endpoint` resolves a `{uuid}` fold to a real descendant, which a mark never needs
  # (a fold can't be marked) and which target_endpoints therefore doesn't do.
  def sitemap_repeater : Nil
    return sitemap_repeater_marked if sitemap_controller.marked_node_count > 0
    if ref = sitemap_controller.view.selected_js_ref
      return sitemap_repeater_js(ref[:host], ref[:path])
    end
    ep = sitemap_controller.view.selected_endpoint
    unless ep
      @toast = "select an endpoint to send"
      return
    end
    if id = @session.store.representative_flow_id(ep[:host], ep[:method], ep[:target])
      repeater_flow(id)
    else
      @toast = "no captured request for this path — capture it, or use Discover"
    end
  end

  # `a` — put the cursor row into the project scope, through the SAME popup the Project
  # tab's `a` opens, pre-filled from where the cursor sits: a host row seeds a `host` rule,
  # a path row seeds a "host/path" `string` rule (see SitemapView#selected_scope_seed).
  # Pre-filled, not written blind: the form is where you widen "/api/v1" to "/api", flip
  # include→exclude, or bail — and it is the one place scope patterns are validated.
  #
  # Cursor-only even with marks set (SITEMAP_CURSOR_ONLY): the form edits ONE pattern, so
  # a marked set has nothing to mean here.
  def sitemap_scope_add : Nil
    seed = sitemap_controller.view.selected_scope_seed
    unless seed
      @toast = "select a host or path to scope"
      return
    end
    # Reload on success: the tree shows a scope marker per host whenever rules EXIST (lens or
    # not), and with the lens on the rule also re-filters the rows under the cursor.
    open_scope_rule_editor(nil, "include", seed[:match_type], seed[:pattern],
      on_applied: -> { sitemap_controller.reload })
  end

  # Open the bytes behind the cursor row. CROSS-TAB mediator: resolves the tree node through
  # the store, then drives the History controller + detail overlay — exactly the hop
  # `navigate_link_ref` (runner/links.cr) makes from an Issue's RELATED row to its source.
  #
  # Deliberately NOT marked-set aware, unlike sitemap_repeater: a detail overlay shows one
  # flow, so the cursor row is the only thing it could mean. It uses the same
  # `selected_endpoint` resolve, so `o` and `r` never disagree about which path is under
  # the cursor — including a `{uuid}` fold, which both resolve to a real descendant.
  def sitemap_open_flow : Nil
    if ref = sitemap_controller.view.selected_js_ref
      return sitemap_open_js_source(ref[:host], ref[:path])
    end
    ep = sitemap_controller.view.selected_endpoint
    unless ep
      @toast = "select an endpoint to open"
      return
    end
    unless id = @session.store.representative_flow_id(ep[:host], ep[:method], ep[:target])
      @toast = "no captured request for this path — capture it, or use Discover"
      return
    end
    if history_controller.view.open_detail_id(id, @session.store)
      @active_tab = :history
      @focus = :body
      @overlay = OverlayKind::Detail
    else
      # The resolve above just saw this id, so only a prune racing between the two reads
      # lands here — say so rather than repeating "no captured request", which would read
      # as "this path was never captured".
      @toast = "that request was pruned since the tree was built"
    end
  end

  # The sighting a JavaScript-only row stands for: the newest one read in CODE, else the newest
  # at all (a route only ever seen commented out is still where it was seen).
  private def sitemap_js_sighting(host : String, path : String) : Store::JsRefSighting?
    seen = @session.store.js_ref_sightings(host: host, path: path, limit: 50)
    seen.find { |s| s.flags & JsRefs::FLAG_COMMENT == 0 } || seen.first?
  end

  # `o` on a path only JavaScript names: there is no request to open, so open where the
  # reference was READ — the script's (or page's) flow in History — and say where in it.
  private def sitemap_open_js_source(host : String, path : String) : Nil
    unless s = sitemap_js_sighting(host, path)
      @toast = "that reference is gone since the tree was built (its flow was deleted)"
      return
    end
    unless history_controller.view.open_detail_id(s.flow_id, @session.store)
      @toast = "that script was pruned since the tree was built"
      return
    end
    # The reference sits in the RESPONSE body. The pane is not scrolled to it: a body line is
    # not a display line once the head, pretty-printing and wrap are drawn above and around it,
    # so the toast names the line and byte instead of landing somewhere near them.
    history_controller.view.set_detail_pane_public(:response)
    @active_tab = :history
    @focus = :body
    @overlay = OverlayKind::Detail
    comment = s.flags & JsRefs::FLAG_COMMENT != 0 ? " (in a comment)" : ""
    @toast = "referenced at line #{s.line}, byte #{s.offset}#{comment}: #{DisplayColumns.display_safe(s.literal)}"
  end

  # `r` on a path only JavaScript names: a BARE GET for it in a new Repeater tab — nothing is
  # sent until ^R. Bare on purpose: copying the page's Cookie/Authorization would carry
  # credentials to a URL nobody visited, and that is the operator's call to make in the editor.
  private def sitemap_repeater_js(host : String, path : String) : Nil
    unless s = sitemap_js_sighting(host, path)
      @toast = "that reference is gone since the tree was built (its flow was deleted)"
      return
    end
    url = Store::FlowRow.url_of(s.scheme, s.host, s.port, s.target)
    built = Repeater::UrlRequest.structured(Repeater::UrlRequest.target(url), "GET",
      [] of {String, String}, nil, expand: false)
    repeater_controller.repeater_from_request(url, String.new(built.bytes), false, nil, name: "js")
    @toast = if s.flags & JsRefs::FLAG_TEMPLATED != 0
               "a GET for a JavaScript reference — replace {expr} before ^R sends it"
             else
               "a bare GET for a path only JavaScript names — nothing sent; ^R sends it"
             end
  rescue ex : Gori::Error
    @toast = "can't build a request for that reference: #{ex.message}"
  end

  # Batch over the marks: one Repeater sub-tab per marked endpoint, capped (BATCH_SUBTAB_CAP)
  # like History's ^R. Nothing is SENT here — a Repeater session only fires on ^R — so this
  # just confirms the sub-tab count.
  #
  # Resolution order matters: every target becomes a flow id FIRST, then the ids are
  # deduplicated. A marked folder and a marked endpoint under it can resolve to the same
  # representative flow, and without the dedup that opens the identical request twice.
  private def sitemap_repeater_marked : Nil
    view = sitemap_controller.view
    wanted = view.target_keys.size
    ids = view.target_endpoints.compact_map do |ep|
      @session.store.representative_flow_id(ep[:host], ep[:method], ep[:target])
    end.uniq!
    if ids.empty?
      @toast = "no captured requests for the #{plural(wanted, "marked path")} — capture them, or use Discover"
      return
    end
    # One flow behind the whole set — a single mark, or N marks that share a representative
    # request — is not a batch: open it straight away, like the cursor row and History's ^R.
    return repeater_flow(ids.first) if ids.size == 1
    return unless targets = batch_within_cap(ids, "Repeater", subject: "endpoints")
    confirm("SEND TO REPEATER", "Open #{targets.size} endpoints as #{targets.size} Repeater sub-tabs?",
      confirm_label: "open", danger: false) do
      opened = 0
      targets.each do |id|
        next unless @session.store.flow_row(id) # pruned since the resolve: skip, report below
        repeater_flow(id)
        opened += 1
      end
      # `wanted`, not targets.size, is the denominator: a marked path with no captured request
      # never became an id, and a batch that silently drops it reads as "sent everything".
      @toast = "opened #{opened} of #{plural(wanted, "marked path")}"
    end
  end
end
