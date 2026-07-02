require "./screen"
require "./theme"
require "./frame"
require "../miner"
require "../settings"

module Gori::Tui
  # Everything needed to start a mining session, captured from History/Replay when the
  # user picks "Mine parameters". `applicable`/`default` come from Miner::Detect so the
  # config overlay only offers locations that make sense for THIS request.
  record MineSeed,
    target : String,
    request : Bytes,
    http2 : Bool,
    sni : String?,
    flow_id : Int64?,
    summary : String,
    applicable : Array(Miner::Location),
    default : Array(Miner::Location)

  # The small config popup shown before a mine starts: adaptive location checkboxes,
  # concurrency + notification cyclers, and a Start row. No text field (so no IME
  # plumbing). Restores the last confirmed overlay choices from Settings when present.
  # On Start the Runner reads build_config + seed and hands them to the MinerController.
  class MineConfigOverlay
    CONC_CHOICES = [5, 10, 20, 40]
    NOTIFY_CHOICES = Miner::NotifyMode.values

    getter seed : MineSeed

    def initialize(@seed : MineSeed)
      @checked = Hash(Miner::Location, Bool).new
      @seed.applicable.each { |l| @checked[l] = @seed.default.includes?(l) }
      @conc_idx = CONC_CHOICES.index(10) || 1
      @notify_idx = NOTIFY_CHOICES.index(Miner::NotifyMode::WhenFound) || 0
      @selected = 0
      restore_saved_prefs
    end

    # Remember the last confirmed overlay for the next History/Replay mine.
    def save_prefs : Nil
      locs = @seed.applicable.select { |l| @checked[l]? }.map(&.label)
      notify = NOTIFY_CHOICES[@notify_idx].token
      Settings.save_mine_prefs(locs, CONC_CHOICES[@conc_idx], notify)
    end

    private def restore_saved_prefs : Nil
      return unless Settings.mine_prefs_saved?
      saved = Settings.mine_locations.to_set
      @seed.applicable.each do |loc|
        @checked[loc] = saved.includes?(loc.label)
      end
      if idx = CONC_CHOICES.index(Settings.mine_concurrency)
        @conc_idx = idx
      end
      if mode = Miner::NotifyMode.parse?(Settings.mine_notify)
        @notify_idx = NOTIFY_CHOICES.index(mode) || @notify_idx
      end
    end

    # Rows: one per applicable location, then concurrency + notification cyclers, then Start.
    private def row_count : Int32
      @seed.applicable.size + 3
    end

    private def conc_row : Int32
      @seed.applicable.size
    end

    private def notify_row : Int32
      @seed.applicable.size + 1
    end

    private def start_row : Int32
      @seed.applicable.size + 2
    end

    def on_start_row? : Bool
      @selected == start_row
    end

    def move(d : Int32) : Nil
      @selected = (@selected + d).clamp(0, row_count - 1)
    end

    def set_selected(idx : Int32) : Nil
      @selected = idx.clamp(0, row_count - 1)
    end

    def adjust(d : Int32) : Nil
      case @selected
      when conc_row   then @conc_idx = (@conc_idx + d) % CONC_CHOICES.size
      when notify_row then @notify_idx = (@notify_idx + d) % NOTIFY_CHOICES.size
      end
    end

    # Space/Enter on a location row flips its checkbox; cyclers advance on space.
    def toggle : Nil
      if @selected < @seed.applicable.size
        loc = @seed.applicable[@selected]
        @checked[loc] = !(@checked[loc]? || false)
      elsif @selected == conc_row || @selected == notify_row
        adjust(1)
      end
    end

    def build_config : Miner::Config
      c = Miner::Config.new
      c.locations = @seed.applicable.select { |l| @checked[l]? }
      c.concurrency = CONC_CHOICES[@conc_idx]
      c.notify = NOTIFY_CHOICES[@notify_idx]
      c
    end

    def any_checked? : Bool
      @checked.values.includes?(true)
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 54}.min
      h = {area.h - 2, row_count + 5}.min # title + summary + gap + rows + border
      return nil if w < 30 || h < 6
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "config needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "MINE PARAMETERS", border: Theme.border_focus)
      screen.text(box.x + 2, box.y + 1, @seed.summary, Theme.text_bright, Theme.panel, Attribute::Bold, width: box.w - 4)
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
      if i < @seed.applicable.size
        loc = @seed.applicable[i]
        on = @checked[loc]? || false
        screen.text(x, py, on ? "[x]" : "[ ]", on ? Theme.green : Theme.muted, bg)
        screen.text(x + 4, py, "#{loc.label} mining", sel ? Theme.text_bright : Theme.text, bg)
      elsif i == conc_row
        screen.text(x, py, "concurrency:", Theme.muted, bg)
        screen.text(x + 13, py, "#{CONC_CHOICES[@conc_idx]}  ‹/›", sel ? Theme.text_bright : Theme.text, bg)
      elsif i == notify_row
        screen.text(x, py, "notification:", Theme.muted, bg)
        screen.text(x + 14, py, "#{NOTIFY_CHOICES[@notify_idx].label}  ‹/›", sel ? Theme.text_bright : Theme.text, bg)
      else
        label = any_checked? ? "[ Start mining ]" : "[ select a location ]"
        screen.text(x, py, label, any_checked? ? Theme.accent : Theme.muted, bg, Attribute::Bold)
      end
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      i = my - (box.y + 3)
      (0 <= i < row_count) ? i : nil
    end
  end
end
