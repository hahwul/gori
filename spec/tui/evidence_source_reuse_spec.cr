require "../spec_helper"

# The Evidence tab's `s` (open original source) against a REUSED Repeater id.
#
# `Store#evidence_count_for` has always guarded the marker with `created_at >= repeaters.created_at`
# — `repeaters.id` has no AUTOINCREMENT, so a tab opened after the source tab was closed can
# inherit its id while the copy outlives the close. The two Runner methods asked only whether a
# row with that id exists, so `s` navigated to the successor and presented it as the original.
# The store half is spec/store/issue_evidence_spec.cr's; `Runner.new` owns a terminal and
# appears nowhere under spec/, so the wiring is pinned by reading the source, the idiom
# `evidence_drift_confirm_spec` established. Comments are stripped first: a comment explaining
# a rule contains the tokens the rule looks for.
private def runner_evidence_code : String
  File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner", "evidence.cr"))
    .lines.reject(&.lstrip.starts_with?('#')).join('\n')
end

describe "the Evidence tab's source navigation" do
  it "asks the store whether the source is still THIS copy's source, not whether the id resolves" do
    body = runner_evidence_code
    available = body[/def evidence_source_available\?.*?\n  end/m].not_nil!
    available.should contain("evidence_source_alive?(meta)")
    # The old test, which a reused id passes.
    available.should_not contain("get_repeater(meta.source_id)")

    reused = body[/private def evidence_source_reused\?.*?\n  end/m].not_nil!
    reused.should contain("meta.source_kind.repeater?")
    reused.should contain("evidence_source_alive?(meta)")
  end

  it "refuses with the reason instead of opening an unrelated tab" do
    open_source = runner_evidence_code[/def evidence_open_source.*?\n  end/m].not_nil!
    open_source.should contain("evidence_source_reused?(meta)")
    # The sentence itself is a constant now: the Issues detail's `s` (#1038 follow-up) asks
    # the same question about the same rows, and two surfaces spelling one refusal twice is
    # how they come to disagree about it.
    open_source.should contain("EVIDENCE_SOURCE_REUSED")
    Gori::Tui::Runner::EVIDENCE_SOURCE_REUSED
      .should eq("the original repeater tab is gone (its id was reused)")
    # …and the refusal comes FIRST: `navigate_link_ref` would otherwise have already jumped.
    open_source.index("evidence_source_reused?").not_nil!
      .should be < open_source.index("navigate_link_ref").not_nil!
  end

  # The Issues detail's `s` on a FROZEN row is the same guard, in the same order, against the
  # same reused id — it is the one place outside the Evidence tab that navigates to a frozen
  # copy's source.
  it "guards the Issues detail's `s` with the same predicate, ahead of the jump" do
    goto = runner_evidence_code[/def issue_goto_link.*?\n  end/m].not_nil!
    goto.should contain("evidence_source_reused?(m)")
    goto.should contain("EVIDENCE_SOURCE_REUSED")
    goto.should contain("evidence_source_alive?(m)")
    goto.index("evidence_source_reused?").not_nil!
      .should be < goto.index("navigate_link_ref").not_nil!
  end
end
