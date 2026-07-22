require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "../oast"
require "../oast/provider_config"

module Gori::Tui
  # Popup form for adding or editing ONE OAST provider — same interaction model as
  # CustomRuleOverlay (which has the same global/project scope row):
  #   ↑/↓  field (name → scope → type → host → token → Save)
  #   ←/→  cycle the scope / provider type when that row is selected
  #   type into name/host/token when focused; ↵ on Save (or a text row) commits
  #   esc cancels
  # The runner validates + persists on :commit (global → settings.json, project → project DB).
  class OastProviderOverlay
    ROW_NAME  = 0
    ROW_SCOPE = 1
    ROW_TYPE  = 2
    ROW_HOST  = 3
    ROW_TOKEN = 4
    ROW_SAVE  = 5
    ROW_COUNT = 6

    SCOPES = %w[project global]
    KINDS  = Gori::Oast::ProviderKind.values

    getter edit_id : String?
    getter edit_scope : String?

    @scope_i : Int32
    @kind_idx : Int32

    # Default (public-preset) host per provider type, so cycling the type in an ADD form
    # prefills a working endpoint (the "quick add" convenience without a separate picker).
    DEFAULT_HOSTS = begin
      h = {} of Gori::Oast::ProviderKind => String
      Gori::Oast::Presets.all.each { |p| h[p.kind] ||= p.host }
      h
    end

    def initialize(*, name : String = "", scope : String = "project",
                   kind : Gori::Oast::ProviderKind = Gori::Oast::ProviderKind::Interactsh,
                   host : String = "", token : String = "",
                   @edit_id : String? = nil, @edit_scope : String? = nil)
      @name = TextField.new(name)
      @scope_i = idx(SCOPES, scope)
      @kind_idx = KINDS.index(kind) || 0
      # Adding with no host → prefill the type's default preset host.
      host = DEFAULT_HOSTS[kind]? || "" if host.empty? && @edit_id.nil?
      @host = TextField.new(host)
      @token = TextField.new(token)
      @host_dirty = !@edit_id.nil? # editing keeps its host; adding auto-syncs to the type default
      @sel = 0                      # ROW_NAME · ROW_SCOPE · ROW_TYPE · ROW_HOST · ROW_TOKEN · ROW_SAVE
    end

    def self.adding : OastProviderOverlay
      new
    end

    def self.editing(config : Gori::Oast::ProviderConfig) : OastProviderOverlay
      kind = Gori::Oast::ProviderKind.parse?(config.kind) || Gori::Oast::ProviderKind::Interactsh
      new(name: config.name, scope: config.scope, kind: kind, host: config.host, token: config.token || "",
        edit_id: config.id, edit_scope: config.scope)
    end

    private def idx(list : Array(String), v : String) : Int32
      list.index(v) || 0
    end

    def provider_name : String
      @name.value.strip
    end

    def scope : String
      SCOPES[@scope_i]
    end

    def kind : Gori::Oast::ProviderKind
      KINDS[@kind_idx]
    end

    def host : String
      @host.value.strip
    end

    def token : String?
      t = @token.value.strip
      t.empty? ? nil : t
    end

    def editing? : Bool
      !@edit_id.nil?
    end

    def valid? : Bool
      !provider_name.empty? && !host.empty?
    end

    private def row_count : Int32
      ROW_COUNT
    end

    def on_save_row? : Bool
      @sel == ROW_SAVE
    end

    def move(d : Int32) : Nil
      @sel = (@sel + d).clamp(0, row_count - 1)
    end

    def set_selected(idx : Int32) : Nil
      @sel = idx.clamp(0, row_count - 1)
    end

    private def cycler_row?(row : Int32) : Bool
      row == ROW_SCOPE || row == ROW_TYPE
    end

    def adjust(d : Int32) : Nil
      case @sel
      when ROW_SCOPE
        @scope_i = (@scope_i + d) % SCOPES.size
      when ROW_TYPE
        @kind_idx = (@kind_idx + d) % KINDS.size
        # Keep the host synced to the type's preset until the user edits it themselves.
        @host = TextField.new(DEFAULT_HOSTS[kind]? || "") unless @host_dirty
      end
    end

    # :stay | :commit | :cancel
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :cancel if key.escape?
      if key.tab? || key.down?
        move(1)
        return :stay
      elsif key.back_tab? || key.up?
        move(-1)
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
      else # name / host / token text fields
        if key.enter?
          move(1) # ↵ advances to the next field; only the Save row commits
        else
          @host_dirty = true if @sel == ROW_HOST # user edited host → stop auto-syncing to the type
          active_field.handle_edit_key(ev)
        end
        :stay
      end
    end

    private def active_field : TextField
      case @sel
      when ROW_NAME then @name
      when ROW_HOST then @host
      else               @token
      end
    end

    def set_preedit(text : String) : Nil
      case @sel
      when ROW_NAME, ROW_HOST, ROW_TOKEN then active_field.set_preedit(text)
      end
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 56}.min
      h = {area.h - 2, ROW_COUNT + 6}.min # title + rows + padding
      return nil if w < 30 || h < 10
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "provider form needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      title = editing? ? "EDIT OAST PROVIDER" : "ADD OAST PROVIDER"
      Frame.card(screen, box, title, border: Theme.border_focus)
      first = box.y + 2
      row_count.times do |i|
        py = first + i
        break if py >= box.bottom - 1
        draw_row(screen, box, i, py)
      end
      hint_y = box.bottom - 1
      if hint_y > first
        screen.text(box.x + 2, hint_y, "↑/↓ field · ←/› options · ↵ save · esc cancel",
          Theme.muted, Theme.panel, width: box.w - 4)
      end
    end

    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      sel = i == @sel
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      x = box.x + 3
      fg = sel ? Theme.text_bright : Theme.text
      case i
      when ROW_NAME then draw_field(screen, box, py, "name:", @name, sel, bg, fg)
      when ROW_SCOPE
        draw_cycle(screen, x, py, bg, sel, "scope:", SCOPES, @scope_i)
      when ROW_TYPE
        draw_cycle(screen, x, py, bg, sel, "type:", KINDS.map(&.label), @kind_idx)
      when ROW_HOST  then draw_field(screen, box, py, "host:", @host, sel, bg, fg)
      when ROW_TOKEN then draw_field(screen, box, py, "token:", @token, sel, bg, fg)
      else
        label = valid? ? "[ Save provider ]" : "[ name + host required ]"
        screen.text(x, py, label, valid? ? Theme.accent : Theme.muted, bg, Attribute::Bold)
      end
    end

    private def draw_cycle(screen : Screen, x : Int32, py : Int32, bg : Color, row_sel : Bool,
                           label : String, opts : Array(String), sel_i : Int32) : Nil
      screen.text(x, py, label, Theme.muted, bg)
      col = row_sel ? Theme.text_bright : Theme.accent
      tx = screen.text(x + label.size + 1, py, opts[sel_i], col, bg, Attribute::Bold)
      screen.text(tx, py, "  ‹/›", Theme.muted, bg)
    end

    private def draw_field(screen : Screen, box : Rect, py : Int32, label : String,
                           field : TextField, sel : Bool, bg : Color, fg : Color) : Nil
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
      (0 <= i < row_count) ? i : nil
    end
  end
end
