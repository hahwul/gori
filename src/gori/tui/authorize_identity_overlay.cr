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
    # The refresh POLICY (#1233): off / jwt-exp / ttl=10m. The refresh STEPS it applies to are
    # shown read-only on the line above it — they are added from the Repeater (space → b),
    # `gori run session edit --refresh` or MCP, where the request is authored and tested.
    POLICY_ROW = 3
    SAVE_ROW   = 4

    getter index : Int32? # nil = adding
    # The focused row, one of the four constants above.
    getter selected : Int32

    # Names already taken by OTHER identities, lower-cased. A duplicate would put two rows
    # under one label in the results table, and nothing on screen would say which session
    # produced which verdict.
    @taken : Set(String)
    # The original header rows let `build_identity` distinguish an unchanged captured value
    # from an operator edit. Provenance is deliberately reconstructed from the displayed text:
    # changing, removing, or adding a row must make it manual again.
    @original_set_headers : Array({String, String})
    @original_literal_headers : Array(String)

    # The step labels of the slot being edited (`SessionRefresh.step_labels`), in order.
    getter refresh_labels : Array(String)

    def initialize(identity : Authorize::Identity? = nil, @index : Int32? = nil,
                   taken : Array(String) = [] of String,
                   @refresh_labels : Array(String) = [] of String)
      @name = TextField.new(identity.try(&.name) || "")
      @original_set_headers = identity.try(&.set_headers) || [] of {String, String}
      @original_literal_headers = identity.try(&.literal_headers) || [] of String
      set_text = @original_set_headers
        .map { |name, value| "#{name}: #{value}" }.join("\n")
      @editor = TextArea.new(set_text)
      # The `$BIND.SESSION` / `$GEN.UUID` completer, in the ONE editor where a slot's overlay
      # headers are written. Deliberately WITHOUT `highlight: :request`
      # on the render: these are header lines with no start line, and the request painter reads
      # line 0 as `METHOD path HTTP/1.1`, so `Cookie: x` would paint as a malformed verb.
      @editor.env_complete = true
      # BIND and GEN only. These header values are resolved by `Env.expand_bindings_as` on the
      # replay path and by NOTHING else — there is no build-time `Env.expand` pass over a slot's
      # overlay headers — so offering `$ENV.UA` would put literal bytes on the wire. The completer
      # (and the peek behind it) is where that offer is constrained.
      @editor.env_complete_namespaces = [Env::Namespace::Bind, Env::Namespace::Gen]
      @remove = TextField.new((identity.try(&.remove_headers) || [] of String).join(", "))
      @baseline = identity.try(&.baseline?) || false
      @refresh = identity.try(&.refresh) || [] of Int64
      @policy = TextField.new((identity.try(&.refresh_before) || SessionSlot::RefreshBefore.off).to_s)
      @taken = taken.map(&.downcase).to_set
      @selected = NAME_ROW
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

    # The policy as typed, or nil while it does not parse.
    def refresh_before : SessionSlot::RefreshBefore?
      SessionSlot::RefreshBefore.parse?(@policy.value)
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
      return "refresh before: use off, jwt-exp or ttl=10m" unless refresh_before
      nil
    end

    # The identity this form describes, or nil while `refusal` stands.
    def build_identity : Authorize::Identity?
      return nil if refusal
      headers = set_headers
      Authorize::Identity.new(name, headers, remove_headers, @baseline, [] of String,
        surviving_literals(headers), @refresh, refresh_before || SessionSlot::RefreshBefore.off)
    end

    # The captured-value marker as it survives this edit. `SessionSlot#literal_header?` is keyed
    # by NAME, and `overlay_head` upserts, so for a name the operator typed twice only the LAST
    # row reaches the wire — and that row alone decides whether the name is still captured
    # bytes. Anything else marks a hand-written `$BIND.X` literal and sends the token's spelling
    # instead of its value, which is the one failure this form must not introduce.
    private def surviving_literals(headers : Array({String, String})) : Array(String)
      marked = [] of String
      headers.each do |(header_name, value)|
        next unless @original_literal_headers.any? { |n| same_header?(n, header_name) }
        captured = @original_set_headers.any? do |(original_name, original_value)|
          same_header?(original_name, header_name) && original_value == value
        end
        marked.reject! { |n| same_header?(n, header_name) }
        marked << header_name if captured
      end
      marked
    end

    private def same_header?(a : String, b : String) : Bool
      a.compare(b, case_insensitive: true) == 0
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

    # Which pasted keystrokes reach this card (see `Overlay#takes_pasted?`): the headers editor takes a line break as a newline; the name/remove rows keep the default.
    def takes_pasted?(ev : Termisu::Event::Key) : Bool
      @selected == EDITOR_ROW || !ev.key.enter?
    end

    def text_fields : Array(TextField)
      [@name, @remove, @policy]
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      # The popup FIRST, before esc and before ⇥ — while it is open it owns ↹/↵/↑/↓/esc, which
      # are exactly the keys this form's row navigation and its cancel claim. Routed after them
      # the dropdown would have been unreachable: ↹ would jump to the next row and esc would
      # throw the whole identity away rather than close a list.
      if @selected == EDITOR_ROW && @editor.env_completing? && @editor.handle_env_complete_key(ev)
        return :stay
      end
      return :cancel if key.escape?
      if key.tab?
        move(1)
        return :stay
      elsif key.back_tab?
        move(-1)
        return :stay
      end

      case @selected
      when NAME_ROW, REMOVE_ROW then field_key(ev, @selected == NAME_ROW ? @name : @remove)
      when EDITOR_ROW           then editor_key(ev)
      when POLICY_ROW           then field_key(ev, @policy)
      else                           save_key(ev)
      end
    end

    private def field_key(ev : Termisu::Event::Key, field : TextField) : Symbol
      key = ev.key
      return :commit if key.enter?
      if key.up?
        move(-1)
      elsif key.down?
        move(1)
      else
        @refused = nil
        field.handle_edit_key(ev)
      end
      :stay
    end

    # ↑/↓ move the caret INSIDE the buffer until it reaches an edge, and only then leave the
    # row — the same "at_top? ? leave : move" rule the Fuzzer template and the Discover lists
    # follow. Without it the editor was a keyboard trap: arrows never left it, so ⇥ was the
    # only way out and Save could not be reached by walking down the form.
    private def editor_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      if key.up? && @editor.at_top?
        move(-1)
      elsif key.down? && @editor.at_bottom?
        move(1)
      else
        edit(ev)
      end
      :stay
    end

    private def save_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :commit if key.enter? || key.space?
      # The last row still has to be walkable BACK out of; only ⇥ used to leave it.
      move(-1) if key.up?
      :stay
    end

    # ⏎ inserts a header line here; everything else is the shared TextArea keymap (⇧arrows
    # select, word motion, ⌥⌫), so a header line can be selected and retyped.
    private def edit(ev : Termisu::Event::Key) : Nil
      @refused = nil
      key = ev.key
      case
      when key.enter?                    then @editor.insert_newline
      when ev.ctrl? && key.lower_z?      then @editor.undo # the undo chord every body editor binds
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
      @selected = (@selected + d).clamp(NAME_ROW, SAVE_ROW)
    end

    def set_selected(idx : Int32) : Nil
      @selected = idx.clamp(NAME_ROW, SAVE_ROW)
    end

    def set_preedit(text : String) : Nil
      case @selected
      when NAME_ROW   then @name.set_preedit(text)
      when REMOVE_ROW then @remove.set_preedit(text)
      when EDITOR_ROW then @editor.set_preedit(text)
      when POLICY_ROW then @policy.set_preedit(text)
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
      elsif my == policy_y(box)
        set_selected(POLICY_ROW)
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
      return unless @selected == EDITOR_ROW
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
      top = box.y + 6 # name, drop, its caption, the set-headers caption
      Rect.new(box.x + 3, top, box.w - 6, {(box.bottom - 5) - top, 1}.max)
    end

    # The refresh steps (read-only) and the policy field sit between the editor and the
    # refusal band.
    private def steps_y(box : Rect) : Int32
      box.bottom - 5
    end

    private def policy_y(box : Rect) : Int32
      box.bottom - 4
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        Overlay.too_small(screen, area, "identity form needs a larger window")
        return
      end
      # `card_title`, never a local called `title`: Crystal has no `override`, so a local of
      # that name silently shadows the contract method (fuzz_set_overlay hit exactly this).
      card_title = title
      Frame.card(screen, box, card_title, bg: Theme.bg, border: Theme.border_focus)
      draw_field(screen, box, box.y + 2, row_bg(NAME_ROW), row_fg(NAME_ROW),
        @selected == NAME_ROW, "name:", @name)
      # "drop headers:" against "set headers" below — the PAIR is what says both rows are
      # about headers. Labelled `remove:` on its own, the field gave no clue it wanted header
      # NAMES, and a first-time reader had nothing to go on but the example in the buffer.
      draw_field(screen, box, box.y + 3, row_bg(REMOVE_ROW), row_fg(REMOVE_ROW),
        @selected == REMOVE_ROW, "drop headers:", @remove)
      screen.text(box.x + 3, box.y + 4, "names, comma separated — e.g. Cookie, Authorization",
        Theme.muted, Theme.bg, width: box.w - 6)
      screen.text(box.x + 3, box.y + 5, "set headers — one Name: Value per line",
        Theme.muted, Theme.bg, width: box.w - 6)
      ed = editor_rect(box)
      if @editor.line_count == 1 && @editor.text.empty?
        screen.text(ed.x, ed.y, "e.g. Cookie: session=…", Theme.muted, Theme.bg, width: ed.w)
        screen.cursor(ed.x, ed.y) if @selected == EDITOR_ROW
      else
        @editor.render(screen, ed, cursor: @selected == EDITOR_ROW)
      end
      steps = @refresh.empty? ? "none — add a Repeater sub-tab with space → b" : @refresh_labels.join(" → ")
      screen.text(box.x + 3, steps_y(box), "refresh:  #{steps}", Theme.muted, Theme.bg, width: box.w - 6)
      draw_field(screen, box, policy_y(box), row_bg(POLICY_ROW), row_fg(POLICY_ROW),
        @selected == POLICY_ROW, "refresh before:", @policy)
      band = box.bottom - 3
      if refused = @refused
        screen.text(box.x + 3, band, refused, Theme.red, Theme.bg, width: box.w - 6)
      end
      save_y = box.bottom - 2
      ok = refusal.nil?
      screen.fill(Rect.new(box.x + 1, save_y, box.w - 2, 1), row_bg(SAVE_ROW))
      screen.cell(box.x + 1, save_y, @selected == SAVE_ROW ? '▎' : ' ', Theme.accent, row_bg(SAVE_ROW))
      screen.text(box.x + 3, save_y, ok ? "[ Save identity ]" : "[ #{refusal} ]",
        ok ? Theme.accent : Theme.muted, row_bg(SAVE_ROW), Attribute::Bold, width: box.w - 6)
    end

    private def row_bg(row : Int32) : Color
      @selected == row ? Theme.accent_bg : Theme.bg
    end

    private def row_fg(row : Int32) : Color
      @selected == row ? Theme.text_bright : Theme.text
    end
  end
end
