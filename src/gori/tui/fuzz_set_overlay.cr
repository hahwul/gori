require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./text_area"
require "./text_field"
require "./path_complete"
require "../settings"
require "../fuzz/presets"
require "../wordlist_catalog"
require "../payload_from"
require "../plural"

module Gori::Tui
  # One payload set: a source kind + a value string in the compact grammar the Fuzz
  # engine consumes (list="a,b,c", numbers="from-to:step", file="path", null="N",
  # brute="charset:min-max"). Shared by FuzzerView (@sets, persistence, engine
  # assembly) and FuzzSetOverlay (the editor that produces one). Hoisted to module
  # scope so the overlay can build one without depending on FuzzerView.
  record SetSpec, kind : Symbol, value : String do
    # A `:list` value is NEWLINE-separated with a trailing newline — the overlay's own grammar
    # ("one value per line") — because a comma is ordinary payload text: `{"id":1,"role":"x"}`
    # or `' OR 1=1,--` stored comma-joined came back as two payloads, and the run count said
    # so while the operator read it as one. The trailing newline is the format marker: a value
    # with no newline at all is a session saved under the old comma grammar and is still
    # split on `,`, so nothing already on disk changes meaning.
    LIST_SEP = '\n'

    def self.list(values : Array(String)) : SetSpec
      new(:list, values.join(LIST_SEP) + LIST_SEP)
    end

    def self.list_values(value : String) : Array(String)
      return value.split(',') unless value.includes?(LIST_SEP)
      value.chomp(LIST_SEP).split(LIST_SEP)
    end

    # A `:project` set (#1352) keeps its source as JSON in `value` — a query, a projection, the
    # sensitive opt-in — because it is a structured thing and a session persists `kind` and `value`
    # as two strings. Read back through `project_spec`, which is nil for a value that no longer
    # parses (a session written by a later gori), so a set row never raises.
    def self.project(query : String, projection : PayloadFrom::Projection, sensitive : Bool,
                     rule : String? = nil) : SetSpec
      new(:project, JSON.build do |j|
        j.object do
          j.field "query", query
          j.field "projection", projection.label
          j.field "rule", rule if rule
          j.field "sensitive", sensitive
        end
      end)
    end

    def project_spec : PayloadFrom::Spec?
      return nil unless kind == :project
      obj = JSON.parse(value).as_h? || return nil
      projection = PayloadFrom::Projection.parse?(obj["projection"]?.try(&.as_s?) || "") || return nil
      PayloadFrom::Spec.new((obj["query"]?.try(&.as_s?) || "").strip, projection,
        obj["rule"]?.try(&.as_s?), include_sensitive: obj["sensitive"]?.try(&.as_bool?) || false)
    rescue JSON::ParseException
      nil
    end

    # ONE line, for a set row and a signature. The stored form of a list carries newlines.
    def display : String
      case kind
      when :list    then SetSpec.list_values(value).join(',')
      when :project then project_display
      else               value
      end
    end

    private def project_display : String
      spec = project_spec || return "(unreadable project source)"
      "#{spec.label}#{spec.include_sensitive ? " · SENSITIVE" : ""}"
    end
  end

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
    PTYPES = [:list, :numbers, :wordlist, :null, :brute, :preset, :project]

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
        # The Project type's QL (#1352); its projection and opt-in are selectors below.
        :project_query => TextField.new(""),
      }
      @values = TextArea.new
      # Soft wrap, like the template this list feeds. One line is one payload, and a payload
      # long enough to matter (a SQLi chain, a serialized blob) was exactly the one the
      # `follow_x` sideways pan made unreadable — you could not see its head and its tail at
      # the same time, in the pane whose whole job is checking what you are about to send.
      @values.wrap = true
      @path_complete = PathComplete.new(wordlist_history: true)
      # The Project type (#1352): the QL that picks flows is a field like the others; the
      # projection and the sensitive opt-in are selectors, `←/→` and `␣`, and start at the
      # safe answer.
      @project_projection = PayloadFrom::Projection::ParamNames
      @project_sensitive = false
      # The "Save as" name prompt (`^S` in the List editor), nil while it is closed; the last
      # save's outcome, shown on the hint row until the next key; and the name whose "already
      # exists" refusal a second ↵ has been told to override.
      @saving = nil.as(TextField?)
      @notice = nil.as(String?)
      @replace_name = nil.as(String?)
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
        @values.set_text(SetSpec.list_values(spec.value).map(&.strip).reject(&.empty?).join('\n'))
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
      when :project
        @ptype = :project
        if ps = spec.project_spec
          @fields[:project_query].set(ps.query)
          @project_projection = ps.projection
          @project_sensitive = ps.include_sensitive
        end
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
      when :project  then [:project_query, :project_projection, :project_sensitive]
      else                [:values]
      end
    end

    private def rows : Array(Symbol)
      [:type] + field_rows
    end

    # Which pasted keystrokes reach this card (see `Overlay#takes_pasted?`): the VALUES editor takes a line break as a newline; the other rows keep the default.
    def takes_pasted?(ev : Termisu::Event::Key) : Bool
      return !ev.key.enter? if @saving # a pasted line break must not answer the name prompt
      focused == :values || !ev.key.enter?
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
    #
    # Only the CURRENT payload type's rows, because that is exactly what `render_fields`
    # draws. `@fields` holds all eight for every type, and a field the current type does not
    # show still carries the `@last_x/@last_y` it was drawn at under a PREVIOUS type — so
    # returning all of them let an off-screen field win a hit-test on stale geometry.
    # `field_rows` also names rows that are not `TextField`s at all (`:values` is the list
    # TextArea, `:preset_name` has no field), which `[]?` drops.
    def text_fields : Array(TextField)
      field_rows.compact_map { |f| @fields[f]? }
    end

    def hint : String
      return "↵ save the list · esc cancel" if @saving
      "↑/↓/⇥ field · ←/→ type/caret · ↵ new value/next · esc applies & closes"
    end

    # --- input ---------------------------------------------------------------
    # Returns :commit when the user applies (the injected closure writes build_spec
    # back), else :stay.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      f = focused
      @notice = nil # an outcome is shown until the next key, then gone
      if sv = @saving
        return handle_save_name(ev, sv)
      end

      # The wordlist Path dropdown owns navigation keys while it's open.
      if outcome = path_dropdown_key(ev, f)
        return outcome
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

    # The Path dropdown's navigation while it is open on the Path row; nil when the key is not
    # its business (a printable falls through to edit the field and refilter the list).
    private def path_dropdown_key(ev : Termisu::Event::Key, f : Symbol) : Symbol?
      return nil unless f == :path && @path_complete.open?
      key = ev.key
      case
      when key.tab?, key.enter?   then accept_path
      when key.back_tab?, key.up? then @path_complete.move(-1); :stay
      when key.down?              then @path_complete.move(1); :stay
      when key.escape?            then @path_complete.close; :stay
      end
    end

    # `^S` in the List editor: keep the values as a named wordlist.
    private def save_chord?(ev : Termisu::Event::Key) : Bool
      ev.ctrl? && !ev.alt? && !ev.shift? && ev.key.lower_s?
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

    # The Project type's two selector rows (#1352). `←/→` cycle the projection; `␣` or `←/→` flip
    # the sensitive opt-in; ↑/↓ move rows; ↵ applies from the last row and moves on from the
    # other. The opt-in starts OFF and is drawn where it cannot be missed once it is on.
    private def handle_project_selector(ev : Termisu::Event::Key, f : Symbol) : Symbol
      key = ev.key
      case
      when key.left?  then cycle_project(f, -1)
      when key.right? then cycle_project(f, 1)
      when space_key?(ev)
        @project_sensitive = !@project_sensitive if f == :project_sensitive
      when key.up?   then move_row(-1)
      when key.down? then move_row(1)
      when key.enter?
        return :commit if on_last_row?
        move_row(1)
      end
      :stay
    end

    private def space_key?(ev : Termisu::Event::Key) : Bool
      ev.key.space? || (ev.char == ' ' && !ev.ctrl? && !ev.alt?)
    end

    # ←/→ on a Project selector: the projection cycles through the five, the opt-in flips.
    private def cycle_project(f : Symbol, d : Int32) : Nil
      if f == :project_projection
        all = PayloadFrom::Projection.values
        @project_projection = all[(all.index!(@project_projection) + d) % all.size]
      else
        @project_sensitive = !@project_sensitive
      end
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
      when save_chord?(ev)                             then start_save
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
      @values.handle_edit_key(ev)
    end

    private def handle_field(ev : Termisu::Event::Key, f : Symbol) : Symbol
      return handle_preset_name(ev) if f == :preset_name # a selector row, not a TextField
      return handle_project_selector(ev, f) if f == :project_projection || f == :project_sensitive
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

    # ── Save the list as a named wordlist (#1353) ──────────────────────────────

    # The List type holds values typed or pasted here; `^S` keeps them as a list in the global
    # catalog (`gori run fuzz -w NAME`, this overlay's Wordlist type and every other tool's
    # `--wordlist` then find it by name). What is saved is exactly what this set would send —
    # the values as `build_spec` reads them, one per line, trimmed and without blank lines,
    # which is the List editor's own grammar (a list that needs a blank or a padded payload is
    # saved with `gori run wordlist save`).
    private def start_save : Nil
      if list_values.empty?
        @notice = "nothing to save — the list is empty"
        return
      end
      @replace_name = nil
      @saving = TextField.new("payloads-#{Time.local.to_s("%Y%m%d-%H%M%S")}.txt")
    end

    private def handle_save_name(ev : Termisu::Event::Key, name : TextField) : Symbol
      key = ev.key
      case
      when key.escape?
        @saving = nil
        @replace_name = nil
      when key.enter?
        commit_save(name.value.strip)
      else
        before = name.value
        name.handle_edit_key(ev)
        @replace_name = nil if name.value != before # a new name is a new question
      end
      :stay
    end

    # A refusal is shown, not raised: an existing name asks for a second ↵ (the operator's
    # explicit "replace it"), anything else — a name that is a path, an unwritable directory —
    # says why and leaves the prompt open to fix the name.
    private def commit_save(name : String) : Nil
      values = list_values
      begin
        entry = Gori::WordlistCatalog.save_values(name, values, overwrite: @replace_name == name)
        @saving = nil
        @replace_name = nil
        @notice = "saved #{Gori.plural(values.size, "value")} as #{entry.name} — " \
                  "pick it under Wordlist, or run with -w #{entry.name}"
      rescue ex : Gori::WordlistCatalog::Error
        if ex.reason.exists?
          @replace_name = name
          @notice = "#{name} already exists — ↵ again replaces it, or edit the name"
        else
          @notice = ex.message
        end
      end
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
      if sv = @saving
        sv.set_preedit(text)
        return
      end
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
        vals.empty? ? nil : SetSpec.list(vals)
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
      when :project
        SetSpec.project(@fields[:project_query].value.strip, @project_projection, @project_sensitive)
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
      when :project  then "Project"
      else                "List"
      end
    end

    FIELD_LABELS = {
      :from               => "From",
      :to                 => "To",
      :step               => "Step",
      :count              => "Count",
      :charset            => "Charset",
      :min                => "Min",
      :max                => "Max",
      :path               => "Path",
      :preset_name        => "Preset",
      :project_query      => "Query",
      :project_projection => "Reads",
      :project_sensitive  => "Secrets",
    }

    private def field_label(f : Symbol) : String
      FIELD_LABELS[f]? || ""
    end

    # --- rendering -----------------------------------------------------------
    LABEL_W = 9 # value column offset (widest field label "Charset" + padding)

    def overlay_box(area : Rect) : Rect?
      # 76 wide at most: the Type row carries seven labels now (Project joined Preset) and the
      # last of them did not fit in 66 columns, which drops it from the row without a word.
      w = {area.w - 4, 76}.min
      h = {area.h - 2, 20}.min
      return nil if w < 34 || h < 8
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        Overlay.too_small(screen, area, "payload set editor needs a larger window")
        return
      end
      # Not `title` — that is now the Overlay chrome method, and a local of the same name
      # shadowing it inside render is the collision C2 hit (Crystal has no `override`).
      card_title = @edit_index ? "PAYLOAD SET · edit" : "PAYLOAD SET · new"
      # bg: Theme.bg (not the card default panel) so the embedded List TextArea, which
      # always paints on Theme.bg, doesn't two-tone against the card interior.
      Frame.card(screen, box, card_title, bg: Theme.bg, border: Theme.border_focus)
      render_meta(screen, box, card_title)
      render_type_row(screen, box)
      Frame.tee_divider(screen, box, box.y + 2, Theme.bg)
      case @ptype
      when :list    then render_values(screen, box)
      when :preset  then render_preset(screen, box)
      when :project then render_project(screen, box)
      else               render_fields(screen, box)
      end
      render_save_prompt(screen, box)
      render_hint(screen, box)
      render_path_dropdown(screen, box) if @ptype == :wordlist
    end

    # `title` is threaded in rather than re-derived: it is dynamic here (` · edit` / ` · new`),
    # and `Frame.border_meta` keeps the count clear of whichever one was drawn.
    private def render_meta(screen : Screen, box : Rect, title : String) : Nil
      return unless @ptype == :list
      n = list_values.size
      Frame.border_meta(screen, box, title, Gori.plural(n, "value"))
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

    # The Project type (#1352): a QL field, then two selector rows. The projection row lists the five
    # projections the way the preset row lists presets; the opt-in row says what it lets in, and turns
    # loud when it is on.
    private def render_project(screen : Screen, box : Rect) : Nil
      vx = box.x + 2 + LABEL_W
      vw = {box.right - 2 - vx, 1}.max
      field_rows.each_with_index do |f, i|
        y = box.y + 3 + i
        break if y >= box.bottom - 3
        foc = @sel == i + 1
        bg = foc ? Theme.accent_bg : Theme.bg
        screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), bg) if foc
        screen.text(box.x + 2, y, field_label(f), foc ? Theme.text_bright : Theme.muted, bg)
        render_project_value(screen, box, f, y, vx, vw, foc, bg)
      end
      meta = "reads captured data · sends nothing · the run reports what it read"
      screen.text(box.x + 2, box.bottom - 4, meta, Theme.muted, Theme.bg, width: box.w - 4)
    end

    PROJECTION_HINTS = {
      PayloadFrom::Projection::ParamNames   => "parameter names of the selected requests",
      PayloadFrom::Projection::ParamValues  => "parameter values, decoded once",
      PayloadFrom::Projection::PathSegments => "request-path segments, as captured",
      PayloadFrom::Projection::JsEndpoints  => "endpoints found in captured JavaScript",
      PayloadFrom::Projection::Extracted    => "extract-rule values (needs Secrets)",
    }

    # One Project row's value column: the QL field, the projection chips, or the opt-in's state.
    private def render_project_value(screen : Screen, box : Rect, f : Symbol, y : Int32, vx : Int32,
                                     vw : Int32, foc : Bool, bg : Color) : Nil
      case f
      when :project_query
        @fields[f].render(screen, vx, y, vw, foc, foc ? Theme.text_bright : Theme.text, bg)
      when :project_projection
        # The selected projection and what it reads — the Mode row's shape. All five did not fit as
        # chips at the card's width, and a chip nobody can see is a projection nobody can pick.
        current = "‹ #{@project_projection.label} ›"
        screen.text(vx, y, current, foc ? Theme.text_bright : Theme.text, bg)
        hint = PROJECTION_HINTS[@project_projection]
        screen.text(vx + current.size + 2, y, hint, Theme.muted, bg, width: {vw - current.size - 2, 1}.max)
      else
        label = @project_sensitive ? "ON — cookies, credentials and extracted values can be read" : "off — credential material stays out"
        screen.text(vx, y, label, @project_sensitive ? Theme.accent : Theme.text, bg, width: vw)
      end
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
      reserved = @saving ? 1 : 0 # the "Save as" row sits above the hint
      Rect.new(box.x + 2, top, box.w - 4, {(box.bottom - 2 - reserved) - top, 1}.max)
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

    # The "Save as" row: a label and the name field, on the row above the hint. Only while
    # the prompt is open; `render_values` has already given up that row (`values_rect`).
    private def render_save_prompt(screen : Screen, box : Rect) : Nil
      return unless (sv = @saving) && @ptype == :list
      y = box.bottom - 3
      screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), Theme.accent_bg)
      screen.text(box.x + 2, y, "Save as", Theme.text_bright, Theme.accent_bg)
      vx = box.x + 2 + LABEL_W
      sv.render(screen, vx, y, {box.right - 2 - vx, 1}.max, true, Theme.text_bright, Theme.accent_bg)
    end

    private def render_hint(screen : Screen, box : Rect) : Nil
      if notice = @notice
        screen.text(box.x + 2, box.bottom - 2, notice, Theme.accent, Theme.bg, width: box.w - 4)
        return
      end
      hint =
        case @ptype
        when :list     then @saving ? "↵ save the list · esc cancel" : "↵ new value · ⇥ field · ^S save list · esc applies"
        when :wordlist then "filter · ↹/↵ complete · ^D favorite · ⇥ field · esc applies"
        when :preset   then "←/→ choose preset · ⇥ type · esc applies & closes"
        when :project  then "QL · ←/→ projection · ␣ sensitive · ⇥ field · esc applies"
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
        # A press inside a drawn field is a caret, not just a row focus — the one line every
        # other overlay with `text_fields` runs (`Overlay#handle_click`), and the whole
        # reason this card lists them. Without it the caret stayed wherever the last
        # keystroke left it, so the next character landed somewhere other than where the
        # operator pointed, and a drag anchored from that stale caret instead of the press.
        click_text_field(mx, my)
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

    def handle_double_click(area : Rect, mx : Int32, my : Int32) : Symbol
      return super unless @ptype == :list
      return :pass unless box = overlay_box(area)
      @values.select_word_at(values_rect(box), mx, my) ? :stay : :pass
    end

    def move(d : Int32) : Nil
      move_row(d)
    end
  end
end
