# Rewriter (Match & Replace rules) — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  def rewriter_add : Nil
    rewriter_controller.rewriter_add
  end

  def rewriter_edit : Nil
    rewriter_controller.rewriter_edit
  end

  def rewriter_toggle : Nil
    rewriter_controller.rewriter_toggle
  end

  def rewriter_delete : Nil
    rewriter_controller.rewriter_delete
  end

  def rewriter_move(dir : Int32) : Nil
    rewriter_controller.rewriter_move(dir)
  end

  def rewriter_duplicate : Nil
    rewriter_controller.rewriter_duplicate
  end

  def rewriter_reload : Nil
    rewriter_controller.rewriter_reload
  end

  # A rule the operator can actually SEE is selected. The sub-tab half is load-bearing: the
  # Rewriter tab is one workflow with three sub-tabs, `selected_rule` is the RULES list
  # regardless of which is on screen, and `RewriterController` does not override
  # `command_section` — so on the `extract` and `bindings` sub-tabs the space menu still
  # offered all six Match&Replace verbs, acting on a selection that was not rendered.
  # `space`+`x` there disabled a live rewrite rule with no confirm and no visible change,
  # while the DIRECT `x` on that same sub-tab means "toggle the extract rule" — one letter,
  # one keypress apart, two tables. Same shape as the 2026-07-29 space-menu scope leak, one
  # axis down: that one forgot `current_tab`, this one forgets `@sub`.
  def rewriter_rule_selected? : Bool
    rewriter_controller.rules_sub? && !rewriter_controller.selected_rule.nil?
  end

  def rewriter_rules_sub? : Bool
    rewriter_controller.rules_sub?
  end

  # The PREVIEW OUTPUT pane holds focus — the gate for its four read verbs (x / v / S / y).
  def rewriter_preview_out? : Bool
    rewriter_controller.rewriter_preview_out_focused?
  end

  def rewriter_save_preset : Nil
    open_rule_preset_save
  end

  def rewriter_load_preset : Nil
    open_rule_preset_load
  end

  # --- the global rule-preset library (settings.json `rewriter.presets`) ---
  # Both are Host methods (tab_controller.cr) as well as verb bodies, mirroring the
  # Decoder's chain library: the Rewriter body binds `s` / `o` directly, and a controller
  # cannot open an overlay itself.

  # Seeded with the rule's own name — an already-labelled rule saves in one keystroke.
  # An unnamed rule falls back to its pattern, which is what the list shows for it too, so
  # the suggested name matches the row the operator is looking at.
  def open_rule_preset_save : Nil
    c = rewriter_controller
    rule = c.selected_rule || return status("no rule selected")
    seed = rule.name.empty? ? rule.pattern : rule.name
    ov = NamePromptOverlay.new("SAVE RULE TO LIBRARY", Rules.summary(rule), seed)
    ov.on_commit = -> {
      c.save_rule_preset(rule, ov.name)
      true
    }
    open_overlay(ov)
  end

  # The detail column carries each preset's rule summary, so the library is readable
  # without loading anything. A pick APPENDS a live rule to this project — never a merge
  # and never a replacement of the current list, which is why one preset is one rule.
  def open_rule_preset_load : Nil
    presets = Settings.rewriter_presets
    lp = LibraryPicker.new("LOAD RULE", preset_rows(presets), "rule", action: "add")
    lp.on_commit = -> {
      # Index against the SAME array this picker's rows were built from — `presets` is
      # reassigned by on_delete below, and a stale index into a shorter list would add a
      # neighbouring rule rather than nothing.
      if (i = lp.selected_index) && (preset = presets[i]?)
        rewriter_controller.load_rule_preset(preset)
      end
      true
    }
    # ^X drops the preset from the LIBRARY only. Rules already loaded into a project are
    # ordinary rows in its own DB and keep rewriting traffic — deleting the recipe is not
    # deleting what was cooked from it, which is why the toast says "from the library".
    lp.on_delete = ->(i : Int32) {
      if preset = presets[i]?
        ok = Settings.delete_rewriter_preset(preset.id)
        presets = Settings.rewriter_presets
        lp.set_rows(preset_rows(presets))
        @toast = ok ? "deleted \"#{preset.name}\" from the library" : "could not delete \"#{preset.name}\""
      end
      nil
    }
    open_overlay(lp)
  end

  private def preset_rows(presets : Array(Settings::RulePreset)) : Array(LibraryPicker::Row)
    presets.map_with_index { |p, i| LibraryPicker::Row.new(i, p.name, Rules.preset_summary(p)) }
  end
end
