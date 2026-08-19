require "./screen"
require "./theme"
require "./frame"
require "./picker_overlay"

module Gori::Tui
  # The reading half of a named GLOBAL library — the Decoder's saved chain specs and the
  # Rewriter's saved rule presets (NamePromptOverlay writes them).
  #
  # It exists because "load by name" used to mean TYPING the name into a blank one-row
  # prompt, with no way to see what had been saved: a name you couldn't recall was a name
  # you couldn't load, and the only way to find out was to open settings.json. So the detail
  # column is not decoration — showing each entry's SPEC next to its name is the point of
  # the card. Structural twin of SubtabPicker (in-memory substring filter, IME preedit,
  # selection-follow scroll, mouse hit-test) over library entries instead of sub-tabs.
  #
  # A dumb form object on the Overlay seam: the load is the injected `on_commit`, which
  # reads `selected_index`. One picker serves both tabs; `noun` only shapes the empty-state
  # text, so a library with nothing in it says which library.
  class LibraryPicker < FilterPickerOverlay
    # `index` is the entry's position in the library array — the value handed back on
    # commit; `label` is its name, `detail` the dim searchable spec.
    record Row, index : Int32, label : String, detail : String

    # Doubles as `Overlay#title`. A field quietly satisfying an abstract method is a real
    # hazard in Crystal (no `override`), so it is spelled out — same note as SubtabPicker.
    getter title : String
    getter action : String          # the ↵ verb, shared by the card hint and the shell's bottom row
    getter noun : String            # what ONE library entry is, for the empty states ("chain" / "rule")
    @indexed : Array({Row, String}) # each row paired with its precomputed filter haystack

    # Remove the highlighted entry from the library, by its `Row#index`. Injected at the
    # open-site like `on_commit`, and for the same reason: the picker knows which row is
    # under the cursor, not which settings section it lives in. nil = a read-only library
    # (the ^X hint then stays off, rather than advertising a key that does nothing).
    #
    # The open-site is expected to call `set_rows` afterwards — deleting is the one action
    # here that changes the list while the card stays up.
    property on_delete : Proc(Int32, Nil)?

    def initialize(@title : String, @rows : Array(Row), @noun : String, @action : String = "load")
      # Precompute each row's filter haystack ONCE (not per keystroke).
      @indexed = @rows.map { |row| {row, "#{row.label} #{row.detail}".downcase} }
      @filtered = @rows
    end

    # Replace the entries after the library changed underneath (a delete). The QUERY is
    # kept — the operator filtered their way to the entry they just removed, and clearing
    # it would throw them back to the full list mid-task — and the cursor holds its place
    # so a second ^X deletes the next entry rather than jumping to the top.
    def set_rows(rows : Array(Row)) : Nil
      at = @selected
      @rows = rows
      @indexed = rows.map { |row| {row, "#{row.label} #{row.detail}".downcase} }
      refilter
      @selected = at.clamp(0, {@filtered.size - 1, 0}.max)
    end

    # The library-array index of the highlighted row (nil when nothing matches).
    def selected_index : Int32?
      @filtered[@selected]?.try(&.index)
    end

    def entry_count : Int32
      @filtered.size
    end

    # --- Overlay contract (see overlay.cr) -----------------------------------
    def key : OverlayKind
      OverlayKind::LibraryPick
    end

    def hint : String
      idle_hint
    end

    private def idle_hint : String
      del = @on_delete ? " · ^X delete" : ""
      "type to filter · ↑/↓ select · ↵ #{@action}#{del} · esc cancel"
    end

    # ^X removes the highlighted entry from the library, in place — the card stays up so a
    # tidy-up is one pass rather than one reopen per entry. No confirm, matching the other
    # settings-library modals (HostsOverlay, EnvOverlay): what is lost is a saved RECIPE,
    # not project data, and re-saving it costs one keystroke from the tab it came from.
    #
    # ^X and not a bare `d`: every printable key belongs to the filter here (the base
    # FilterPickerOverlay routes them to `query_char`), so a letter cannot be an action.
    # ^C/^D reach a modal (`Runner.quit_chord_claimed?` yields the quit-arm to one), but the
    # base drops every unclaimed Ctrl/Alt chord rather than typing its letter, and ⌫ edits
    # the query — ^X is the free chord, and it is the same "delete a set" key the Fuzzer's
    # config pane uses.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      if ev.ctrl? && ev.key.lower_x?
        delete_selected
        return :stay
      end
      super
    end

    private def delete_selected : Nil
      return unless del = @on_delete
      return unless i = selected_index
      del.call(i)
    end

    protected def refilter : Nil
      terms = @query.downcase.split
      @filtered = terms.empty? ? @rows : @indexed.select { |(_, hay)| terms.all? { |t| hay.includes?(t) } }.map(&.first)
      @selected = 0
      @scroll = 0
    end

    # A centred card filling most of the body area (stable height). nil when there isn't
    # room to draw.
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 96}.min
      h = area.h - 2
      return nil if w < 30 || h < 8
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    # Row index under (mx, my), mirroring render's list loop; nil outside the list.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      list_h = list_height(box)
      i = my - (box.y + LIST_OFFSET)
      return nil if i < 0 || i >= list_h
      return nil if mx < box.x + 1 || mx >= box.right - 1
      ri = @scroll + i
      ri < @filtered.size ? ri : nil
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "picker needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, @title, border: Theme.border_focus)

      list_top = render_filter(screen, box, idle_hint)
      list_h = list_height(box)
      ensure_visible(list_h)

      if @filtered.empty?
        # An empty LIBRARY and an empty FILTER are different dead ends, and the way out of
        # each is different (save one / clear the query), so they never share a message.
        msg = @rows.empty? ? "no saved #{@noun} yet" : "no saved #{@noun} matches"
        screen.text(box.x + 3, list_top, msg, Theme.muted, Theme.panel)
        return
      end

      (0...list_h).each do |i|
        ri = @scroll + i
        break if ri >= @filtered.size
        draw_row(screen, box, list_top + i, @filtered[ri], ri == @selected)
      end
    end

    private def draw_row(screen : Screen, box : Rect, ry : Int32, row : Row, active : Bool) : Nil
      bg = active ? Theme.accent_bg : Theme.panel
      fg = active ? Theme.text_bright : Theme.text
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)

      label_x = box.x + 3
      label_w = {box.w // 3, 18}.max
      detail_x = label_x + label_w + 1
      detail_w = {box.right - 1 - detail_x, 1}.max

      screen.text(label_x, ry, row.label, fg, bg, Attribute::Bold, width: label_w)
      screen.text(detail_x, ry, oneline(row.detail), Theme.muted, bg, width: detail_w)
    end

    # A saved spec can carry newlines (a short-circuit stub body); collapse so one entry is
    # always exactly one row and can never push the rows below it out of alignment.
    private def oneline(s : String) : String
      s.gsub(/[\r\n\t]+/, " ")
    end
  end
end
