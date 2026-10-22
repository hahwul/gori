require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./text_area"
require "../settings"
require "../env"

module Gori::Tui
  # The operator's own `$GEN.USER_AGENT` list (settings:user-agents, #1154): a plain multi-line
  # editor, one User-Agent per line, the same shape `gori settings user-agents --set` reads
  # (`Settings.user_agents_from_text` is the ONE parser). An EMPTY buffer means the built-in
  # list — the buffer is never pre-filled with it, because saving an untouched copy would pin
  # today's built-in versions into settings.json and stop them refreshing with gori.
  #
  # esc saves and closes. A line that cannot be a header value refuses the close and names
  # itself, the rule `DiscoverHeadersOverlay` settled: a dropped line silently changes which
  # browser gori claims to be. As there, the refusal holds only while the card that explains it
  # is on screen; where it cannot be drawn, esc closes WITHOUT saving and the degraded line says
  # so, since there is no partial list worth writing.
  class UserAgentsOverlay < Overlay
    include SavingEditorCard # `on_commit` (Runner#user_agents_editor) saves only a list that parsed

    def initialize
      @opened_with = Settings.user_agents
      @editor = TextArea.new(@opened_with.join("\n"))
      @refused = nil.as(String?)
      @card_drawn = true # see DiscoverHeadersOverlay: production draws before it reads a key
    end

    # The parsed buffer, or the first line that cannot be a User-Agent.
    def parsed : Array(String) | String
      Settings.user_agents_from_text(@editor.text)
    end

    # The list to write on commit, or nil when there is nothing to write: a buffer that does not
    # parse, or one the operator left as it opened. esc always commits, and the peer tick can move
    # `Settings.user_agents` underneath an open editor (`reload_user_agents_from_disk`), so "did
    # the operator change anything" is asked against the list this editor OPENED on, never the
    # live one — or closing an untouched editor wrote its stale copy over a peer's new list.
    def edited_list : Array(String)?
      list = parsed
      list.is_a?(Array(String)) && list != @opened_with ? list : nil
    end

    # The list to save; call only once `parsed` answered a list.
    def user_agents : Array(String)
      parsed.as?(Array(String)) || Settings.user_agents
    end

    def refusal : String?
      (why = parsed).is_a?(String) ? "#{why} — fix or delete it" : nil
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::UserAgents
    end

    def title : String
      "USER-AGENTS"
    end

    def hint : String
      "type one per line · empty = built-in list · esc saves & closes"
    end

    def overlay_box(area : Rect) : Rect?
      area.card?(100, 18, 34, 8)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      @card_drawn = !box.nil?
      unless box
        render_degraded(screen, area) unless area.empty?
        return
      end
      Frame.card(screen, box, "USER-AGENTS", bg: Theme.bg, border: Theme.border_focus)
      hintline = box.bottom - 2
      editor = editor_rect(box)
      if @editor.line_count == 1 && @editor.text.empty?
        screen.text(editor.x, editor.y,
          "empty — $GEN.USER_AGENT draws from the built-in list (#{Env::USER_AGENTS.size})",
          Theme.muted, Theme.bg, width: editor.w)
        screen.cursor(editor.x, editor.y)
      else
        @editor.render(screen, editor, cursor: true)
      end
      if refused = @refused
        screen.text(box.x + 2, hintline, refused, Theme.red, Theme.bg, width: box.w - 4)
      else
        screen.text(box.x + 2, hintline,
          "one per line, replaces the built-in list · a family with no line of yours uses the built-in one",
          Theme.muted, Theme.bg, width: box.w - 4)
      end
    end

    private def render_degraded(screen : Screen, area : Rect) : Nil
      if refusal
        screen.text(area.x + 1, area.y, "esc closes WITHOUT saving · a line is unusable · widen the window to fix", Theme.red, Theme.bg)
      else
        screen.text(area.x + 1, area.y, "User-Agents editor needs a larger window · esc saves & closes", Theme.muted, Theme.bg)
      end
    end
  end
end
