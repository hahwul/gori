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
  # `@preview_scroll : Int32`, both initialised in its constructor.
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

    # ⇥. A no-op while the preview is off — otherwise focus moves to a band that is not
    # drawn and the tab looks frozen.
    def cycle_preview_focus : Nil
      return unless preview_enabled?
      @preview_focus = @preview_focus == :list ? :preview : :list
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
  end
end
