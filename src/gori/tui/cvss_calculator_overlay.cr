require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./text_field"
require "../cvss"

module Gori::Tui
  # The CVSS v3.1 base-metric builder behind an issue's `cvss` field (#575).
  #
  # TWO ways in, one value out. The `vector:` row is an ordinary text field — paste a
  # `CVSS:3.1/…` string, or type the bare score (`8.8`) you were handed — and the eight
  # metric rows under it are the builder for everyone who would rather pick than spell.
  # They stay in step both ways: editing the field re-selects the metrics whenever what is
  # in it parses as v3.x, and touching any metric rewrites the field. A bare score has no
  # metrics to mirror, so the rows simply stop tracking it until the next metric edit takes
  # the vector back — which is the honest reading, not a sync bug.
  #
  # That field is why the form's own cvss row is a LAUNCHER rather than a second text box:
  # one place to type a vector, one place to build one, and `↵` on the row opens this. Two
  # editable copies of the same value on two cards is how they drift.
  #
  # Geometry and controls are the SHARED rule-form ones — `Overlay.rule_form_box`,
  # `Frame.option_cycle`, `Overlay#draw_field` — so this modal has the hands every other
  # form in gori has: ↑/↓ row, ←/→ option, ↵ save, esc cancel. The first cut drew its own
  # 72×14 card with option pills pinned to `box.x + 28`, its own Apply/Cancel buttons and a
  # second copy of the key hint the shell already prints for `hint`. All three ran past the
  # card's own border below ~76 columns, and `Screen#text` clips to the SCREEN, not to the
  # box — so the overflow landed ON the frame, and the in-card hint overwrote the Cancel
  # button even at full width. `option_cycle` is the fix that generalises: it measures the
  # strip and falls back to the lit value alone when the card is too narrow for it.
  class CvssCalculatorOverlay < Overlay
    # One base metric: the row label, the vector key it writes, and its choices as
    # {vector value, display}. v3.1 base only — temporal/environmental are not a thing an
    # issue's single `cvss` field carries, and the field takes any vector version anyway
    # (this card just cannot BUILD one).
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

    METRICS = [
      Metric.new("attack vector (AV):", "AV", [
        {"N", "network"}, {"A", "adjacent"}, {"L", "local"}, {"P", "physical"},
      ]),
      Metric.new("complexity (AC):", "AC", [
        {"L", "low"}, {"H", "high"},
      ]),
      Metric.new("privileges (PR):", "PR", [
        {"N", "none"}, {"L", "low"}, {"H", "high"},
      ]),
      Metric.new("interaction (UI):", "UI", [
        {"N", "none"}, {"R", "required"},
      ]),
      Metric.new("scope (S):", "S", [
        {"U", "unchanged"}, {"C", "changed"},
      ]),
      Metric.new("confidentiality (C):", "C", [
        {"N", "none"}, {"L", "low"}, {"H", "high"},
      ]),
      Metric.new("integrity (I):", "I", [
        {"N", "none"}, {"L", "low"}, {"H", "high"},
      ]),
      Metric.new("availability (A):", "A", [
        {"N", "none"}, {"L", "low"}, {"H", "high"},
      ]),
    ]

    # Row 0 is the vector field, rows 1..8 the metrics, the last row commits.
    ROW_VECTOR = 0
    ROW_SAVE   = METRICS.size + 1
    ROW_COUNT  = METRICS.size + 2

    # Where every metric row's option strip starts, measured from the label column so the
    # eight rows line up under each other. One past the longest label.
    VALUE_INDENT = METRICS.max_of(&.label.size) + 1

    getter selections : Hash(String, Int32)
    getter sel : Int32 = ROW_VECTOR

    def initialize(initial : String = "")
      @selections = Hash(String, Int32).new
      METRICS.each { |m| @selections[m.code] = 0 }
      @vector = TextField.new("")

      # An empty start is deliberately the LEAST severe vector this card can build
      # (AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:N → 0.0), not the worst. The first cut defaulted
      # C/I/A to High "so the baseline starts at High/Critical", which meant opening the
      # calculator and pressing ↵ filed a 9.8 Critical the operator never chose — and an
      # issue's severity is a number that ends up in someone's report. Every metric here
      # starts at its first (least severe) option; raising one is the operator's move.
      if initial.strip.empty?
        sync_to_field
      else
        @vector.set(initial.strip)
        sync_from_field
      end
    end

    # --- value ---------------------------------------------------------------

    # What committing applies: the text in the field, trimmed. Empty means "clear the
    # issue's cvss", which is a real intent (the detail-scope verb opens this on an issue
    # that already has one), so it is not the same thing as an unparseable string.
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

    # The vector the eight metric rows currently spell.
    def vector_string : String
      parts = METRICS.map { |m| "#{m.code}:#{m.options[@selections[m.code]][0]}" }
      "CVSS:3.1/#{parts.join('/')}"
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

    # Adopt the field's text into the metric rows — but ONLY for a v3.x vector, the one
    # version this card's eight rows can actually spell. A v2 vector names `Au` where v3
    # names PR/UI and a v4 one names `AT`/`VC`/`VI`/`VA`; walking either into this table
    # would leave some rows on the pasted value and the rest on a default, i.e. a set of
    # selections that spells a DIFFERENT vector than the one in the field. Leave the rows
    # alone instead: the field still holds (and still commits) the vector verbatim.
    private def sync_from_field : Nil
      vec = Gori::Cvss.parse(value)
      return unless vec && vec.version.starts_with?("3.")
      vec.to_s.split('/').skip(1).each do |part|
        k, _, v = part.partition(':')
        next if v.empty?
        m = METRICS.find { |metric| metric.code == k }
        next unless m
        idx = m.options.index { |opt| opt[0] == v }
        @selections[k] = idx if idx
      end
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
      when ROW_VECTOR then "type/paste a vector or score · ↑/↓ row · ↵ save · esc cancel"
      when ROW_SAVE   then "↵ save · ↑/↓ row · esc cancel"
      else                 "←/→ option · 1..4 pick · ↑/↓ row · ↵ save · esc cancel"
      end
    end

    def text_fields : Array(TextField)
      [@vector]
    end

    def on_vector_row? : Bool
      @sel == ROW_VECTOR
    end

    def on_save_row? : Bool
      @sel == ROW_SAVE
    end

    def move(d : Int32) : Nil
      @sel = (@sel + d).clamp(0, ROW_COUNT - 1)
    end

    def set_selected(idx : Int32) : Nil
      @sel = idx.clamp(0, ROW_COUNT - 1)
    end

    # ←/→ (and 1..4) on a metric row. Writes the field, so the two halves never disagree.
    def adjust(d : Int32) : Nil
      return unless m = metric_at(@sel)
      @selections[m.code] = (@selections[m.code] + d) % m.options.size
      sync_to_field
    end

    def pick(idx : Int32) : Nil
      return unless m = metric_at(@sel)
      return unless 0 <= idx < m.options.size
      @selections[m.code] = idx
      sync_to_field
    end

    private def metric_at(row : Int32) : Metric?
      (1 <= row <= METRICS.size) ? METRICS[row - 1] : nil
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :cancel if key.escape?
      return :stay if move_row(ev)
      return save_outcome if key.enter?

      if on_vector_row?
        @vector.handle_edit_key(ev)
        sync_from_field
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
        set_selected(row)
        return save_outcome if on_save_row?
        if m = metric_at(row)
          if idx = option_at(box, m, mx)
            pick(idx)
            return :stay
          end
        end
      end
      click_text_field(mx, my)
      :stay
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      i = my - (box.y + 2)
      (0 <= i < ROW_COUNT) ? i : nil
    end

    # Which option pill on `m`'s row column `mx` landed in. Measured off the SAME
    # `" name "` cells `Frame.option_cycle` draws, walked in the same order — the standing
    # hazard this repo names for every clickable row is a second copy of the geometry that
    # drifts from the one the card actually drew. nil when the strip did not fit (the
    # narrow-card fallback draws the lit value alone, which has nothing to hit).
    private def option_at(box : Rect, m : Metric, mx : Int32) : Int32?
      x = value_x(box)
      names = m.names
      return nil if x + names.sum { |n| Screen.draw_width(n) + 2 } > box.right - 2
      names.each_with_index do |name, i|
        w = Screen.draw_width(name) + 2
        return i if mx >= x && mx < x + w
        x += w
      end
      nil
    end

    private def value_x(box : Rect) : Int32
      box.x + 3 + VALUE_INDENT
    end

    def overlay_box(area : Rect) : Rect?
      Overlay.rule_form_box(area, ROW_COUNT)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "cvss form needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "CVSS v3.1", border: Theme.border_focus)
      first = box.y + 2
      ROW_COUNT.times do |i|
        py = first + i
        break if py >= box.bottom - 1
        draw_row(screen, box, i, py)
      end
      # No key hint on the bottom border — the shell draws `hint` in the status strip for
      # the open modal (Runner#key_hints). See ScopeRuleOverlay#render.
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      sel = i == @sel
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      fg = sel ? Theme.text_bright : Theme.text
      x = box.x + 3

      if i == ROW_VECTOR
        draw_field(screen, box, py, bg, invalid? ? Theme.red : fg, sel, "vector:", @vector)
      elsif m = metric_at(i)
        Frame.option_cycle(screen, x, py, box.right - 2, bg, m.label, m.names,
          @selections[m.code], sel, value_x: value_x(box))
      else
        draw_save(screen, box, py, bg)
      end
    end

    # The commit row doubles as the readout: what the field currently scores AS is the one
    # thing to check before applying it, so it is written where the eye already is at ↵
    # rather than on a summary line of its own.
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
