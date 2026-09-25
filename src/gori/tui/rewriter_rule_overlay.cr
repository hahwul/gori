require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "./overlay"
require "../rules/stub"
require "../store"
require "../store/safe_regexp"

module Gori::Tui
  # Popup form to add or edit ONE Rewriter (Match & Replace) rule. Same interaction model
  # as CustomRuleOverlay / ScopeRuleOverlay:
  #   ↑/↓ or ↹   move between fields
  #   ←/→         cycle the selected option row (target / op / match / part)
  #   type        edit the focused text row (name / host / find / value)
  #   ↵           advance a text row (↵ on value or Save commits) · esc cancels
  #
  # On the polymorphic Overlay seam (see overlay.cr). BOTH domain couplings are injected
  # at the open-site (Runner#open_rewriter_rule_editor): `on_commit` persists through the
  # shared Rules engine (which the proxy reads live), and `on_preview` scans recent flows
  # for the live match PREVIEW. The form owns only WHEN to ask for that preview — see
  # refresh_preview.
  class RewriterRuleOverlay < Overlay
    ROW_NAME = 0
    # Where the rule LIVES, which is who it applies to (`Store::RuleScope`). First of the
    # cyclers, and directly under the name, because it is the question the operator answers
    # once per rule and the one that reaches outside this project.
    ROW_SCOPE  = 1
    ROW_TARGET = 2
    ROW_OP     = 3
    ROW_MATCH  = 4
    ROW_PART   = 5
    ROW_HOST   = 6
    ROW_FIND   = 7
    # short_circuit only (#1237): WHERE the answer comes from — an inline stub, a body file, a
    # directory (map local), or a fault instead of a response. Directly above the rows it
    # decides, so the form reads top-down as the choice and then its parts.
    ROW_RESPOND = 8
    ROW_VALUE   = 9
    # short_circuit only: the response BODY file — or, for a directory source, the directory.
    # Sits between the response and the options so the body sources read as one choice.
    ROW_BODY_FILE = 10
    # short_circuit only: the source's options (prefix, fall-through, hang bound, delay), in
    # their own sub-editor so the form stays one screen tall (`RewriterRespondOverlay`).
    ROW_OPTIONS = 11
    ROW_SAVE    = 12
    ROW_COUNT   = 13

    SCOPES       = %w[project global]
    SCOPE_LABELS = ["this project", "global (every project)"]
    TARGETS      = %w[request response]
    OPS          = %w[replace add_header set_header remove_header short_circuit pipe]
    OP_LABELS    = ["replace", "add header", "set header", "remove header", "stub", "pipe (run a command)"]
    MATCHES      = %w[literal regex]
    # `ws` rewrites a WebSocket MESSAGE on an upgraded (101) flow, with `target:` picking
    # the direction (request = client→server, response = server→client). It is its own part
    # rather than a flavour of `body` so that no existing body rule starts touching frames.
    PARTS = %w[head body ws]
    # The `source:` cycler. The three fault kinds are sources of their own rather than an
    # option under one "fault" entry: which fault is the whole of what such a rule does.
    SOURCES       = %w[inline file dir close reset hang]
    SOURCE_LABELS = ["inline", "body file", "directory", "close", "reset", "hang"]

    getter edit_id : Int64?
    # The scope the edited rule was OPENED at, so the commit can tell an edit from a re-home:
    # `scope` is the cycler's current value and these two differing is the whole signal that
    # the rule has to move between the project table and the global library.
    getter edit_scope : Store::RuleScope?

    # Renders the "affects N of M recent flows" line under the form. Injected at the
    # open-site because it READS TRAFFIC — the form itself stays store-free.
    property on_preview : Proc(Store::MatchRule, String)?

    # Opens the multi-line stub editor for the `response:` row. Injected at the open-site the
    # same way DiscoverConfigOverlay injects its headers editor: the form owns WHEN to ask,
    # the Runner owns the overlay swap and putting this form back afterwards.
    property on_edit_stub : Proc(Nil)?

    # Opens the answer-options sub-editor for the `options:` row — the same seam as
    # `on_edit_stub` (#1237).
    property on_edit_options : Proc(Nil)?

    @scope_i : Int32
    @target_i : Int32
    @op_i : Int32
    @match_i : Int32
    @part_i : Int32
    @source_i : Int32
    # The source's options as last edited; `respond_args` drops the ones the current source
    # does not read.
    @options : Store::RespondArgs
    @sel : Int32
    @preview : String = ""
    # Last previewed field set; gates the rescan to real changes (see refresh_preview).
    @preview_sig : String = ""

    def initialize(*, name : String = "", target : String = "request", op : String = "replace",
                   match : String = "literal", part : String = "head", host : String = "",
                   pattern : String = "", replacement : String = "", @edit_id : Int64? = nil,
                   body_file : String = "", scope : String = "project",
                   @edit_scope : Store::RuleScope? = nil, respond : String = "inline",
                   respond_args : String = "")
      @fields = {
        name:      TextField.new(name),
        host:      TextField.new(host),
        pattern:   TextField.new(pattern),
        value:     TextField.new(replacement),
        body_file: TextField.new(body_file),
      }
      # A short-circuit rule's response is multi-line, so it lives in its own buffer edited by
      # RewriterStubOverlay rather than in the single-line `value` field the other ops use.
      # Seeded from `replacement`, which is where it is persisted either way.
      @stub = replacement
      @scope_i = idx(SCOPES, scope)
      @target_i = idx(TARGETS, target)
      @op_i = idx(OPS, op)
      @match_i = idx(MATCHES, match)
      @part_i = idx(PARTS, part)
      parsed = Store::RespondArgs.parse(respond_args)
      @options = parsed.is_a?(String) ? Store::RespondArgs.new : parsed
      source = respond == "fault" ? (@options.fault.try(&.label) || "close") : respond
      @source_i = idx(SOURCES, source)
      @sel = 0
    end

    def self.adding : RewriterRuleOverlay
      new
    end

    def self.editing(rule : Store::MatchRule) : RewriterRuleOverlay
      new(name: rule.name, target: rule.target.label, op: rule.op.label,
        match: rule.match_kind.label, part: rule.part.label, host: rule.host,
        pattern: rule.pattern, replacement: rule.replacement, edit_id: rule.id,
        body_file: rule.body_file, scope: rule.scope.label, edit_scope: rule.scope,
        respond: rule.respond.label, respond_args: rule.respond_args)
    end

    private def idx(list : Array(String), v : String) : Int32
      list.index(v) || 0
    end

    def editing? : Bool
      !@edit_id.nil?
    end

    def name : String
      @fields[:name].value.strip
    end

    def host : String
      @fields[:host].value.strip
    end

    # The find pattern — or, for a header op, the header NAME.
    #
    # Stripped only for the NAME case: ` X-Trace ` and `X-Trace` name one header and the
    # spaces could only ever be a typo. Every other op matches this field against BYTES, so it
    # is kept verbatim, exactly as `replacement` below is. A `replace` rule finding `" token "`
    # or a regex anchored on a trailing space is an ordinary thing to write — and `gori run
    # rewriter add` / the MCP `create_rule` do not strip, so opening such a rule HERE and
    # saving any other field silently changed which bytes it matched.
    def pattern : String
      raw = @fields[:pattern].value
      header_op? ? raw.strip : raw
    end

    # The replacement / header value keeps interior + trailing spaces (a header value or
    # a replacement may legitimately contain them). A short-circuit rule persists its canned
    # response through the same field, so the two paths join here.
    def replacement : String
      return @fields[:value].value unless short_circuit_op?
      respond.fault? ? "" : @stub
    end

    # The stub buffer, as the sub-editor last left it.
    def stub : String
      @stub
    end

    def stub=(text : String) : Nil
      @stub = text
    end

    def body_file : String
      short_circuit_op? && (respond.file? || respond.dir?) ? @fields[:body_file].value.strip : ""
    end

    # The short-circuit sub-kind the `source:` row names (#1237).
    def respond : Store::RespondKind
      fault_kind ? Store::RespondKind::Fault : (Store::RespondKind.from_label?(SOURCES[@source_i]) || Store::RespondKind::Inline)
    end

    def fault_kind : Store::FaultKind?
      Store::FaultKind.from_label?(SOURCES[@source_i])
    end

    # The options as the sub-editor last left them, before the source filters them.
    def options : Store::RespondArgs
      @options
    end

    def options=(args : Store::RespondArgs) : Nil
      @options = args
    end

    # The stored args: only what the current source reads, so switching `source:` never leaves
    # an ignored setting behind for `respond_error` to refuse.
    def respond_args : String
      return "" unless short_circuit_op?
      @options.for(respond, fault_kind).to_stored
    end

    def scope : Store::RuleScope
      Store::RuleScope.from_label(SCOPES[@scope_i])
    end

    def target : Store::RuleTarget
      Store::RuleTarget.from_label(TARGETS[@target_i])
    end

    def op : Store::RuleOp
      Store::RuleOp.from_label(OPS[@op_i])
    end

    def match_kind : Store::MatchKind
      Store::MatchKind.from_label(MATCHES[@match_i])
    end

    def part : Store::RulePart
      Store::RulePart.from_label(PARTS[@part_i])
    end

    def header_op? : Bool
      op.header?
    end

    def short_circuit_op? : Bool
      op.short_circuit?
    end

    # The op whose `value:` row is an ARGV, not a replacement — see `Store::RuleOp::Pipe`.
    def pipe_op? : Bool
      op.pipe?
    end

    # Rows the CURRENT op has no meaning for, skipped by ↑/↓ so the form never parks the
    # caret on a field that does nothing: the body-file row for the five ops that are not a
    # stub, target/part for a stub (drawn as what it forces them to), and for a header op
    # the match and part rows it ignores — plus the value row for `remove header`, which
    # has nothing to set. The header rows were drawn `n/a` but still landed on: ←/→ there
    # cycled a value the op never reads, and every notch re-ran the 200-flow preview scan
    # for a change that changed nothing.
    private def skip_row?(row : Int32) : Bool
      if short_circuit_op?
        stub_skips?(row)
      elsif header_op?
        row == ROW_MATCH || row == ROW_PART || row == ROW_BODY_FILE || stub_only_row?(row) ||
          (row == ROW_VALUE && op.remove_header?)
      else
        row == ROW_BODY_FILE || stub_only_row?(row)
      end
    end

    # A stub forces target/part, a fault has no response, and only a file or a directory
    # source has a path.
    private def stub_skips?(row : Int32) : Bool
      case row
      when ROW_TARGET, ROW_PART then true
      when ROW_VALUE            then respond.fault?
      when ROW_BODY_FILE        then !(respond.file? || respond.dir?)
      else                           false
      end
    end

    private def stub_only_row?(row : Int32) : Bool
      row == ROW_RESPOND || row == ROW_OPTIONS
    end

    def on_save_row? : Bool
      @sel == ROW_SAVE
    end

    # A pattern is required; a regex match must additionally compile; a short-circuit rule's
    # canned response must parse, because an unparseable one would answer every matching
    # request with gori's own 502 and still never reach the origin.
    def valid? : Bool
      return false if pattern.empty?
      return false if short_circuit_op? && !respond_error.nil?
      # A pipe rule's `value:` is the command, so an empty or unparseable one is exactly as
      # unsaveable as an empty pattern: the rule would match live traffic and then do nothing
      # at all, silently, on every message. Same validator the CLI and MCP call
      # (`Rules.pipe_argv_error`).
      return false if pipe_op? && !Gori::Rules.pipe_argv_error(op, replacement).nil?
      return true unless match_kind.regex? && !op.header?
      SafeRegexp.compile(pattern)
      true
    rescue
      false
    end

    # What is missing, for the Save row's label.
    def invalid_reason : String
      return "enter a #{header_op? ? "header name" : "pattern"}" if pattern.empty?
      if short_circuit_op? && (why = respond_error)
        # The editor says what is wrong with a response as it is typed; the Save row only has to
        # say where to go.
        stub = (respond.inline? || respond.file?) && !RuleStub.valid?(@stub)
        return stub ? "write a stub response (↵ on response:)" : why
      end
      if pipe_op? && (why = Gori::Rules.pipe_argv_error(op, replacement))
        return replacement.strip.empty? ? "enter a command to pipe through" : "fix the command: #{why}"
      end
      "fix the regex"
    end

    # The shared validator (#1237) over what this form would save.
    private def respond_error : String?
      RuleStub.respond_error(respond, replacement, body_file, respond_args)
    end

    # The preview line as last computed — "" until the first key that changes a
    # match-relevant field (opening an edit form does NOT scan).
    getter preview

    # The fields a match preview depends on — only rescan when this changes.
    private def preview_signature : String
      "#{@target_i}|#{@op_i}|#{@match_i}|#{@part_i}|#{host}|#{pattern}|#{replacement}|#{body_file}|#{@source_i}|#{respond_args}"
    end

    # Recompute the preview when the candidate rule's match-relevant fields changed.
    # Selection moves and caret keys therefore cost nothing, which is what keeps typing
    # responsive: the injected scan is the expensive part. An empty pattern never scans —
    # it would match everything — and says so in the preview slot instead.
    private def refresh_preview : Nil
      sig = preview_signature
      return if sig == @preview_sig
      @preview_sig = sig
      if pattern.empty?
        @preview = "enter a #{header_op? ? "header name" : "pattern"} to preview"
        return
      end
      if src = @on_preview
        @preview = src.call(candidate_rule)
      end
    end

    # The rule as currently edited (id 0 when adding) — used for the live preview.
    def candidate_rule : Store::MatchRule
      tgt, prt = Gori::Rules.normalize_shape(op, target, part)
      Store::MatchRule.new(@edit_id || 0_i64, true, tgt, prt,
        pattern, replacement, op, match_kind, name, host, body_file, scope: scope,
        respond: short_circuit_op? ? respond : Store::RespondKind::Inline, respond_args: respond_args)
    end

    def move(d : Int32) : Nil
      step = d < 0 ? -1 : 1
      nxt = @sel
      # Walk PAST rows this op ignores instead of landing on them; stop at the ends rather
      # than wrapping, matching the previous clamp behaviour.
      loop do
        probe = nxt + step
        break if probe < 0 || probe > ROW_COUNT - 1
        nxt = probe
        break unless skip_row?(nxt)
      end
      @sel = nxt unless skip_row?(nxt)
    end

    def set_selected(idx : Int32) : Nil
      idx = idx.clamp(0, ROW_COUNT - 1)
      @sel = idx unless skip_row?(idx)
    end

    private def cycler_row?(row : Int32) : Bool
      ROW_SCOPE <= row <= ROW_PART || row == ROW_RESPOND
    end

    private def text_field_for(row : Int32) : TextField?
      case row
      when ROW_NAME      then @fields[:name]
      when ROW_HOST      then @fields[:host]
      when ROW_FIND      then @fields[:pattern]
      when ROW_BODY_FILE then @fields[:body_file]
      when ROW_VALUE     then short_circuit_op? ? nil : @fields[:value]
      end
    end

    def adjust(d : Int32) : Nil
      case @sel
      when ROW_SCOPE   then @scope_i = (@scope_i + d) % SCOPES.size
      when ROW_TARGET  then @target_i = (@target_i + d) % TARGETS.size
      when ROW_OP      then @op_i = (@op_i + d) % OPS.size
      when ROW_MATCH   then @match_i = (@match_i + d) % MATCHES.size
      when ROW_PART    then @part_i = (@part_i + d) % PARTS.size
      when ROW_RESPOND then @source_i = (@source_i + d) % SOURCES.size
      end
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::RewriterRule
    end

    def title : String
      "REWRITER RULE"
    end

    # The single-line fields the pointer can reach — see `Overlay#text_fields`. Listing them
    # is the whole opt-in: caret placement on a press, drag to extend, double-click for a
    # word, all inverted by the field against the geometry `render` last drew it at.
    def text_fields : Array(TextField)
      @fields.values.to_a # NamedTuple on some cards, Hash on others — one shape out
    end

    def hint : String
      "↑/↓ field · ←/→ options · type find/value · ↵ save · esc cancel"
    end

    # :stay | :commit | :cancel. A key that leaves the form open also refreshes the match
    # preview (only the :stay path — there is nothing to preview once it closes).
    def handle_key(ev : Termisu::Event::Key) : Symbol
      out = edit_key(ev)
      refresh_preview if out == :stay
      out
    end

    # Click a field row to select it; a click on Save commits; a click outside the card
    # cancels. Mirrors the ↑/↓ + ↵ keyboard model. No preview refresh: selecting a row
    # can't change a match-relevant field.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if idx = row_at(box, mx, my)
        set_selected(idx)
        return :commit if on_save_row?
        @on_edit_stub.try(&.call) if idx == ROW_VALUE && short_circuit_op? && !respond.fault?
        @on_edit_options.try(&.call) if idx == ROW_OPTIONS && short_circuit_op?
      end
      # …then the caret, if the press landed inside a drawn field. The row pick above is
      # what focuses; this is what puts the caret where the operator pointed instead of
      # leaving it wherever the last keystroke did (Overlay#click_text_field).
      click_text_field(mx, my)
      :stay
    end

    private def edit_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :cancel if key.escape?
      if key.up? || key.back_tab?
        move(-1)
        return :stay
      elsif key.down? || key.tab?
        move(1)
        return :stay
      end

      if cycler_row?(@sel)
        case
        when key.left?              then adjust(-1)
        when key.right?             then adjust(1)
        when key.enter?, key.space? then move(1)
        end
        :stay
      elsif @sel == ROW_SAVE
        (key.enter? || key.space?) ? :commit : :stay
      elsif @sel == ROW_VALUE && short_circuit_op?
        # Not a text row for this op — the response is multi-line and lives in its own editor.
        @on_edit_stub.try(&.call) if key.enter? || key.space?
        :stay
      elsif @sel == ROW_OPTIONS
        @on_edit_options.try(&.call) if key.enter? || key.space?
        :stay
      else # text row
        field = text_field_for(@sel)
        if key.enter?
          # ↵ on the LAST text row commits — the value, or the header name when the op has no
          # value row (remove header). A stub's body-file row is followed by its options, so ↵
          # there moves on like every other row before the end.
          return :commit if @sel == ROW_VALUE || (@sel == ROW_FIND && skip_row?(ROW_VALUE) && !short_circuit_op?)
          move(1)
        elsif field
          field.handle_edit_key(ev)
        end
        :stay
      end
    end

    def set_preedit(text : String) : Nil
      text_field_for(@sel).try(&.set_preedit(text))
    end

    def overlay_box(area : Rect) : Rect?
      Overlay.rule_form_box(area, ROW_COUNT, preview: true)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        Overlay.too_small(screen, area, "rewriter-rule form needs a larger window")
        return
      end
      title = editing? ? "EDIT REWRITER RULE" : "ADD REWRITER RULE"
      Frame.card(screen, box, title, border: Theme.border_focus)
      first = box.y + 2
      ROW_COUNT.times do |i|
        py = first + i
        break if py >= box.bottom - 2
        draw_row(screen, box, i, py)
      end
      pv_y = box.bottom - 2
      if pv_y > first && !@preview.empty?
        screen.fill(Rect.new(box.x + 1, pv_y, box.w - 2, 1), Theme.panel)
        screen.text(box.x + 2, pv_y, "▶ #{@preview}", Theme.muted, Theme.panel, width: box.w - 4)
      end
      # No key hint on the bottom border: the shell already draws `hint` in the status strip
      # for whichever modal is open (Runner#key_hints), so a second copy here was the same
      # advice twice — and the two had already drifted apart, this one having dropped the
      # `type find/value` clause the method still carries. Per-row affordances stay where the
      # key applies (the `‹/›` a cycler draws when it has focus).
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      sel = i == @sel
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      x = box.x + 3
      fg = sel ? Theme.text_bright : Theme.text
      hop = header_op?
      sc = short_circuit_op?
      case i
      when ROW_NAME   then draw_field(screen, box, py, bg, fg, sel, "name:", @fields[:name])
      when ROW_SCOPE  then Frame.option_cycle(screen, x, py, box.right - 2, bg, "scope:", SCOPE_LABELS, @scope_i, sel)
      when ROW_TARGET then sc ? draw_na(screen, x, py, bg, "target:", "request (a stub answers a request)") : Frame.option_cycle(screen, x, py, box.right - 2, bg, "target:", TARGETS, @target_i, sel)
      when ROW_OP     then Frame.option_cycle(screen, x, py, box.right - 2, bg, "op:", OP_LABELS, @op_i, sel)
      when ROW_MATCH  then hop ? draw_na(screen, x, py, bg, "match:") : Frame.option_cycle(screen, x, py, box.right - 2, bg, "match:", MATCHES, @match_i, sel)
      when ROW_PART   then (hop || sc) ? draw_na(screen, x, py, bg, "part:", sc ? "head (matches the request head)" : nil) : Frame.option_cycle(screen, x, py, box.right - 2, bg, "part:", PARTS, @part_i, sel)
      when ROW_HOST   then draw_field(screen, box, py, bg, fg, sel, "host:", @fields[:host])
      when ROW_FIND   then draw_field(screen, box, py, bg, fg, sel, hop ? "header:" : "find:", @fields[:pattern])
      when ROW_VALUE
        if sc && respond.fault?
          draw_na(screen, x, py, bg, "response:", "none — a fault answers with no response")
        elsif sc
          draw_stub_row(screen, x, py, bg, fg, sel)
        elsif op.remove_header?
          draw_na(screen, x, py, bg, "value:", "n/a (nothing to set)")
        else
          draw_field(screen, box, py, bg, fg, sel, value_label, @fields[:value])
        end
      when ROW_RESPOND
        Frame.option_cycle(screen, x, py, box.right - 2, bg, "source:", SOURCE_LABELS, @source_i, sel) if sc
      when ROW_BODY_FILE
        if sc && respond.dir?
          draw_field(screen, box, py, bg, fg, sel, "dir:", @fields[:body_file])
        elsif sc && respond.file?
          draw_field(screen, box, py, bg, fg, sel, "body file:", @fields[:body_file])
        end
      when ROW_OPTIONS
        draw_options_row(screen, x, py, bg, fg, sel) if sc
      else
        ok = valid?
        label = ok ? "[ Save rule ]" : "[ #{invalid_reason} ]"
        screen.text(x, py, label, ok ? Theme.accent : Theme.muted, bg, Attribute::Bold)
      end
    end

    # The `response:` row is a BUTTON, not a field: ↵ opens the multi-line stub editor. The
    # row shows what the buffer currently amounts to, so the form still says at a glance what
    # this rule would answer with.
    private def draw_stub_row(screen : Screen, x : Int32, py : Int32, bg : Color, fg : Color, sel : Bool) : Nil
      screen.text(x, py, "response:", Theme.muted, bg)
      tx = x + 10
      text =
        if respond.dir?
          # For a directory the buffer is only a head TEMPLATE; the body is the mapped file.
          @stub.blank? ? "200 OK (default — ↵ to add headers)" : "head: #{RuleStub.summary(@stub, "").split(" · ").first}"
        elsif @stub.blank?
          "(none — ↵ to write one)"
        else
          RuleStub.summary(@stub, body_file)
        end
      screen.text(tx, py, text, @stub.blank? ? Theme.muted : fg, bg)
      screen.text(tx + Screen.draw_width(text) + 1, py, "↵", Theme.accent, bg) if sel
    end

    # The `options:` row is a button like `response:` — ↵ opens the answer-options sub-editor —
    # and shows what the options amount to for the current source.
    private def draw_options_row(screen : Screen, x : Int32, py : Int32, bg : Color, fg : Color, sel : Bool) : Nil
      screen.text(x, py, "options:", Theme.muted, bg)
      tx = x + 10
      text = options_summary
      screen.text(tx, py, text, fg, bg)
      screen.text(tx + Screen.draw_width(text) + 1, py, "↵", Theme.accent, bg) if sel
    end

    private def options_summary : String
      parts = [] of String
      if respond.dir?
        parts << (@options.strip_prefix.empty? ? "no prefix" : "strip #{@options.strip_prefix}")
        parts << (@options.fallthrough? ? "falls through" : "missing → 502")
      end
      parts << "≤#{@options.hang_ms}ms" if fault_kind == Store::FaultKind::Hang
      parts << (@options.delay_ms > 0 ? "delay #{@options.delay_ms}ms" : "no delay")
      parts.join(" · ")
    end

    private def value_label : String
      case op
      when .add_header?, .set_header? then "value:"
        # Not "replace:" — the field holds a COMMAND, and a row labelled "replace" over an
        # argv is the one place this form could make an operator think the text on the right
        # is what lands on the wire.
      when .pipe? then "run:"
      else             "replace:"
      end
    end

    private def draw_na(screen : Screen, x : Int32, py : Int32, bg : Color, label : String, note : String? = nil) : Nil
      screen.text(x, py, label, Theme.muted, bg)
      screen.text(x + label.size + 1, py, note || "n/a (header op)", Theme.muted, bg)
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      i = my - (box.y + 2)
      (0 <= i < ROW_COUNT) ? i : nil
    end
  end
end
