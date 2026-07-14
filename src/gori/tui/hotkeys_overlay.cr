require "./screen"
require "./theme"
require "./frame"
require "./keybind"
require "../verb"
require "../hotkeys"
require "../settings"

module Gori::Tui
  # The settings:hotkeys editor (settings:hotkeys). A scrollable, scope-grouped list of
  # rebindable verbs; press a key on a row to rebind it. Edits a WORKING COPY — committed
  # on ↵, discarded on esc — like the settings:* family. Two sub-modes: :browse (navigate
  # the list) and :capture (the next key becomes the new binding). Conflict + reserved-key
  # checks block a bad capture inline. An OS default profile (auto/macOS/Linux/Windows) is
  # cycled with ←/→. Reads every effective chord through Gori::Hotkeys so the view never
  # drifts from the live keymap.
  class HotkeysOverlay
    # A rendered line: a scope :header or a rebindable verb :binding.
    record Row, kind : Symbol, verb_id : String, scope : Verb::Scope, title : String

    SCOPE_LABEL = {
      Verb::Scope::Global         => "GLOBAL",
      Verb::Scope::Sidebar        => "TAB BAR",
      Verb::Scope::Body           => "HISTORY",
      Verb::Scope::HistoryDetail  => "FLOW DETAIL",
      Verb::Scope::Repeater         => "REPEATER",
      Verb::Scope::Fuzzer         => "FUZZER",
      Verb::Scope::Sitemap        => "SITEMAP",
      Verb::Scope::Findings       => "FINDINGS",
      Verb::Scope::FindingsDetail => "FINDING DETAIL",
      Verb::Scope::Intercept      => "INTERCEPT",
      Verb::Scope::Comparer       => "COMPARER",
      Verb::Scope::Project        => "PROJECT SCOPE",
      Verb::Scope::Env            => "PROJECT ENV",
      Verb::Scope::PaletteOpen    => "PALETTE",
    }

    def initialize(@registry : Verb::Registry)
      @rows = [] of Row
      @overrides = {} of String => Verb::Chord?
      @profile = "auto"
      @selected = 0
      @mode = :browse
      @feedback = nil.as(String?)
      @feedback_kind = :hint
      reset
    end

    # Rebuild the working copy from persisted Settings (called when the overlay opens), so
    # esc-discarded edits from a prior session don't linger.
    def reset : Nil
      @rows = build_rows
      @overrides = load_overrides
      @profile = Hotkeys.os_profile
      @selected = @rows.index { |r| r.kind == :binding } || 0
      @mode = :browse
      @feedback = nil
      @feedback_kind = :hint
    end

    private def build_rows : Array(Row)
      rows = [] of Row
      Verb::Scope.values.each do |scope|
        verbs = @registry.select { |v| v.scope == scope && Hotkeys.rebindable?(v) }
        next if verbs.empty?
        rows << Row.new(:header, "", scope, SCOPE_LABEL[scope]? || scope.to_s.upcase)
        verbs.each { |v| rows << Row.new(:binding, v.id, scope, v.title) }
      end
      rows
    end

    private def load_overrides : Hash(String, Verb::Chord?)
      out = {} of String => Verb::Chord?
      # rebindable_overrides (not raw chord_overrides): drop stale overrides for now-FIXED/hidden
      # verb ids that build_keymap ignores, so the editor's conflict check can't report a phantom
      # "already bound" for a chord live dispatch never actually claims.
      Hotkeys.rebindable_overrides(@registry).each { |id, chords| out[id] = chords.first? }
      out
    end

    # --- working-copy queries the Runner / render use ---
    def capturing? : Bool
      @mode == :capture
    end

    def to_working : {Hash(String, Verb::Chord?), String}
      {@overrides, @profile}
    end

    private def selected_id : String
      @rows[@selected]?.try(&.verb_id) || ""
    end

    # True when @selected points at a real binding row (the row-mutating verbs gate on this).
    private def selected_binding? : Bool
      (r = @rows[@selected]?) ? r.kind == :binding : false
    end

    private def effective_chord(id : String) : Verb::Chord?
      return @overrides[id] if @overrides.has_key?(id)
      Hotkeys.default_for(@registry, id, @profile)
    end

    private def overridden?(id : String) : Bool
      @overrides.has_key?(id)
    end

    # --- navigation ---
    def select_move(d : Int32) : Nil
      i = @selected
      loop do
        i += d
        return if i < 0 || i >= @rows.size
        if @rows[i].kind == :binding
          @selected = i
          @feedback = nil
          return
        end
      end
    end

    # Click target: snap to the row, or the nearest binding when a header is hit.
    def set_selected(idx : Int32) : Nil
      idx = idx.clamp(0, {@rows.size - 1, 0}.max)
      return if @rows.empty?
      if @rows[idx].kind == :binding
        @selected = idx
        return
      end
      down = (idx...@rows.size).find { |i| @rows[i].kind == :binding }
      up = (0..idx).reverse_each.find { |i| @rows[i].kind == :binding }
      @selected = down || up || @selected
    end

    # --- capture sub-mode ---
    def begin_capture : Nil
      return unless selected_binding?
      @mode = :capture
      @feedback_kind = :hint
      @feedback = "press a key to bind · esc cancel"
    end

    def cancel_capture : Nil
      @mode = :browse
      @feedback = nil
      @feedback_kind = :hint
    end

    # Validate + commit a captured chord; stays in capture (with an error) on a bad key.
    def apply_capture(chord : Verb::Chord) : Nil
      if reason = Hotkeys.reserved?(chord)
        @feedback_kind = :error
        @feedback = reason
        return
      end
      if msg = conflict_message(selected_id, chord)
        @feedback_kind = :error
        @feedback = msg
        return
      end
      @overrides[selected_id] = chord
      @feedback_kind = :ok
      @feedback = "bound to #{chord.label}"
      @mode = :browse
    end

    private def conflict_message(id : String, chord : Verb::Chord) : String?
      working = Hotkeys.as_chord_overrides(@overrides)
      return nil unless c = Hotkeys.conflict(@registry, id, chord, working, @profile)
      other = @registry[c.verb_id]?
      label = SCOPE_LABEL[c.scope]? || c.scope.to_s
      "#{chord.label} conflicts with #{other.try(&.title) || c.verb_id} (#{label})"
    end

    def unbind_selected : Nil
      return unless selected_binding?
      @overrides[selected_id] = nil
      @feedback_kind = :ok
      @feedback = "unbound"
    end

    def reset_selected : Nil
      return unless selected_binding?
      @overrides.delete(selected_id)
      @feedback_kind = :ok
      @feedback = "reset to default"
    end

    def reset_all : Nil
      @overrides.clear
      @feedback_kind = :ok
      @feedback = "all bindings reset to default"
    end

    def cycle_profile(d : Int32) : Nil
      i = Hotkeys::PROFILES.index(@profile) || 0
      @profile = Hotkeys::PROFILES[(i + d) % Hotkeys::PROFILES.size]
      @feedback_kind = :hint
      @feedback = "profile: #{Hotkeys.profile_label(@profile)}"
    end

    # --- geometry (mirrors TabsOverlay; reserves the last interior row for the footer) ---
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 56}.min
      h = {area.h - 2, @rows.size + 4}.min # top border + gap + list + footer + bottom border
      return nil if w < 32 || h < 7
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    private def list_capacity(box : Rect) : Int32
      {box.bottom - 2 - (box.y + 2), 0}.max # list ends at box.bottom-3; footer at box.bottom-2
    end

    private def list_window(cap : Int32) : Int32
      return 0 if cap <= 0 || @rows.size <= cap
      { {@selected - cap + 1, 0}.max, @rows.size - cap }.min
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "hotkeys editor needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "HOTKEYS", border: Theme.border_focus)
      prof = "profile: #{Hotkeys.profile_label(@profile)}"
      screen.text({box.right - prof.size - 2, box.x + 12}.max, box.y, prof, Theme.muted, Theme.panel)

      top = box.y + 2
      cap = list_capacity(box)
      start = list_window(cap)
      cap.times do |row|
        i = start + row
        break if i >= @rows.size
        r = @rows[i]
        up = row == 0 && start > 0
        down = row == cap - 1 && i < @rows.size - 1
        if r.kind == :header
          draw_header(screen, box, r, top + row)
          # The boundary viewport row can land on a header; still show the ▲/▼ affordance
          # (it was previously swallowed whenever the top/bottom row was a header).
          draw_scroll_marker(screen, box.right - 2, top + row, Theme.panel, up: up, down: down)
        else
          draw_binding(screen, box, i, top + row, up: up, down: down)
        end
      end
      render_footer(screen, box)
    end

    private def draw_header(screen : Screen, box : Rect, r : Row, ry : Int32) : Nil
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), Theme.panel)
      screen.text(box.x + 2, ry, r.title, Theme.accent, Theme.panel, attr: Attribute::Bold, width: {box.w - 4, 1}.max)
    end

    private def draw_binding(screen : Screen, box : Rect, i : Int32, ry : Int32, *, up : Bool, down : Bool) : Nil
      r = @rows[i]
      sel = i == @selected
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, sel ? '▎' : ' ', Theme.accent, bg)
      ov = overridden?(r.verb_id)
      screen.cell(box.x + 3, ry, ov ? '●' : '·', ov ? Theme.accent : Theme.muted, bg)

      mark_x = box.right - 2
      chord = effective_chord(r.verb_id) # resolve once (label + unbound flag derive from it)
      clabel = chord.try(&.label) || "(unbound)"
      unbound = chord.nil?
      cx = mark_x - 1 - clabel.size
      name_w = {cx - (box.x + 5) - 1, 1}.max
      screen.text(box.x + 5, ry, r.title, sel ? Theme.text_bright : Theme.text, bg, width: name_w)
      ccol = unbound ? Theme.yellow : (ov ? Theme.accent : (sel ? Theme.text_bright : Theme.muted))
      screen.text(cx, ry, clabel, ccol, bg) if cx > box.x + 5
      draw_scroll_marker(screen, mark_x, ry, bg, up: up, down: down)
    end

    private def draw_scroll_marker(screen : Screen, mark_x : Int32, ry : Int32, bg : Color, *, up : Bool, down : Bool) : Nil
      glyph = if up && down
                '↕'
              elsif up
                '▲'
              elsif down
                '▼'
              else
                return
              end
      screen.cell(mark_x, ry, glyph, Theme.muted, bg)
    end

    private def render_footer(screen : Screen, box : Rect) : Nil
      ry = box.bottom - 2
      if fb = @feedback
        color = case @feedback_kind
                when :error then Theme.yellow
                when :ok    then Theme.green
                else             Theme.muted
                end
        screen.text(box.x + 2, ry, "• #{fb}", color, Theme.panel, width: {box.w - 4, 1}.max)
      elsif (r = @rows[@selected]?) && r.kind == :binding && (v = @registry[r.verb_id]?)
        screen.text(box.x + 2, ry, v.description, Theme.muted, Theme.panel, width: {box.w - 4, 1}.max)
      end
    end

    # Flat row index under (mx,my) — nil for header rows / outside the list.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      cap = list_capacity(box)
      row = my - (box.y + 2)
      return nil if row < 0 || row >= cap
      i = list_window(cap) + row
      return nil unless i < @rows.size
      @rows[i].kind == :binding ? i : nil
    end
  end
end
