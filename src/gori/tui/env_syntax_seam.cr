require "../settings"
require "../env"
require "../env_migration/store"

module Gori::Tui
  # How a running TUI follows a token-grammar switch made in ANOTHER terminal.
  #
  # `Settings.save` merges with the file per SECTION (`pick_changed`): a section this process
  # changed wins whole. The grammar lives in the `env` section beside the vars and the prefix, so
  # EVERY var edit in the Settings env card — and every prefix commit on the Project tab's ENV
  # pane — rewrites it, and the env section is never reloaded while the TUI runs. A
  # `gori settings env-syntax namespaced` in another terminal was therefore undone by the next
  # `a`/`e`/`d` on that card: the operator's switch reverted with no message, and every editor in
  # the session went back to reading tokens under the grammar they had left.
  #
  # No TUI surface SETS the grammar, so there is nothing for this process to own: whenever the file
  # states a grammar, the file is right and the in-memory copy is the one that may be stale.
  #
  # But adopting it is only half the act, and the half that was here. A grammar switch re-spells
  # the tokens stored in the project database — and `gori settings env-syntax` cannot re-spell a
  # project that is already open in this process, because the marker check inside the reconcile is
  # what keeps two openers from doing it twice. So the session has to do it itself, and then say
  # what it did. That is `EnvMigration.follow_disk`; this module is the TUI's adapter onto it —
  # `follow` at every seam that could notice, `announce` on the three surfaces the OPEN-TIME
  # migration already uses (the ring, the bottom-bar toast, the ACTIVITY feed the reconcile writes
  # itself).
  module EnvSyntaxSeam
    # Adopt the FILE's grammar, re-spell this session's project, and hand back the notices. Empty
    # when the file says nothing new, which is every call but the one after a peer's switch.
    #
    # `session` is nilable so the overlay-level specs — which drive the env card with no project
    # open — take the same door the Runner does; a nil one adopts the grammar and has nothing to
    # re-spell, which is also the unbound case.
    def self.follow(session : Gori::Session? = nil) : Array(String)
      Gori::EnvMigration.follow_disk(session.try(&.store), session.try(&.project.db_path),
        session.try(&.project.name))
    end

    # The grammar the FILE states, or nil when it has nothing to say. A delegate, so a TUI-side
    # reader does not grow a second copy of the four "nothing to say" cases.
    def self.disk_syntax : Env::Syntax?
      Gori::EnvMigration.disk_syntax
    end

    # Put the notices in the ring, and answer the one a caller may want as a toast. `:warn`, like
    # the open-time announcement: the bytes in this operator's Repeater tabs changed, and `:info`
    # takes neither the bell nor the toast (`Notifications#push`).
    def self.announce(lines : Array(String), notifications : Notifications) : String?
      lines.each { |line| notifications.push(:warn, line, goto: Jobs::Goto.new(:project)) }
      lines.first?
    end
  end
end
