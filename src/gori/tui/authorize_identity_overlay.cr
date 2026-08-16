require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./text_field"
require "./text_area"
require "../authorize/identity"
require "../discover/headers"

module Gori::Tui
  # Add or edit ONE Authorize identity: a name, the headers it SETS (a multi-line buffer, one
  # `Name: Value` per line — how an operator pastes a Cookie straight out of devtools), and the
  # headers it REMOVES (a comma list, since an anonymous identity only names them).
  #
  # It does NOT touch the baseline flag. That flag has an invariant — exactly one identity
  # carries it — and the only place it moves is the list's `b`, which rewrites the whole list at
  # once. Leaving it out of the form is what makes two-baselines unreachable rather than merely
  # unlikely.
  #
  # A line the wire cannot carry is REFUSED and named, not dropped: `Discover::Headers` owns
  # that rule (a value may not contain CR/LF, a name must be an RFC 7230 token) and reports
  # which lines it would not take. Dropping an `Authorization` line in silence is how an
  # authenticated sweep runs unauthenticated and reports nothing found.
  class AuthorizeIdentityOverlay < Overlay
    NAME_ROW   = 0
    REMOVE_ROW = 1
    EDITOR_ROW = 2
    SAVE_ROW   = 3

    getter index : Int32? # nil = adding

    # Names already taken by OTHER identities, lower-cased. A duplicate would put two rows
    # under one label in the results table, and nothing on screen would say which session
    # produced which verdict.
    @taken : Set(String)

    def initialize(identity : Authorize::Identity? = nil, @index : Int32? = nil,
                   taken : Array(String) = [] of String)
      @name = TextField.new(identity.try(&.name) || "")
      set_text = (identity.try(&.set_headers) || [] of {String, String})
        .map { |name, value| "#{name}: #{value}" }.join("\n")
      @editor = TextArea.new(set_text)
      @remove = TextField.new((identity.try(&.remove_headers) || [] of String).join(", "))
      @baseline = identity.try(&.baseline?) || false
      @taken = taken.map(&.downcase).to_set
      @sel = NAME_ROW
      @refused = nil.as(String?)
    end

    def editing? : Bool
      !@index.nil?
    end

    def name : String
      @name.value.strip
    end

    def set_headers : Array({String, String})
      Discover::Headers.parse_lines(@editor.text.split('\n'))
    end

    def remove_headers : Array(String)
      @remove.value.split(',').map(&.strip).reject(&.empty?)
    end

    # Lines the header parser will not turn into a header, in buffer order.
    def rejected_lines : Array(String)
      rejected = [] of String
      Discover::Headers.parse_lines(@editor.text.split('\n'), rejected)
      rejected
    end

    # Why this form cannot be saved yet, or nil when it can.
    def refusal : String?
      return "an identity needs a name" if name.empty?
      return "another identity is already called #{name.inspect}" if @taken.includes?(name.downcase)
      if first = rejected_lines.first?
        label = first.partition(':')[0].strip
        label = first.strip if label.empty?
        label = "#{label[0, 39]}…" if label.size > 40
        return "#{label.inspect} will not be sent — a value may not contain CR or LF, " \
               "and a name must be an RFC 7230 token"
      end
      nil
    end

    # The identity this form describes, or nil while `refusal` stands.
    def build_identity : Authorize::Identity?
      return nil if refusal
      Authorize::Identity.new(name, set_headers, remove_headers, @baseline)
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::AuthorizeIdentity
    end

    def title : String
      editing? ? "EDIT IDENTITY" : "ADD IDENTITY"
    end

    def hint : String
      "⇥ field · type · ↵ save (newline in headers) · esc cancel"
    end

    def text_fields : Array(TextField)
      [@name, @remove]
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :cancel if key.escape?
      if key.tab?
        move(1)
        return :stay
      elsif key.back_tab?
        move(-1)
        return :stay
      end

      case @sel
      when NAME_ROW, REMOVE_ROW
        field = @sel == NAME_ROW ? @name : @remove
        if key.enter?
          return :commit
        elsif key.up?
          move(-1)
        elsif key.down?
          move(1)
        else
          @refused = nil
          field.handle_edit_key(ev)
        end
        :stay
      when EDITOR_ROW
        edit(ev)
        :stay
      else
        (key.enter? || key.space?) ? :commit : :stay
      end
    end

    # ⏎ inserts a header line here; everything else is the shared TextArea keymap (⇧arrows
    # select, word motion, ⌥⌫), so a header line can be selected and retyped.
    private def edit(ev : Termisu::Event::Key) : Nil
      @refused = nil
      key = ev.key
      case
      when key.enter?                    then @editor.insert_newline
      when @editor.word_delete_key?(ev)  then @editor.handle_motion_key(ev)
      when key.backspace?                then @editor.backspace
      when key.delete?                   then @editor.delete
      when @editor.handle_motion_key(ev) then nil
      else
        ch = ev.char || key.to_char
        @editor.insert(ch) if ch && !ev.ctrl? && !ev.alt?
      end
    end

    # Refuse to close on a form that cannot become an identity, and SAY why — the shell only
    # closes on a true here, so a false keeps the card up with `@refused` on its band.
    def commit : Bool
      @refused = refusal
      return false if @refused
      (c = on_commit) ? c.call : true
    end

    def move(d : Int32) : Nil
      @sel = (@sel + d).clamp(NAME_ROW, SAVE_ROW)
    end

    def set_selected(idx : Int32) : Nil
      @sel = idx.clamp(NAME_ROW, SAVE_ROW)
    end

    def set_preedit(text : String) : Nil
      case @sel
      when NAME_ROW   then @name.set_preedit(text)
      when REMOVE_ROW then @remove.set_preedit(text)
      when EDITOR_ROW then @editor.set_preedit(text)
      end
    end

    # --- pointer ---
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      ed = editor_rect(box)
      if my == box.y + 2
        set_selected(NAME_ROW)
      elsif my == box.y + 3
        set_selected(REMOVE_ROW)
      elsif my == box.bottom - 2
        set_selected(SAVE_ROW)
        return :commit
      elsif ed.contains?(mx, my)
        set_selected(EDITOR_ROW)
        @editor.click_to_cursor(ed, mx, my)
        return :stay
      end
      click_text_field(mx, my)
      :stay
    end

    def supports_drag? : Bool
      true
    end

    def handle_drag(area : Rect, mx : Int32, my : Int32) : Nil
      return unless box = overlay_box(area)
      return unless @sel == EDITOR_ROW
      @editor.click_to_cursor(editor_rect(box), mx, my, selecting: true)
    end

    # --- geometry / render ---
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 68}.min
      h = {area.h - 2, 18}.min
      return nil if w < 40 || h < 12
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    # The SET-headers buffer, between the two single-line fields and the refusal band. Shared
    # by render and the pointer entries so a click cannot land on a row the draw never used.
    private def editor_rect(box : Rect) : Rect
      top = box.y + 5
      Rect.new(box.x + 3, top, box.w - 6, {(box.bottom - 3) - top, 1}.max)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "identity form needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      # `card_title`, never a local called `title`: Crystal has no `override`, so a local of
      # that name silently shadows the contract method (fuzz_set_overlay hit exactly this).
      card_title = title
      Frame.card(screen, box, card_title, bg: Theme.bg, border: Theme.border_focus)
      draw_field(screen, box, box.y + 2, row_bg(NAME_ROW), row_fg(NAME_ROW),
        @sel == NAME_ROW, "name:", @name)
      draw_field(screen, box, box.y + 3, row_bg(REMOVE_ROW), row_fg(REMOVE_ROW),
        @sel == REMOVE_ROW, "remove:", @remove)
      screen.text(box.x + 3, box.y + 4, "set headers — one Name: Value per line",
        Theme.muted, Theme.bg, width: box.w - 6)
      ed = editor_rect(box)
      if @editor.line_count == 1 && @editor.text.empty?
        screen.text(ed.x, ed.y, "e.g. Cookie: session=…", Theme.muted, Theme.bg, width: ed.w)
        screen.cursor(ed.x, ed.y) if @sel == EDITOR_ROW
      else
        @editor.render(screen, ed, cursor: @sel == EDITOR_ROW)
      end
      band = box.bottom - 3
      if refused = @refused
        screen.text(box.x + 3, band, refused, Theme.red, Theme.bg, width: box.w - 6)
      end
      save_y = box.bottom - 2
      ok = refusal.nil?
      screen.fill(Rect.new(box.x + 1, save_y, box.w - 2, 1), row_bg(SAVE_ROW))
      screen.cell(box.x + 1, save_y, @sel == SAVE_ROW ? '▎' : ' ', Theme.accent, row_bg(SAVE_ROW))
      screen.text(box.x + 3, save_y, ok ? "[ Save identity ]" : "[ #{refusal} ]",
        ok ? Theme.accent : Theme.muted, row_bg(SAVE_ROW), Attribute::Bold, width: box.w - 6)
    end

    private def row_bg(row : Int32) : Color
      @sel == row ? Theme.accent_bg : Theme.bg
    end

    private def row_fg(row : Int32) : Color
      @sel == row ? Theme.text_bright : Theme.text
    end
  end
end
