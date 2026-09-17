# The MCP `screenshot` tool: draw the real TUI over the bound project and hand the agent back
# a file (and, on request, the picture itself).
#
# WHY A SURFACE REACHES INTO ANOTHER SURFACE HERE. `Tui::Headless.render` is the engine for
# this feature in the sense AGENTS.md means — the one implementation all three surfaces call,
# with only the option PARSING differing. There is no frame to be had without booting a Runner,
# and a mock of the chrome would be a picture of something gori does not ship. `gori run
# screenshot` reaches for exactly the same seam.
#
# It is a WRITE tool (`gated:`) because it puts a file on disk outside the project database —
# the one thing here that a read tool never does. It is NOT an `agent_action`: nothing in the
# project changes, nothing goes out on the network, and an event-feed entry per screenshot
# would bury the mutations the feed exists to surface.
require "base64"
require "json"
require "../../screenshot"
require "../../tui/headless"

module Gori
  module MCP
    class Tools
      # The largest inline payload, as ENCODED (base64 for an image, the document itself for
      # text). A tool result travels in the model's context window, and a 132x38 SVG is already
      # ~200 KB of markup — past a megabyte the block is not a picture the agent can use, it is
      # a context budget spent on one call. The file has been named either way; `inline:false`
      # and reading the path is always available.
      SCREENSHOT_INLINE_MAX = 1024 * 1024

      # Rendering a frame is expensive in the one dimension an agent cannot see (cells drawn),
      # so the grid is capped the same way `gori run screenshot --size` caps it.
      SCREENSHOT_MAX_DIM = 1000

      # Every argument, already read and already judged. Built once by `screenshot_args`, so the
      # handler below is the ORDER of the operation and nothing else.
      record ScreenshotArgs,
        tab : Symbol?, format : String, theme : String?,
        cols : Int32, rows : Int32, scale : Int32, title : String?,
        inline : Bool, overwrite : Bool, include_sensitive : Bool,
        steps : Array(Tui::KeyScript::Step)

      @[Tool("screenshot", gated: true)]
      private def screenshot(h) : Result
        # FIRST, before a single validation and long before anything is written: this server may
        # be bound BY STORE and not by path (a test harness, an embedder). There is no project
        # FILE to open a second view-only session on, and `Headless.render` needs one.
        path_of_db = @db_path
        unless path_of_db
          return err("this server has no project FILE to render (bound by store, not by path); " \
                     "call switch_project first", "NO_PROJECT")
        end

        a = screenshot_args(h)
        return a if a.is_a?(Result)

        target = screenshot_target(str(h, "path"), a.format, a.tab, a.overwrite)
        return target if target.is_a?(Result)

        frame = screenshot_frame(path_of_db, a)
        payload = screenshot_payload(frame, a.format, a.scale)
        return payload if payload.is_a?(Result)

        budget = screenshot_budget(payload, a)
        return budget if budget

        begin
          File.write(target, payload)
        rescue ex : File::Error
          return err("cannot write #{target}: #{ex.message}", "INVALID_ARGUMENT", field: "path")
        end

        Result.new(screenshot_json(target, a.format, frame, payload, a.tab),
          extra: a.inline ? [screenshot_block(payload, a.format)] : [] of Content)
      end

      # Read and judge every argument, before the first side effect. The three closed sets are
      # the same constants the schema advertises, so a value the schema shows is a value this
      # accepts and a value it does not is refused BY NAME.
      private def screenshot_args(h) : ScreenshotArgs | Result
        tab_name = closed_filter(h, "tab", Tui::Chrome::TABS.map(&.first.to_s))
        return tab_name if tab_name.is_a?(Result)
        tab = tab_name.try { |n| Tui::Chrome::TABS.find { |(sym, _)| sym.to_s == n }.try(&.[0]) }

        fmt = closed_filter(h, "format", Screenshot::FORMATS) || "svg"
        return fmt if fmt.is_a?(Result)

        # Custom themes are files under <GORI_HOME>/themes; they have to be REGISTERED before
        # `Theme.available` can say whether the caller's spelling is one of them.
        Tui::Theme.load_custom
        theme = closed_filter(h, "theme", Tui::Theme.available)
        return theme if theme.is_a?(Result)

        steps = screenshot_steps(h)
        return steps if steps.is_a?(Result)

        ScreenshotArgs.new(
          tab: tab, format: fmt, theme: theme,
          cols: clamp(int(h, "cols"), 132, SCREENSHOT_MAX_DIM),
          rows: clamp(int(h, "rows"), 38, SCREENSHOT_MAX_DIM),
          scale: clamp(int(h, "scale"), 2, Screenshot::Png::MAX_SCALE),
          title: str(h, "title").try(&.presence),
          inline: bool_arg(h, "inline", false),
          overwrite: bool_arg(h, "overwrite", false),
          include_sensitive: bool_arg(h, "include_sensitive", false),
          steps: steps)
      end

      # Parsed BEFORE the session opens, which is `KeyScript.parse`'s whole contract: a typo in
      # the last key must not first open a project and bind a shelf of process globals.
      private def screenshot_steps(h) : Array(Tui::KeyScript::Step) | Result
        script = str(h, "keys").try(&.presence)
        return [] of Tui::KeyScript::Step unless script
        Tui::KeyScript.parse(script)
      rescue ex : Gori::Error
        err("invalid 'keys': #{ex.message}", "INVALID_ARGUMENT", field: "keys")
      end

      # The refusal an oversized `inline` earns, or nil.
      #
      # Judged BEFORE the write, not after: a refusal that has already put a file on disk is not
      # a refusal, and the caller who re-runs with `inline:false` would then meet their own
      # half-finished artifact as an "already exists".
      private def screenshot_budget(payload : Bytes, a : ScreenshotArgs) : Result?
        return nil unless a.inline
        size = screenshot_encoded(payload, a.format).bytesize
        return nil unless size > SCREENSHOT_INLINE_MAX
        err("the #{a.format} picture is #{size} bytes encoded, past the " \
            "#{SCREENSHOT_INLINE_MAX}-byte inline budget — nothing was written; call again with " \
            "inline:false (the path is returned either way), or narrow the shot with cols/rows",
          "BUDGET_EXHAUSTED", field: "inline")
      end

      # The frame, drawn by the same Runner `gori` boots.
      #
      # `matcher_for` rather than a matcher: building one needs the session's OWN store, which
      # does not exist until `render` opens it — and this server's `@store` is a different
      # handle on the same file. `include_sensitive` is the MCP convention for "hand me the
      # captured bytes" and turns the mask off; without it the project's ambient profile (if it
      # has one) is painted over the cells, exactly as `get_flow` sanitizes a body.
      private def screenshot_frame(db_path : String, a : ScreenshotArgs) : Screenshot::Frame
        Paths.ensure_dirs
        project = Project.new(@project_name || File.basename(File.dirname(db_path)), db_path)
        config = Config.new(db_path: db_path, ca_dir: Paths.default_ca_dir)
        Tui::Headless.render(project, config,
          Proxy::Tls::CertAuthority.load_or_create(config.ca_dir), Verbs.registry,
          cols: a.cols, rows: a.rows, tab: a.tab, keys: a.steps, theme: a.theme, title: a.title,
          matcher_for: a.include_sensitive ? nil : ->(store : Store) { Redact::Policy.ambient(store) })
      end

      # Where the picture goes, or the refusal. A RELATIVE path is resolved under the
      # screenshots convention dir rather than against this server's working directory, which
      # an agent has no way to know and no reason to write into.
      private def screenshot_target(requested : String?, fmt : String, tab : Symbol?,
                                    overwrite : Bool) : String | Result
        asked = requested.try(&.strip).presence
        path =
          if asked
            asked.starts_with?('/') ? asked : File.expand_path(asked, Paths.screenshots_dir)
          else
            Paths.ensure_dir(Paths.screenshots_dir)
            File.join(Paths.screenshots_dir,
              Screenshot.suggest_filename(Screenshot.slug(@project_name || "gori"),
                tab.try(&.to_s), fmt, Time.local))
          end
        if Dir.exists?(path)
          return err("'path' #{path} is a directory", "INVALID_ARGUMENT", field: "path")
        end
        parent = File.dirname(path)
        unless Dir.exists?(parent)
          return err("'path' #{path} has no directory #{parent} — create it, or pass a relative " \
                     "path, which is resolved under #{Paths.screenshots_dir}",
            "INVALID_ARGUMENT", field: "path")
        end
        if File.exists?(path) && !overwrite
          return err("#{path} already exists — pass overwrite:true, or a different 'path'",
            "INVALID_ARGUMENT", field: "path")
        end
        path
      end

      # The document as the bytes that go on disk. PNG is the only binary one; the rest are
      # text, and `to_slice` keeps one write path rather than two.
      private def screenshot_payload(frame : Screenshot::Frame, fmt : String, scale : Int32) : Bytes | Result
        case fmt
        when "png"
          Screenshot::Font.use
          # `cols`, `rows` and `scale` are each clamped on their own and their PRODUCT is not:
          # 1000x1000 at scale 2 asks for a 516-million-pixel canvas, two gigabytes, from three
          # arguments that were every one of them in range. Judged off `dimensions`, which draws
          # nothing, and before the write — so a refusal leaves no file behind.
          dims = Screenshot::Png.dimensions(frame, scale: scale, title: frame.title)
          if msg = Screenshot::Png.pixel_budget_error(*dims)
            return err("#{msg} — lower 'scale', narrow the shot with cols/rows, or ask for " \
                       "format:\"svg\"", "BUDGET_EXHAUSTED", field: "scale")
          end
          bytes = Screenshot::Png.render(frame, scale: scale, title: frame.title)
          # The header read back off the bytes, against the geometry they were asked for — the
          # one self-check a writer can make, and what would catch a truncated encode before the
          # agent is handed a path to a picture nothing can open.
          if msg = Screenshot::Png.output_error(bytes, dims)
            return err("#{msg} — refusing to write it; ask for format:\"svg\"",
              "INTERNAL", field: "format")
          end
          bytes
        when "ansi" then Screenshot::Ansi.render(frame).to_slice
        when "txt"  then Screenshot::Text.render(frame).to_slice
        else             Screenshot::Svg.render(frame, title: frame.title).to_slice
        end
      end

      # The inline payload as it will travel: base64 for an image, the document verbatim for
      # text. Measured before the write, so the budget is judged on what the caller would
      # actually receive rather than on the file's size.
      private def screenshot_encoded(payload : Bytes, fmt : String) : String
        fmt == "png" ? Base64.strict_encode(payload) : String.new(payload)
      end

      # The second `content[]` block. An image carries a mime type and travels base64; every
      # other format is a TEXT block holding the document itself, which is what lets an agent
      # read an SVG's markup or paste an ANSI dump somewhere without a second file read.
      private def screenshot_block(payload : Bytes, fmt : String) : Content
        if fmt == "png"
          Content.new("image", Base64.strict_encode(payload), "image/png")
        else
          Content.new("text", String.new(payload))
        end
      end

      # The summary the agent reads. `sanitized` is the count of masked cells, or null when no
      # redaction profile applied at all — the same distinction `Screenshot::Mask` draws, and
      # the difference between a picture that was checked and one that never was.
      #
      # `unmaskable` is the rest of that answer: rules the profile carries that NO frame can be
      # asked for (its JSON pointers). Without it a pointer-only profile reports `sanitized: 0`
      # and an agent reads "checked, and clean" off a picture nothing was applied to.
      private def screenshot_json(path : String, fmt : String, frame : Screenshot::Frame,
                                  payload : Bytes, tab : Symbol?) : String
        JSON.build do |j|
          j.object do
            j.field "path", path
            j.field "format", fmt
            j.field "cols", frame.cols
            j.field "rows", frame.rows
            j.field "bytes", payload.size
            j.field "sanitized", frame.sanitized
            j.field "unmaskable", frame.unmaskable
            j.field "tab", tab.try(&.to_s)
          end
        end
      end

      private def list_screenshot_tools(j : JSON::Builder) : Nil
        return unless @allow_actions

        tool j, "screenshot",
          "Draw the gori TUI headlessly over the BOUND project and write the frame to a file. " \
          "It is the real chrome over the real store — the shipping UI, not a mock — opened " \
          "VIEW-ONLY: no port is bound, no capture lock is taken, nothing is captured and the " \
          "active project is not changed, so the status line's capture chip reads `off` in " \
          "every shot. Returns the path it wrote; pass inline:true to also get the picture " \
          "back in this result (an image block for png, the document as text for svg/ansi/txt). " \
          "Use it to SEE what an operator would see — a pane's layout, a chart, a rendered " \
          "issue — when the JSON tools give you rows but not the shape." do |s|
          s.field "tab", enumprop("tab to open before drawing (default: the project's own home tab)",
            Tui::Chrome::TABS.map(&.first.to_s))
          s.field "keys", strprop("keys to send before drawing, in tmux send-keys grammar " \
                                  "(`C-p \"acme\" Enter Down Down`, plus SLEEP<secs> — at most " \
                                  "#{Tui::KeyScript::MAX_SLEEP.total_seconds.to_i}s per pause and " \
                                  "#{Tui::KeyScript::MAX_TOTAL_PAUSE.total_seconds.to_i}s over the script). " \
                                  "Drives NAVIGATION: the frame " \
                                  "shows the store as it is now, so anything async (a Repeater send, a scan) is " \
                                  "photographed mid-flight rather than awaited")
          s.field "cols", intprop("terminal width to draw at (default 132, max #{SCREENSHOT_MAX_DIM})")
          s.field "rows", intprop("terminal height to draw at (default 38, max #{SCREENSHOT_MAX_DIM})")
          s.field "theme", enumprop("theme to draw in (default: the configured one)", Tui::Theme.available)
          s.field "format", enumprop("output format (default svg)", Screenshot::FORMATS)
          s.field "path", strprop("where to write. Absolute, or relative — which is resolved under " \
                                  "#{Paths.screenshots_dir}. Omit for a timestamped name there")
          s.field "title", strprop("title for the window bar (default: the frame's own)")
          s.field "include_sensitive", boolprop("draw the captured values verbatim instead of masking " \
                                                "them with the project's redaction profile (default false)")
          s.field "inline", boolprop("also return the picture in this result, as a second content " \
                                     "block (default false). Refused past #{SCREENSHOT_INLINE_MAX} encoded bytes")
          s.field "overwrite", boolprop("replace an existing file at 'path' (default false)")
          s.field "scale", intprop("PNG supersample, 1..#{Screenshot::Png::MAX_SCALE} (png only, default 2)")
        end
      end
    end
  end
end
