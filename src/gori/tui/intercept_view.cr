require "./screen"
require "./theme"
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

    # --- rendering -----------------------------------------------------------

    def render(screen : Screen, rect : Rect, focused : Bool = true) : Nil
      return if rect.empty?
      hint = @editing ? "type to edit · f forward · esc stop" : "j/k move · ↵/e edit · f forward · d drop · F all"
      screen.text(rect.x + 1, rect.y, "INTERCEPT QUEUE (#{@items.size})", Theme::TEXT_BRIGHT, attr: Attribute::Bold)
      screen.text({rect.right - hint.size - 1, rect.x}.max, rect.y, hint, Theme::MUTED)
      screen.hline(rect.x, rect.y + 1, rect.w)

      content = Rect.new(rect.x, rect.y + 2, rect.w, {rect.h - 2, 0}.max)
      return if content.h <= 0

      if @items.empty?
        screen.text(content.x + 1, content.y, "no held messages", Theme::MUTED)
        screen.text(content.x + 1, content.y + 2, "turn intercept on (i) — held requests/responses appear here", Theme::MUTED)
        return
      end

      mid = content.x + content.w // 3
      left = Rect.new(content.x, content.y, {mid - content.x, 0}.max, content.h)
      right = Rect.new(mid + 1, content.y, {content.right - mid - 1, 0}.max, content.h)
      screen.vline(mid, content.y, content.h)
      render_list(screen, left, focused && !@editing)
      render_detail(screen, right, focused && @editing)
    end

    private def render_list(screen : Screen, rect : Rect, focused : Bool) : Nil
      ensure_visible(rect.h)
      (0...rect.h).each do |i|
        idx = @scroll + i
        break if idx >= @items.size
        it = @items[idx]
        y = rect.y + i
        selected = idx == @selected
        bg = selected ? (focused ? Theme::ACCENT_BG : Theme::SELECTION_DIM) : Theme::BG
        screen.fill(Rect.new(rect.x, y, rect.w, 1), bg) if selected
        badge, bcolor = it.kind.request? ? {"REQ", Theme::YELLOW} : {"RES", Theme::ACCENT}
        screen.text(rect.x + 1, y, badge, bcolor, bg, Attribute::Bold)
        label = it.kind.request? ? "#{it.method} #{it.host}#{it.target}" : "#{it.host} #{it.target}"
        screen.text(rect.x + 5, y, label, selected ? Theme::TEXT_BRIGHT : Theme::TEXT, bg, width: rect.w - 12)
        age = "#{(Time.instant - it.held_at).total_seconds.to_i}s"
        screen.text(rect.right - age.size - 1, y, age, Theme::MUTED, bg)
      end
    end

    private def render_detail(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty?
      it = selected_item
      unless it
        screen.text(rect.x + 1, rect.y, "—", Theme::MUTED)
        return
      end
      title = it.kind.request? ? "REQUEST (held)" : "RESPONSE (held)"
      screen.text(rect.x + 1, rect.y, title, @editing ? Theme::TEXT_BRIGHT : Theme::MUTED,
        attr: @editing ? Attribute::Bold : Attribute::None)
      body = Rect.new(rect.x + 1, rect.y + 1, {rect.w - 1, 0}.max, {rect.h - 1, 0}.max)
      if @editing && @loaded_id == it.id
        @editor.render(screen, body, cursor: focused)
      else
        String.new(it.raw).split('\n').map(&.rstrip('\r')).each_with_index do |line, i|
          break if i >= body.h
          screen.text(body.x, body.y + i, line, Theme::TEXT, width: body.w)
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
