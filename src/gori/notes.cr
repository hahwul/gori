require "json"
require "./store"

module Gori
  # Shared reader/writer for the Notes tab's persisted documents. The TUI
  # `Tui::NotesView` and the headless `gori run notes` CLI both go through here,
  # so the on-disk layout has a single source of truth.
  #
  # Layout: a JSON document set lives in the project settings KV under
  # "notes.docs" — {"cur":Int32, "notes":[{"id":Int64,"text":String}, ...],
  # "next_id":Int64}. A project written by the pre-multi (single-note) build instead
  # has a plain-text body under the legacy "notes" key; `load` migrates that into a
  # one-note set on read. It never writes the legacy key back (it's left untouched).
  module Notes
    DOCS_KEY   = "notes.docs" # JSON note set (see above)
    LEGACY_KEY = "notes"      # pre-multi single plain-text note

    # One persisted note document with a stable id (used by entity_links).
    record NoteEntry, id : Int64, text : String

    # A parsed note set: `cur` is the active sub-tab index (0-based).
    record Doc, cur : Int32, notes : Array(NoteEntry), next_id : Int64 do
      def empty? : Bool
        notes.empty?
      end

      def size : Int32
        notes.size
      end

      # Note bodies in tab order (CLI listing).
      def texts : Array(String)
        notes.map(&.text)
      end

      def note_id(idx : Int32) : Int64?
        notes[idx]?.try(&.id)
      end
    end

    # Load the persisted note set, applying the legacy-key fallback. Returns an
    # empty Doc (no texts) when the project has never had a note saved.
    def self.load(store : Store) : Doc
      if raw = store.setting(DOCS_KEY)
        if doc = parse(raw)
          return doc
        end
      end
      if legacy = store.setting(LEGACY_KEY)
        return Doc.new(0, [NoteEntry.new(1_i64, legacy)], 2_i64) unless legacy.empty?
      end
      Doc.new(0, [] of NoteEntry, 1_i64)
    end

    # Parse the JSON document set; nil on malformed data so callers can fall back.
    def self.parse(raw : String) : Doc?
      doc = JSON.parse(raw)
      arr = doc["notes"]?.try(&.as_a?)
      return nil unless arr
      cur = doc["cur"]?.try(&.as_i?) || 0
      next_id = doc["next_id"]?.try(&.as_i64?) || 0_i64
      entries = [] of NoteEntry
      legacy_id = 1_i64
      arr.each do |v|
        if obj = v.as_h?
          id = obj["id"]?.try(&.as_i64?) || legacy_id
          text = obj["text"]?.try(&.as_s?) || ""
          entries << NoteEntry.new(id, text)
          legacy_id = {legacy_id, id + 1}.max
        else
          text = v.as_s? || ""
          entries << NoteEntry.new(legacy_id, text)
          legacy_id += 1
        end
      end
      next_id = {next_id, legacy_id}.max
      Doc.new(cur, entries, next_id)
    rescue JSON::ParseException
      nil
    end

    # Serialize a note set back to the "notes.docs" JSON value.
    def self.serialize(cur : Int32, notes : Array(NoteEntry), next_id : Int64) : String
      JSON.build do |j|
        j.object do
          j.field "cur", cur
          j.field "next_id", next_id
          j.field "notes" do
            j.array do
              notes.each do |n|
                j.object do
                  j.field "id", n.id
                  j.field "text", n.text
                end
              end
            end
          end
        end
      end
    end

    # Reconcile THIS session's notes with the currently-persisted set before a save,
    # so two TUI sessions open on the same project don't clobber each other's notes.
    # `persisted` is re-read at save time; `mine` is this session's notes (id → text);
    # `deleted` is the ids this session closed. Merge rules (per-note last-writer-wins,
    # keyed by the stable id):
    #   - a persisted note THIS session also has  → this session's text (an edit)
    #   - a persisted note only the PEER has      → kept (was silently dropped before)
    #   - a persisted note THIS session deleted   → dropped
    #   - a note only THIS session has (new)      → appended
    # (`mine` carry cross-session-unique ids, so a peer's new note can't be mistaken
    # for an edit of ours.) next_id advances past every surviving id.
    def self.merge(persisted : Doc, mine : Array(NoteEntry), deleted : Set(Int64),
                   cur : Int32, next_id : Int64) : Doc
      mine_by_id = {} of Int64 => String
      mine.each { |n| mine_by_id[n.id] = n.text }
      result = [] of NoteEntry
      seen = Set(Int64).new
      persisted.notes.each do |p|
        next if deleted.includes?(p.id)
        result << NoteEntry.new(p.id, mine_by_id[p.id]? || p.text)
        seen << p.id
      end
      mine.each do |n|
        next if seen.includes?(n.id)
        result << n
        seen << n.id
      end
      max_id = result.max_of?(&.id) || 0_i64
      Doc.new(cur.clamp(0, {result.size - 1, 0}.max), result, {next_id, max_id + 1}.max)
    end

    # The note's title: its first non-blank line, trimmed; nil when the note is
    # empty/all-whitespace. Mirrors how the TUI derives each sub-tab's label.
    def self.title(text : String) : String?
      text.split('\n').each do |raw|
        line = raw.rstrip('\r')
        return line.strip unless line.blank?
      end
      nil
    end

    # Number of editor lines in a note (split on '\n'); an empty note is one line.
    def self.line_count(text : String) : Int32
      text.split('\n').size
    end
  end
end
