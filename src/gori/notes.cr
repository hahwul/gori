require "json"
require "./store"

module Gori
  # Shared reader/writer for the Notes tab's persisted documents. The TUI
  # `Tui::NotesView` and the headless `gori run notes` CLI both go through here,
  # so the on-disk layout has a single source of truth.
  #
  # Layout: a JSON document set lives in the project settings KV under
  # "notes.docs" — {"cur":Int32, "notes":[String, ...]}. A project written by the
  # pre-multi (single-note) build instead has a plain-text body under the legacy
  # "notes" key; `load` migrates that into a one-note set on read. It never writes
  # the legacy key back (it's left untouched — harmless).
  module Notes
    DOCS_KEY   = "notes.docs" # JSON {"cur":Int32, "notes":[String, ...]}
    LEGACY_KEY = "notes"      # pre-multi single plain-text note

    # A parsed note set: `cur` is the active sub-tab index (0-based), `texts` holds
    # each note's full body in tab order.
    record Doc, cur : Int32, texts : Array(String) do
      def empty? : Bool
        texts.empty?
      end

      def size : Int32
        texts.size
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
        return Doc.new(0, [legacy]) unless legacy.empty?
      end
      Doc.new(0, [] of String)
    end

    # Parse the JSON document set; nil on malformed data so callers can fall back
    # (defensive — the KV value could be hand-edited or written by a future build).
    def self.parse(raw : String) : Doc?
      doc = JSON.parse(raw)
      arr = doc["notes"]?.try(&.as_a?)
      return nil unless arr
      cur = doc["cur"]?.try(&.as_i?) || 0
      Doc.new(cur, arr.map { |v| v.as_s? || "" })
    rescue JSON::ParseException
      nil
    end

    # Serialize a note set back to the "notes.docs" JSON value.
    def self.serialize(cur : Int32, texts : Array(String)) : String
      JSON.build do |j|
        j.object do
          j.field "cur", cur
          j.field "notes" do
            j.array do
              texts.each { |t| j.string(t) }
            end
          end
        end
      end
    end

    # The note's title: its first non-blank line, trimmed; nil when the note is
    # empty/all-whitespace. Mirrors how the TUI derives each sub-tab's label
    # (TextArea#first_nonblank_line over lines split on '\n' with '\r' trimmed),
    # so a CLI listing reads the same titles the editor shows.
    def self.title(text : String) : String?
      text.split('\n').each do |raw|
        line = raw.rstrip('\r')
        return line.strip unless line.blank?
      end
      nil
    end

    # Number of editor lines in a note (split on '\n'); an empty note is one line,
    # matching the TUI's TextArea.
    def self.line_count(text : String) : Int32
      text.split('\n').size
    end
  end
end
