# `gori run screenshot` (alias `shot`) — draw the shipping TUI with no terminal attached and
# write the frame out: an SVG or PNG picture, a re-ingestable ANSI dump, or plain text.
#
# The picture is of the REAL chrome over the REAL project. `Tui::Headless.render` boots the
# same Runner `gori` boots, against the same store, and hands back the frame it drew — so a
# screenshot in a bug report or a README is the version that shipped, never a mock that drifts.
#
# What it is NOT is a capture session. `Headless.render` opens the project view-only: no port
# is bound, no capture lock is taken, the active-project pointer is not moved. The visible
# consequence is that the status line's capture chip reads "off" in every headless shot, and
# that is correct rather than a defect — this process never captured anything.
#
# `--from-ansi` is the other producer: a `tmux capture-pane -e -p` dump re-ingested into the
# same `Frame`, which is how a screenshot can be taken of a gori running in ANOTHER terminal
# (or of a session that has already ended). With it there is no project to open, so every flag
# that names or drives one is refused by name rather than silently ignored.
#
# The command is split three ways — `screenshot_parser` collects, `screenshot_refusal` judges,
# `screenshot_emit` acts — so that the ENTIRE refusal ladder is one pure function a spec can
# drive top to bottom. That is also the ordering guarantee this file exists to keep: nothing is
# opened, rendered or written until every "no" has been asked.
require "../../screenshot"
require "../../tui/headless"

