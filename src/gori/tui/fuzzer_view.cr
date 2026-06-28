require "json"
require "./screen"
require "./theme"
require "./frame"
require "./text_area"
require "./fmt"
require "./spark"
require "../store"
require "../fuzz"
require "../fuzzy"
require "../paths"
require "../replay/flow_request"

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

    record SetSpec, kind : Symbol, value : String

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
      @config = Fuzz::Config.new(keep_bodies: :matched)
      @sets = [] of SetSpec
      @matcher = Fuzz::Matcher.new(keep_bodies: :matched)
      # CONFIG form state — a navigable field form (no command line). @cfg_field is
      # the flat field cursor (↑/↓), @cfg_caret the caret in the focused text field.
      @cfg_field = 0
      @cfg_caret = 0
      @cfg_scroll = 0
      @show_advanced = false            # Engine/Opts/Match/Filter collapsed by default
      @path_complete = PathComplete.new # wordlist path inline auto-complete
      @ptype = :list                    # selected payload-type tab
      @s_conc = "20"                    # engine numeric fields are edited as string buffers, committed
      @s_rate = ""                      # to @config at build/persist time (so a field can be cleared)
      @s_timeout = ""
      @s_retries = "0"
      @s_m_regex = "" # regex fields buffered as source strings, compiled on commit
      @s_f_regex = ""
      @p_values = "" # payload-type draft fields (the input for the selected tab)
      @p_from = "1"
      @p_to = "100"
      @p_step = "1"
      @p_path = ""
      @p_count = "10"
      @p_charset = "abc"
      @p_min = "1"
      @p_max = "3"
      @results = [] of Fuzz::Result
      @results_rev = 0_i64 # bumped on every @results mutation — the DIST cache key
      @sel = 0
      @scroll = 0
      @sort = :index
      @matched_only = false
      # §-region offsets, recomputed only when the buffer changes (keyed on @editor.edits).
      # Backs BOTH the template tint colours and the Sets→marker chips, so they can't disagree.
      @marker_text_rev = -1
      @marker_spans = [] of {Int32, Int32}
      @show_dist = true # the DIST sidebar beside RESULTS (toggled with `v`)
      @dist_cache = nil.as(DistData?)
      @dist_cache_rev = -1_i64
      @dist_cache_w = -1
      @progress = nil.as(Fuzz::Progress?)
      @run_total = nil.as(Int64?)
      @stop_requested = false
      @detail_scroll = 0
      @detail_pane = :response
      @focus = :template
      @loaded = false
      @dirty = false
      @running = false
    end

    # --- loading -------------------------------------------------------------
    def load(detail : Store::FlowDetail) : Nil
      built = Replay::FlowRequest.build(detail)
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
    # ReplayView#load_blank; the ⇧I/from-Replay paths keep template focus since their
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
      @focus = :template
      @loaded = true
      @dirty = false
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

    # --- focus ring ----------------------------------------------------------
    def focus_first : Nil
      @focus = :target
    end

    def focus_last : Nil
      @focus = :results
    end

    def focus_pane(pane : Symbol) : Nil
      @focus = pane if PANE_ORDER.includes?(pane)
    end

    def focus_config : Nil
      @focus = :config
      @cfg_field = 0 # land straight on the payload type tabs
      @cfg_caret = 0
      @path_complete.close
    end

    def pane_advance(dir : Int32) : Bool
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
      case @focus
      when :target   then true
      when :template then @editor.at_top?
      when :config   then @cfg_field == 0
      when :results  then @sel == 0
      else                false
      end
    end

    def set_preedit(text : String) : Nil
      @editor.set_preedit(text) if @focus == :template
    end

    # --- marking -------------------------------------------------------------
    def auto_mark : String
      text = Fuzz::Template.auto_mark(@editor.text)
      @editor.set_text(text)
      @dirty = true
      n = Fuzz::Template.parse(text).position_count
      "auto-marked #{n} position#{n == 1 ? "" : "s"}"
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
      @editor.set_text(@editor.text.gsub("§", ""))
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

    # --- run lifecycle -------------------------------------------------------
    def stop_requested? : Bool
      @stop_requested
    end

    def request_stop : Nil
      @stop_requested = true
    end

    def begin_run(total : Int64?) : Nil
      @results.clear
      @results_rev += 1
      @sel = 0
      @scroll = 0
      @running = true
      @stop_requested = false
      @run_total = total
      @progress = Fuzz::Progress.new(0_i64, total, 0_i64, 0_i64)
    end

    def finish_run : Nil
      @running = false
    end

    def apply_progress(p : Fuzz::Progress) : Nil
      @progress = p
    end

    def append_result(r : Fuzz::Result) : Nil
      @results << r
      @results.shift if @results.size > RESULT_CAP
      @results_rev += 1 # grow AND ring-evict both bump (size is pinned once full)
    end

    def matched_count : Int32
      @results.count(&.matched?)
    end

    def result_count : Int32
      @results.size
    end

    # --- config form ---------------------------------------------------------
    # The cursor (@cfg_field, ↑/↓) walks an ordered field list split around the
    # variable-length @sets rows: HEAD (payload type + its draft fields + add)
    # comes first so entering CONFIG lands straight on the payload; the @sets rows
    # sit in the MIDDLE (the `:set` pseudo-field); TAIL (mode + the collapsible
    # `▸ Advanced` toggle, then Engine/Opts/Match/Filter only when expanded) is last.
    ADVANCED_FIELDS = [:conc, :rate, :timeout, :retries, :follow, :calibrate,
                       :m_status, :m_size, :m_words, :m_regex,
                       :f_status, :f_size, :f_words, :f_regex]

    def config_field : Symbol
      current_field
    end

    private def head_fields : Array(Symbol)
      [:ptype] + ptype_fields + [:add]
    end

    private def tail_fields : Array(Symbol)
      @show_advanced ? [:mode, :advanced] + ADVANCED_FIELDS : [:mode, :advanced]
    end

    private def ptype_fields : Array(Symbol)
      case @ptype
      when :numbers  then [:p_from, :p_to, :p_step]
      when :wordlist then [:p_path]
      when :null     then [:p_count]
      when :brute    then [:p_charset, :p_min, :p_max]
      else                [:p_values]
      end
    end

    private def field_count : Int32
      head_fields.size + @sets.size + tail_fields.size
    end

    private def current_field : Symbol
      h = head_fields.size
      return head_fields[@cfg_field] if @cfg_field < h
      return :set if @cfg_field < h + @sets.size
      tail_fields[@cfg_field - h - @sets.size]? || :mode # `|| :mode` guards a stale index
    end

    private def current_set_index : Int32
      @cfg_field - head_fields.size
    end

    # ↑/↓ — move the field cursor (caret resets to the end of the new field).
    def form_move(d : Int32) : Nil
      @cfg_field = (@cfg_field + d).clamp(0, {field_count - 1, 0}.max)
      @cfg_caret = field_text(current_field).size
      sync_path_complete
    end

    # ←/→ — cycle an enum/toggle, else move the text caret.
    def form_adjust(d : Int32) : Nil
      case current_field
      when :mode      then cycle_mode(d)
      when :ptype     then cycle_ptype(d)
      when :advanced  then toggle_advanced
      when :follow    then @config.follow_redirects = !@config.follow_redirects?; @dirty = true
      when :calibrate then toggle_calibrate
      else                 @cfg_caret = (@cfg_caret + d).clamp(0, field_text(current_field).size)
      end
    end

    # ⏎ — Add field appends the set, Advanced toggles the block, else step down.
    def form_enter : Nil
      case current_field
      when :add      then add_current_set
      when :advanced then toggle_advanced
      else                form_move(1)
      end
    end

    def form_delete : Nil
      remove_set(current_set_index) if current_field == :set
    end

    # ⌫ — delete a char in a text field, or remove the focused set row.
    def form_backspace : Nil
      if current_field == :set
        remove_set(current_set_index)
      elsif text_field?(current_field) && @cfg_caret > 0
        s = field_text(current_field)
        field_set(current_field, "#{s[0, @cfg_caret - 1]}#{s[@cfg_caret..]}")
        @cfg_caret -= 1
        @dirty = true
        @path_complete.refresh(@p_path) if current_field == :p_path
      end
    end

    def form_type(ch : Char) : Nil
      return unless text_field?(current_field)
      s = field_text(current_field)
      field_set(current_field, "#{s[0, @cfg_caret]}#{ch}#{s[@cfg_caret..]}")
      @cfg_caret += 1
      @dirty = true
      @path_complete.refresh(@p_path) if current_field == :p_path
    end

    # Keep the wordlist path popup in lockstep with the cursor: open/refresh while
    # the :p_path field is focused, close on any other field.
    private def sync_path_complete : Nil
      current_field == :p_path ? @path_complete.refresh(@p_path) : @path_complete.close
    end

    # --- wordlist path completion (mirrors Convert's ChainComplete contract) -----
    # True while the popup owns Tab/Enter/↑/↓/Esc — the runner's pre-ring guard routes
    # those keys here (via the controller) before the focus ring claims Tab.
    def path_completing? : Bool
      @focus == :config && current_field == :p_path && @path_complete.open?
    end

    def path_complete_move(d : Int32) : Nil
      @path_complete.move(d)
    end

    def path_complete_close : Nil
      @path_complete.close
    end

    # Apply the highlighted completion: replace the field, jump the caret to the end,
    # keep the popup open + drill on a directory, close on a file.
    def path_complete_accept : Nil
      res = @path_complete.accept || return
      @p_path, is_dir = res
      @cfg_caret = @p_path.size
      @dirty = true
      is_dir ? @path_complete.refresh(@p_path) : @path_complete.close
    end

    private def cycle_mode(d : Int32) : Nil
      modes = [Fuzz::Mode::Sniper, Fuzz::Mode::BatteringRam, Fuzz::Mode::Pitchfork, Fuzz::Mode::ClusterBomb]
      i = modes.index(@config.mode) || 0
      @config.mode = modes[(i + d) % modes.size]
      @dirty = true
    end

    private def cycle_ptype(d : Int32) : Nil
      types = [:list, :numbers, :wordlist, :null, :brute]
      i = types.index(@ptype) || 0
      @ptype = types[(i + d) % types.size]
      @cfg_caret = 0
      sync_path_complete # cursor stays on :ptype → closes a stale wordlist popup
    end

    private def toggle_calibrate : Nil
      on = !@config.auto_calibrate?
      @config.auto_calibrate = on
      @matcher.auto_calibrate = on
      @dirty = true
    end

    # Collapse/expand the Advanced block. Pure UI state — NO @dirty (mirrors
    # cycle_ptype); re-clamp the cursor since tail_fields just shrank/grew.
    private def toggle_advanced : Nil
      @show_advanced = !@show_advanced
      @cfg_field = @cfg_field.clamp(0, {field_count - 1, 0}.max)
    end

    private def add_current_set : Nil
      return unless spec = draft_spec
      @sets << spec
      @dirty = true
    end

    # Build a SetSpec from the selected payload type's draft fields (nil if blank).
    private def draft_spec : SetSpec?
      case @ptype
      when :list     then @p_values.strip.empty? ? nil : SetSpec.new(:list, @p_values.strip)
      when :numbers  then SetSpec.new(:numbers, "#{num(@p_from)}-#{num(@p_to)}:#{num(@p_step, 1)}")
      when :wordlist then @p_path.strip.empty? ? nil : SetSpec.new(:file, @p_path.strip)
      when :null     then SetSpec.new(:null, num(@p_count, 1).to_s)
      when :brute    then @p_charset.strip.empty? ? nil : SetSpec.new(:brute, "#{@p_charset.strip}:#{num(@p_min, 1)}-#{num(@p_max, 1)}")
      end
    end

    private def num(s : String, default : Int32 = 0) : Int32
      s.to_i? || default
    end

    private def remove_set(i : Int32) : Nil
      return unless 0 <= i < @sets.size
      @sets.delete_at(i)
      @cfg_field = @cfg_field.clamp(0, {field_count - 1, 0}.max)
      @dirty = true
    end

    private def text_field?(f : Symbol) : Bool
      case f
      when :mode, :ptype, :follow, :calibrate, :add, :set, :advanced then false
      else                                                                true
      end
    end

    private def field_text(f : Symbol) : String
      engine_text(f) || matcher_text(f) || payload_text(f) || ""
    end

    private def engine_text(f : Symbol) : String?
      case f
      when :conc    then @s_conc
      when :rate    then @s_rate
      when :timeout then @s_timeout
      when :retries then @s_retries
      when :m_regex then @s_m_regex
      when :f_regex then @s_f_regex
      end
    end

    private def matcher_text(f : Symbol) : String?
      case f
      when :m_status then @matcher.match_status
      when :m_size   then @matcher.match_size
      when :m_words  then @matcher.match_words
      when :f_status then @matcher.filter_status
      when :f_size   then @matcher.filter_size
      when :f_words  then @matcher.filter_words
      end
    end

    private def payload_text(f : Symbol) : String?
      case f
      when :p_values  then @p_values
      when :p_from    then @p_from
      when :p_to      then @p_to
      when :p_step    then @p_step
      when :p_path    then @p_path
      when :p_count   then @p_count
      when :p_charset then @p_charset
      when :p_min     then @p_min
      when :p_max     then @p_max
      end
    end

    private def field_set(f : Symbol, s : String) : Nil
      engine_set(f, s) || matcher_set(f, s) || payload_set(f, s)
    end

    private def engine_set(f : Symbol, s : String) : Bool
      case f
      when :conc    then @s_conc = s
      when :rate    then @s_rate = s
      when :timeout then @s_timeout = s
      when :retries then @s_retries = s
      when :m_regex then @s_m_regex = s
      when :f_regex then @s_f_regex = s
      else               return false
      end
      true
    end

    private def matcher_set(f : Symbol, s : String) : Bool
      case f
      when :m_status then @matcher.match_status = blank_nil(s)
      when :m_size   then @matcher.match_size = blank_nil(s)
      when :m_words  then @matcher.match_words = blank_nil(s)
      when :f_status then @matcher.filter_status = blank_nil(s)
      when :f_size   then @matcher.filter_size = blank_nil(s)
      when :f_words  then @matcher.filter_words = blank_nil(s)
      else                return false
      end
      true
    end

    private def payload_set(f : Symbol, s : String) : Bool
      case f
      when :p_values  then @p_values = s
      when :p_from    then @p_from = s
      when :p_to      then @p_to = s
      when :p_step    then @p_step = s
      when :p_path    then @p_path = s
      when :p_count   then @p_count = s
      when :p_charset then @p_charset = s
      when :p_min     then @p_min = s
      when :p_max     then @p_max = s
      else                 return false
      end
      true
    end

    private def blank_nil(s : String) : String?
      s.empty? ? nil : s
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
      template = Fuzz::Template.parse(@editor.text, @http2)
      return {nil, "mark a position first — ^A params · ^K word"} if template.position_count == 0
      return {nil, "add a payload set — ^O config · pick a type · ⏎ add"} if @sets.empty?
      scheme, host, port = Replay::FlowRequest.parse_target(@target)
      return {nil, "invalid target"} if host.empty?
      sets = @sets.map { |s| Fuzz::PayloadSet.new(build_source(s)) }
      gen_sets = @config.mode.per_position? ? sets : [sets.first]
      generator = Fuzz::Generator.new(template, gen_sets, @config)
      sender = Fuzz::Sender.new(Fuzz::Origin.new(scheme, host, port),
        http2: @http2, verify: verify, sni: sni_override, timeout: @config.timeout)
      @matcher.auto_calibrate = @config.auto_calibrate?
      {Fuzz::Engine.new(generator, @matcher, sender, @config), nil}
    rescue ex
      {nil, "config error: #{ex.message}"}
    end

    def target_origin : String
      scheme, host, port = Replay::FlowRequest.parse_target(@target)
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
      from, _, to = range.partition('-')
      Fuzz::NumberRange.new(from.to_i64? || 0_i64, to.to_i64? || 0_i64, step.to_i64? || 1_i64)
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
      @detail_pane = :response
    end

    def detail_scroll(d : Int32) : Nil
      @detail_scroll = {@detail_scroll + d, 0}.max
    end

    def detail_toggle_pane : Nil
      @detail_pane = @detail_pane == :response ? :request : :response
      @detail_scroll = 0
    end

    def selected_result : Fuzz::Result?
      sorted_results[@sel]?
    end

    private def sorted_results : Array(Fuzz::Result)
      rows = @matched_only ? @results.select(&.matched?) : @results
      case @sort
      when :status then rows.sort_by { |r| r.status || -1 }
      when :length then rows.sort_by(&.length)
      when :words  then rows.sort_by(&.words)
      when :time   then rows.sort_by(&.duration_us)
      else              rows
      end
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
        screen.text(rect.x + 1, rect.y, "no request loaded", Theme.muted)
        screen.text(rect.x + 1, rect.y + 2, "select a flow in History/Replay and press ⇧I to send it here", Theme.muted)
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
    end

    private def render_top(screen : Screen, rect : Rect, focused : Bool) : Nil
      half = {(rect.w - 1) // 2, 1}.max
      left = Rect.new(rect.x, rect.y, half, rect.h)
      right = Rect.new(rect.x + half + 1, rect.y, {rect.w - half - 1, 0}.max, rect.h)
      render_template(screen, left, focused && @focus == :template)
      render_config(screen, right, focused && @focus == :config)
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

    private def render_target(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.h < 2
      Frame.card(screen, rect, "TARGET", bg: Theme.bg, border: Frame.pane_border(focused))
      unless @sni.strip.empty?
        badge = " SNI "
        screen.text({rect.right - badge.size - 1, rect.x + 9}.max, rect.y, badge, Theme.text_bright, Theme.accent_bg)
      end
      base = rect.x + 4
      screen.text(rect.x + 2, rect.y + 1, "›", focused ? Theme.accent : Theme.muted)
      screen.text(base, rect.y + 1, @target, Theme.text_bright, width: {rect.right - base - 1, 1}.max)
      if focused
        cx = base + Screen.display_width(@target[0, @tcx])
        if cx < rect.right - 1
          ch = @tcx < @target.size ? @target[@tcx] : ' '
          screen.cell(cx, rect.y + 1, ch, Theme.bg, Theme.accent)
          screen.cursor(cx, rect.y + 1)
        end
      end
    end

    private def render_template(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      spans = marker_spans
      pc = spans.size
      label = @http2 ? "TEMPLATE (h2)" : "TEMPLATE"
      Frame.card(screen, rect, label, bg: Theme.bg, border: Frame.pane_border(focused))
      badge = " §#{pc} "
      screen.text({rect.right - badge.size - 1, rect.x + label.size + 4}.max, rect.y, badge,
        pc > 0 ? Theme.text_bright : Theme.muted, pc > 0 ? Theme.accent_bg : Theme.bg)
      # Marker i ↔ position i ↔ generator.set_for(i). Colours resolved fresh each frame
      # (theme-reactive without a revision key, since the cached offsets are colour-free).
      @editor.bg_regions = spans.map_with_index { |(a, b), i| {a, b, Theme.marker_bg(i)} }
      @editor.render(screen, rect.inset(1, 1), cursor: focused, highlight: :request)
    end

    private def render_config(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "CONFIG", bg: Theme.bg, border: Frame.pane_border(focused))
      inner = rect.inset(1, 1)
      mx = inner.right
      y = inner.y

      # 1. payload type tabs — the cursor lands here on entry
      draw_ptype(screen, inner.x, y, mx, focused)
      y += 1

      # 2. the selected type's draft fields + add (capture the :p_path anchor)
      x = inner.x + 2
      ppath_x = nil
      ppath_y = y
      ptype_fields.each do |f|
        if f == :p_path
          ppath_x = x
          ppath_y = y
        end
        x = draw_seg(screen, x, y, ptype_label(f), f, mx, focused)
      end
      draw_add(screen, x, y, mx, focused)
      y += 2

      # 3. payload sets (variable length) — capped so the tail stays on-screen
      tail_h = @show_advanced ? 7 : 3
      y = render_sets(screen, inner, y, focused, {inner.bottom - tail_h, y}.max)
      y += 1

      # 4. mode
      x = label_at(screen, inner.x, y, "Mode")
      x = draw_seg(screen, x, y, "", :mode, mx, focused)
      screen.text(x + 1, y, mode_formula, Theme.muted, Theme.bg) if x + 10 < mx
      y += 1

      # 5. advanced toggle
      draw_advanced(screen, inner.x, y, mx, focused)
      y += 1

      # 6. advanced block — only when expanded
      if @show_advanced
        x = label_at(screen, inner.x, y, "Engine")
        x = draw_seg(screen, x, y, "conc", :conc, mx, focused)
        x = draw_seg(screen, x, y, "rate", :rate, mx, focused)
        x = draw_seg(screen, x, y, "to", :timeout, mx, focused)
        draw_seg(screen, x, y, "retry", :retries, mx, focused)
        y += 1

        x = label_at(screen, inner.x, y, "Opts")
        x = draw_seg(screen, x, y, "follow", :follow, mx, focused)
        draw_seg(screen, x, y, "calib", :calibrate, mx, focused)
        y += 1

        y = render_cond_line(screen, inner.x, y, mx, focused, "Match", :m_status, :m_size, :m_words, :m_regex)
        render_cond_line(screen, inner.x, y, mx, focused, "Filtr", :f_status, :f_size, :f_words, :f_regex)
      end

      # the wordlist completion popup floats over the lines below the :p_path field
      if @ptype == :wordlist && (ax = ppath_x) && @path_complete.open?
        @path_complete.render(screen, ax, ppath_y + 1, inner)
      end
    end

    private def draw_advanced(screen, x, y, mx, pane_focused) : Nil
      foc = pane_focused && current_field == :advanced
      label = @show_advanced ? "▾ Advanced" : "▸ Advanced (Engine · Match · Filter)"
      bg = foc ? Theme.accent_bg : Theme.bg
      fg = foc ? Theme.text_bright : Theme.muted
      screen.text(x, y, label, fg, bg, width: {mx - x, 1}.max)
    end

    private def render_cond_line(screen, ox, y, mx, focused, label, st, sz, wd, re) : Int32
      x = label_at(screen, ox, y, label)
      x = draw_seg(screen, x, y, "st", st, mx, focused)
      x = draw_seg(screen, x, y, "sz", sz, mx, focused)
      x = draw_seg(screen, x, y, "wd", wd, mx, focused)
      draw_seg(screen, x, y, "re", re, mx, focused)
      y + 1
    end

    # Render the "Sets" header + rows, bounded so the rows never overrun `limit`
    # (the bottom budget reserved for the Mode/Advanced tail). Overflow collapses
    # into a "… +N more" line. Returns the next free y.
    private def render_sets(screen, inner, y, focused, limit : Int32) : Int32
      pp = @config.mode.per_position? # set i → marker i (Pitchfork/ClusterBomb)
      header = "Sets"
      screen.text(inner.x, y, header, Theme.muted, Theme.bg)
      mcount = marker_spans.size
      if pp && !@sets.empty? && @sets.size != mcount
        hx = inner.x + header.size + 1
        screen.text(hx, y, sets_hint(mcount, @sets.size), Theme.muted, Theme.bg,
          width: {inner.right - hx, 1}.max)
      end
      y += 1
      if @sets.empty?
        screen.text(inner.x + 2, y, "(none — pick a type above, ⏎ add)", Theme.muted, Theme.bg)
        return y + 1
      end
      avail = {limit - y, 1}.max
      return render_sets_all(screen, inner, y, focused, pp) if @sets.size <= avail
      render_sets_windowed(screen, inner, y, focused, avail, pp)
    end

    # Every set fits — render them all (no scroll).
    private def render_sets_all(screen, inner : Rect, y : Int32, focused : Bool, pp : Bool) : Int32
      @cfg_scroll = 0
      @sets.each_with_index do |s, i|
        sel = focused && current_field == :set && current_set_index == i
        render_set_row(screen, inner, y, s, i, sel, pp)
        y += 1
      end
      y
    end

    # The list exceeds the pane: window it around the focused set (the unused @cfg_scroll
    # meant selection/delete could operate on a row scrolled off-screen). One row is
    # reserved for an "above/below" overflow indicator.
    private def render_sets_windowed(screen, inner : Rect, y : Int32, focused : Bool, avail : Int32, pp : Bool) : Int32
      visible = {avail - 1, 1}.max
      idx = current_set_index
      @cfg_scroll = idx if idx < @cfg_scroll
      @cfg_scroll = idx - visible + 1 if idx >= @cfg_scroll + visible
      @cfg_scroll = @cfg_scroll.clamp(0, {@sets.size - visible, 0}.max)
      stop = {@cfg_scroll + visible, @sets.size}.min
      (@cfg_scroll...stop).each do |i|
        sel = focused && current_field == :set && current_set_index == i
        render_set_row(screen, inner, y, @sets[i], i, sel, pp)
        y += 1
      end
      above, below = @cfg_scroll, @sets.size - stop
      hint = above > 0 && below > 0 ? "… #{above} above · #{below} below" : (above > 0 ? "… #{above} above" : "… +#{below} more")
      screen.text(inner.x + 1, y, hint, Theme.muted, Theme.bg)
      y + 1
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

    private def label_at(screen, x, y, label) : Int32
      screen.text(x, y, label, Theme.muted, Theme.bg)
      x + label.size + 1
    end

    # Draw "label value" at x; the value highlighted (accent bg) when its field is
    # focused, with a block caret + terminal cursor for a focused TEXT field.
    private def draw_seg(screen, x, y, label : String, fid : Symbol, mx, pane_focused) : Int32
      return x if x >= mx
      foc = pane_focused && current_field == fid
      vx = label.empty? ? x : label_at(screen, x, y, label)
      raw = field_text(fid)
      val = seg_display(fid, foc, raw)
      bg = foc ? Theme.accent_bg : Theme.bg
      fg = foc ? Theme.text_bright : Theme.text
      screen.text(vx, y, val, fg, bg, width: {mx - vx, 1}.max)
      if foc && text_field?(fid)
        cx = vx + {@cfg_caret, raw.size}.min
        if cx < mx
          screen.cell(cx, y, @cfg_caret < raw.size ? raw[@cfg_caret] : ' ', Theme.bg, Theme.accent)
          screen.cursor(cx, y)
        end
      end
      vx + val.size + 2
    end

    private def seg_display(fid : Symbol, focused : Bool, raw : String) : String
      case fid
      when :mode           then "‹ #{@config.mode.label} ›"
      when :follow         then @config.follow_redirects? ? "on" : "off"
      when :calibrate      then @config.auto_calibrate? ? "on" : "off"
      when :rate, :timeout then focused ? raw : (raw.empty? ? "∞" : raw)
      else                      focused ? raw : (raw.empty? ? "—" : raw)
      end
    end

    private def draw_ptype(screen, x, y, mx, pane_focused) : Nil
      foc = pane_focused && current_field == :ptype
      tx = label_at(screen, x, y, "Payld")
      {:list, :numbers, :wordlist, :null, :brute}.each do |t|
        sel = t == @ptype
        bg = sel ? (foc ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
        fg = sel ? Theme.text_bright : Theme.muted
        seg = " #{t.to_s.capitalize} "
        break if tx + seg.size > mx
        screen.text(tx, y, seg, fg, bg)
        tx += seg.size + 1
      end
    end

    private def draw_add(screen, x, y, mx, pane_focused) : Nil
      foc = pane_focused && current_field == :add
      return if x + 7 >= mx
      bg = foc ? Theme.accent_bg : Theme.bg
      screen.text(x + 1, y, " + add ", foc ? Theme.text_bright : Theme.accent, bg)
    end

    private def mode_formula : String
      case @config.mode
      when .sniper?        then "P×N"
      when .battering_ram? then "N"
      when .pitchfork?     then "min(Nᵢ)"
      else                      "∏Nᵢ"
      end
    end

    private def ptype_label(f : Symbol) : String
      case f
      when :p_values  then "values"
      when :p_from    then "from"
      when :p_to      then "to"
      when :p_step    then "step"
      when :p_path    then "path"
      when :p_count   then "count"
      when :p_charset then "chars"
      when :p_min     then "min"
      when :p_max     then "max"
      else                 ""
      end
    end

    private def render_results(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "RESULTS", bg: Theme.bg, border: Frame.pane_border(focused))
      status = if @running
                 p = @progress
                 "running #{p ? p.sent : 0}/#{@run_total || "?"} · #{matched_count} hit"
               else
                 "#{result_count} sent · #{matched_count} hit · sort:#{@sort}#{@matched_only ? " · matched" : ""}"
               end
      sx = {rect.right - status.size - 1, rect.x + 10}.max
      screen.text(sx, rect.y, status, Theme.muted, Theme.bg)
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
        screen.text(inner.x + 1, inner.y + 2, @running ? "running…" : "no results yet — ^R run", Theme.muted)
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
        screen.text(inner.x, inner.y, @running ? "sampling…" : "no results yet",
          Theme.muted, Theme.bg, width: inner.w)
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
      Frame.card(screen, rect, "RESULT ##{r.index}", bg: Theme.bg, border: Frame.pane_border(focused))
      tx = screen.text(rect.x + 14, rect.y, " request ", @detail_pane == :request ? Theme.text_bright : Theme.muted, @detail_pane == :request ? Theme.accent_bg : Theme.bg) + 1
      screen.text(tx, rect.y, " response ", @detail_pane == :response ? Theme.text_bright : Theme.muted, @detail_pane == :response ? Theme.accent_bg : Theme.bg)
      inner = rect.inset(1, 1)
      lines = @detail_pane == :request ? detail_request_lines(r) : detail_response_lines(r)
      # Clamp so ↓/wheel can't scroll past the last line into a blank void (keeps ≥1 row).
      @detail_scroll = @detail_scroll.clamp(0, {lines.size - 1, 0}.max)
      (0...inner.h).each do |i|
        li = @detail_scroll + i
        break if li >= lines.size
        screen.text(inner.x, inner.y + i, lines[li], Theme.text, Theme.bg, width: inner.w)
      end
    end

    private def detail_request_lines(r : Fuzz::Result) : Array(String)
      template = Fuzz::Template.parse(@editor.text, @http2)
      bytes = template.render(r.payloads)
      String.new(bytes).scrub.split('\n').map(&.rstrip('\r'))
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

    # --- clicks --------------------------------------------------------------
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

  # Inline filesystem path completion for the wordlist payload field. Mirrors the
  # Convert tab's ChainComplete (scroll-window dropdown) but with path-aware accept:
  # it keeps the typed directory prefix, replaces only the basename, and appends "/"
  # to directories so the user can keep drilling. Bare names (no "/") complete from
  # BOTH the current working dir and ~/.gori/wordlists. Per-directory child caching
  # keeps steady-state keystrokes off the filesystem.
  class PathComplete
    CAP = 60

    record Entry, label : String, insert : String, dir : Bool

    getter? open : Bool = false
    getter entries : Array(Entry) = [] of Entry
    getter selected : Int32 = 0
    @scroll = 0
    @cache = {} of String => Array(String) # dir → sorted children

    def refresh(value : String) : Nil
      @entries = candidates(value)
      @selected = 0
      @scroll = 0
      @open = !@entries.empty?
    end

    def move(d : Int32) : Nil
      return if @entries.empty?
      @selected = (@selected + d).clamp(0, @entries.size - 1)
    end

    def close : Nil
      @open = false
    end

    # The chosen insert string + whether it is a directory (the caller keeps the
    # popup open + refreshes on a dir, closes on a file). nil when nothing selectable.
    def accept : {String, Bool}?
      e = @entries[@selected]? || return nil
      {e.insert, e.dir}
    end

    private def candidates(value : String) : Array(Entry)
      if slash = value.rindex('/')
        prefix = value[0..slash] # kept verbatim, incl. trailing '/'
        partial = value[(slash + 1)..]
        read_dir = Path[prefix].expand(home: true).to_s
        merged = ranked(read_dir, partial).map do |name, is_dir, rank|
          {Entry.new(name, "#{prefix}#{name}#{is_dir ? "/" : ""}", is_dir), rank}
        end
        merge_cap(merged)
      else
        # bare name → cwd (bare insert) + ~/.gori/wordlists (ABSOLUTE insert: the
        # engine opens wordlist paths relative to CWD, so a wordlists-dir-only name
        # MUST resolve absolutely or it would fail at run time). Both sources are
        # ranked TOGETHER so a prefix/wordlist hit isn't buried under cwd fuzz.
        wl = Gori::Paths.wordlists_dir
        merged = ranked(Dir.current, value).map do |name, is_dir, rank|
          {Entry.new(name, "#{name}#{is_dir ? "/" : ""}", is_dir), rank}
        end
        ranked(wl, value).each do |name, is_dir, rank|
          merged << {Entry.new("#{name}  ·~/.gori", "#{File.join(wl, name)}#{is_dir ? "/" : ""}", is_dir), rank}
        end
        merge_cap(merged)
      end
    end

    private def merge_cap(scored : Array({Entry, Int32})) : Array(Entry)
      scored.sort_by! { |(e, rank)| {-rank, e.label} }
      scored.first(CAP).map { |(e, _)| e }
    end

    # Children of `dir` matching `partial` (case-insensitive prefix OR fuzzy),
    # ranked prefix-first then by score then name. Returns [{name, dir?, rank}],
    # capped; only the survivors are stat'd for directory-ness.
    private def ranked(dir : String, partial : String) : Array({String, Bool, Int32})
      pl = partial.downcase
      scored = children_of(dir).compact_map do |name|
        dn = name.downcase
        if partial.empty?
          {name, 1}
        elsif dn.starts_with?(pl)
          {name, 1_000_000}
        elsif s = Gori::Fuzzy.score(pl, dn)
          {name, s}
        else
          nil
        end
      end
      scored.sort_by! { |(name, rank)| {-rank, name} }
      scored.first(CAP).map { |(name, rank)| {name, File.directory?(File.join(dir, name)), rank} }
    end

    # Per-directory children cache (bounded): re-read only when a dir is first seen.
    private def children_of(dir : String) : Array(String)
      @cache.clear if @cache.size > 8
      @cache[dir] ||= (Dir.children(dir).sort rescue [] of String)
    end

    # Frame-less dropdown anchored at (x, y), clamped within `inner`. Same scroll +
    # accent-bg selection as ChainComplete.
    def render(screen : Screen, x : Int32, y : Int32, inner : Rect) : Nil
      return if !@open || @entries.empty?
      w = ({@entries.max_of(&.label.size) + 2, 18}.max).clamp(1, {inner.right - x, 1}.max)
      h = {@entries.size, 8, {inner.bottom - y, 1}.max}.min
      return if h <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - h + 1 if @selected >= @scroll + h
      @scroll = @scroll.clamp(0, {@entries.size - h, 0}.max)
      (0...h).each do |i|
        e = @entries[@scroll + i]? || break
        active = (@scroll + i) == @selected
        bg = active ? Theme.accent_bg : Theme.elevated
        screen.fill(Rect.new(x, y + i, w, 1), bg)
        screen.cell(x, y + i, active ? '▎' : ' ', Theme.accent, bg)
        screen.text(x + 1, y + i, e.label, active ? Theme.text_bright : Theme.text, bg, width: {w - 1, 1}.max)
      end
    end
  end
end
