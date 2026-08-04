require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "./path_complete"
require "./overlay"

module Gori::Tui
  # Centered popup collecting the DESTINATION path for an export — Notes → "Export note"
  # and Issues → "Export issues". One path field with an inline PathComplete dropdown:
  # ImportOverlay's form, pointed the other way.
  #
  # Two callers share it because the form is identical and everything that differs (card
  # title, blurb, prefill, toast noun) is the `kind` axis ImportOverlay already models. The
  # WRITE itself rides in as the `on_commit` closure supplied by Runner#open_export, so
  # neither controller learns that a modal exists.
  #
  # NOT a subclass of ImportOverlay, and no shared PathFieldOverlay base was extracted:
  # Crystal has no `override`, so a subclass silently shadows a base contract method, and
  # the two forms validate in OPPOSITE directions — import demands the file exist, export
  # demands it be writable and NOT (silently) exist. If a fourth path form ever appears,
  # extracting the field + dropdown + box geometry is the refactor to make then.
  #
  # It defines no handle_click for the same reason ImportOverlay doesn't: the one field is
  # always focused, so the base default (click inside → stay, outside → dismiss) already IS
  # this form's behaviour.
  class ExportOverlay < Overlay
    getter kind : Symbol

    # The filename the directory fill-in below drops in. Derived from the prefill so the
    # default name has exactly one source — the open-site's `default_path`.
    getter default_basename : String

    def initialize(@kind : Symbol, default_path : String)
      @field = TextField.new(default_path)
      @default_basename = File.basename(default_path)
      @path_complete = PathComplete.new
      @notice = ""
      @overwrite_armed = false
      # Deliberately NO @path_complete.refresh here: the field arrives prefilled, and a
      # dropdown covering the card before the user has touched anything reads as noise.
      # TextField#set parked the caret at the END, so the basename is what's under it.
    end

    def path : String
      @field.value.strip
    end

    # The path as the filesystem sees it. This is the ONLY place `~`/relative expansion
    # happens (same idiom as Import.import_file and PathComplete), so the exists-check, the
    # write and the result toast can never disagree about which file this is. A relative
    # name resolves against the cwd, matching `gori run issues --export=`.
    def resolved_path : String
      p = path
      p.empty? ? p : Path[p].expand(home: true).to_s
    end

    # The export SUBJECT, for the card title and the Runner's result toast — one source so
    # the popup and the toast can't disagree about what was written.
    def label : String
      case @kind
      when :note        then "note"
      when :issues_md   then "issues (Markdown)"
      when :issues_json then "issues (JSON)"
      else                   "file"
      end
    end

    private def blurb : String
      case @kind
      when :note        then "Write the current note's text to a Markdown file."
      when :issues_md   then "Write the Markdown issue report to a file."
      when :issues_json then "Write every issue to a JSON file."
      else                   "Write the export to a file."
      end
    end

    # --- Overlay contract (see overlay.cr) -----------------------------------
    def key : OverlayKind
      OverlayKind::Export
    end

    def title : String
      "EXPORT #{label}"
    end

    # The single-line fields the pointer can reach — see `Overlay#text_fields`. Listing them
    # is the whole opt-in: caret placement on a press, drag to extend, double-click for a
    # word, all inverted by the field against the geometry `render` last drew it at.
    def text_fields : Array(TextField)
      [@field]
    end

    def hint : String
      "type to complete · ↹ pick · ↑↓ browse · ↵ write · esc cancel"
    end

    # --- input ---------------------------------------------------------------
    # :commit when the destination validates, :cancel on esc, else :stay.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key

      # esc peels one layer at a time: the dropdown first, the popup only once it's down —
      # so a stray esc can't discard a path the user just typed.
      if key.escape?
        return :cancel unless @path_complete.open?
        @path_complete.close
        return :stay
      end

      return commit_or_complete(key) if key.tab? || key.enter?

      if key.back_tab? || key.up?
        @path_complete.move(-1) if @path_complete.open?
        return :stay
      end
      if key.down?
        @path_complete.move(1) if @path_complete.open?
        return :stay
      end

      @field.handle_edit_key(ev)
      @path_complete.refresh(@field.value) # keep the dropdown in lockstep
      disarm                               # a retyped path is a DIFFERENT path — re-ask before clobbering it
      :stay
    end

    # ↹/↵ with the dropdown up accepts the highlighted entry (a directory keeps the list
    # open so the user can keep drilling, a file closes it); ↵ landing on a file falls
    # through to `validate` in the same keystroke. With no dropdown up, ↵ validates what
    # was typed. ↹ alone never writes.
    private def commit_or_complete(key : Termisu::Input::Key) : Symbol
      if @path_complete.open? && (res = @path_complete.accept)
        insert, is_dir = res
        @field.set(insert)
        disarm
        if is_dir
          @path_complete.refresh(insert)
        else
          @path_complete.close
          return validate if key.enter?
        end
        return :stay
      end
      key.enter? ? validate : :stay
    end

    # The destination checks, in the order a user hits them. Every failure returns :stay so
    # the typed path stays on screen for in-place correction rather than being thrown away.
    # Runtime failures (permissions, ENOSPC, a directory that vanished) are NOT checked here
    # — they belong to the write, which reports them by returning false from on_commit.
    private def validate : Symbol
      p = resolved_path

      # Unlike ImportOverlay, an empty field is not a cancel: this form arrives PREFILLED,
      # so a cleared field means the user is mid-edit, not backing out.
      if p.empty?
        @notice = "type a destination path"
        return :stay
      end

      # A directory isn't an error, it's a half-finished path — fill in the file name and
      # let the next ↵ write it, exactly like a Save-As dialog. (PathComplete#accept leaves
      # a trailing '/' on a directory; File.join handles that.)
      if File.directory?(p)
        @field.set(File.join(p, @default_basename))
        @notice = "filled in the file name — ↵ to write"
        return :stay
      end

      # No mkdir_p: silently creating a directory tree from a typo'd path is worse than
      # refusing to write.
      parent = File.dirname(p)
      unless File.directory?(parent)
        @notice = "no such directory: #{parent}"
        return :stay
      end

      if File.exists?(p) && !@overwrite_armed
        @overwrite_armed = true
        @notice = "file exists — ↵ again to overwrite"
        return :stay
      end

      :commit
    end

    # Any edit or completion invalidates the arm: the ↵ that overwrites must be the one
    # immediately after the warning, for the path that was warned about.
    private def disarm : Nil
      @overwrite_armed = false
      @notice = ""
    end

    def set_preedit(text : String) : Nil
      @field.set_preedit(text)
    end

    # Wheel support — the Runner routes a scroll here, and the only scrollable thing is the
    # completion list.
    def move(d : Int32) : Nil
      @path_complete.move(d) if @path_complete.open?
    end

    # --- rendering -----------------------------------------------------------
    LABEL_W = 8 # value column offset ("Path" + padding)

    # Tall enough (14) that PathComplete's 8-row cap fits under the field instead of being
    # clipped; `area` still wins on a short terminal.
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 6, 76}.min
      h = {area.h - 4, 14}.min
      return nil if w < 40 || h < 8
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        unless area.empty?
          screen.text(area.x + 1, area.y, "export needs a larger window · esc to close",
            Theme.muted, Theme.bg)
        end
        return
      end
      Frame.card(screen, box, "EXPORT #{label.upcase} · destination path", bg: Theme.bg,
        border: Theme.border_focus)
      screen.text(box.x + 2, box.y + 1, blurb, Theme.muted, Theme.bg, width: box.w - 4)
      render_field(screen, box)
      render_footer(screen, box)
      render_dropdown(screen, box)
    end

    # Notice and hint SHARE the bottom row rather than stacking. An extra row would sit
    # under the 8-deep dropdown, which is drawn last and would overdraw it — and the row
    # the eye is already on is where a warning belongs.
    private def render_footer(screen : Screen, box : Rect) : Nil
      text = @notice.empty? ? hint : "⚠ #{@notice}"
      fg = @notice.empty? ? Theme.muted : Theme.yellow
      screen.text(box.x + 2, box.bottom - 2, text, fg, Theme.bg, width: box.w - 4)
    end

    # The single field is always focused (there's nowhere else to go), so it always carries
    # the focus band.
    private def render_field(screen : Screen, box : Rect) : Nil
      y = field_y(box)
      screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), Theme.accent_bg)
      screen.text(box.x + 2, y, "Path", Theme.text_bright, Theme.accent_bg)
      vx = value_x(box)
      vw = {box.right - 2 - vx, 1}.max
      @field.render(screen, vx, y, vw, true, Theme.text_bright, Theme.accent_bg)
    end

    private def render_dropdown(screen : Screen, box : Rect) : Nil
      return unless @path_complete.open?
      @path_complete.render(screen, value_x(box), field_y(box) + 1, box.inset(1, 1))
    end

    private def field_y(box : Rect) : Int32
      box.y + 3
    end

    private def value_x(box : Rect) : Int32
      box.x + 2 + LABEL_W
    end
  end
end
