require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "../cvss"

module Gori::Tui
  # Interactive CVSS v3.1 base metrics calculator modal (#575).
  # Lets operators visually toggle and select metric values (AV, AC, PR, UI, S, C, I, A)
  # with live calculation of score, qualitative severity, and canonical vector string.
  class CvssCalculatorOverlay < Overlay
    struct Metric
      getter name : String
      getter code : String
      getter options : Array({String, String})

      def initialize(@name, @code, @options)
      end
    end

    METRICS = [
      Metric.new("Attack Vector (AV)", "AV", [
        {"N", "Network"},
        {"A", "Adjacent"},
        {"L", "Local"},
        {"P", "Physical"},
      ]),
      Metric.new("Attack Complexity (AC)", "AC", [
        {"L", "Low"},
        {"H", "High"},
      ]),
      Metric.new("Privileges Required (PR)", "PR", [
        {"N", "None"},
        {"L", "Low"},
        {"H", "High"},
      ]),
      Metric.new("User Interaction (UI)", "UI", [
        {"N", "None"},
        {"R", "Required"},
      ]),
      Metric.new("Scope (S)", "S", [
        {"U", "Unchanged"},
        {"C", "Changed"},
      ]),
      Metric.new("Confidentiality (C)", "C", [
        {"N", "None"},
        {"L", "Low"},
        {"H", "High"},
      ]),
      Metric.new("Integrity (I)", "I", [
        {"N", "None"},
        {"L", "Low"},
        {"H", "High"},
      ]),
      Metric.new("Availability (A)", "A", [
        {"N", "None"},
        {"L", "Low"},
        {"H", "High"},
      ]),
    ]

    CARD_W = 72
    CARD_H = 14

    getter selected_metric : Int32 = 0
    getter selections : Hash(String, Int32)
    property on_apply : Proc(String, Nil)?

    def initialize(initial : String = "")
      @selections = Hash(String, Int32).new
      METRICS.each do |m|
        @selections[m.code] = 0
      end
      # Default CIA to High so baseline starts at High/Critical
      @selections["C"] = 2
      @selections["I"] = 2
      @selections["A"] = 2

      parse_initial(initial) unless initial.strip.empty?
    end

    private def parse_initial(vec_str : String) : Nil
      if vec = ::CVSS.parse?(vec_str) || ::CVSS.parse?(vec_str.upcase)
        canonical = vec.to_s
        canonical.split('/')[1..].each do |part|
          next unless part.includes?(':')
          k, v = part.split(':', 2)
          if m = METRICS.find { |metric| metric.code == k }
            idx = m.options.index { |opt| opt[0] == v }
            @selections[k] = idx if idx
          end
        end
      end
    end

    def key : OverlayKind
      OverlayKind::CvssCalculator
    end

    def title : String
      "CVSS v3.1 CALCULATOR"
    end

    def hint : String
      "↑/↓ metric · ←/→ cycle · 1..4 pick · ↵ apply · esc cancel"
    end

    def vector_string : String
      parts = METRICS.map do |m|
        val = m.options[@selections[m.code]][0]
        "#{m.code}:#{val}"
      end
      "CVSS:3.1/#{parts.join('/')}"
    end

    def current_score : Float64
      Gori::Cvss.score_for(vector_string) || 0.0
    end

    def current_severity : Store::Severity
      Gori::Cvss.severity_for(vector_string) || Store::Severity::Info
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      c = ev.char
      case
      when key.escape?
        :cancel
      when key.enter?
        apply
        :commit
      when key.up?, key.lower_k?, c == 'k'
        @selected_metric = (@selected_metric - 1) % METRICS.size
        :stay
      when key.down?, key.lower_j?, c == 'j'
        @selected_metric = (@selected_metric + 1) % METRICS.size
        :stay
      when key.left?, key.lower_h?, c == 'h'
        cycle_option(-1)
        :stay
      when key.right?, key.lower_l?, key.space?, c == 'l'
        cycle_option(1)
        :stay
      when c && '1' <= c <= '4'
        idx = c - '1'
        m = METRICS[@selected_metric]
        if idx < m.options.size
          @selections[m.code] = idx
        end
        :stay
      else
        :stay
      end
    end

    private def cycle_option(delta : Int32) : Nil
      m = METRICS[@selected_metric]
      curr = @selections[m.code]
      @selections[m.code] = (curr + delta) % m.options.size
    end

    private def apply : Nil
      @on_apply.try &.call(vector_string)
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, CARD_W}.min
      return nil if w < 40 || area.h < CARD_H
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - CARD_H) // 2, w, CARD_H)
    end

    def handle_wheel(step : Int32) : Nil
      @selected_metric = (@selected_metric + step).clamp(0, METRICS.size - 1)
    end

    def handle_click(area : Rect, x : Int32, y : Int32) : Symbol
      box = overlay_box(area)
      return :stay unless box
      return :cancel unless box.contains?(x, y)

      # Check metric rows
      METRICS.each_with_index do |m, i|
        row_y = box.y + 1 + i
        if y == row_y
          @selected_metric = i
          # Check which option pill was clicked
          curr_x = box.x + 28
          m.options.each_with_index do |opt, opt_idx|
            opt_w = opt[1].size + 2 # "[Name]"
            if x >= curr_x && x < curr_x + opt_w
              @selections[m.code] = opt_idx
              return :stay
            end
            curr_x += opt_w + 1
          end
          return :stay
        end
      end

      # Check action buttons on row 11
      btn_y = box.y + 11
      if y == btn_y
        apply_w = 11  # "[ Apply (↵) ]"
        cancel_w = 16 # "[ Cancel (Esc) ]"
        if x >= box.x + 2 && x < box.x + 2 + apply_w
          apply
          return :commit
        elsif x >= box.x + 16 && x < box.x + 16 + cancel_w
          return :cancel
        end
      end

      :stay
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      return unless box

      Frame.card(screen, box, title, border: Theme.border_focus)

      # Render each metric row
      METRICS.each_with_index do |m, i|
        row_y = box.y + 1 + i
        is_focused = @selected_metric == i

        if is_focused
          screen.cell(box.x + 1, row_y, '▎', Theme.accent, Theme.panel)
        end

        label_color = is_focused ? Theme.accent : Theme.text
        screen.text(box.x + 2, row_y, m.name.ljust(25), label_color, Theme.panel)

        curr_x = box.x + 28
        selected_idx = @selections[m.code]
        m.options.each_with_index do |opt, opt_idx|
          is_opt_selected = opt_idx == selected_idx
          opt_label = is_opt_selected ? "[#{opt[1]}]" : " #{opt[1]} "

          fg = if is_opt_selected
                 Theme.accent
               elsif is_focused
                 Theme.text
               else
                 Theme.muted
               end

          screen.text(curr_x, row_y, opt_label, fg, Theme.panel)
          curr_x += opt_label.size + 1
        end
      end

      # Divider
      div_y = box.y + 9
      (box.x + 1...box.x + box.w - 1).each do |x|
        screen.cell(x, div_y, '─', Theme.muted, Theme.panel)
      end

      # Summary row (score + severity + vector)
      summary_y = box.y + 10
      score = current_score
      sev = current_severity
      sev_col = sev_color(sev)

      screen.text(box.x + 2, summary_y, "Score: ", Theme.muted, Theme.panel)
      score_str = sprintf("%.1f", score)
      screen.text(box.x + 9, summary_y, "#{score_str} #{sev.label.upcase}", sev_col, Theme.panel)

      v_label = vector_string
      max_v_w = box.w - 30
      disp_v = v_label.size > max_v_w ? "#{v_label[0, max_v_w - 3]}..." : v_label
      screen.text(box.x + 26, summary_y, disp_v, Theme.text_bright, Theme.panel)

      # Buttons & hint
      btn_y = box.y + 11
      screen.text(box.x + 2, btn_y, "[ Apply (↵) ]", Theme.accent, Theme.panel)
      screen.text(box.x + 16, btn_y, "[ Cancel (Esc) ]", Theme.muted, Theme.panel)

      hint = "↑/↓: metric · ←/→: option · 1..4: pick · ↵: apply"
      screen.text(box.x + box.w - hint.size - 2, btn_y, hint, Theme.muted, Theme.panel)
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
