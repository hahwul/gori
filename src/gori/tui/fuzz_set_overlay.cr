require "./screen"
require "./theme"
require "./frame"
require "./text_area"
require "./text_field"
require "./path_complete"

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
  # Surfaces used by the Runner: handle_key returns :apply when the user commits
  # (esc, or ↵ on the last field) so the Runner writes build_spec back into @sets;
  # :stay otherwise. overlay_box centers the box; set_preedit routes composing text.
  class FuzzSetOverlay
    PTYPES = [:list, :numbers, :wordlist, :null, :brute]

    getter edit_index : Int32?

    def initialize(@edit_index : Int32? = nil)
      @ptype = :list
      @sel = 0 # row cursor: 0 = the Type selector, then the type's fields
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
      @path_complete = PathComplete.new
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

    # --- input ---------------------------------------------------------------
    # Returns :apply when the user commits (Runner writes build_spec back), else :stay.
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

      return :apply if key.escape?
      if key.tab?
        move_row(1); return :stay
      elsif key.back_tab?
        move_row(-1); return :stay
      end

      return handle_type_row(ev) if f == :type
      return handle_values(ev) if f == :values
      handle_field(ev, f)
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
      case
      when key.up?   then @values.at_top? ? move_row(-1) : @values.move(-1, 0)
      when key.down? then @values.move(1, 0) unless @values.at_bottom?
      else                edit_values(ev) # enter = new value line, else edit/caret
      end
      :stay
    end

    # ⏎ inserts a new value line; the rest are the usual TextArea editing/caret keys.
    private def edit_values(ev : Termisu::Event::Key) : Nil
      key = ev.key
      case
      when key.enter?     then @values.insert_newline
      when key.backspace? then @values.backspace
      when key.delete?    then @values.delete
      when key.left?      then @values.move(0, -1)
      when key.right?     then @values.move(0, 1)
      when key.home?      then @values.home
      when key.end?       then @values.end_of_line
      else
        ch = ev.char || key.to_char
        @values.insert(ch) if ch && !ev.ctrl? && !ev.alt?
      end
    end

    private def handle_field(ev : Termisu::Event::Key, f : Symbol) : Symbol
      key = ev.key
      tf = @fields[f]? || return :stay
      case
      when key.up?    then move_row(-1)
      when key.down?  then move_row(1)
      when key.enter? then return :apply if on_last_row?; move_row(1)
      else
        tf.handle_edit_key(ev)
        refresh_path(f) # keep the wordlist dropdown in lockstep with the field
      end
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
      when :numbers  then "Numbers"
      when :wordlist then "Wordlist"
      when :null     then "Null"
      when :brute    then "Brute"
      else                "List"
      end
    end

    private def field_label(f : Symbol) : String
      case f
      when :from    then "From"
      when :to      then "To"
      when :step    then "Step"
      when :count   then "Count"
      when :charset then "Charset"
      when :min     then "Min"
      when :max     then "Max"
      when :path    then "Path"
      else               ""
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
      title = @edit_index ? "PAYLOAD SET · edit" : "PAYLOAD SET · new"
      # bg: Theme.bg (not the card default panel) so the embedded List TextArea, which
      # always paints on Theme.bg, doesn't two-tone against the card interior.
      Frame.card(screen, box, title, bg: Theme.bg, border: Theme.border_focus)
      render_meta(screen, box)
      render_type_row(screen, box)
      Frame.tee_divider(screen, box, box.y + 2, Theme.bg)
      @ptype == :list ? render_values(screen, box) : render_fields(screen, box)
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
        @fields[f].render(screen, vx, y, vw, foc, foc ? Theme.text_bright : Theme.text, bg)
      end
    end

    private def render_values(screen : Screen, box : Rect) : Nil
      top = box.y + 3
      h = {(box.bottom - 2) - top, 1}.max
      editor = Rect.new(box.x + 2, top, box.w - 4, h)
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
        when :wordlist then "type to filter · ↹/↵ complete · ⇥ field · esc applies"
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
    # editor. Returns true when the click was inside the box (consumed).
    def handle_click(box : Rect, mx : Int32, my : Int32) : Bool
      return false unless box.contains?(mx, my)
      if my == box.y + 1
        @sel = 0
        sync_path_complete
      elsif @ptype == :list
        @sel = rows.index(:values) || @sel
        @values.click_to_cursor(Rect.new(box.x + 2, box.y + 3, box.w - 4, {(box.bottom - 2) - (box.y + 3), 1}.max), mx, my)
      else
        i = my - (box.y + 3)
        @sel = (i + 1).clamp(1, rows.size - 1) if 0 <= i < field_rows.size
        sync_path_complete
      end
      true
    end

    def move(d : Int32) : Nil
      move_row(d)
    end
  end
end
