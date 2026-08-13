require "../tab_controller"
require "../help_view"

module Gori::Tui
  # The Help tab: three read-only sub-tabs sharing one strip — Shortcuts (the scrollable
  # cheat-sheet), Query (the QL reference) and About (brand art, version, author, GitHub).
  # Unlike Repeater/Notes the set is FIXED: no create/close/rename. The strip, focus
  # routing, ←/→, ^1-9 and click hit-testing all come free from the runner's shared
  # sub-tab machinery once we expose subtab_labels; we add only the page renderers.
  class HelpController < TabController
    # The fixed sub-tab strip. Index 0 (Shortcuts) is the default landing page,
    # preserving the tab's original behaviour. Query sits BESIDE Shortcuts rather than after
    # About: the two are the same kind of thing (a reference you scroll), where About is the
    # colophon, and ^2 landing on a reference reads better than ^2 landing on brand art.
    PAGE_LABELS = ["Shortcuts", "Query", "About"]

    @current : Int32 = 0

    # Derived from the LABEL rather than the index, so reordering `PAGE_LABELS` can never leave a
    # predicate pointing at a different page. Inserting Query already shifted About from 1 to 2 and
    # four separate `@current == 0` / `== 1` literals had to move with it — the failure mode being
    # a page that renders the wrong content or silently stops scrolling. The label is the thing
    # that actually names the page, and nothing in the strip machinery depends on a fixed position.
    # (Named predicates mirror `ProbeController#rules_tab?`; deriving them from the label goes one
    # step further.)
    private def page : String
      PAGE_LABELS[@current]? || PAGE_LABELS.first
    end

    private def query_page? : Bool
      page == "Query"
    end

    private def about_page? : Bool
      page == "About"
    end

    # About is a centred static block with nothing below the fold; the other two scroll.
    private def scrollable_page? : Bool
      !about_page?
    end

    # Scroll whichever page is showing. Each keeps its OWN offset (see `HelpView`), so switching
    # pages does not carry one page's position onto another.
    private def page_move(delta : Int32) : Nil
      return unless scrollable_page?
      query_page? ? @help.query_move(delta) : @help.move(delta)
    end

    private def page_at_top? : Bool
      query_page? ? @help.query_at_top? : @help.at_top?
    end

    def initialize(host : Host)
      super(host)
      @help = HelpView.new(host.session.registry)
    end

    # Rebuild the cheat-sheet after settings:hotkeys save so labels match dispatch.
    def reload_help(registry : Verb::Registry) : Nil
      @help.reload(registry)
    end

    def tab : Symbol
      :help
    end

    def command_scope : Verb::Scope
      Verb::Scope::Body
    end

    # PageUp/PageDown/Home/End over the (long) Help cheat-sheet. move() clamps the top;
    # the bottom is clamped at render (clamp_scroll), so the large Home/End magnitude is
    # safe and lands on the last page.
    def body_scroll(delta : Int32) : Bool
      page_move(delta)
      true
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
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, focus == :subtabs, PAGE_LABELS, @current, @subtab_start) do |content|
        if about_page?
          @help.render_about(screen, content)
        elsif query_page?
          @help.render_query(screen, content)
        else
          @help.render(screen, content, focused: focused) # Shortcuts
        end
      end
    end

    # Read-only navigation. ←/→ switch pages (claimed so arrows never fall through
    # to top-level tab switching — there's no caret to move here). ↑/↓ scroll whichever
    # page is showing; ↑ at its top (or on About, which does not scroll) steps up to the
    # strip. esc pops to the tab bar. EVERY other key falls through (return false)
    # so the space menu and the global keymap still see it.
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      case
      when key.escape?              then @host.request_focus(:menu)
      when key.left?, key.lower_h?  then move_subtab(-1)
      when key.right?, key.lower_l? then move_subtab(1)
      when key.up?, key.lower_k?
        (scrollable_page? && !page_at_top?) ? page_move(-1) : @host.request_focus(:subtabs)
      when key.down?, key.lower_j?
        page_move(1)
      else
        return false # ^P / space / q / global keys pass through
      end
      true
    end

    def handle_wheel(step : Int32) : Bool
      page_move(step) # About is static; the other two scroll
      true
    end

    def body_hint(focus : Symbol) : String
      # No "q projects": q (back to the picker) is tab-bar-only by design, so the
      # body must not advertise it as a key (esc/↹ to the bar first, then q).
      "↑/↓ scroll · ←/→ pages · ↹/esc tabs · ^P cmds"
    end
  end
end
