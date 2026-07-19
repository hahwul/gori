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
  # live-applies a save) and the picker. `allowed_openers` gates which opener sections show
  # + fire: nil = all (in-app); the picker passes a small set (just :theme, which it can
  # host as a card) so tabs/hosts/env/hotkeys stay hidden there.
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
    # Whether @status reports a FAILURE (rejected save, blocked opener, unsaved-edit
    # warning) rather than a success. Kept as a flag rather than re-sniffing the string:
    # SettingsView can match on its own short internal status ("invalid port"), but what
    # lands here is `save`'s RETURN message ("settings: invalid bind port …"), so the
    # prefixes it looks for are not present and every failure rendered green.
    @status_warn : Bool = false
    @confirm_discard : Bool = false # an esc landed on unsaved edits; the next one discards

    def initialize(@allowed_openers : Set(Symbol)? = nil)
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
      @confirm_discard = false
    end

    # Re-pull ONE section from Settings, leaving every other section's working copy alone.
    # Used when a dedicated editor changed something a form row summarizes (the Hostnames
    # editor and Network's "N entries" row), so returning to the modal doesn't show a lie.
    def refresh(section : Symbol) : Nil
      return unless v = @forms[section]?
      return if v.dirty? # never clobber unsaved edits — a stale summary beats losing typed input
      v.reload(section)
      sync_focus
    end

    # The titles of sections edited but not yet saved (↵ saves the focused section only).
    private def dirty_titles : Array(String)
      SettingsCatalog.all.compact_map do |s|
        f = @forms[s.sym]?
        s.title if f && f.dirty?
      end
    end

    def dirty? : Bool
      @forms.each_value.any?(&.dirty?)
    end

    # --- input: returns an Outcome the host acts on ---
    def handle_key(ev : Termisu::Event::Key) : Outcome
      key = ev.key
      c = ev.char || key.to_char
      @status = nil # clear stale save/reset feedback; activate_focus/reset_focused re-set it
      @status_warn = false
      # A discard warning survives exactly one keystroke: the esc that would confirm it.
      confirming, @confirm_discard = @confirm_discard, false
      # Modal-wide chords, claimed before the strip/body split so they work on both:
      # ^P jumps to the palette (as it does from every other overlay), Ctrl+, closes the
      # modal the same chord opened.
      # ^P leaves the modal just as surely as esc does — the host sets @overlay = :none —
      # so it has to pass the same unsaved-edits guard. It was the one exit that didn't,
      # and the pending edits then died silently at the next open's reload_all.
      if ev.ctrl? && key.lower_p?
        return NONE unless close_or_warn(confirming).kind == :close
        return Outcome.new(:palette)
      end
      return close_or_warn(confirming) if ev.ctrl? && key.comma?
      return handle_strip_key(key, confirming) if @on_strip

      case
      when key.escape?
        return close_or_warn(confirming)
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

    private def handle_strip_key(key : Termisu::Input::Key, confirming : Bool) : Outcome
      case
      when key.escape?, key.up?  then return close_or_warn(confirming)
      when key.left?             then set_group(@group - 1)
      when key.right?            then set_group(@group + 1)
      when key.down?, key.enter? then @on_strip = false
      end
      NONE
    end

    # Closing throws away every unsaved section, and the modal stacks several of them while
    # ↵ saves only the focused one — so a first esc names what would be lost and a second
    # esc discards. Clean (or already-warned) → close straight away.
    private def close_or_warn(confirming : Bool) : Outcome
      dirty = dirty_titles
      return Outcome.new(:close) if confirming || dirty.empty?
      @confirm_discard = true
      @status = "unsaved: #{dirty.join(", ")} — ↵ saves the focused section, esc again discards"
      @status_warn = true
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
      # Click outside the card → close, through the same unsaved-edits guard as esc (a
      # stray click must not silently drop what was typed; the second click confirms).
      unless box.contains?(mx, my)
        confirming, @confirm_discard = @confirm_discard, false
        return close_or_warn(confirming)
      end
      @confirm_discard = false
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
      @status_warn = !form.saved?
      # `save` returns its error message and persists NOTHING when validation fails, so a
      # :saved outcome there would be a lie the host acts on — apply_settings_saved
      # rebinds the live proxy and re-pushes upstream/landing settings for input that was
      # just rejected. Report the failure in the footer only.
      return NONE unless form.saved?
      Outcome.new(:saved, sec.sym, msg)
    end

    # An opener is actionable only where its editor exists. Where it isn't allowed (the
    # picker has no tabs/hosts/env/hotkeys editors) it's a no-op with a hint instead.
    private def open_or_block(sym : Symbol) : Outcome
      return Outcome.new(:open, sym) if opener_allowed?(sym)
      @status = "open a project to edit this"
      @status_warn = true
      NONE
    end

    private def opener_allowed?(sym : Symbol) : Bool
      (ao = @allowed_openers).nil? || ao.includes?(sym)
    end

    private def reset_focused : Nil
      if f = focused_form
        f.reset_to_defaults # working copy only — still needs ↵ to persist, so no confirm
        # reset_to_defaults snaps the FORM's own cursor back to field 0, but the modal
        # tracks focus in its own flat index. Without this the highlighted row and the
        # row that actually receives edits drift apart until the next ↑/↓/click.
        sync_focus
        @status = "section reset to defaults — ↵ to save"
      end
    end

    # --- rendering ---
    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      # Too small for the grouped form. The modal still HOLDS input, so it must not render
      # nothing — that reads as a frozen app. Say why and how to get out instead.
      return render_too_small(screen, area) if box.w < 24 || box.h < 10
      Frame.card(screen, box, "PREFERENCES", border: Theme.border_focus)
      strip = Rect.new(box.x + 2, box.y + 2, box.w - 4, 1)
      @strip_start = Chrome.render_tab_strip(screen, strip, GROUP_LABELS, @group, @on_strip, @strip_start)
      screen.hline(box.x + 1, box.y + 3, box.w - 2, fg: @on_strip ? Theme.focus_gold : Theme.border, bg: Theme.panel)
      render_group(screen, content_rect(box), !@on_strip)
      render_footer(screen, box)
    end

    private def render_too_small(screen : Screen, area : Rect) : Nil
      return if area.w < 4 || area.h < 3
      w = {area.w - 2, 34}.min
      box = Rect.new(area.x + (area.w - w) // 2, area.y + area.h // 2 - 1, w, 3)
      Frame.card(screen, box, "PREFERENCES", border: Theme.border_focus)
      screen.text(box.x + 2, box.y + 1, "terminal too small · esc", Theme.muted, Theme.panel, width: {w - 4, 1}.max)
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
        draw_subheader(screen, content, sec.title, y, dirty: @forms[sec.sym]?.try(&.dirty?) || false)
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

    # `dirty` appends a ● so an edited-but-unsaved section is visible while you are still in
    # the modal, not only in the esc warning.
    private def draw_subheader(screen : Screen, content : Rect, title : String, y : Int32, dirty : Bool) : Nil
      return unless content.y <= y < content.bottom
      screen.fill(Rect.new(content.x, y, content.w, 1), Theme.panel)
      screen.text(content.x, y, title.upcase, Theme.focus_gold, Theme.panel, Attribute::Bold, width: content.w)
      screen.text(content.x + title.size + 1, y, "● unsaved", Theme.yellow, Theme.panel, width: {content.right - content.x - title.size - 1, 1}.max) if dirty
    end

    private def draw_opener(screen : Screen, content : Rect, sec : SettingsCatalog::Section, y : Int32, focused : Bool) : Nil
      return unless content.y <= y < content.bottom
      bg = focused ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(content.x, y, content.w, 1), bg)
      screen.cell(content.x, y, focused ? '▎' : ' ', Theme.accent, bg)
      lx = content.x + 2
      cue = "↵ open"
      cx = {content.right - cue.size, lx + sec.title.size + 1}.max
      screen.text(lx, y, sec.title, focused ? Theme.text_bright : Theme.text, bg)
      # Theme row: preview the CURRENT theme inline — its name + a swatch of its palette —
      # so you see what's selected without opening the card.
      if sec.sym == :theme
        name = Theme.canonical(Settings.theme)
        sx = {cx - 1 - SWATCH_W, lx + sec.title.size + 2}.max
        name_x = lx + sec.title.size + 2
        screen.text(name_x, y, name, focused ? Theme.text_bright : Theme.muted, bg, width: {sx - name_x - 1, 1}.max)
        draw_swatch(screen, sx, y, name)
      end
      screen.text(cx, y, cue, focused ? Theme.accent : Theme.muted, bg, width: {content.right - cx, 1}.max)
    end

    # A tiny preview strip in the theme's OWN palette (its canvas colour framing 5 accent
    # ticks) — the same swatch the theme card draws per row. Width == SWATCH_W.
    SWATCH_W = 7

    private def draw_swatch(screen : Screen, x : Int32, ry : Int32, name : String) : Nil
      pal = Theme.palette(name)
      return unless pal
      ticks = {pal.accent, pal.green, pal.yellow, pal.red, pal.syn_header}
      screen.cell(x, ry, ' ', pal.bg, pal.bg)
      ticks.each_with_index { |c, i| screen.cell(x + 1 + i, ry, '█', c, pal.bg) }
      screen.cell(x + 6, ry, ' ', pal.bg, pal.bg)
    end

    private def render_footer(screen : Screen, box : Rect) : Nil
      note_y = box.bottom - 3
      hint_y = box.bottom - 2
      iw = {box.w - 4, 0}.max
      note = @status || focused_hint
      # Same green/yellow split SettingsView uses — a rejected save must not read as a
      # successful one just because it came through the modal.
      note_fg = @status ? (@status_warn ? Theme.yellow : Theme.green) : Theme.muted
      screen.text(box.x + 2, note_y, note, note_fg, Theme.panel, width: iw)
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

    # The group's sections, honouring allowed_openers (the picker hides :opener rows it has
    # no editor for).
    private def sections_of(gsym : Symbol) : Array(SettingsCatalog::Section)
      SettingsCatalog.sections_in(gsym).select { |s| s.kind == :form || opener_allowed?(s.sym) }
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
