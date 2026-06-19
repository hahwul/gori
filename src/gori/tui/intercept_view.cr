require "./screen"
require "./theme"
require "./frame"
require "./highlight"
require "./text_area"
require "../interceptor"

module Gori::Tui
  # The Intercept tab: a queue of held requests/responses (P4 — the human decides
  # to Forward or Drop each one; the proxy fiber blocks until then). Left: the
  # queue (REQ/RES badge, method, host+target, waiting age). Right: the selected
  # item's raw bytes in a TextArea (editable — Forward sends the edited bytes).
  # Pure view: it reads the shared Interceptor snapshot; the Runner performs the
  # actual forward/drop. No diff (that's Replay's job).
  class InterceptView
    getter? editing : Bool

    def initialize
      @items = [] of Interceptor::Item
      @selected = 0
      @scroll = 0
      @editor = TextArea.new
      @editing = false
      @loaded_id = nil.as(Int64?) # which item the editor currently holds
    end

    # Fresh snapshot (cheap; called on enter AND every frame via the 50ms loop).
    # If the edited item vanished (forwarded/dropped/released), drop edit mode.
    def reload(interceptor : Interceptor) : Nil
      @items = interceptor.pending
      @selected = @selected.clamp(0, {@items.size - 1, 0}.max)
      if @editing && (id = @loaded_id) && @items.none? { |it| it.id == id }
        @editing = false
        @loaded_id = nil
      end
    end

    def selected_item : Interceptor::Item?
      @items[@selected]?
    end

    def selected_id : Int64?
      selected_item.try(&.id)
    end

    def empty? : Bool
      @items.empty?
    end

    def move(delta : Int32) : Nil
      return if @items.empty? || @editing
      @selected = (@selected + delta).clamp(0, @items.size - 1)
    end

    def toggle_edit : Nil
      if @editing
        @editing = false
      elsif it = selected_item
        @editor.set_text(String.new(it.raw))
        @loaded_id = it.id
        @editing = true
      end
    end

    def stop_edit : Nil
      @editing = false
    end

    # The forward payload: edited bytes when the editor holds THIS item, else the
    # original bytes (byte-exact passthrough, P7).
    def forward_bytes(it : Interceptor::Item) : Bytes
      @loaded_id == it.id ? @editor.to_bytes : it.raw
    end

    def edit_insert(ch : Char) : Nil
      @editor.insert(ch) if @editing
    end

    def edit_newline : Nil
      @editor.insert_newline if @editing
    end

    def edit_backspace : Nil
      @editor.backspace if @editing
    end

    def edit_move(dr : Int32, dc : Int32) : Nil
      @editor.move(dr, dc) if @editing
    end

    # --- focus ring (driven by the Runner's Tab/Shift-Tab) ---
    # Two panes: queue (editing off) ▸ detail editor (editing on). Entering the
    # detail pane starts editing the selected item; pane_advance returns false at
    # an end so the Runner wraps focus back to the tab bar.
    def focus_first : Nil
      @editing = false
    end

    def focus_last : Nil
      toggle_edit unless @editing
    end

    def pane_advance(dir : Int32) : Bool
      if dir > 0
        return false if @editing # detail → off the end (to the tab bar)
        return false unless selected_item
        toggle_edit # queue → detail (start editing)
        true
      else
        return false unless @editing # queue → off the end (to the tab bar)
        @editing = false             # detail → queue
        true
      end
    end

    # --- rendering -----------------------------------------------------------

    def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      if @items.empty?
        Frame.card(screen, rect, "INTERCEPT", bg: Theme::BG, border: pane_border(focused))
        inner = rect.inset(1, 1)
        screen.text(inner.x + 1, inner.y, "no held messages", Theme::MUTED)
        screen.text(inner.x + 1, inner.y + 2, "turn intercept on (i) — held requests/responses appear here", Theme::MUTED)
        return
      end

      half = {rect.w // 3, 1}.max
      left = Rect.new(rect.x, rect.y, half, rect.h)
      right = Rect.new(rect.x + half + 1, rect.y, {rect.w - half - 1, 0}.max, rect.h)
      render_list(screen, left, focused && !@editing)
      render_detail(screen, right, focused && @editing)
    end

    private def pane_border(focused : Bool) : Color
      Frame.pane_border(focused)
    end

    private def render_list(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "QUEUE (#{@items.size})", bg: Theme::BG, border: pane_border(focused))
      inner = rect.inset(1, 1)
      ensure_visible(inner.h)
      (0...inner.h).each do |i|
        idx = @scroll + i
        break if idx >= @items.size
        it = @items[idx]
        y = inner.y + i
        selected = idx == @selected
        bg = selected ? (focused ? Theme::ACCENT_BG : Theme::SELECTION_DIM) : Theme::BG
        if selected
          screen.fill(Rect.new(inner.x, y, inner.w, 1), bg)
          screen.cell(inner.x, y, '▎', Theme::ACCENT, bg)
        end
        badge, bcolor = it.kind.request? ? {"REQ", Theme::YELLOW} : {"RES", Theme::ACCENT}
        screen.text(inner.x + 1, y, badge, bcolor, bg, Attribute::Bold)
        label = it.kind.request? ? "#{it.method} #{it.host}#{it.target}" : "#{it.host} #{it.target}"
        screen.text(inner.x + 5, y, label, selected ? Theme::TEXT_BRIGHT : Theme::TEXT, bg, width: {inner.w - 6, 1}.max)
      end
    end

    private def render_detail(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      it = selected_item
      title = it.nil? ? "DETAIL" : (it.kind.request? ? "REQUEST (held)" : "RESPONSE (held)")
      Frame.card(screen, rect, title, bg: Theme::BG, border: pane_border(focused))
      inner = rect.inset(1, 1)
      unless it
        screen.text(inner.x, inner.y, "—", Theme::MUTED)
        return
      end
      mode = it.kind.request? ? :request : :response
      if @editing && @loaded_id == it.id
        @editor.render(screen, inner, cursor: focused, highlight: mode)
      else
        styled = Highlight.from_lines(String.new(it.raw).split('\n').map(&.rstrip('\r')), it.kind.request?)
        styled.each_with_index do |line, i|
          break if i >= inner.h
          Highlight.draw(screen, inner.x, inner.y + i, line, width: inner.w)
        end
      end
    end

    private def ensure_visible(h : Int32) : Nil
      return if h <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - h + 1 if @selected >= @scroll + h
      @scroll = 0 if @scroll < 0
    end
  end
end
