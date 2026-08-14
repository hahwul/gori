require "json"
require "./screen"
require "./theme"
require "./frame"
require "./input_mode"
require "./text_read_state"
require "./line_field_read"
require "./read_cursor"
require "./read_pane"
require "./gutter"
require "./traffic_empty_state"
require "./text_area"
require "./fmt"
require "./spark"
require "./chain_pane"
require "./chain_overlay"
require "../store"
require "../fuzz"
require "../proxy/h2/grpc"
require "../decoder"
require "./fuzz_set_overlay"
require "./fuzz_advanced_overlay"
require "../repeater/flow_request"
require "../env"
require "./highlight"
require "../saml"
require "../jwt"
require "../graphql"
require "../form_data"
require "./subtab_clone"

module Gori::Tui
  # One Fuzzer/Intruder session (a sub-tab under the Fuzzer tab). Holds the editable
  # target + §-marked template + the run config (mode / payload sets / matchers /
  # engine opts) + the streamed results. Panes (focus ring): target ▸ template ▸
  # config ▸ results; `:detail` swaps over the results pane when a row is opened.
  #
  # Config is edited in-pane with a small command line (no modal overlay): type e.g.
  # `mode clusterbomb`, `list a,b,c`, `match status:200,500`, `concurrency 50`.
  class FuzzerView
    RESULT_CAP = 5000 # ring cap on retained result rows (metrics are cheap; bodies kept only for matched)

    # Aggregated result distribution for the DIST sidebar. Raw numbers only — bakes no
    # Color, so a theme switch needs no cache rebuild (colours resolve live at draw).
    record DistData,
      codes : Array({Int32, Int32}), # (status, count), ascending
      err : Int32,                   # status-nil rows (network/timeout failures)
      len_hist : Array(Int32), len_min : Int64, len_max : Int64,
      words_hist : Array(Int32), words_min : Int32, words_max : Int32,
      time_hist : Array(Int32), time_min : Int64, time_max : Int64

    STATUS_MAX_ROWS =  6 # ≤ this many distinct codes → per-code bars; else collapse to classes
    DIST_MIN_TOTAL  = 60 # narrowest bottom width that still earns a sidebar
    DIST_MIN_VW     = 22 # min / max sidebar width
    DIST_MAX_VW     = 34
    # Results-table payload column, in display COLUMNS (see `payload_cell`). The header
    # string in `render_results` reserves exactly this much between `#` and `status`.
    PAYLOAD_COL_W = 22

    getter focus : Symbol # :target | :template | :config | :results | :detail
    getter target : String
    getter? http2 : Bool
    getter? loaded : Bool
    getter? dirty : Bool
    getter? running : Bool
    # PROVENANCE: this template's bytes came out of a CAPTURED FLOW (⇧I from History /
    # Sitemap / Issues evidence), not a request the operator drafted here. Feeds
    # `Fuzz::PlanOptions#evidence?` — see `evidence_template` for what it turns off and
    # why an operator edit does NOT clear it.
    getter? evidence : Bool
    property name : String?
    property job_id : Int32 # bottom-bar/notification job handle (0 = no active job)
    getter config : Fuzz::Config
    getter matcher : Fuzz::Matcher

    PANE_ORDER = [:target, :template, :config, :results]

    def initialize
      @name = nil
      @target = ""
      @tcx = 0
      @sni = ""
      @scx = 0             # caret in the SNI row (@tcx is the URL row's)
      @target_field = :url # which field the TARGET pane edits: :url | :sni
      @http2 = false
      @evidence = false
      # The `$NAME`s the SEEDED template arrived with — see `operator_env_vars`, and
      # `RepeaterView#seed_draft_baselines` for the model. Empty on a draft, where every `$`
      # is the operator's by definition.
      @evidence_env_names = Set(String).new
      @editor = TextArea.new
      @editor.gutter = true
      # Soft wrap, Burp-style, exactly as the Repeater's request pane: a long header, URL or
      # §-marked minified body spills onto continuation rows and the line number stays on the
      # first of them. Replaces the `follow_x` horizontal scroll this pane used to carry — a
      # request you have to pan sideways to read is a request you misread, and here the thing
      # off the right edge is a `§…§` marker whose position IS the payload's insertion point.
      @editor.wrap = true
      @editor.env_complete = true # `$KEY` autocomplete against the registered env vars (expanded on send)
      @editor.chain_peek = true   # tooltip revealing the concealed ¦chain of the §…§ marker under the caret
      # …and here it carries `^O` as well. A marked position in the Fuzzer is only half a
      # setup: with no payload set in the CONFIG pane the run produces nothing, and the two
      # halves sit in different panes, so the tooltip over the position names the pane that
      # completes it. (In the Repeater a marker IS complete on its own — hence the default.)
      @editor.chain_peek_hint = "^Q edit · ^O sets"
      @last_synced_config = "" # last store config blob applied (reconcile equality)
      @config = Fuzz::Config.new(keep_bodies: :matched)
      @sets = [] of SetSpec
      @matcher = Fuzz::Matcher.new(keep_bodies: :matched)
      # CONFIG pane state — a calm, single-axis summary (no text field, no caret). @cfg_row
      # is the row cursor (↑/↓) over the payload-set rows + Add + Mode + Advanced + Run;
      # all text entry lives in the Set / Advanced overlays. @cfg_scroll windows the sets.
      @cfg_row = 0
      @cfg_scroll = 0
      @s_conc = "20" # engine numeric fields are edited (in the Advanced overlay) as string
      @s_rate = ""   # buffers, committed to @config at build/persist time (so a field can be cleared)
      @s_timeout = ""
      @s_retries = "0"
      @s_max_req = ""
      @s_m_regex = "" # regex fields buffered as source strings, compiled on commit
      @s_f_regex = ""
      # Memoized "Run · N requests" count, recomputed only when the config signature
      # (mode + sets + marker count) changes, so the summary row never rebuilds sources each frame.
      @run_count_cache = nil.as(Int64?)
      @run_count_sig = ""
      @results = [] of Fuzz::Result
      @results_rev = 0_i64 # bumped on every @results mutation — the DIST cache key
      # The template snapshot the CURRENT run's results were generated from — the RESULT
      # detail must reconstruct each request against this, not the live @editor buffer,
      # which the user may have edited (adding/removing §…§ markers) since the run.
      @run_template = nil.as(Fuzz::Template?)
      @pending_template = nil.as(Fuzz::Template?)
      # {update_content_length?, add_content_length_when_missing?, keep_bodies} as of the run
      # that produced @results — frozen alongside @run_template for the same reason: the
      # reconstruction and the note that names the retention policy must describe THAT run,
      # not whatever the CONFIG pane says now.
      @run_policy = nil.as({Bool, Bool, Symbol}?)
      @pending_policy = nil.as({Bool, Bool, Symbol}?)
      # `Fuzz::Plan#rewrites_content_length?` as of the last plan build, plus the
      # `@editor.edits` revision it was computed at — an edit to the template invalidates
      # the answer, and a stale "your CL is being rewritten" is worse than none.
      @cl_rewrite = false
      @cl_rewrite_rev = -1
      @sel = 0
      @scroll = 0
      @sort = :index
      @matched_only = false
      # §-region offsets, recomputed only when the buffer changes (keyed on @editor.edits).
      # Backs BOTH the template tint colours and the Sets→marker chips, so they can't disagree.
      @marker_text_rev = -1
      @marker_spans = [] of {Int32, Int32}
      @marker_regions_rev = -1
      @marker_regions_cache = [] of {Int32, Int32, Int32}
      # The chain under the cursor, cached on {editor revision, cursor} — render_chain_pane
      # reads it every frame the pane is visible, so a stationary cursor mustn't re-join +
      # re-scan the whole template buffer each frame (mirrors marker_spans).
      @chain_rev = -1
      @chain_cursor = -1
      @chain_cache = nil.as(String?)
      # The CHAIN sub-pane: a visible editor for the Decoder chain of the §…§ marker under
      # the TEMPLATE cursor (transform applied to each payload on send). @chain_focused =
      # editing it; @chain_marker_cursor remembers which marker to commit back to.
      @chain_pane = ChainPane.new
      @chain_focused = false
      @chain_marker_cursor = 0
      @show_dist = true # the DIST sidebar beside RESULTS (toggled with `v`)
      @dist_cache = nil.as(DistData?)
      @dist_cache_rev = -1_i64
      @dist_cache_w = -1
      # Reused scratch for build_dist's histogram inputs — cleared + refilled each rebuild so a
      # live run doesn't reallocate three growing arrays every frame. Not stored in DistData
      # (histogram consumes them into fresh bin arrays), so clearing on the next rebuild is safe.
      @dist_lens = [] of Int64
      @dist_words = [] of Int32
      @dist_times = [] of Int64
      # Results-pane memos, all keyed on @results_rev (the O(n)/O(n log n) scans below
      # ran EVERY frame — the busiest moment is a live run streaming results, each of
      # which forces a redraw). matched_count is rev-only; the sorted view also keys on
      # the sort order + matched-only toggle.
      #
      # NOTE on matched_count: during a live run @results_rev bumps per appended result, so
      # this key never hits and the count(&.matched?) scan does run every frame. Maintaining
      # the count incrementally in append_result instead was tried and benched at RESULT_CAP
      # (bench/fuzz_view_frame_bench.cr) — no measurable difference, the frame is dominated by
      # cell drawing. Left as a memo rather than trade a self-correcting recompute for state
      # that three mutation sites must keep in sync for no gain.
      @matched_count_cache = 0
      @matched_count_rev = -1_i64
      @sorted_cache = nil.as(Array(Fuzz::Result)?)
      @sorted_cache_rev = -1_i64
      @sorted_cache_sort = :index
      @sorted_cache_matched = false
      @sorted_cache_at = Time.instant # see SORT_REFRESH
      @progress = nil.as(Fuzz::Progress?)
      @run_total = nil.as(Int64?)
      @job_id = 0
      @stop_requested = false
      @detail_pane = :response
      # The RESULT detail's caret, selection, scroll anchor and whole draw. This pane is one of
      # the three hand-rolled copies `ReadPane` was extracted to replace (see its class comment)
      # and the last to move onto it: it carried its own `@detail_scroll` / `@detail_xscroll` /
      # `@detail_last_h` / `ReadCursor` plus its own `ensure_detail_visible`, and the drift
      # between that copy and the Decoder's was already a documented bug.
      #
      # Gutter on: these rows ARE lines of the request/response under test. Wrap on: a fuzz
      # response is attacker-shaped, so "one enormous line" is the normal case here, and the
      # tail of it used to be reachable only by panning sideways with ⇧←/→.
      @detail_read = ReadPane.new(gutter: true, wrap: true)
      @target_mode = InputMode::Read
      @template_mode = InputMode::Read
      @template_read = TextReadState.new
      @target_read = LineFieldRead.new
      # Decoded-protocol panes for the OPEN result detail (SAML/JWT/GraphQL/form),
      # parsed once per opened row (@decoded_index guards re-decode). Each nil/empty
      # one means that pane isn't offered — mirrors the History detail decode strip.
      @d_saml = nil.as(Saml::Doc?)
      @d_jwts = [] of Jwt::Found
      @d_graphql = nil.as(Graphql::Op?)
      @d_form = nil.as(Array(FormData::Field)?)
      @decoded_index = nil.as(Int64?)
      # The reconstructed request / decoded response text of the OPEN result detail,
      # cached by {pane, row index} — the request pane re-parsed the template + rendered
      # payloads and the response pane re-scrubbed + split the whole (possibly multi-MiB)
      # body on EVERY scroll keystroke. The selected row is fixed while the detail is open
      # (same invariant @decoded_index relies on), so this only recomputes on pane/row change.
      @detail_lines_cache = nil.as(Array(String)?)
      @detail_lines_key = nil.as({Symbol, Int64}?)
      # The Array `@detail_read` is currently pointed at, compared by IDENTITY — see
      # `sync_detail_source`.
      @detail_source_lines = nil.as(Array(String)?)
      # Styled overlay for the detail lines (syntax highlighting), keyed by pane/row +
      # theme revision so a palette switch rebuilds it. Held in lockstep with the plain
      # @detail_lines_cache; the plain lines still back the gutter/cursor/selection math.
      @detail_styled_cache = nil.as(Array(Highlight::Line)?)
      @detail_styled_key = nil.as({Symbol, Int64}?)
      @detail_styled_rev = 0_u32
      @focus = :template
      @loaded = false
      @dirty = false
      @running = false
    end

    # --- loading -------------------------------------------------------------
    # ⇧I: a CAPTURED flow becomes this session's template. `evidence` is set here and
    # nowhere else, because this is the only loader whose bytes came off the wire.
    #
    # Which is exactly why the bytes get two things done to them here and nowhere else:
    #
    #   * every `§` is escaped to the `§§` literal `Fuzz::Template.parse` already defines.
    #     `§…§` is this pane's INJECTION-POSITION syntax, but `§` is also U+00A7, ordinary
    #     text a German or legal body carries constantly — so a captured `"mk":"§SEED§"`
    #     used to arrive as a live position the operator never marked, and a run replaced
    #     the site's own text with every payload in the set. Escaping keeps the bytes:
    #     `render` puts the single `§` back on the wire, the Content-Length still agrees,
    #     and ^K still marks whatever the operator actually points at. (RepeaterView's
    #     `space ▸ f` seed applies the same escape at the same kind of seam.)
    #   * no `.scrub`. A capture is EVIDENCE and may legitimately not be valid UTF-8 — a
    #     protobuf/gRPC frame, a gzip'd POST, a latin-1 form field. Scrubbing rewrote each
    #     such byte to the three bytes of U+FFFD before the operator ever saw the request,
    #     and `Plan.build` then resynced Content-Length to the corruption. `Template.parse`
    #     / `render` and `evidence_template` are all byte-oriented, and RepeaterView#load
    #     never scrubbed; this was the one loader that did.
    def load(detail : Store::FlowDetail) : Nil
      built = Repeater::FlowRequest.build(detail)
      @http2 = built.http2
      @target = built.target
      @tcx = @target.size
      @target_field = :url
      @editor.set_text(String.new(Fuzz::Template.escape_literal_markers(built.bytes)))
      @evidence = true
      seed_env_baseline
      @focus = :template
      @loaded = true
      @dirty = false
    end

    def load_request(target : String, request_text : String, http2 : Bool, sni : String) : Nil
      @target = target
      @tcx = target.size
      @http2 = http2
      @sni = sni
      @scx = @sni.size
      @target_field = :url
      @editor.set_text(request_text)
      # A Repeater/reconstruction seed and ^N are DRAFTS: the operator authored (or gori
      # rebuilt) those bytes, so a `$KEY` in them is a variable reference they meant.
      @evidence = false
      seed_env_baseline
      @focus = :template
      @loaded = true
      @dirty = false
    end

    # A fresh, hand-authored fuzz session (^N). Focus starts on the TARGET field —
    # the scaffold URL is a placeholder you almost always change first (mirrors
    # RepeaterView#load_blank; the ⇧I/from-Repeater paths keep template focus since their
    # URL is already real).
    def load_blank : Nil
      load_request("https://example.com", "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n", false, "")
      @focus = :target
    end

    def restore(rec : Store::FuzzSessionRecord) : Nil
      @target = rec.target
      @tcx = rec.target.size
      @http2 = rec.http2?
      @sni = rec.sni || ""
      @scx = @sni.size
      @target_field = :url
      @editor.set_text(rec.template)
      # Provenance has to survive a restart, or a reopened capture silently becomes a
      # draft again. `flow_id` is what `insert_fuzz_session` already stored for the ⇧I
      # path and nothing else sets it — the same one-line test the CLI's `fuzz_source`
      # makes on `--flow`.
      @evidence = !rec.flow_id.nil?
      seed_env_baseline
      @name = rec.name
      apply_config_json(rec.config)
      @last_synced_config = rec.config
      @focus = :template
      @loaded = true
      @dirty = false
    end

    # Live cross-session request-side sync. Updates target/template/config/flags
    # WITHOUT wiping focus, in-memory results, scroll/selection, or a running job.
    # Full restore() is project-open only (it forces focus=:template).
    def apply_peer_session(rec : Store::FuzzSessionRecord) : Nil
      @target = rec.target
      @tcx = @target.size
      @http2 = rec.http2?
      @sni = rec.sni || ""
      @scx = @sni.size
      @target_field = :url
      # set_text zeroes the caret/scroll and clears undo, so it must only run on a REAL text
      # change. The compare is EXACT (`wire_text` is set_text's byte-for-byte inverse), the
      # same test RepeaterView#apply_request_fields makes: the template is persisted in wire
      # form now, so a normalized compare would be blind to a pure line-ending edit — which
      # is a real edit on a message — while an exact one is never falsely unequal.
      @editor.set_text(rec.template) if @editor.wire_text != rec.template
      @evidence = !rec.flow_id.nil? # see restore
      seed_env_baseline
      @name = rec.name
      apply_config_json(rec.config)
      @last_synced_config = rec.config
      @loaded = true
      @dirty = false
    end

    # True when the live view matches a store row's request-side fields (reconcile skip).
    # The template compare is EXACT — see apply_peer_session above; `template_text` is wire
    # form and is exactly what `update_fuzz_session` wrote, so the two can never disagree.
    def session_side_matches?(rec : Store::FuzzSessionRecord) : Bool
      @target == rec.target &&
        template_text == rec.template &&
        @http2 == rec.http2? &&
        (sni_override || "") == (rec.sni || "") &&
        (@name || "") == (rec.name || "") &&
        @last_synced_config == rec.config
    end

    # Content-only clone for sub-tab Duplicate: template + target + config/sets.
    # Does not copy run results, job state, or source flow linkage.
    def duplicate_from(src : FuzzerView) : Nil
      load_request(src.target, src.template_text, src.http2?, src.sni_override || "")
      # `load_request` cleared it; a content clone carries the SAME bytes, so it carries
      # the same provenance. (The clone has no `flow_id` row of its own, so `restore`
      # will read it back as a draft after a restart — that is the store's linkage, not
      # a claim about these bytes, and erring toward "draft" for a copy is the safe way.)
      @evidence = src.evidence?
      seed_env_baseline
      apply_config_json(src.config_json)
      @name = SubtabClone.copy_name(src.name)
      @dirty = true
      @results.clear
      @results_rev += 1
      @sel = 0
      @scroll = 0
      @running = false
      @stop_requested = false
      @job_id = 0
    end

    # --- persistence accessors ----------------------------------------------
    # `wire_text`, NOT `text`: this is what gets written to `fuzz_sessions.template`, so
    # persisting the LF projection would make the loss of a captured body's CRLFs SURVIVE a
    # restart — the run would then be wrong even after the send path was fixed. Wire form
    # round-trips exactly (`set_text` is `wire_text`'s inverse), and it is also what
    # `duplicate_from` and the reconstruction in `result_request` read.
    def template_text : String
      @editor.wire_text
    end

    def sni_override : String?
      s = @sni.strip
      s.empty? ? nil : s
    end

    def summary(max : Int32 = 28) : String
      line = (@editor.first_nonblank_line || "").strip
      parts = line.split(' ')
      s = "#{parts[0]?} #{parts[1]?}".strip
      s = "new" if s.empty?
      s.size > max ? "#{s[0, max - 1]}…" : s
    end

    # HTTP method from the template's request line — feeds the sub-tab filter's `method:`.
    def request_method : String
      (@editor.first_nonblank_line || "").strip.split(' ').first? || ""
    end

    def label(max : Int32 = 18) : String
      if (n = @name) && !(t = n.strip).empty?
        t.size > max ? "#{t[0, max - 1]}…" : t
      else
        summary(max)
      end
    end

    def mark_dirty : Nil
      @dirty = true
    end

    def clear_dirty : Nil
      @dirty = false
    end

    # After a successful save, record the config blob we just wrote so reconcile
    # can equality-skip without re-serializing (JSON field order may differ).
    def mark_config_synced(config : String) : Nil
      @last_synced_config = config
    end

    # --- focus ring ----------------------------------------------------------
    # Every focus change exits the ^S SNI sub-field — the rule `RepeaterView#set_focus`
    # states: SNI editing is an explicit per-visit sub-mode, so navigating away while in it
    # and coming back must not silently route URL keystrokes into @sni.
    def focus_first : Nil
      set_focus(:target)
    end

    def focus_last : Nil
      set_focus(:results)
    end

    def focus_pane(pane : Symbol) : Nil
      return unless PANE_ORDER.includes?(pane)
      commit_chain_pane if @chain_focused
      set_focus(pane)
    end

    def focus_config : Nil
      commit_chain_pane if @chain_focused
      set_focus(:config)
      @cfg_row = 0 # land on the first payload set / the Add row
    end

    def pane_advance(dir : Int32) : Bool
      commit_chain_pane if @chain_focused
      if @focus == :detail
        set_focus(:results)
        return true
      end
      i = PANE_ORDER.index(@focus) || 0
      ni = i + dir
      return false if ni < 0 || ni >= PANE_ORDER.size
      set_focus(PANE_ORDER[ni])
      true
    end

    private def set_focus(pane : Symbol) : Nil
      @focus = pane
      @target_field = :url
    end

    def at_top? : Bool
      @focus == :target
    end

    def template_at_top? : Bool
      @editor.at_top?
    end

    def config_at_top? : Bool
      @cfg_row == 0
    end

    def results_at_top? : Bool
      @sel == 0
    end

    def set_preedit(text : String) : Nil
      if chain_pane_active?
        @chain_pane.set_preedit(text)
      elsif @focus == :template && template_insert?
        @editor.set_preedit(text)
      end
    end

    # --- READ / INS input modes (target + template panes) ---
    getter target_mode : InputMode
    getter template_mode : InputMode

    # The RESULT detail's caret + selection. Read off the pane that owns them now, rather than
    # being a second cursor beside it.
    def detail_cursor : ReadCursor
      @detail_read.cursor
    end

    # The READ-mode caret/selection over the TEMPLATE pane. Exposed like
    # `HistoryView#detail_read` so a wrap example can assert where a visual-row step landed in
    # BUFFER coordinates — the one thing a screen-cell assertion cannot distinguish from a
    # caret that stopped on the right cell of the wrong line.
    def template_read : ReadCursor
      @template_read.cursor
    end

    def target_insert? : Bool
      @target_mode == InputMode::Insert
    end

    def template_insert? : Bool
      @template_mode == InputMode::Insert
    end

    def pane_insert?(pane : Symbol) : Bool
      case pane
      when :template then template_insert? || chain_pane_active?
      when :target   then target_insert?
      else                false
      end
    end

    def enter_target_insert! : Nil
      @target_mode = InputMode::Insert
    end

    def exit_target_insert! : Nil
      @target_mode = InputMode::Read
    end

    def enter_template_insert! : Nil
      @template_mode = InputMode::Insert
    end

    def exit_template_insert! : Nil
      @template_mode = InputMode::Read
      @editor.env_complete_close # no dangling $ENV dropdown once we leave insert mode
      # Carry an INS ⇧arrow selection over to READ — see TextReadState#adopt_editor_selection.
      @template_read.adopt_editor_selection(@editor)
    end

    # --- $ENV autocomplete in the template editor ---
    # True while the template is a live text editor (insert mode, not the CHAIN sub-pane) —
    # the state in which the $ENV dropdown and editor-style Tab apply (controller reads it too).
    def template_text_editing? : Bool
      @focus == :template && template_insert? && !chain_pane_active?
    end

    def template_env_completing? : Bool
      template_text_editing? && @editor.env_completing?
    end

    # The popup owns tab/↵/↑/↓/esc while open; accepting edits the buffer → mark dirty.
    def handle_template_env_complete_key(ev : Termisu::Event::Key) : Bool
      return false unless template_text_editing?
      before = @editor.edits
      handled = @editor.handle_env_complete_key(ev)
      @dirty = true if handled && @editor.edits != before
      handled
    end

    # Editor-style Tab: insert a literal tab into the template (no focus move).
    def template_tab_insert : Nil
      return unless template_text_editing?
      @editor.insert('\t')
      @editor.set_preedit("")
      @dirty = true
    end

    def detail_navigable? : Bool
      @focus == :detail
    end

    # The CHAIN sub-pane owns keyboard input (focused on the TEMPLATE column). The
    # controller routes template keys here when true.
    def chain_pane_active? : Bool
      @chain_focused && @focus == :template
    end

    # ^Q: focus the CHAIN pane for the marker under the template cursor. Returns a hint
    # string when it can't (surfaced by the controller), nil on success.
    def focus_chain_pane : String?
      return "move to the TEMPLATE pane first (↹)" unless @focus == :template
      chain = Fuzz::Template.chain_at(@editor.text, @editor.cursor_offset)
      return "put the cursor in a §…§ marker · ^A mark all · ^T insert §" if chain.nil?
      @chain_marker_cursor = @editor.cursor_offset
      @chain_pane.load(chain)
      @chain_focused = true
      nil
    end

    # Commit the CHAIN pane back to the bound marker + return focus to the template editor.
    # Idempotent so the focus changers above can call it freely.
    def commit_chain_pane : Nil
      return unless @chain_focused
      # The marker's open § (value region) is unchanged by the chain edit, so it's a stable
      # anchor — restoring the raw cursor could land inside a now-longer hidden chain.
      anchor = Fuzz::Template.marker_start_at(@editor.text, @chain_marker_cursor) || @chain_marker_cursor
      if updated = Fuzz::Template.set_chain(@editor.text, @chain_marker_cursor, @chain_pane.value)
        @editor.set_text(restore_wire_eols(updated))
        @editor.place_at_offset(anchor) # back into the marker (set_text reset it) → tooltip stays up
        @dirty = true
      end
      @chain_focused = false
    end

    # Leave the CHAIN pane WITHOUT writing its edits back to the marker (esc = cancel,
    # matching the pane's own "esc cancel" hint). The template text is only touched by
    # commit_chain_pane, so dropping focus is a clean discard; restore the cursor onto
    # the marker so its tooltip stays up.
    def discard_chain_pane : Nil
      return unless @chain_focused
      anchor = Fuzz::Template.marker_start_at(@editor.text, @chain_marker_cursor) || @chain_marker_cursor
      @editor.place_at_offset(anchor)
      @chain_focused = false
    end

    # Route a key while the CHAIN pane is focused (typing/autocomplete stays; ↵/tab/↑
    # commit + return to the template editor, while esc cancels — discards the edit).
    def handle_chain_pane_key(ev : Termisu::Event::Key) : Nil
      return if @chain_pane.handle_key(ev)
      key = ev.key
      if key.escape?
        discard_chain_pane
      elsif key.enter? || key.tab? || key.up?
        commit_chain_pane
      end
    end

    # "§N" label for the marker under the template cursor (1-based), or "§" when not in one.
    private def marker_label : String
      cur = @editor.cursor_offset
      idx = marker_spans.index { |(a, b)| a <= cur && cur <= b }
      idx ? "§#{idx + 1}" : "§"
    end

    # --- marking -------------------------------------------------------------
    # Re-attach the buffer's ORIGINAL line terminators to the result of a marking transform.
    #
    # The § / ¦ helpers (auto_mark, mark_word, clear_markers, set_chain) all take the LF
    # projection, because every offset they are given — `@editor.cursor_offset`, the cached
    # `marked_spans` — indexes THAT string; handing them wire text would shift every offset by
    # one per CRLF line and mark the wrong span. But they only ever insert or delete `§`/`¦`
    # WITHIN a line, never a newline, so the line count is invariant and the terminators can
    # simply be put back. Without this, `set_text(transformed)` stores the LF projection and a
    # captured body's CRLFs are gone before the run even starts — which is how ^K (the marking
    # chord the status line names on every fuzz session open) defeated a byte-exact send path.
    #
    # Falls back to `lf_text` unchanged when the line count did move: better a template that
    # lost its CRLFs than one whose terminators were reattached to the wrong lines.
    private def restore_wire_eols(lf_text : String) : String
      wl = @editor.wire_lines
      parts = lf_text.split('\n')
      return lf_text unless parts.size == wl.size
      return lf_text if wl.all? { |(_, eol)| eol == "\n" || eol.empty? } # nothing to restore
      String.build do |io|
        parts.each_with_index do |p, i|
          io << p
          io << wl[i][1]
        end
      end
    end

    def auto_mark : String
      before = @editor.text
      text = Fuzz::Template.auto_mark(before)
      # `Template.auto_mark` is a deliberate no-op once ANY § is present — it will not
      # double-mark, and it must not clear the operator's own markers to re-derive them.
      # Say so instead of counting the markers in the UNCHANGED text and reporting them
      # as if this keystroke had placed them (mark_word already refuses honestly).
      if text == before
        n = Fuzz::Template.parse(before).position_count
        return "already marked (#{n} position#{n == 1 ? "" : "s"}) — Clear markers first to re-derive" unless n.zero?
        # A `§` with no POSITION around it — an escaped `§§`, which is what `#load` makes of
        # a capture's own `§`, or a half-open one the operator typed. `Template.auto_mark`
        # is a no-op on either, and the "nothing to mark" line below would be a plain untruth
        # about a request that visibly has a query string and a body full of values.
        return "§ here is literal (escaped §§) — auto-mark won't add positions; ^K marks the token at the cursor" if Fuzz::Template.marker_bytes_in?(before.to_slice)
        return "nothing to auto-mark — no query, cookie or body values found"
      end
      @editor.set_text(restore_wire_eols(text))
      @dirty = true
      n = Fuzz::Template.parse(text).position_count
      "auto-marked #{n} position#{n == 1 ? "" : "s"}"
    end

    # Flip the run transport between HTTP/1.1 and HTTP/2 (`^V`), picking which engine the
    # Sender dials and overriding the seed flow's protocol. Rewrites the request-line
    # version token to match (so a template seeded from an h2 flow doesn't ship a stray
    # "HTTP/2" once run over h1, and the `TEMPLATE (h2)` label agrees with the wire).
    def toggle_http2 : Bool
      @http2 = !@http2
      if first = @editor.text.split('\n', 2).first?
        if updated = Repeater::FlowRequest.retarget_version_line(first, @http2)
          @editor.replace_line(0, updated)
        end
      end
      @dirty = true
      @http2
    end

    # Reformat the template's BODY. Reads `wire_text` and splices the head back verbatim: a
    # pretty-print is an explicit request to rewrite the body, but it is not a licence to
    # re-encode the head's terminators — this is the one marking-adjacent transform whose line
    # count moves, so restore_wire_eols cannot cover it.
    def pretty_print_template : String?
      text = @editor.wire_text
      crlf = text.index("\r\n\r\n")
      lf = text.index("\n\n")
      # First blank line wins, whichever form it is (an LF head whose BODY holds a CRLFCRLF
      # must not be split at the body's) — same rule as Fuzz::ContentLength.boundary.
      sep, sep_w = if crlf && (lf.nil? || crlf <= lf)
                     {crlf, 4}
                   elsif lf
                     {lf, 2}
                   else
                     {nil, 0}
                   end
      return "no request body" unless sep

      head = text[0, sep]
      eol = sep_w == 4 ? "\r\n" : "\n"
      body = text[sep + sep_w..]
      return "request body is empty" if body.strip.empty?

      if formatted_body = Pretty.format_request(head, body)
        new_text = "#{head}#{eol}#{eol}#{formatted_body}"
        @editor.set_text(new_text)
        @dirty = true
        nil # success
      else
        "failed to pretty-print (unsupported or malformed body)"
      end
    end

    def mark_word : String
      return "mark word (^K) works on the TEMPLATE pane — ↹ to it" unless @focus == :template
      before = @editor.text
      after = Fuzz::Template.mark_word(before, @editor.cursor_offset)
      return "no word at the cursor — place it on a token (or ^A to auto-mark)" if after == before
      @editor.set_text(restore_wire_eols(after))
      @dirty = true
      Fuzz::Template.parse(after).position_count < Fuzz::Template.parse(before).position_count ? "unmarked position" : "marked position"
    end

    # Drop a single § marker at the cursor. Place two to bracket ANY region by hand:
    # ^K auto-expands to a whole token, but this gives byte-exact control over the
    # span — part of a token, or a region crossing delimiters that word-detection
    # would never pick. An odd marker count means a position is still "open"; move
    # the cursor and fire again to close it. (parse treats a dangling § as literal.)
    def insert_marker : String
      return "mark point (^T) works on the TEMPLATE pane — ↹ to it" unless @focus == :template
      @editor.insert(Fuzz::Template::MARKER)
      @editor.set_preedit("")
      @dirty = true
      if @editor.text.count(Fuzz::Template::MARKER).odd?
        "marker opened — move the cursor and ^T again to close the region"
      else
        n = Fuzz::Template.parse(@editor.text).position_count
        "marked point — #{n} position#{n == 1 ? "" : "s"}"
      end
    end

    def clear_marks : String
      # clear_markers renders the defaults inline — drops both the § delimiters AND any
      # ¦chain (a naive gsub("§","") would leave a stray value¦chain behind).
      @editor.set_text(restore_wire_eols(Fuzz::Template.clear_markers(@editor.text)))
      @dirty = true
      "cleared all § markers"
    end

    # Insert an OAST payload URL at the template caret (cross-tab "Insert OAST payload").
    # Only when the template pane is focused.
    def insert_oast_payload(url : String) : Bool
      return false unless @focus == :template
      @editor.insert_string(url)
      @editor.set_preedit("")
      @dirty = true
      true
    end

    def position_count : Int32
      marker_spans.size
    end

    # Cached `§…§` char-offset spans for the current template buffer, recomputed only
    # when the editor content changes (cheap Int compare on @editor.edits). marked_spans
    # is 1:1 with parse().positions, so `.size == position_count`. Backs the template
    # tint colours AND the config Sets→marker chips so the two can never disagree.
    private def marker_spans : Array({Int32, Int32})
      if @editor.edits != @marker_text_rev
        @marker_text_rev = @editor.edits
        @marker_spans = Fuzz::Template.marked_spans(@editor.text)
      end
      @marker_spans
    end

    # The chain (`¦…`) of the marker under the cursor, or nil (not in a marker) / "" (marker,
    # no chain). Cached on {editor revision, cursor} so a stationary cursor doesn't re-join +
    # re-scan the whole template buffer every render frame the CHAIN pane is visible.
    private def chain_under_cursor : String?
      cur = @editor.cursor_offset
      if @editor.edits != @chain_rev || cur != @chain_cursor
        @chain_rev = @editor.edits
        @chain_cursor = cur
        @chain_cache = Fuzz::Template.chain_at(@editor.text, cur)
      end
      @chain_cache
    end

    # {open, sep, close} regions cached on the editor revision — the template tint runs it
    # every render; without the cache marker_regions did 2× whole-buffer `text.chars` per
    # frame (its own + marked_spans'). Reuses the already-cached `marker_spans`.
    private def marker_regions : Array({Int32, Int32, Int32})
      if @editor.edits != @marker_regions_rev
        @marker_regions_rev = @editor.edits
        @marker_regions_cache = Fuzz::Template.marker_regions(@editor.text, marker_spans)
      end
      @marker_regions_cache
    end

    # --- run lifecycle -------------------------------------------------------

    # The running engine, so ^X can reach it directly. Set by FuzzerController#start_run
    # before the run fiber is spawned; mirrors `DiscoverRun#engine`, which is the one tab
    # that already did this and the reason its stop is prompt.
    property engine : Fuzz::Engine? = nil

    def stop_requested? : Bool
      @stop_requested
    end

    # Stop NOW, not at the next event.
    #
    # The flag alone was reaching the engine only through `engine.stop if v.stop_requested?`
    # inside the controller's `engine.run { }` block — so it took effect only when the next
    # event arrived, and there are windows with no events at all. `calibrate_baseline` runs
    # BEFORE `engine.run` is ever called, so a ^X during auto-calibrate stopped nothing: the
    # remaining calibration requests went out and then a full sweep STARTED, after the
    # operator had asked to stop. For a tool whose contract is that the operator decides what
    # leaves the machine (P4), that is a correctness bug, not a latency one.
    def request_stop : Nil
      @stop_requested = true
      @engine.try(&.stop)
    end

    def begin_run(total : Int64?) : Nil
      @results.clear
      @run_template = @pending_template # freeze the template these results are rendered against
      @run_policy = @pending_policy     # ...and the CL knobs + retention its generator ran under
      @results_rev += 1
      # A fresh run reuses result indices from 0, so drop the {pane, index}-keyed detail
      # cache — otherwise an old row's lines could survive under a colliding new index.
      # `@detail_source_lines` goes with it: dropping the cache alone would already force a
      # rebuild (and so a re-source, the Array being new), but tying the two together keeps
      # the "the pane is pointed at THAT Array" invariant readable in one place.
      @detail_lines_cache = nil
      @detail_source_lines = nil
      @detail_lines_key = nil
      @detail_styled_cache = nil
      @detail_styled_key = nil
      @sel = 0
      @scroll = 0
      @running = true
      @stop_requested = false
      @run_total = total
      @progress = Fuzz::Progress.new(0_i64, total, 0_i64, 0_i64)
      clear_detail_decode # a new run reuses request indices → drop the old decode cache
    end

    def finish_run : Nil
      @running = false
    end

    def apply_progress(p : Fuzz::Progress) : Nil
      @progress = p
    end

    def append_result(r : Fuzz::Result) : Nil
      @results << r
      if @results.size > RESULT_CAP
        @results.shift
        # Only the raw index view (no filter, no re-sort) shifts 1:1 with @results, so only
        # there does pinning selection/scroll by -1 keep the same logical rows. In a
        # matched-only or re-sorted view the evicted (usually unmatched) front row isn't at
        # this position — @sel should stay put (the render clamp bounds it); a blind -1 there
        # would retarget the open detail to a different result.
        if @sort == :index && !@matched_only
          @sel -= 1 if @sel > 0
          @scroll -= 1 if @scroll > 0
        end
      end
      @results_rev += 1 # grow AND ring-evict both bump (size is pinned once full)
    end

    def matched_count : Int32
      return @matched_count_cache if @matched_count_rev == @results_rev
      @matched_count_cache = @results.count(&.matched?)
      @matched_count_rev = @results_rev
      @matched_count_cache
    end

    def result_count : Int32
      @results.size
    end

    # --- config pane (calm summary) ------------------------------------------
    # A single row cursor @cfg_row (↑/↓) walks: one row per payload set, then the
    # Add / Mode / Advanced rows (Run is the TEMPLATE border's ^R:RUN badge now, not a
    # cursor row). There is NO text field and NO caret in-pane — all text entry lives in the
    # Set / Advanced overlays — so ←/→ can only ever cycle (Mode), which removes the old
    # caret-vs-cycle overload and the axis mismatch.
    CONFIG_TAIL = [:add, :mode, :advanced]

    private def config_row_count : Int32
      @sets.size + CONFIG_TAIL.size
    end

    # The kind of row under the cursor: :set | :add | :mode | :advanced. (Run is no longer a
    # config row — it moved to the TEMPLATE border's ^R:RUN badge.)
    def config_row : Symbol
      @cfg_row < @sets.size ? :set : (CONFIG_TAIL[@cfg_row - @sets.size]? || :advanced)
    end

    # The payload-set index under the cursor, or nil when the cursor is on a tail row.
    def current_set_index : Int32?
      @cfg_row < @sets.size ? @cfg_row : nil
    end

    # ↑/↓ — move the row cursor.
    def form_move(d : Int32) : Nil
      @cfg_row = (@cfg_row + d).clamp(0, {config_row_count - 1, 0}.max)
    end

    # ←/→ — cycle Mode (the only in-pane cycler); a no-op on every other row.
    def form_adjust(d : Int32) : Nil
      cycle_mode(d) if config_row == :mode
    end

    # Del/⌫ on a set row — remove that set.
    def form_delete : Nil
      if i = current_set_index
        remove_set(i)
      end
    end

    # The payload sets, for the Set overlay to seed an edit and the engine to build.
    def set_specs : Array(SetSpec)
      @sets
    end

    # Apply the Set overlay's result: append (edit_index nil) or replace an existing
    # set. A nil spec (blank required input) leaves @sets unchanged.
    def apply_set(edit_index : Int32?, spec : SetSpec?) : Nil
      return unless spec
      if i = edit_index
        @sets[i] = spec if 0 <= i < @sets.size
      else
        @sets << spec
        @cfg_row = @sets.size - 1 # land on the just-added set
      end
      @cfg_row = @cfg_row.clamp(0, {config_row_count - 1, 0}.max)
      @dirty = true
    end

    private def remove_set(i : Int32) : Nil
      return unless 0 <= i < @sets.size
      @sets.delete_at(i)
      @cfg_row = @cfg_row.clamp(0, {config_row_count - 1, 0}.max)
      @dirty = true
    end

    private def cycle_mode(d : Int32) : Nil
      modes = [Fuzz::Mode::Sniper, Fuzz::Mode::BatteringRam, Fuzz::Mode::Pitchfork, Fuzz::Mode::ClusterBomb]
      i = modes.index(@config.mode) || 0
      @config.mode = modes[(i + d) % modes.size]
      @dirty = true
    end

    # ⏎ on the Mode row — cycle forward (mirrors form_adjust(1)).
    def cycle_mode_forward : Nil
      cycle_mode(1)
    end

    # --- advanced overlay bridge ---------------------------------------------
    # Read the current advanced knobs for FuzzAdvancedOverlay to seed from.
    def advanced_snapshot : AdvancedSnapshot
      AdvancedSnapshot.new(
        conc: @s_conc, rate: @s_rate, timeout: @s_timeout, retries: @s_retries,
        max_requests: @s_max_req,
        follow: @config.follow_redirects?, calibrate: @config.auto_calibrate?,
        keep_alive: @config.keep_alive?, update_cl: @config.update_content_length?,
        m_status: @matcher.match_status || "", m_size: @matcher.match_size || "",
        m_words: @matcher.match_words || "", m_regex: @s_m_regex,
        f_status: @matcher.filter_status || "", f_size: @matcher.filter_size || "",
        f_words: @matcher.filter_words || "", f_regex: @s_f_regex)
    end

    # Write the overlay's edited knobs back into the engine buffers (regexes stay as
    # source strings, compiled by commit_buffers at build/persist time — unchanged).
    def apply_advanced(s : AdvancedSnapshot) : Nil
      @s_conc = s.conc
      @s_rate = s.rate
      @s_timeout = s.timeout
      @s_retries = s.retries
      @s_max_req = s.max_requests
      @config.follow_redirects = s.follow
      @config.auto_calibrate = s.calibrate
      @matcher.auto_calibrate = s.calibrate
      @config.keep_alive = s.keep_alive
      @config.update_content_length = s.update_cl
      @matcher.match_status = blank_nil(s.m_status)
      @matcher.match_size = blank_nil(s.m_size)
      @matcher.match_words = blank_nil(s.m_words)
      @s_m_regex = s.m_regex
      @matcher.filter_status = blank_nil(s.f_status)
      @matcher.filter_size = blank_nil(s.f_size)
      @matcher.filter_words = blank_nil(s.f_words)
      @s_f_regex = s.f_regex
      @dirty = true
    end

    private def blank_nil(s : String) : String?
      s.strip.empty? ? nil : s
    end

    # --- run-count estimate --------------------------------------------------
    # The "Run · N requests" figure for the summary's Run row, memoized on a cheap
    # signature (mode + set specs + marker count) so it never rebuilds sources per
    # frame. nil when the size is unknown (empty/invalid config, or an overflowing
    # cluster-bomb / brute set) → the Run row omits the count.
    def run_request_count : Int64?
      sig = "#{@config.mode}|#{position_count}|#{@sets.map { |s| "#{s.kind}:#{s.value}" }.join("~")}"
      return @run_count_cache if sig == @run_count_sig
      @run_count_sig = sig
      @run_count_cache = compute_run_count
    end

    private def compute_run_count : Int64?
      return nil if @sets.empty? || position_count == 0
      sizes = @sets.map { |s| estimated_set_size(s) }
      return nil if sizes.any?(Nil) # any unknown / overflowing size → unknown total
      run_count_for_mode(sizes.compact)
    rescue
      nil
    end

    # Only line-count a wordlist this small on the render fiber; anything larger
    # reports "unknown" for the live estimate rather than freezing the UI.
    COUNT_FILE_CAP = 8_i64 * 1024 * 1024

    # A set's payload count for the LIVE Run-row estimate. `run_request_count` runs on
    # the render fiber, so a wordlist file is counted only when it's a regular file
    # within COUNT_FILE_CAP — a rockyou-scale file would freeze the UI for seconds
    # (re-read on every Mode cycle) and a non-regular path (/dev/zero, a FIFO) would
    # block forever. Those report nil → the Run row just omits the count; the exact
    # total is still computed off this path when the run actually starts.
    private def estimated_set_size(s : SetSpec) : Int64?
      if s.kind == :file
        info = File.info?(s.value)
        return nil unless info && info.type.file? && info.size <= COUNT_FILE_CAP
      end
      Fuzz::PayloadSet.new(build_source(s)).size
    end

    private def run_count_for_mode(ns : Array(Int64)) : Int64?
      first = ns.first? || 0_i64
      case @config.mode
      when .sniper?        then mul_checked(position_count.to_i64, first)
      when .battering_ram? then first
      when .pitchfork?     then (0...position_count).min_of? { |i| ns[i]? || first } || 0_i64
      else                      combos(ns) # cluster-bomb ∏Nᵢ
      end
    end

    # ∏ of the per-position set sizes (cluster-bomb), nil on Int64 overflow.
    private def combos(ns : Array(Int64)) : Int64?
      total = 1_i64
      (0...position_count).each do |i|
        n = ns[i]? || ns.first? || 0_i64
        total = mul_checked(total, n) || return nil
      end
      total
    end

    private def mul_checked(a : Int64, b : Int64) : Int64?
      return 0_i64 if a == 0 || b == 0
      return nil if a > Int64::MAX // b
      a * b
    end

    # Push the buffered numeric/regex fields into @config/@matcher (before a run and
    # before persistence) so they reflect the edited buffers.
    private def commit_buffers : Nil
      @config.concurrency = (@s_conc.to_i? || 20).clamp(1, 1000)
      @config.rps = @s_rate.to_f?.try { |r| r > 0 ? r : nil }
      @config.timeout = @s_timeout.to_i?.try { |t| t > 0 ? t.seconds : nil }
      @config.retries = (@s_retries.to_i? || 0).clamp(0, 1000)
      # Blank / unparsable / <= 0 all mean "no cap" — the same reading `--max-requests`
      # and MCP give an absent key, so clearing the field really does remove the ceiling.
      @config.max_requests = @s_max_req.to_i64?.try { |n| n > 0 ? n : nil }
      @matcher.match_regex = @s_m_regex.empty? ? nil : (Regex.new(@s_m_regex) rescue nil)
      @matcher.filter_regex = @s_f_regex.empty? ? nil : (Regex.new(@s_f_regex) rescue nil)
    end

    private def sync_buffers : Nil
      @s_conc = @config.concurrency.to_s
      @s_rate = @config.rps.try(&.to_s) || ""
      @s_timeout = @config.timeout.try(&.total_seconds.to_i.to_s) || ""
      @s_retries = @config.retries.to_s
      @s_max_req = @config.max_requests.try(&.to_s) || ""
      @s_m_regex = @matcher.match_regex.try(&.source) || ""
      @s_f_regex = @matcher.filter_regex.try(&.source) || ""
    end

    # A message when a non-empty regex buffer failed to compile (commit_buffers nils
    # it, which would otherwise match everything with no feedback), else nil.
    private def regex_error : String?
      return "invalid match regex: #{@s_m_regex}" if !@s_m_regex.empty? && @matcher.match_regex.nil?
      return "invalid filter regex: #{@s_f_regex}" if !@s_f_regex.empty? && @matcher.filter_regex.nil?
      nil
    end

    # --- engine assembly -----------------------------------------------------
    # Build an engine ready to run, or {nil, error}. `scope` becomes the interactive
    # `Gori::Outbound` decision the sender dials through: no up-front allowlist gate (the
    # operator typed this target), but Sandbox mode and explicit EXCLUDE rules hard-block
    # every send — the same protection Discover already applies per-request.
    # `overrides` is the project's hostname overrides. It defaults to nil because the
    # Fuzzer tab has never applied them (the proxy path does, via Proxy::Upstream.dial) and
    # closing that gap is a controller change, outside this refactor — but the parameter
    # exists so the fix is one call-site edit rather than another re-plumbed sender.
    def build_engine(verify : Bool, scope : Gori::Scope,
                     overrides : Gori::HostOverrides? = nil) : {Fuzz::Engine?, String?}
      commit_buffers
      if err = regex_error
        return {nil, err} # don't silently run match-everything on a bad pattern
      end
      # `wire_text`, NOT `text` — the same distinction the Repeater's send path draws
      # (`RepeaterView#expanded_editor_bytes`) and for the same reason. `text` is the LF
      # projection: it flattens every CRLF the capture carried, and since `ContentLength.sync`
      # then resyncs the header DOWN to the shortened body, a captured request goes out one
      # byte shorter per line with nothing erroring and nothing warning. A 0x0D 0x0A inside a
      # BODY is data — a CL/TE desync probe, a multipart delimiter, part content, a
      # CRLF-injection test — never a line ending the fuzzer may re-encode, and a sweep whose
      # baseline is not the captured request produces results that mean nothing.
      # `Plan.build`'s `Env.expand_wire` still promotes the HEAD to CRLF, and it is idempotent
      # on a head that already carries CRLF (`Env.normalize_crlf` only inserts a CR before an
      # LF that has none), so a wire-form template changes nothing downstream.
      options = Fuzz::PlanOptions.new(evidence_template, evidence: @evidence,
        target: @target, http2: @http2,
        sources: @sets.map { |s| build_source(s) }, config: @config, matcher: @matcher,
        verify: verify, sni: sni_override, overrides: overrides, env_vars: operator_env_vars)
      plan = Fuzz::Plan.build(options, Gori::Outbound.interactive(scope))
      @pending_template = plan.template # committed to @run_template in begin_run (see result_request)
      # Freeze the CL knobs + retention policy the same way: the reconstruction in
      # `result_request` has to reproduce what THIS run's generator did, and its note has to
      # name the retention THIS run used — not what the CONFIG pane says after a post-run edit.
      @pending_policy = {@config.update_content_length?, @config.add_content_length_when_missing?,
                         @matcher.keep_bodies}
      # The template declares a Content-Length that disagrees with its own body BEFORE any
      # payload is substituted — so the auto-resync is about to rewrite framing the operator
      # authored deliberately, on every variation, and the sweep would report a clean
      # CL-desync run that never put a CL desync on the wire. `gori run fuzz` says this once
      # up front and names `--verbatim`; this is the same fact pointed at the toggle.
      @cl_rewrite = plan.rewrites_content_length?
      @cl_rewrite_rev = @editor.edits
      {plan.engine, nil}
    rescue ex : Fuzz::PlanError
      {nil, fuzz_plan_error(ex)}
    rescue ex
      {nil, "config error: #{ex.message}"}
    end

    # The template bytes handed to `Plan.build`, with ONE editor-owed fixup applied for an
    # EVIDENCE session.
    #
    # `Fuzz::PlanOptions#evidence?` turns off two draft-time passes at once, and only one of
    # them is right for a tab that has an editor in it:
    #
    #   * the unresolved-`$KEY` refusal and `$KEY` SUBSTITUTION — off, and that is the whole
    #     point. A capture's `$filter`/`$top`/`$where`/`$IFS`/`$user.name` are bytes the
    #     origin sent, not variables anybody typed. With them on, a captured OData request
    #     was refused outright, and the refusal's own remedy ("set the variable") rewrote the
    #     PARAMETER NAMES on the wire (`?PWNED=aa&99=10`) while the TEMPLATE pane still read
    #     `$filter=§…§` and the screen said `6 hits / 6 sent`.
    #   * the head's LF→CRLF promotion — which `expand_wire` did, and which this editor still
    #     OWES the wire. `TextArea#insert_newline` gives a line the user typed `DEFAULT_EOL`
    #     ("\n") and documents `expand_wire` as what promotes it back; without that, adding
    #     one header to a seeded capture would put a bare LF in the head — itself a
    #     front-end/back-end desync primitive, i.e. a different test than the one on screen.
    #     So the view runs the head-only normalization itself. It is idempotent on a head
    #     that already carries CRLF (`Env.normalize_crlf` only inserts a CR before an LF that
    #     has none), the body is copied through byte-for-byte, and no `$` is touched.
    #
    # Provenance is about where the bytes CAME FROM, so an operator edit does not clear it:
    # ^A/^K only insert §/¦ within a line (`restore_wire_eols` keeps every terminator), and
    # dropping evidence on the first keystroke would put the substitution back on the most
    # common workflow there is — seed a capture, tweak a header, mark, run.
    #
    # The one thing given up: an IMPORTED flow whose head is bare-LF terminated is promoted
    # here rather than replayed. gori's proxy refuses to capture such a head at all (P7), so
    # it is not reachable through the proxy; `gori run repeater --verbatim` is the byte-exact
    # route for one.
    # Record the `$NAME`s the just-seeded template arrived with, and tell the editor which of
    # them it must not paint (or tooltip) as resolvable. Called from every loader AFTER both
    # the text and `@evidence` are set — the baseline has to describe the bytes gori was
    # handed, and the editor's answer has to match the provenance those bytes carry.
    private def seed_env_baseline : Nil
      @evidence_env_names = Env.token_names(@editor.wire_text).to_set
      @editor.env_literal_names = @evidence ? @evidence_env_names : Set(String).new
    end

    # The `$KEY` table THIS template may substitute from, or nil to substitute nothing.
    #
    # nil only for a draft, where `Plan.build` expands the full table itself. For an evidence
    # session it is every registered name EXCEPT the ones the seed arrived with: a `$TOKEN`
    # the operator adds to a captured template is a variable reference they typed, while the
    # capture's own `$filter`/`$top`/`$where` are origin bytes and stay literal for the life
    # of the session. Same rule, same wording as `RepeaterView#operator_env_vars` — the two
    # tabs hold the same bytes for the same flow and must not answer this differently.
    private def operator_env_vars : Hash(String, String)?
      return nil unless @evidence
      Env.vars_without(@evidence_env_names)
    end

    private def evidence_template : String
      text = @editor.wire_text
      return text unless @evidence
      bytes = text.to_slice
      boundary = Env.head_body_boundary(bytes)
      head = Env.normalize_crlf(bytes[0...boundary])
      return String.new(head) if boundary >= bytes.size
      body = bytes[boundary..]
      buf = IO::Memory.new(head.size + body.size)
      buf.write(head)
      buf.write(body)
      String.new(buf.to_slice)
    end

    # The Fuzzer tab's wording for a plan this view's state can't produce. The builder
    # reports the machine-readable `reason`; the hint (and the hotkeys it names) is ours.
    private def fuzz_plan_error(ex : Fuzz::PlanError) : String
      case ex.reason
      in Fuzz::PlanError::Reason::NoPositions
        "mark a position first — ^A params · ^K word"
      in Fuzz::PlanError::Reason::NoTarget, Fuzz::PlanError::Reason::BadTarget
        "invalid target — use scheme://host[:port]/path"
      in Fuzz::PlanError::Reason::NoPayloads
        "add a payload set — ^O config · + Add set (^L for a List)"
      in Fuzz::PlanError::Reason::UnresolvedEnv
        "unresolved env #{ex.detail} — add it in the Project tab's ENV pane"
      end
    end

    # True when the LAST plan built off this exact template buffer was going to recompute a
    # Content-Length the operator wrote by hand. Scoped to `@editor.edits` so a template
    # edit retracts the claim rather than leaving a stale one on screen.
    def rewrites_content_length? : Bool
      @cl_rewrite && @editor.edits == @cl_rewrite_rev
    end

    # `gori run fuzz`'s sentence for the same fact, with this surface's remedy in place of
    # `--verbatim`. A constant so the controller's run-start line and any future consumer
    # cannot drift from each other about what the run is doing.
    CL_REWRITE_NOTE = "the template's Content-Length disagrees with its own body and is " \
                      "being recomputed on every request — turn off ^O ▸ Advanced ▸ " \
                      "Auto Content-Length to send it as written"

    # Whether the run targets HTTP/2 — for Probe's synthetic RepeaterRecord (see
    # FuzzerController#probe_scan_fuzz_result), which needs to know the protocol
    # the same way RepeaterView#http2? already exposes it.
    def http2? : Bool
      @http2
    end

    def target_origin : String
      scheme, host, port = Repeater::FlowRequest.parse_target(Env.expand(@target))
      "#{scheme}://#{host}:#{port}"
    end

    private def build_source(s : SetSpec) : Fuzz::PayloadSource
      case s.kind
      when :list    then Fuzz::InlineList.new(s.value.split(','))
      when :file    then Fuzz::WordlistFile.new(s.value)
      when :preset  then Fuzz::PresetSource.new(s.value)
      when :null    then Fuzz::NullPayloads.new(s.value.to_i? || 1)
      when :numbers then build_numbers(s.value)
      when :brute   then build_brute(s.value)
      else               Fuzz::InlineList.new([s.value])
      end
    end

    private def build_numbers(value : String) : Fuzz::NumberRange
      range, _, step = value.partition(':')
      # Match two (possibly negative) integers, so a leading '-' on From isn't mistaken
      # for the from/to separator (partition('-') would split "-5-5" as "" / "5-5").
      m = range.match(/\A(-?\d+)-(-?\d+)\z/)
      from = (m.try(&.[1].to_i64?)) || 0_i64
      to = (m.try(&.[2].to_i64?)) || 0_i64
      Fuzz::NumberRange.new(from, to, step.to_i64? || 1_i64)
    end

    private def build_brute(value : String) : Fuzz::BruteForce
      charset, _, lens = value.rpartition(':')
      lo, _, hi = lens.partition('-')
      Fuzz::BruteForce.new(charset, lo.to_i? || 1, hi.to_i? || (lo.to_i? || 1))
    end

    # --- results pane navigation --------------------------------------------
    def results_move(d : Int32) : Nil
      view = sorted_results
      return if view.empty?
      @sel = (@sel + d).clamp(0, view.size - 1)
    end

    # The selected sorted-view row index (mouse dispatch: select-first, then open).
    def results_selected_index : Int32
      @sel
    end

    # Mouse: select a row without opening its detail (clamped to the live view).
    def select_result_row(idx : Int32) : Nil
      view = sorted_results
      return if view.empty?
      @sel = idx.clamp(0, view.size - 1)
    end

    def cycle_sort : String
      order = [:index, :status, :length, :words, :time]
      i = order.index(@sort) || 0
      @sort = order[(i + 1) % order.size]
      "sort: #{@sort}"
    end

    def toggle_matched_only : String
      @matched_only = !@matched_only
      @sel = 0
      @matched_only ? "showing matched only" : "showing all results"
    end

    def open_detail : Nil
      return if sorted_results.empty?
      @focus = :detail
      @detail_pane = :response
      @detail_read.reset
      decode_detail # parse the decoded-protocol panes for the row we're opening
    end

    def detail_cursor_at_top? : Bool
      @detail_read.at_top?
    end

    def detail_move(dr : Int32, dc : Int32, selecting : Bool = false) : Nil
      return unless detail_navigable?
      sync_detail_source
      @detail_read.move(dr, dc, selecting: selecting)
    end

    def detail_scroll_view(step : Int32) : Nil
      return unless detail_navigable?
      sync_detail_source
      @detail_read.scroll_view(step)
    end

    # Home / End / PgUp / PgDn, ⇧ extending — the shared `ReadPane` set. False when the key
    # was not one of them, so the controller can go on matching. This pane was the last
    # `ReadPane` consumer in the tree without it (`fuzzer` was the only tab controller with
    # neither this nor a `body_scroll`), which left those four keys dead here alone.
    def detail_motion_key(ev : Termisu::Event::Key) : Bool
      return false unless detail_navigable?
      sync_detail_source
      @detail_read.motion_key(ev)
    end

    def detail_plain_lines : Array(String)
      r = selected_result
      return [] of String unless r
      detail_lines(r)
    end

    def detail_copy_text : String
      sync_detail_source
      @detail_read.copy_text
    end

    def detail_copy_all_text : String
      detail_plain_lines.join("\n")
    end

    # Point the detail pane at the OPEN result's lines. Cheap and idempotent — `detail_lines`
    # is memoized on {pane, row} — so every gesture can call it and none can act on a pane
    # sourced from a row the list has since re-sorted away underneath it. That re-source is
    # also what keeps the old hand-rolled `cy` clamp honest: while a run streams, a live
    # re-sort can swap the fixed `@sel` onto a SHORTER result, and `ReadPane` clamps the caret
    # against the text it is pointed at.
    #
    # A stale cache hit cannot survive that swap, because the memo key holds `r.index` and
    # `Fuzz::Result#index` is the run's request ORDINAL — `Generator#emit` hands out `idx` once
    # per emitted job, so no two rows of one run share it. Indices DO restart at 0 on the next
    # run, and `begin_run` drops the cache for exactly that.
    private def sync_detail_source : Nil
      lines = detail_plain_lines
      prev = @detail_source_lines
      # IDENTITY, not equality: `detail_lines` hands back the very same Array while its
      # {pane, row} key holds, and `ReadPane#source` drops the wrap memo — so comparing by
      # value here would re-wrap the visible window on every keystroke over a body that can
      # reach multiple MiB, which is exactly what the memo exists to prevent.
      @detail_read.source(lines) unless prev && lines.same?(prev)
      @detail_source_lines = lines
    end

    # --- mouse over the RESULT detail ---------------------------------------
    # This pane paints a selection band, grows it on ⇧arrows and copies it with `y`, and the
    # POINTER was the one way in that did nothing at all: the controller's drag and
    # double-click arms both bailed unless the focused pane was the template, and its click arm
    # had no `:detail` branch, so a click focused the card and left the caret where it was.
    # Compare the History drill-in, which has had all four (chips, caret, drag, word) since it
    # grew a read cursor. The hit test itself is `ReadPane`'s now — it owns the wrap layout and
    # the gutter, and a second inverse here would drift from the caret the click lands on.

    # The card `render_bottom` hands `render_detail`, so every gesture inverts against exactly
    # the rect that was drawn. nil unless the detail is what is actually on screen there.
    private def detail_card_rect(rect : Rect) : Rect?
      return nil unless @focus == :detail
      _, _, bottom = stack_rects(rect)
      bottom.h > 0 ? bottom : nil
    end

    # The detail card's interior, or nil when there is nothing to hit-test. The gutter width is
    # no longer computed here: `ReadPane` derives it from the size it was sourced with, and two
    # derivations of it would be two answers about where the text column starts.
    private def detail_hit_geometry(rect : Rect) : Rect?
      return nil unless detail_navigable?
      card = detail_card_rect(rect)
      return nil unless card
      sync_detail_source
      return nil if @detail_read.empty?
      inner = card.inset(1, 1)
      inner.empty? ? nil : inner
    end

    def detail_click_to_cursor(rect : Rect, mx : Int32, my : Int32, selecting : Bool = false) : Nil
      inner = detail_hit_geometry(rect) || return
      @detail_read.click(inner, mx, my, selecting)
    end

    def detail_select_word(rect : Rect, mx : Int32, my : Int32) : Bool
      inner = detail_hit_geometry(rect) || return false
      @detail_read.select_word(inner, mx, my)
    end

    # The pane chip under (mx, my) on the detail card's TOP BORDER, or nil. Inverts
    # `render_detail_chips` — same start column, same `" label "` padding, same +1 gap, same
    # right-edge break — so the strip the card draws is the strip a click can reach. The
    # History detail's chips have been clickable via `detail_pane_at`; these were drawn only.
    def detail_chip_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      card = detail_card_rect(rect)
      return nil unless card && my == card.y
      x = card.x + 14
      detail_panes.each do |pane|
        label = " #{detail_pane_label(pane)} "
        break if x + label.size >= card.right - 1
        return pane if mx >= x && mx < x + label.size
        x += label.size + 1
      end
      nil
    end

    # Show `pane` in the detail card (a chip click), no-op for a pane this result has no
    # section for. Routes through `detail_step_pane`'s reset so the scroll, the h-scroll, the
    # caret and both line caches are dropped together, exactly as ←/→ does. Named `show_` not
    # `set_`: it is a navigation action with side effects, not a writer for `@detail_pane`.
    #
    # The already-showing case has to bail BEFORE that, because a zero delta is not a no-op in
    # `detail_step_pane` — its range guard passes, it re-assigns the same pane and runs the whole
    # reset. Clicking the chip you are already on would then silently throw away your scroll
    # position and your selection, which is the opposite of what re-clicking a tab means.
    def show_detail_pane(pane : Symbol) : Nil
      return if pane == @detail_pane
      panes = detail_panes
      i = panes.index(pane)
      return unless i
      detail_step_pane(i - (panes.index(@detail_pane) || 0))
    end

    # ←/→ in the RESULT detail: step through the pane chain (request → response →
    # whichever decoded-protocol panes the row carries), clamped — no wrap, so ← past
    # the first / → past the last is a no-op (esc leaves the detail).
    def detail_step_pane(dir : Int32) : Nil
      panes = detail_panes
      i = (panes.index(@detail_pane) || 0) + dir
      return if i < 0 || i >= panes.size
      @detail_pane = panes[i]
      @detail_read.reset
      @detail_source_lines = nil
      @detail_lines_cache = nil
      @detail_lines_key = nil
      @detail_styled_cache = nil
      @detail_styled_key = nil
    end

    # Parse the OPEN result's request/response into the optional protocol panes
    # (SAML/JWT/GraphQL/PARAMS), mirroring the History detail decode strip. The selected
    # row is fixed while the detail is open, so this runs once per open (@decoded_index).
    private def decode_detail : Nil
      r = selected_result
      unless r
        clear_detail_decode
        return
      end
      return if @decoded_index == r.index # already decoded this row
      @decoded_index = r.index
      req = result_request_bytes(r)
      off, sep_w = req_head_end(req)
      req_head = off ? req[0, off] : req
      req_body = off ? req[(off + sep_w)..] : Bytes.empty
      tgt = request_target(req_head)
      @d_saml = Saml.from_flow(tgt, req_head, req_body, r.head, r.body)
      @d_jwts = Jwt.from_flow(tgt, req_head, req_body, r.head, r.body)
      @d_graphql = Graphql.from_flow(tgt, req_head, req_body)
      @d_form = FormData.from_flow(tgt, req_head, req_body)
    end

    private def clear_detail_decode : Nil
      @decoded_index = nil
      @d_saml = nil
      @d_jwts = [] of Jwt::Found
      @d_graphql = nil
      @d_form = nil
    end

    # Locate the head/body separator = the first blank line (LFLF or CRLFCRLF) in the
    # reconstructed request, mirroring Fuzz::ContentLength's left-to-right scan (the
    # template holds LF-joined text, so it's usually LFLF). Returns {offset, sep-width};
    # {nil, 0} when the request carries no body. Byte-level so a UTF-8 body can't skew it.
    private def req_head_end(bytes : Bytes) : {Int32?, Int32}
      i = 0
      while i + 1 < bytes.size
        return {i, 2} if bytes[i] == 0x0A_u8 && bytes[i + 1] == 0x0A_u8
        if i + 3 < bytes.size && bytes[i] == 0x0D_u8 && bytes[i + 1] == 0x0A_u8 &&
           bytes[i + 2] == 0x0D_u8 && bytes[i + 3] == 0x0A_u8
          return {i, 4}
        end
        i += 1
      end
      {nil, 0}
    end

    # The request-target (path?query) from the reconstructed request line — the decoders
    # read the GET-binding query from here (SAML Redirect, GraphQL GET), the same value
    # History passes as the flow's stored target.
    private def request_target(head : Bytes) : String
      line = String.new(head).each_line.first?.try(&.strip) || ""
      line.split(' ')[1]? || "/"
    end

    def selected_result : Fuzz::Result?
      sorted_results[@sel]?
    end

    # How often the sorted view may be rebuilt WHILE A RUN IS STREAMING. See `sorted_results`.
    SORT_REFRESH = 250.milliseconds

    # The memo keys on @results_rev, which bumps on EVERY appended result, so during a live
    # run it never hit and the rebuild below ran once per frame. Measured at RESULT_CAP (5000
    # rows): sort_by(:status) 615µs / 2.54MB per call, sort_by(:length) 378µs / 2.54MB,
    # matched-only select 49µs / 502kB — against a whole results-pane frame of ~239µs
    # (bench/fuzz_view_frame_bench.cr). At 20 fps that is ~50 MB/s of garbage, and the
    # allocation is the part that matters (AGENTS.md: allocation-shaped wins are real, CPU
    # micro-optimisations usually are not).
    #
    # Throttled rather than maintained incrementally: results also RING-EVICT at RESULT_CAP,
    # so keeping a sorted array correct means three mutation sites staying in sync — the same
    # trade the matched_count note above declined. A sorted list of a streaming run
    # re-ordering 20 times a second is unreadable anyway; four times is plenty.
    #
    # The throttle applies only when the view COPIES. With the default `:index` and no
    # matched-only filter `rows` IS @results, so the cached array is the live one, new rows
    # appear with no rebuild at all, and there is nothing to go stale. A shape change (the
    # operator cycling the sort) misses the key outright and rebuilds on the next frame.
    private def reusable_sorted_cache : Array(Fuzz::Result)?
      c = @sorted_cache
      return nil unless c && @sorted_cache_sort == @sort && @sorted_cache_matched == @matched_only
      return c if @sorted_cache_rev == @results_rev
      return c if @running && copies_results? && Time.instant - @sorted_cache_at < SORT_REFRESH
      nil
    end

    private def sorted_results : Array(Fuzz::Result)
      if cached = reusable_sorted_cache
        return cached
      end
      rows = @matched_only ? @results.select(&.matched?) : @results
      sorted =
        case @sort
        when :status then rows.sort_by { |r| r.status || -1 }
        when :length then rows.sort_by(&.length)
        when :words  then rows.sort_by(&.words)
        when :time   then rows.sort_by(&.duration_us)
        else              rows # :index — the live @results order (uncopied; read-only here)
        end
      @sorted_cache = sorted
      @sorted_cache_rev = @results_rev
      @sorted_cache_sort = @sort
      @sorted_cache_matched = @matched_only
      @sorted_cache_at = Time.instant
      sorted
    end

    # Does the current view shape COPY @results, or hand it back as-is? `:index` with no
    # matched-only filter is the identity, and an identity needs neither a rebuild nor a
    # throttle — this is what keeps the default view perfectly live.
    private def copies_results? : Bool
      @sort != :index || @matched_only
    end

    # --- target editing ------------------------------------------------------
    # The TARGET card holds two single-line fields — the URL and the TLS SNI override —
    # selected by @target_field (^S toggles), exactly as RepeaterView's does. The mutators
    # below self-route, so the controller's key handling is the same for both rows.
    #
    # The knob was already whole here: `@sni` is persisted with the session, restored,
    # compared by the reconcile, cloned by Duplicate and handed to `build_engine`. Only the
    # AFFORDANCE was missing, so a fuzz session seeded from History (⇧I) could never present
    # anything but the dialed IP — an https vhost sweep is exactly the run that needs one,
    # and the sole working route was to open the request in the Repeater, set SNI there, and
    # hand it back with `space ▸ Send to Fuzzer`.
    def editing_sni? : Bool
      @target_field == :sni
    end

    def toggle_sni_field : Nil
      if @target_field == :sni
        @target_field = :url
      else
        @target_field = :sni
        @scx = @sni.size
        @target_mode = InputMode::Insert
      end
    end

    # Drop back to URL editing (↵/↑/esc in the SNI field) without changing the value.
    def exit_sni_field : Nil
      @target_field = :url
    end

    def target_insert(ch : Char) : Nil
      if @target_field == :sni
        @sni = "#{@sni[0, @scx]}#{ch}#{@sni[@scx..]}"
        @scx += 1
      else
        @target = "#{@target[0, @tcx]}#{ch}#{@target[@tcx..]}"
        @tcx += 1
      end
      @dirty = true
    end

    def target_backspace : Nil
      if @target_field == :sni
        return if @scx == 0
        @sni = "#{@sni[0, @scx - 1]}#{@sni[@scx..]}"
        @scx -= 1
      else
        return if @tcx == 0
        @target = "#{@target[0, @tcx - 1]}#{@target[@tcx..]}"
        @tcx -= 1
      end
      @dirty = true
    end

    def target_move(d : Int32) : Nil
      if @target_field == :sni
        @scx = (@scx + d).clamp(0, @sni.size)
      else
        @tcx = (@tcx + d).clamp(0, @target.size)
      end
    end

    # Home/End on the target/SNI row, ⇧ EXTENDING — the Repeater twin of these carries the
    # reasoning: assigning the caret directly DROPPED the selection ⇧Home/⇧End was asking to
    # grow, because the anchor lives in `@target_read` and a bare assignment never reaches it.
    # A bare press still clears the anchor, which is what the INSERT-mode callers rely on.
    def target_home(selecting : Bool = false) : Nil
      if @target_field == :sni
        @scx = @target_read.move_cx(@scx, -@scx, @sni.size, selecting: selecting)
      else
        @tcx = @target_read.move_cx(@tcx, -@tcx, @target.size, selecting: selecting)
      end
    end

    def target_end(selecting : Bool = false) : Nil
      if @target_field == :sni
        @scx = @target_read.move_cx(@scx, @sni.size - @scx, @sni.size, selecting: selecting)
      else
        @tcx = @target_read.move_cx(@tcx, @target.size - @tcx, @target.size, selecting: selecting)
      end
    end

    def target_read_move(dc : Int32, selecting : Bool = false) : Nil
      return if target_insert?
      if @target_field == :sni
        @scx = @target_read.move_cx(@scx, dc, @sni.size, selecting: selecting)
      else
        @tcx = @target_read.move_cx(@tcx, dc, @target.size, selecting: selecting)
      end
    end

    def target_copy_text : String
      @target_field == :sni ? @target_read.copy_text(@sni, @scx) : @target_read.copy_text(@target, @tcx)
    end

    # --- template editing ----------------------------------------------------
    # Characters the last `template_insert` replaced — see TextArea#last_replaced.
    def template_last_replaced : Int32
      @editor.last_replaced
    end

    def template_insert(ch : Char) : Nil
      # Marker-in-marker guard: a §/¦ typed inside (or flush against) a closed marker is
      # auto-escaped to a §§/¦¦ literal so the structure survives (Template.insert_breaks_marker?).
      if Fuzz::Template.insert_breaks_marker?(@editor.text, @editor.cursor_offset, ch, marker_spans)
        @editor.insert_pair(ch)
      else
        @editor.insert(ch)
      end
      @editor.set_preedit("")
      @dirty = true
    end

    # --- marker structure guards (delimiter delete / nesting) --------------------
    # When a backspace here would delete a §/¦ that structures a closed marker, the {a, b}
    # span of that marker (fed to the strip-confirm) — else nil.
    def marker_break_on_backspace : {Int32, Int32}?
      Fuzz::Template.structural_marker_at(@editor.text, @editor.cursor_offset - 1, marker_spans)
    end

    # Same, for a forward-delete (the char UNDER the caret).
    def marker_break_on_delete : {Int32, Int32}?
      Fuzz::Template.structural_marker_at(@editor.text, @editor.cursor_offset, marker_spans)
    end

    # 1-based ordinal of the closed marker at `span` — for the confirm copy ("marker §N").
    def marker_ordinal(span : {Int32, Int32}) : Int32
      (marker_spans.index(span) || 0) + 1
    end

    # Confirmed strip: drop the whole marker at `span`, keeping only its raw value; caret to
    # the freed value's end. One undoable edit, so prior edits stay undoable. Dirties the tab.
    def strip_marker_span(span : {Int32, Int32}) : Nil
      new_text, caret = Fuzz::Template.strip_marker(@editor.text, span)
      # `caret` is an offset into the LF projection, which is what `replace_all` →
      # `place_at_offset` walks (@lines is CR-free), so restoring the terminators is caret-safe.
      @editor.replace_all(restore_wire_eols(new_text), caret)
      @dirty = true
    end

    def template_newline : Nil
      @editor.insert_newline
      @dirty = true
    end

    # Splice a whole bracketed paste in as ONE edit instead of N keystrokes — the Repeater's
    # `edit_paste`, same refusal and same reason (a pasted `§`/`¦` needs the per-character
    # marker guard, so it goes back to the keystroke path; the Runner replays it).
    def template_paste(text : String) : Bool
      return false unless template_text_editing?
      return false if text.includes?(Fuzz::Template::MARKER) || text.includes?(Fuzz::Template::CHAIN_SEP)
      @editor.insert_text(text)
      @dirty = true
      true
    end

    def template_backspace : Nil
      before = @editor.edits
      @editor.backspace
      @dirty = true if @editor.edits != before # no-op at buffer start — don't dirty the tab
    end

    # ⌃Z in the TEMPLATE editor. The Repeater's request pane has had this since it grew an
    # editor and the Fuzzer's — the same `TextArea`, holding the same captured request — did
    # not, so an accidental keystroke over a seeded template was permanent. Gated on a real
    # edit for the reason `RepeaterView#edit_undo` spells out: an empty undo stack must not
    # mark a tab dirty (which here would re-persist a template nobody changed).
    def template_undo : Nil
      before = @editor.edits
      @editor.undo
      @dirty = true if @editor.edits != before
    end

    # `selecting` is the Shift half of ⇧←/→/↑/↓ — it extends the INSERT-mode selection from
    # its anchor instead of collapsing it. `TextArea#move` implements both ends (the band, the
    # ⌫/Del that removes a selection, replace-on-type); this pane only had the plain motion,
    # so ⇧arrows moved the caret and quietly selected nothing while the READ pane's footer
    # advertised "⇧arrows select" one keypress away.
    def template_move(dr : Int32, dc : Int32, selecting : Bool = false) : Nil
      @editor.move(dr, dc, selecting: selecting)
    end

    # Whether the TEMPLATE editor holds a non-empty INSERT-mode selection (the READ pane's
    # selection is `@template_read`'s — see `pane_selection?`).
    def template_insert_selection? : Bool
      @editor.selection?
    end

    # Home/End: caret to line start/end — pure navigation, no dirty. `selecting` is the Shift
    # half (extends instead of collapsing), like the arrows.
    #
    # These move the EDITOR's caret directly, so READ mode has to adopt the result — the anchor
    # rules live in `@template_read`, and `paint_template_read_chrome`'s per-frame `sync_from`
    # copies cy/cx while leaving the anchor alone. Without `sync_to`: a plain Home left the anchor
    # where it was and painted a band from there to column 0, over a selection the operator had
    # just collapsed — and `y` then copied "" because the band's two ends had crossed. ⇧Home/⇧End
    # planted no anchor at all and extended nothing. `sync_to` is the helper written for exactly
    # this pair; Notes, Issues, Project and the Decoder input all already call it.
    def template_home(selecting : Bool = false) : Nil
      @editor.home(selecting)
      @template_read.sync_to(@editor, selecting: selecting) unless template_insert?
    end

    def template_end(selecting : Bool = false) : Nil
      @editor.end_of_line(selecting)
      @template_read.sync_to(@editor, selecting: selecting) unless template_insert?
    end

    # ⌃/⌥ + Home/End — the buffer's start/end rather than the line's.
    def template_buffer_start(selecting : Bool = false) : Nil
      @editor.to_buffer_start(selecting)
    end

    def template_buffer_end(selecting : Bool = false) : Nil
      @editor.to_buffer_end(selecting)
    end

    # PageUp / PageDown, sized from the editor's own last rendered height.
    def template_page(dir : Int32, selecting : Bool = false) : Nil
      @editor.page(dir * @editor.page_rows, selecting: selecting)
    end

    # THE shared editor keymap over the template — see `TextArea#handle_motion_key`. Dirties
    # only on a real buffer change (⌥⌫ is the one mutation in the set).
    def template_motion_key(ev : Termisu::Event::Key) : Bool
      before = @editor.edits
      return false unless @editor.handle_motion_key(ev)
      @dirty = true if @editor.edits != before
      true
    end

    # ⌃/⌥ + ←/→ — one word instead of one character. Pure motion.
    def template_word_move(dir : Int32, selecting : Bool = false) : Nil
      dir < 0 ? @editor.word_left(selecting) : @editor.word_right(selecting)
    end

    # ⌥⌫ — delete back to the previous word boundary as one undo step.
    def template_delete_word : Nil
      before = @editor.edits
      @editor.delete_word_left
      @dirty = true if @editor.edits != before
    end

    # Forward-delete the char under the caret — a content edit.
    def template_delete : Nil
      @editor.delete
      @dirty = true
    end

    def template_read_move(dr : Int32, dc : Int32, selecting : Bool = false) : Nil
      return if template_insert? || chain_pane_active?
      @template_read.move(@editor, dr, dc, selecting: selecting)
    end

    # PageUp / PageDown with the pane in READ mode — a screenful of the editor that draws it.
    def template_read_page(dir : Int32, selecting : Bool = false) : Nil
      template_read_move(dir * @editor.page_rows, 0, selecting: selecting)
    end

    # `chain_pane_active?` still bails — the ^Q chain sub-pane owns the wheel while it is up,
    # so scrolling the template underneath it would move a pane the operator is not in.
    # `template_insert?` does NOT, and that was the defect: the guard read the MODE, not the
    # pane, so the wheel died the moment `i` was pressed. Same reasoning as
    # `RepeaterController#handle_wheel`'s dropped `unless v.request_insert?` — INS is the same
    # pane showing the same bytes, and `scroll_view` pulls the caret into the new window so the
    # next keystroke lands where the operator is looking.
    def template_scroll_view(step : Int32) : Nil
      return if chain_pane_active?
      @editor.scroll_view(step)
    end

    # One selection model per mode — see RepeaterView#request_copy_text, which this mirrors.
    # Changes together with `pane_selection?`'s :template arm.
    def template_copy_text : String
      if pane_insert?(:template)
        @editor.selection_text || @template_read.copy_text(@editor)
      else
        @template_read.copy_text(@editor)
      end
    end

    def template_copy_all_text : String
      @template_read.copy_all(@editor)
    end

    def pane_copy_text : String
      case @focus
      when :template then template_copy_text
      when :target   then target_copy_text
      when :detail   then detail_copy_text
      else                ""
      end
    end

    def pane_copy_all_text : String
      case @focus
      when :template then template_copy_all_text
      when :target   then @target
      when :detail   then detail_copy_all_text
      else                ""
      end
    end

    def pane_selection? : Bool
      case @focus
      # INS has its own selection model (the editor's `@sel_anchor`); reporting only the READ
      # side made a visible ⇧arrow band uncopyable — see RepeaterView#pane_selection?.
      when :template then pane_insert?(:template) ? @editor.selection? : @template_read.selection?
      when :target   then !pane_insert?(:target) && @target_read.selection?
      when :detail   then detail_navigable? && @detail_read.selection?
      else                false
      end
    end

    def pane_select_line : Nil
      case @focus
      when :template
        return if pane_insert?(:template)
        @template_read.select_line(@editor)
      when :target
        return if pane_insert?(:target)
        @tcx = @target_read.select_line(@target.size)
      when :detail
        return unless detail_navigable?
        sync_detail_source
        @detail_read.select_line
      end
    end

    def pane_clear_selection : Nil
      case @focus
      when :template then @template_read.clear_selection
      when :target   then @target_read.clear_selection
      when :detail   then @detail_read.clear_selection
      end
    end

    # --- config serialization ------------------------------------------------
    def config_json : String
      commit_buffers # fold edited buffers into @config/@matcher before serializing
      JSON.build do |j|
        j.object do
          j.field "mode", @config.mode.to_s
          j.field "http2", @http2
          j.field "sni", @sni
          j.field "concurrency", @config.concurrency
          j.field "rps", @config.rps
          j.field "throttle_ms", @config.throttle_ms
          j.field "timeout_s", @config.timeout.try(&.total_seconds.to_i)
          j.field "retries", @config.retries
          j.field "max_requests", @config.max_requests
          j.field "follow", @config.follow_redirects?
          j.field "calibrate", @config.auto_calibrate?
          j.field "keep_alive", @config.keep_alive?
          j.field "update_cl", @config.update_content_length?
          j.field("sets") { j.array { @sets.each { |s| j.object { j.field "kind", s.kind.to_s; j.field "value", s.value } } } }
          j.field "match_status", @matcher.match_status
          j.field "filter_status", @matcher.filter_status
          j.field "match_size", @matcher.match_size
          j.field "filter_size", @matcher.filter_size
          j.field "match_words", @matcher.match_words
          j.field "filter_words", @matcher.filter_words
          j.field "match_regex", @matcher.match_regex.try(&.source)
          j.field "filter_regex", @matcher.filter_regex.try(&.source)
          j.field "extract", @matcher.extract.try(&.source)
        end
      end
    end

    private def apply_config_json(raw : String) : Nil
      return if raw.strip.empty?
      obj = JSON.parse(raw).as_h? || return
      obj["mode"]?.try(&.as_s?).try { |m| Fuzz::Mode.parse?(m).try { |mode| @config.mode = mode } }
      @http2 = obj["http2"]?.try(&.as_bool?) || @http2
      @sni = obj["sni"]?.try(&.as_s?) || @sni
      obj["concurrency"]?.try(&.as_i?).try { |n| @config.concurrency = n }
      @config.rps = obj["rps"]?.try(&.as_f?)
      @config.throttle_ms = obj["throttle_ms"]?.try(&.as_i?)
      obj["timeout_s"]?.try(&.as_i?).try { |s| @config.timeout = s.seconds }
      obj["retries"]?.try(&.as_i?).try { |n| @config.retries = n }
      @config.max_requests = obj["max_requests"]?.try(&.as_i64?)
      @config.follow_redirects = obj["follow"]?.try(&.as_bool?) || false
      @config.auto_calibrate = obj["calibrate"]?.try(&.as_bool?) || false
      # A session persisted before this key existed reads as nil ⇒ keep the ctor default
      # (on). `|| false` here would silently turn keep-alive off for every saved tab.
      @config.keep_alive = obj["keep_alive"]?.try(&.as_bool?) != false
      # Same nil-means-default reading as keep_alive above: a session saved before this
      # key existed must keep the ctor default (on), not silently start sending desyncs.
      @config.update_content_length = obj["update_cl"]?.try(&.as_bool?) != false
      apply_sets_json(obj["sets"]?)
      @matcher.match_status = obj["match_status"]?.try(&.as_s?)
      @matcher.filter_status = obj["filter_status"]?.try(&.as_s?)
      @matcher.match_size = obj["match_size"]?.try(&.as_s?)
      @matcher.filter_size = obj["filter_size"]?.try(&.as_s?)
      @matcher.match_words = obj["match_words"]?.try(&.as_s?)
      @matcher.filter_words = obj["filter_words"]?.try(&.as_s?)
      @matcher.match_regex = obj["match_regex"]?.try(&.as_s?).try { |s| Regex.new(s) rescue nil }
      @matcher.filter_regex = obj["filter_regex"]?.try(&.as_s?).try { |s| Regex.new(s) rescue nil }
      @matcher.extract = obj["extract"]?.try(&.as_s?).try { |s| Regex.new(s) rescue nil }
      sync_buffers # mirror the restored config/matcher into the editable buffers
    rescue
      # tolerate a malformed/older config blob — keep defaults
    end

    private def apply_sets_json(arr : JSON::Any?) : Nil
      arr.try(&.as_a?).try do |sets|
        @sets = sets.compact_map do |sp|
          h = sp.as_h?
          kind = parse_set_kind(h.try(&.["kind"]?).try(&.as_s?))
          v = h.try(&.["value"]?).try(&.as_s?) || ""
          kind ? SetSpec.new(kind, v) : nil
        end
      end
    end

    private def parse_set_kind(k : String?) : Symbol?
      case k
      when "list"    then :list
      when "file"    then :file
      when "preset"  then :preset
      when "numbers" then :numbers
      when "null"    then :null
      when "brute"   then :brute
      end
    end

    # --- rendering -----------------------------------------------------------
    def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      unless @loaded
        TrafficEmptyState.render(screen, rect, variant: :fuzzer, title: "no request loaded")
        return
      end
      target, top, bottom = stack_rects(rect)
      render_target(screen, target, focused && @focus == :target)
      return if top.h <= 0
      render_top(screen, top, focused)
      render_bottom(screen, bottom, focused) if bottom.h > 0
      render_chain_overlay(screen, rect) if @chain_focused # centered ^Q modal ON TOP (replaces the old split)
    end

    # The body's three horizontal bands — TARGET, the template/config row, and the
    # results-or-detail row — in one place because `render`, `pane_at` and the detail
    # hit-tests all need them and each used to re-derive `target_h` / `top_h` by hand. A
    # `top.h` of 0 means the body is too short for anything under TARGET (render bails, the
    # hit-tests answer nil), which is the `rest.h <= 0` guard those copies carried.
    private def stack_rects(rect : Rect) : {Rect, Rect, Rect}
      target_h = {rect.h, target_card_h}.min
      target = Rect.new(rect.x, rect.y, rect.w, target_h)
      rest_h = {rect.h - target_h, 0}.max
      empty = Rect.new(rect.x, rect.y + target_h, rect.w, 0)
      return {target, empty, empty} if rest_h <= 0
      rest_y = rect.y + target_h
      top_h = {rest_h * 45 // 100, 5}.max
      top_h = rest_h if rest_h < 6
      {target,
       Rect.new(rect.x, rest_y, rect.w, top_h),
       Rect.new(rect.x, rest_y + top_h, rect.w, {rest_h - top_h, 0}.max)}
    end

    private def render_top(screen : Screen, rect : Rect, focused : Bool) : Nil
      half = {(rect.w - 1) // 2, 1}.max
      left = Rect.new(rect.x, rect.y, half, rect.h)
      right = Rect.new(rect.x + half + 1, rect.y, {rect.w - half - 1, 0}.max, rect.h)
      tmpl_focused = focused && @focus == :template
      render_template(screen, left, tmpl_focused && !@chain_focused) # dimmed while the ^Q modal owns focus
      render_config(screen, right, focused && @focus == :config)
    end

    # The ^Q chain editor modal over the whole tab, bound to the marker the cursor sat in
    # when ^Q was pressed. Shows the value, the editable chain, and a live transform
    # preview. Keys route here via the controller (chain_pane_active?).
    private def render_chain_overlay(screen : Screen, area : Rect) : Nil
      value = Fuzz::Template.value_at(@editor.text, @chain_marker_cursor) || ""
      ChainOverlay.render(screen, area, "CHAIN · #{marker_label}", value, @chain_pane)
    end

    private def render_bottom(screen : Screen, rect : Rect, focused : Bool) : Nil
      if @focus == :detail
        render_detail(screen, rect, focused) # full width — detail is unchanged
        return
      end
      vw = @show_dist ? dist_width(rect.w) : 0
      if vw <= 0
        render_results(screen, rect, focused && @focus == :results) # graceful: full width
      else
        rw = rect.w - vw - 1 # results width minus the 1-col gap (mirrors render_top)
        render_results(screen, Rect.new(rect.x, rect.y, rw, rect.h), focused && @focus == :results)
        render_dist(screen, Rect.new(rect.x + rw + 1, rect.y, vw, rect.h)) # read-only sidebar
      end
    end

    # Sidebar width for a bottom rect `w` cols wide, or 0 (no sidebar) when too narrow.
    private def dist_width(w : Int32) : Int32
      return 0 if w < DIST_MIN_TOTAL
      vw = {w * 30 // 100, DIST_MAX_VW}.min
      vw < DIST_MIN_VW ? 0 : vw
    end

    def toggle_dist : String
      @show_dist = !@show_dist
      @show_dist ? "distribution shown" : "distribution hidden"
    end

    # The TARGET card grows to a second content row (4 high vs 3) whenever an SNI override is
    # set OR is being edited, so the override is always visible and the input row only
    # appears once you reach for it (^S). Same rule and same numbers as RepeaterView.
    private def sni_active? : Bool
      !@sni.strip.empty? || (editing_sni? && @focus == :target)
    end

    private def target_card_h : Int32
      sni_active? ? 4 : 3
    end

    # The TARGET card row prefixes (marker + the field value 1 col to its right). Constants
    # so render_target and the click→caret mapping agree on the value base.
    TARGET_PREFIX = "›"
    SNI_PREFIX    = "SNI ›"
    SNI_BADGE     = " SNI "

    private def field_base(rect : Rect, prefix : String) : Int32
      rect.x + 2 + prefix.size + 1
    end

    private def render_target(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.h < 2
      ins = focused && target_insert?
      Frame.card(screen, rect, "TARGET", bg: Theme.bg, border: Frame.pane_border(focused))
      # The REAL mode, not `ins` — `target_chrome_hit` measures the bare `target_insert?`, and the
      # two labels are different widths. See `Frame.mode_badge`.
      Frame.mode_badge(screen, rect.right - 1, rect.y, rect.x + 8, target_insert?)
      # An at-a-glance SNI marker on the top border, CHAINED left of the mode chip rather
      # than placed at `rect.right - size - 1` — which is inside the mode chip's own cells.
      # Setting an override used to paint over the right of ` ↵:READ `, leaving `↵: SNI ` on
      # the border, and `target_chrome_hit` still measured the full mode rect underneath, so
      # clicking the visible SNI letters toggled insert. Repeater hit this first and fixed it
      # the same way (`repeater_view.cr#target_chrome_chain`); this is that fix, ported.
      if sni_x = target_sni_x(rect)
        screen.text(sni_x, rect.y, SNI_BADGE, Theme.text_bright, Theme.accent_bg)
      end
      draw_target_row(screen, rect, rect.y + 1, TARGET_PREFIX, @target, @tcx,
        focused && @target_field == :url, ins)
      if sni_active? && rect.h >= 4
        draw_target_row(screen, rect, rect.y + 2, SNI_PREFIX, @sni, @scx,
          focused && @target_field == :sni, ins)
      end
    end

    # One single-line field row of the TARGET card: a marker prefix, then the value, with the
    # block caret + terminal cursor when this row is the active field. Mirrors
    # RepeaterView#draw_target_row, including the `Screen.draw_width` caret measure that
    # `target_click_to_cursor`'s `Screen.column_for` inverts and that `paint_char_span_bg`
    # uses for the selection tint — the three-way agreement `display_width` broke on a value
    # holding a zero-width char.
    private def draw_target_row(screen : Screen, rect : Rect, row : Int32, prefix : String, value : String,
                                cx : Int32, active : Bool, insert : Bool) : Nil
      screen.text(rect.x + 2, row, prefix, active ? Theme.accent : Theme.muted)
      base = field_base(rect, prefix)
      w = {rect.right - base - 1, 1}.max
      Highlight.draw(screen, base, row, Highlight.env_line(value, Theme.text_bright), width: w)
      # AFTER the value and before the caret — see `RepeaterView#draw_target_row`, whose note
      # carries the reasoning: `Highlight.draw` writes its own `bg` over every cell, so a band
      # painted first was erased on the same frame and this row's ⇧←/→ selection was invisible.
      if active && !insert
        if span = @target_read.selection_span(cx)
          paint_char_span_bg(screen, base, row, value, span[0], span[1], Theme.accent_bg)
        end
      end
      if active
        cursor_x = base + Screen.draw_width(value[0, cx])
        if cursor_x < rect.right - 1
          ch = cx < value.size ? value[cx] : ' '
          screen.cell(cursor_x, row, ch, Theme.bg, insert ? Theme.accent : Theme.accent_bg)
          screen.cursor(cursor_x, row)
        end
      end
    end

    private def render_template(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      spans = marker_spans
      pc = spans.size
      label = @http2 ? "TEMPLATE (h2)" : "TEMPLATE"
      ins = focused && (template_insert? || @chain_focused)
      Frame.card(screen, rect, label, bg: Theme.bg, border: Frame.pane_border(focused))
      badge = " §#{pc} "
      min_x = rect.x + label.size + 4
      # ^R:RUN rides the TEMPLATE border as the primary action — rightmost, mirroring the
      # Repeater's ^R:SEND so the muscle memory transfers. A gold button while idle, recessed
      # while a run streams (^X stops it). The old CONFIG "Run" row is gone; the request-count
      # estimate stays there as a passive summary (render_run_summary).
      run_x = Frame.action_badge(screen, rect.right - 1, rect.y, min_x, "^R", "RUN", !running?)
      pretty_x = Frame.toggle_badge(screen, run_x, rect.y, min_x, "^U", "PRETTY", false)
      # The mode chip states the pane's REAL mode, not `focused && …`: `template_chrome_hit` and
      # `apply_chrome_click` both read `template_insert?` alone, so gating the LABEL on focus made
      # an unfocused pane that had retained INS draw " ↵:READ " (8 cols) over a 5-col " INS " hit
      # rect — dead cells on the left of the chip — and a click on a chip reading "↵:READ" then
      # EXITED insert mode. Focus is still carried, by the border colour below.
      mode_x = Frame.mode_badge(screen, pretty_x, rect.y, min_x, template_insert? || @chain_focused)
      # …and `§N` chains off the mode chip's left edge. It used to be drawn at `pretty_x - 4`,
      # which is INSIDE the mode badge — so it overwrote the label's tail and the border read
      # "↵: §2", destroying the mode chip and leaving the marker count ambiguous. Every other
      # badge on every other pane chains off its neighbour's returned left x; this one did not.
      badge_x = mode_x - badge.size
      screen.text(badge_x, rect.y, badge,
        pc > 0 ? Theme.text_bright : Theme.muted, pc > 0 ? Theme.accent_bg : Theme.bg) if badge_x >= min_x
      # Marker i ↔ position i ↔ generator.set_for(i). The value gets the position hue; a
      # trailing ¦chain (Decoder transform-on-send) is over-painted with a neutral band so
      # it reads as metadata, not payload. Colours resolved fresh each frame (offsets are
      # colour-free); marker_regions is 1:1 with `spans`, so the config chips stay in sync.
      bg = [] of {Int32, Int32, Color}
      conceal = [] of {Int32, Int32}
      marker_regions.each_with_index do |region, i|
        a, sep, close = region
        bg << {a, close + 1, Theme.marker_bg(i)} # band spans the whole marker; the conceal-aware paint skips hidden cells
        conceal << {sep, close} if sep < close   # hide the ¦chain inline (kept in the buffer → tooltip + ^Q overlay)
      end
      @editor.bg_regions = bg
      @editor.conceal_spans = conceal
      # A marker WITHOUT a chain gets the tooltip too (`""` → "no chain yet · ^Q edit · ^O
      # sets"). That is the state a freshly auto-marked template is in for every one of its
      # positions, i.e. the one an operator meets first and the one that used to say nothing.
      # nil (caret outside every marker) still draws nothing.
      @editor.chain_peek_text = chain_under_cursor
      inner = rect.inset(1, 1)
      read_active = focused && !ins
      @editor.render(screen, inner, cursor: ins, highlight: :request, peek: focused, gauge: true, gauge_focused: focused)
      paint_template_read_chrome(screen, inner, read_active)
    end

    # READ-mode over-paint (selection band + block caret) on top of the frame the editor drew.
    #
    # Band and caret both go through the EDITOR, which owns the concealed-run map. This pane is
    # THE place operators write `§value¦chain§`, and the `¦chain` is concealed here — so measuring
    # a span on the raw line put the tint and the caret N columns right of the text they addressed
    # (N = the hidden width to their left), and re-drawing the raw segment for the band put the
    # hidden chain back on screen: selecting a line UNCONCEALED it and shifted the rest of the row.
    # The copy was right all along (it reads buffer coordinates), so the band highlighted different
    # bytes than `y` copied. See the READ-mode over-paint seam in `text_area.cr`.
    #
    # The shared over-paint — `TextReadState#paint_chrome`, which inverts the row list the
    # editor actually drew instead of the `li - scroll` sum this method used to carry. That sum
    # stopped being the screen row the moment this pane started soft-wrapping.
    private def paint_template_read_chrome(screen : Screen, rect : Rect, active : Bool) : Nil
      @template_read.paint_chrome(screen, rect, @editor, active)
    end

    private def paint_char_span_bg(screen : Screen, x : Int32, y : Int32, line : String,
                                   x0 : Int32, x1 : Int32, bg : Color) : Nil
      return if x0 >= x1
      # Cluster-wise, matching the base draw and the caret. Summing draw_width over single
      # CHARS is exactly the retired per-codepoint measure: it drifts right by each
      # cluster's inflation (1 column for a skin tone, 9 for a ZWJ family), and drawing
      # char-by-char also SHREDS a cluster across cells, stranding a bare combining mark in
      # one of its own. Span edges snap outward so the tint covers whole glyphs.
      a = Screen.cluster_start(line, {x0, line.size}.min)
      b = Screen.cluster_end(line, {x1, line.size}.min)
      px = x + Screen.draw_width(line[0, a])
      i = a
      while i < b
        e = Screen.cluster_end(line, i + 1)
        seg = line[i...e]
        screen.text(px, y, seg, Theme.text, bg)
        px += Screen.draw_width(seg)
        i = e
      end
    end

    # The calm CONFIG summary: a header, the payload-set rows + an Add row, then the
    # Mode / Advanced rows + a passive run-size read-out anchored at the bottom. One row
    # cursor (@cfg_row), no text field, no caret — so ←/→ can only cycle Mode. All editing
    # drills into the Set / Advanced overlays; the run itself is the TEMPLATE's ^R:RUN badge.
    private def render_config(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "CONFIG", bg: Theme.bg, border: Frame.pane_border(focused))
      inner = rect.inset(1, 1)
      return if inner.h < 1
      mx = inner.right

      screen.text(inner.x, inner.y, "PAYLOAD SETS", Theme.muted, Theme.bg)
      mcount = marker_spans.size
      if @config.mode.per_position? && !@sets.empty? && @sets.size != mcount
        hx = inner.x + 13
        screen.text(hx, inner.y, sets_hint(mcount, @sets.size), Theme.muted, Theme.bg, width: {mx - hx, 1}.max)
      end

      # Mode / Advanced + the run-size read-out anchor to the bottom 3 rows; the sets list +
      # Add row fill the space between the header and that tail (windowed if they overflow).
      #
      # The tail SHRINKS rather than climbing into the sets. `{inner.bottom - 3, inner.y + 1}.max`
      # used to clamp `tail_top` onto the sets' own first row, and since neither writer pads its
      # row, Mode landed ON a set row with the set text bleeding through its gaps
      # ("Modeist‹ sniper ›hP×N,four,…"); with no sets the Add row landed on the "PAYLOAD SETS"
      # header and — it DOES pad — erased it. Reserve the header plus one sets row first, then
      # hand the tail what is left, dropping the run read-out, then Advanced, then Mode.
      tail_rows = (inner.h - 2).clamp(0, 3)
      tail_top = inner.bottom - tail_rows
      render_sets(screen, inner, inner.y + 1, focused, tail_top)
      render_mode_row(screen, inner, tail_top, focused) if tail_rows >= 1
      render_advanced_row(screen, inner, tail_top + 1, focused) if tail_rows >= 2
      render_run_summary(screen, inner, tail_top + 2) if tail_rows >= 3
    end

    # Payload-set rows within [y0, limit), followed by the "+ Add payload set…" row.
    # `limit` is the first row the bottom tail occupies, so sets never overwrite it.
    private def render_sets(screen, inner : Rect, y0 : Int32, focused : Bool, limit : Int32) : Nil
      return if y0 >= limit           # the tail owns every row under the header — nothing to fill
      pp = @config.mode.per_position? # set i → marker i (Pitchfork/ClusterBomb)
      # REAL rows. This used to be `{limit - y0, 1}.max`, which fabricated a row the pane did
      # not have and put the first set (or the Add row) on top of the tail.
      avail = limit - y0
      if @sets.empty?
        screen.text(inner.x + 1, y0, "(no sets yet)", Theme.muted, Theme.bg)
        draw_add_row(screen, inner, y0 + 1, focused, limit)
        return
      end
      set_rows = {avail - 1, 1}.max # reserve the last available row for the Add row
      if @sets.size <= set_rows
        @cfg_scroll = 0
        y = y0
        @sets.each_with_index do |s, i|
          render_set_row(screen, inner, y, s, i, set_selected?(i), focused, pp)
          y += 1
        end
        draw_add_row(screen, inner, y, focused, limit)
      else
        visible = {set_rows - 1, 1}.max # 1 row for the overflow hint, 1 for Add
        # Only re-anchor scroll to the cursor when it's actually on a set row; on a tail
        # row (Add/Mode/Advanced/Run) current_set_index is nil, and defaulting it to 0
        # would snap a scrolled list back to the top on every render.
        if idx = current_set_index
          @cfg_scroll = idx if idx < @cfg_scroll
          @cfg_scroll = idx - visible + 1 if idx >= @cfg_scroll + visible
        end
        @cfg_scroll = @cfg_scroll.clamp(0, {@sets.size - visible, 0}.max)
        stop = {@cfg_scroll + visible, @sets.size}.min
        y = y0
        (@cfg_scroll...stop).each do |i|
          render_set_row(screen, inner, y, @sets[i], i, set_selected?(i), focused, pp)
          y += 1
        end
        above, below = @cfg_scroll, @sets.size - stop
        hint = above > 0 && below > 0 ? "… #{above} above · #{below} below" : (above > 0 ? "… #{above} above" : "… +#{below} more")
        screen.text(inner.x + 1, y, hint, Theme.muted, Theme.bg) if y < limit
        draw_add_row(screen, inner, y + 1, focused, limit)
      end
    end

    # Focus is NOT part of "is this row selected" — it decides how loudly the selection is
    # drawn, which is `render_set_row`'s business. Folded in here it erased the CONFIG cursor
    # outright whenever focus moved to a sibling pane, so coming back meant finding the row
    # again by eye.
    private def set_selected?(i : Int32) : Bool
      config_row == :set && current_set_index == i
    end

    # `limit` is the tail's first row: the Add row PADS its width, so an unbounded one
    # erased whatever the tail (or the header) had already drawn there.
    private def draw_add_row(screen, inner : Rect, y : Int32, focused : Bool, limit : Int32) : Nil
      return if y >= limit || y >= inner.bottom
      foc = focused && config_row == :add
      bg = foc ? Theme.accent_bg : Theme.bg
      screen.fill(Rect.new(inner.x, y, inner.w, 1), bg) if foc
      screen.text(inner.x + 1, y, "+ Add payload set…", foc ? Theme.text_bright : Theme.accent, bg, width: {inner.w - 1, 1}.max)
    end

    private def render_mode_row(screen, inner : Rect, y : Int32, focused : Bool) : Nil
      return if y >= inner.bottom
      foc = focused && config_row == :mode
      bg = foc ? Theme.accent_bg : Theme.bg
      screen.fill(Rect.new(inner.x, y, inner.w, 1), bg) if foc
      screen.text(inner.x, y, "Mode", Theme.muted, bg)
      x = screen.text(inner.x + 7, y, "‹ #{@config.mode.label} ›", foc ? Theme.text_bright : Theme.text, bg)
      screen.text(x + 1, y, mode_formula, Theme.muted, bg) if x + 1 + mode_formula.size <= inner.right
    end

    private def render_advanced_row(screen, inner : Rect, y : Int32, focused : Bool) : Nil
      return if y >= inner.bottom
      foc = focused && config_row == :advanced
      bg = foc ? Theme.accent_bg : Theme.bg
      screen.fill(Rect.new(inner.x, y, inner.w, 1), bg) if foc
      screen.text(inner.x, y, "Advanced", foc ? Theme.text_bright : Theme.muted, bg)
      dx = inner.x + 9
      screen.text(dx, y, "Engine · Match · Filter  ⏎", Theme.muted, bg, width: {inner.right - dx, 1}.max) if dx < inner.right
    end

    # A passive read-out of the run size (mode × sets × markers) at the CONFIG foot. NOT a
    # cursor row — the run action lives on the TEMPLATE border's ^R:RUN badge now; this just
    # reports what that badge will send, updating live as the config changes. Muted so it
    # reads as a summary, not a button. Blank when there are no sets yet (the empty-sets
    # guidance already fills that space); "unknown" when a set's size can't be sized cheaply.
    private def render_run_summary(screen, inner : Rect, y : Int32) : Nil
      return if y >= inner.bottom
      text =
        if n = run_request_count
          "↳ #{Fmt.count(n)} request#{n == 1 ? "" : "s"}"
        elsif @sets.empty?
          ""
        else
          "↳ run size unknown"
        end
      # The two things a run's SIZE now depends on besides the payload sets: the wire cap
      # (retries + redirect hops charge it, so it is not the same number as the estimate
      # above) and whether the framing the operator authored is about to be rewritten.
      cl = rewrites_content_length?
      if cap = @config.max_requests
        text += "#{text.empty? ? "↳" : " ·"} cap #{Fmt.count(cap)}"
      end
      text += "#{text.empty? ? "↳" : " ·"} CL recomputed" if cl
      return if text.empty?
      screen.text(inner.x, y, text, cl ? Theme.yellow : Theme.muted, Theme.bg, width: {inner.w, 1}.max)
    end

    # One Sets row. In per-position modes (pp) it carries a marker-coloured swatch + →N
    # chip tying it to template marker i (same tint marker i shows in the editor); the
    # chip draws AFTER the selection fill so it survives on the selected (accent_bg) row.
    private def render_set_row(screen, inner : Rect, y : Int32, s : SetSpec, i : Int32, sel : Bool,
                               focused : Bool, pp : Bool) : Nil
      bg = sel ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      screen.fill(Rect.new(inner.x, y, inner.w, 1), bg) if sel
      fg = sel ? Theme.text_bright : Theme.text
      label = "#{i + 1} #{s.kind} #{s.value}"
      unless pp
        screen.text(inner.x + 1, y, label, fg, bg, width: {inner.w - 2, 1}.max)
        return
      end
      chip = "→#{i + 1}"
      cwid = 2 + chip.size + 1 # '▎' + ' ' + token + ' '
      cx = {inner.right - cwid, inner.x + 1}.max
      screen.text(inner.x + 1, y, label, fg, bg, width: {cx - inner.x - 2, 1}.max)
      screen.cell(cx, y, '▎', Theme.marker_hue(i), bg)
      screen.text(cx + 1, y, " #{chip} ", Theme.marker_fg, Theme.marker_bg(i))
    end

    # set_for(p) = @sets[p]? || @sets[0]: with fewer sets than markers the extras wrap
    # back to set 1; with more, the surplus sets are unused. 1-based to match the rows.
    private def sets_hint(markers : Int32, sets : Int32) : String
      sets < markers ? "· #{markers} markers, #{sets} sets — marker #{sets + 1}+ reuse set 1" : "· #{markers} markers — set #{markers + 1}+ unused"
    end

    private def mode_formula : String
      case @config.mode
      when .sniper?        then "P×N"
      when .battering_ram? then "N"
      when .pitchfork?     then "min(Nᵢ)"
      else                      "∏Nᵢ"
      end
    end

    # The RESULTS border's live count. ONE definition because `results_chrome_hit` has to
    # measure exactly the string `render_results` drew, or the badge hit-boxes shift.
    #
    # `requests` — the TRUE number of requests this run put on the target — is shown only
    # when it exceeds the payload count, which is precisely when retries or redirect hops
    # made them diverge. It used to be absent entirely: the header read the number of
    # RESULT ROWS, so a 3-payload sweep with `Follow redirects` on against a redirect chain
    # said `3 sent` for 18 requests at the origin, and `Retries 2` against a dead host said
    # `2 sent` for 3. For a tester inside an agreed request budget, or against anything that
    # rate-limits or alerts on volume, that is the number that matters, and the engine has
    # always published it (`Fuzz::Progress#requests`).
    # Public so a spec can assert on the exact string the border draws — the whole defect
    # was a header reporting a different number from the one on the wire.
    def results_count_label : String
      p = @progress
      req = p ? p.requests : 0_i64
      if @running
        extra = req > (p ? p.sent : 0_i64) ? " · #{req} req" : ""
        "running #{p ? p.sent : 0}/#{@run_total || "?"}#{extra} · #{matched_count} hit"
      else
        extra = req > result_count ? " · #{req} requests" : ""
        "#{result_count} sent#{extra} · #{matched_count} hit"
      end
    end

    private def render_results(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "RESULTS", bg: Theme.bg, border: Frame.pane_border(focused))
      # Left: the live count. Right: keyed toggle badges (sort value · matched · dist) so
      # each results toggle's shortcut rides the border, not just the bottom hint bar.
      count = results_count_label
      screen.text(rect.x + 11, rect.y, count, Theme.muted, Theme.bg) # +11 clears the " RESULTS " title
      min_x = rect.x + 11 + count.size + 1                           # badges never overwrite the count
      rx = Frame.toggle_badge(screen, rect.right - 1, rect.y, min_x, "v", "DIST", @show_dist)
      rx = Frame.toggle_badge(screen, rx, rect.y, min_x, "m", "MATCH", @matched_only)
      Frame.toggle_badge(screen, rx, rect.y, min_x, "o", @sort.to_s, false) # sort: a value chip, never lit
      inner = rect.inset(1, 1)
      view = sorted_results
      @sel = @sel.clamp(0, {view.size - 1, 0}.max)
      adjust_scroll(inner.h)
      if view.empty?
        # No column header over an empty list: it is a legend for a table that is not drawn, and
        # it sat directly on the onboarding card's roof. The card takes the whole interior
        # instead. `results_row_at` already refuses every click here (it bounds-checks against
        # `sorted_results.size`), so dropping the row cannot desynchronise the hit-test.
        TrafficEmptyState.render(screen, inner, variant: :fuzzer_results, running: @running)
        return
      end
      header = "  #   payload                 status  len      words   time"
      screen.text(inner.x, inner.y, header, Theme.muted, Theme.bg, width: inner.w)
      rows_h = {inner.h - 1, 0}.max
      (0...rows_h).each do |i|
        ri = @scroll + i
        break if ri >= view.size
        render_result_row(screen, inner, inner.y + 1 + i, view[ri], ri == @sel)
      end
      # Gauge rides the rows region (below the header row), so its track lines up with
      # what @scroll actually windows.
      Frame.scroll_gauge(screen, Rect.new(inner.x, inner.y + 1, inner.w, rows_h), view.size, @scroll, focused)
    end

    private def render_result_row(screen : Screen, inner : Rect, y : Int32, r : Fuzz::Result, selected : Bool) : Nil
      bg = selected ? Theme.accent_bg : Theme.bg
      screen.fill(Rect.new(inner.x, y, inner.w, 1), bg) if selected
      screen.cell(inner.x, y, selected ? '▎' : (r.matched? ? '✓' : ' '), r.matched? ? Theme.accent : Theme.muted, bg)
      payload = r.payloads.join(", ")
      line = "#{r.index.to_s.ljust(4)} #{payload_cell(payload)}"
      # `width:` on BOTH of these: they used to draw unclamped, so a payload cell that
      # measured short (see payload_cell) pushed the status cell past `inner.right`, over
      # the card's right border and across the gap into the DIST sidebar.
      x = screen.text(inner.x + 2, y, line, selected ? Theme.text_bright : Theme.text, bg,
        width: {inner.right - (inner.x + 2), 0}.max)
      sc = r.status.try(&.to_s) || (r.error ? "ERR" : "—")
      x = screen.text(x + 1, y, sc.ljust(7), status_color(r), bg, width: {inner.right - (x + 1), 0}.max)
      # A send that never got a response has no length/words/duration worth showing — the
      # reason does. `cli/output.cr:fuzz_row_text` already appends `r.error` per row; the
      # TUI used to drop it entirely, so a scope/sandbox refusal read as a bare "ERR".
      #
      # Every remaining-width clamp below is floored at 0, NOT 1: once `x` reaches
      # `inner.right` there are no columns left to spend, and a floor of 1 kept painting one
      # cell per call PAST the card's border — which is how an over-wide payload leaked into
      # the DIST sidebar. `Screen#text` returns immediately on a width of 0, so 0 is a clean
      # no-draw and the gRPC `x2` chain no-ops instead of cascading.
      if err = r.error
        screen.text(x, y, err, Theme.red, bg, width: {inner.right - x, 0}.max)
      elsif r.chain_error
        # The send succeeded, but this row's `¦chain` did not run — its payload went out raw.
        # Flag it in the list (the detail request pane names the reason) so a swallowed chain
        # isn't invisible among clean rows. #567/H3 Finding 1.
        screen.text(x, y, "⚠ ¦chain not applied", Theme.yellow, bg, width: {inner.right - x, 0}.max)
      else
        line = "#{Fmt.size(r.length).ljust(8)} #{r.words.to_s.ljust(7)} #{Fmt.dur(r.duration_us)}"
        # Compact per-row markers — the detail panes carry the full story; here they flag a SHORT
        # capture (so the size/words to the left aren't read as the whole response) and a
        # `--retries` re-send, so a scan of the list catches both. Built from the row's own flags,
        # not the CLI classifier: the TUI has no CLI dependency.
        line += "  ⚠ incomplete" if r.incomplete?
        line += "  ⟳ ×#{r.resent_count}" if r.resent?
        # For a gRPC target the h2 `:status` to the left is 200 by definition; THIS is the
        # call's real outcome. Only rendered when the response carried it, so a non-gRPC row
        # is unchanged — same fields `cli/output.cr:fuzz_row_text` already renders.
        if gs = r.grpc_status
          x2 = screen.text(x, y, line, selected ? Theme.text : Theme.muted, bg, width: {inner.right - x, 0}.max)
          gline = " grpc #{gs} #{Proxy::H2::Grpc.status_name(gs)}#{r.grpc_message ? " · #{r.grpc_message}" : ""}"
          screen.text(x2, y, gline, gs == 0 ? Theme.green : Theme.red, bg, width: {inner.right - x2, 0}.max)
        else
          screen.text(x, y, line, selected ? Theme.text : Theme.muted, bg, width: {inner.right - x, 0}.max)
        end
      end
    end

    # The payload cell, exactly PAYLOAD_COL_W display COLUMNS wide — never `String#size`.
    # A Hangul payload is one char but TWO columns per char, so `payload.size > 22` read
    # false at 44 columns and `ljust(22)` then padded a cell already at double its budget:
    # the row ran 22 columns long, pushing every cell to its right over the RESULTS border
    # and into the DIST sidebar. `column_for` is the exact inverse of `draw_width` at
    # cluster boundaries, so the cut lands on a boundary and no wide glyph is split; the
    # pad is the COLUMN shortfall, which is why the ellipsis branch pads too (a cut that
    # stops short of a wide glyph leaves one column to make up).
    private def payload_cell(payload : String) : String
      w = Screen.draw_width(payload)
      return "#{payload}#{" " * (PAYLOAD_COL_W - w)}" if w <= PAYLOAD_COL_W
      cut = payload[0, Screen.column_for(payload, PAYLOAD_COL_W - 1)]
      "#{cut}…#{" " * (PAYLOAD_COL_W - 1 - Screen.draw_width(cut))}"
    end

    private def status_color(r : Fuzz::Result) : Color
      return Theme.red if r.error
      s = r.status
      return Theme.muted unless s
      case s
      when 200..299 then Theme.green
      when 300..399 then Theme.muted
      when 400..499 then Theme.yellow
      else               Theme.red
      end
    end

    # ── DIST sidebar — result distribution at a glance ───────────────────────────
    # Status bars + Len/Words/Time sparkline histograms over ALL @results (NOT the
    # matched/sort-filtered view) so the outlier you're filtering out still shows and
    # the picture stays stable while you re-sort. Read-only; data cached on @results_rev.

    private def render_dist(screen : Screen, rect : Rect, focused : Bool = false) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "DIST", bg: Theme.bg, border: Frame.pane_border(focused))
      inner = rect.inset(1, 1)
      return if inner.empty?
      if @results.empty?
        # A LINE, not the card. DIST sits beside the RESULTS pane, which is already drawing the
        # `fuzzer_results` card — the same variant here put "no results yet · ^O payload sets ·
        # ^R run" on screen twice, side by side, in a sidebar too narrow to render anything but
        # the medium fallback anyway.
        screen.text(inner.x + 1, inner.y, @running ? "sampling…" : "no results yet",
          Theme.muted, Theme.bg, width: {inner.w - 2, 0}.max)
        return
      end
      d = dist_data(inner.w)
      # Reserve 6 rows for the 3 spark sections when the pane is tall; else status takes all.
      status_limit = inner.h >= 8 ? {inner.bottom - 6, inner.y + 1}.max : inner.bottom
      y = render_dist_status(screen, inner, inner.y, status_limit, d)
      y = render_dist_spark(screen, inner, y, "len", d.len_hist, Fmt.size(d.len_min), Fmt.size(d.len_max)) if y + 2 <= inner.bottom
      y = render_dist_spark(screen, inner, y, "wrd", d.words_hist, d.words_min.to_s, d.words_max.to_s) if y + 2 <= inner.bottom
      render_dist_spark(screen, inner, y, "tim", d.time_hist, Fmt.dur(d.time_min), Fmt.dur(d.time_max)) if y + 2 <= inner.bottom
    end

    private def render_dist_status(screen, inner : Rect, y0 : Int32, limit : Int32, d : DistData) : Int32
      rows_budget = {limit - y0, 1}.max
      groups = dist_status_groups(d, rows_budget)
      return y0 if groups.empty?
      total = d.codes.sum(&.[1]) + d.err
      maxc = groups.max_of?(&.[1]) || 1
      label_w = 4                      # "200 " / "5xx " / "ERR "
      num_w = {total.to_s.size, 4}.min # right-aligned count column (≤ RESULT_CAP digits)
      bar_w = {inner.w - label_w - num_w - 1, 1}.max
      y = y0
      groups.each_with_index do |(label, count, code), i|
        break if y >= limit
        if i == rows_budget - 1 && groups.size > rows_budget
          screen.text(inner.x, y, "+#{groups.size - i} more", Theme.muted, Theme.bg, width: inner.w)
          return y + 1
        end
        col = code ? Theme.status_color(code) : Theme.red # ERR (nil) → red; resolved LIVE
        screen.text(inner.x, y, label.ljust(label_w), col, Theme.bg)
        screen.text(inner.x + label_w, y, Spark.bar(count, maxc, bar_w), col, Theme.bg)
        screen.text(inner.x + label_w + bar_w + 1, y, count.to_s.rjust(num_w), Theme.muted, Theme.bg, width: num_w)
        y += 1
      end
      y
    end

    # Distinct codes when they fit (a lone 500 keeps its own red bar — max signal);
    # otherwise collapse to classes 2xx/3xx/4xx/5xx (+ ERR for status-nil rows).
    private def dist_status_groups(d : DistData, budget : Int32) : Array({String, Int32, Int32?})
      n = d.codes.size + (d.err > 0 ? 1 : 0)
      out = [] of {String, Int32, Int32?}
      if n <= {budget, STATUS_MAX_ROWS}.min
        d.codes.each { |(s, c)| out << {s.to_s, c, s.as(Int32?)} }
      else
        cls = Hash(Int32, Int32).new(0)
        d.codes.each { |(s, c)| cls[s // 100] += c }
        cls.to_a.sort_by!(&.[0]).each { |(k, c)| out << {"#{k}xx", c, (k * 100).as(Int32?)} }
      end
      out << {"ERR", d.err, nil.as(Int32?)} if d.err > 0
      out
    end

    private def render_dist_spark(screen, inner : Rect, y : Int32, label : String,
                                  hist : Array(Int32), lo_s : String, hi_s : String) : Int32
      screen.text(inner.x, y, "#{label} #{lo_s} … #{hi_s}", Theme.muted, Theme.bg, width: inner.w)
      screen.text(inner.x, y + 1, Spark.line(hist), Theme.text, Theme.bg, width: inner.w)
      y + 2
    end

    # Aggregate @results into the DIST view, cached on {@results_rev, pane width}. NOT
    # keyed on Theme.revision — DistData bakes no Color (resolved live at draw); NOT on
    # @matched_only/@sort — the distribution is intentionally over the full result set.
    private def dist_data(w : Int32) : DistData
      c = @dist_cache
      return c if c && @dist_cache_rev == @results_rev && @dist_cache_w == w
      @dist_cache_rev = @results_rev
      @dist_cache_w = w
      @dist_cache = build_dist(w)
    end

    private def build_dist(w : Int32) : DistData
      codes = Hash(Int32, Int32).new(0)
      err = 0
      lens = @dist_lens; lens.clear
      words = @dist_words; words.clear
      times = @dist_times; times.clear
      @results.each do |r|
        if s = r.status
          codes[s] += 1
          lens << r.length # response rows only — keep error 0-rows out of len/wrd spikes
          words << r.words
        else
          err += 1
        end
        times << r.duration_us # every row: a timeout's latency IS the signal
      end
      lh, lmin, lmax = hist_bounds64(lens, w)
      wh, wmin, wmax = hist_bounds32(words, w)
      th, tmin, tmax = hist_bounds64(times, w)
      DistData.new(
        codes: codes.to_a.sort_by!(&.[0]), err: err,
        len_hist: lh, len_min: lmin, len_max: lmax,
        words_hist: wh, words_min: wmin, words_max: wmax,
        time_hist: th, time_min: tmin, time_max: tmax,
      )
    end

    # Histogram + {min, max} for a dimension in a SINGLE min/max scan whose result is fed to
    # Spark.histogram so it doesn't re-scan for bounds — replacing the old three passes per
    # dimension (histogram's own min/max scan + an explicit `.min?` + `.max?`). Empty → zeros,
    # matching the old `(values.min? || 0)` / `(values.max? || 0)`; the passed bounds are the
    # array's own min/max, so the binning is byte-identical.
    private def hist_bounds64(values : Array(Int64), w : Int32) : {Array(Int32), Int64, Int64}
      return {Spark.histogram(values, w), 0_i64, 0_i64} if values.empty?
      lo = hi = values.unsafe_fetch(0)
      values.each do |v|
        lo = v if v < lo
        hi = v if v > hi
      end
      {Spark.histogram(values, w, min: lo.to_f, max: hi.to_f), lo, hi}
    end

    private def hist_bounds32(values : Array(Int32), w : Int32) : {Array(Int32), Int32, Int32}
      return {Spark.histogram(values, w), 0, 0} if values.empty?
      lo = hi = values.unsafe_fetch(0)
      values.each do |v|
        lo = v if v < lo
        hi = v if v > hi
      end
      {Spark.histogram(values, w, min: lo.to_f, max: hi.to_f), lo, hi}
    end

    private def adjust_scroll(h : Int32) : Nil
      rows_h = {h - 1, 1}.max
      @scroll = @sel if @sel < @scroll
      @scroll = @sel - rows_h + 1 if @sel >= @scroll + rows_h
      @scroll = {@scroll, 0}.max
    end

    private def render_detail(screen : Screen, rect : Rect, focused : Bool) : Nil
      r = selected_result
      unless r
        @focus = :results
        return
      end
      Frame.card(screen, rect, "RESULT ##{r.index}", bg: Theme.bg, border: Frame.pane_border(focused))
      panes = detail_panes
      @detail_pane = :request unless panes.includes?(@detail_pane) # decode may have dropped a pane
      render_detail_chips(screen, rect, panes)
      inner = rect.inset(1, 1)
      lines = detail_lines(r)
      styled = detail_styled(r, lines)
      sync_detail_source
      # `styled_at` is COLOUR ONLY — its span texts concatenate back to the same `lines[li]` the
      # pane addresses, which is what lets the caret, the selection band and the wrap layout be
      # measured on the plain line while the draw paints the coloured one. A row the overlay has
      # no entry for falls back to the plain text in `Theme.text`, exactly as before.
      @detail_read.render(screen, inner, focused && detail_navigable?,
        styled_at: ->(li : Int32) { styled[li]? || Highlight::Line{Highlight::Span.new(lines[li]? || "", Theme.text)} })
    end

    # The detail sub-panes in order: REQUEST → RESPONSE → decoded-protocol panes (each
    # present only when the open result carries it). Mirrors the History detail strip.
    private def detail_panes : Array(Symbol)
      panes = [:request, :response]
      panes << :saml if @d_saml
      panes << :jwt unless @d_jwts.empty?
      panes << :graphql if @d_graphql
      panes << :params if @d_form
      panes
    end

    # The pane chips on the RESULT detail top border — one per pane the result carries,
    # the active one lit. Starts right of the "RESULT ##" title; stops before the edge.
    private def render_detail_chips(screen : Screen, rect : Rect, panes : Array(Symbol)) : Nil
      x = rect.x + 14
      panes.each do |pane|
        label = " #{detail_pane_label(pane)} "
        break if x + label.size >= rect.right - 1
        active = pane == @detail_pane
        x = screen.text(x, rect.y, label, active ? Theme.text_bright : Theme.muted,
          active ? Theme.accent_bg : Theme.bg) + 1
      end
    end

    private def detail_pane_label(pane : Symbol) : String
      case pane
      when :saml    then "saml"
      when :jwt     then @d_jwts.size > 1 ? "jwt (#{@d_jwts.size})" : "jwt"
      when :graphql then "graphql"
      when :params  then "params"
      when :request then "request"
      else               "response"
      end
    end

    private def detail_lines(r : Fuzz::Result) : Array(String)
      key = {@detail_pane, r.index}
      if (c = @detail_lines_cache) && @detail_lines_key == key
        return c
      end
      lines =
        case @detail_pane
        when :saml    then saml_detail_lines
        when :jwt     then jwt_detail_lines
        when :graphql then graphql_detail_lines
        when :params  then form_detail_lines
        when :request then detail_request_lines(r)
        else               detail_response_lines(r)
        end
      @detail_lines_cache = lines
      @detail_lines_key = key
      lines
    end

    # Syntax-highlighted overlay for the detail `lines`, cached in lockstep with the
    # plain @detail_lines_cache (+ theme revision). Request/response panes go through the
    # full message highlighter; the decoded panes style per line with their body kind.
    # 1:1 with `lines`, so the plain strings still drive the gutter/cursor/selection.
    private def detail_styled(r : Fuzz::Result, lines : Array(String)) : Array(Highlight::Line)
      key = {@detail_pane, r.index}
      if (c = @detail_styled_cache) && @detail_styled_key == key && @detail_styled_rev == Theme.revision
        return c
      end
      styled =
        case @detail_pane
        when :request  then Highlight.from_lines(lines, request: true)
        when :response then Highlight.from_lines(lines, request: false)
        when :graphql  then lines.map { |ln| Highlight.body_styled(ln, :graphql) }
        when :jwt      then lines.map { |ln| Highlight.body_styled(ln, :json) }
        when :saml     then lines.map { |ln| Highlight.body_styled(ln, :xml) }
        else                lines.map { |ln| Highlight.body_styled(ln, :text) }
        end
      @detail_styled_cache = styled
      @detail_styled_key = key
      @detail_styled_rev = Theme.revision
      styled
    end

    # The wire request for a result, WITH its provenance — what the detail pane shows and
    # what "Send to Repeater" hands over (see FuzzerController#selected_repeater_seed), so
    # the two can never disagree, and neither can pass a reconstruction off as evidence.
    #
    # `reconstructed: false` means `bytes` is the exact octets the engine put on the socket
    # (`Result#request` = `Job#bytes`), retained under the run's keep_bodies policy.
    # `reconstructed: true` means nothing kept them and they were re-derived here.
    record ResultRequest, bytes : Bytes, reconstructed : Bool

    # The one sentence every surface uses for a reconstruction — kept next to the record so
    # the detail pane, the copy buffer and the Repeater seed cannot word it differently, and
    # deliberately shaped like the response pane's "(response not retained — …)" note, which
    # sits beside it and would otherwise imply by contrast that the request pane is real.
    def self.reconstruction_note(keep_bodies : Symbol) : String
      "(reconstructed from the template — this row's request was not retained; keep_bodies: #{keep_bodies})"
    end

    # `Result#request` is the byte-exact request the engine sent. When it wasn't retained
    # (:none, or :matched and this row missed — the TUI default, so this is EVERY
    # non-matching row) re-render the run's frozen template: env-expanded as sent, so a
    # post-run edit to the live buffer can't truncate/garble it, and now through the SAME
    # two steps the generator applied — the per-position `¦chain` transform and the
    # Content-Length sync (`Fuzz::Generator#emit`). Without those the pane showed a 31-byte
    # body under the template's `Content-Length: 12`, a combination no socket ever carried
    # and the single most consequential header to get wrong on a fuzzing surface.
    #
    # It is still a reconstruction, not evidence: a payload the engine sent through a set
    # processor, a run whose template the buffer no longer matches, or anything the frozen
    # template does not capture can still differ. Hence the flag — closeness is the
    # consolation, saying so is the fix.
    def result_request(r : Fuzz::Result) : ResultRequest
      if sent = r.request
        return ResultRequest.new(sent, false)
      end
      tmpl = @run_template || Fuzz::Template.parse(String.new(Env.expand_wire(@editor.wire_text)), @http2)
      # Values only — the reason a chain didn't run is already carried on the row
      # (r.chain_error), surfaced by detail_request_lines below.
      payloads = tmpl.apply_chains(r.payloads, Decoder.shared_registry)
      raw = tmpl.render(payloads)
      sync, add, _ = run_policy
      raw = Fuzz::ContentLength.sync(raw, add) if sync
      ResultRequest.new(raw, true)
    end

    # The frozen {update_cl, add_cl_when_missing, keep_bodies} of the run that produced
    # @results, falling back to the live config for a view whose results predate the freeze.
    private def run_policy : {Bool, Bool, Symbol}
      @run_policy || {@config.update_content_length?, @config.add_content_length_when_missing?,
                      @matcher.keep_bodies}
    end

    # The provenance note for `r`, or nil when its request is retained evidence. Public: the
    # controller stamps it on the Repeater seed so "Send to Repeater" carries the same caveat
    # the detail pane shows.
    def result_request_note(r : Fuzz::Result) : String?
      return nil unless r.request.nil?
      FuzzerView.reconstruction_note(run_policy[2])
    end

    # Bytes only — for callers that have already accounted for provenance (the decode strip,
    # which only needs a shape to parse). Never use this where the bytes are shown or resent.
    def result_request_bytes(r : Fuzz::Result) : Bytes
      result_request(r).bytes
    end

    private def detail_request_lines(r : Fuzz::Result) : Array(String)
      req = result_request(r)
      lines = String.new(req.bytes).scrub.split('\n').map(&.rstrip('\r'))
      lines.unshift(FuzzerView.reconstruction_note(run_policy[2])) if req.reconstructed
      # This pane already SHOWS the untransformed bytes for a row whose `¦chain` did not run
      # (result_request re-applies the same chains the engine did). Say WHY, so the operator
      # doesn't read the raw payload as the request they declared. #567/H3 Finding 1.
      if ce = r.chain_error
        lines.unshift("(¦chain not applied: #{ce})")
      end
      # The `--retries` config re-sent this request after a network error (DISTINCT from a
      # keep-alive re-send) — a note here because it qualifies the REQUEST that went out, and
      # the raw bytes above give no hint that they were sent more than once.
      if r.resent?
        lines.unshift("(re-sent #{r.resent_count}× after a network error — --retries)")
      end
      lines
    end

    private def detail_response_lines(r : Fuzz::Result) : Array(String)
      # The send failed, so there is no response to retain — say THAT, not the retention
      # policy. Fuzz::Engine builds a refused/failed Result with an empty head (engine.cr,
      # the scope/sandbox path), and Matcher#present returns nil for it under every
      # keep_bodies setting, so this branch is the only place the reason can surface.
      if err = r.error
        return ["(send failed: #{err})"]
      end
      head = r.head
      return ["(response not retained — only matched results keep the response)"] unless head
      body = r.body
      lines = String.new(head).scrub.split('\n').map(&.rstrip('\r'))
      if body && !body.empty?
        lines << ""
        lines.concat(String.new(body).scrub.split('\n').map(&.rstrip('\r')))
      end
      # The captured response was cut short (origin closed early, a read deadline fired, or the
      # capture ceiling stopped the read), so what is shown above is a FRAGMENT. Flagged from the
      # row's own flags, not the CLI classifier — the TUI has no CLI dependency — keeping the
      # timeout distinction the operator needs to tell "raise the deadline" from "origin closed".
      if r.incomplete?
        lines.unshift(r.timed_out? ? "(incomplete — the read deadline expired; the response is truncated)" : "(incomplete — the response is truncated)")
      end
      lines
    end

    # --- decoded-protocol detail panes (plain text, like the request/response panes) ---
    private def saml_detail_lines : Array(String)
      doc = @d_saml || return [] of String
      lines = ["▸ #{Saml.summary(doc)}", ""]
      lines.concat(Saml.pretty_xml(doc.xml).scrub.split('\n').map(&.rstrip('\r')))
      lines
    end

    private def jwt_detail_lines : Array(String)
      lines = [] of String
      @d_jwts.each_with_index do |f, i|
        lines << "" if i > 0
        brief = f.brief
        lines << (brief ? "▸ #{f.location} · #{brief}" : "▸ #{f.location}")
        lines << detail_jwt_token(f.token)
        lines << ""
        lines.concat(f.decoded.scrub.split('\n'))
      end
      lines
    end

    # A JWT can be hundreds of chars; show a head…tail preview so the raw token is
    # available to read without dominating the pane (mirrors the History detail).
    private def detail_jwt_token(tok : String) : String
      tok.size > 64 ? "#{tok[0, 40]}…#{tok[-12, 12]}" : tok
    end

    private def graphql_detail_lines : Array(String)
      op = @d_graphql || return [] of String
      Graphql.display(op).scrub.split('\n')
    end

    private def form_detail_lines : Array(String)
      fields = @d_form || return [] of String
      lines = ["▸ #{fields.size} field#{fields.size == 1 ? "" : "s"}", ""]
      fields.each do |f|
        tag = f.source == :query ? "?" : " "
        note = f.note
        lines << "#{tag} #{f.name} = #{note ? "(#{note})" : f.value}"
      end
      lines
    end

    # --- clicks --------------------------------------------------------------
    # Mouse: place the TARGET field caret at a click. Single-line field; the value
    # base mirrors render_target (the "›" marker at rect.x+2, the value at rect.x+4).
    # `selecting` is the DRAG half — see `RepeaterView#target_click_to_cursor`, whose
    # reasoning this mirrors: a drag never switches FIELDS (the anchor would end up measured
    # in one value and painted over another), and even a bare press routes through `move_cx`
    # so it COLLAPSES a standing selection instead of leaving the anchor behind.
    def target_click_to_cursor(rect : Rect, mx : Int32, my : Int32, selecting : Bool = false) : Nil
      return unless @loaded
      # Row 2 is the SNI field when it is showing — a click there selects that field, the
      # same mapping RepeaterView#target_click_to_cursor makes, so the caret cannot land on
      # the row the click did not point at.
      @target_field = (sni_active? && my == rect.y + 2) ? :sni : :url unless selecting
      if @target_field == :sni
        to = Screen.column_for_click(@sni, mx - field_base(rect, SNI_PREFIX))
        @scx = @target_read.move_cx(@scx, to - @scx, @sni.size, selecting: selecting)
      else
        to = Screen.column_for_click(@target, mx - field_base(rect, TARGET_PREFIX))
        @tcx = @target_read.move_cx(@tcx, to - @tcx, @target.size, selecting: selecting)
      end
    end

    # Pointer moved with the button held over the target card — READ mode only, for the
    # reason spelled out on `RepeaterView#target_drag_to_cursor`: INSERT paints no band, so
    # extending there would plant a selection nothing draws and `target_copy_text` would
    # still honour it.
    def target_drag_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return if target_insert?
      target_click_to_cursor(rect, mx, my, selecting: true)
    end

    # Double-click: take the word the press already placed the caret on, spreading from THAT
    # caret rather than hit-testing again. False on whitespace or an empty field, leaving the
    # press's caret standing.
    def target_select_word : Bool
      return false unless @loaded && !target_insert?
      if @target_field == :sni
        cx = @target_read.select_word_at_cursor(@sni, @scx)
        return false unless cx
        @scx = cx
      else
        cx = @target_read.select_word_at_cursor(@target, @tcx)
        return false unless cx
        @tcx = cx
      end
      true
    end

    # Mouse: place the TEMPLATE editor caret at a click. Re-derives the template
    # half-pane exactly as render/render_top do (target band → 45%-tall top row →
    # left half → the card's 1-cell inset), so the caret lands where the click points.
    def template_click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless @loaded
      target_h = {rect.h, target_card_h}.min
      rest = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
      return if rest.h <= 0
      top_h = {rest.h * 45 // 100, 5}.max
      top_h = rest.h if rest.h < 6
      half = {(rest.w - 1) // 2, 1}.max
      left = Rect.new(rest.x, rest.y, half, top_h)
      commit_chain_pane if @chain_focused # a click outside the ^Q modal commits + dismisses it
      inner = left.inset(1, 1)
      template_insert? ? @editor.click_to_cursor(inner, mx, my) : @template_read.click(@editor, inner, mx, my)
    end

    # Mouse DRAG in the TEMPLATE pane — extend the selection to the pointer. Each mode is
    # extended through the selection model that owns it (INS: the editor's own anchor; READ:
    # `@template_read`), the same split the Repeater's request pane draws.
    def template_drag_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      inner = template_editor_rect(rect) || return
      if template_insert?
        @editor.click_to_cursor(inner, mx, my, selecting: true)
      else
        @template_read.click(@editor, inner, mx, my, selecting: true)
      end
    end

    # Mouse DOUBLE-CLICK in the TEMPLATE pane — select the word under the pointer.
    def template_select_word(rect : Rect, mx : Int32, my : Int32) : Bool
      inner = template_editor_rect(rect) || return false
      template_insert? ? @editor.select_word_at(inner, mx, my) : @template_read.select_word(@editor, inner, mx, my)
    end

    # The template editor's content rect inside `rect` — the derivation
    # `template_click_to_cursor` walks, factored out so click, drag and double-click cannot
    # land on three slightly different rects.
    private def template_editor_rect(rect : Rect) : Rect?
      return nil unless @loaded
      target_h = {rect.h, target_card_h}.min
      rest = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
      return nil if rest.h <= 0
      top_h = {rest.h * 45 // 100, 5}.max
      top_h = rest.h if rest.h < 6
      half = {(rest.w - 1) // 2, 1}.max
      Rect.new(rest.x, rest.y, half, top_h).inset(1, 1)
    end

    # Mouse: the sorted-view result index under a click in the RESULTS pane, or nil
    # (outside the pane, on the header row, or past the last populated row). Mirrors
    # render_results' 1-cell inset → header row → @scroll+i row math.
    def results_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      results = results_rect(rect)
      return nil if results.nil? || results.empty? || !results.contains?(mx, my)
      inner = results.inset(1, 1)
      i = my - (inner.y + 1) # rows start one line below the header
      return nil if i < 0 || i >= {inner.h - 1, 0}.max
      ri = @scroll + i
      ri < sorted_results.size ? ri : nil
    end

    # The row a click on the scroll gauge asks for. The gauge rides the frame's right hairline,
    # one column outside the list rect, so the row hit-test cannot answer it — and `@scroll`
    # here is DERIVED from the selection, so the answer is a selection.
    def results_gauge_row(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless pane = results_rect(rect)
      inner = pane.inset(1, 1)
      return nil if inner.h <= 1
      # Rows region, below the header — the band the draw hands the gauge.
      Frame.scroll_gauge_row(Rect.new(inner.x, inner.y + 1, inner.w, inner.h - 1),
        sorted_results.size, mx, my)
    end

    # The RESULTS pane rect within body `rect`, re-deriving render → render_bottom →
    # render_results' split (target band → 45%-tall top row → bottom minus the DIST
    # sidebar). nil when the layout leaves no room. Backs results_row_at hit-testing.
    private def results_rect(rect : Rect) : Rect?
      return nil unless @loaded
      # render_bottom hands the whole band to RESULT DETAIL when `@focus == :detail`, so
      # RESULTS is not on screen at all — and this rect backs `results_chrome_hit`, which
      # `FuzzerController#handle_click` consults FIRST. Ungated, a click on the detail card's
      # own top border in the badge zone toggled DIST/MATCH/sort *and* kicked the operator
      # out of the detail via `focus_pane(:results)`. With `@show_dist` on, the two rects do
      # not even share a right edge — this one is `dist_width` narrower than the card drawn.
      return nil if @focus == :detail
      target_h = {rect.h, target_card_h}.min
      rest = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
      return nil if rest.h <= 0
      top_h = {rest.h * 45 // 100, 5}.max
      top_h = rest.h if rest.h < 6
      bottom = Rect.new(rest.x, rest.y + top_h, rest.w, {rest.h - top_h, 0}.max)
      return nil if bottom.h <= 0
      vw = @show_dist ? dist_width(bottom.w) : 0
      rw = vw > 0 ? bottom.w - vw - 1 : bottom.w
      Rect.new(bottom.x, bottom.y, rw, bottom.h)
    end

    # Hit-test RESULTS border badges (v:DIST / m:MATCH / o:sort). Geometry matches
    # render_results: count text at x+11, badges right-chained from right_edge with
    # min_x past the count. Miss → nil (caller falls through to row select).
    def results_chrome_hit(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil unless pane = results_rect(rect)
      return nil if pane.w < 2 || my != pane.y
      min_x = pane.x + 11 + results_count_label.size + 1
      Frame.right_badge_hit(mx, my, pane.y, pane.right - 1, min_x, [
        {:dist, "v", "DIST"},
        {:match, "m", "MATCH"},
        {:sort, "o", @sort.to_s},
      ] of {Symbol, String, String})
    end

    # Hit-test the TEMPLATE border chrome (^R:RUN, ^U:PRETTY, NOR/INS). Geometry mirrors
    # render_template. Miss → nil (caller falls through to caret/focus).
    def template_chrome_hit(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil unless @loaded
      target_h = {rect.h, target_card_h}.min
      rest = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
      return nil if rest.h <= 0
      top_h = {rest.h * 45 // 100, 5}.max
      top_h = rest.h if rest.h < 6
      half = {(rest.w - 1) // 2, 1}.max
      left = Rect.new(rest.x, rest.y, half, top_h)
      return nil if left.w < 2 || my != left.y
      label = @http2 ? "TEMPLATE (h2)" : "TEMPLATE"
      min_x = left.x + label.size + 4
      right_edge = left.right - 1
      badges = [{:run, "^R", "RUN"}, {:pretty, "^U", "PRETTY"}] of {Symbol, String, String}
      if hit = Frame.right_badge_hit(mx, my, left.y, right_edge, min_x, badges)
        return hit
      end
      mode_edge = Frame.right_badge_edge(right_edge, min_x, badges)
      Frame.mode_badge_hit(mx, my, left.y, mode_edge, min_x, template_insert? || @chain_focused) ? :mode : nil
    end

    # `SNI` is a MARKER, not a control — nothing happens when it is clicked. It is hit-tested
    # anyway so it can answer `nil` for itself: without this the mode chip's rect still covered
    # those cells and a press on them flipped insert mode.
    #
    # Hit-test the TARGET border NOR/INS chip. Geometry matches render_target through the
    # shared `target_sni_x`.
    def target_chrome_hit(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil unless @loaded
      target_h = {rect.h, target_card_h}.min
      return nil if target_h < 2 || my != rect.y
      if sni_x = target_sni_x(rect)
        return nil if mx >= sni_x && mx < sni_x + SNI_BADGE.size
      end
      Frame.mode_badge_hit(mx, my, rect.y, rect.right - 1, rect.x + 8, target_insert?) ? :mode : nil
    end

    # Where the SNI marker sits, or nil when there is no override or no room for one. The ONE
    # place that geometry lives, so render and the hit-test cannot disagree about it.
    private def target_sni_x(rect : Rect) : Int32?
      return nil if @sni.strip.empty?
      edge = rect.right - 1
      mode = Frame.mode_badge_label(target_insert?)
      edge -= mode.size if edge - mode.size >= rect.x + 8 # the mode chip's own stop
      x = edge - SNI_BADGE.size
      x >= rect.x + 9 ? x : nil # one column clear of the card title
    end

    def pane_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil unless @loaded && rect.contains?(mx, my)
      target, top, bottom = stack_rects(rect)
      return :target if target.contains?(mx, my)
      return nil if top.h <= 0
      if my < top.bottom
        half = {(top.w - 1) // 2, 1}.max
        mx < top.x + half ? :template : :config
      elsif @focus == :detail
        :detail
      else
        vw = @show_dist ? dist_width(bottom.w) : 0
        vw > 0 && mx >= bottom.x + bottom.w - vw ? nil : :results # read-only DIST sidebar → no-op
      end
    end
  end
end
