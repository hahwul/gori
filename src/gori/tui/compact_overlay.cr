require "./screen"
require "./theme"
require "./frame"
require "./fmt"
require "../store"

module Gori::Tui
  # The scope popup shown before a project is compacted from the ProjectPicker.
  # Adaptive checkboxes (one per removable data category, each annotated with the
  # bytes it would free) + a "keep newest flows" cycler + a Compress row. Pure
  # state + rendering, self-contained like ConfirmDialog/SettingsView: the picker
  # drives it (its own `:compress` mode) and reads `plan` on the Compress row.
  #
  # Response bodies + the raw HTTP/2 frame log default ON — the biggest, safest
  # wins that keep every flow's projection intact; the rest are opt-in. The keep
  # cycler is the only option that drops whole flow rows, so it defaults to "all".
  class CompactOverlay
    record Option, key : Symbol, label : String

    OPTIONS = [
      Option.new(:response_bodies, "Response bodies"),
      Option.new(:request_bodies, "Request bodies"),
      Option.new(:h2_frames, "HTTP/2 frame log"),
      Option.new(:ws_messages, "WebSocket messages"),
      Option.new(:fuzz_bodies, "Fuzzer responses"),
    ]

    # nil = keep every flow (no row deletion); the rest cap history to the newest N.
    KEEP_CHOICES = [nil, 50_000, 10_000, 1_000]

    getter project_name : String

    def initialize(@project_name : String, @stats : Store::CompactStats)
      @checked = {
        :response_bodies => true,
        :request_bodies  => false,
        :h2_frames       => true,
        :ws_messages     => false,
        :fuzz_bodies     => false,
      } of Symbol => Bool
      @keep_idx = 0
      @selected = 0
    end

    private def row_count : Int32
      OPTIONS.size + 2 # options, keep-flows cycler, Compress row
    end

    private def keep_row : Int32
      OPTIONS.size
    end

    private def run_row : Int32
      OPTIONS.size + 1
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

    # ‹/› cycles the keep-flows choice; a no-op elsewhere.
    def adjust(d : Int32) : Nil
      @keep_idx = (@keep_idx + d) % KEEP_CHOICES.size if @selected == keep_row
    end

    # Space/Enter flips a checkbox or advances the keep cycler. The Compress row is
    # handled by the picker (it opens the confirm), not here.
    def toggle : Nil
      if @selected < OPTIONS.size
        key = OPTIONS[@selected].key
        @checked[key] = !@checked[key]
      elsif @selected == keep_row
        adjust(1)
      end
    end

    def plan : Store::CompactPlan
      Store::CompactPlan.new(
        response_bodies: @checked[:response_bodies],
        request_bodies: @checked[:request_bodies],
        h2_frames: @checked[:h2_frames],
        ws_messages: @checked[:ws_messages],
        fuzz_bodies: @checked[:fuzz_bodies],
        keep_flows: KEEP_CHOICES[@keep_idx],
      )
    end

    # Summed reclaimable bytes for the CHECKED blob categories — the estimate shown
    # in the confirm prompt. Old-flow deletion (keep cycler) isn't summed here
    # (its saving depends on per-row sizes); VACUUM reclaims it plus overhead.
    def estimated_bytes : Int64
      total = 0_i64
      OPTIONS.each do |opt|
        total += bytes_for(opt.key) if @checked[opt.key]
      end
      total
    end

    private def bytes_for(key : Symbol) : Int64
      case key
      when :response_bodies then @stats.response_body_bytes
      when :request_bodies  then @stats.request_body_bytes
      when :h2_frames       then @stats.h2_bytes
      when :ws_messages     then @stats.ws_bytes
      when :fuzz_bodies     then @stats.fuzz_bytes
      else                       0_i64
      end
    end

    private def keep_label : String
      KEEP_CHOICES[@keep_idx].try { |n| Fmt.count(n.to_i64) } || "all"
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 52}.min
      h = {area.h - 2, row_count + 5}.min # title + summary + gap + rows + border
      return nil if w < 34 || h < 6
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "compress needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "COMPRESS PROJECT", border: Theme.border_focus)
      summary = "#{@project_name} · DB #{Fmt.size(@stats.db_bytes)}"
      screen.text(box.x + 2, box.y + 1, summary, Theme.text_bright, Theme.panel, Attribute::Bold, width: box.w - 4)
      first = box.y + 3
      row_count.times do |i|
        py = first + i
        break if py >= box.bottom
        draw_row(screen, box, i, py)
      end
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      sel = i == @selected
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      x = box.x + 3
      if i < OPTIONS.size
        opt = OPTIONS[i]
        on = @checked[opt.key]
        screen.text(x, py, on ? "[x]" : "[ ]", on ? Theme.green : Theme.muted, bg)
        screen.text(x + 4, py, opt.label, sel ? Theme.text_bright : Theme.text, bg, width: box.w - 16)
        bytes = bytes_for(opt.key)
        size = bytes > 0 ? Fmt.size(bytes) : "—"
        screen.text(box.right - size.size - 2, py, size, bytes > 0 ? Theme.muted : Theme.border, bg)
      elsif i == keep_row
        screen.text(x, py, "keep newest flows:", Theme.muted, bg)
        screen.text(x + 19, py, "#{keep_label}  ‹/›", sel ? Theme.text_bright : Theme.text, bg)
      else
        screen.text(x, py, "[ Compress ]", Theme.accent, bg, Attribute::Bold)
        hint = "↵ run"
        screen.text(box.right - hint.size - 2, py, hint, Theme.muted, bg)
      end
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      i = my - (box.y + 3)
      (0 <= i < row_count) ? i : nil
    end
  end
end
