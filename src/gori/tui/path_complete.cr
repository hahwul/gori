require "./screen"
require "./theme"
require "../fuzzy"
require "../paths"
require "../wordlist_catalog"
require "./fmt"
require "../settings"
require "./viewport"

module Gori::Tui
  # Inline filesystem path completion for the wordlist payload field. Mirrors the
  # Decoder tab's ChainComplete (scroll-window dropdown) but with path-aware accept:
  # it keeps the typed directory prefix, replaces only the basename, and appends "/"
  # to directories so the user can keep drilling. Bare names (no "/") complete from
  # BOTH the current working dir and ~/.gori/wordlists. Per-directory child caching
  # keeps steady-state keystrokes off the filesystem.
  class PathComplete
    CAP = 60

    # `header` rows (section labels "★ Favorites" / "🕒 Recent" / "📚 Wordlists") are unselectable —
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
        # bare name → cwd (bare insert) + ~/.gori/wordlists (the catalog: see `catalog_insert`
        # for what a pick inserts). Both sources are ranked TOGETHER so a prefix/wordlist hit
        # isn't buried under cwd fuzz.
        wl = Gori::Paths.wordlists_dir
        merged = ranked(Dir.current, value).map do |name, is_dir, rank|
          {Entry.new(name, "#{name}#{is_dir ? "/" : ""}", is_dir), rank}
        end
        ranked(wl, value).each do |name, is_dir, rank|
          insert = is_dir ? "#{File.join(wl, name)}/" : catalog_insert(name)
          merged << {Entry.new("#{name}  ·~/.gori", insert, is_dir), rank}
        end
        merge_cap(merged)
      end
    end

    # What picking a list from the GLOBAL catalog puts in the field: its bare name when the
    # engine will resolve that name to this very list, and its absolute path when it would not.
    #
    # It used to be the absolute path always, because the engine opened wordlist paths relative
    # to the working directory and a name that lived only under ~/.gori/wordlists would have
    # failed at run time. `WordlistCatalog.resolve` closed that (#1353), so the name is enough —
    # and it is what the operator would type, what `gori run fuzz -w NAME` takes, and what the
    # recent/favorite lists remember. The one case it is NOT enough is a same-named file in the
    # current directory (a bare name reads the working directory first): there the name would
    # run the wrong list, so the path is inserted instead. `resolve` is the judge, not a copy of
    # its rule.
    private def catalog_insert(name : String) : String
      Gori::WordlistCatalog.resolve(name).source.catalog? ? name : File.join(Gori::Paths.wordlists_dir, name)
    end

    # Favorites, then recents, then the catalog: a blank field is "what do I usually reach for",
    # and the operator's saved lists (`Gori::WordlistCatalog`) are the third answer to it. An
    # entry is shown once under the first heading that claims it, whichever spelling it was
    # stored in (`Settings.canonical_wordlist`).
    private def recent_and_favorite_entries : Array(Entry)
      favs = Gori::Settings.fuzz_favorite_wordlists
      fav_keys = favs.map { |p| Gori::Settings.canonical_wordlist(p) }.to_set
      recents = Gori::Settings.fuzz_recent_wordlists.reject { |p| fav_keys.includes?(Gori::Settings.canonical_wordlist(p)) }
      entries = [] of Entry
      shown = Set(String).new
      favorite_rows = favs.compact_map { |p| history_entry(p) }.select { |e| shown.add?(e.label) }
      unless favorite_rows.empty?
        entries << Entry.new("★ Favorites", "", false, header: true)
        favorite_rows.first(CAP).each { |e| entries << e }
      end
      recent_rows = recents.compact_map { |p| history_entry(p) }.select { |e| shown.add?(e.label) }
      unless recent_rows.empty?
        entries << Entry.new("🕒 Recent", "", false, header: true)
        recent_rows.first(CAP).each { |e| entries << e }
      end
      # Only WITH history: a fresh install with saved lists but no history falls through to the
      # plain cwd + catalog listing (`candidates`), which already shows them.
      entries.concat(catalog_entries(shown)) unless entries.empty?
      entries
    end

    # The catalog's lists under their own heading, minus those already shown above. Labelled
    # with their size — `stat` only, never a read (`WordlistCatalog.list`).
    private def catalog_entries(shown : Set(String)) : Array(Entry)
      rows = Gori::WordlistCatalog.list(CAP).entries.reject { |e| shown.includes?(e.name) }
      return [] of Entry if rows.empty?
      out = [Entry.new("📚 Wordlists (~/.gori)", "", false, header: true)]
      rows.each { |e| out << Entry.new("#{e.name}  #{Fmt.size(e.bytes)}", catalog_insert(e.name), false) }
      out
    end

    # A history (recent/favorite) pick's dir-ness must be checked against the
    # filesystem — unlike the fuzzy-search entries below, these paths didn't just
    # come from listing a directory, so accept()'s close-vs-keep-drilling
    # semantics would silently pick the wrong one otherwise.
    #
    # A list in the catalog is shown, and inserted, by NAME (`catalog_insert`) — including an
    # old entry stored as the absolute path an earlier gori inserted — and is dropped when it
    # no longer exists: those are files gori manages, so a list deleted or renamed by
    # `gori run wordlist` (or by hand) must not linger as a dead favorite. Every other entry is
    # shown exactly as stored, present or not, as it always was.
    private def history_entry(p : String) : Entry?
      name = Gori::Settings.canonical_wordlist(p)
      if name != p || Gori::WordlistCatalog.resolve(name).source.catalog?
        return nil unless Gori::WordlistCatalog.entry(name)
        return Entry.new(name, catalog_insert(name), false)
      end
      dir = dir?(p)
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
        end
      end
      scored.sort_by! { |(name, rank)| {-rank, name} }
      scored.first(CAP).map { |(name, rank)| {name, dir?(File.join(dir, name)), rank} }
    end

    # `File.directory?` raises rather than answering false for a path it cannot stat: on
    # Windows a file another process holds open (`D:\DumpStack.log.tmp` at a drive root)
    # refuses even the attribute read. A dropdown row is not worth a crash.
    private def dir?(path : String) : Bool
      File.directory?(path)
    rescue File::Error
      false
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
      # `@entries` is what the loop below walks (headers included — they are navigable rows).
      @scroll = Viewport.scroll_to_show(@selected, @scroll, h, @entries.size)
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
