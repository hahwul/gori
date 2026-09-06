module Gori::Tui
  class HistoryController < TabController
    @search_generation = 0_i64
    @search_identity : HistoryView::SearchIdentity? = nil
    @search_control : Store::QueryControl? = nil
    @search_pending : Tuple(Store, HistoryView::SearchRequest, Int64)? = nil
    @search_results = Channel(Tuple(Int64, HistoryView::SearchResult?)).new(1)
    @pending_open : Tuple(Int64, Int64)? = nil

    @host_generation = 0_i64
    @host_request_key : Tuple(Store, String)? = nil
    @host_control : Store::QueryControl? = nil
    @host_pending : Tuple(Store, String, Int64)? = nil
    @host_results = Channel(Tuple(Int64, String, Array(String)?)).new(1)

    # One running read and one replaceable request per worker. A cancelled read
    # must unwind before its successor checks out another pool connection.
    private def invalidate_search : Nil
      @search_generation += 1
      @search_control.try(&.cancel)
      @search_pending = nil
      @pending_open = nil
      @history.searching = true
    end

    private def request_search(store : Store) : Nil
      invalidate_search
      @query_reload_at = nil
      @search_identity = @history.search_identity
      if request = @history.prepare_search(store)
        @search_pending = {store, request, @search_generation}
        start_search
      end
    end

    private def refresh_search : Nil
      if !@query_reload_at && @search_identity != @history.search_identity
        request_search(@host.session.store)
      else
        @history.stale_filter
      end
    end

    private def start_search : Nil
      return if @search_control
      return unless pending = @search_pending
      @search_pending = nil
      control = Store::QueryControl.new
      @search_control = control
      perform_search(pending[0], pending[1], pending[2], control)
    end

    private def perform_search(store : Store, request : HistoryView::SearchRequest,
                               generation : Int64, control : Store::QueryControl) : Nil
      spawn do
        result = nil.as(HistoryView::SearchResult?)
        begin
          control.check!
          result = @history.fetch_search(store, request, control)
        rescue Store::QueryCancelled
          # Superseded/closed is not a failed query and never means zero matches.
        rescue ex
          ::Log.warn { "history worker failed: #{ex.message}" }
          result = HistoryView::SearchResult.new([] of Store::FlowRow, request.note,
            false, nil, "search failed — try another filter")
        ensure
          @search_results.send({generation, result})
        end
      end
    end

    private def drain_search : Bool
      select
      when done = @search_results.receive
        @search_control = nil
        if done[0] == @search_generation && (result = done[1])
          @history.apply_search(result)
          apply_pending_open unless result.error
          @pending_open = nil
        end
        start_search
        true
      else
        false
      end
    end

    private def select_during_search(clicked_id : Int64?, selected : Bool) : Bool
      return false unless clicked_id && @history.searching?
      if idx = @history.row_index(clicked_id)
        @history.set_preview_focus(:list)
        end_range_gesture
        @history.select_row(idx)
        @pending_open = {@search_generation, clicked_id} if selected
      end
      true
    end

    private def apply_pending_open : Nil
      return unless click = @pending_open
      return unless click[0] == @search_generation
      return unless @history.selected_id == click[1] && @host.overlay == :none
      open_detail
    end

    private def request_host_suggestions(prefix : String) : Nil
      store = @host.session.store
      key = {store, prefix.downcase}
      if @host_control && @host_request_key == key
        # Capture invalidated the same prefix. Finish the current read, publish
        # it, then refresh once; repeated invalidations must not starve it.
        @host_pending = {store, prefix, @host_generation}
        return
      end
      @host_request_key = key
      @host_generation += 1
      @host_control.try(&.cancel)
      @host_pending = {store, prefix, @host_generation}
      start_host_search
    end

    private def start_host_search : Nil
      return if @host_control
      return unless pending = @host_pending
      @host_pending = nil
      control = Store::QueryControl.new
      @host_control = control
      perform_host_search(pending[0], pending[1], pending[2], control)
    end

    private def perform_host_search(store : Store, prefix : String, generation : Int64,
                                    control : Store::QueryControl) : Nil
      spawn do
        values = nil.as(Array(String)?)
        begin
          control.check!
          values = @history.fetch_host_suggestions(store, prefix, control)
        rescue Store::QueryCancelled
        rescue ex
          ::Log.warn { "history completion failed: #{ex.message}" }
        ensure
          @host_results.send({generation, prefix, values})
        end
      end
    end

    private def drain_host_search : Bool
      select
      when done = @host_results.receive
        @host_control = nil
        if done[0] == @host_generation && (values = done[2])
          @history.apply_host_suggestions(done[1], values)
        end
        start_host_search
        true
      else
        false
      end
    end

    # Called on departure and teardown. Store#close independently drains reads
    # already inside SQLite, so closing cannot finalize a suspended statement.
    def cancel_searches : Nil
      invalidate_search
      @query_reload_at = nil
      @history.searching = false
      @host_generation += 1
      @host_request_key = nil
      @host_control.try(&.cancel)
      @host_pending = nil
      @history.popup_close
      @history.invalidate_host_suggest_cache
    end
  end
end
