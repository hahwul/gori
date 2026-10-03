# `gori run notes` — read the project's notes (list, show one, or --all),
# or write them (create, delete). Notes are addressed by their 1-based list
# position <n> (the same number `notes <n>` and the listing show), not the
# internal stable id.
module Gori
  module CLI
    module Run
      @[Subcommand("notes", help: [
        {"notes [<n>]", "Read or write the project's notes (list, <n>, --all, create)"},
        {"notes update <n>", "Replace (or --append to) the text of the note at list position <n>"},
        {"notes delete <n>", "Delete the note at 1-based list position <n> (needs --yes)"},
      ])]
      private def self.cmd_notes(args : Array(String)) : Nil
        case sub = args.first?
        when "create" then cmd_notes_create(args[1..])
        when "update", "edit", "append"
          cmd_notes_update(args[1..], append: args.first == "append")
        when "delete", "rm" then cmd_notes_delete(args[1..])
        when "list"         then cmd_notes_read(args[1..])
        else
          # `notes` takes a bare `<n>`, so `verb_token?` alone cannot decide: "3" is a verb token
          # but is legitimately DATA. Only a NON-NUMERIC bare word can have been meant as a verb.
          # Without this, `notes remove 2` aborted with "too many arguments (expected at most one
          # note number)" — non-zero, so never the silent no-op class, but it never told the
          # operator that notes has verbs and `remove` is not one, unlike its issues/links siblings.
          if (s = sub) && verb_token?(s) && s.to_i?.nil?
            abort "gori run notes: unknown subcommand '#{s}' (create, update/append, delete/rm, list) — " \
                  "or pass a note number"
          end
          cmd_notes_read(args)
        end
      end

      private def self.cmd_notes_read(args : Array(String)) : Nil
        proj = ProjectFlags.new
        format = :text
        all = false

        positional = parse_args(args, "gori run notes") do |p|
          p.banner = "Usage: gori run notes [<n>] [options]\n\n" \
                     "List the project's notes; with <n> (1-based) print that note in full, " \
                     "or --all to print them all.\n\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run notes create [--text TEXT] [options]\n" \
                     "  gori run notes delete <n> --yes [options]"
          project_options(p, proj, "read")
          p.on("--all", "Print every note in full instead of the one-line list") { all = true }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end

        abort "gori run notes: too many arguments (expected at most one note number)" if positional.size > 1
        index = parse_note_index(positional.first?)
        abort "gori run notes: <n> and --all are mutually exclusive" if index && all

        doc = with_store(resolve_read_project(proj.name, proj.db), read_only: true) do |store|
          Notes.load(store)
        end

        if n = index
          abort "gori run notes: no note ##{n} (this project has #{Gori.plural(doc.size, "note")})" unless n <= doc.size
          show_note(doc, n - 1, format)
        elsif all
          show_all_notes(doc, format)
        else
          list_notes(doc, format)
        end
      end

      private def self.cmd_notes_create(args : Array(String)) : Nil
        proj = ProjectFlags.new
        text : String? = nil
        format = :text

        positional = parse_args(args, "gori run notes create") do |p|
          p.banner = "Usage: gori run notes create [--text TEXT] [options]\n\n" \
                     "Create a note. Body comes from --text, else the positional args,\n" \
                     "else STDIN (e.g. `some-tool | gori run notes create`)."
          project_options(p, proj, "update")
          p.on("--text=TEXT", "Note body (else positional args, else STDIN)") { |v| text = v }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end

        body = text || (positional.empty? ? nil : positional.join(' '))
        body ||= read_stdin_fallback(STDIN, "gori run notes", "note text") unless STDIN.tty?
        abort "gori run notes create: no note text (use --text, positional args, or pipe via STDIN)" if body.nil? || body.empty?

        with_store(resolve_read_project(proj.name, proj.db)) do |store|
          # `Notes.create` — the READ, the merge and the write in one transaction. Reading the
          # set here and writing it back was two statements, and a peer (a TUI on the same
          # project, a `gori mcp`, a second shell) that appended between them had its note
          # erased by our commit while both calls printed success. Minting the id inside the
          # transaction matters just as much: `next_id` read out here is the SAME number the
          # peer read, so two concurrent creates claimed one id and the merge treated the
          # second as an EDIT of the first.
          #
          # `cur` is left on the note just created — `gori run notes create` is the operator
          # saying "this is what I am working on now", the same thing `^N` means in the TUI
          # — which is what `Notes.create` persists.
          new_id = Notes.create(store, body)
          unless new_id
            store.close
            abort "gori run notes create: project is busy (write did not commit) — try again"
          end
          # The position is a DISPLAY figure read back after the commit, so it names the note
          # where it actually landed among a peer's; a peer that deletes it in that instant
          # leaves nothing to number, and the id is then the only honest thing to print.
          puts note_created_output(Notes.load(store), new_id, format, store)
        end
      end

      # `gori run notes update <n>` (#1388) — MCP's `update_note`, addressed by the list position
      # every other `notes` verb takes. `--append` (or the `append` verb) adds to the note
      # instead of replacing it. The text comes from where `notes create` takes it: --text, the
      # positional words after <n>, or a pipe.
      private def self.cmd_notes_update(args : Array(String), *, append : Bool = false) : Nil
        proj = ProjectFlags.new
        text : String? = nil
        format = :text

        positional = parse_args(args, "gori run notes update") do |p|
          p.banner = "Usage: gori run notes update <n> [--append] [--text TEXT | TEXT… ] [options]\n" \
                     "       gori run notes append <n> [--text TEXT | TEXT…] [options]\n\n" \
                     "Replace the text of the note at 1-based list position <n>, or add to it with\n" \
                     "--append. The text comes from --text, else the words after <n>, else STDIN."
          p.on("--append", "Add the text on a new line after the note's current text instead of replacing it") { append = true }
          project_options(p, proj, "update")
          p.on("--text=TEXT", "The text (else the words after <n>, else STDIN)") { |v| text = v }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end

        n = parse_note_index(positional.first?) || abort "gori run notes update: missing <n>"
        body = note_update_text(text, positional[1..])
        store = open_store(resolve_read_project(proj.name, proj.db))
        apply_note_update(store, n, body, append, format)
      end

      # The text for `notes update`: --text, else the words after <n>, else a pipe. An empty
      # replacement would blank the note and an empty append would do nothing — neither is what
      # a script that lost its input meant, so both are refused.
      private def self.note_update_text(text : String?, words : Array(String)) : String
        abort "gori run notes update: pass the text as --text or as words after <n>, not both" if text && !words.empty?
        body = text || (words.empty? ? nil : words.join(' '))
        body ||= read_stdin_fallback(STDIN, "gori run notes", "note text") unless STDIN.tty?
        abort "gori run notes update: no note text (use --text, words after <n>, or pipe via STDIN)" if body.nil? || body.empty?
        body
      end

      private def self.apply_note_update(store : Store, n : Int32, body : String, append : Bool, format : Symbol) : Nil
        doc = Notes.load(store)
        unless n <= doc.size
          store.close
          abort "gori run notes update: no note ##{n} (this project has #{Gori.plural(doc.size, "note")})"
        end
        # By the note's STABLE id, inside the write transaction — see `Notes.update`.
        id = doc.notes[n - 1].id
        case Notes.update(store, id, body, append: append)
        when .busy?
          store.close
          abort "gori run notes update: project is busy (write did not commit) — try again"
        when .missing?
          store.close
          abort "gori run notes update: note ##{n} was deleted before it could be updated"
        end
        after = Notes.load(store)
        idx = after.notes.index { |e| e.id == id }
        if format == :json
          # A peer deleted it between the commit and this read: JSON refuses rather than print a
          # sentence where a script expects an object (`note_created_output`'s rule).
          i = idx || abort_closing(store, "gori run notes update: note ##{n} was updated, but it was gone before it could be read back")
          puts CLI::Output.note_object_json(i, after.notes[i], current: after.cur == i, with_text: true)
        else
          puts "Note ##{(idx || n - 1) + 1} #{append ? "appended to" : "updated"}."
        end
      ensure
        store.close
      end

      # What `notes create` prints, from the set read back after the commit. `--format json`
      # (#1117) is the note's row from `gori run notes --format json` — the listing view, so
      # no `text`: the caller just supplied it — with `id` the stable id and `index` the
      # position the text sentence names. A note a peer deleted in that instant has no row,
      # and where text degrades to the id, JSON refuses rather than print an object whose
      # `index` the listing could never show.
      private def self.note_created_output(doc : Notes::Doc, new_id : Int64, format : Symbol,
                                           store : Store? = nil) : String
        idx = doc.notes.index { |n| n.id == new_id }
        if format == :json
          i = idx || abort_closing(store, "gori run notes create: note (id #{new_id}) was created, but it was gone before it could be read back")
          CLI::Output.note_object_json(i, doc.notes[i], current: doc.cur == i, with_text: false)
        elsif idx
          "Note ##{idx + 1} created."
        else
          "Note created (id #{new_id})."
        end
      end

      # `gori run notes delete <n> --yes` — remove one note by its 1-based list position.
      #
      # `--yes` is required for the reason the rest of the delete family requires it, only more
      # so: a note is prose the operator typed, and unlike a flow or a fuzz run there is no
      # capture or re-run that reproduces it. The TUI already confirms here — `notes.close` puts
      # up a "Its text will be discarded" modal and `notes.clear` another — and headless was the
      # one surface that took the number and ran.
      #
      # MCP is NOT covered by that and this comment does not claim it is: `delete_note` is
      # `gated:`, but the gate is a per-SERVER enable, which is why `clear_history` and
      # `delete_repeaters` each ask for `confirm:true` on top of it. `delete_note` asks for
      # nothing, and closing that is a change to the MCP contract rather than to this file.
      private def self.cmd_notes_delete(args : Array(String)) : Nil
        proj = ProjectFlags.new
        yes = false

        positional = parse_args(args, "gori run notes delete") do |p|
          p.banner = "Usage: gori run notes delete <n> --yes [options]\n\n" \
                     "Delete the note at 1-based list position <n> (as shown by `notes`)."
          p.on("-y", "--yes", "Confirm the deletion (required — there is no interactive prompt here)") { yes = true }
          project_options(p, proj, "update")
        end

        abort "gori run notes delete: missing <n>" if positional.empty?
        abort "gori run notes delete: too many arguments (expected one note number)" if positional.size > 1
        n = parse_note_index(positional.first).not_nil!

        with_store(resolve_read_project(proj.name, proj.db)) do |store|
          persisted = Notes.load(store)
          unless n <= persisted.size
            store.close
            abort "gori run notes delete: no note ##{n} (this project has #{Gori.plural(persisted.size, "note")})"
          end
          target = persisted.notes[n - 1]
          # Gated AFTER the note is resolved, so the refusal can name the text that would go —
          # and after the "no note #n" abort, so a typo'd number still gets the specific answer.
          #
          # NOT free: `open_store` above already migrated the schema and re-spelled the stored
          # env tokens, so a refused invocation is not a no-op on disk. It stays here anyway,
          # because resolving the position on a separate read-only handle and reopening for
          # write would let a peer's insert or delete land between the two — and `n` is a
          # POSITION, so the note this refusal names would no longer be the note the second
          # handle deletes. One handle is what keeps the name honest.
          if err = note_delete_confirmation_error(n, target, yes)
            store.close
            abort "gori run notes delete: #{err}"
          end
          # Delete by the note's STABLE id (not its list position) and merge, so a concurrent
          # writer's other notes aren't clobbered by a blind overwrite. See Notes.merge.
          target_id = target.id
          # Keep the ACTIVE note active across the delete, by id. `persisted.cur` is a
          # position, and removing a note ahead of it slides every later one up — so deleting
          # note 1 while note 3 was active left `cur` on 3, which is now the note that used to
          # be 4. When the active note is the one being deleted, fall to its neighbour (next,
          # else previous), which is what closing a sub-tab does in the TUI.
          keep_id = persisted.note_id(persisted.cur)
          keep_id = persisted.note_id(persisted.cur + 1) || persisted.note_id(persisted.cur - 1) if keep_id == target_id
          # `Notes.save` re-runs that merge against the set the WRITE TRANSACTION reads, so a
          # note a peer added between the load above and this line survives the delete. The
          # two-statement version committed a document built before the peer's row landed and
          # reported success. (`Notes.delete` would be the smaller call but it re-clamps `cur`
          # by POSITION, which is exactly the drift `keep_id` above exists to avoid.)
          merged = Notes.save(store, [] of Notes::NoteEntry, Set{target_id}, keep_id, persisted.next_id)
          unless merged
            store.close
            abort "gori run notes delete: project is busy (write did not commit) — try again"
          end
          puts "Note ##{n} deleted."
        end
      end

      # The refusal `notes delete` owes an operator who did not pass --yes, or nil when they
      # did. Split from the delete itself so a spec can pin the wording — `cmd_notes_delete`
      # ends in `abort`, which a spec cannot drive (the same reason `delete_confirmation_error`
      # is its own method in `history.cr`).
      #
      # The target is NAMED, where `repeater delete`'s gate only counts: a note is addressed by
      # its 1-based LIST POSITION, so `notes delete 2` means a different note once an earlier
      # one is gone, and the first line is the only thing that tells the operator whether the
      # number they typed is the note they meant. A blank note has no first line, and echoing
      # the listing's "note N" fallback here would repeat the number back as if it were a name,
      # so that case says nothing extra.
      #
      # It still REFUSES a blank note, where the TUI's `notes.close` skips its modal for one.
      # That is not drift: the TUI calls a note blank on the buffer the operator is looking at,
      # while this reads the last COMMITTED text, and a peer typing into that note in a TUI or
      # through `update_note` has not committed yet. So the sentence stays true of a blank note
      # too — "cannot be recovered", not "its text exists nowhere else", which would be a claim
      # about text this surface cannot see.
      #
      # Takes the ENTRY, not a title: `Notes.title` splits the whole note body, and the happy
      # `--yes` path must not pay for a string the first line here throws away.
      private def self.note_delete_confirmation_error(n : Int32, entry : Notes::NoteEntry, yes : Bool) : String?
        return nil if yes
        named = Notes.title(entry.text).try { |t| " (#{note_title_for_message(t)})" } || ""
        "refusing to delete note ##{n}#{named} without --yes; positions shift when a note is " \
        "removed, and a deleted note cannot be recovered"
      end

      # A note's first line, fit to print inside a one-line terminal message.
      #
      # Clamped BEFORE it is scrubbed, so the work is proportional to the message rather than
      # to the note: a note body is unbounded (`notes create` reads STDIN) and can be one very
      # long line, and scrubbing all of it to keep 39 characters is a copy of the whole thing.
      #
      # `CLI::Output.term_safe`, NOT `Issues::Export.one_line` — which is what MCP wraps this
      # same title in. The two are not interchangeable here: `one_line` collapses `[[:cntrl:]]`,
      # which is Cc ONLY, while `term_safe` tests Crystal's `Char#control?`, which is Cc AND Cf.
      # Cf is the class that matters for a line a terminal renders — U+202E and the bidi
      # isolates reverse the display without changing a byte, so an operator checking "is this
      # the note I meant" could be shown a name that is not the one that would go. See the same
      # reasoning spelled out at `CLI::Settings.unsafe_char?`.
      #
      # `inspect` last, for the quotes: a first line containing one cannot forge the end of the
      # name. It escapes, so the rendered name can exceed the clamp — the clamp bounds the
      # note's characters, not the printed width.
      private def self.note_title_for_message(title : String) : String
        clamped = title.size > 40 ? "#{title[0, 39]}…" : title
        CLI::Output.term_safe(clamped).inspect
      end

      private def self.parse_note_index(arg : String?) : Int32?
        return nil unless arg
        n = arg.to_i?
        abort "gori run notes: invalid note number '#{arg}' (expected a positive integer)" unless n && n > 0
        n
      end

      # Print one note (`idx` 0-based) in full: its exact text, or a full JSON object.
      private def self.show_note(doc : Notes::Doc, idx : Int32, format : Symbol) : Nil
        entry = doc.notes[idx]
        text = entry.text
        if format == :json
          puts CLI::Output.note_object_json(idx, entry, current: doc.cur == idx, with_text: true)
        else
          STDOUT.puts Issues::Export.scrub_controls(text)
        end
      end

      private def self.show_all_notes(doc : Notes::Doc, format : Symbol) : Nil
        if format == :json
          puts CLI::Output.notes_array_json(doc, with_text: true)
        elsif doc.empty?
          STDERR.puts "no notes"
        else
          doc.texts.each_with_index do |text, i|
            puts "" if i > 0
            puts "=== note #{i + 1}: #{CLI::Output.note_label(i, text)}#{doc.cur == i ? " *" : ""} ==="
            STDOUT.puts Issues::Export.scrub_controls(text)
          end
        end
      end

      private def self.list_notes(doc : Notes::Doc, format : Symbol) : Nil
        if format == :json
          puts CLI::Output.notes_array_json(doc, with_text: false)
        elsif doc.empty?
          STDERR.puts "no notes"
        else
          doc.notes.each_with_index do |entry, i|
            text = Issues::Export.scrub_controls(entry.text)
            puts CLI::Output.note_row_text(i, entry.id, text, current: doc.cur == i)
          end
        end
      end
    end
  end
end
