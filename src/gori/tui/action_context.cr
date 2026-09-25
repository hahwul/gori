require "../verb"

module Gori::Tui
  # "What can I do here", captured at the keystroke that asks. `Space` and `Ctrl-P` both take
  # it before they open, and both list the focused tab's actions from it, so the two surfaces
  # answer the question identically (#1282):
  #   * `scope` / `section` — the tab's command scope and the focused area within it;
  #   * `subtabs` — the tab has a sub-tab family, so the strip's SUB-TABS bucket joins every
  #     view of it (#1055);
  #   * `banner` — the state the actions will act on ("3 MARKED", #442), or nil.
  #
  # It is captured, never re-read, because opening either surface changes what a re-read
  # would see: the palette takes `@overlay`, and an open History detail answers
  # `@overlay.detail?` only while nothing sits on top of it.
  record ActionContext, scope : Verb::Scope, section : Symbol, subtabs : Bool = false, banner : String? = nil do
    # The rule behind `Runner#action_context`, pure so it can be pinned without a terminal.
    #
    # Deliberately DISTINCT from the keymap's `Runner#current_scope`: the tab bar keeps
    # Sidebar for keybindings (so Repeater's chords don't fire while navigating tabs), but
    # both surfaces on the tab bar offer that TAB's own top actions instead. An open History
    # detail is its own scope with no sections.
    #
    # `subtabs` is keyed to the registry and NOT to whether the strip is drawn: a Repeater
    # with no sessions open draws no strip, and gating on the strip being DRAWN would have
    # taken `New repeater request` off the menu in exactly the empty state that verb exists
    # for. Scopes with no `:subtab` verbs are unaffected either way — an empty bucket drops.
    def self.capture(registry : Verb::Registry, *, detail : Bool, focus : Symbol, scope : Verb::Scope,
                     pane_section : Symbol, banner : String? = nil) : ActionContext
      if detail
        scope = Verb::Scope::HistoryDetail
        section = :common
      else
        section = case focus
                  when :menu    then registry.has_section?(scope, :tab) ? :tab : :common
                  when :subtabs then :subtab
                  else               pane_section
                  end
      end
      new(scope, section, registry.has_section?(scope, :subtab), banner)
    end
  end
end
