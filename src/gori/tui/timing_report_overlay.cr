require "./overlay"
require "./spark"
require "../repeater/timing"

module Gori::Tui
  # The read-only verdict card for a differential timing run (#1246), opened when the
  # `repeater.timing-analysis` fiber finishes. Displays the verdict, the order bias + p-value,
  # each variant's quartiles, and a shared-scale distribution sparkline per variant — modeled on
  # `SequencerView`'s analysis pane (a colored banner + `Spark` microcharts, no new chart code).
  # A display-only overlay like NoteDetail/Evidence: esc closes, `y` copies the text report.
  class TimingReportOverlay < Overlay
    MAX_W = 76
    MIN_W = 40
    MIN_H = 14

    getter report : Repeater::Timing::Stats::Report
    getter subject : Repeater::Timing::Present::Subject
    @flash : String? = nil

    def initialize(@report, @subject)
    end

    def key : OverlayKind
      OverlayKind::TimingReport
    end

    def title : String
      "TIMING"
    end

    def hint : String
      return "#{@flash} · esc back" if @flash
      "y copy report · esc back"
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      @flash = nil
      return :cancel if ev.key.escape?
      if ev.char == 'y' && !ev.ctrl? && !ev.alt?
        Clipboard.copy(Repeater::Timing::Present.report_text(@report, @subject))
        @flash = "copied"
      end
      :stay
    end

    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      box.nil? || !box.contains?(mx, my) ? :cancel : :stay
    end

    ROWS = 13 # banner + rationale + 2 meta + order + blank + (label+bars)×2 + hist label

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, MAX_W}.min
      h = {area.h - 2, ROWS + 3}.min
      return nil if w < MIN_W || h < MIN_H
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        Overlay.too_small(screen, area, "timing report needs a larger window")
        return
      end
      Frame.card(screen, box, "TIMING ANALYSIS", border: Theme.border_focus)
      subject.origin.try { |o| Frame.border_meta(screen, box, "TIMING ANALYSIS", o, bg: Theme.panel) }
      iw = {box.w - 4, 1}.max
      x = box.x + 2
      y = box.y + 1

      # Verdict banner.
      screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), Theme.panel)
      screen.text(x, y, report.verdict.label, verdict_color, Theme.panel, Attribute::Bold, width: iw)
      y += 1
      screen.text(x, y, report.rationale, Theme.muted, Theme.panel, width: iw)
      y += 1
      transport = subject.transport || subject.mode || "—"
      screen.text(x, y, "transport: #{transport}  ·  #{report.pairs_valid} usable / #{report.iterations} pairs",
        Theme.muted, Theme.panel, width: iw)
      y += 1
      screen.text(x, y, "order: A-slower #{report.a_slower}  B-slower #{report.b_slower}  ties #{report.ties}  (p=#{Repeater::Timing::Stats.fmt_p(report.p_value)})",
        Theme.text, Theme.panel, width: iw)
      y += 2

      # Per-variant quartiles + a sparkline over the shared scale, so the two rows compare.
      lo = report.hist_min.to_f
      hi = report.hist_max.to_f
      draw_variant(screen, x, y, iw, "A", subject.a_label, report.a, lo, hi, report.verdict.a_slower?)
      y += 2
      draw_variant(screen, x, y, iw, "B", subject.b_label, report.b, lo, hi, report.verdict.b_slower?)
    end

    private def draw_variant(screen, x, y, iw, tag, label, d : Repeater::Timing::Stats::VariantDist,
                             lo, hi, slower) : Nil
      color = slower ? Theme.red : Theme.text
      screen.text(x, y, "#{tag}  #{quartile_line(d)}", color, Theme.panel, width: iw)
      # y+1: the request label on the LEFT, its distribution sparkline on the RIGHT — laid out on
      # disjoint spans of the row so the spark never overdraws the label (which names WHICH request
      # this variant is). SequencerView splits the same way.
      spark_w = {iw // 2, Repeater::Timing::Stats::HIST_BINS}.min
      spark_w = 1 if spark_w < 1
      spark_x = x + iw - spark_w
      label_w = {spark_x - x - 1, 1}.max
      screen.text(x, y + 1, "   #{oneline(label)}", Theme.muted, Theme.panel, width: label_w)
      hist = Repeater::Timing::Stats.histogram(d.samples, spark_w, lo, hi)
      screen.text(spark_x, y + 1, Spark.line(hist, spark_w), Theme.accent, Theme.panel)
    end

    private def quartile_line(d : Repeater::Timing::Stats::VariantDist) : String
      return "n=0 (no responses)" if d.n == 0
      s = Repeater::Timing::Stats
      "n=#{d.n}  min #{s.fmt_us(d.min)}  med #{s.fmt_us(d.median.round.to_i64)}  q3 #{s.fmt_us(d.q3.round.to_i64)}  max #{s.fmt_us(d.max)}"
    end

    private def verdict_color : Color
      case report.verdict
      in Repeater::Timing::Stats::Verdict::ASlower, Repeater::Timing::Stats::Verdict::BSlower then Theme.red
      in Repeater::Timing::Stats::Verdict::NoDifference                                       then Theme.green
      in Repeater::Timing::Stats::Verdict::Inconclusive                                       then Theme.yellow
      end
    end

    private def oneline(s : String) : String
      s.gsub(/\s+/, " ").strip
    end
  end
end
