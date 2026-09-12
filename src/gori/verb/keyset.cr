module Gori
  module Verb
    # EDITOR KEYSETS — a named bundle of key overrides for the small, fixed set of verbs a
    # text-editor pane owns. Exactly the mechanism `OsProfile::OVERRIDES` is, one layer up:
    # a table of verb-id → replacement chords, applied in `Keymap.effective_chords`.
    #
    # It is a MAPPING, not an emulation. gori's editors are modal (READ ↔ INS) and their
    # READ grammar is helix-shaped — `x` selects the line, then `y` copies the selection —
    # which is a real, coherent grammar that a vim-trained hand fights on exactly that one
    # gesture. A keyset moves the keys. It does not add an operator-pending grammar, a
    # register file, counts, text objects, or any editing operation gori's panes do not
    # already have (`ReadPane` is a caret, a selection and a copy). Naming keys for
    # operations that do not exist is how "vim mode" becomes a promise the editor breaks.
    #
    # The two-key limits are the honest edge of that. `Chord` is ONE keystroke, so `gg`,
    # `dd` and `yy` cannot be spelled at all; `:`-prefixed commands are out because
    # `Verb::Reserved` keeps `:` for the command line. Each is named in
    # docs/content/guide/hotkeys.md rather than silently approximated.
    #
    # PRECEDENCE, which is the whole contract: **user rebind > keyset > OS profile >
    # the verb's declared chords** (`Keymap.effective_chords`). A keyset is a better
    # DEFAULT, never a ceiling — picking `vim` and then moving one key leaves that key moved.
    module Keyset
      enum Kind
        Helix # today's keys; the table is empty by construction
        Vim
      end

      # Every verb that binds a bare `x` = "select the line/row" by default. Listed rather
      # than derived because a keyset table is static data (OsProfile::OVERRIDES' shape), and
      # kept honest by `spec/verb/keyset_spec.cr`, which fails if the registry grows a
      # select-line verb this list does not carry.
      #
      # `intercept.select-line` is deliberately absent: it is KEYLESS by design (verbs/
      # read_edit.cr — the Intercept queue spends nearly every letter, so that pane reaches
      # select-line from the space menu). A keyset respells keys; it does not hand a key to a
      # pane whose author decided against one.
      SELECT_LINE_IDS = %w[
        notes.select-line repeater.select-line decoder.select-line fuzzer.select-line
        jwt.select-line cookie.select-line issue.select-line project.select-line
        rewriter.select-line comparer.select-line oast.select-line probe.select-line
        sequence.select-line mine.select-line detail.select-line
      ]

      # `helix` IS today's keys, so its table is empty — the default keyset must be a no-op,
      # or "the default" and "what the verb files declare" would be two different things to
      # keep in step.
      HELIX = Hash(String, Array(Chord)).new

      # The `vim` table. Every row respells a verb that already exists:
      #   • SELECT LINE `x` → `⇧V`. The one gesture that actually trips a vim hand, and the
      #     reason this feature exists. `V` is free in all fifteen scopes (only Scope::Diff
      #     binds it, and Diff has no select-line); `validate_chords!` sweeps every keyset on
      #     every OS profile at boot, so a future clash is a startup failure, not a shadow.
      #   • COPY stays `y`. It is already vim's letter, and `yy` is a chord SEQUENCE the
      #     keymap cannot express — but `y` with no selection already copies the whole pane,
      #     which is the useful half of what `yy` would mean.
      #   • UNDO `^Z` → `u`. `^Z` keeps undoing inside INSERT either way: the nine editor
      #     ladders claim it upstream of the keymap (Hotkeys' CLAIMED_CTRL_LETTERS), which is
      #     where a typing hand wants it.
      #   • FIND `^F` → `/`. Free in an editor pane — the `/` filter bars all live on LIST
      #     scopes, which are never on the Editor chain. `^F` still opens the prompt from the
      #     Runner's guard, INSERT included.
      #   • INSERT `i` and BACK-TO-READ `esc` need no row: gori already spells them that way.
      #   • APPEND `a` and TOP/BOTTOM `g` / `⇧G` give a key to three verbs `helix` leaves
      #     unbound. Both halves of append (one column right, then INSERT) are motions the
      #     editors have; `gg` is not expressible, so `g` alone is the top.
      #
      # No DELETE row. There is no delete-line in a READ-mode pane to bind — `dd` would have
      # to be implemented, not respelled, and this is not the change that adds editing
      # operations. No GOTO-LINE row either: vim spells it `:N`, and `:` is reserved for the
      # command line, so `^G` stands in both keysets.
      VIM = begin
        t = Hash(String, Array(Chord)).new
        SELECT_LINE_IDS.each { |id| t[id] = [Chord.new("v", shift: true)] }
        t["editor.undo"] = [Chord.new("u")]
        t["editor.find"] = [Chord.new("/")]
        t["editor.append"] = [Chord.new("a")]
        t["editor.top"] = [Chord.new("g")]
        t["editor.bottom"] = [Chord.new("g", shift: true)]
        t
      end

      OVERRIDES = {
        Kind::Helix => HELIX,
        Kind::Vim   => VIM,
      }

      DEFAULT = Kind::Helix

      def self.overrides_for(kind : Kind) : Hash(String, Array(Chord))
        OVERRIDES[kind]
      end

      # Settings string → Kind; anything unknown (a hand-edited config, a keyset from a newer
      # build) falls back to the default rather than to an empty keymap.
      def self.resolve(setting : String) : Kind
        case setting
        when "vim"   then Kind::Vim
        when "helix" then Kind::Helix
        else              DEFAULT
        end
      end

      # The persisted names, in the order settings:keys cycles them.
      NAMES = %w[helix vim]

      def self.name_of(kind : Kind) : String
        kind.vim? ? "vim" : "helix"
      end

      def self.active : Kind
        resolve(Gori::Settings.editor_keyset)
      end
    end
  end
end
