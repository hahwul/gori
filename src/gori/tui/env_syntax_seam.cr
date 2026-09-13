require "json"
require "../settings"
require "../env"

module Gori::Tui
  # Who owns `env.syntax` while a TUI session is up, and how the TUI avoids writing a stale
  # answer back over a peer's.
  #
  # `Settings.save` merges with the file per SECTION (`pick_changed`): a section this process
  # changed wins whole. The grammar lives in the `env` section beside the vars and the prefix, so
  # EVERY var edit in the Settings env card rewrites it — and the env section is never reloaded
  # while the TUI runs. A `gori settings env-syntax namespaced` in another terminal was therefore
  # undone by the next `a`/`e`/`d` on that card: the operator's switch reverted with no message,
  # and every editor in the session went back to reading tokens under the grammar they had left.
  #
  # Two halves, and both are needed. The overlay no longer hands its snapshot back on save (the
  # `s` toggle writes `Settings.env_syntax` itself, so the snapshot only ever repeats it or
  # contradicts it), and before any env-section write the TUI re-reads the grammar from the file —
  # unless the TUI itself set it this session, in which case the file is the stale copy and the
  # operator's own keystroke is the answer.
  module EnvSyntaxSeam
    # Has a TUI surface set the grammar in this session (Settings env card `s`, Project ENV pane
    # `s`)? A class-level answer because the two surfaces are different objects and the question is
    # about the PROCESS: once the operator flips it here, a file written before that flip is the
    # stale side of the merge.
    class_property? owned : Bool = false

    # Called by the surfaces that actually flip it, right where they assign `Settings.env_syntax`.
    def self.claim : Nil
      self.owned = true
    end

    # Adopt the FILE's grammar before writing the env section, so a save that is about a var (or
    # about the sigil) carries no opinion about the grammar. A no-op once a TUI surface has
    # claimed it.
    def self.refresh_from_disk : Nil
      return if owned?
      found = disk_syntax
      return unless found
      Settings.env_syntax = found unless found == Settings.env_syntax
    end

    # The grammar as the FILE spells it: an absent key means bare (the absence rule, forever — and
    # `serialize_env` omits the key for exactly that reason), and so does a value this build does
    # not know, which is what `parse_env` concludes for the same bytes.
    #
    # nil means "the file has nothing to say": no file yet (a home whose first save has not landed
    # — its in-memory grammar is the only copy there is) or bytes that will not parse, where
    # `Settings.load` keeps what it has rather than guessing. Read here, in the TUI, rather than
    # through a `Settings` helper, because the reload is a TUI-shaped need: the headless surfaces
    # load, write and exit.
    def self.disk_syntax : Env::Syntax?
      path = Settings.path
      return nil unless File.exists?(path)
      root = JSON.parse(File.read(path)).as_h?
      return nil unless root
      raw = root["env"]?.try(&.as_h?).try(&.["syntax"]?).try(&.as_s?)
      return Settings::DEFAULT_ENV_SYNTAX unless raw
      Env::Syntax.parse?(raw.strip) || Settings::DEFAULT_ENV_SYNTAX
    rescue
      nil
    end
  end
end
