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
    ROW_NAME   = 0
    ROW_TARGET = 1
    ROW_OP     = 2
    ROW_MATCH  = 3
    ROW_PART   = 4
    ROW_HOST   = 5
    ROW_FIND   = 6
    ROW_VALUE  = 7
    # short_circuit only: the response BODY file. Sits between the response and Save so the
    # two body sources (inline, in the response buffer; on disk, here) read as one choice.
    ROW_BODY_FILE =  8
    ROW_SAVE      =  9
    ROW_COUNT     = 10

    TARGETS   = %w[request response]
    OPS       = %w[replace add_header set_header remove_header short_circuit]
    OP_LABELS = ["replace", "add header", "set header", "remove header", "stub"]
    MATCHES   = %w[literal regex]
    PARTS     = %w[head body]

    getter edit_id : Int64?

    # Renders the "affects N of M recent flows" line under the form. Injected at the
    # open-site because it READS TRAFFIC — the form itself stays store-free.
    property on_preview : Proc(Store::MatchRule, String)?

    # Opens the multi-line stub editor for the `response:` row. Injected at the open-site the
    # same way DiscoverConfigOverlay injects its headers editor: the form owns WHEN to ask,
    # the Runner owns the overlay swap and putting this form back afterwards.
    property on_edit_stub : Proc(Nil)?

    @target_i : Int32
    @op_i : Int32
    @match_i : Int32
    @part_i : Int32
    @sel : Int32
    @preview : String = ""
    # Last previewed field set; gates the rescan to real changes (see refresh_preview).
    @preview_sig : String = ""

    def initialize(*, name : String = "", target : String = "request", op : String = "replace",
                   match : String = "literal", part : String = "head", host : String = "",
                   pattern : String = "", replacement : String = "", @edit_id : Int64? = nil,
                   body_file : String = "")
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
      @target_i = idx(TARGETS, target)
      @op_i = idx(OPS, op)
      @match_i = idx(MATCHES, match)
      @part_i = idx(PARTS, part)
      @sel = 0
    end

    def self.adding : RewriterRuleOverlay
      new
    end

    def self.editing(rule : Store::MatchRule) : RewriterRuleOverlay
      new(name: rule.name, target: rule.target.label, op: rule.op.label,
        match: rule.match_kind.label, part: rule.part.label, host: rule.host,
        pattern: rule.pattern, replacement: rule.replacement, edit_id: rule.id,
        body_file: rule.body_file)
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

    def pattern : String
      @fields[:pattern].value.strip
    end

    # The replacement / header value keeps interior + trailing spaces (a header value or
    # a replacement may legitimately contain them). A short-circuit rule persists its canned
    # response through the same field, so the two paths join here.
    def replacement : String
      short_circuit_op? ? @stub : @fields[:value].value
    end

    # The stub buffer, as the sub-editor last left it.
    def stub : String
      @stub
    end

    def stub=(text : String) : Nil
      @stub = text
    end

    def body_file : String
      short_circuit_op? ? @fields[:body_file].value.strip : ""
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

    # Rows the CURRENT op has no meaning for, skipped by ↑/↓ so the form never parks the
    # caret on a field that does nothing. target/match/part are already drawn "n/a" for the
    # ops that ignore them; this stops the two body-source rows from appearing at all for the
    # four rewrite ops, and the plain `replace:` row from appearing for a stub.
    private def skip_row?(row : Int32) : Bool
      if short_circuit_op?
        row == ROW_TARGET || row == ROW_PART
      else
        row == ROW_BODY_FILE
      end
    end

    def on_save_row? : Bool
      @sel == ROW_SAVE
    end

    # A pattern is required; a regex match must additionally compile; a short-circuit rule's
    # canned response must parse, because an unparseable one would answer every matching
    # request with gori's own 502 and still never reach the origin.
    def valid? : Bool
      return false if pattern.empty?
      return false if short_circuit_op? && !RuleStub.valid?(@stub)
      return true unless match_kind.regex? && !op.header?
      SafeRegexp.compile(pattern)
      true
    rescue
      false
    end

    # What is missing, for the Save row's label.
    def invalid_reason : String
      return "enter a #{header_op? ? "header name" : "pattern"}" if pattern.empty?
      return "write a stub response (↵ on response:)" if short_circuit_op? && !RuleStub.valid?(@stub)
      "fix the regex"
    end

    # The preview line as last computed — "" until the first key that changes a
    # match-relevant field (opening an edit form does NOT scan).
    getter preview

    # The fields a match preview depends on — only rescan when this changes.
    private def preview_signature : String
      "#{@target_i}|#{@op_i}|#{@match_i}|#{@part_i}|#{host}|#{pattern}|#{replacement}|#{body_file}"
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
        pattern, replacement, op, match_kind, name, host, body_file)
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
      ROW_TARGET <= row <= ROW_PART
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
      when ROW_TARGET then @target_i = (@target_i + d) % TARGETS.size
      when ROW_OP     then @op_i = (@op_i + d) % OPS.size
      when ROW_MATCH  then @match_i = (@match_i + d) % MATCHES.size
      when ROW_PART   then @part_i = (@part_i + d) % PARTS.size
      end
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::RewriterRule
    end

    def title : String
      "REWRITER RULE"
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
        @on_edit_stub.try(&.call) if idx == ROW_VALUE && short_circuit_op?
      end
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
      else # text row
        field = text_field_for(@sel)
        if key.enter?
          return :commit if @sel == ROW_VALUE || @sel == ROW_BODY_FILE
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
      # 72, not 66: a fifth op pushed the option row past the card edge at the old width.
      w = {area.w - 4, 72}.min
      h = {area.h - 2, ROW_COUNT + 5}.min # title + rows + preview + hint + padding
      return nil if w < 40 || h < 13
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "rewriter-rule form needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
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
      hint_y = box.bottom - 1
      screen.text(box.x + 2, hint_y, "↑/↓ field · ←/→ options · ↵ save · esc cancel",
        Theme.muted, Theme.panel, width: box.w - 4) if hint_y > first
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
      when ROW_TARGET then sc ? draw_na(screen, x, py, bg, "target:", "request (a stub answers a request)") : draw_cycle(screen, x, py, bg, fg, "target:", TARGETS, @target_i, sel)
      when ROW_OP     then draw_cycle(screen, x, py, bg, fg, "op:", OP_LABELS, @op_i, sel)
      when ROW_MATCH  then hop ? draw_na(screen, x, py, bg, "match:") : draw_cycle(screen, x, py, bg, fg, "match:", MATCHES, @match_i, sel)
      when ROW_PART   then (hop || sc) ? draw_na(screen, x, py, bg, "part:", sc ? "head (matches the request head)" : nil) : draw_cycle(screen, x, py, bg, fg, "part:", PARTS, @part_i, sel)
      when ROW_HOST   then draw_field(screen, box, py, bg, fg, sel, "host:", @fields[:host])
      when ROW_FIND   then draw_field(screen, box, py, bg, fg, sel, hop ? "header:" : "find:", @fields[:pattern])
      when ROW_VALUE
        sc ? draw_stub_row(screen, x, py, bg, fg, sel) : draw_field(screen, box, py, bg, fg, sel, value_label, @fields[:value])
      when ROW_BODY_FILE
        draw_field(screen, box, py, bg, fg, sel, "body file:", @fields[:body_file]) if sc
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
      text = @stub.blank? ? "(none — ↵ to write one)" : RuleStub.summary(@stub, body_file)
      screen.text(tx, py, text, @stub.blank? ? Theme.muted : fg, bg)
      screen.text(tx + Screen.draw_width(text) + 1, py, "↵", Theme.accent, bg) if sel
    end

    private def value_label : String
      case op
      when .add_header?, .set_header? then "value:"
      when .remove_header?            then "value: (n/a)"
      else                                 "replace:"
      end
    end

    private def draw_na(screen : Screen, x : Int32, py : Int32, bg : Color, label : String, note : String? = nil) : Nil
      screen.text(x, py, label, Theme.muted, bg)
      screen.text(x + label.size + 1, py, note || "n/a (header op)", Theme.muted, bg)
    end

    private def draw_cycle(screen : Screen, x : Int32, py : Int32, bg : Color, fg : Color,
                           label : String, opts : Array(String), sel_i : Int32, row_sel : Bool) : Nil
      screen.text(x, py, label, Theme.muted, bg)
      tx = x + label.size + 1
      opts.each_with_index do |opt, oi|
        lit = oi == sel_i
        col = lit ? (row_sel ? Theme.text_bright : Theme.accent) : Theme.muted
        tx = screen.text(tx, py, " #{opt} ", col, bg, lit ? Attribute::Bold : Attribute::None)
      end
      screen.text(tx, py, " ‹/›", Theme.muted, bg) if row_sel
    end

    private def draw_field(screen : Screen, box : Rect, py : Int32, bg : Color, fg : Color,
                           sel : Bool, label : String, field : TextField) : Nil
      x = box.x + 3
      screen.text(x, py, label, Theme.muted, bg)
      vx = x + label.size + 1
      vw = {box.right - 2 - vx, 3}.max
      val = field.value
      pre = field.preedit
      shown = pre.empty? ? val : "#{val[0, field.caret]}#{pre}#{val[field.caret..]}"
      screen.text(vx, py, shown, fg, bg, width: vw)
      if sel && pre.empty?
        cx = field.caret.clamp(0, val.size)
        px = vx + Screen.draw_width(val[0, cx])
        if px < box.right - 2
          ch = cx < val.size ? val[cx] : ' '
          screen.cell(px, py, ch, Theme.bg, Theme.accent_bg)
          screen.cursor(px, py)
        end
      end
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      i = my - (box.y + 2)
      (0 <= i < ROW_COUNT) ? i : nil
    end
  end
end
