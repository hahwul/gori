require "json"
require "../settings"
require "../env"

module Gori::Tui
  # How the TUI avoids writing a stale `env.syntax` back over a peer's switch.
  #
  # `Settings.save` merges with the file per SECTION (`pick_changed`): a section this process
  # changed wins whole. The grammar lives in the `env` section beside the vars and the prefix, so
  # EVERY var edit in the Settings env card — and every prefix commit on the Project tab's ENV
  # pane — rewrites it, and the env section is never reloaded while the TUI runs. A
  # `gori settings env-syntax namespaced` in another terminal was therefore undone by the next
  # `a`/`e`/`d` on that card: the operator's switch reverted with no message, and every editor in
  # the session went back to reading tokens under the grammar they had left.
  #
  # No TUI surface sets the grammar any more (switching it has to RE-SPELL the tokens already
  # stored in project DBs and in the global rules, which is `gori settings env-syntax`'s work), so
  # there is nothing for this process to own: whenever the file states a grammar, the file is
  # right and the in-memory copy is the one that may be stale. Re-read it before any env-section
  # write, so a save that is about a var (or about the sigil) carries no opinion about the
  # grammar.
  module EnvSyntaxSeam
    # Adopt the FILE's grammar before writing the env section. Unconditional: the only writer of
    # this key is the CLI verb, so a difference means a peer switched while this session was up.
    def self.refresh_from_disk : Nil
      found = disk_syntax
      return unless found
      Settings.env_syntax = found unless found == Settings.env_syntax
    end

    # The grammar as the FILE spells it, or nil when the file has NOTHING TO SAY.
    #
    # "Nothing to say" is four cases and they all mean "keep what this session has": no file yet (a
    # home whose first save has not landed — the in-memory grammar is the only copy there is), bytes
    # that will not parse, a value this build does not know, and an ABSENT key.
    #
    # The absent key belongs in that list now. `serialize_env` always writes the grammar, so a peer
    # that switched wrote it down; an absence is a file from before namespaces, and what a
    # pre-namespace file means is settled by `Settings.load`'s adoption — not by a refresh whose only
    # job is to avoid clobbering a peer's switch. Reading it as bare here would have a stale file
    # flip a live session's grammar (and, through the marker, its next project open) to the one
    # thing this seam exists to prevent.
    def self.disk_syntax : Env::Syntax?
      path = Settings.path
      return nil unless File.exists?(path)
      root = JSON.parse(File.read(path)).as_h?
      return nil unless root
      raw = root["env"]?.try(&.as_h?).try(&.["syntax"]?).try(&.as_s?)
      return nil unless raw
      Env::Syntax.parse?(raw.strip)
    rescue
      nil
    end
  end
end
