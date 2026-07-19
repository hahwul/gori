require "./settings_catalog"
require "./settings_view"
require "./frame"
require "./chrome"

module Gori::Tui
  # The unified Preferences modal — ONE grouped settings surface reachable everywhere:
  # in-app (Ctrl+, / the ⚙ top-bar chip / the "Settings: …" palette entries) and the
  # project picker (Ctrl+,). It replaces both the small per-section overlay card and the
  # (removed) Settings tab, so there is a single settings paradigm — a modal layer — in
  # every context.
  #
  # Groups + sections come from SettingsCatalog. A :form section edits INLINE via a
  # per-section SettingsView (the shared field engine — render_fields_into / toggle_or_move
  # / insert / save), so the modal and any remaining SettingsView surface can't diverge. A
  # :opener section (theme list, tabs/hosts/env/hotkeys editors) is a single "↵ open" row
  # whose action the HOST performs — the view stays self-contained and returns an Outcome
  # the caller acts on, so the SAME view works in the Runner (opens the dedicated overlay,
  # live-applies a save) and the picker (allow_openers: false → openers are hidden and a
  # save just persists, there being no live proxy).
  class PreferencesView
    # What a keystroke asks the host to do. :saved / :open carry the section symbol;
    # :saved also carries the toast the host shows after its own live-apply.
    record Outcome, kind : Symbol, section : Symbol? = nil, message : String? = nil
    NONE = Outcome.new(:none)

    GROUP_LABELS = SettingsCatalog::GROUPS.map { |g| g[1] }

    @group : Int32 = 0
    @focus : Int32 = 0       # index into the active group's flat target list
    @scroll : Int32 = 0      # first visible virtual row (derived — follows @focus)
    @on_strip : Bool = false # true = the group strip holds focus (←/→ switch groups)
    @strip_start : Int32 = 0
    @status : String? = nil

    def initialize(@allow_openers : Bool = true)
      # One SettingsView per form section, reloaded from live Settings.
      @forms = {} of Symbol => SettingsView
      SettingsCatalog.all.each do |s|
        next unless s.kind == :form
        v = SettingsView.new
        v.reload(s.sym)
        @forms[s.sym] = v
      end
    end

    # Reopen at the default entry (Ctrl+, / ⚙): refresh from disk, land on the group strip
    # so the user picks a group first (then ↓ into fields).
    def open_default : Nil
      reload_all
      @group = 0
      @on_strip = true
      @focus = 0
      @scroll = 0
      sync_focus
    end

    # Reopen positioned at a specific section (the "Settings: Network" palette entries):
    # jump to its group and land on its first field. Falls back to the default.
    def open(section : Symbol) : Nil
      reload_all
      SettingsCatalog::GROUPS.each_with_index do |g, gi|
        secs = sections_of(g[0])
        next unless secs.any?(&.sym.==(section))
        @group = gi
        @on_strip = false
        @scroll = 0
        @focus = target_index_of(section)
        sync_focus
        return
      end
      open_default
    end

    private def reload_all : Nil
      @forms.each { |sym, v| v.reload(sym) }
      @status = nil
    end

    # --- input: returns an Outcome the host acts on ---
    def handle_key(ev : Termisu::Event::Key) : Outcome
      key = ev.key
      c = ev.char || key.to_char
      @status = nil # clear stale save/reset feedback; activate_focus/reset_focused re-set it
      return handle_strip_key(key) if @on_strip

      case
      when key.escape?
        return Outcome.new(:close)
      when key.up?
        if @focus <= 0
          @on_strip = true # step up to the group strip
        else
          @focus -= 1
          sync_focus
        end
      when key.down?
        if @focus < targets.size - 1
          @focus += 1
          sync_focus
        end
      when key.left?
        focused_form.try(&.toggle_or_move(-1)) # bool flip / choice cycle / caret ←
      when key.right?
        focused_form.try(&.toggle_or_move(1)) # bool flip / choice cycle / caret →
      when key.enter?
        return activate_focus
      when key.backspace?
        focused_form.try(&.backspace)
      when key.delete?
        focused_form.try(&.delete)
      when ev.ctrl? && key.lower_r?
        reset_focused
      when c && !ev.ctrl? && !ev.alt?
        # Printable (incl. space) → into the focused field, exactly like the overlay:
        # space toggles a bool / cycles a choice / types into text.
        if f = focused_form
          f.insert(c)
          f.set_preedit("")
        end
      else
        return NONE
      end
      NONE
    end

    private def handle_strip_key(key : Termisu::Input::Key) : Outcome
      case
      when key.escape?, key.up?  then return Outcome.new(:close)
      when key.left?             then set_group(@group - 1)
      when key.right?            then set_group(@group + 1)
      when key.down?, key.enter? then @on_strip = false
      end
      NONE
    end

    def set_preedit(text : String) : Bool
      return false if @on_strip
      if f = focused_form
        f.set_preedit(text)
        return true
      end
      false
    end

    def wheel(step : Int32) : Nil
      return if @on_strip
      @focus = (@focus + step).clamp(0, {targets.size - 1, 0}.max)
      sync_focus
    end

    def click(area : Rect, mx : Int32, my : Int32) : Outcome
      box = overlay_box(area)
      return Outcome.new(:close) unless box.contains?(mx, my) # click outside the card → close
      strip = Rect.new(box.x + 2, box.y + 2, box.w - 4, 1)
      if strip.contains?(mx, my)
        if seg = Chrome.strip_segments(strip, GROUP_LABELS, @group, @strip_start, nil).find { |(_, r)| r.contains?(mx, my) }
          @on_strip = true
          set_group(seg[0])
        end
        return NONE
      end
      content = content_rect(box)
      if content.contains?(mx, my)
        if idx = target_at_row((my - content.y) + @scroll)
          @on_strip = false
          @focus = idx
          sync_focus
        end
      end
      NONE
    end

    private def set_group(idx : Int32) : Nil
      idx = idx.clamp(0, GROUP_LABELS.size - 1)
      return if idx == @group
      @group = idx
      @focus = 0
      @scroll = 0
      @status = nil
      sync_focus
    end

    private def activate_focus : Outcome
      return NONE unless ft = focused_target
      sec = ft[0]
      return open_or_block(sec.sym) if sec.kind == :opener
      form = @forms[sec.sym]
      if opener = form.focused_opener
        return open_or_block(opener) # e.g. Network's "Hostname overrides" action row
      end
      msg = form.save
      @status = msg # reflect the save in the footer (self-contained feedback for the picker)
      Outcome.new(:saved, sec.sym, msg)
    end

    # An opener is actionable only where the dedicated overlay exists (in-app). In the
    # picker (allow_openers: false) it's a no-op with a hint instead.
    private def open_or_block(sym : Symbol) : Outcome
      return Outcome.new(:open, sym) if @allow_openers
      @status = "open a project to edit this"
      NONE
    end

    private def reset_focused : Nil
      if f = focused_form
        f.reset_to_defaults # working copy only — still needs ↵ to persist, so no confirm
        @status = "section reset to defaults — ↵ to save"
      end
    end

    # --- rendering ---
    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      return if box.w < 24 || box.h < 10
      Frame.card(screen, box, "PREFERENCES", border: Theme.border_focus)
      strip = Rect.new(box.x + 2, box.y + 2, box.w - 4, 1)
      @strip_start = Chrome.render_tab_strip(screen, strip, GROUP_LABELS, @group, @on_strip, @strip_start)
      screen.hline(box.x + 1, box.y + 3, box.w - 2, fg: @on_strip ? Theme.focus_gold : Theme.border, bg: Theme.panel)
      render_group(screen, content_rect(box), !@on_strip)
      render_footer(screen, box)
    end

    # The centred modal card. Height fits the tallest group's content (so switching groups
    # doesn't resize the card), capped to the terminal; content scrolls when it overflows.
    private def overlay_box(area : Rect) : Rect
      tallest = SettingsCatalog::GROUPS.max_of { |g| height_of(g[0]) }
      w = {area.w - 4, 82}.min
      # Fit the tallest group's content but never exceed the area — on a short terminal h
      # drops below the render guard (box.h < 10) and the modal simply doesn't draw, rather
      # than spilling the card over the tab bar / status rows.
      h = {tallest + 7, area.h - 2}.min
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    # Interior content rows (between the strip divider and the two footer rows).
    private def content_rect(box : Rect) : Rect
      Rect.new(box.x + 2, box.y + 4, box.w - 4, {box.h - 7, 1}.max)
    end

    private def render_group(screen : Screen, content : Rect, body_focused : Bool) : Nil
      ensure_scroll(content)
      fsym = nil.as(Symbol?)
      ffield = -1
      if body_focused && (ft = focused_target)
        fsym = ft[0].sym
        ffield = ft[1]
      end
      y = content.y - @scroll
      group_sections.each do |sec|
        draw_subheader(screen, content, sec.title, y)
        y += 1
        if sec.kind == :form
          fc = field_count(sec.sym)
          focused_idx = fsym == sec.sym ? ffield : -1
          @forms[sec.sym].render_fields_into(screen, Rect.new(content.x, y, content.w, fc), focused_idx, content)
          y += fc
        else
          draw_opener(screen, content, sec, y, fsym == sec.sym)
          y += 1
        end
        y += 1 # spacer between sections
      end
    end

    private def draw_subheader(screen : Screen, content : Rect, title : String, y : Int32) : Nil
      return unless content.y <= y < content.bottom
      screen.fill(Rect.new(content.x, y, content.w, 1), Theme.panel)
      screen.text(content.x, y, title.upcase, Theme.focus_gold, Theme.panel, Attribute::Bold, width: content.w)
    end

    private def draw_opener(screen : Screen, content : Rect, sec : SettingsCatalog::Section, y : Int32, focused : Bool) : Nil
      return unless content.y <= y < content.bottom
      bg = focused ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(content.x, y, content.w, 1), bg)
      screen.cell(content.x, y, focused ? '▎' : ' ', Theme.accent, bg)
      cue = "↵ open"
      lx = content.x + 2
      cx = {content.right - cue.size, lx + sec.title.size + 1}.max
      screen.text(lx, y, sec.title, focused ? Theme.text_bright : Theme.text, bg, width: {cx - lx, 1}.max)
      screen.text(cx, y, cue, focused ? Theme.accent : Theme.muted, bg, width: {content.right - cx, 1}.max)
    end

    private def render_footer(screen : Screen, box : Rect) : Nil
      note_y = box.bottom - 3
      hint_y = box.bottom - 2
      iw = {box.w - 4, 0}.max
      note = @status || focused_hint
      screen.text(box.x + 2, note_y, note, @status ? Theme.green : Theme.muted, Theme.panel, width: iw)
      hint = @on_strip ? "←/→ group · ↓/↵ enter · esc close" : "↑/↓ field · ←/→ edit · ↵ save · ^R reset · esc close"
      hx = {box.right - hint.size - 2, box.x + 2}.max
      screen.text(hx, hint_y, hint, Theme.muted, Theme.panel, width: {box.right - hx - 1, 0}.max)
    end

    private def focused_hint : String
      return "←/→ pick a settings group, ↓ to edit" if @on_strip
      return "" unless ft = focused_target
      sec, field = ft
      if sec.kind == :form && field >= 0
        flds = SettingsView::SECTIONS[sec.sym]?
        fld = flds ? flds[field]? : nil
        return fld ? fld.hint : ""
      end
      "↵ opens the #{sec.title} editor"
    end

    # Keep the focused row inside the content viewport (scroll follows focus).
    private def ensure_scroll(content : Rect) : Nil
      total = group_height
      vis = {content.h, 1}.max
      top = focus_row_offset
      @scroll = top if top < @scroll
      @scroll = top - vis + 1 if top >= @scroll + vis
      @scroll = @scroll.clamp(0, {total - vis, 0}.max)
    end

    # --- catalog / geometry helpers ---
    private def group_sym : Symbol
      SettingsCatalog::GROUPS[@group][0]
    end

    # The group's sections, honouring allow_openers (the picker hides :opener rows it has
    # no editor for).
    private def sections_of(gsym : Symbol) : Array(SettingsCatalog::Section)
      SettingsCatalog.sections_in(gsym).select { |s| @allow_openers || s.kind == :form }
    end

    private def group_sections : Array(SettingsCatalog::Section)
      sections_of(group_sym)
    end

    private def field_count(sym : Symbol) : Int32
      SettingsView::SECTIONS[sym]?.try(&.size) || 0
    end

    private def targets : Array({SettingsCatalog::Section, Int32})
      out = [] of {SettingsCatalog::Section, Int32}
      group_sections.each do |sec|
        if sec.kind == :form
          field_count(sec.sym).times { |i| out << {sec, i} }
        else
          out << {sec, -1}
        end
      end
      out
    end

    private def focused_target : {SettingsCatalog::Section, Int32}?
      t = targets
      return nil if t.empty?
      t[@focus.clamp(0, t.size - 1)]
    end

    private def focused_form : SettingsView?
      return nil unless ft = focused_target
      sec, field = ft
      return nil unless sec.kind == :form && field >= 0
      @forms[sec.sym]
    end

    private def sync_focus : Nil
      return unless ft = focused_target
      sec, field = ft
      @forms[sec.sym].set_field(field) if sec.kind == :form && field >= 0
    end

    # The flat target index of a section's first field/opener within its group.
    private def target_index_of(section : Symbol) : Int32
      i = 0
      group_sections.each do |sec|
        return i if sec.sym == section
        i += sec.kind == :form ? field_count(sec.sym) : 1
      end
      0
    end

    private def height_of(gsym : Symbol) : Int32
      sections_of(gsym).sum { |sec| 1 + (sec.kind == :form ? field_count(sec.sym) : 1) + 1 }
    end

    private def group_height : Int32
      height_of(group_sym)
    end

    private def focus_row_offset : Int32
      return 0 unless ft = focused_target
      fsec, ffield = ft
      row = 0
      group_sections.each do |sec|
        header = row
        row += 1
        if sec.kind == :form
          return ffield == 0 ? header : row + ffield if sec.sym == fsec.sym
          row += field_count(sec.sym)
        else
          return header if sec.sym == fsec.sym
          row += 1
        end
        row += 1
      end
      row
    end

    private def target_at_row(vrow : Int32) : Int32?
      row = 0
      ti = 0
      group_sections.each do |sec|
        row += 1 # header
        if sec.kind == :form
          fc = field_count(sec.sym)
          fc.times do |i|
            return ti if row + i == vrow
            ti += 1
          end
          row += fc
        else
          return ti if row == vrow
          ti += 1
          row += 1
        end
        row += 1 # spacer
      end
      nil
    end
  end
end
