require "./geometry"

module Gori::Tui
  # The list-over-preview geometry the History, Issues and Probe tabs share.
  #
  # All three had their own copy, identical to the byte, and the numbers are why that
  # mattered more than the line count: the 55% split, the `rect.h >= 12` floor and the
  # `clamp(6, rect.h - 5)` bound are ONE layout decision. Three copies can disagree about
  # how a short terminal degrades while all three still look right in a full-size window —
  # the size where nobody checks.
  #
  # Only the geometry is shared. The focus vocabulary is not: History cycles three ways
  # (list → request → response, because its preview holds two panes) while Issues and Probe
  # cycle two — see `PreviewPane` for that half, which History deliberately does not include.
  #
  # The includer supplies `preview_enabled?`, its own Settings flag; the three tabs are
  # toggled separately.
  module PreviewSplit
    # Split `rect` into {list, preview}. The preview is nil when it is switched off or the
    # terminal is too short to give both panes a usable height — below 12 rows the list takes
    # the whole rect rather than both panes becoming unreadable.
    def list_split(rect : Rect) : {Rect, Rect?}
      return {rect, nil} unless preview_enabled? && rect.h >= 12
      list_h = (rect.h * 55 // 100).clamp(6, rect.h - 5)
      list = Rect.new(rect.x, rect.y, rect.w, list_h)
      prev = Rect.new(rect.x, rect.y + list_h, rect.w, rect.h - list_h)
      {list, prev}
    end
  end

  # The two-way focus half of that layout — one list, one preview pane, ⇥ between them.
  # Issues and Probe share it; History does not (its preview is two panes, so it owns a
  # three-way cycle of its own).
  #
  # The includer supplies `preview_enabled?` plus `@preview_focus : Symbol` and
  # `@preview_scroll : Int32`, both initialised in its constructor; for the list half,
  # `@issues`, `@selected`, `@scroll`, `move_list` and `list_top` (the first row's screen-y,
  # one row deeper on Probe for its MODE band); and `selected_preview_lines`, the selected
  # row's preview text or nil when nothing is selected.
  module PreviewPane
    # :list or :preview. A Symbol rather than an enum because the shell's focus plumbing
    # speaks symbols; `set_preview_focus` is what keeps a bad one from ever landing here.
    getter preview_focus : Symbol
    getter preview_scroll : Int32

    # Ignores anything outside the vocabulary, so a caller cannot park focus on a value
    # neither pane answers to — which renders as "nothing focused" rather than as an error.
    def set_preview_focus(f : Symbol) : Nil
      @preview_focus = f if {:list, :preview}.includes?(f)
    end

    # One step list → preview (dir > 0) or back; false off either end, so the Runner's focus
    # ring can leave for the tab bar there.
    def step_preview_focus(dir : Int32) : Bool
      return false unless preview_enabled?
      target = dir > 0 ? :preview : :list
      return false if @preview_focus == target
      @preview_focus = target
      true
    end

    def scroll_preview(delta : Int32) : Nil
      return unless @preview_focus == :preview
      wheel_preview(delta)
    end

    # The same scroll without the focus guard — for the wheel, which reads whatever pane is
    # under the pointer and must not move keyboard focus to do it. The ceiling is written at
    # render, where the line count is known (both includers clamp there).
    def wheel_preview(delta : Int32) : Nil
      @preview_scroll = {@preview_scroll + delta, 0}.max
    end

    def move(delta : Int32) : Nil
      if preview_enabled? && @preview_focus == :preview
        scroll_preview(delta)
        return
      end
      move_list(delta)
    end

    # Inverts render_list's row layout: maps a click to a row index, or nil past the last
    # populated row / outside the list pane.
    def list_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      list_rect, _ = list_split(rect)
      return nil if mx < list_rect.x || mx >= list_rect.right
      top = list_top(list_rect)
      list_h = {list_rect.bottom - top, 0}.max
      i = my - top
      return nil if i < 0 || i >= list_h
      idx = @scroll + i
      idx < @issues.size ? idx : nil
    end

    # The row a click on the list's scroll gauge asks for. The gauge rides the frame's right
    # hairline — one column OUTSIDE the list rect, which is why `list_row_at` cannot answer it
    # — and this list's `@scroll` is DERIVED from the selection by render's `ensure_visible`,
    # so the answer is a selection, not an offset. See `Frame.scroll_gauge_row`.
    def gauge_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      list_rect, _ = list_split(rect)
      top = list_top(list_rect) # same band list_row_at and the gauge draw measure
      Frame.scroll_gauge_row(Rect.new(list_rect.x, top, list_rect.w, {list_rect.bottom - top, 0}.max),
        @issues.size, mx, my)
    end

    # True when (mx,my) lands in the bottom preview pane.
    def preview_at?(rect : Rect, mx : Int32, my : Int32) : Bool
      _, prev = list_split(rect)
      !!prev.try(&.contains?(mx, my))
    end

    # Bottom summary of the selected row (settings:layout issues_preview / probe_preview).
    private def render_preview_pane(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty? || rect.h < 2
      border = Frame.pane_border(focused)
      Frame.inner_divider(screen, rect, rect.y, border: border)
      lines = selected_preview_lines
      unless lines
        screen.text(rect.x + 1, rect.y + 1, "preview — select an issue", Theme.muted,
          width: {rect.w - 2, 0}.max)
        return
      end
      active = focused && @preview_focus == :preview
      body = Rect.new(rect.x, rect.y + 1, rect.w, {rect.h - 1, 0}.max)
      return if body.h < 1
      screen.fill(body, Theme.selection_dim) if active
      bg = active ? Theme.selection_dim : Theme.bg
      # Write the clamp back so overscrolling a short preview can't inflate @preview_scroll
      # and leave later scroll-up presses dead until it drains back into range.
      @preview_scroll = @preview_scroll.clamp(0, {lines.size - 1, 0}.max)
      sc = @preview_scroll
      w = {body.w - 2, 0}.max
      (0...body.h).each do |i|
        li = sc + i
        break if li >= lines.size
        fg, text = lines[li]
        screen.text(body.x + 1, body.y + i, text, fg, bg, width: w)
      end
      Frame.scroll_gauge(screen, body, lines.size, sc, false, bg)
    end
  end
end
