require "./screen"
require "./theme"
require "./frame"
require "../discover"
require "../settings"

module Gori::Tui
  # A discovery run's seed: one or more candidate start targets so the user can pick the
  # scope from the config popup. When launched on a PATH (a `/notes` flow or node) the choices
  # are `[{"/notes/", url}, {"/", url}]` — the path subtree first (the likely intent), then the
  # whole host. On a host root there is just the one `/` choice. `base_label` is the host.
  record DiscoverSeed,
    choices : Array({String, String}), # [{display path, full URL}]; index 0 is the default
    base_label : String

  # The config popup shown before a discovery run: a start-target chooser, spider/bruteforce
  # checkboxes, a max-depth cycler, a containment cycler, a concurrency cycler, and a Start row.
  # No text field (so no IME plumbing). Mirrors MineConfigOverlay's shape.
  class DiscoverConfigOverlay
    DEPTHS       = [1, 2, 3, 4, 5, 6, 8]
    CONCS        = [10, 20, 40, 80]
    CONTAINMENTS = [Discover::Containment::ScopeAware, Discover::Containment::SameOrigin, Discover::Containment::HostAndSubdomains]
    COMMON_EXT   = %w(php asp aspx jsp html json txt bak zip)

    ROW_TARGET  = 0
    ROW_SPIDER  = 1
    ROW_BRUTE   = 2
    ROW_DEPTH   = 3
    ROW_CONTAIN = 4
    ROW_CONC    = 5
    ROW_EXT     = 6
    ROW_HEADERS = 7
    ROW_START   = 8
    ROWS        = 9

    getter seed : DiscoverSeed
    # Custom request headers ({name, value}) prefilled from a History flow and/or
    # edited in the headers overlay. NOT persisted to prefs — they can carry secrets.
    getter headers : Array({String, String}) = [] of {String, String}

    def initialize(@seed : DiscoverSeed)
      @target_idx = 0
      @spider = true
      @bruteforce = true
      @depth_idx = DEPTHS.index(4) || 3
      @contain_idx = 0
      @conc_idx = CONCS.index(20) || 1
      @ext = false
      @selected = 0
      restore_saved_prefs
    end

    def set_headers(headers : Array({String, String})) : Nil
      @headers = headers
    end

    def on_headers_row? : Bool
      @selected == ROW_HEADERS
    end

    # The chosen start URL + its display path.
    def selected_target : String
      @seed.choices[@target_idx][1]
    end

    def selected_path : String
      @seed.choices[@target_idx][0]
    end

    # Remember the last confirmed overlay for the next Sitemap/History discovery.
    def save_prefs : Nil
      Settings.save_discover_prefs(CONTAINMENTS[@contain_idx].label, DEPTHS[@depth_idx],
        CONCS[@conc_idx], @spider, @bruteforce, @ext)
    end

    private def restore_saved_prefs : Nil
      return unless Settings.discover_prefs_saved?
      @spider = Settings.discover_spider?
      @bruteforce = Settings.discover_bruteforce?
      @ext = Settings.discover_extensions?
      DEPTHS.index(Settings.discover_max_depth).try { |i| @depth_idx = i }
      CONCS.index(Settings.discover_concurrency).try { |i| @conc_idx = i }
      if c = Discover::Containment.parse?(Settings.discover_containment)
        @contain_idx = CONTAINMENTS.index(c) || @contain_idx
      end
    end

    def on_start_row? : Bool
      @selected == ROW_START
    end

    def move(d : Int32) : Nil
      @selected = (@selected + d).clamp(0, ROWS - 1)
    end

    def set_selected(idx : Int32) : Nil
      @selected = idx.clamp(0, ROWS - 1)
    end

    def adjust(d : Int32) : Nil
      case @selected
      when ROW_TARGET  then @target_idx = (@target_idx + d) % @seed.choices.size
      when ROW_DEPTH   then @depth_idx = (@depth_idx + d) % DEPTHS.size
      when ROW_CONTAIN then @contain_idx = (@contain_idx + d) % CONTAINMENTS.size
      when ROW_CONC    then @conc_idx = (@conc_idx + d) % CONCS.size
      end
    end

    def toggle : Nil
      case @selected
      when ROW_SPIDER                                   then @spider = !@spider
      when ROW_BRUTE                                    then @bruteforce = !@bruteforce
      when ROW_EXT                                      then @ext = !@ext
      when ROW_TARGET, ROW_DEPTH, ROW_CONTAIN, ROW_CONC then adjust(1)
      end
    end

    def valid? : Bool
      @spider || @bruteforce
    end

    def build_config : Discover::Config
      Discover::Config.new(
        spider: @spider, bruteforce: @bruteforce,
        max_depth: DEPTHS[@depth_idx], concurrency: CONCS[@conc_idx],
        containment: CONTAINMENTS[@contain_idx],
        extensions: @ext ? COMMON_EXT.dup : [] of String,
        headers: @headers)
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 56}.min
      h = {area.h - 2, ROWS + 5}.min
      return nil if w < 30 || h < 6
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "config needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "DISCOVER", border: Theme.border_focus)
      screen.text(box.x + 2, box.y + 1, @seed.base_label, Theme.text_bright, Theme.panel, Attribute::Bold, width: box.w - 4)
      first = box.y + 3
      ROWS.times do |i|
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
      case i
      when ROW_TARGET  then cyc(screen, x, py, bg, sel, "start at:", selected_path, @seed.choices.size > 1)
      when ROW_SPIDER  then check(screen, x, py, bg, sel, @spider, "spider (follow links)")
      when ROW_BRUTE   then check(screen, x, py, bg, sel, @bruteforce, "bruteforce (probe paths)")
      when ROW_EXT     then check(screen, x, py, bg, sel, @ext, "probe common extensions")
      when ROW_DEPTH   then cyc(screen, x, py, bg, sel, "max depth:", DEPTHS[@depth_idx].to_s)
      when ROW_CONTAIN then cyc(screen, x, py, bg, sel, "scope:", CONTAINMENTS[@contain_idx].label)
      when ROW_CONC    then cyc(screen, x, py, bg, sel, "concurrency:", CONCS[@conc_idx].to_s)
      when ROW_HEADERS then headers_row(screen, x, py, bg, sel)
      else                  start_row(screen, x, py, bg)
      end
    end

    private def start_row(screen : Screen, x : Int32, py : Int32, bg : Color) : Nil
      label = valid? ? "[ Start discovery ]" : "[ enable spider or bruteforce ]"
      screen.text(x, py, label, valid? ? Theme.accent : Theme.muted, bg, Attribute::Bold)
    end

    private def check(screen : Screen, x : Int32, py : Int32, bg : Color, sel : Bool, on : Bool, label : String) : Nil
      screen.text(x, py, on ? "[x]" : "[ ]", on ? Theme.green : Theme.muted, bg)
      screen.text(x + 4, py, label, sel ? Theme.text_bright : Theme.text, bg)
    end

    private def headers_row(screen : Screen, x : Int32, py : Int32, bg : Color, sel : Bool) : Nil
      label = "custom headers:"
      screen.text(x, py, label, Theme.muted, bg)
      val = @headers.empty? ? "none" : "#{@headers.size} set"
      vx = x + label.size + 1
      screen.text(vx, py, val, sel ? Theme.text_bright : Theme.text, bg)
      screen.text(vx + val.size + 2, py, "↵ edit", Theme.muted, bg)
    end

    private def cyc(screen : Screen, x : Int32, py : Int32, bg : Color, sel : Bool, label : String, val : String, cyclable : Bool = true) : Nil
      screen.text(x, py, label, Theme.muted, bg)
      shown = cyclable ? "#{val}  ‹/›" : val
      screen.text(x + label.size + 1, py, shown, sel ? Theme.text_bright : Theme.text, bg)
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      i = my - (box.y + 3)
      (0 <= i < ROWS) ? i : nil
    end
  end
end
