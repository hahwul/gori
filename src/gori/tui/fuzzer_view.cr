require "json"
require "./screen"
require "./theme"
require "./frame"
require "./input_mode"
require "./text_read_state"
require "./line_field_read"
require "./read_cursor"
require "./gutter"
require "./traffic_empty_state"
require "./text_area"
require "./fmt"
require "./spark"
require "./chain_pane"
require "./chain_overlay"
require "../store"
require "../fuzz"
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

    getter focus : Symbol # :target | :template | :config | :results | :detail
    getter target : String
    getter? http2 : Bool
    getter? loaded : Bool
    getter? dirty : Bool
    getter? running : Bool
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
      @http2 = false
      @editor = TextArea.new
      @editor.gutter = true
      @editor.follow_x = true     # long lines (headers, URLs, §-marked params) scroll horizontally to keep the cursor visible
      @editor.env_complete = true # `$KEY` autocomplete against the registered env vars (expanded on send)
      @editor.chain_peek = true   # tooltip revealing the concealed ¦chain of the §…§ marker under the caret
      @last_synced_config = ""    # last store config blob applied (reconcile equality)
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
      # Results-pane memos, all keyed on @results_rev (the O(n)/O(n log n) scans below
      # ran EVERY frame — the busiest moment is a live run streaming results, each of
      # which forces a redraw). matched_count is rev-only; the sorted view also keys on
      # the sort order + matched-only toggle.
      @matched_count_cache = 0
      @matched_count_rev = -1_i64
      @sorted_cache = nil.as(Array(Fuzz::Result)?)
      @sorted_cache_rev = -1_i64
      @sorted_cache_sort = :index
      @sorted_cache_matched = false
      @progress = nil.as(Fuzz::Progress?)
      @run_total = nil.as(Int64?)
      @job_id = 0
      @stop_requested = false
      @detail_scroll = 0
      @detail_xscroll = 0 # horizontal scroll offset for the RESULT detail (shift+←/→)
      @detail_pane = :response
      @detail_cursor = ReadCursor.new
      @detail_last_h = 0 # viewport height from last detail render (wheel clamp)
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
    def load(detail : Store::FlowDetail) : Nil
      built = Repeater::FlowRequest.build(detail)
      @http2 = built.http2
      @target = built.target
      @tcx = @target.size
      @editor.set_text(String.new(built.bytes).scrub)
      @focus = :template
      @loaded = true
      @dirty = false
    end

    def load_request(target : String, request_text : String, http2 : Bool, sni : String) : Nil
      @target = target
      @tcx = target.size
      @http2 = http2
      @sni = sni
      @editor.set_text(request_text)
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
      @editor.set_text(rec.template)
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
      @editor.set_text(rec.template) if @editor.text != rec.template
      @name = rec.name
      apply_config_json(rec.config)
      @last_synced_config = rec.config
      @loaded = true
      @dirty = false
    end

    # True when the live view matches a store row's request-side fields (reconcile skip).
    # Template compare normalizes CRLF→LF (TextArea stores LF; the store may hold wire CRLF).
    def session_side_matches?(rec : Store::FuzzSessionRecord) : Bool
      @target == rec.target &&
        template_text == normalize_lf(rec.template) &&
        @http2 == rec.http2? &&
        (sni_override || "") == (rec.sni || "") &&
        (@name || "") == (rec.name || "") &&
        @last_synced_config == rec.config
    end

    private def normalize_lf(s : String) : String
      s.gsub("\r\n", "\n").gsub('\r', '\n')
    end

    # Content-only clone for sub-tab Duplicate: template + target + config/sets.
    # Does not copy run results, job state, or source flow linkage.
    def duplicate_from(src : FuzzerView) : Nil
      load_request(src.target, src.template_text, src.http2?, src.sni_override || "")
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
    def template_text : String
      @editor.text
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
    def focus_first : Nil
      @focus = :target
    end

    def focus_last : Nil
      @focus = :results
    end

    def focus_pane(pane : Symbol) : Nil
      return unless PANE_ORDER.includes?(pane)
      commit_chain_pane if @chain_focused
      @focus = pane
    end

    def focus_config : Nil
      commit_chain_pane if @chain_focused
      @focus = :config
      @cfg_row = 0 # land on the first payload set / the Add row
    end

    def pane_advance(dir : Int32) : Bool
      commit_chain_pane if @chain_focused
      if @focus == :detail
        @focus = :results
        return true
      end
      i = PANE_ORDER.index(@focus) || 0
      ni = i + dir
      return false if ni < 0 || ni >= PANE_ORDER.size
      @focus = PANE_ORDER[ni]
      true
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
    getter detail_cursor : ReadCursor

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

    # ^Y: focus the CHAIN pane for the marker under the template cursor. Returns a hint
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
        @editor.set_text(updated)
        @editor.place_at_offset(anchor) # back into the marker (set_text reset it) → tooltip stays up
        @dirty = true
      end
      @chain_focused = false
    end

    # Route a key while the CHAIN pane is focused (typing/autocomplete stays; a focus-exit
    # key commits + returns to the template editor).
    def handle_chain_pane_key(ev : Termisu::Event::Key) : Nil
      return if @chain_pane.handle_key(ev)
      key = ev.key
      commit_chain_pane if key.escape? || key.enter? || key.tab? || key.up?
    end

    # "§N" label for the marker under the template cursor (1-based), or "§" when not in one.
    private def marker_label : String
      cur = @editor.cursor_offset
      idx = marker_spans.index { |(a, b)| a <= cur && cur <= b }
      idx ? "§#{idx + 1}" : "§"
    end

    # --- marking -------------------------------------------------------------
    def auto_mark : String
      text = Fuzz::Template.auto_mark(@editor.text)
      @editor.set_text(text)
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

    def pretty_print_template : String?
      text = @editor.text
      env_sep = text.index("\n\n")
      return "no request body" unless env_sep

      head = text[0, env_sep]
      body = text[env_sep + 2..]
      return "request body is empty" if body.strip.empty?

      if formatted_body = Pretty.format_request(head, body)
        new_text = "#{head}\n\n#{formatted_body}"
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
      @editor.set_text(after)
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
      @editor.set_text(Fuzz::Template.clear_markers(@editor.text))
      @dirty = true
      "cleared all § markers"
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
    def stop_requested? : Bool
      @stop_requested
    end

    def request_stop : Nil
      @stop_requested = true
    end

    def begin_run(total : Int64?) : Nil
      @results.clear
      @run_template = @pending_template # freeze the template these results are rendered against
      @results_rev += 1
      # A fresh run reuses result indices from 0, so drop the {pane, index}-keyed detail
      # cache — otherwise an old row's lines could survive under a colliding new index.
      @detail_lines_cache = nil
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
        follow: @config.follow_redirects?, calibrate: @config.auto_calibrate?,
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
      @config.follow_redirects = s.follow
      @config.auto_calibrate = s.calibrate
      @matcher.auto_calibrate = s.calibrate
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
      @matcher.match_regex = @s_m_regex.empty? ? nil : (Regex.new(@s_m_regex) rescue nil)
      @matcher.filter_regex = @s_f_regex.empty? ? nil : (Regex.new(@s_f_regex) rescue nil)
    end

    private def sync_buffers : Nil
      @s_conc = @config.concurrency.to_s
      @s_rate = @config.rps.try(&.to_s) || ""
      @s_timeout = @config.timeout.try(&.total_seconds.to_i.to_s) || ""
      @s_retries = @config.retries.to_s
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
    # Build an engine ready to run, or {nil, error}.
    def build_engine(verify : Bool) : {Fuzz::Engine?, String?}
      commit_buffers
      if err = regex_error
        return {nil, err} # don't silently run match-everything on a bad pattern
      end
      template = Fuzz::Template.parse(Env.expand(@editor.text), @http2)
      @pending_template = template # committed to @run_template in begin_run (see detail_request_bytes)
      return {nil, "mark a position first — ^A params · ^K word"} if template.position_count == 0
      return {nil, "add a payload set — ^O config · + Add set (^L for a List)"} if @sets.empty?
      scheme, host, port = Repeater::FlowRequest.parse_target(Env.expand(@target))
      return {nil, "invalid target — use scheme://host[:port]/path"} if host.empty?
      sets = @sets.map { |s| Fuzz::PayloadSet.new(build_source(s)) }
      gen_sets = @config.mode.per_position? ? sets : [sets.first]
      generator = Fuzz::Generator.new(template, gen_sets, @config, registry: Decoder.shared_registry)
      sender = Fuzz::Sender.new(Fuzz::Origin.new(scheme, host, port),
        http2: @http2, verify: verify, sni: sni_override, timeout: @config.timeout)
      @matcher.auto_calibrate = @config.auto_calibrate?
      {Fuzz::Engine.new(generator, @matcher, sender, @config), nil}
    rescue ex
      {nil, "config error: #{ex.message}"}
    end

    def target_origin : String
      scheme, host, port = Repeater::FlowRequest.parse_target(Env.expand(@target))
      "#{scheme}://#{host}:#{port}"
    end

    private def build_source(s : SetSpec) : Fuzz::PayloadSource
      case s.kind
      when :list    then Fuzz::InlineList.new(s.value.split(','))
      when :file    then Fuzz::WordlistFile.new(s.value)
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
      @detail_scroll = 0
      @detail_xscroll = 0
      @detail_pane = :response
      @detail_cursor.reset
      decode_detail # parse the decoded-protocol panes for the row we're opening
    end

    def detail_cursor_at_top? : Bool
      @detail_cursor.cy == 0 && @detail_scroll == 0
    end

    def detail_move(dr : Int32, dc : Int32, selecting : Bool = false) : Nil
      return unless detail_navigable?
      lines = detail_plain_lines
      return if lines.empty?
      @detail_cursor.move(dr, dc, lines, selecting: selecting)
      ensure_detail_visible(@detail_last_h) if @detail_last_h > 0
    end

    def detail_scroll_view(step : Int32) : Nil
      return unless detail_navigable?
      lines = detail_plain_lines
      return if @detail_last_h <= 0 || lines.size <= @detail_last_h
      max = lines.size - @detail_last_h
      @detail_scroll = (@detail_scroll + step).clamp(0, max)
      lo = @detail_scroll
      hi = {@detail_scroll + @detail_last_h - 1, lines.size - 1}.min
      # Clamp cy into range BEFORE indexing `lines`: while a run streams, a live re-sort
      # (non-index sort) can swap the fixed @sel onto a shorter result, leaving cy stale
      # and larger than the new `lines` — a bare `lines[cy]` would then raise IndexError.
      cy = @detail_cursor.cy.clamp(lo, hi)
      @detail_cursor.sync(cy, @detail_cursor.cx.clamp(0, lines[cy].size))
    end

    def detail_plain_lines : Array(String)
      r = selected_result
      return [] of String unless r
      detail_lines(r)
    end

    def detail_copy_text : String
      lines = detail_plain_lines
      return "" if lines.empty?
      @detail_cursor.selection_text(lines) || @detail_cursor.current_line(lines)
    end

    def detail_copy_all_text : String
      detail_plain_lines.join("\n")
    end

    # Horizontal companion to `detail_scroll` (shift+←/→). Floored at 0 here; the
    # render loop clamps the upper bound to the widest row actually on screen.
    def hscroll_detail(delta : Int32) : Nil
      @detail_xscroll = {@detail_xscroll + delta * 4, 0}.max
    end

    # ←/→ in the RESULT detail: step through the pane chain (request → response →
    # whichever decoded-protocol panes the row carries), clamped — no wrap, so ← past
    # the first / → past the last is a no-op (esc leaves the detail).
    def detail_step_pane(dir : Int32) : Nil
      panes = detail_panes
      i = (panes.index(@detail_pane) || 0) + dir
      return if i < 0 || i >= panes.size
      @detail_pane = panes[i]
      @detail_scroll = 0
      @detail_xscroll = 0
      @detail_cursor.reset
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
      req = detail_request_bytes(r)
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

    private def sorted_results : Array(Fuzz::Result)
      if (c = @sorted_cache) && @sorted_cache_rev == @results_rev &&
         @sorted_cache_sort == @sort && @sorted_cache_matched == @matched_only
        return c
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
      sorted
    end

    # --- target editing ------------------------------------------------------
    def target_insert(ch : Char) : Nil
      @target = "#{@target[0, @tcx]}#{ch}#{@target[@tcx..]}"
      @tcx += 1
      @dirty = true
    end

    def target_backspace : Nil
      return if @tcx == 0
      @target = "#{@target[0, @tcx - 1]}#{@target[@tcx..]}"
      @tcx -= 1
      @dirty = true
    end

    def target_move(d : Int32) : Nil
      @tcx = (@tcx + d).clamp(0, @target.size)
    end

    def target_home : Nil
      @tcx = 0
    end

    def target_end : Nil
      @tcx = @target.size
    end

    def target_read_move(dc : Int32, selecting : Bool = false) : Nil
      return if target_insert?
      cx = @target_read.move_cx(@tcx, dc, @target.size, selecting: selecting)
      @tcx = cx
    end

    def target_copy_text : String
      @target_read.copy_text(@target, @tcx)
    end

    # --- template editing ----------------------------------------------------
    def template_insert(ch : Char) : Nil
      @editor.insert(ch)
      @editor.set_preedit("")
      @dirty = true
    end

    def template_newline : Nil
      @editor.insert_newline
      @dirty = true
    end

    def template_backspace : Nil
      @editor.backspace
      @dirty = true
    end

    def template_move(dr : Int32, dc : Int32) : Nil
      @editor.move(dr, dc)
    end

    # Home/End: caret to line start/end — pure navigation, no dirty.
    def template_home : Nil
      @editor.home
    end

    def template_end : Nil
      @editor.end_of_line
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

    def template_scroll_view(step : Int32) : Nil
      return if template_insert? || chain_pane_active?
      @editor.scroll_view(step)
    end

    def template_copy_text : String
      @template_read.copy_text(@editor)
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
      when :template then !pane_insert?(:template) && @template_read.selection?
      when :target   then !pane_insert?(:target) && @target_read.selection?
      when :detail   then detail_navigable? && @detail_cursor.selection?
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
        lines = detail_plain_lines
        return if lines.empty?
        @detail_cursor.select_line(lines)
        ensure_detail_visible(@detail_last_h) if @detail_last_h > 0
      end
    end

    def pane_clear_selection : Nil
      case @focus
      when :template then @template_read.clear_selection
      when :target   then @target_read.clear_selection
      when :detail   then @detail_cursor.clear_selection
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
          j.field "follow", @config.follow_redirects?
          j.field "calibrate", @config.auto_calibrate?
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
      @config.follow_redirects = obj["follow"]?.try(&.as_bool?) || false
      @config.auto_calibrate = obj["calibrate"]?.try(&.as_bool?) || false
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
      target_h = {rect.h, 3}.min
      render_target(screen, Rect.new(rect.x, rect.y, rect.w, target_h), focused && @focus == :target)
      rest = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
      return if rest.h <= 0
      top_h = {rest.h * 45 // 100, 5}.max
      top_h = rest.h if rest.h < 6
      top = Rect.new(rest.x, rest.y, rest.w, top_h)
      bottom = Rect.new(rest.x, rest.y + top_h, rest.w, {rest.h - top_h, 0}.max)
      render_top(screen, top, focused)
      render_bottom(screen, bottom, focused) if bottom.h > 0
      render_chain_overlay(screen, rect) if @chain_focused # centered ^Y modal ON TOP (replaces the old split)
    end

    private def render_top(screen : Screen, rect : Rect, focused : Bool) : Nil
      half = {(rect.w - 1) // 2, 1}.max
      left = Rect.new(rect.x, rect.y, half, rect.h)
      right = Rect.new(rect.x + half + 1, rect.y, {rect.w - half - 1, 0}.max, rect.h)
      tmpl_focused = focused && @focus == :template
      render_template(screen, left, tmpl_focused && !@chain_focused) # dimmed while the ^Y modal owns focus
      render_config(screen, right, focused && @focus == :config)
    end

    # The ^Y chain editor modal over the whole tab, bound to the marker the cursor sat in
    # when ^Y was pressed. Shows the value, the editable chain, and a live transform
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

    private def pane_border(focused : Bool, insert : Bool = false) : Color
      return Frame.pane_border(false) unless focused
      insert ? Theme.accent : Theme.focus_gold
    end

    private def render_mode_badge(screen : Screen, right_edge : Int32, y : Int32, min_x : Int32, insert : Bool) : Nil
      if insert
        Frame.toggle_badge(screen, right_edge, y, min_x, "i", "INS", true)
      else
        x = right_edge - " NOR ".size
        screen.text(x, y, " NOR ", Theme.muted, Theme.bg) if x >= min_x
      end
    end

    private def render_target(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.h < 2
      ins = focused && target_insert?
      Frame.card(screen, rect, "TARGET", bg: Theme.bg, border: pane_border(focused, insert: ins))
      render_mode_badge(screen, rect.right - 1, rect.y, rect.x + 8, ins)
      unless @sni.strip.empty?
        badge = " SNI "
        bx = {rect.right - badge.size - 1, rect.x + 9}.max
        screen.text(bx, rect.y, badge, Theme.text_bright, Theme.accent_bg)
      end
      base = rect.x + 4
      screen.text(rect.x + 2, rect.y + 1, "›", focused ? Theme.accent : Theme.muted)
      tw = {rect.right - base - 1, 1}.max
      if focused && !ins
        if span = @target_read.selection_span(@tcx)
          paint_char_span_bg(screen, base, rect.y + 1, @target, span[0], span[1], Theme.accent_bg)
        end
      end
      Highlight.draw(screen, base, rect.y + 1, Highlight.env_line(@target, Theme.text_bright), width: tw)
      if focused
        cx = base + Screen.display_width(@target[0, @tcx])
        if cx < rect.right - 1
          ch = @tcx < @target.size ? @target[@tcx] : ' '
          screen.cell(cx, rect.y + 1, ch, Theme.bg, ins ? Theme.accent : Theme.accent_bg)
          screen.cursor(cx, rect.y + 1)
        end
      end
    end

    private def render_template(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      spans = marker_spans
      pc = spans.size
      label = @http2 ? "TEMPLATE (h2)" : "TEMPLATE"
      ins = focused && (template_insert? || @chain_focused)
      Frame.card(screen, rect, label, bg: Theme.bg, border: pane_border(focused, insert: ins))
      badge = " §#{pc} "
      min_x = rect.x + label.size + 4
      # ^R:RUN rides the TEMPLATE border as the primary action — rightmost, mirroring the
      # Repeater's ^R:SEND so the muscle memory transfers. A gold button while idle, recessed
      # while a run streams (^X stops it). The old CONFIG "Run" row is gone; the request-count
      # estimate stays there as a passive summary (render_run_summary).
      run_x = Frame.action_badge(screen, rect.right - 1, rect.y, min_x, "^R", "RUN", !running?)
      pretty_x = Frame.toggle_badge(screen, run_x, rect.y, min_x, "^U", "PRETTY", false)
      render_mode_badge(screen, pretty_x, rect.y, min_x, ins)
      screen.text({pretty_x - badge.size, min_x}.max, rect.y, badge,
        pc > 0 ? Theme.text_bright : Theme.muted, pc > 0 ? Theme.accent_bg : Theme.bg)
      # Marker i ↔ position i ↔ generator.set_for(i). The value gets the position hue; a
      # trailing ¦chain (Decoder transform-on-send) is over-painted with a neutral band so
      # it reads as metadata, not payload. Colours resolved fresh each frame (offsets are
      # colour-free); marker_regions is 1:1 with `spans`, so the config chips stay in sync.
      bg = [] of {Int32, Int32, Color}
      conceal = [] of {Int32, Int32}
      marker_regions.each_with_index do |region, i|
        a, sep, close = region
        bg << {a, close + 1, Theme.marker_bg(i)} # band spans the whole marker; the conceal-aware paint skips hidden cells
        conceal << {sep, close} if sep < close   # hide the ¦chain inline (kept in the buffer → tooltip + ^Y overlay)
      end
      @editor.bg_regions = bg
      @editor.conceal_spans = conceal
      chain = chain_under_cursor
      @editor.chain_peek_text = (chain && !chain.empty?) ? chain : nil # tooltip only for a concealed (non-empty) chain
      inner = rect.inset(1, 1)
      read_active = focused && !ins
      @editor.render(screen, inner, cursor: ins, highlight: :request, peek: focused)
      paint_template_read_chrome(screen, inner, read_active)
    end

    private def paint_template_read_chrome(screen : Screen, rect : Rect, active : Bool) : Nil
      return unless active
      lines = @editor.lines_snapshot
      return if lines.empty?
      @template_read.sync_from(@editor)
      sel_bg = Theme.accent_bg
      scr = @editor.scroll
      @template_read.cursor.highlight_spans(lines).each do |(li, x0, x1)|
        next unless li >= scr && li < scr + rect.h
        row = li - scr
        gw = @editor.gutter? ? Gutter.width(lines.size) : 0
        paint_char_span_bg(screen, rect.x + gw, rect.y + row, lines[li], x0, x1, sel_bg)
      end
      cy, cx = @editor.cy, @editor.cx
      return unless cy >= scr && cy < scr + rect.h
      row = cy - scr
      gw = @editor.gutter? ? Gutter.width(lines.size) : 0
      line = lines[cy]
      px = rect.x + gw + Screen.column_width(line[0, cx])
      if px < rect.x + rect.w
        ch = cx < line.size ? line[cx] : ' '
        screen.cell(px, rect.y + row, ch, Theme.bg, Theme.accent_bg)
        screen.cursor(px, rect.y + row)
      end
    end

    private def paint_char_span_bg(screen : Screen, x : Int32, y : Int32, line : String,
                                   x0 : Int32, x1 : Int32, bg : Color) : Nil
      return if x0 >= x1
      px = x
      (0...x0).each { |i| px += Screen.column_width(line[i].to_s) } if x0 > 0
      (x0...x1).each do |i|
        break if i >= line.size
        w = Screen.column_width(line[i].to_s)
        screen.text(px, y, line[i].to_s, Theme.text, bg)
        px += w
      end
    end

    private def ensure_detail_visible(view_h : Int32) : Nil
      return if view_h <= 0
      cy = @detail_cursor.cy
      if cy < @detail_scroll
        @detail_scroll = cy
      elsif cy >= @detail_scroll + view_h
        @detail_scroll = cy - view_h + 1
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
      tail_top = {inner.bottom - 3, inner.y + 1}.max
      render_sets(screen, inner, inner.y + 1, focused, tail_top)
      render_mode_row(screen, inner, tail_top, focused)
      render_advanced_row(screen, inner, tail_top + 1, focused)
      render_run_summary(screen, inner, tail_top + 2)
    end

    # Payload-set rows within [y0, limit), followed by the "+ Add payload set…" row.
    # `limit` is the first row the bottom tail occupies, so sets never overwrite it.
    private def render_sets(screen, inner : Rect, y0 : Int32, focused : Bool, limit : Int32) : Nil
      pp = @config.mode.per_position? # set i → marker i (Pitchfork/ClusterBomb)
      avail = {limit - y0, 1}.max
      if @sets.empty?
        screen.text(inner.x + 1, y0, "(no sets yet)", Theme.muted, Theme.bg) if y0 < limit
        draw_add_row(screen, inner, {y0 + 1, limit - 1}.min, focused)
        return
      end
      set_rows = {avail - 1, 1}.max # reserve the last available row for the Add row
      if @sets.size <= set_rows
        @cfg_scroll = 0
        y = y0
        @sets.each_with_index do |s, i|
          render_set_row(screen, inner, y, s, i, set_selected?(focused, i), pp)
          y += 1
        end
        draw_add_row(screen, inner, y, focused)
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
          render_set_row(screen, inner, y, @sets[i], i, set_selected?(focused, i), pp)
          y += 1
        end
        above, below = @cfg_scroll, @sets.size - stop
        hint = above > 0 && below > 0 ? "… #{above} above · #{below} below" : (above > 0 ? "… #{above} above" : "… +#{below} more")
        screen.text(inner.x + 1, y, hint, Theme.muted, Theme.bg)
        draw_add_row(screen, inner, y + 1, focused)
      end
    end

    private def set_selected?(focused : Bool, i : Int32) : Bool
      focused && config_row == :set && current_set_index == i
    end

    private def draw_add_row(screen, inner : Rect, y : Int32, focused : Bool) : Nil
      return if y >= inner.bottom
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
      return if text.empty?
      screen.text(inner.x, y, text, Theme.muted, Theme.bg, width: {inner.w, 1}.max)
    end

    # One Sets row. In per-position modes (pp) it carries a marker-coloured swatch + →N
    # chip tying it to template marker i (same tint marker i shows in the editor); the
    # chip draws AFTER the selection fill so it survives on the selected (accent_bg) row.
    private def render_set_row(screen, inner : Rect, y : Int32, s : SetSpec, i : Int32, sel : Bool, pp : Bool) : Nil
      bg = sel ? Theme.accent_bg : Theme.bg
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

    private def render_results(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "RESULTS", bg: Theme.bg, border: Frame.pane_border(focused))
      # Left: the live count. Right: keyed toggle badges (sort value · matched · dist) so
      # each results toggle's shortcut rides the border, not just the bottom hint bar.
      count = if @running
                p = @progress
                "running #{p ? p.sent : 0}/#{@run_total || "?"} · #{matched_count} hit"
              else
                "#{result_count} sent · #{matched_count} hit"
              end
      screen.text(rect.x + 11, rect.y, count, Theme.muted, Theme.bg) # +11 clears the " RESULTS " title
      min_x = rect.x + 11 + count.size + 1                           # badges never overwrite the count
      rx = Frame.toggle_badge(screen, rect.right - 1, rect.y, min_x, "v", "DIST", @show_dist)
      rx = Frame.toggle_badge(screen, rx, rect.y, min_x, "m", "MATCH", @matched_only)
      Frame.toggle_badge(screen, rx, rect.y, min_x, "o", @sort.to_s, false) # sort: a value chip, never lit
      inner = rect.inset(1, 1)
      view = sorted_results
      @sel = @sel.clamp(0, {view.size - 1, 0}.max)
      adjust_scroll(inner.h)
      header = "  #   payload                 status  len      words   time"
      screen.text(inner.x, inner.y, header, Theme.muted, Theme.bg, width: inner.w)
      rows_h = {inner.h - 1, 0}.max
      (0...rows_h).each do |i|
        ri = @scroll + i
        break if ri >= view.size
        render_result_row(screen, inner, inner.y + 1 + i, view[ri], ri == @sel)
      end
      if view.empty?
        body = Rect.new(inner.x, inner.y + 1, inner.w, {inner.h - 1, 0}.max)
        TrafficEmptyState.render(screen, body, variant: :fuzzer_results, running: @running)
      end
    end

    private def render_result_row(screen : Screen, inner : Rect, y : Int32, r : Fuzz::Result, selected : Bool) : Nil
      bg = selected ? Theme.accent_bg : Theme.bg
      screen.fill(Rect.new(inner.x, y, inner.w, 1), bg) if selected
      screen.cell(inner.x, y, selected ? '▎' : (r.matched? ? '✓' : ' '), r.matched? ? Theme.accent : Theme.muted, bg)
      payload = r.payloads.join(", ")
      line = "#{r.index.to_s.ljust(4)} #{payload.size > 22 ? "#{payload[0, 21]}…" : payload.ljust(22)}"
      x = screen.text(inner.x + 2, y, line, selected ? Theme.text_bright : Theme.text, bg)
      sc = r.status.try(&.to_s) || (r.error ? "ERR" : "—")
      x = screen.text(x + 1, y, sc.ljust(7), status_color(r), bg)
      screen.text(x, y, "#{Fmt.size(r.length).ljust(8)} #{r.words.to_s.ljust(7)} #{Fmt.dur(r.duration_us)}", selected ? Theme.text : Theme.muted, bg, width: {inner.right - x, 1}.max)
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
        TrafficEmptyState.render(screen, inner, variant: :fuzzer_results, running: @running)
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
      lens = [] of Int64
      words = [] of Int32
      times = [] of Int64
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
      DistData.new(
        codes: codes.to_a.sort_by!(&.[0]), err: err,
        len_hist: Spark.histogram(lens, w), len_min: (lens.min? || 0_i64), len_max: (lens.max? || 0_i64),
        words_hist: Spark.histogram(words, w), words_min: (words.min? || 0), words_max: (words.max? || 0),
        time_hist: Spark.histogram(times, w), time_min: (times.min? || 0_i64), time_max: (times.max? || 0_i64),
      )
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
      Frame.card(screen, rect, "RESULT ##{r.index}", bg: Theme.bg, border: pane_border(focused))
      panes = detail_panes
      @detail_pane = :request unless panes.includes?(@detail_pane) # decode may have dropped a pane
      render_detail_chips(screen, rect, panes)
      inner = rect.inset(1, 1)
      lines = detail_lines(r)
      styled = detail_styled(r, lines)
      @detail_last_h = inner.h
      ensure_detail_visible(inner.h) if focused
      @detail_scroll = @detail_scroll.clamp(0, {lines.size - inner.h, 0}.max)
      gw = {Gutter.width(lines.size), inner.w}.min
      cw = {inner.w - gw, 0}.max
      rows = (0...inner.h).compact_map { |i| lines[@detail_scroll + i]? }
      @detail_xscroll = @detail_xscroll.clamp(0, {(rows.max_of? { |l| Screen.display_width_upto(l, @detail_xscroll + cw + 1) } || 0) - cw, 0}.max)
      rows.each_with_index do |line, i|
        li = @detail_scroll + i
        Gutter.draw(screen, inner.x, inner.y + i, li, gw, current: focused && li == @detail_cursor.cy)
        # Draw the styled overlay; the plain `line` still drives the cursor/selection chrome.
        sline = styled[li]? || [Highlight::Span.new(line, Theme.text)]
        sline = Highlight.slice_left(sline, @detail_xscroll) if @detail_xscroll > 0
        Highlight.draw(screen, inner.x + gw, inner.y + i, sline, bg: Theme.bg, width: cw)
        paint_detail_line_chrome(screen, inner.x + gw, inner.y + i, li, line, focused, lines)
      end
    end

    private def paint_detail_line_chrome(screen : Screen, x : Int32, y : Int32, li : Int32, line : String,
                                         focused : Bool, lines : Array(String)) : Nil
      return unless focused && detail_navigable?
      @detail_cursor.highlight_spans(lines).each do |(l, x0, x1)|
        paint_char_span_bg(screen, x, y, line, x0, x1, Theme.accent_bg) if l == li
      end
      return unless li == @detail_cursor.cy
      cx = @detail_cursor.cx.clamp(0, line.size)
      px = x + Screen.column_width(line[0, cx])
      ch = cx < line.size ? line[cx] : ' '
      screen.cell(px, y, ch, Theme.bg, Theme.accent_bg)
      screen.cursor(px, y)
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

    # The reconstructed wire request for a result (template with its payloads spliced in).
    private def detail_request_bytes(r : Fuzz::Result) : Bytes
      # Render against the run's frozen template (env-expanded, as sent) so a post-run
      # edit to the live buffer can't truncate/garble the reconstructed request.
      tmpl = @run_template || Fuzz::Template.parse(Env.expand(@editor.text), @http2)
      tmpl.render(r.payloads)
    end

    private def detail_request_lines(r : Fuzz::Result) : Array(String)
      String.new(detail_request_bytes(r)).scrub.split('\n').map(&.rstrip('\r'))
    end

    private def detail_response_lines(r : Fuzz::Result) : Array(String)
      head = r.head
      return ["(response not retained — only matched results keep the response)"] unless head
      body = r.body
      lines = String.new(head).scrub.split('\n').map(&.rstrip('\r'))
      if body && !body.empty?
        lines << ""
        lines.concat(String.new(body).scrub.split('\n').map(&.rstrip('\r')))
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
    def target_click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless @loaded
      base = rect.x + 4
      @tcx = Screen.column_for(@target, mx - base)
    end

    # Mouse: place the TEMPLATE editor caret at a click. Re-derives the template
    # half-pane exactly as render/render_top do (target band → 45%-tall top row →
    # left half → the card's 1-cell inset), so the caret lands where the click points.
    def template_click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless @loaded
      target_h = {rect.h, 3}.min
      rest = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
      return if rest.h <= 0
      top_h = {rest.h * 45 // 100, 5}.max
      top_h = rest.h if rest.h < 6
      half = {(rest.w - 1) // 2, 1}.max
      left = Rect.new(rest.x, rest.y, half, top_h)
      commit_chain_pane if @chain_focused # a click outside the ^Y modal commits + dismisses it
      @editor.click_to_cursor(left.inset(1, 1), mx, my)
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

    # The RESULTS pane rect within body `rect`, re-deriving render → render_bottom →
    # render_results' split (target band → 45%-tall top row → bottom minus the DIST
    # sidebar). nil when the layout leaves no room. Backs results_row_at hit-testing.
    private def results_rect(rect : Rect) : Rect?
      return nil unless @loaded
      target_h = {rect.h, 3}.min
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
      count = if @running
                p = @progress
                "running #{p ? p.sent : 0}/#{@run_total || "?"} · #{matched_count} hit"
              else
                "#{result_count} sent · #{matched_count} hit"
              end
      min_x = pane.x + 11 + count.size + 1
      Frame.right_badge_hit(mx, my, pane.y, pane.right - 1, min_x, [
        {:dist, "v", "DIST"},
        {:match, "m", "MATCH"},
        {:sort, "o", @sort.to_s},
      ] of {Symbol, String, String})
    end

    # Hit-test the TEMPLATE border's ^R:RUN badge (rightmost, drawn by render_template).
    # Returns :run when the click lands on it, else nil (caller falls through to caret/focus).
    # Geometry mirrors render → render_top's left-column top border; the CHAIN split hangs
    # below, so the border row is unaffected by whether the strip is shown.
    def template_chrome_hit(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil unless @loaded
      target_h = {rect.h, 3}.min
      rest = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
      return nil if rest.h <= 0
      top_h = {rest.h * 45 // 100, 5}.max
      top_h = rest.h if rest.h < 6
      half = {(rest.w - 1) // 2, 1}.max
      left = Rect.new(rest.x, rest.y, half, top_h)
      return nil if left.w < 2 || my != left.y
      label = @http2 ? "TEMPLATE (h2)" : "TEMPLATE"
      min_x = left.x + label.size + 4
      Frame.right_badge_hit(mx, my, left.y, left.right - 1, min_x, [
        {:run, "^R", "RUN"},
      ] of {Symbol, String, String})
    end

    def pane_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil unless @loaded && rect.contains?(mx, my)
      target_h = {rect.h, 3}.min
      return :target if my < rect.y + target_h
      rest = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
      return nil if rest.h <= 0
      top_h = {rest.h * 45 // 100, 5}.max
      top_h = rest.h if rest.h < 6
      if my < rest.y + top_h
        half = {(rest.w - 1) // 2, 1}.max
        mx < rest.x + half ? :template : :config
      elsif @focus == :detail
        :detail
      else
        vw = @show_dist ? dist_width(rest.w) : 0
        vw > 0 && mx >= rest.x + rest.w - vw ? nil : :results # read-only DIST sidebar → no-op
      end
    end
  end
end
