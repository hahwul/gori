require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "../oast"

module Gori::Tui
  # Popup form for adding or editing ONE OAST provider — same interaction model as
  # ScopeRuleOverlay:
  #   ↑/↓  field (name → type → host → token → Save)
  #   ←/→  cycle the provider type when that row is selected
  #   type into name/host/token when focused; ↵ on Save (or a text row) commits
  #   esc cancels
  class OastProviderOverlay
    KINDS = Gori::Oast::ProviderKind.values

    getter edit_id : Int64?

    # Default (public-preset) host per provider type, so cycling the type in an ADD form
    # prefills a working endpoint (the "quick add" convenience without a separate picker).
    DEFAULT_HOSTS = begin
      h = {} of Gori::Oast::ProviderKind => String
      Gori::Oast::Presets.all.each { |p| h[p.kind] ||= p.host }
      h
    end

    def initialize(*, name : String = "", kind : Gori::Oast::ProviderKind = Gori::Oast::ProviderKind::Interactsh,
                   host : String = "", token : String = "", @edit_id : Int64? = nil)
      @name = TextField.new(name)
      @kind_idx = KINDS.index(kind) || 0
      # Adding with no host → prefill the type's default preset host.
      host = DEFAULT_HOSTS[kind]? || "" if host.empty? && @edit_id.nil?
      @host = TextField.new(host)
      @token = TextField.new(token)
      @host_dirty = !@edit_id.nil? # editing keeps its host; adding auto-syncs to the type default
      @sel = 0 # 0 name · 1 type · 2 host · 3 token · 4 save
    end

    def self.adding : OastProviderOverlay
      new
    end

    def self.editing(id : Int64, name : String, kind : Gori::Oast::ProviderKind, host : String, token : String) : OastProviderOverlay
      new(name: name, kind: kind, host: host, token: token, edit_id: id)
    end

    def provider_name : String
      @name.value.strip
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
      5
    end

    def on_save_row? : Bool
      @sel == 4
    end

    def move(d : Int32) : Nil
      @sel = (@sel + d).clamp(0, row_count - 1)
    end

    def set_selected(idx : Int32) : Nil
      @sel = idx.clamp(0, row_count - 1)
    end

    def adjust(d : Int32) : Nil
      return unless @sel == 1
      @kind_idx = (@kind_idx + d) % KINDS.size
      # Keep the host synced to the type's preset until the user edits it themselves.
      @host = TextField.new(DEFAULT_HOSTS[kind]? || "") unless @host_dirty
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

      case @sel
      when 1 # type cycler
        if key.left?
          adjust(-1)
        elsif key.right?
          adjust(1)
        elsif key.enter? || key.space?
          move(1)
        end
        :stay
      when 4 # save row
        (key.enter? || key.space?) ? :commit : :stay
      else # name / host / token text fields
        if key.enter?
          move(1) # ↵ advances to the next field; only the Save row commits
        else
          @host_dirty = true if @sel == 2 # user edited host → stop auto-syncing to the type
          active_field.handle_edit_key(ev)
        end
        :stay
      end
    end

    private def active_field : TextField
      case @sel
      when 0 then @name
      when 2 then @host
      else        @token
      end
    end

    def set_preedit(text : String) : Nil
      case @sel
      when 0, 2, 3 then active_field.set_preedit(text)
      end
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 56}.min
      h = {area.h - 2, 12}.min # title + 5 rows + padding
      return nil if w < 30 || h < 9
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
        screen.text(box.x + 2, hint_y, "↑/↓ field · ←/› type · ↵ save · esc cancel",
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
      when 0 then draw_field(screen, box, py, "name:", @name, sel, bg, fg)
      when 1
        screen.text(x, py, "type:", Theme.muted, bg)
        tx = x + 6
        KINDS.each_with_index do |k, ki|
          lit = ki == @kind_idx
          col = lit ? (sel ? Theme.text_bright : Theme.accent) : Theme.muted
          tx = screen.text(tx, py, " #{k.label} ", col, bg, lit ? Attribute::Bold : Attribute::None)
        end
        screen.text(tx, py, " ‹/›", Theme.muted, bg)
      when 2 then draw_field(screen, box, py, "host:", @host, sel, bg, fg)
      when 3 then draw_field(screen, box, py, "token:", @token, sel, bg, fg)
      else
        label = valid? ? "[ Save provider ]" : "[ name + host required ]"
        screen.text(x, py, label, valid? ? Theme.accent : Theme.muted, bg, Attribute::Bold)
      end
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
        px = vx + Screen.column_width(val[0, cx])
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
