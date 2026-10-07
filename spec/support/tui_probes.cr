require "../spec_helper"

# Spec-only probes over production paths, kept out of `src/` because nothing there calls them.
module Gori::Tui
  module Chrome
    # The drawn rect of a tagged top-bar chip (or nil if absent) — rebuilds the SAME
    # chip list + layout render_top_bar uses, so a click on `notify:N` can't drift
    # from the glyph. Used by the Runner to make the badge clickable.
    #
    # `min_x` reproduces render_top_bar's project-name floor WITHOUT a live Screen:
    # that floor only ever resolves to one of two values — `rect.right -
    # chips_width - 1` (chips have room; the name gets whatever's left) or `name_x +
    # 1` (chips are wider than available space, so the name is squeezed to zero
    # width) — never something in between, since the name's own drawn width is
    # itself bounded by the same floor. `chip_layout`'s `{A, min_x}.max` picks the
    # right one either way, so passing `name_x + 1` here matches the real render
    # exactly regardless of the actual project string or its truncation.
    def self.top_bar_chip_rect(rect : Rect, tag : Symbol, *, scope : String, probe : String = "",
                               rules : String = "", intercept : String = "", sandbox : String = "",
                               listen : String, unread : Int32 = 0, capturing : Bool = true,
                               write_failures : Int32 = 0, bypass : Int32 = 0,
                               authorize : String = "", session : String = "",
                               agents : String = "", asks : Int32 = 0) : Rect?
      chips = top_bar_chips(scope: scope, probe: probe, rules: rules, intercept: intercept,
        sandbox: sandbox, listen: listen, unread: unread, capturing: capturing,
        write_failures: write_failures, bypass: bypass, authorize: authorize, session: session,
        agents: agents, asks: asks)
      idx = chips.index { |c| c.tag == tag }
      return nil unless idx
      name_x = rect.x + 1 + Screen.display_width(WORDMARK) + 1
      chip_layout(rect, chips, name_x + 1)[idx]?
    end
  end

  class InterceptView
    # What a forward of `it` sends: the editor's bytes for the loaded item while it has an
    # edit, else the original raw bytes — the expression `intercept_forward` evaluates.
    def forward_bytes(it : Interceptor::Item) : Bytes
      edit = pending_edit
      (edit && edit[0] == it.id) ? edit[1] : it.raw
    end
  end
end
