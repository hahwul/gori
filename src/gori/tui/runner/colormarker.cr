# Colormarker (History row-colour rules) — ExecContext verb implementations, reopens
# Gori::Tui::Runner (see tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  forward colormarker_add : Nil,
    colormarker_edit : Nil,
    colormarker_toggle : Nil,
    colormarker_delete : Nil,
    colormarker_filter : Nil,
    to: colormarker_controller

  def colormarker_move(dir : Int32) : Nil
    colormarker_controller.colormarker_move(dir)
  end

  forward colormarker_duplicate : Nil,
    colormarker_reload : Nil,
    to: colormarker_controller

  def colormarker_rule_selected? : Bool
    colormarker_controller.rule_selected?
  end

  # The POLICY pane is the focused one. Gates the rule chords so `x`/`s`/⇧J cannot act on a rule
  # while the CUSTOM COLORS pane is up — a chord has no `section:` to keep it away.
  def colormarker_rule_list_focused? : Bool
    colormarker_controller.rule_list_focused?
  end

  # The selected rule is a GLOBAL one — the gate for the verb that only means something for
  # the library half (flip the default everywhere).
  def colormarker_global_rule_selected? : Bool
    colormarker_controller.global_rule_selected?
  end

  forward colormarker_scope_toggle : Nil,
    colormarker_toggle_default : Nil,
    to: colormarker_controller

  # --- CUSTOM COLORS pane ---
  def colormarker_colors_focused? : Bool
    colormarker_controller.colors_focused?
  end

  def colormarker_color_selected? : Bool
    colormarker_controller.color_selected?
  end

  def colormarker_color_add : Nil
    colormarker_controller.customcolor_add
  end

  def colormarker_color_edit : Nil
    colormarker_controller.customcolor_edit
  end

  def colormarker_color_delete : Nil
    colormarker_controller.customcolor_delete
  end
end
