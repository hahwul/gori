require "./runner"
require "../session"
require "./terminal_port"
require "./key_script"
require "../screenshot"

module Gori::Tui
  # Draw one TUI frame with no terminal, and hand it back as data.
  #
  # A Runner is booted against an `OffscreenTerminal` exactly the way `Runner#run` boots one
  # against a real tty — same `boot`, same controllers, same store — then asked for its frame.
  # Not a mock of the UI: whatever ships is what is photographed, which is the only version of
  # this worth having.
  #
  # ## What a rendered frame is a picture OF
  #
  # It is a picture of the state the store is in RIGHT NOW, plus whatever the scripted keys
  # changed synchronously.
  #
  # The one wait is `Runner#settle_reads`, for the backgrounded History/Sitemap query this
  # render itself started — without it every frame of the busiest tab in the product would read
  # "no flows match…" over a full database. Nothing else is waited for: `Runner#run`'s poll loop
  # also drains flow events, repeater results, intercept holds and the data_version poll between
  # frames, and none of that runs here. That work arrives from OUTSIDE and has no end a renderer
  # could wait on, so a `SLEEP` step only yields to the scheduler. A script that sends `C-r` in
  # the Repeater therefore photographs "sending…", not the response. Scripts should drive
  # NAVIGATION and state that is already in the database.
  #
  # ## What it must not disturb
  #
  # Rendering is supposed to be an observation, but a Runner is a full TUI shell and opening a
  # project rebinds a shelf of process globals — the `Env` layer most sharply. Inside `gori mcp`
  # the `Tools` object binds `Env.layer` ONCE at construction, so a screenshot that left the
  # session's layer in place (or nil'd it on close) would silently wipe every `$BIND.NAME` an
  # agent had extracted. `with_globals` saves and restores every one of them.
  #
  # Two things it deliberately does NOT do: it never calls `Paths.write_active_project` (a
  # picture of a project is not a decision to work in it — that is `run`'s, and it is what
  # `gori mcp --use-active-project` follows), and it never announces agent presence. One thing
  # it cannot avoid: `Runner.new` calls `Runner.settle_tab_slots`, which rewrites and SAVES the
  # tab prefs once if a layout saved before the nine slots names more visible tabs than the bar
  # holds. That write is the point of settling (the notice is raised on this launch and never
  # again) and is idempotent, so it is left alone.
  module Headless
    # `matcher_for` is a Proc rather than a matcher because building one needs the session's
    # store, which does not exist until this method opens it — and the caller must not be
    # handed a store it would then have to remember not to close.
    def self.render(project : Project, config : Config, ca : Proxy::Tls::CertAuthority,
                    registry : Verb::Registry, *,
                    cols : Int32 = 132, rows : Int32 = 38, tab : Symbol? = nil,
                    keys : Array(KeyScript::Step) = [] of KeyScript::Step,
                    theme : String? = nil, title : String? = nil,
                    matcher_for : Proc(Store, Gori::Redact::Matcher?)? = nil) : Screenshot::Frame
      if tab && !Chrome::TABS.any? { |(sym, _)| sym == tab }
        raise Gori::Error.new("no such tab: #{tab} (expected one of #{Chrome::TABS.map(&.first).join(", ")})")
      end
      with_globals do
        # `Theme.apply` falls back to GORIDARK for a name it does not know, so an unknown theme
        # would render silently in the default rather than being reported. Validating is the
        # CALLER's job (it has the operator's spelling and somewhere to complain); by here the
        # name is taken as meant.
        Theme.apply(theme) if theme
        # `listen: false`: no capture lock, no socket, no scanner, no retention sweep, no idle
        # indexer. Drawing a project must not take capture away from the process that has it.
        session = Session.open(config, ca, registry, project, listen: false)
        begin
          runner = Runner.new(session, OffscreenTerminal.new(cols, rows))
          runner.boot(announce: false)
          # `focus_tab`, NOT `goto_tab`: only focus_tab runs `on_enter_tab`, which is where each
          # controller reloads from the store. A tab switched into any other way photographs an
          # empty pane over a full database.
          runner.focus_tab(tab, focus: :body) if tab
          runner.settle_reads
          keys.each do |step|
            step.events.each { |ev| runner.feed(ev) }
            # Yields to the scheduler and nothing more — see the note on async above.
            if pause = step.pause
              sleep pause
            end
            # Between keystrokes, exactly where the tick would have run it: a script that types
            # a filter and then arrows down has to be arrowing through the filtered rows.
            runner.settle_reads
          end
          frame = runner.frame
          # The window bar defaults to the caption the interactive capture stamps
          # (`Runner#capture_frame`, via the same `project_tab_title`), not to nothing: a
          # picture whose bar is blank cannot say which project or tab it is OF, and both
          # headless surfaces document `--title` as overriding "the frame's own".
          frame = frame.with(title: title || runner.project_tab_title)
          Screenshot::Mask.apply(frame, matcher_for.try &.call(session.store))
        ensure
          session.close
        end
      end
    end

    # Run `block` and put every process global a project open moves back where it was.
    #
    # This is the whole reason a render is safe to call from a long-lived process (`gori mcp`,
    # a TUI that screenshots itself). Each entry below is something `Session.open` or the
    # Runner assigns unconditionally, and each would otherwise outlive the frame.
    private def self.with_globals(&)
      env_layer = Env.layer
      env_vars = Settings.project_env_vars
      theme_name = Theme.active_name
      bell = Settings.notify_bell?
      # The nine project-network class properties `Settings.load_project_network` assigns —
      # ALL of them, nil included, because that method assigns unconditionally (a surface that
      # switches projects must not carry the previous one's upstream into the next).
      bind_host = Settings.project_bind_host
      bind_port = Settings.project_bind_port
      upstream = Settings.project_upstream_proxy
      upstream_dest = Settings.project_upstream_destination
      upstream_auth = Settings.project_upstream_auth
      upstream_auth_error = Settings.project_upstream_auth_error
      connect_timeout = Settings.project_connect_timeout_secs
      io_timeout = Settings.project_io_timeout_secs
      capture_max = Settings.project_capture_max_mib
      # A notification raised while drawing writes `\a` to `TtyOut`, which falls back to STDOUT
      # when there is no tty — a bell in whatever pipe the caller is writing the picture to.
      Settings.notify_bell = false
      begin
        yield
      ensure
        Settings.notify_bell = bell
        # Through the SETTER, not the ivar: it recompiles the routing pattern and re-derives
        # its error, so assigning the raw string back is what makes the restored value mean the
        # same thing to `Upstream.dial` as it did before.
        Settings.project_upstream_destination = upstream_dest
        Settings.project_bind_host = bind_host
        Settings.project_bind_port = bind_port
        Settings.project_upstream_proxy = upstream
        Settings.project_upstream_auth = upstream_auth
        Settings.project_upstream_auth_error = upstream_auth_error
        Settings.project_connect_timeout_secs = connect_timeout
        Settings.project_io_timeout_secs = io_timeout
        Settings.project_capture_max_mib = capture_max
        Settings.project_env_vars = env_vars
        # By NAME: a custom theme's palette may have been rebuilt under a stable name while we
        # were away, and `apply` compares content, so re-applying the name is what restores the
        # live palette rather than a stale copy of it.
        Theme.apply(theme_name)
        # LAST of the three token-resolution globals, and the one that matters most: `gori mcp`
        # binds `Env.layer` once at construction (mcp/tools.cr), so the session's `close` nil'ing
        # it would leave every later `$BIND.NAME` unresolvable for the rest of that process.
        Env.layer = env_layer
        # `Theme.apply` and the `Env`/`Settings` restores above all feed caches keyed on the
        # highlight revision (a TextArea's styled buffer, `Highlight`, `Rules#subst_snapshot`).
        # Bump once at the end so nothing reads a buffer painted under the render's globals.
        Env.bump_highlight_rev
      end
    end

    # `Protobuf::Schemas.load_project` is deliberately absent from the list above: it is
    # replace-semantics keyed on the store it was loaded from, so a render of project X
    # followed by a restore to project X is the same load twice — idempotent. A render of a
    # DIFFERENT project does replace it, which is the same thing the project picker does and is
    # the behaviour every surface already expects from switching projects.
  end
end
