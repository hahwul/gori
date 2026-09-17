require "../../screenshot"
require "../../redact/policy"

# The screenshot verbs — reopens Gori::Tui::Runner (see tui/runner.cr for the event
# loop, Host facade, overlays, and rendering).
#
# Two intents over one capture. `screenshot_capture` writes where settings:screenshot says;
# `screenshot_save_as` raises the export card and lets the extension pick the format. Both go
# through `capture_frame`, which is where the three things that make a screenshot HONEST live:
#
#   1. Menus come down and the screen is repainted BEFORE the grid is read, so the picture is
#      of the UI rather than of the palette the operator opened to reach this verb.
#   2. The frame is the BACKEND's own front buffer — what the last flush actually put on the
#      glass — not a re-derivation of what the views think they drew.
#   3. The project's redaction profile is painted over it (`Screenshot::Mask`) before a single
#      byte reaches disk. A picture of a live engagement is evidence, and it leaves gori's
#      process the moment it is written.
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # "Screenshot" — straight to a file, no prompt. The common gesture, so it costs one palette
  # entry and nothing else.
  def screenshot_capture : Nil
    frame = capture_frame || return # capture_frame toasts when the backend keeps no frame
    fmt = Settings.screenshot_format
    write_screenshot(frame, File.join(screenshot_dir, screenshot_basename(fmt)), fmt)
  end

  # "Screenshot to…" — the export card, with the settings default prefilled.
  def screenshot_save_as : Nil
    # Capture NOW, before the card goes up. `dispatch_overlay_key` runs the commit closure
    # while the overlay is still on screen, so a capture inside the closure would photograph
    # the EXPORT card instead of the screen the operator wanted a picture of.
    frame = capture_frame || return
    default = File.join(screenshot_dir, screenshot_basename(Settings.screenshot_format))
    open_export(:screenshot, default) do |path|
      # The EXTENSION is the format — the card says so, and it is the only per-write choice
      # here. Matched against `Screenshot::FORMATS` rather than a local list, so a format the
      # renderers gain is reachable from this card without a second edit.
      fmt = Gori::Screenshot::FORMATS.find { |f| path.downcase.ends_with?(".#{f}") }
      unless fmt
        status("screenshot: unknown format for #{File.extname(path).inspect} — use .svg, .png, .ansi or .txt", :error)
        # false keeps the card up with the typed path intact: a mistyped extension is a
        # correctable failure, and making the operator retype the directory is not the fix.
        next false
      end
      write_screenshot(frame, path, fmt)
    end
  end

  # What is on the glass, with the menus down and the redaction profile painted over it.
  #
  # `render` first, deliberately: `Backend#snapshot` answers with the frame the LAST FLUSH
  # produced, and a verb runs partway through a tick — so without a repaint here the picture
  # would be one frame stale AND would still show whatever modal dispatched this verb.
  private def capture_frame : Gori::Screenshot::Frame?
    # The two MENUS come down — and ONLY those. A bare `leave_overlay` here would also drop
    # the History/Issues detail, the Links card, the settings editors and every other screen
    # modelled as an `OverlayKind`, which are precisely the screens worth photographing: the
    # detail is where a response body is READ, and a picture of the list behind it is not a
    # picture of what the operator was looking at. The palette and the space menu both close
    # themselves before dispatching a verb, so in practice this only catches a caller that
    # does not — but a menu is the one thing on screen that is about taking the picture
    # rather than part of it.
    leave_overlay if @overlay.palette?
    close_space_menu
    render
    frame = @backend.snapshot
    unless frame
      # The honest answer for a backend with no front buffer (see `Backend#snapshot`), not a
      # crash and not a blank picture.
      @toast = "screenshot failed: this terminal keeps no frame"
      return nil
    end
    frame = frame.with(title: project_tab_title, cursor: @last_cursor)
    # `Policy.ambient` and never a hand-built Matcher: it is what refuses an empty profile
    # (a picture that claims to be sanitized and is not is worse than an honest raw one) and
    # what arms the correlation salt behind every placeholder tag.
    Gori::Screenshot::Mask.apply(frame, Redact::Policy.ambient(@session.store))
  end

  # Serialize `frame` as `fmt` and write it. Returns whether the write happened, which is
  # also the export card's close decision.
  private def write_screenshot(frame : Gori::Screenshot::Frame, path : String, fmt : String) : Bool
    # `tighten: false`: a directory gori CREATES here is still 0700, but one it merely finds
    # belongs to whoever made it — and `screenshot_save_as` takes an arbitrary path, whose
    # parent can be a shared checkout or the working directory (see `Paths.ensure_dir`).
    Paths.ensure_dir(File.dirname(path), tighten: false)
    case fmt
    when "svg"  then File.write(path, Gori::Screenshot::Svg.render(frame))
    when "ansi" then File.write(path, Gori::Screenshot::Ansi.render(frame))
    when "txt"  then File.write(path, Gori::Screenshot::Text.render(frame))
    when "png"  then File.write(path, Gori::Screenshot::Png.render(frame, scale: Settings.screenshot_png_scale))
    else
      # Unreachable from either verb (both pick from `Screenshot::FORMATS`), so this is the
      # guard for a future caller rather than a branch an operator can drive.
      status("screenshot: unknown format #{fmt.inspect} — use svg, png, ansi or txt", :error)
      return false
    end
    # The export convention: lowercase, the count when a profile ran, and the PATH — a
    # picture the operator cannot find is one they will take again.
    @toast = "#{CopyMenu.sanitized_title("screenshot written", frame.sanitized)} · #{path}"
    true
  rescue ex
    @toast = "screenshot failed: #{ex.message}"
    false
  end

  # Where a screenshot lands when nobody names a path. `~` and a relative spelling are
  # expanded HERE, so the write, the collision check and the toast can never disagree about
  # which directory this is (`ExportOverlay#resolved_path`'s rule, one level up).
  private def screenshot_dir : String
    dir = Settings.screenshot_dir.presence || Paths.screenshots_dir
    Path[dir].expand(home: true).to_s
  end

  # `<project>-<tab>-<YYYYmmdd-HHMMSS>.<fmt>`, with a `-2`, `-3`… suffix when that name is
  # taken. The timestamp is LOCAL because it is a filename an operator reads back against
  # their own notes, and its one-second resolution is exactly why the suffix exists: a burst
  # of captures inside one second must not overwrite each other.
  private def screenshot_basename(fmt : String) : String
    stem = "#{screenshot_slug}-#{@active_tab}-#{Time.local.to_s("%Y%m%d-%H%M%S")}"
    dir = screenshot_dir
    name = "#{stem}.#{fmt}"
    n = 2
    while File.exists?(File.join(dir, name)) && n < 1000
      name = "#{stem}-#{n}.#{fmt}"
      n += 1
    end
    name
  end

  # The project's directory name, reduced to something safe on every filesystem. The DIRECTORY
  # and not `project.name`: the display name is free text (spaces, slashes, emoji), while the
  # directory is what the registry already made a filename out of.
  private def screenshot_slug : String
    slug = File.basename(@session.project.dir).gsub(/[^A-Za-z0-9_-]/, "-")[0, 40].strip('-')
    slug.empty? ? "gori" : slug
  end
end
