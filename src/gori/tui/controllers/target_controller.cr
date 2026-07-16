require "../tab_controller"
require "./sitemap_controller"
require "./discover_controller"

module Gori::Tui
  # The Target parent tab: a fixed two-sub-tab multiplexer over the existing Sitemap and
  # the new Discover views — "‹ Sitemap · Discover ›". It composes both child controllers
  # (they are NOT registered in the Runner's @tabs) and forwards nearly every hook to the
  # active child. command_scope/command_section delegate to the child, so every existing
  # Sitemap verb keeps firing when the Sitemap sub-tab is active, and Discover verbs fire
  # when the Discover sub-tab is active — no re-scoping.
  class TargetController < TabController
    SUBS = ["Sitemap", "Discover"]

    def initialize(host : Host)
      super(host)
      @sitemap = SitemapController.new(host)
      @discover = DiscoverController.new(host)
      @active_sub = 0
    end

    # child accessors (the Runner reaches Sitemap/Discover verbs through these)
    def sitemap : SitemapController
      @sitemap
    end

    def discover : DiscoverController
      @discover
    end

    def sitemap_active? : Bool
      @active_sub == 0
    end

    private def active_child : TabController
      @active_sub == 0 ? @sitemap : @discover
    end

    # --- identity ---
    def tab : Symbol
      :target
    end

    def command_scope : Verb::Scope
      active_child.command_scope
    end

    def command_section : Symbol
      active_child.command_section
    end

    # --- sub-tab strip (fixed set: no ^N/^W create/close) ---
    def subtab_labels : Array(String)?
      SUBS
    end

    def subtab_index : Int32
      @active_sub
    end

    def subtab_strip_shown? : Bool
      true
    end

    def subtabs_fixed? : Bool
      true
    end

    def move_subtab(dir : Int32) : Nil
      set_sub(@active_sub + dir)
    end

    def jump_subtab(idx : Int32) : Nil
      set_sub(idx)
    end

    private def set_sub(idx : Int32) : Nil
      idx = idx.clamp(0, SUBS.size - 1)
      return if idx == @active_sub
      active_child.commit # flush any outgoing in-progress edit (base no-op for both children today)
      @active_sub = idx
      active_child.on_enter # refresh the incoming child (Sitemap re-derives its tree)
    end

    # --- rendering ---
    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      # Sitemap is a single tree that relies on the outer frame gilding on focus; Discover
      # draws its own inner cards, so its outer frame stays a hairline (multi_pane).
      shell = BodyChrome.shell_focused(focus, multi_pane: @active_sub == 1)
      subtabs_focused = focus == :subtabs
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, subtabs_focused,
        subtab_labels, @active_sub, @subtab_start) do |content|
        if @active_sub == 0
          @sitemap.render_content(screen, content, focus)
        else
          @discover.render_content(screen, content, focus)
        end
      end
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      content = BodyChrome.content_rect(rect, strip: true)
      if @active_sub == 0
        @sitemap.handle_click_content(content, mx, my)
      else
        @discover.handle_click_content(content, mx, my)
      end
    end

    # --- forwarded input / focus / lifecycle ---
    def handle_body_key(ev : Termisu::Event::Key) : Bool
      active_child.handle_body_key(ev)
    end

    def handle_wheel(step : Int32) : Bool
      active_child.handle_wheel(step)
    end

    def handle_wheel_at(step : Int32, mx : Int32, my : Int32, rect : Rect) : Bool
      active_child.handle_wheel_at(step, mx, my, rect)
    end

    def body_scroll(delta : Int32) : Bool
      active_child.body_scroll(delta)
    end

    def set_preedit(text : String) : Bool
      active_child.set_preedit(text)
    end

    def body_badge : Symbol
      active_child.body_badge
    end

    def body_hint(focus : Symbol) : String
      active_child.body_hint(focus)
    end

    def goto_symbol : Symbol?
      active_child.goto_symbol
    end

    def pane_advance(dir : Int32) : Bool
      active_child.pane_advance(dir)
    end

    def focus_first : Nil
      active_child.focus_first
    end

    def focus_last : Nil
      active_child.focus_last
    end

    def on_enter : Nil
      active_child.on_enter
    end

    def on_external_change : Nil
      active_child.on_external_change
    end

    def commit : Nil
      active_child.commit
    end

    def locked? : Bool
      active_child.locked?
    end

    # A finished Discover job's notification jumps here: select the Discover sub-tab and
    # reveal the run.
    def reveal_session(id : Int64) : Nil
      set_sub(1)
      @discover.reveal_session(id)
    end

    def select_discover : Nil
      set_sub(1)
    end
  end
end
