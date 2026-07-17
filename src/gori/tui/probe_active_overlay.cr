require "./screen"
require "./theme"
require "./frame"
require "../probe/analyzer"
require "../miner/types"
require "../store"
require "../settings"

module Gori::Tui
  # The small popup shown before a manual "Run active scan" fires. A read-only header (the target
  # request, the per-rule request estimate, and the total), then two interactive rows: a
  # notification-mode cycler (‹/›, mirroring the Mine popup) and a Run row. The Runner reads
  # notify_mode + detail/repeater_id on Run and persists the notify choice. Pure state + render.
  class ProbeActiveOverlay
    NOTIFY_CHOICES = Miner::NotifyMode.values

    getter detail : Store::FlowDetail
    getter repeater_id : Int64?

    @selected : Int32
    @notify_idx : Int32
    @info : Array(String)

    def initialize(@detail : Store::FlowDetail,
                   @estimate : Array(Probe::Analyzer::ActiveEstimate),
                   @repeater_id : Int64? = nil)
      @notify_idx = NOTIFY_CHOICES.index(Miner::NotifyMode::WhenFound) || 0
      if mode = Miner::NotifyMode.parse?(Settings.probe_active_notify)
        @notify_idx = NOTIFY_CHOICES.index(mode) || @notify_idx
      end
      @selected = run_row # start on Run so a reflexive ↵ fires with the saved default
      @info = build_info
    end

    def notify_mode : Miner::NotifyMode
      NOTIFY_CHOICES[@notify_idx]
    end

    # The "N request(s)" summary the Runner reuses in its post-run toast.
    def total_label : String
      min = @estimate.sum { |e| e.requests.begin }
      max = @estimate.sum { |e| e.requests.end }
      min == max ? "#{min} request#{min == 1 ? "" : "s"}" : "#{min}–#{max} requests"
    end

    private def notify_row : Int32
      0
    end

    private def run_row : Int32
      1
    end

    private def row_count : Int32
      2
    end

    def on_run_row? : Bool
      @selected == run_row
    end

    def move(d : Int32) : Nil
      @selected = (@selected + d).clamp(0, row_count - 1)
    end

    def set_selected(idx : Int32) : Nil
      @selected = idx.clamp(0, row_count - 1)
    end

    def adjust(d : Int32) : Nil
      @notify_idx = (@notify_idx + d) % NOTIFY_CHOICES.size if @selected == notify_row
    end

    # ␣/↵ on the notify row cycles it; the Run row is handled by the Runner.
    def toggle : Nil
      adjust(1) if @selected == notify_row
    end

    private def build_info : Array(String)
      lines = [] of String
      url = @detail.row.url
      url = "#{url[0, 51]}…" if url.size > 52
      lines << "#{@detail.row.method} #{url}"
      lines << ""
      @estimate.each { |e| lines << "  #{e.info.name} — #{req_label(e.requests)}" }
      lines << ""
      lines << "#{total_label} → #{@detail.row.host}"
      lines
    end

    private def req_label(rng : Range(Int32, Int32)) : String
      rng.begin == rng.end ? "#{rng.begin} req" : "#{rng.begin}–#{rng.end} req"
    end

    def overlay_box(area : Rect) : Rect?
      longest = @info.max_of { |l| Screen.display_width(l) }
      w = {area.w - 4, {longest + 6, 54}.max.clamp(30, 60)}.min
      h = {area.h - 2, @info.size + row_count + 4}.min # title + info + gap + rows + border
      return nil if w < 30 || h < 6
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    # First interactive row's y: below the header block + a blank spacer line.
    private def first_row_y(box : Rect) : Int32
      box.y + 1 + @info.size + 1
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "window too small · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "RUN ACTIVE SCAN", border: Theme.border_focus)
      @info.each_with_index do |line, i|
        py = box.y + 1 + i
        break if py >= box.bottom - 2
        fg = i == 0 ? Theme.text_bright : Theme.text
        screen.text(box.x + 2, py, line, fg, Theme.panel, width: box.w - 4)
      end
      row_count.times { |i| draw_row(screen, box, i) }
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32) : Nil
      py = first_row_y(box) + i
      return if py >= box.bottom
      sel = i == @selected
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      x = box.x + 3
      if i == notify_row
        screen.text(x, py, "notification:", Theme.muted, bg)
        screen.text(x + 14, py, "#{notify_mode.label}  ‹/›", sel ? Theme.text_bright : Theme.text, bg)
      else
        screen.text(x, py, "[ Run active scan ]", Theme.accent, bg, Attribute::Bold)
      end
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      i = my - first_row_y(box)
      (0 <= i < row_count) ? i : nil
    end
  end
end
