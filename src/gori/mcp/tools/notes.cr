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
            # The current note's ID, not `Doc#cur`'s 0-based INDEX, which is what this used to
            # publish under the name `cur`. Every other number in this payload is an id, and
            # `get_note`/`update_note`/`delete_note` are id-addressed, so an index sitting there
            # reads as one: on the demo project it was `{"cur":4}` while the current note was
            # `id:5` — and `id:4` exists and is a different note. The CLI twin
            # (`gori run notes --format json`) names its `id` and its (1-based) `index` on every
            # row rather than leaving one bare number to be read either way.
            # nil when `cur` addresses no note: `Notes.parse` accepts `{"cur":0,"notes":[]}`.
            j.field "current_id", doc.notes[doc.cur]?.try(&.id)
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

      # `Notes.create`, not load → serialize → `set_setting`: the note set is ONE settings row
      # holding the whole document, so an append done as two statements commits a document
      # built before a peer's row landed and DELETES it. Two `gori mcp` processes against one
      # project kept 103 of 200 notes that way, every call answering `isError:false`.
      # `Notes.create` runs the read and the write inside one `BEGIN IMMEDIATE` (see
      # `Store#mutate_setting`), and mints the id from the set the transaction read — so two
      # concurrent creates get two ids and both notes survive.
      private def create_note(h) : Result
        text = str(h, "text") || ""
        new_id = Notes.create(store, text)
        return busy("note NOT saved (store busy or unwritable); nothing was persisted") unless new_id

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

        # The id is looked up INSIDE the write transaction — see `create_note`. That is also
        # what makes `Missing` trustworthy: it is "not in the set this write is amending",
        # not "not in a copy we read some milliseconds ago".
        case Notes.update(store, id, text)
        when .missing?
          return not_found("no note with id #{id}")
        when .busy?
          return busy("note NOT updated (store busy or unwritable); it is unchanged")
        end

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

        case Notes.delete(store, id)
        when .missing?
          return not_found("no note with id #{id}")
        when .busy?
          return busy("note NOT deleted (store busy or unwritable); it is unchanged")
        end

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
        tool j, "list_notes",
          "List all project notes (markdown/text documents) with metadata like title and line " \
          "count. `current_id` is the id of the open note (null when there is none); every " \
          "row's `current` says the same thing per note." { }

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
