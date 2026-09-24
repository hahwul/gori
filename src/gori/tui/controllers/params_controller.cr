require "../tab_controller"
require "../params_view"
require "../sitemap_view"
require "../../param_inventory"
require "../../paths"
require "../../durable_file"

module Gori::Tui
  # The Params sub-tab (under Target): the parameter inventory (#1231) over the flows the
  # Sitemap tab shows — the same `/` query and `s` scope lens, so the two sub-tabs answer
  # about one flow set.
  #
  # The read is `ParamInventory.build`, run on a WORKER fiber: it walks up to MAX_FLOWS
  # flows with their bodies, and on the one cooperative scheduler a synchronous walk would
  # freeze the terminal for its whole length. The engine yields between flows; this owns
  # the generation that makes a superseded scan stop early and drop its answer.
  class ParamsController < TabController
    # Newest flows one scan reads. The build is off the event loop, so this bounds WALL time
    # and memory, not a frozen frame; a cut is reported on the header (TRUNCATED).
    MAX_FLOWS = 5000

    getter generation : Int64 = 0_i64

    # `sitemap` is the Sitemap sub-tab's view, whose filter this scans under. The default is
    # an unfiltered stand-alone one, for a controller built outside TargetController.
    def initialize(host : Host, @sitemap : SitemapView = SitemapView.new)
      super(host)
      @params = ParamsView.new
      @results = Channel({Int64, ParamInventory::Report?, String?}).new(1)
    end

    def view : ParamsView
      @params
    end

    def tab : Symbol
      :params
    end

    def command_scope : Verb::Scope
      Verb::Scope::Params
    end

    # The first visit scans; later visits keep what is on screen (^R rescans) — unless the
    # Sitemap's query or scope lens changed since, in which case what is on screen answers
    # about a flow set the tree beside it no longer shows. A scan that re-ran on EVERY switch
    # would move rows out from under the cursor the operator came back to.
    def on_enter : Nil
      return if @params.scanning?
      run unless @params.ready? && scanned_filter_current?
    end

    # The filter the on-screen scan read under, as {sql, args} — `QL::Filter` is a struct
    # with no `==` of its own worth trusting across a re-parse.
    @scanned_under : {String, Array(DB::Any)}? = nil

    private def scanned_filter_current? : Bool
      f = @sitemap.params_filter
      !f.nil? && @scanned_under == {f.sql, f.args}
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      BodyChrome.framed(screen, rect, focus == :body) { |inner| render_content(screen, inner, focus) }
    end

    def render_content(screen : Screen, content : Rect, focus : Symbol) : Nil
      @params.render(screen, content, focused: focus == :body)
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      handle_click_content(BodyChrome.frame_inner(rect), mx, my)
    end

    def handle_click_content(content : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      if idx = @params.row_at(content, mx, my)
        @params.select_index(idx)
      end
      true
    end

    # A double-click opens the row's newest flow — what ↵ (`params.open-flow`) does, through
    # the Host because the tab switch is the Runner's.
    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      handle_double_click_content(BodyChrome.frame_inner(rect), mx, my)
    end

    def handle_double_click_content(content : Rect, mx : Int32, my : Int32) : Bool
      return false unless idx = @params.row_at(content, mx, my)
      @params.select_index(idx)
      @host.params_open_flow
      true
    end

    def body_scroll(delta : Int32) : Bool
      @params.move(delta)
      true
    end

    def page_rows : Int32?
      @params.list_page_rows
    end

    def handle_wheel(step : Int32) : Bool
      @params.move(step)
      true
    end

    def focus_first : Nil
      @params.focus_first
    end

    def focus_last : Nil
      @params.focus_last
    end

    # `y`: the selected parameter's name.
    def copy_row : Nil
      copy_text(@params.selected_row.try(&.name) || "", "parameter name")
    end

    # `⇧Y`: every name the view shows, one per line — a wordlist on the clipboard.
    def copy_names : Nil
      copy_text(ParamInventory.wordlist(@params.rows, headers: true).join("\n"), "parameter names")
    end

    def body_hint(focus : Symbol) : String
      return "" unless focus == :body
      base = keys("{params.run} scan · {params.all-headers} headers")
      base = "#{base} · esc all endpoints" if @params.target
      return "#{base} · ↑/esc sub-tabs" unless @params.selected_row
      "#{base} · #{keys("↵ open · {params.copy} copy · {params.copy-names} all names · " \
                        "{params.export} wordlist · {params.mine} mine")} · ↑/esc sub-tabs"
    end

    # --- verbs ---------------------------------------------------------------

    # Narrow to one Sitemap row (host, or subtree). A rescan, not a re-filter: the engine
    # reads the host and subtree's flows only, which is what makes a narrowed scan cheap on a big project.
    def set_target(t : ParamsView::Target?) : Nil
      @params.target = t
      run
    end

    def toggle_all_headers : Nil
      @params.all_headers = !@params.all_headers?
      run
    end

    # (Re)scan. Supersedes a scan in flight: its `stop` sees the generation move and it
    # returns early; `drain_build` drops whatever it sends.
    def run : Nil
      gen = (@generation += 1)
      filter = @sitemap.params_filter
      unless filter
        @params.error = "the Sitemap query has no usable terms — fix it on the Sitemap tab (/)"
        @params.scanning = false
        return
      end
      @scanned_under = {filter.sql, filter.args}
      opts = ParamInventory::Options.new(filter: filter, host: @params.target.try(&.host),
        path_prefix: @params.target.try(&.prefix),
        all_headers: @params.all_headers?, max_flows: MAX_FLOWS)
      store = @host.session.store
      results = @results
      me = self
      @params.scanning = true
      spawn(name: "gori-params-scan") do
        report = nil.as(ParamInventory::Report?)
        failure = nil.as(String?)
        begin
          report = ParamInventory.build(store, opts, -> { me.generation != gen })
        rescue ex
          failure = ex.message || ex.class.name
        ensure
          results.send({gen, report, failure})
        end
      end
    end

    # Called each run-loop tick: land a finished scan. True when one arrived (→ a frame).
    def drain_build : Bool
      select
      when done = @results.receive
        gen, report, failure = done
        if gen == @generation
          @params.scanning = false
          if report
            @params.report = report
          else
            @params.error = "params scan failed: #{failure}"
          end
        end
        true
      else
        false
      end
    end

    # `w`: the visible names as a wordlist under `Paths.wordlists_dir`, where the Fuzzer's
    # path completion and `gori run mine --wordlist` both find it. Header names are left
    # out: a Miner wordlist is one parameter namespace.
    def export_wordlist : Nil
      names = ParamInventory.wordlist(@params.rows)
      return @host.status("no parameter names to export") if names.empty?
      host = @params.target.try(&.host) || "all"
      stamp = Time.local.to_s("%Y%m%d-%H%M%S")
      path = File.join(Paths.wordlists_dir, "params-#{host.scrub.gsub(/[^A-Za-z0-9._-]/, "_")}-#{stamp}.txt")
      Dir.mkdir_p(Paths.wordlists_dir)
      DurableFile.write(path, names.join("\n") + "\n", perm: File::Permissions.new(0o644))
      @host.status("wrote #{names.size} names → #{path}")
    rescue ex : IO::Error | File::Error
      @host.status("wordlist export failed: #{ex.message}")
    end
  end
end
