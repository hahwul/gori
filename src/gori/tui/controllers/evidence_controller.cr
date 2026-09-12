require "../tab_controller"
require "../evidence_view"
require "../../hotkeys"

module Gori::Tui
  # The Evidence tab: a project-wide, read-only metadata list whose row opens the existing
  # frozen request/response viewer. Link/delete/duplicate/compare remain Runner-mediated
  # because they cross tabs or open overlays; this controller owns only list navigation.
  class EvidenceController < TabController
    def initialize(host : Host)
      super(host)
      @evidence = EvidenceView.new
    end

    def view : EvidenceView
      @evidence
    end

    def tab : Symbol
      :evidence
    end

    def command_scope : Verb::Scope
      Verb::Scope::Evidence
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      focused = focus == :body
      BodyChrome.framed(screen, rect, focused) { |inner| @evidence.render(screen, inner, focused) }
    end

    def handle_body_key(ev : Termisu::Event::Key) : Bool
      return handle_query_key(ev) if @evidence.querying?
      return false if ev.ctrl? || ev.alt?
      case
      when nav_up?(ev)
        @evidence.at_top? ? @host.request_focus(:menu) : @evidence.move(-1)
        true
      when nav_down?(ev)
        @evidence.move(1)
        true
      when ev.key.escape?
        if @evidence.compare_anchor
          @evidence.clear_compare
          @host.status("evidence comparison cancelled")
        else
          @host.request_focus(:menu)
        end
        true
      else
        false
      end
    end

    def body_scroll(delta : Int32) : Bool
      @evidence.move(delta)
      true
    end

    def page_rows : Int32?
      @evidence.list_page_rows
    end

    def body_badge : Symbol
      @evidence.querying? ? :editor : :body
    end

    def body_hint(focus : Symbol) : String
      if @evidence.querying?
        "type to filter · ↵ apply · esc clear"
      elsif anchor = @evidence.compare_anchor
        # `(older→newer)`: the pair is ordered by `created_at`, not by which half was pinned
        # first (`evidence_compare`), so A here is the anchor and NOT necessarily the left side
        # the Comparer opens with. Saying so costs six columns and stops the reading that a
        # pin order chooses the diff direction.
        "A=##{anchor} · move to B · c compare (older→newer) · esc cancel"
      else
        keys("↑/↓ move · ↵ open · {evidence.filter} filter · {evidence.compare} compare · {evidence.issue} issue · {evidence.source} source · space cmds · esc tabs")
      end
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      if idx = @evidence.row_at(rect.inset(1, 1), mx, my)
        @evidence.select(idx)
      end
      true
    end

    def handle_double_click(rect : Rect, mx : Int32, my : Int32) : Bool
      return false unless idx = @evidence.row_at(rect.inset(1, 1), mx, my)
      @evidence.select(idx)
      @host.evidence_open
      true
    end

    def handle_query_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      if action = LineEdit.action(ev)
        @evidence.query_edit(action)
      elsif key.enter?
        @evidence.stop_query
      elsif key.escape?
        @evidence.cancel_query
      elsif key.left?
        @evidence.query_move(-1)
      elsif key.right?
        @evidence.query_move(1)
      elsif key.backspace?
        @evidence.query_backspace
      elsif (ch = ev.char || key.to_char) && !ev.ctrl? && !ev.alt?
        @evidence.query_insert(ch)
        @evidence.set_preedit("")
      end
      true
    end

    def set_preedit(text : String) : Bool
      return false unless @evidence.querying?
      @evidence.set_preedit(text)
      true
    end

    def on_enter : Nil
      @evidence.reload(@host.session.store)
    end

    def on_external_change : Nil
      @evidence.reload(@host.session.store)
    end
  end
end
