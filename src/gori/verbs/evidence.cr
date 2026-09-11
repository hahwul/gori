require "../verb"

module Gori
  module Verbs
    def self.register_evidence(r : Verb::Registry) : Nil
      selected = ->(ctx : Verb::ExecContext) { !ctx.selected_evidence_id.nil? }

      r.register Verb::Definition.new(
        "evidence.open", "Open frozen evidence", "Inspect the immutable request and response",
        Verb::Scope::Evidence, [Verb::Chord.new("enter"), Verb::Chord.new("l"), Verb::Chord.new("right")],
        available: selected, mnemonic: 'o', group: :view) { |ctx| ctx.evidence_open; nil }

      r.register Verb::Definition.new(
        "evidence.filter", "Filter evidence", "Filter by issue, host, method, HTTP status, confirmation, source or date",
        Verb::Scope::Evidence, [Verb::Chord.new("/")], group: :view) { |ctx| ctx.evidence_filter; nil }

      r.register Verb::Definition.new(
        "evidence.compare", "Compare snapshots", "Pin this snapshot as A, then choose B and compare their frozen bytes",
        Verb::Scope::Evidence, [Verb::Chord.new("c")], available: selected, group: :view) { |ctx| ctx.evidence_compare; nil }

      r.register Verb::Definition.new(
        "evidence.issue", "Open linked Issue", "Open an Issue linked to this snapshot",
        Verb::Scope::Evidence, [Verb::Chord.new("i")],
        available: ->(ctx : Verb::ExecContext) { selected.call(ctx) && ctx.evidence_has_links? },
        group: :triage) { |ctx| ctx.evidence_open_issue; nil }

      r.register Verb::Definition.new(
        "evidence.source", "Open original source", "Open the History flow or Repeater tab when it still exists",
        Verb::Scope::Evidence, [Verb::Chord.new("s")],
        available: ->(ctx : Verb::ExecContext) { selected.call(ctx) && ctx.evidence_source_available? },
        group: :view) { |ctx| ctx.evidence_open_source; nil }

      r.register Verb::Definition.new(
        "evidence.copy-as", "Copy as…", "Copy the frozen request/response through the project's body-redaction policy",
        Verb::Scope::Evidence, available: selected, mnemonic: 'Y', group: :copy) { |ctx| ctx.copy_as_open; nil }

      # `⇧E`, not `e`: `e` is Edit in every scope that has something to edit, and the
      # archive has nothing — the same pairing `issues.export-key` and `notes.export` use
      # (spelled shift + lowercase, because a typed capital normalises to that and a bare
      # "E" chord could never fire).
      r.register Verb::Definition.new(
        "evidence.export", "Export evidence", "Write a redacted JSON copy to a file",
        Verb::Scope::Evidence, [Verb::Chord.new("e", shift: true)], available: selected,
        mnemonic: 'E', group: :copy) { |ctx| ctx.evidence_export; nil }

      r.register Verb::Definition.new(
        "evidence.repeater", "Duplicate into Repeater", "Create an editable Repeater tab from the frozen request",
        Verb::Scope::Evidence, [Verb::Chord.new("r")], available: selected,
        group: :send) { |ctx| ctx.evidence_duplicate_repeater; nil }

      # Menu-only, like `link.*.attach`: both open a picker, and neither has a chord to
      # spare here. `k`/`u` are the SPACE-MENU keys — `k` as a chord would never fire (the
      # controller claims j/k as list nav before the keymap is consulted) and would read as
      # "move up", which is what k does in every other list scope.
      r.register Verb::Definition.new(
        "evidence.link", "Link Issue…", "Link this snapshot to another Issue without changing its bytes",
        Verb::Scope::Evidence, available: selected,
        mnemonic: 'k', group: :triage) { |ctx| ctx.evidence_link_issue; nil }

      r.register Verb::Definition.new(
        "evidence.unlink", "Unlink Issue…", "Remove one Issue link without changing the snapshot",
        Verb::Scope::Evidence,
        available: ->(ctx : Verb::ExecContext) { selected.call(ctx) && ctx.evidence_has_links? },
        mnemonic: 'u', group: :triage) { |ctx| ctx.evidence_unlink_issue; nil }

      r.register Verb::Definition.new(
        "evidence.delete", "Delete evidence", "Delete this immutable copy after confirming every affected Issue link",
        Verb::Scope::Evidence, [Verb::Chord.new("d")], available: selected,
        group: :danger) { |ctx| ctx.evidence_delete; nil }
    end
  end
end
