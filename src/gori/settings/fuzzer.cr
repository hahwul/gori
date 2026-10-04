require "json"
require "../wordlist_catalog"

# FUZZER section: recently-used + favorited wordlist file paths for the Payload
# overlay's wordlist Path field (global scratch/prefs, not project data). See
# settings.cr for the module-level overview and the load/save/serialize orchestration.
module Gori::Settings
  # MRU cap: PathComplete's dropdown only ever shows ~8 rows at a time, so a
  # double-page's worth is plenty without letting the list grow unbounded.
  RECENT_WORDLISTS_CAP = 10

  class_property fuzz_recent_wordlists : Array(String) = [] of String
  class_property fuzz_favorite_wordlists : Array(String) = [] of String

  # The KEY a wordlist is compared and de-duplicated by (#1353). A list in the global catalog is
  # keyed by NAME — `common.txt`, which every consumer now resolves (`WordlistCatalog.resolve`) —
  # so the absolute path an older gori's completion inserted and the name are one entry.
  # Everything else (a path elsewhere, a name from the working directory, a subdirectory of the
  # catalog) is its own key, exactly as given: this never rewrites one it cannot vouch for.
  # What is STORED is `remembered_wordlist`, which is not always the key.
  def self.canonical_wordlist(path : String) : String
    p = path.strip
    dir = Paths.wordlists_dir
    return p if p == dir || !Paths.within?(p, dir)
    name = p[dir.size..]
    name = name[1..] if Path::SEPARATORS.includes?(name[0]?)
    WordlistCatalog.valid_name?(name) ? name : p
  end

  # The spelling a wordlist is REMEMBERED under: its name, so the recent/favorite lists say what
  # the operator would type and survive a moved `$GORI_HOME` — unless the name would not read
  # the same list from here. A bare name reads the working directory first, so where a file of
  # that name sits beside the catalog's list the completion inserted the PATH, and the set was
  # applied with it; remembering the name would lose that, and the entry would insert the
  # working-directory file next time. There the path is kept, and the completion, which asks
  # `resolve` again when it inserts, still shortens it whenever the name is enough.
  def self.remembered_wordlist(path : String) : String
    p = path.strip
    name = canonical_wordlist(p)
    return p if name == p
    WordlistCatalog.resolve(name).source.cwd? ? p : name
  end

  # Move `path` to the front (deduped), capped. Called once a wordlist payload set is
  # actually applied to the Fuzzer session, not on every keystroke — but that's still once per
  # esc/↵ on an UNCHANGED existing set, so skip the array rebuild + disk save entirely when
  # `path` is already the most-recent entry (a no-op).
  #
  # Compared by `canonical_wordlist` and stored as `remembered_wordlist`, so an entry written as
  # an absolute path into the catalog and the same list picked by name are one entry, not two.
  def self.record_recent_wordlist(path : String) : Nil
    kept = remembered_wordlist(path)
    return if kept.empty? || fuzz_recent_wordlists.first? == kept
    key = canonical_wordlist(kept)
    self.fuzz_recent_wordlists = ([kept] + fuzz_recent_wordlists.reject { |e| canonical_wordlist(e) == key }).first(RECENT_WORDLISTS_CAP)
    save
  end

  # Add/remove `path` from favorites. Returns the NEW favorite state so the caller
  # (the Path field's ★ indicator) can reflect it without a second lookup. A path and the
  # catalog name for the same list are one favorite (`canonical_wordlist`).
  def self.toggle_favorite_wordlist(path : String) : Bool
    kept = remembered_wordlist(path)
    return false if kept.empty?
    key = canonical_wordlist(kept)
    now_favorite = !favorite_wordlist?(kept)
    rest = fuzz_favorite_wordlists.reject { |e| canonical_wordlist(e) == key }
    self.fuzz_favorite_wordlists = now_favorite ? [kept] + rest : rest
    save
    now_favorite
  end

  def self.favorite_wordlist?(path : String) : Bool
    p = canonical_wordlist(path)
    return false if p.empty?
    fuzz_favorite_wordlists.any? { |e| canonical_wordlist(e) == p }
  end

  private def self.parse_fuzzer_prefs(node : JSON::Any?) : Nil
    obj = node.try(&.as_h?)
    return unless obj
    if recent = obj["recent_wordlists"]?.try(&.as_a?)
      self.fuzz_recent_wordlists = recent.compact_map(&.as_s?).map(&.strip).reject(&.empty?).first(RECENT_WORDLISTS_CAP)
    end
    if favs = obj["favorite_wordlists"]?.try(&.as_a?)
      self.fuzz_favorite_wordlists = favs.compact_map(&.as_s?).map(&.strip).reject(&.empty?)
    end
  end

  # Factory reset for this section (dispatched by Settings.reset_to_factory).
  private def self.reset_fuzzer : Nil
    self.fuzz_recent_wordlists = [] of String
    self.fuzz_favorite_wordlists = [] of String
  end

  # Omit the whole block when there's nothing worth persisting, so an install that
  # never touches the wordlist field never grows a "fuzzer" section.
  private def self.serialize_fuzzer(j : JSON::Builder) : Nil
    return if fuzz_recent_wordlists.empty? && fuzz_favorite_wordlists.empty?
    j.field "fuzzer" do
      j.object do
        unless fuzz_recent_wordlists.empty?
          j.field "recent_wordlists" do
            j.array { fuzz_recent_wordlists.each { |p| j.string p } }
          end
        end
        unless fuzz_favorite_wordlists.empty?
          j.field "favorite_wordlists" do
            j.array { fuzz_favorite_wordlists.each { |p| j.string p } }
          end
        end
      end
    end
  end
end
