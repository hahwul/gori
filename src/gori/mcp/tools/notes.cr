require "json"
require "../../notes"
require "../../issues_export" # Issues::Export.one_line / .scrub_only

module Gori
  module MCP
    class Tools
      private def list_notes : Result
        doc = Notes.load(store)
        Result.new(JSON.build do |j|
          j.object do
            j.field "cur", doc.cur
            j.field "notes" do
              j.array do
                doc.notes.each_with_index do |entry, idx|
                  j.object do
                    j.field "id", entry.id
                    j.field "title", note_title(entry)
                    j.field "line_count", Notes.line_count(entry.text)
                    j.field "current", doc.cur == idx
                  end
                end
              end
            end
          end
        end)
      end

      private def get_note(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        doc = Notes.load(store)
        entry = doc.notes.find { |n| n.id == id }
        return not_found("no note with id #{id}") unless entry
        idx = doc.notes.index(entry).not_nil!
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", entry.id
            # A note body does NOT always originate inside gori: `gori run notes create` takes
            # it from --text, positional args, or STDIN — and its own banner suggests
            # `some-tool | gori run notes create`, so piping a gzip/binary response body (or a
            # file the external $EDITOR wrote) stores raw non-UTF-8 bytes, which the settings KV
            # round-trips verbatim. Unscrubbed, that byte reached JSON::Builder and broke this
            # tool's whole JSON-RPC line. See `Serialize.text`'s contract; `scrub_only` (not
            # `one_line`) because a note is multi-line BY DESIGN, the same split
            # `Serialize.issue` makes for an issue's free-text `notes`.
            j.field "text", Issues::Export.scrub_only(entry.text)
            j.field "title", note_title(entry)
            j.field "current", doc.cur == idx
          end
        end)
      end

      private def create_note(h) : Result
        text = str(h, "text") || ""
        doc = Notes.load(store)
        new_id = doc.next_id
        new_entry = Notes::NoteEntry.new(new_id, text)
        new_notes = doc.notes + [new_entry]
        new_cur = new_notes.size - 1
        new_next_id = new_id + 1

        serialized = Notes.serialize(new_cur, new_notes, new_next_id)
        return busy("note NOT saved (store busy or unwritable); nothing was persisted") unless store.set_setting(Notes::DOCS_KEY, serialized)

        Result.new(JSON.build do |j|
          j.object do
            j.field "id", new_id
            j.field "message", "Note created successfully"
          end
        end)
      end

      private def update_note(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        text = str(h, "text")
        return Result.new("missing 'text' parameter", is_error: true) unless text

        doc = Notes.load(store)
        entry_idx = doc.notes.index { |n| n.id == id }
        return not_found("no note with id #{id}") unless entry_idx

        updated_entry = Notes::NoteEntry.new(id, text)
        new_notes = doc.notes.dup
        new_notes[entry_idx] = updated_entry

        serialized = Notes.serialize(doc.cur, new_notes, doc.next_id)
        return busy("note NOT updated (store busy or unwritable); it is unchanged") unless store.set_setting(Notes::DOCS_KEY, serialized)

        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "message", "Note updated successfully"
          end
        end)
      end

      private def delete_note(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id

        doc = Notes.load(store)
        entry_idx = doc.notes.index { |n| n.id == id }
        return not_found("no note with id #{id}") unless entry_idx

        new_notes = doc.notes.dup
        new_notes.delete_at(entry_idx)
        new_cur = doc.cur.clamp(0, {new_notes.size - 1, 0}.max)

        serialized = Notes.serialize(new_cur, new_notes, doc.next_id)
        return busy("note NOT deleted (store busy or unwritable); it is unchanged") unless store.set_setting(Notes::DOCS_KEY, serialized)

        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "message", "Note deleted successfully"
          end
        end)
      end

      # The note's display title, scrubbed for the JSON-RPC wire. `one_line` rather than
      # `scrub_only`: `Notes.title` returns the first non-blank LINE, so it is a single-line
      # field here exactly as an issue's `title` is — and a lone CR or a stray C0 inside that
      # line would otherwise ride out into a field a client renders inline.
      private def note_title(entry : Notes::NoteEntry) : String
        Issues::Export.one_line(Notes.title(entry.text) || "").presence || "Untitled"
      end

      # The tools/list schemas for the note tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_notes_tools(j : JSON::Builder) : Nil
        tool j, "list_notes", "List all project notes (markdown/text documents) with metadata like title and line count." { }

        tool j, "get_note", "Get the full text and metadata of a specific note by its database ID." do |s|
          s.field "id", intprop("database note ID"), required: true
        end

        return unless @allow_actions

        tool j, "create_note", "Create a new note with optional text content." do |s|
          s.field "text", strprop("initial text content for the new note")
        end

        tool j, "update_note", "Update the text content of an existing note by its database ID." do |s|
          s.field "id", intprop("database note ID to update"), required: true
          s.field "text", strprop("new text content for the note"), required: true
        end

        tool j, "delete_note", "Delete a note by its database ID." do |s|
          s.field "id", intprop("database note ID to delete"), required: true
        end
      end
    end
  end
end
