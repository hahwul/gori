require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./tag_input"

module Gori::Tui
  # The Project tab's Edit tags card: the new-project form's tags field (`TagInput`), alone.
  # `↵` on an empty buffer commits through the injected `on_commit`, which stores `#tags`.
  class TagPromptOverlay < Overlay
    getter input : TagInput
    @preedit = ""

    def initialize(tags : Array(String), known : Array({String, Int32}))
      @input = TagInput.new(tags.dup, known)
    end

    def key : OverlayKind
      OverlayKind::TagPrompt
    end

    def title : String
      "EDIT TAGS"
    end

    def hint : String
      "↵ add/save · tab complete · ←/→ pick · ⌫ remove · esc cancel"
    end

    # Every tag on the card, a word still being typed included. Raises like
    # `ProjectRegistry.normalize_tags`.
    def tags : Array(String)
      @input.final_tags
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      @preedit = ""
      return :cancel if ev.key.escape?
      @input.handle(ev).submit? ? :commit : :stay
    end

    def set_preedit(text : String) : Nil
      @preedit = text
    end

    def overlay_box(area : Rect) : Rect?
      area.card?(72, 8, 34, 7)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      return render_too_small(screen, area, "tag editor") unless box
      Frame.card(screen, box, title, bg: Theme.bg, border: Theme.border_focus)
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), Theme.accent_bg)
      prefix = "tags › "
      screen.text(box.x + 2, y, prefix, Theme.text_bright, Theme.accent_bg)
      vx = box.x + 2 + Screen.display_width(prefix)
      vw = {box.right - 2 - vx, 1}.max
      @input.render_field(screen, vx, y, vw, Theme.text_bright, Theme.accent_bg, true, @preedit)
      @input.render_suggestions(screen, vx, y + 1, vw, Theme.bg)
      if why = @input.refusal
        screen.text(box.x + 2, box.bottom - 3, why, Theme.red, Theme.bg, width: iw)
      end
      screen.text(box.x + 2, box.bottom - 2, hint, Theme.muted, Theme.bg, width: iw)
    end
  end
end
