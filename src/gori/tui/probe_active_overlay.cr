require "./screen"
require "./theme"
require "./frame"
require "../probe/analyzer"
require "../miner/types"
require "../store"
require "../settings"

module Gori::Tui
  # The small popup shown before a manual "Run active scan" fires. A read-only header (the target
  # request, the per-rule request estimate, and the total), then interactive rows: a notification-
  # mode cycler (‹/›, mirroring the Mine popup), an OPTIONAL "unsafe methods" opt-in cycler (shown
  # only when unsafe-method probing would add checks the safe scan can't run — i.e. the flow is a
  # POST/PUT/PATCH/DELETE, or a rule that only runs on non-GET bodies would apply), and a Run row.
  # The Runner reads notify_mode + allow_unsafe? + detail/repeater_id on Run and persists the notify
  # choice. Pure state + render.
  class ProbeActiveOverlay
    NOTIFY_CHOICES = Miner::NotifyMode.values

    getter detail : Store::FlowDetail
    getter repeater_id : Int64?

    @selected : Int32
    @notify_idx : Int32
    @allow_unsafe : Bool
    @show_unsafe_row : Bool
    @info : Array(String)

    # `est_safe` is what runs with the safe-method gate (default); `est_unsafe` is what runs once
    # unsafe methods are allowed (always a superset). When they differ, the unsafe opt-in row is
    # offered; otherwise it's hidden (the common GET/HEAD case is unchanged).
    def initialize(@detail : Store::FlowDetail,
                   @est_safe : Array(Probe::Analyzer::ActiveEstimate),
                   @est_unsafe : Array(Probe::Analyzer::ActiveEstimate),
                   @repeater_id : Int64? = nil)
      @notify_idx = NOTIFY_CHOICES.index(Miner::NotifyMode::WhenFound) || 0
      if mode = Miner::NotifyMode.parse?(Settings.probe_active_notify)
        @notify_idx = NOTIFY_CHOICES.index(mode) || @notify_idx
      end
      @allow_unsafe = false
      # est_unsafe is a superset of est_safe (allow_unsafe only widens the method gate), so a size
      # difference means unsafe probing would add checks — only then is the opt-in meaningful.
      @show_unsafe_row = @est_unsafe.size != @est_safe.size
      @selected = run_row # start on Run so a reflexive ↵ fires with the saved defaults
      @info = build_info
    end

    def notify_mode : Miner::NotifyMode
      NOTIFY_CHOICES[@notify_idx]
    end

    def allow_unsafe? : Bool
      @allow_unsafe
    end

    # The estimate for the current opt-in state (safe by default, widened when unsafe is toggled on).
    private def estimate : Array(Probe::Analyzer::ActiveEstimate)
      @allow_unsafe ? @est_unsafe : @est_safe
    end

    # True when the currently-selected options would send nothing (e.g. a POST with the unsafe
    # opt-in still off) — the Runner uses this to hint instead of firing a no-op scan.
    def estimate_empty? : Bool
      estimate.empty?
    end

    # The "N request(s)" summary the Runner reuses in its post-run toast.
    def total_label : String
      est = estimate
      min = est.sum(&.requests.begin)
      max = est.sum(&.requests.end)
      min == max ? "#{min} request#{min == 1 ? "" : "s"}" : "#{min}–#{max} requests"
    end

    private def notify_row : Int32
      0
    end

    # -1 when hidden; the row indices below shift by whether the unsafe row is shown.
    private def unsafe_row : Int32
      @show_unsafe_row ? 1 : -1
    end

    private def run_row : Int32
      @show_unsafe_row ? 2 : 1
    end

    private def row_count : Int32
      @show_unsafe_row ? 3 : 2
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
      if @selected == notify_row
        @notify_idx = (@notify_idx + d) % NOTIFY_CHOICES.size
      elsif @show_unsafe_row && @selected == unsafe_row
        toggle_unsafe
      end
    end

    # ␣/↵ on the notify row cycles it; on the unsafe row flips the opt-in; the Run row is handled
    # by the Runner.
    def toggle : Nil
      if @selected == notify_row
        adjust(1)
      elsif @show_unsafe_row && @selected == unsafe_row
        toggle_unsafe
      end
    end

    private def toggle_unsafe : Nil
      @allow_unsafe = !@allow_unsafe
      @info = build_info # the estimate list + total change with the opt-in
    end

    private def build_info : Array(String)
      lines = [] of String
      url = @detail.row.url
      url = "#{url[0, 51]}…" if url.size > 52
      lines << "#{@detail.row.method} #{url}"
      lines << ""
      est = estimate
      if est.empty?
        lines << "  no active checks apply"
        # A state-changing flow with the opt-in still off: point at the toggle rather than dead-end.
        if @show_unsafe_row && !@allow_unsafe
          lines << "  (enable unsafe methods below to probe this #{@detail.row.method})"
        end
      else
        est.each { |e| lines << "  #{e.info.name} — #{req_label(e.requests)}" }
      end
      lines << ""
      lines << "⚠ re-sends #{@detail.row.method} — may mutate server data" if @allow_unsafe
      lines << (est.empty? ? "0 requests → #{@detail.row.host}" : "#{total_label} → #{@detail.row.host}")
      lines
    end

    private def req_label(rng : Range(Int32, Int32)) : String
      rng.begin == rng.end ? "#{rng.begin} req" : "#{rng.begin}–#{rng.end} req"
    end

    def overlay_box(area : Rect) : Rect?
      longest = @info.max_of { |l| Screen.display_width(l) }
      w = {area.w - 4, {longest + 6, 54}.max.clamp(30, 64)}.min
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
        fg = if i == 0
               Theme.text_bright
             elsif line.starts_with?("⚠")
               Theme.red
             else
               Theme.text
             end
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
      elsif @show_unsafe_row && i == unsafe_row
        screen.text(x, py, "unsafe methods:", Theme.muted, bg)
        state = @allow_unsafe ? "ON" : "off"
        col = @allow_unsafe ? Theme.red : (sel ? Theme.text_bright : Theme.text)
        screen.text(x + 16, py, "#{state}  ‹/›", col, bg)
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
