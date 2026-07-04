require "./screen"
require "./theme"
require "../fuzzy"
require "../paths"

module Gori::Tui
  # Inline filesystem path completion for the wordlist payload field. Mirrors the
  # Convert tab's ChainComplete (scroll-window dropdown) but with path-aware accept:
  # it keeps the typed directory prefix, replaces only the basename, and appends "/"
  # to directories so the user can keep drilling. Bare names (no "/") complete from
  # BOTH the current working dir and ~/.gori/wordlists. Per-directory child caching
  # keeps steady-state keystrokes off the filesystem.
  class PathComplete
    CAP = 60

    record Entry, label : String, insert : String, dir : Bool

    getter? open : Bool = false
    getter entries : Array(Entry) = [] of Entry
    getter selected : Int32 = 0
    @scroll = 0
    @cache = {} of String => Array(String) # dir → sorted children

    def refresh(value : String) : Nil
      @entries = candidates(value)
      @selected = 0
      @scroll = 0
      @open = !@entries.empty?
    end

    def move(d : Int32) : Nil
      return if @entries.empty?
      @selected = (@selected + d).clamp(0, @entries.size - 1)
    end

    def close : Nil
      @open = false
    end

    # The chosen insert string + whether it is a directory (the caller keeps the
    # popup open + refreshes on a dir, closes on a file). nil when nothing selectable.
    def accept : {String, Bool}?
      e = @entries[@selected]? || return nil
      {e.insert, e.dir}
    end

    private def candidates(value : String) : Array(Entry)
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
        active = (@scroll + i) == @selected
        bg = active ? Theme.accent_bg : Theme.elevated
        screen.fill(Rect.new(x, y + i, w, 1), bg)
        screen.cell(x, y + i, active ? '▎' : ' ', Theme.accent, bg)
        screen.text(x + 1, y + i, e.label, active ? Theme.text_bright : Theme.text, bg, width: {w - 1, 1}.max)
      end
    end
  end
end