module Gori
  module CLI
    module Run
      # The terminal a headless shot pretends to be on, when `--size` says nothing. 132x38 is
      # the shape gori's own docs are captured at: wide enough for the History columns not to
      # fold, tall enough for a pane plus the chrome.
      SCREENSHOT_COLS = 132
      SCREENSHOT_ROWS =  38

      # The largest grid `--size` may ask for. Every cell is a rendered element in the SVG and
      # a rasterized glyph in the PNG, so the cost is the product — a 1000x1000 frame is a
      # million cells, which is already past what any viewer opens happily.
      SCREENSHOT_MAX_DIM = 1000

      # `capture.sh` parity: the SVG geometry gori's own documentation captures at.
      SCREENSHOT_FONT_SIZE = 15.0
      SCREENSHOT_PAD       = 18.0

      # Everything the parser collected, plus the handful of values `screenshot_refusal` DERIVES
      # while it is checking them. A class and not a record for the reason `RedactFlags` is one:
      # OptionParser fills it in from callbacks.
      #
      # The derived fields matter as much as the raw ones. `--size`, `--tab` and `--keys` are
      # each read exactly once, by the function whose job is to refuse them, and what it read is
      # what the render then uses — so there is no second parse to disagree with the first.
      class ScreenshotFlags
        property project : String? = nil
        property db : String? = nil
        property tab : String? = nil
        property keys : String? = nil
        property size : String? = nil
        property theme : String? = nil
        property format : Symbol = :svg
        # `dest` and not `out`: `out` is a Crystal keyword, and a local or property named for it
        # fails to parse at the NEXT definition rather than at its own.
        property dest : String? = nil
        property? force : Bool = false
        property title : String? = nil
        property aria : String? = nil
        property font_size : Float64? = nil
        property pad : Float64? = nil
        property tail : Int32? = nil
        property scale : Int32? = nil
        property font : String? = nil
        property from_ansi : String? = nil
        property redact = RedactFlags.new
        property leftover = [] of String

        # Derived by `screenshot_refusal`.
        property cols : Int32 = SCREENSHOT_COLS
        property rows : Int32 = SCREENSHOT_ROWS
        property tab_sym : Symbol? = nil
        property steps = [] of Tui::KeyScript::Step

        # Whether the operator asked for a shape at all — a different question from what `cols`
        # ended up being, and the one `--from-ansi` consults.
        def sized? : Bool
          !@size.nil?
        end
      end

      @[Subcommand("screenshot", "shot", help: [
        {"screenshot (shot)", "Render the TUI headlessly to SVG / PNG / ANSI / text"},
      ])]
      private def self.cmd_screenshot(args : Array(String)) : Nil
        flags = ScreenshotFlags.new
        screenshot_parser(flags).parse(args)
        # Deferred past `parse` for the reason every sibling gives: the unknown-args callback
        # runs before the flag sweep, so aborting inside it misdiagnoses a typo'd flag.
        unless flags.leftover.empty?
          abort "gori run screenshot: unexpected argument#{flags.leftover.size == 1 ? "" : "s"} " \
                "#{flags.leftover.join(" ").inspect} — every end is named by a flag (--project, --tab, --out)"
        end
        if msg = screenshot_refusal(flags)
          abort msg
        end
        # PNG bytes into a terminal scribble over the operator's screen and can leave it in a
        # state they have to `reset`. Asked here rather than in the pure ladder because it is
        # the one refusal that reads the PROCESS and not the arguments.
        if flags.dest == "-" && flags.format == :png && STDOUT.tty?
          abort "gori run screenshot: refusing to write PNG bytes to a terminal; redirect or pass -o PATH"
        end
        screenshot_emit(flags)
      end

      private def self.screenshot_parser(f : ScreenshotFlags) : OptionParser
        OptionParser.new do |p|
          p.banner = "Usage: gori run screenshot [options]\n\n" \
                     "Draw the TUI with no terminal attached and write the frame out as SVG\n" \
                     "(default), PNG, an ANSI dump, or plain text. The project is opened\n" \
                     "VIEW-ONLY: no port is bound, no capture lock is taken, and the\n" \
                     "active-project pointer is not moved — so the status line's capture chip\n" \
                     "reads `off` in every headless shot, because this process never captured.\n" \
                     "With no -o the picture lands in #{Paths.screenshots_dir}."
          p.on("--project=NAME", "Project to draw (default: most-recently-active)") { |v| f.project = v }
          p.on("--db=PATH", "Explicit SQLite db file to draw") { |v| f.db = v }
          p.on("--tab=NAME", "Tab to open before drawing: #{Tui::Chrome::TABS.map(&.first).join(" | ")}") { |v| f.tab = v }
          p.on("--keys=SCRIPT",
            "Keys to send before drawing, in tmux send-keys grammar " \
            "(`C-p \"acme\" Enter Down Down`, plus SLEEP<secs>). Drives NAVIGATION: a frame is " \
            "a picture of the store as it is now, so anything ASYNC — a Repeater send, a scan — " \
            "is photographed mid-flight, not awaited") { |v| f.keys = v }
          p.on("--size=WxH", "Terminal size to draw at (default #{SCREENSHOT_COLS}x#{SCREENSHOT_ROWS}, max #{SCREENSHOT_MAX_DIM} each)") { |v| f.size = v }
          p.on("--theme=NAME", "Theme to draw in (default: the configured one)") { |v| f.theme = v }
          p.on("--format=FMT", "Output: svg (default) | png | ansi | txt") { |v| f.format = parse_format(v, [:svg, :png, :ansi, :txt]) }
          p.on("-oPATH", "--out=PATH", "Write here instead of #{Paths.screenshots_dir} (`-` = STDOUT)") { |v| f.dest = v }
          p.on("--force", "Overwrite an existing file") { f.force = true }
          p.on("--title=T", "Title for the window bar (default: the frame's own)") { |v| f.title = v }
          p.on("--aria=A", "Spoken label for screen readers (svg only)") { |v| f.aria = v }
          p.on("--font-size=F", "SVG cell font size in px (svg only, default #{SCREENSHOT_FONT_SIZE})") { |v| f.font_size = screenshot_float(v, "--font-size") }
          p.on("--pad=P", "SVG padding in px (svg only, default #{SCREENSHOT_PAD})") { |v| f.pad = screenshot_float(v, "--pad") }
          p.on("--tail=N", "Keep only the last N non-blank rows (an SVG strip has no window chrome)") { |v| f.tail = parse_count(v, "--tail") }
          p.on("--scale=N", "PNG supersample, 1..#{Screenshot::Png::MAX_SCALE} (png only, default 2)") { |v| f.scale = parse_count(v, "--scale") }
          p.on("--font=PATH", "Font file to rasterize glyphs from (png only)") { |v| f.font = v }
          redact_options(p, f.redact)
          # The three rows above are the shared ones, and their wording is about request and
          # response BODIES because that is what every other command they appear on redacts.
          # Here the same profile is painted over the drawn CELLS, and there is no per-value
          # list for `--redact-preview` to print — so the difference is said rather than left
          # for an operator to discover from a refusal.
          p.separator "                                     (here the profile masks the drawn CELLS, " \
                      "and --redact-preview is refused: a frame has no per-value list)"
          p.on("--from-ansi=FILE", "Ingest a `tmux capture-pane -e -p` dump instead of drawing a project (`-` = STDIN)") { |v| f.from_ansi = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| f.leftover = before + after }
          p.invalid_option { |o| abort "gori run screenshot: unknown option: #{o}\n#{p}" }
          p.missing_option { |o| abort "gori run screenshot: missing value for #{o}" }
        end
      end

      # Every "no" this command can say before it opens, renders or writes anything — the whole
      # ladder, in the order an operator meets it, as ONE pure function. Returns the complete
      # sentence to abort with, or nil and a `flags` whose derived fields are filled in.
      #
      # Split out from the command precisely so a spec can walk it: each arm ends in `abort` at
      # the call site, and a spec cannot drive one of those.
      def self.screenshot_refusal(f : ScreenshotFlags) : String?
        if f.redact.preview?
          return "gori run screenshot: --redact-preview has no meaning here — a frame is masked " \
                 "as CELLS, so there is no per-value list to print. Take the shot and read the " \
                 "count this command reports on stderr."
        end
        screenshot_target_refusal(f) || screenshot_shape_refusal(f) || screenshot_render_refusal(f)
      end

      # Which project (or dump) is being drawn, and whether every flag belongs to the format.
      private def self.screenshot_target_refusal(f : ScreenshotFlags) : String?
        if f.from_ansi
          if msg = screenshot_ansi_conflict(f.project, f.db, f.tab, f.keys, f.theme)
            return "gori run screenshot: #{msg}"
          end
        elsif msg = two_targets_error(f.project, f.db, "gori run screenshot")
          # Already a complete sentence — the prefix is one of its arguments.
          return msg
        end
        if msg = screenshot_pairing_error(f.format, aria: f.aria, font_size: f.font_size,
             pad: f.pad, scale: f.scale, font: f.font)
          return "gori run screenshot: #{msg}"
        end
        nil
      end

      # The grid, and the one flag whose RANGE (rather than pairing) the format cares about.
      private def self.screenshot_shape_refusal(f : ScreenshotFlags) : String?
        size = screenshot_size(f.size)
        return "gori run screenshot: #{size}" if size.is_a?(String)
        f.cols, f.rows = size
        scale = f.scale
        return nil unless scale && !(1..Screenshot::Png::MAX_SCALE).includes?(scale)
        "gori run screenshot: --scale #{scale} is out of range (1..#{Screenshot::Png::MAX_SCALE})"
      end

      # What the render itself is asked for: a tab, a theme, a key script. Every one is resolved
      # HERE, before a session exists — `KeyScript.parse`'s whole contract is that a typo in the
      # last key must not first open a project and bind a shelf of process globals.
      private def self.screenshot_render_refusal(f : ScreenshotFlags) : String?
        if v = f.tab
          resolved = screenshot_tab(v)
          return "gori run screenshot: #{resolved}" if resolved.is_a?(String)
          f.tab_sym = resolved
        end
        # Custom themes are files under <GORI_HOME>/themes, so they have to be REGISTERED before
        # `Theme.available` can be asked whether the operator's spelling is one.
        Tui::Theme.load_custom
        if (v = f.theme) && !Tui::Theme.available.includes?(v)
          return "gori run screenshot: no theme named #{v.inspect} (have: #{Tui::Theme.available.join(", ")})"
        end
        return nil unless script = f.keys
        begin
          f.steps = Tui::KeyScript.parse(script)
          nil
        rescue ex : Gori::Error
          "gori run screenshot: --keys: #{ex.message}"
        end
      end

      # Render, serialize, write. Reached only once `screenshot_refusal` has said nothing.
      private def self.screenshot_emit(f : ScreenshotFlags) : Nil
        # `choice` is filled in from inside the render (building a matcher needs the session's
        # store, which does not exist until then) and judged the moment it comes back — before
        # a single byte is serialized, let alone written.
        choice = Redact::Policy::Choice.new
        frame, slug =
          if src = f.from_ansi
            choice = redact_choice(nil, f.redact)
            {screenshot_ingest(f, src, choice),
             Screenshot.slug(src == "-" ? "stdin" : File.basename(src, File.extname(src)))}
          else
            project = resolve_read_project(f.project, f.db)
            drawn = screenshot_draw(f, project) { |store| choice = redact_choice(store, f.redact) }
            {drawn, Screenshot.slug(project.name)}
          end
        abort "gori run screenshot: #{choice.error}" if choice.error
        screenshot_write(f, frame, slug)
        screenshot_notes(frame, choice)
      end

      # A dump, re-ingested. `cols` from `--size` when the operator gave one, else the dump's
      # own longest row: a capture was ALREADY framed by the terminal that drew it, and
      # re-framing it against a width nobody typed shifts every row below the first wide one.
      # Rows are always the dump's line count, which is why `--size`'s H is not consulted here.
      private def self.screenshot_ingest(f : ScreenshotFlags, src : String,
                                         choice : Redact::Policy::Choice) : Screenshot::Frame
        text = read_input_file(src, "gori run screenshot", stdin: true,
          noun: "ANSI dump", flag: "--from-ansi")
        ingested = Screenshot::Frame.from_ansi(text, cols: f.sized? ? f.cols : nil, title: f.title)
        Screenshot::Mask.apply(ingested, choice.matcher)
      end

      # The project, drawn. The block is handed the session's own store so the caller can build
      # (and keep) the redaction `Choice` — `Headless` takes a Proc for exactly that reason: the
      # store does not exist until `render` opens it, and the caller must not be handed one it
      # would then have to remember not to close.
      # The block is CAPTURED (`&resolve`) rather than yielded: it is called from inside the
      # `matcher_for` proc `Headless` takes, and `yield` cannot cross a proc literal.
      private def self.screenshot_draw(f : ScreenshotFlags, project : Project,
                                       &resolve : Store -> Redact::Policy::Choice) : Screenshot::Frame
        Paths.ensure_dirs
        config = Config.new(db_path: project.db_path, ca_dir: Paths.default_ca_dir)
        Tui::Headless.render(project, config,
          Proxy::Tls::CertAuthority.load_or_create(config.ca_dir), Verbs.registry,
          cols: f.cols, rows: f.rows, tab: f.tab_sym, keys: f.steps,
          theme: f.theme, title: f.title,
          matcher_for: ->(store : Store) { resolve.call(store).matcher })
      end

      # The frame as the document it was asked for.
      #
      # `--tail` on the SVG is the renderer's own argument (it drops the window chrome with it,
      # which is what makes a one-pane strip look like a strip); every other format has no
      # chrome to drop, so the frame itself is sliced.
      private def self.screenshot_serialize(f : ScreenshotFlags, frame : Screenshot::Frame) : Bytes
        tail = f.tail
        case f.format
        when :png  then screenshot_png(f, tail ? frame.tail(tail) : frame, tail.nil?)
        when :ansi then Screenshot::Ansi.render(tail ? frame.tail(tail) : frame).to_slice
        when :txt  then Screenshot::Text.render(tail ? frame.tail(tail) : frame).to_slice
        else
          Screenshot::Svg.render(frame, title: frame.title, aria: f.aria,
            font_size: f.font_size || SCREENSHOT_FONT_SIZE,
            pad: f.pad || SCREENSHOT_PAD, tail: tail).to_slice
        end
      end

      # A zero-byte answer is refused rather than written: a 0-byte `.png` is a file an operator
      # has to open to discover is empty, and every later step would treat it as a picture.
      private def self.screenshot_png(f : ScreenshotFlags, frame : Screenshot::Frame,
                                      chrome : Bool) : Bytes
        Screenshot::Font.use(f.font)
        bytes = Screenshot::Png.render(frame, scale: f.scale || 2, title: frame.title, chrome: chrome)
        if bytes.empty?
          abort "gori run screenshot: the PNG renderer produced no bytes — refusing to write " \
                "an empty picture (use --format svg)"
        end
        bytes
      end

      # STDOUT for `-o -`, a file otherwise — and on a file, the PATH on STDOUT so the next
      # command in the pipeline can pick it up.
      private def self.screenshot_write(f : ScreenshotFlags, frame : Screenshot::Frame,
                                        slug : String) : Nil
        payload = screenshot_serialize(f, frame)
        if f.dest == "-"
          STDOUT.write(payload)
          STDOUT.flush
          return
        end
        path = f.dest || begin
          Paths.ensure_dir(Paths.screenshots_dir)
          File.join(Paths.screenshots_dir,
            Screenshot.suggest_filename(slug, f.tab_sym.try(&.to_s), screenshot_ext(f.format), Time.local))
        end
        if msg = screenshot_target_error(path, f.force?)
          abort "gori run screenshot: #{msg}"
        end
        begin
          File.write(path, payload)
        rescue ex : File::Error
          abort "gori run screenshot: cannot write to #{path}: #{ex.message}"
        end
        puts path
      end

      # What a sanitized frame has to SAY, on STDERR — never mixed into the document, the rule
      # `redact_notes` already holds for every other artifact this suite writes.
      #
      # `Frame#sanitized` is a COUNT and not a `Redact::Report`: a mask rewrites cells, and a
      # cell has no field path or rule name to name. So this is its own reporter rather than a
      # caller of `redact_notes` — but it draws the same distinction `Mask` does, between "no
      # profile was applied" (nil, and nothing is said) and "a profile was applied and matched
      # nothing" (0), which is the difference between a picture that was never checked and one
      # that was.
      private def self.screenshot_notes(frame : Screenshot::Frame,
                                        choice : Redact::Policy::Choice,
                                        io : IO = STDERR) : Nil
        n = frame.sanitized || return
        profile = choice.matcher.try(&.profile)
        name = profile ? profile.name.inspect : "the active profile"
        if n > 0
          io.puts "gori run screenshot: SANITIZED (#{n}) with profile #{name}: " \
                  "#{n} value#{n == 1 ? "" : "s"} masked on the rendered frame " \
                  "(the store still holds the captured bytes)"
        else
          io.puts "gori run screenshot: sanitized with profile #{name}: nothing on this frame " \
                  "matched it — the picture is the screen as drawn"
        end
        return if choice.salt_persisted
        io.puts "gori run screenshot: the placeholder salt could not be saved to #{Settings.path}, " \
                "so these tags are consistent within this picture and will NOT match another session's"
      end

      # --- the pure halves, split from the aborts so a spec can drive them ------

      # `--size=WxH` → `{cols, rows}`, or the sentence to refuse with. nil is the default shape.
      #
      # Both ends are refused rather than clamped: a `--size 0x40` is a typo, and silently
      # drawing 132 columns for it produces a picture the operator did not ask for and cannot
      # tell apart from one they did.
      def self.screenshot_size(v : String?) : {Int32, Int32} | String
        return {SCREENSHOT_COLS, SCREENSHOT_ROWS} unless v
        parts = v.downcase.split('x')
        bad = "invalid --size #{v.inspect} (expected WxH, e.g. 132x38)"
        return bad unless parts.size == 2
        w = parts[0].strip.to_i?
        h = parts[1].strip.to_i?
        return bad unless w && h
        return "--size #{v.inspect}: both ends must be at least 1" if w < 1 || h < 1
        if w > SCREENSHOT_MAX_DIM || h > SCREENSHOT_MAX_DIM
          return "--size #{v.inspect} is past the #{SCREENSHOT_MAX_DIM}x#{SCREENSHOT_MAX_DIM} cap"
        end
        {w, h}
      end

      # `--tab=NAME` → the catalog symbol, or the sentence to refuse with.
      #
      # A DIGIT is refused by the same branch as a misspelling and deliberately not read as a
      # tab number: the bar's numbering is the operator's own visible-tab configuration, so
      # `--tab=3` would name a different tab on two machines and the same script would
      # photograph two different panes.
      def self.screenshot_tab(v : String) : Symbol | String
        want = v.strip.downcase
        found = Tui::Chrome::TABS.find { |(sym, _)| sym.to_s == want }
        return found[0] if found
        "no tab named #{v.inspect} (have: #{Tui::Chrome::TABS.map(&.first).join(", ")})"
      end

      # "X only makes sense with --format Y", asked once for every such pairing so the refusal
      # can name BOTH flags. A flag silently ignored because the format did not read it is the
      # failure this exists to prevent: the picture comes out, looks right, and is missing the
      # thing that was asked for.
      def self.screenshot_pairing_error(format : Symbol, *, aria : String?,
                                        font_size : Float64?, pad : Float64?,
                                        scale : Int32?, font : String?) : String?
        if format != :svg
          {"--aria" => !aria.nil?, "--font-size" => !font_size.nil?, "--pad" => !pad.nil?}.each do |flag, given|
            return "#{flag} is an SVG option, and --format #{format} was asked for" if given
          end
        end
        return nil if format == :png
        {"--scale" => !scale.nil?, "--font" => !font.nil?}.each do |flag, given|
          return "#{flag} is a PNG option, and --format #{format} was asked for" if given
        end
        nil
      end

      # `--from-ansi` turns off the project half of this command, so every flag that names or
      # drives a project is refused BY NAME. Ignoring them would be the worse answer twice
      # over: `--tab=history` on a dump would photograph whatever tab the dump already held,
      # and the operator could not tell which of their flags had been read.
      def self.screenshot_ansi_conflict(project_name : String?, db_path : String?,
                                        tab : String?, keys : String?, theme : String?) : String?
        named = [] of String
        named << "--project" if project_name
        named << "--db" if db_path
        named << "--tab" if tab
        named << "--keys" if keys
        named << "--theme" if theme
        return nil if named.empty?
        one = named.size == 1
        "--from-ansi reads a dump that was already drawn, so #{named.join(", ")} " \
        "#{one ? "has" : "have"} nothing to act on — drop #{one ? "it" : "them"}, " \
        "or drop --from-ansi to draw the project instead"
      end

      # The file extension each format writes.
      def self.screenshot_ext(format : Symbol) : String
        format.to_s
      end

      # The default filename, `<slug>-<tab>-<YYYYmmdd-HHMMSS>.<ext>`. Both of these delegate to
      # `Screenshot`: the MCP tool writes into the SAME directory with the same convention, and
      # a second spelling of it would be a drift nobody notices until the folder is sorted.
      def self.screenshot_slug(name : String) : String
        Screenshot.slug(name)
      end

      def self.screenshot_default_name(slug : String, tab : String?, ext : String, at : Time) : String
        Screenshot.suggest_filename(slug, tab, ext, at)
      end

      # Why this path cannot be written, or nil. Checked BEFORE the write and after the render,
      # which is the only order in which "that file already exists" is answerable without
      # having destroyed the answer.
      def self.screenshot_target_error(path : String, force : Bool) : String?
        return "#{path} is a directory" if Dir.exists?(path)
        parent = File.dirname(path)
        return "no such directory: #{parent}" unless Dir.exists?(parent)
        return nil unless File.exists?(path)
        return nil if force
        "#{path} already exists — pass --force to overwrite it, or -o PATH to write elsewhere"
      end

      # A px measurement flag. Its own parser rather than `parse_count`'s: these are genuinely
      # fractional (a 13.5px cell is a legal capture), and they must be positive and finite or
      # the SVG geometry comes out as `NaN` in an attribute no viewer reports on.
      private def self.screenshot_float(v : String, flag : String) : Float64
        f = v.to_f?
        abort "gori run screenshot: invalid #{flag} '#{v}' (expected a positive number)" unless f && f.finite? && f > 0
        f
      end
    end
  end
end
