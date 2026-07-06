require "../tab_controller"
require "../help_view"

module Gori::Tui
  # The Help tab: three read-only sub-tabs sharing one strip — Shortcuts (the
  # scrollable cheat-sheet), Links (project URLs), About (version, later a logo).
  # Unlike Replay/Notes the set is FIXED: no create/close/rename. The strip, focus
  # routing, ←/→, ^1-9 and click hit-testing all come free from the runner's shared
  # sub-tab machinery once we expose subtab_labels; we add only the page renderers.
  class HelpController < TabController
    # The fixed sub-tab strip. Index 0 (Shortcuts) is the default landing page,
    # preserving the tab's original behaviour.
    PAGE_LABELS = ["Shortcuts", "Links", "About"]

    @current : Int32 = 0

    def initialize(host : Host)
      super(host)
      @help = HelpView.new
    end

    def tab : Symbol
      :help
    end

    def command_scope : Verb::Scope
      Verb::Scope::Body
    end

    # --- fixed sub-tab strip (no new/close/rename) ---
    def subtab_labels : Array(String)
      PAGE_LABELS
    end

    def subtab_index : Int32
      @current
    end

    def move_subtab(dir : Int32) : Nil
      @current = (@current + dir).clamp(0, PAGE_LABELS.size - 1)
    end

    def jump_subtab(idx : Int32) : Nil
      @current = idx if 0 <= idx < PAGE_LABELS.size
    end

    def subtabs_fixed? : Bool # constant set, read-only body — no ^N/^W, no editing
      true
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      focused = focus == :body
      shell = BodyChrome.shell_focused(focus, multi_pane: false)
      BodyChrome.framed_body(screen, rect, shell, focus == :subtabs, PAGE_LABELS, @current) do |content|
        case @current
        when 1 then @help.render_links(screen, content)
        when 2 then @help.render_version(screen, content)
        else        @help.render(screen, content, focused: focused) # Shortcuts
        end
      end
    end

    # Read-only navigation. ←/→ switch pages (claimed so arrows never fall through
    # to top-level tab switching — there's no caret to move here). ↑/↓ scroll only
    # the Shortcuts page; ↑ at its top (or any non-scrolling page) steps up to the
    # strip. esc pops to the tab bar. EVERY other key falls through (return false)
    # so the space menu and the global keymap still see it.
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      case
      when key.escape?              then @host.request_focus(:menu)
      when key.left?, key.lower_h?  then move_subtab(-1)
      when key.right?, key.lower_l? then move_subtab(1)
      when key.up?, key.lower_k?
        (@current == 0 && !@help.at_top?) ? @help.move(-1) : @host.request_focus(:subtabs)
      when key.down?, key.lower_j?
        @help.move(1) if @current == 0
      else
        return false # ^P / space / q / global keys pass through
      end
      true
    end

    def handle_wheel(step : Int32) : Bool
      @help.move(step) if @current == 0 # only the Shortcuts page scrolls
      true
    end

    def body_hint(focus : Symbol) : String
      # No "q projects": q (back to the picker) is tab-bar-only by design, so the
      # body must not advertise it as a key (esc/↹ to the bar first, then q).
      "↑/↓ scroll · ←/→ pages · ↹/esc tabs · ^P cmds"
    end
  end
end
