require "../tab_controller"
require "../settings_catalog"
require "../settings_view"

module Gori::Tui
  # The Settings tab (:prefs, labelled "Settings") — a browsable, editable home for the
  # same config the Ctrl-P palette exposes. Hidden by default (Chrome::DEFAULT_HIDDEN);
  # reachable via the ⋯ dropdown, settings:tabs, or "Go to Settings".
  #
  # Its sub-tabs are the SettingsCatalog groups; each group stacks its sections vertically.
  # A :form section renders + edits INLINE via a per-section SettingsView instance (the
  # SAME field engine the palette overlay uses — render_fields_into, toggle_or_move,
  # insert, save), so the tab and the overlay can never draw or persist a field
  # differently. A :opener section (theme list, tabs/env/hotkeys editors) is a single row
  # whose ↵ opens that section's existing overlay via open_settings — one implementation,
  # reached identically from both surfaces. Saving routes through the shared
  # apply_settings_saved seam, so a save takes effect the same way as from the palette.
  class SettingsController < TabController
    GROUP_LABELS = SettingsCatalog::GROUPS.map { |g| g[1] }

    @group : Int32 = 0  # active sub-tab (index into GROUPS)
    @focus : Int32 = 0  # focused row (index into the active group's flat target list)
    @scroll : Int32 = 0 # first visible virtual row (derived — follows @focus)

    def initialize(host : Host)
      super(host)
      # One SettingsView per inline-editable section, reloaded from live Settings.
      @forms = {} of Symbol => SettingsView
      SettingsCatalog.all.each do |s|
        next unless s.in_tab && s.kind == :form
        v = SettingsView.new
        v.reload(s.sym)
        @forms[s.sym] = v
      end
    end

    # --- identity ---
    def tab : Symbol
      :prefs
    end

    def command_scope : Verb::Scope
      Verb::Scope::Body
    end

    # --- fixed sub-tab strip (the catalog groups; no ^N/^W) ---
    def subtab_labels : Array(String)
      GROUP_LABELS
    end

    def subtab_index : Int32
      @group
    end

    def subtab_strip_shown? : Bool
      true
    end

    def subtabs_fixed? : Bool
      true
    end

    # Entering the tab lands on the group strip first — pick a group, then ↓ into fields.
    def enter_on_subtabs? : Bool
      true
    end

    def move_subtab(dir : Int32) : Nil
      set_group(@group + dir)
    end

    def jump_subtab(idx : Int32) : Nil
      set_group(idx)
    end

    private def set_group(idx : Int32) : Nil
      idx = idx.clamp(0, GROUP_LABELS.size - 1)
      return if idx == @group
      @group = idx
      @focus = 0
      @scroll = 0
      sync_focus
    end

    # --- lifecycle ---
    def on_enter : Nil
      @forms.each { |sym, v| v.reload(sym) } # pick up edits made elsewhere (palette overlay, etc.)
      @focus = @focus.clamp(0, {targets.size - 1, 0}.max)
      sync_focus
    end

    def focus_first : Nil
      @focus = 0
      sync_focus
    end

    def focus_last : Nil
      @focus = {targets.size - 1, 0}.max
      sync_focus
    end

    def body_badge : Symbol
      :editor # the form rows capture typed text
    end

    def body_hint(focus : Symbol) : String
      "↑/↓ field · ←/→ edit · ↵ save/open · ^R reset · ↹/esc tabs · ^P cmds"
    end

    # --- input ---
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.escape?
        @host.request_focus(:menu)
      when key.up?
        if @focus <= 0
          @host.request_focus(:subtabs) # step up to the group strip
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
        activate_focus
      when key.backspace?
        focused_form.try(&.backspace)
      when key.delete?
        focused_form.try(&.delete)
      when ev.ctrl? && key.lower_r?
        reset_focused_section
      when c && !ev.ctrl? && !ev.alt?
        # Printable (incl. space) → into the focused field, exactly like the overlay:
        # space toggles a bool / cycles a choice / types into text. Consumed so it never
        # falls through to the space menu — the field owns it while the body has focus.
        if f = focused_form
          f.insert(c)
          f.set_preedit("")
        end
      else
        return false # ^P, ↹, ^D, … fall through to the focus ring / keymap
      end
      true
    end

    def set_preedit(text : String) : Bool
      if f = focused_form
        f.set_preedit(text)
        return true
      end
      false
    end

    # Page/Home/End move the focused row (scroll follows focus in render).
    def body_scroll(delta : Int32) : Bool
      @focus = (@focus + delta).clamp(0, {targets.size - 1, 0}.max)
      sync_focus
      true
    end

    def handle_wheel(step : Int32) : Bool
      @focus = (@focus + step).clamp(0, {targets.size - 1, 0}.max)
      sync_focus
      true
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      content = BodyChrome.content_rect(rect, strip: true)
      return false unless content.contains?(mx, my)
      if idx = target_at_row((my - content.y) + @scroll)
        @focus = idx
        sync_focus
        @host.focus_body
      end
      true # consume any click inside the pane (header/spacer rows just re-focus body)
    end

    # --- rendering ---
    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      shell = BodyChrome.shell_focused(focus, multi_pane: false)
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, focus == :subtabs,
        GROUP_LABELS, @group, @subtab_start) do |content|
        render_group(screen, content, focus == :body)
      end
    end

    private def render_group(screen : Screen, content : Rect, body_focused : Bool) : Nil
      ensure_scroll(content)
      # Resolve the focused section/field once (only when the body holds focus) so the
      # per-section loop stays free of nil-narrowing.
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
      screen.fill(Rect.new(content.x, y, content.w, 1), Theme.bg)
      screen.text(content.x, y, title.upcase, Theme.focus_gold, Theme.bg, Attribute::Bold, width: content.w)
    end

    private def draw_opener(screen : Screen, content : Rect, sec : SettingsCatalog::Section, y : Int32, focused : Bool) : Nil
      return unless content.y <= y < content.bottom
      bg = focused ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(content.x, y, content.w, 1), bg)
      screen.cell(content.x, y, focused ? '▎' : ' ', Theme.accent, bg)
      cue = "↵ open"
      lx = content.x + 2
      cx = {content.right - cue.size, lx + sec.title.size + 1}.max
      # width-bound both so a narrow pane can't bleed the title/cue past the frame edge.
      screen.text(lx, y, sec.title, focused ? Theme.text_bright : Theme.text, bg, width: {cx - lx, 1}.max)
      screen.text(cx, y, cue, focused ? Theme.accent : Theme.muted, bg, width: {content.right - cx, 1}.max)
    end

    # Keep the focused row inside the content viewport (scroll follows focus, like the
    # theme list). @scroll is derived here every frame, never set by the user directly.
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

    private def group_sections : Array(SettingsCatalog::Section)
      SettingsCatalog.sections_in(group_sym)
    end

    private def field_count(sym : Symbol) : Int32
      SettingsView::SECTIONS[sym]?.try(&.size) || 0
    end

    # The active group's focusable rows, in display order: one per form field, one per
    # opener section. A tuple {section, field_idx} (field_idx == -1 for an opener row).
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

    # The SettingsView backing the focused row, or nil when the focus is on an opener row
    # (a catalog :opener section — not a form field, so nothing to edit inline).
    private def focused_form : SettingsView?
      return nil unless ft = focused_target
      sec, field = ft
      return nil unless sec.kind == :form && field >= 0
      @forms[sec.sym]
    end

    # Sync the focused form's internal caret to the focused field so its input line renders
    # with the caret in the right place (the overlay does this on every move_field).
    private def sync_focus : Nil
      return unless ft = focused_target
      sec, field = ft
      @forms[sec.sym].set_field(field) if sec.kind == :form && field >= 0
    end

    private def activate_focus : Nil
      return unless ft = focused_target
      sec = ft[0]
      if sec.kind == :opener
        @host.open_settings(sec.sym) # theme / tabs / env / hotkeys editor
        return
      end
      form = @forms[sec.sym]
      if opener = form.focused_opener
        @host.open_settings(opener) # e.g. Network's "Hostname overrides" action row
        return
      end
      @host.status(@host.apply_settings_saved(sec.sym, form.save))
    end

    private def reset_focused_section : Nil
      return unless ft = focused_target
      sec = ft[0]
      return unless sec.kind == :form
      form = @forms[sec.sym]
      @host.confirm("RESET SETTINGS",
        "Reset the #{sec.title.upcase} settings to their\n" \
        "default values? Unsaved edits here are replaced.",
        confirm_label: "reset", danger: true) do
        form.reset_to_defaults
        @host.status("#{sec.title} settings reset to defaults — ↵ to save")
      end
    end

    # Total virtual height of the active group: per section a header + its rows + a spacer.
    private def group_height : Int32
      group_sections.sum { |sec| 1 + (sec.kind == :form ? field_count(sec.sym) : 1) + 1 }
    end

    # Virtual row (0-based from the group top) that scroll-follow keeps visible for the
    # focused row. For a section's FIRST field (or an opener row) we target the header one
    # line above, so entering a section keeps its label on screen; deeper fields target
    # themselves (the header may then scroll off, which is fine — you've paged past it).
    private def focus_row_offset : Int32
      return 0 unless ft = focused_target
      fsec, ffield = ft
      row = 0
      group_sections.each do |sec|
        header = row
        row += 1 # header → row now points at this section's first content line
        if sec.kind == :form
          return ffield == 0 ? header : row + ffield if sec.sym == fsec.sym
          row += field_count(sec.sym)
        else
          return header if sec.sym == fsec.sym
          row += 1
        end
        row += 1 # spacer
      end
      row
    end

    # Inverse of the render layout: the flat target index drawn at virtual `vrow`, or nil
    # for a header/spacer row (a click there just re-focuses the body without moving @focus).
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
