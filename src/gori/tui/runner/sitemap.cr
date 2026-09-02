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

  def sitemap_toggle_grouping : Nil
    sitemap_controller.sitemap_toggle_grouping
  end

  def sitemap_toggle_query_fold : Nil
    sitemap_controller.sitemap_toggle_query_fold
  end

  # --- multi-select marks ---
  def sitemap_mark_toggle : Nil
    sitemap_controller.sitemap_mark_toggle
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
    ep = sitemap_controller.view.selected_endpoint
    unless ep
      @toast = I18n.sys("select an endpoint to send")
      return
    end
    if id = @session.store.representative_flow_id(ep[:host], ep[:method], ep[:target])
      repeater_flow(id)
    else
      @toast = I18n.sys("no captured request for this path — capture it, or use Discover")
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
      @toast = I18n.sys("select a host or path to scope")
      return
    end
    # Reload on success: the tree shows a scope marker per host whenever rules EXIST (lens or
    # not), and with the lens on the rule also re-filters the rows under the cursor.
    open_scope_rule_editor(nil, "include", seed[:match_type], seed[:pattern],
      on_applied: -> { sitemap_controller.reload })
  end

  # Open the bytes behind the cursor row. CROSS-TAB mediator: resolves the tree node through
  # the store, then drives the History controller + detail overlay — exactly the hop
  # issue_open_flow (runner/issues.cr) makes from an issue to its evidence.
  #
  # Deliberately NOT marked-set aware, unlike sitemap_repeater: a detail overlay shows one
  # flow, so the cursor row is the only thing it could mean. It uses the same
  # `selected_endpoint` resolve, so `o` and `r` never disagree about which path is under
  # the cursor — including a `{uuid}` fold, which both resolve to a real descendant.
  def sitemap_open_flow : Nil
    ep = sitemap_controller.view.selected_endpoint
    unless ep
      @toast = I18n.sys("select an endpoint to open")
      return
    end
    unless id = @session.store.representative_flow_id(ep[:host], ep[:method], ep[:target])
      @toast = I18n.sys("no captured request for this path — capture it, or use Discover")
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
      @toast = I18n.sys("that request was pruned since the tree was built")
    end
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
      @toast = I18n.sys_n(wanted, "no captured requests for the %{n} marked path — capture it, or use Discover", "no captured requests for the %{n} marked paths — capture them, or use Discover", n: wanted)
      return
    end
    # One flow behind the whole set — a single mark, or N marks that share a representative
    # request — is not a batch: open it straight away, like the cursor row and History's ^R.
    return repeater_flow(ids.first) if ids.size == 1
    return unless targets = batch_within_cap(ids, "Repeater", subject: "endpoints")
    confirm(I18n.ui("SEND TO REPEATER"), I18n.sys("Open %{n} endpoints as %{n} Repeater sub-tabs?", n: targets.size),
      confirm_label: I18n.ui("open"), danger: false) do
      opened = 0
      targets.each do |id|
        next unless @session.store.flow_row(id) # pruned since the resolve: skip, report below
        repeater_flow(id)
        opened += 1
      end
      # `wanted`, not targets.size, is the denominator: a marked path with no captured request
      # never became an id, and a batch that silently drops it reads as "sent everything".
      @toast = I18n.sys_n(wanted, "opened %{opened} of %{n} marked path", "opened %{opened} of %{n} marked paths", opened: opened, n: wanted)
    end
  end
end
