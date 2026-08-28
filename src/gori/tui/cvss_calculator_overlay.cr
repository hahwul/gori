require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./text_field"
require "./viewport"
require "../cvss"

module Gori::Tui
  # The CVSS base-metric builder behind an issue's `cvss` field (#575), for v3.1 and v4.0.
  #
  # TWO ways in, one value out. The `vector:` row is an ordinary text field — paste a
  # `CVSS:3.1/…` or `CVSS:4.0/…` string, or type the bare score (`8.8`) you were handed —
  # and the metric rows under it are the builder for everyone who would rather pick than
  # spell. They stay in step both ways: editing the field re-selects the metrics (and moves
  # the version row) whenever what is in it parses as a version this card can spell, and
  # touching any control rewrites the field. A bare score has no metrics to mirror, so the
  # rows stop tracking it until the next metric edit takes the vector back.
  #
  # That field is why the form's own cvss row is a LAUNCHER: one place to type a vector, one
  # place to build one, and `↵` on the row opens this. Two editable copies of the same value
  # on two cards is how they drift.
  #
  # VERSIONS ARE SEPARATE ASSESSMENTS, not two spellings of one. v4.0 asks questions v3.1
  # does not (`AT`, and the Vulnerable/Subsequent impact split that replaces `S`), and its
  # `UI` has three values where v3.1 has two — FIRST's own guidance is that the two are not
  # convertible. So the version row does not translate: each version keeps its OWN
  # selections, remembered while the card is open, and toggling back restores exactly what
  # you had. Nothing is lost and nothing is invented — a translated vector would put a score
  # in someone's report that nobody assessed.
  #
  # Geometry and controls are the SHARED rule-form ones — `Overlay.rule_form_box`,
  # `Frame.option_cycle`, `Overlay#draw_field`, `Viewport.scroll_to_show` — so this modal has
  # the hands every other form in gori has: ↑/↓ row, ←/→ option, ↵ save, esc cancel. The
  # first cut drew its own 72×14 card with option pills pinned to `box.x + 28`, its own
  # Apply/Cancel buttons and a second copy of the key hint the shell already prints for
  # `hint`. All three ran past the card's own border below ~76 columns, and `Screen#text`
  # clips to the SCREEN, not to the box — so the overflow landed ON the frame, and the
  # in-card hint overwrote the Cancel button even at full width.
  class CvssCalculatorOverlay < Overlay
    # One base metric: the row label, the vector key it writes, and its choices as
    # {vector value, display}. Base metrics only — temporal/threat/environmental are not
    # something an issue's single `cvss` field carries, and the field takes any vector the
    # parser knows anyway (this card just cannot BUILD one).
    struct Metric
      getter label : String
      getter code : String
      getter options : Array({String, String})

      def initialize(@label, @code, @options)
      end

      def names : Array(String)
        @options.map { |o| o[1] }
      end
    end

    # One CVSS version this card can build: its `version:` row label, the vector prefix, and
    # its metric table IN CANONICAL ORDER — the rows are drawn in that order and the vector
    # is joined in it, so the two cannot disagree.
    struct Spec
      getter label : String
      getter prefix : String
      getter metrics : Array(Metric)

      def initialize(@label, @prefix, @metrics)
      end

      # Where this version's option strips start, measured from the label column so its rows
      # line up under each other. One past its longest label; per-version rather than shared,
      # because v4's longer names would otherwise push v3.1's strips right for nothing.
      def indent : Int32
        @metrics.max_of(&.label.size) + 1
      end
    end

    # Impact triads. v3.1's C/I/A and v4's VC/VI/VA and SC/SI/SA all take the same three
    # values, listed LEAST severe first — which is what makes an untouched card score 0.0
    # in both versions (a CVSS base score is 0 when nothing is impacted).
    IMPACT = [{"N", "none"}, {"L", "low"}, {"H", "high"}]

    V31 = Spec.new("3.1", "CVSS:3.1", [
      Metric.new("attack vector (AV):", "AV", [
        {"N", "network"}, {"A", "adjacent"}, {"L", "local"}, {"P", "physical"},
      ]),
      Metric.new("complexity (AC):", "AC", [{"L", "low"}, {"H", "high"}]),
      Metric.new("privileges (PR):", "PR", [{"N", "none"}, {"L", "low"}, {"H", "high"}]),
      Metric.new("interaction (UI):", "UI", [{"N", "none"}, {"R", "required"}]),
      Metric.new("scope (S):", "S", [{"U", "unchanged"}, {"C", "changed"}]),
      Metric.new("confidentiality (C):", "C", IMPACT),
      Metric.new("integrity (I):", "I", IMPACT),
      Metric.new("availability (A):", "A", IMPACT),
    ])

    # v4.0 base (CVSS-B): eleven metrics, all mandatory. `S` is gone — what it approximated
    # is now the Subsequent-system triad — and `AT` is new.
    V40 = Spec.new("4.0", "CVSS:4.0", [
      Metric.new("attack vector (AV):", "AV", [
        {"N", "network"}, {"A", "adjacent"}, {"L", "local"}, {"P", "physical"},
      ]),
      Metric.new("complexity (AC):", "AC", [{"L", "low"}, {"H", "high"}]),
      Metric.new("requirements (AT):", "AT", [{"N", "none"}, {"P", "present"}]),
      Metric.new("privileges (PR):", "PR", [{"N", "none"}, {"L", "low"}, {"H", "high"}]),
      Metric.new("interaction (UI):", "UI", [{"N", "none"}, {"P", "passive"}, {"A", "active"}]),
      Metric.new("vulnerable C (VC):", "VC", IMPACT),
      Metric.new("vulnerable I (VI):", "VI", IMPACT),
      Metric.new("vulnerable A (VA):", "VA", IMPACT),
      Metric.new("subsequent C (SC):", "SC", IMPACT),
      Metric.new("subsequent I (SI):", "SI", IMPACT),
      Metric.new("subsequent A (SA):", "SA", IMPACT),
    ])

    # v3.1 first: it is still what NVD, most scanners and most report templates speak, so a
    # fresh score opens there. A vector pasted into the field moves the row to its OWN
    # version instead (see `sync_from_field`).
    VERSIONS = [V31, V40]

    # Row 0 is the vector field, row 1 the version cycler, then the active version's metrics,
    # then the commit row. The metric count is per version, so the last index is too.
    ROW_VECTOR  = 0
    ROW_VERSION = 1
    ROW_FIRST_M = 2

    getter sel : Int32 = ROW_VECTOR
    getter version_idx : Int32 = 0
    @selections : Array(Hash(String, Int32))
    @scroll : Int32 = 0

    def initialize(initial : String = "")
      # One selection map PER VERSION — see the class note. Toggling is then free of loss.
      @selections = VERSIONS.map do |spec|
        h = Hash(String, Int32).new
        spec.metrics.each { |m| h[m.code] = 0 }
        h
      end
      @vector = TextField.new("")

      # An empty start is deliberately the LEAST severe vector this card can build, not the
      # worst. The first cut defaulted C/I/A to High "so the baseline starts at
      # High/Critical", which meant opening the calculator and pressing ↵ filed a 9.8
      # Critical the operator never chose — and an issue's severity is a number that ends up
      # in someone's report. Every metric starts on its first option; raising one is the
      # operator's move.
      if initial.strip.empty?
        sync_to_field
      else
        @vector.set(initial.strip)
        sync_from_field
      end
    end

    # --- shape ---------------------------------------------------------------

    def spec : Spec
      VERSIONS[@version_idx]
    end

    def metrics : Array(Metric)
      spec.metrics
    end

    def selections : Hash(String, Int32)
      @selections[@version_idx]
    end

    def row_save : Int32
      ROW_FIRST_M + metrics.size
    end

    def row_count : Int32
      row_save + 1
    end

    # --- value ---------------------------------------------------------------

    # What committing applies: the text in the field, trimmed. Empty means "clear the issue's
    # cvss", which is a real intent (the Space menu's Set CVSS opens this on an issue that
    # already has one), so it is not the same thing as an unparseable string.
    def value : String
      @vector.value.strip
    end

    def resolved : {Float64, Store::Severity, String}?
      Gori::Cvss.resolve(value)
    end

    # A value the card refuses to commit: something is typed, and it scores as nothing.
    def invalid? : Bool
      !value.empty? && resolved.nil?
    end

    # The vector the metric rows currently spell, in this version's canonical order.
    def vector_string : String
      sel = selections
      parts = metrics.map { |m| "#{m.code}:#{m.options[sel[m.code]][0]}" }
      "#{spec.prefix}/#{parts.join('/')}"
    end

    def current_score : Float64
      resolved.try(&.[0]) || 0.0
    end

    def current_severity : Store::Severity
      resolved.try(&.[1]) || Store::Severity::Info
    end

    # --- sync ----------------------------------------------------------------

    private def sync_to_field : Nil
      @vector.set(vector_string)
    end

    # Adopt the field's text into the version row and the metric rows — but ONLY for a
    # version this card can spell, and only into THAT version's table. A v1/v2 vector names
    # metrics no table here has (`Au`, an Impact Bias), and walking one in would leave some
    # rows on the pasted value and the rest on a default: a set of selections spelling a
    # DIFFERENT vector than the one in the field. Leave the rows alone instead — the field
    # still holds, and still commits, the vector verbatim.
    private def sync_from_field : Nil
      vec = Gori::Cvss.parse(value)
      return unless vec
      idx = VERSIONS.index { |s| version_matches?(s, vec.version) }
      return unless idx
      @version_idx = idx
      sel = @selections[idx]
      VERSIONS[idx].metrics.each do |m|
        v = metric_value(vec.to_s, m.code)
        next unless v
        opt = m.options.index { |o| o[0] == v }
        sel[m.code] = opt if opt
      end
      clamp_sel
    end

    # v3.0 and v3.1 share this card's eight metrics exactly, so a pasted v3.0 vector builds
    # here — it just re-emits as 3.1 the moment a metric is touched, which is the honest
    # reading of "you edited it with the 3.1 table".
    private def version_matches?(s : Spec, version : String) : Bool
      s.label == version || (s.label == "3.1" && version.starts_with?("3."))
    end

    # The value a canonical vector string gives `code`, walking the same `KEY:VALUE` segments
    # the vector is built from. A plain scan rather than a regex: the codes overlap as
    # substrings (`C` inside `VC`/`SC`/`AC`), so anything less exact reads the wrong metric.
    private def metric_value(vector : String, code : String) : String?
      vector.split('/').each do |part|
        k, _, v = part.partition(':')
        return v if k == code && !v.empty?
      end
      nil
    end

    # --- Overlay contract (see overlay.cr) ---

    def key : OverlayKind
      OverlayKind::CvssCalculator
    end

    def title : String
      "CVSS"
    end

    def hint : String
      case @sel
      when ROW_VECTOR  then "type/paste a vector or score · ↑/↓ row · ↵ save · esc cancel"
      when ROW_VERSION then "←/→ cvss version · ↑/↓ row · ↵ save · esc cancel"
      else
        @sel == row_save ? "↵ save · ↑/↓ row · esc cancel" : "←/→ option · 1..4 pick · ↑/↓ row · ↵ save · esc cancel"
      end
    end

    def text_fields : Array(TextField)
      [@vector]
    end

    def on_vector_row? : Bool
      @sel == ROW_VECTOR
    end

    def on_version_row? : Bool
      @sel == ROW_VERSION
    end

    def on_save_row? : Bool
      @sel == row_save
    end

    def move(d : Int32) : Nil
      @sel = (@sel + d).clamp(0, row_count - 1)
    end

    def set_selected(idx : Int32) : Nil
      @sel = idx.clamp(0, row_count - 1)
    end

    private def clamp_sel : Nil
      @sel = @sel.clamp(0, row_count - 1)
    end

    # ←/→ on the version row. The field is rewritten from the version being switched TO, out
    # of its own remembered selections — the two versions never share a metric map, so this
    # neither loses the assessment you leave nor invents the one you arrive at.
    #
    # …but ONLY when the field is currently what the rows spell. A field holding a bare score
    # (`8.8`) or a vector this card cannot build (v2) is already not tracked by the rows —
    # the class note says so — and rewriting it here meant that opening Set CVSS on an issue
    # scored 8.8, pressing ↓ once and ← to SEE what versions exist silently replaced the value
    # with an all-least-severe vector and the severity with Info. Looking at a row is not an
    # edit. Touching a metric still takes the vector back, which is the deliberate act.
    def cycle_version(d : Int32) : Nil
      rebuild = field_matches_rows?
      @version_idx = (@version_idx + d) % VERSIONS.size
      clamp_sel
      sync_to_field if rebuild
    end

    # Whether the field currently holds exactly what the metric rows spell — i.e. whether the
    # builder, rather than something pasted or typed, is what put the value there.
    private def field_matches_rows? : Bool
      value == vector_string
    end

    # ←/→ (and 1..n) on a metric row. Writes the field, so the two halves never disagree.
    def adjust(d : Int32) : Nil
      return unless m = metric_at(@sel)
      sel = selections
      sel[m.code] = (sel[m.code] + d) % m.options.size
      sync_to_field
    end

    def pick(idx : Int32) : Nil
      return unless m = metric_at(@sel)
      return unless 0 <= idx < m.options.size
      selections[m.code] = idx
      sync_to_field
    end

    private def metric_at(row : Int32) : Metric?
      i = row - ROW_FIRST_M
      (0 <= i < metrics.size) ? metrics[i] : nil
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :cancel if key.escape?
      return :stay if move_row(ev)
      return save_outcome if key.enter?

      if on_vector_row?
        @vector.handle_edit_key(ev)
        sync_from_field
      elsif on_version_row?
        # Direction matters even though two versions make ± identical today: the metric rows
        # one line down step backwards on ←, and a third entry in VERSIONS would silently put
        # this row out of step with them and with its own hint.
        if key.left?
          cycle_version(-1)
        elsif key.right? || key.space?
          cycle_version(1)
        end
      elsif !on_save_row?
        metric_key(ev)
      end
      :stay
    end

    # ↑/↓ and ⇥/⇧⇥ walk the rows on EVERY row, the text field included — the field owns the
    # horizontal keys, not the vertical ones. Answers whether it took the key.
    private def move_row(ev : Termisu::Event::Key) : Bool
      if ev.key.up? || ev.key.back_tab?
        move(-1)
      elsif ev.key.down? || ev.key.tab?
        move(1)
      else
        return false
      end
      # A composition in flight belongs to the row that was taking keys. Left standing it
      # keeps being spliced into what the vector row DISPLAYS (`draw_field`/`TextField#render`
      # both do) while ←/→ edit metric rows — and `value`, which excludes preedit, then
      # commits something other than what the card shows. IssueForm#move_row clears its own
      # for the same reason.
      @vector.set_preedit("") unless on_vector_row?
      true
    end

    private def metric_key(ev : Termisu::Event::Key) : Nil
      if ev.key.left?
        adjust(-1)
      elsif ev.key.right? || ev.key.space?
        adjust(1)
      elsif (c = ev.char) && !ev.ctrl? && !ev.alt? && '1' <= c <= '9'
        pick(c - '1')
      end
    end

    # ↵ on a value that scores as nothing keeps the card up — the save row already says so,
    # and dropping the modal would throw the typed text away with it. Same rule the base
    # class states for a commit closure that returns false, decided here because the card,
    # not the open-site, is what knows the value is unreadable.
    private def save_outcome : Symbol
      invalid? ? :stay : :commit
    end

    def set_preedit(text : String) : Nil
      @vector.set_preedit(text) if on_vector_row?
    end

    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if row = row_at(box, mx, my)
        # Captured BEFORE the row moves: the strip this click is inverting was drawn with the
        # focus state of the LAST frame, and `Frame.option_cycle` only draws the `‹/›` cue —
        # and only reserves room for it — on the focused row.
        was_focused = row == @sel
        set_selected(row)
        return save_outcome if on_save_row?
        if on_version_row?
          # Pick the pill that was clicked, not "the next one": clicking the label already
          # under the cursor must be a no-op, and it was switching away from it.
          if idx = option_at(box, VERSIONS.map(&.label), was_focused, mx)
            cycle_version(idx - @version_idx)
          end
          return :stay
        end
        if m = metric_at(row)
          if idx = option_at(box, m.names, was_focused, mx)
            pick(idx)
            return :stay
          end
        end
      end
      click_text_field(mx, my)
      :stay
    end

    # Inverts the window `render` last drew — `@scroll`, NOT a freshly computed offset. A
    # hit-test that re-derives the scroll can move it, and then the click lands on a row the
    # operator was never looking at (the pairing `Viewport`'s own note names).
    #
    # The BAND check is the other half, and `Rect#contains?` does not supply it: it counts the
    # borders and the blank interior lines as inside, so without this a click on the card's
    # bottom padding resolved to `@scroll + capacity` — one past the last row drawn — and on a
    # clamped card that is a real index, up to and including the commit row. Clicking empty
    # chrome would then SAVE. A click on the top border did the mirror of it, selecting
    # `@scroll - 2`. Only the rows the render actually painted are hits.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      first = box.y + 2
      return nil unless first <= my < first + list_capacity(box)
      i = @scroll + (my - first)
      (0 <= i < row_count) ? i : nil
    end

    # Which option pill on a row column `mx` landed in. Measured off the SAME `" name "` cells
    # `Frame.option_cycle` draws, walked in the same order — the standing hazard this repo
    # names for every clickable row is a second copy of the geometry that drifts from the one
    # the card actually drew. nil when the strip did not fit: the narrow-card fallback draws
    # the lit value alone, which has nothing to hit.
    #
    # `focused` is load-bearing and was the drift: the fit test in `Frame.option_cycle` adds
    # the four columns of the ` ‹/›` cue on the focused row, so there is a band of card widths
    # where the strip is NOT drawn and this method still answered with pill indices. A click
    # on the row then changed the operator's assessment to whatever the phantom geometry said
    # was under the pointer, with nothing on screen to explain it.
    private def option_at(box : Rect, names : Array(String), focused : Bool, mx : Int32) : Int32?
      x = value_x(box)
      cue_w = focused ? Screen.draw_width(" ‹/›") : 0
      return nil if x + names.sum { |n| Screen.draw_width(n) + 2 } + cue_w > box.right - 2
      names.each_with_index do |name, i|
        w = Screen.draw_width(name) + 2
        return i if mx >= x && mx < x + w
        x += w
      end
      nil
    end

    private def value_x(box : Rect) : Int32
      box.x + 3 + spec.indent
    end

    def overlay_box(area : Rect) : Rect?
      Overlay.rule_form_box(area, row_count)
    end

    # Rows the card can actually draw. `rule_form_box`'s natural height is `rows + 4` (border,
    # a blank, the rows, a blank, border), and it CLAMPS to the area — so on a short terminal
    # this is smaller than `row_count` and the list scrolls. v4.0 is fourteen rows, i.e. a
    # natural height of 18 against the 16 a classic 80×24 terminal leaves: without the window
    # the bottom rows, the commit row among them, would simply not be drawn.
    private def list_capacity(box : Rect) : Int32
      {box.h - 4, 1}.max
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "cvss form needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "CVSS v#{spec.label}", border: Theme.border_focus)
      draw_readout(screen, box)

      visible = list_capacity(box)
      @scroll = Viewport.scroll_to_show(@sel, @scroll, visible, row_count)
      (0...visible).each do |i|
        ri = @scroll + i
        break if ri >= row_count
        draw_row(screen, box, ri, box.y + 2 + i)
      end
      # No key hint on the bottom border — the shell draws `hint` in the status strip for
      # the open modal (Runner#key_hints). See ScopeRuleOverlay#render.
    end

    # The score, right-aligned on the card's own top border. It lives there rather than only
    # on the commit row because the commit row SCROLLS on a short terminal, and "what does
    # this currently score as" is the one fact you must be able to see before pressing ↵.
    private def draw_readout(screen : Screen, box : Rect) : Nil
      return if value.empty?
      text = if r = resolved
               "#{sprintf("%.1f", r[0])} #{r[1].label}"
             else
               "unreadable"
             end
      w = Screen.draw_width(text) + 2
      x = box.right - w - 1
      title_end = box.x + 2 + Screen.draw_width(" CVSS v#{spec.label} ")
      return if x <= title_end
      color = resolved ? sev_color(current_severity) : Theme.red
      screen.text(x, box.y, " #{text} ", color, Theme.panel, Attribute::Bold, width: w)
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      sel = i == @sel
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      fg = sel ? Theme.text_bright : Theme.text
      x = box.x + 3

      case
      when i == ROW_VECTOR
        # `TextField#render`, NOT the base class's `draw_field`: a v4.0 base vector is 63
        # columns against the ~59 this field gets on an 80-column terminal, and `draw_field`
        # has no horizontal window — it clips at the width and then declines to draw the block
        # caret or sync the terminal cursor at all past the edge, so an operator editing the
        # tail of the vector the card itself just generated is typing blind. `render` scrolls
        # with the caret (and remembers its own geometry for `click_text_field`).
        screen.text(x, py, "vector:", Theme.muted, bg)
        vx = x + "vector:".size + 1
        @vector.render(screen, vx, py, {box.right - 2 - vx, 1}.max, sel,
          invalid? ? Theme.red : fg, bg)
      when i == ROW_VERSION
        Frame.option_cycle(screen, x, py, box.right - 2, bg, "version:",
          VERSIONS.map(&.label), @version_idx, sel, value_x: value_x(box))
      when m = metric_at(i)
        Frame.option_cycle(screen, x, py, box.right - 2, bg, m.label, m.names,
          selections[m.code], sel, value_x: value_x(box))
      else
        draw_save(screen, box, py, bg)
      end
    end

    # The commit row doubles as the readout in words: what the field scores AS is the one
    # thing to check before applying it, so it is written where the eye already is at ↵.
    private def draw_save(screen : Screen, box : Rect, py : Int32, bg : Color) : Nil
      x = box.x + 3
      w = {box.right - 2 - x, 0}.max
      if value.empty?
        screen.text(x, py, "[ clear cvss ]", Theme.accent, bg, Attribute::Bold, width: w)
      elsif r = resolved
        score, sev, _ = r
        lx = screen.text(x, py, "[ use ", Theme.accent, bg, Attribute::Bold, width: w)
        lx = screen.text(lx, py, sprintf("%.1f", score), sev_color(sev), bg, Attribute::Bold,
          width: {box.right - 2 - lx, 0}.max)
        lx = screen.text(lx, py, " · ", Theme.muted, bg, width: {box.right - 2 - lx, 0}.max)
        lx = screen.text(lx, py, sev.label, sev_color(sev), bg, Attribute::Bold,
          width: {box.right - 2 - lx, 0}.max)
        screen.text(lx, py, " ]", Theme.accent, bg, Attribute::Bold, width: {box.right - 2 - lx, 0}.max)
      else
        screen.text(x, py, "[ not a cvss vector or score ]", Theme.red, bg, Attribute::Bold, width: w)
      end
    end

    private def sev_color(s : Store::Severity) : Color
      case s
      when .critical? then Theme.red
      when .high?     then Theme.orange
      when .medium?   then Theme.yellow
      when .low?      then Theme.accent
      else                 Theme.muted
      end
    end
  end
end
