require "json"
require "./store"
require "./issues_export" # Issues::Export.scrub_controls — the shared terminal-safety helper

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

      # Note bodies in tab order, sanitized for terminal display — this is the CLI listing
      # accessor (`gori run notes` prints these straight to STDOUT). Control characters a TTY
      # would treat as escape sequences (ESC/BEL/OSC/CSI, other C0/C1) are stripped while
      # newlines/tabs are preserved, so a note body carrying an OSC "set window title" /
      # clipboard-write can't drive the terminal. The stored NoteEntry text is left untouched,
      # so persistence and TUI editing still see the raw bytes.
      def texts : Array(String)
        notes.map { |n| Issues::Export.scrub_controls(n.text) }
      end

      # The stable id at sub-tab position `idx`, or nil when there is no such position.
      # The explicit `idx < 0` guard is not belt-and-braces: Crystal's `Array#[]?` counts a
      # NEGATIVE index from the END, so a bare `notes[-1]?` answers "the last note" for a
      # caller that meant "the slot before the first one" — and every caller here is walking
      # neighbours around a position it is about to remove.
      def note_id(idx : Int32) : Int64?
        return nil if idx < 0
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

    # A document build from the two raw rows `load` reads, with the same legacy fallback.
    # Split out of `load` so the TRANSACTIONAL mutators below can rebuild the doc from the
    # blob the store handed them inside the write transaction (see `Store#mutate_setting`)
    # rather than from a second, racy read.
    def self.doc_from(raw : String?, legacy : String?) : Doc
      if raw && (doc = parse(raw))
        return doc
      end
      if legacy && !legacy.empty?
        return Doc.new(0, [NoteEntry.new(1_i64, legacy)], 2_i64)
      end
      Doc.new(0, [] of NoteEntry, 1_i64)
    end

    # What a transactional mutation did. Three outcomes, and the middle one is why this is
    # not a Bool: "no note with that id" is a DETERMINISTIC refusal the caller must report as
    # such, while `Busy` is transient and retryable (an agent that retries the first loops
    # forever, the split `SessionSlots` documents for the same reason).
    enum Write
      Committed
      Missing
      Busy
    end

    # ── transactional mutators ────────────────────────────────────────────────
    #
    # The note set is ONE settings row holding the whole document, so every edit is a
    # read-modify-write. Done as two statements it loses a peer's notes: both processes read
    # the same set, both append one note, both commit — and the second commit's document
    # never contained the first's row. MEASURED at 103 of 200 surviving across two `gori mcp`
    # processes, every call reporting success. `Store#mutate_setting` puts the read and the
    # write inside one `BEGIN IMMEDIATE`, which is the whole fix; these four wrappers are what
    # make the surfaces use it.
    #
    # The blocks below run on the writer fiber and touch nothing but their arguments — see
    # `Store#mutate_setting` for that contract. `legacy` is read BEFORE the transaction on
    # purpose: gori never WRITES the legacy key, so its value cannot move under us, and
    # reading it from inside the block would need a second statement on the writer's
    # connection for a row that is absent in every project written this decade.

    # Append one note and return its id, or nil when the store did not commit. The id is
    # minted from the set as it exists INSIDE the transaction, so two processes appending at
    # once get two different ids and both notes survive.
    def self.create(store : Store, text : String) : Int64?
      legacy = store.setting(LEGACY_KEY)
      created = nil.as(Int64?)
      committed = store.mutate_setting(DOCS_KEY) do |raw|
        doc = doc_from(raw, legacy)
        id = doc.next_id
        notes = doc.notes + [NoteEntry.new(id, text)]
        created = id
        serialize(notes.size - 1, notes, id + 1)
      end
      committed ? created : nil
    end

    # Replace one note's text. `Missing` when the id is not in the set the transaction read —
    # which is the authoritative one, so a note a peer deleted a moment ago reports Missing
    # rather than being silently resurrected by our stale copy.
    def self.update(store : Store, id : Int64, text : String) : Write
      legacy = store.setting(LEGACY_KEY)
      found = false
      committed = store.mutate_setting(DOCS_KEY) do |raw|
        doc = doc_from(raw, legacy)
        idx = doc.notes.index { |n| n.id == id }
        if idx
          found = true
          notes = doc.notes.dup
          notes[idx] = NoteEntry.new(id, text)
          serialize(doc.cur, notes, doc.next_id)
        end
      end
      return Write::Busy unless committed
      found ? Write::Committed : Write::Missing
    end

    # Drop one note. `cur` is re-clamped against the set the transaction read, not ours.
    def self.delete(store : Store, id : Int64) : Write
      legacy = store.setting(LEGACY_KEY)
      found = false
      committed = store.mutate_setting(DOCS_KEY) do |raw|
        doc = doc_from(raw, legacy)
        idx = doc.notes.index { |n| n.id == id }
        if idx
          found = true
          notes = doc.notes.dup
          notes.delete_at(idx)
          serialize(doc.cur.clamp(0, {notes.size - 1, 0}.max), notes, doc.next_id)
        end
      end
      return Write::Busy unless committed
      found ? Write::Committed : Write::Missing
    end

    # `merge` applied to the persisted set INSIDE the write transaction, for the two surfaces
    # that hold a whole session's worth of notes (the TUI's Notes tab, `gori run notes`).
    # Returns the merged document as committed, or nil when the store did not commit.
    #
    # This is the same reconciliation those surfaces already do; what changes is WHERE the
    # `persisted` argument comes from. Re-reading it just before `set_setting` — which is
    # what they do today — still merges against a set a peer can replace between the read and
    # the write, and the merge's whole promise is that a peer's note is kept.
    def self.save(store : Store, mine : Array(NoteEntry), deleted : Set(Int64),
                  cur_id : Int64?, next_id : Int64) : Doc?
      legacy = store.setting(LEGACY_KEY)
      merged = nil.as(Doc?)
      committed = store.mutate_setting(DOCS_KEY) do |raw|
        doc = merge(doc_from(raw, legacy), mine, deleted, cur_id, next_id)
        merged = doc
        serialize(doc.cur, doc.notes, doc.next_id)
      end
      committed ? merged : nil
    end

    # Parse the JSON document set; nil on malformed data so callers can fall back.
    def self.parse(raw : String) : Doc?
      # Read the root through `as_h?` rather than indexing the JSON::Any directly:
      # `JSON::Any#[]?` RAISES a bare Exception ("Expected Hash for #[]?") when the
      # root is valid JSON that is not an object (`[]`, `42`, `null`), which the
      # `JSON::ParseException` rescue below does not catch. A corrupt or externally
      # written "notes.docs" row would then escape as a backtrace out of `gori run
      # notes`, and re-raise every TUI tick until the tick-error breaker exits.
      doc = JSON.parse(raw).as_h?
      return nil unless doc
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
    #
    # The active note arrives as `cur_id`, a STABLE ID, not as an index. The merged order is
    # the persisted one (minus this session's deletes) with this session's new notes appended,
    # which is NOT the caller's own list order — so an index meant "my note #2" and landed on
    # whatever the merge happened to put there. Two ways that bit: a peer adding a note ahead
    # of ours parked the persisted `cur` on the PEER's note instead of the one being typed in,
    # and `gori run notes delete 1` left `cur` on its old number, i.e. one note further down
    # than the one that was active. An id cannot drift. Unresolvable (a peer deleted it) → 0.
    def self.merge(persisted : Doc, mine : Array(NoteEntry), deleted : Set(Int64),
                   cur_id : Int64?, next_id : Int64) : Doc
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
      cur = cur_id.try { |id| result.index { |n| n.id == id } } || 0
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

    FILENAME_MAX_CHARS = 48

    # A filesystem-safe basename for "export this note", derived from its title the same
    # way the sub-tab label is.
    #
    # UNICODE IS PRESERVED — a Korean/CJK title stays legible in the filename. Neither of
    # the codebase's other name-manglers fits: ProjectRegistry#slugify must emit an ASCII
    # *directory* slug and so hashes a non-ASCII name to project-<sha256>, and Runner's
    # title_safe caps at 40 with a '…' that has no business in a filename. Only bytes a
    # path cannot carry are replaced here.
    #
    # `index` is the sub-tab position behind the "note N" fallback, matching
    # NotesView::Note#label, so an untitled note exports as note-3.md and never as a bare
    # ".md". Path separators are replaced BEFORE the strip, so a title like "../../etc/passwd"
    # can only ever yield "etc-passwd.md".
    #
    # The cap is in CHARACTERS, not bytes: 48 × 4 bytes worst case plus ".md" is still far
    # under the 255-byte limit every filesystem gori runs on enforces.
    def self.export_basename(text : String, index : Int32) : String
      raw = (title(text) || "").scrub
      safe = raw.gsub { |c| c.control? ? ' ' : c } # NUL/ESC/BEL/CR can never reach a filename
        .gsub(/[\/\\:*?"<>|]+/, "-")               # path separators + the Windows-hostile set
        .gsub(/\s+/, "-")
        .gsub(/-+/, "-")
        .strip("-. \t") # "." / ".." / a leading dot (hidden) / a trailing dot cannot survive
      safe = safe[0, FILENAME_MAX_CHARS].strip("-. ") if safe.size > FILENAME_MAX_CHARS
      safe = "note-#{index + 1}" if safe.empty?
      "#{safe}.md"
    end
  end
end
