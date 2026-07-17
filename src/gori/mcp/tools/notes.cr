require "json"
require "../../notes"

module Gori
  module MCP
    class Tools
      private def list_notes : Result
        doc = Notes.load(@store)
        Result.new(JSON.build do |j|
          j.object do
            j.field "cur", doc.cur
            j.field "notes" do
              j.array do
                doc.notes.each_with_index do |entry, idx|
                  j.object do
                    j.field "id", entry.id
                    j.field "title", Notes.title(entry.text) || "Untitled"
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
        doc = Notes.load(@store)
        entry = doc.notes.find { |n| n.id == id }
        return not_found("no note with id #{id}") unless entry
        idx = doc.notes.index(entry).not_nil!
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", entry.id
            j.field "text", entry.text
            j.field "title", Notes.title(entry.text) || "Untitled"
            j.field "current", doc.cur == idx
          end
        end)
      end

      private def create_note(h) : Result
        text = str(h, "text") || ""
        doc = Notes.load(@store)
        new_id = doc.next_id
        new_entry = Notes::NoteEntry.new(new_id, text)
        new_notes = doc.notes + [new_entry]
        new_cur = new_notes.size - 1
        new_next_id = new_id + 1

        serialized = Notes.serialize(new_cur, new_notes, new_next_id)
        @store.set_setting(Notes::DOCS_KEY, serialized)

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

        doc = Notes.load(@store)
        entry_idx = doc.notes.index { |n| n.id == id }
        return not_found("no note with id #{id}") unless entry_idx

        updated_entry = Notes::NoteEntry.new(id, text)
        new_notes = doc.notes.dup
        new_notes[entry_idx] = updated_entry

        serialized = Notes.serialize(doc.cur, new_notes, doc.next_id)
        @store.set_setting(Notes::DOCS_KEY, serialized)

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

        doc = Notes.load(@store)
        entry_idx = doc.notes.index { |n| n.id == id }
        return not_found("no note with id #{id}") unless entry_idx

        new_notes = doc.notes.dup
        new_notes.delete_at(entry_idx)
        new_cur = doc.cur.clamp(0, {new_notes.size - 1, 0}.max)

        serialized = Notes.serialize(new_cur, new_notes, doc.next_id)
        @store.set_setting(Notes::DOCS_KEY, serialized)

        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "message", "Note deleted successfully"
          end
        end)
      end
    end
  end
end
