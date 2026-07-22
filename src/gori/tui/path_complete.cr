require "./screen"
require "./theme"
require "../fuzzy"
require "../paths"
require "../settings"

module Gori::Tui
  # Inline filesystem path completion for the wordlist payload field. Mirrors the
  # Decoder tab's ChainComplete (scroll-window dropdown) but with path-aware accept:
  # it keeps the typed directory prefix, replaces only the basename, and appends "/"
  # to directories so the user can keep drilling. Bare names (no "/") complete from
  # BOTH the current working dir and ~/.gori/wordlists. Per-directory child caching
  # keeps steady-state keystrokes off the filesystem.
  class PathComplete
    CAP = 60

    # `header` rows (section labels "★ Favorites" / "🕒 Recent") are unselectable —
    # `move` steps over them and `refresh`/`accept` never land the cursor on one.
    record Entry, label : String, insert : String, dir : Bool, header : Bool = false

    getter? open : Bool = false
    getter entries : Array(Entry) = [] of Entry
    getter selected : Int32 = 0
    @scroll = 0
    @cache = {} of String => Array(String) # dir → sorted children

    # PathComplete is shared by every path-picking field in the TUI (the Fuzzer
    # wordlist Path, the Import overlay's source path, the CA Import cert/key
    # paths, …). The recent/favorite view is Fuzzer-wordlist-specific data
    # (Gori::Settings.fuzz_recent_wordlists/fuzz_favorite_wordlists), so it must
    # opt in per instance — defaulting it on would leak wordlist history into
    # every other overlay's blank-field dropdown.
    def initialize(@wordlist_history : Bool = false)
    end

    def refresh(value : String) : Nil
      @entries = candidates(value)
      @selected = @entries.index { |e| !e.header } || 0
      @scroll = 0
      @open = @entries.any? { |e| !e.header }
    end

    # Steps by `d`, skipping header rows; a no-op if there's no selectable row
    # further in that direction (mirrors the plain clamp's edge no-op).
    def move(d : Int32) : Nil
      return if @entries.empty?
      i = @selected
      loop do
        i += d
        return if i < 0 || i >= @entries.size
        break unless @entries[i].header
      end
      @selected = i
    end

    def close : Nil
      @open = false
    end

    # The chosen insert string + whether it is a directory (the caller keeps the
    # popup open + refreshes on a dir, closes on a file). nil when nothing selectable.
    def accept : {String, Bool}?
      e = @entries[@selected]? || return nil
      return nil if e.header
      {e.insert, e.dir}
    end

    # Blank Path field → the user's own recent/favorited wordlist picks (no cwd
    # noise); typing anything at all falls through to the usual fuzzy directory
    # search below. Favorites first, then recents (a path already favorited isn't
    # repeated under Recent). A user with no history yet (or a fresh install)
    # still gets the original cwd + ~/.gori/wordlists listing — recent/favorite
    # is additive, not a replacement for that discovery path.
    private def candidates(value : String) : Array(Entry)
      if value.empty? && @wordlist_history
        rf = recent_and_favorite_entries
        return rf unless rf.empty?
      end
      if slash = value.rindex('/')
        prefix = value[0..slash] # kept verbatim, incl. trailing '/'
        partial = value[(slash + 1)..]
        read_dir = Path[prefix].expand(home: true).to_s
        merged = ranked(read_dir, partial).map do |name, is_dir, rank|
          {Entry.new(name, "#{prefix}#{name}#{is_dir ? "/" : ""}", is_dir), rank}
        end
        merge_cap(merged)
      else
        # bare name → cwd (bare insert) + ~/.gori/wordlists (ABSOLUTE insert: the
        # engine opens wordlist paths relative to CWD, so a wordlists-dir-only name
        # MUST resolve absolutely or it would fail at run time). Both sources are
        # ranked TOGETHER so a prefix/wordlist hit isn't buried under cwd fuzz.
        wl = Gori::Paths.wordlists_dir
        merged = ranked(Dir.current, value).map do |name, is_dir, rank|
          {Entry.new(name, "#{name}#{is_dir ? "/" : ""}", is_dir), rank}
        end
        ranked(wl, value).each do |name, is_dir, rank|
          merged << {Entry.new("#{name}  ·~/.gori", "#{File.join(wl, name)}#{is_dir ? "/" : ""}", is_dir), rank}
        end
        merge_cap(merged)
      end
    end

    private def recent_and_favorite_entries : Array(Entry)
      favs = Gori::Settings.fuzz_favorite_wordlists
      recents = Gori::Settings.fuzz_recent_wordlists.reject { |p| favs.includes?(p) }
      entries = [] of Entry
      unless favs.empty?
        entries << Entry.new("★ Favorites", "", false, header: true)
        favs.first(CAP).each { |p| entries << history_entry(p) }
      end
      unless recents.empty?
        entries << Entry.new("🕒 Recent", "", false, header: true)
        recents.first(CAP).each { |p| entries << history_entry(p) }
      end
      entries
    end

    # A history (recent/favorite) pick's dir-ness must be checked against the
    # filesystem — unlike the fuzzy-search entries below, these paths didn't just
    # come from listing a directory, so accept()'s close-vs-keep-drilling
    # semantics would silently pick the wrong one otherwise.
    private def history_entry(p : String) : Entry
      dir = File.directory?(p)
      Entry.new(p, "#{p}#{dir ? "/" : ""}", dir)
    end

    private def merge_cap(scored : Array({Entry, Int32})) : Array(Entry)
      scored.sort_by! { |(e, rank)| {-rank, e.label} }
      scored.first(CAP).map { |(e, _)| e }
    end

    # Children of `dir` matching `partial` (case-insensitive prefix OR fuzzy),
    # ranked prefix-first then by score then name. Returns [{name, dir?, rank}],
    # capped; only the survivors are stat'd for directory-ness.
    private def ranked(dir : String, partial : String) : Array({String, Bool, Int32})
      pl = partial.downcase
      scored = children_of(dir).compact_map do |name|
        dn = name.downcase
        if partial.empty?
          {name, 1}
        elsif dn.starts_with?(pl)
          {name, 1_000_000}
        elsif s = Gori::Fuzzy.score(pl, dn)
          {name, s}
        else
          nil
        end
      end
      scored.sort_by! { |(name, rank)| {-rank, name} }
      scored.first(CAP).map { |(name, rank)| {name, File.directory?(File.join(dir, name)), rank} }
    end

    # Per-directory children cache (bounded): re-read only when a dir is first seen.
    private def children_of(dir : String) : Array(String)
      @cache.clear if @cache.size > 8
      @cache[dir] ||= (Dir.children(dir).sort rescue [] of String)
    end

    # Frame-less dropdown anchored at (x, y), clamped within `inner`. Same scroll +
    # accent-bg selection as ChainComplete.
    def render(screen : Screen, x : Int32, y : Int32, inner : Rect) : Nil
      return if !@open || @entries.empty?
      w = ({@entries.max_of(&.label.size) + 2, 18}.max).clamp(1, {inner.right - x, 1}.max)
      h = {@entries.size, 8, {inner.bottom - y, 1}.max}.min
      return if h <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - h + 1 if @selected >= @scroll + h
      @scroll = @scroll.clamp(0, {@entries.size - h, 0}.max)
      (0...h).each do |i|
        e = @entries[@scroll + i]? || break
        if e.header
          screen.fill(Rect.new(x, y + i, w, 1), Theme.elevated)
          screen.text(x + 1, y + i, e.label, Theme.muted, Theme.elevated, width: {w - 1, 1}.max)
          next
        end
        active = (@scroll + i) == @selected
        bg = active ? Theme.accent_bg : Theme.elevated
        screen.fill(Rect.new(x, y + i, w, 1), bg)
        screen.cell(x, y + i, active ? '▎' : ' ', Theme.accent, bg)
        screen.text(x + 1, y + i, e.label, active ? Theme.text_bright : Theme.text, bg, width: {w - 1, 1}.max)
      end
    end
  end
end
