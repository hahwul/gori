require "json"

# FUZZER section: recently-used + favorited wordlist file paths for the Payload
# overlay's wordlist Path field (global scratch/prefs, not project data). See
# settings.cr for the module-level overview and the load/save/serialize orchestration.
module Gori::Settings
  # MRU cap: PathComplete's dropdown only ever shows ~8 rows at a time, so a
  # double-page's worth is plenty without letting the list grow unbounded.
  RECENT_WORDLISTS_CAP = 10

  class_property fuzz_recent_wordlists : Array(String) = [] of String
  class_property fuzz_favorite_wordlists : Array(String) = [] of String

  # Move `path` to the front (deduped), capped. Called once a wordlist payload set
  # is actually applied to the Fuzzer session, not on every keystroke — but that's
  # still once per esc/↵ on an UNCHANGED existing set, so skip the array rebuild +
  # disk save entirely when `path` is already the most-recent entry (a no-op).
  def self.record_recent_wordlist(path : String) : Nil
    p = path.strip
    return if p.empty? || fuzz_recent_wordlists.first? == p
    self.fuzz_recent_wordlists = ([p] + fuzz_recent_wordlists.reject { |e| e == p }).first(RECENT_WORDLISTS_CAP)
    save
  end

  # Add/remove `path` from favorites. Returns the NEW favorite state so the caller
  # (the Path field's ★ indicator) can reflect it without a second lookup.
  def self.toggle_favorite_wordlist(path : String) : Bool
    p = path.strip
    return false if p.empty?
    now_favorite = !fuzz_favorite_wordlists.includes?(p)
    self.fuzz_favorite_wordlists = now_favorite ? [p] + fuzz_favorite_wordlists : fuzz_favorite_wordlists.reject { |e| e == p }
    save
    now_favorite
  end

  def self.favorite_wordlist?(path : String) : Bool
    fuzz_favorite_wordlists.includes?(path.strip)
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
