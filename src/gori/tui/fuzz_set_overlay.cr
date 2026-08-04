require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./text_area"
require "./text_field"
require "./path_complete"
require "../settings"
require "../fuzz/presets"

module Gori::Tui
  # One payload set: a source kind + a value string in the compact grammar the Fuzz
  # engine consumes (list="a,b,c", numbers="from-to:step", file="path", null="N",
  # brute="charset:min-max"). Shared by FuzzerView (@sets, persistence, engine
  # assembly) and FuzzSetOverlay (the editor that produces one). Hoisted to module
  # scope so the overlay can build one without depending on FuzzerView.
  record SetSpec, kind : Symbol, value : String

  # The full-area popup for adding or editing ONE payload set. Replaces the cramped
  # in-pane draft fields: every payload type gets its own vertically-stacked, labeled
  # form, and List is a newline-native multi-line editor by DEFAULT (one value per
  # line, paste splits automatically). Modeled on MineConfigOverlay's row model but
  # with text fields, so it also carries IME (set_preedit) plumbing and, for the
  # wordlist Path field, an inline PathComplete dropdown.
  #
  # Rides the polymorphic Overlay seam (see overlay.cr). handle_key returns :commit when
  # the user applies (esc, ↵ on the last field, or a click-away) and the injected closure
  # writes build_spec back into @sets; :stay otherwise. There is no cancel: every exit
  # applies, which is what the shell's apply_close_fuzz_set did on all three paths.
  class FuzzSetOverlay < Overlay
    PTYPES = [:list, :numbers, :wordlist, :null, :brute, :preset]

    getter edit_index : Int32?

    def initialize(@edit_index : Int32? = nil)
      @ptype = :list
      @preset_name = Gori::Fuzz::Presets.names.first? || "sqli" # the built-in preset selector's value
      @sel = 0                                                  # row cursor: 0 = the Type selector, then the type's fields
      @fields = {
        :from    => TextField.new("1"),
        :to      => TextField.new("100"),
        :step    => TextField.new("1"),
        :count   => TextField.new("10"),
        :charset => TextField.new("abc"),
        :min     => TextField.new("1"),
        :max     => TextField.new("3"),
        :path    => TextField.new(""),
      }
      @values = TextArea.new
      @values.follow_x = true # long list values scroll horizontally to keep the caret visible
      @path_complete = PathComplete.new(wordlist_history: true)
    end

    # Open pre-seeded to List (the ^L / "Add a List payload set" verb).
    def self.for_list : FuzzSetOverlay
      new
    end

    # Open seeded from an existing set for in-place editing.
    def self.editing(spec : SetSpec, index : Int32) : FuzzSetOverlay
      ov = new(index)
      ov.seed(spec)
      ov
    end

    def seed(spec : SetSpec) : Nil
      case spec.kind
      when :list
        @ptype = :list
        @values.set_text(spec.value.split(',').map(&.strip).reject(&.empty?).join('\n'))
      when :numbers
        @ptype = :numbers
        range, _, step = spec.value.partition(':')
        # Parse two (possibly negative) integers so reopening a set with a negative From
        # shows the real values, not a corrupted split on the leading '-'.
        if m = range.match(/\A(-?\d+)-(-?\d+)\z/)
          @fields[:from].set(m[1])
          @fields[:to].set(m[2])
        else
          from, _, to = range.partition('-')
          @fields[:from].set(from)
          @fields[:to].set(to)
        end
        @fields[:step].set(step.empty? ? "1" : step)
      when :file
        @ptype = :wordlist
        @fields[:path].set(spec.value)
      when :null
        @ptype = :null
        @fields[:count].set(spec.value)
      when :brute
        @ptype = :brute
        charset, _, lens = spec.value.rpartition(':')
        lo, _, hi = lens.partition('-')
        @fields[:charset].set(charset)
        @fields[:min].set(lo)
        @fields[:max].set(hi)
      when :preset
        @ptype = :preset
        @preset_name = spec.value if Gori::Fuzz::Presets.exists?(spec.value)
      end
    end

    # --- layout model --------------------------------------------------------
    # Row 0 is always the Type selector; the rest are the selected type's fields.
    private def field_rows : Array(Symbol)
      case @ptype
      when :numbers  then [:from, :to, :step]
      when :wordlist then [:path]
      when :null     then [:count]
      when :brute    then [:charset, :min, :max]
      when :preset   then [:preset_name]
      else                [:values]
      end
    end

    private def rows : Array(Symbol)
      [:type] + field_rows
    end

    private def focused : Symbol
      rows[@sel]? || :type
    end

    private def on_last_row? : Bool
      @sel == rows.size - 1
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::FuzzSet
    end

    def title : String
      "PAYLOAD SET"
    end

    # The single-line fields the pointer can reach — see `Overlay#text_fields`. Listing them
    # is the whole opt-in: caret placement on a press, drag to extend, double-click for a
    # word, all inverted by the field against the geometry `render` last drew it at.
    def text_fields : Array(TextField)
      @fields.values.to_a # NamedTuple on some cards, Hash on others — one shape out
    end

    def hint : String
      "↑/↓/⇥ field · ←/→ type/caret · ↵ new value/next · esc applies & closes"
    end

    # --- input ---------------------------------------------------------------
    # Returns :commit when the user applies (the injected closure writes build_spec
    # back), else :stay.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      f = focused

      # The wordlist Path dropdown owns navigation keys while it's open.
      if f == :path && @path_complete.open?
        case
        when key.tab?, key.enter?   then return accept_path
        when key.back_tab?, key.up? then @path_complete.move(-1); return :stay
        when key.down?              then @path_complete.move(1); return :stay
        when key.escape?            then @path_complete.close; return :stay
        else # printables fall through → edit + refilter
        end
      end

      return :commit if key.escape?
      if key.tab?
        move_row(1); return :stay
      elsif key.back_tab?
        move_row(-1); return :stay
      end

      return handle_type_row(ev) if f == :type
      return handle_values(ev) if f == :values
      handle_field(ev, f)
    end

    # The built-in-preset selector row: ←/→ cycle the preset name, ↑/↓ move rows, ↵ applies
    # (it is the only field, so it is always the last row).
    private def handle_preset_name(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      case
      when key.left?  then cycle_preset(-1)
      when key.right? then cycle_preset(1)
      when key.up?    then move_row(-1)
      when key.down?  then move_row(1)
      when key.enter? then return :commit
      end
      :stay
    end

    private def cycle_preset(d : Int32) : Nil
      names = Gori::Fuzz::Presets.names
      return if names.empty?
      i = names.index(@preset_name) || 0
      @preset_name = names[(i + d) % names.size]
    end

    private def handle_type_row(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      case
      when key.left?             then cycle_ptype(-1)
      when key.right?            then cycle_ptype(1)
      when key.up?               then move_row(-1)
      when key.down?, key.enter? then move_row(1)
      else
        # A printable typed (or pasted) on the Type row while it's a List drops straight
        # into the values editor and is captured there. Without this the Type selector
        # silently swallowed it — losing the whole first line of a pasted wordlist (the
        # ^L quick-List path opens focused on this row). →/← still cycle the type.
        if @ptype == :list && (ch = ev.char) && !ev.ctrl? && !ev.alt?
          @sel = rows.index(:values) || @sel
          @values.insert(ch)
        end
      end
      :stay
    end

    private def handle_values(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      # A ROW-crossing ↑ claims only a BARE press: ⇧ means a selection is mid-build and
      # leaving the buffer would abandon it, and ⌥↑ is a motion this editor owns. The same
      # line the Notes and Project-description editors draw.
      crossing = !ev.shift? && !ev.ctrl? && !ev.alt?
      case
      when key.up? && crossing && @values.at_top?      then move_row(-1)
      when key.down? && crossing && @values.at_bottom? then nil             # the last value is the floor
      else                                                  edit_values(ev) # enter = new value line, else edit/caret
      end
      :stay
    end

    # ⏎ inserts a new value line; everything below ⌫/Del is `TextArea#handle_motion_key` —
    # the ONE editor keymap (⇧arrows select, PageUp/PageDown, ⇧Home/⇧End, ⌥/⌃←→ by word,
    # ⌥⌫). This buffer hand-rolled bare ←→ and Home/End and passed no `selecting:` anywhere,
    # so the pane an operator PASTES A WORDLIST INTO had no way to select a run of it back out.
    private def edit_values(ev : Termisu::Event::Key) : Nil
      key = ev.key
      case
      when key.enter? then @values.insert_newline
        # Before plain ⌫, which would swallow the modified form as a one-character delete.
      when @values.word_delete_key?(ev)  then @values.handle_motion_key(ev)
      when key.backspace?                then @values.backspace
      when key.delete?                   then @values.delete
      when @values.handle_motion_key(ev) then nil
      else
        ch = ev.char || key.to_char
        @values.insert(ch) if ch && !ev.ctrl? && !ev.alt?
      end
    end

    private def handle_field(ev : Termisu::Event::Key, f : Symbol) : Symbol
      return handle_preset_name(ev) if f == :preset_name # a selector row, not a TextField
      key = ev.key
      tf = @fields[f]? || return :stay
      # ^D (browser-bookmark convention): toggle the CURRENTLY TYPED path in/out of
      # favorites — checked before the TextField sees the keystroke so it never
      # inserts a literal "d".
      return toggle_favorite_path if f == :path && ev.ctrl_d?
      case
      when key.up?    then move_row(-1)
      when key.down?  then move_row(1)
      when key.enter? then return :commit if on_last_row?; move_row(1)
      else
        tf.handle_edit_key(ev)
        refresh_path(f) # keep the wordlist dropdown in lockstep with the field
      end
      :stay
    end

    private def toggle_favorite_path : Symbol
      Gori::Settings.toggle_favorite_wordlist(@fields[:path].value)
      :stay
    end

    private def move_row(d : Int32) : Nil
      @sel = (@sel + d).clamp(0, rows.size - 1)
      sync_path_complete
    end

    private def cycle_ptype(d : Int32) : Nil
      i = PTYPES.index(@ptype) || 0
      @ptype = PTYPES[(i + d) % PTYPES.size]
      @sel = 0 # rows just changed shape — land back on the Type selector
      @path_complete.close
    end

    private def sync_path_complete : Nil
      focused == :path ? @path_complete.refresh(@fields[:path].value) : @path_complete.close
    end

    private def refresh_path(f : Symbol) : Nil
      @path_complete.refresh(@fields[:path].value) if f == :path
    end

    private def accept_path : Symbol
      res = @path_complete.accept
      return :stay unless res
      path, is_dir = res
      @fields[:path].set(path)
      is_dir ? @path_complete.refresh(path) : @path_complete.close
      :stay
    end

    def set_preedit(text : String) : Nil
      case focused
      when :values then @values.set_preedit(text)
      else              @fields[focused]?.try(&.set_preedit(text))
      end
    end

    # --- result --------------------------------------------------------------
    # The edited set, or nil when its required input is blank (empty List / Path /
    # Charset) — the Runner then leaves @sets unchanged.
    def build_spec : SetSpec?
      case @ptype
      when :list
        vals = list_values
        vals.empty? ? nil : SetSpec.new(:list, vals.join(","))
      when :numbers
        SetSpec.new(:numbers, "#{num64(:from)}-#{num64(:to)}:#{num64(:step, 1_i64)}")
      when :wordlist
        p = @fields[:path].value.strip
        p.empty? ? nil : SetSpec.new(:file, p)
      when :null
        SetSpec.new(:null, num(:count, 1).to_s)
      when :brute
        cs = @fields[:charset].value.strip
        cs.empty? ? nil : SetSpec.new(:brute, "#{cs}:#{num(:min, 1)}-#{num(:max, 1)}")
      when :preset
        SetSpec.new(:preset, @preset_name)
      end
    end

    private def list_values : Array(String)
      @values.text.split('\n').map(&.strip).reject(&.empty?)
    end

    private def num(f : Symbol, default : Int32 = 0) : Int32
      @fields[f].value.to_i? || default
    end

    # From/To/Step round-trip through the Int64 engine (Fuzz::NumberRange), so parse
    # them wide: `num` (Int32) truncated any bound above 2³¹−1 to the default, silently
    # collapsing e.g. a post-2038 timestamp or large-ID range to `0` on the first apply.
    private def num64(f : Symbol, default : Int64 = 0_i64) : Int64
      @fields[f].value.to_i64? || default
    end

    private def ptype_label(t : Symbol) : String
      case t
      when :preset   then "Preset"
      when :numbers  then "Numbers"
      when :wordlist then "Wordlist"
      when :null     then "Null"
      when :brute    then "Brute"
      else                "List"
      end
    end

    private def field_label(f : Symbol) : String
      case f
      when :from        then "From"
      when :to          then "To"
      when :step        then "Step"
      when :count       then "Count"
      when :charset     then "Charset"
      when :min         then "Min"
      when :max         then "Max"
      when :path        then "Path"
      when :preset_name then "Preset"
      else                   ""
      end
    end

    # --- rendering -----------------------------------------------------------
    LABEL_W = 9 # value column offset (widest field label "Charset" + padding)

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 6, 66}.min
      h = {area.h - 4, 20}.min
      return nil if w < 34 || h < 8
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "payload set editor needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      # Not `title` — that is now the Overlay chrome method, and a local of the same name
      # shadowing it inside render is the collision C2 hit (Crystal has no `override`).
      card_title = @edit_index ? "PAYLOAD SET · edit" : "PAYLOAD SET · new"
      # bg: Theme.bg (not the card default panel) so the embedded List TextArea, which
      # always paints on Theme.bg, doesn't two-tone against the card interior.
      Frame.card(screen, box, card_title, bg: Theme.bg, border: Theme.border_focus)
      render_meta(screen, box)
      render_type_row(screen, box)
      Frame.tee_divider(screen, box, box.y + 2, Theme.bg)
      case @ptype
      when :list   then render_values(screen, box)
      when :preset then render_preset(screen, box)
      else              render_fields(screen, box)
      end
      render_hint(screen, box)
      render_path_dropdown(screen, box) if @ptype == :wordlist
    end

    private def render_meta(screen : Screen, box : Rect) : Nil
      return unless @ptype == :list
      n = list_values.size
      meta = "#{n} value#{n == 1 ? "" : "s"}"
      screen.text({box.right - meta.size - 2, box.x + 22}.max, box.y, meta, Theme.muted, Theme.bg)
    end

    private def render_type_row(screen : Screen, box : Rect) : Nil
      foc = @sel == 0
      x = box.x + 2
      screen.text(x, box.y + 1, "Type", Theme.muted, Theme.bg)
      x += LABEL_W
      PTYPES.each do |t|
        sel = t == @ptype
        seg = " #{ptype_label(t)} "
        break if x + seg.size > box.right - 2
        bg = sel ? (foc ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
        fg = sel ? Theme.text_bright : Theme.muted
        screen.text(x, box.y + 1, seg, fg, bg)
        x += seg.size + 1
      end
    end

    private def render_fields(screen : Screen, box : Rect) : Nil
      vx = box.x + 2 + LABEL_W
      vw = {box.right - 2 - vx, 1}.max
      field_rows.each_with_index do |f, i|
        y = box.y + 3 + i
        break if y >= box.bottom - 2
        foc = @sel == i + 1
        bg = foc ? Theme.accent_bg : Theme.bg
        screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), bg) if foc
        screen.text(box.x + 2, y, field_label(f), foc ? Theme.text_bright : Theme.muted, bg)
        # overlay_box already refused to render below w=34 (see `render`), so vw - 2
        # never underflows here.
        favorited = f == :path && Gori::Settings.favorite_wordlist?(@fields[f].value)
        screen.text(box.right - 3, y, "★", Theme.accent, bg) if favorited
        @fields[f].render(screen, vx, y, favorited ? vw - 2 : vw, foc, foc ? Theme.text_bright : Theme.text, bg)
      end
    end

    # The built-in-preset selector: a "Preset" row of the available names (the enumeration
    # requirement), the current one highlighted, followed by its payload count. ←/→ cycle.
    private def render_preset(screen : Screen, box : Rect) : Nil
      foc = focused == :preset_name
      y = box.y + 3
      screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), Theme.accent_bg) if foc
      screen.text(box.x + 2, y, "Preset", foc ? Theme.text_bright : Theme.muted, foc ? Theme.accent_bg : Theme.bg)
      # Wrap the name segments across the field area so all six stay discoverable even at
      # the overlay's minimum width.
      x = box.x + 2 + LABEL_W
      row = y
      left = box.x + 2 + LABEL_W
      Gori::Fuzz::Presets.names.each do |name|
        sel = name == @preset_name
        seg = " #{name} "
        if x + seg.size > box.right - 2
          row += 1
          x = left
          break if row >= box.bottom - 3
        end
        bg = sel ? (foc ? Theme.accent : Theme.selection_dim) : Theme.bg
        fg = sel ? Theme.text_bright : Theme.muted
        screen.text(x, row, seg, fg, bg)
        x += seg.size + 1
      end
      n = preset_count(@preset_name)
      meta = n ? "#{n} payloads" : ""
      screen.text(box.x + 2, box.bottom - 3, meta, Theme.muted, Theme.bg, width: box.w - 4) unless meta.empty?
    end

    # The selected preset's payload count for the meta line — nil (count hidden) if the
    # embedded set somehow fails to load, so a render never raises.
    private def preset_count(name : String) : Int32?
      Gori::Fuzz::Presets.load(name).size
    rescue
      nil
    end

    # The value list's rect inside a drawn card. Shared by `render_values` and the three
    # pointer entries so the caret cannot land on a row it wasn't drawn on — the click arm
    # used to re-derive this expression by hand, one copy away from drifting.
    private def values_rect(box : Rect) : Rect
      top = box.y + 3
      Rect.new(box.x + 2, top, box.w - 4, {(box.bottom - 2) - top, 1}.max)
    end

    private def render_values(screen : Screen, box : Rect) : Nil
      editor = values_rect(box)
      foc = focused == :values
      if @values.line_count == 1 && @values.text.empty?
        screen.text(editor.x, editor.y, "one value per line — paste a wordlist, it splits automatically", Theme.muted, Theme.bg, width: editor.w)
        screen.cursor(editor.x, editor.y) if foc
      else
        @values.render(screen, editor, cursor: foc)
      end
    end

    private def render_hint(screen : Screen, box : Rect) : Nil
      hint =
        case @ptype
        when :list     then "one value per line · ↵ new value · ⇥ field · esc applies"
        when :wordlist then "filter · ↹/↵ complete · ^D favorite · ⇥ field · esc applies"
        when :preset   then "←/→ choose preset · ⇥ type · esc applies & closes"
        else                "⇥/↑↓ field · ↵ next · esc applies & closes"
        end
      screen.text(box.x + 2, box.bottom - 2, hint, Theme.muted, Theme.bg, width: box.w - 4)
    end

    private def render_path_dropdown(screen : Screen, box : Rect) : Nil
      return unless focused == :path && @path_complete.open?
      vx = box.x + 2 + LABEL_W
      @path_complete.render(screen, vx, box.y + 4, box.inset(1, 1))
    end

    # --- mouse ---------------------------------------------------------------
    # Focus the row under a click; place the List caret when the click lands in the
    # editor. A click outside the card APPLIES (esc semantics) — the same dismissal the
    # shell used to run through apply_close_fuzz_set.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :commit if box.nil? || !box.contains?(mx, my)
      if my == box.y + 1
        @sel = 0
        sync_path_complete
      elsif @ptype == :list
        @sel = rows.index(:values) || @sel
        @values.click_to_cursor(values_rect(box), mx, my)
      else
        i = my - (box.y + 3)
        @sel = (i + 1).clamp(1, rows.size - 1) if 0 <= i < field_rows.size
        sync_path_complete
      end
      :stay
    end

    # --- pointer selection (see Overlay#supports_drag?) ---
    # This card has BOTH kinds of text: the LIST payload type is a real multi-line `TextArea`
    # (`@values`), every other type is single-line `TextField` rows. So each entry handles the
    # buffer when it is showing and otherwise falls through to the base, which routes to
    # whichever listed field was drawn under the pointer.
    def supports_drag? : Bool
      @ptype == :list || super
    end

    def handle_drag(area : Rect, mx : Int32, my : Int32) : Nil
      return super unless @ptype == :list
      return unless box = overlay_box(area)
      @values.click_to_cursor(values_rect(box), mx, my, selecting: true)
    end

    def handle_double_click(area : Rect, mx : Int32, my : Int32) : Bool
      return super unless @ptype == :list
      return false unless box = overlay_box(area)
      @values.select_word_at(values_rect(box), mx, my)
    end

    def move(d : Int32) : Nil
      move_row(d)
    end
  end
end
