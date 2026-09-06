require "../spec_helper"
require "./fake_host"
require "./memory_backend"
require "file_utils"

# The roster every TUI *contract* spec walks: one live `Session`, and one freshly built
# instance of EVERY `Gori::Tui::TabController` subclass over it.
#
# Why a roster rather than N hand-written examples. The tab controllers keep regressing on
# the same handful of interaction rules — a Ctrl chord swallowed before the keymap sees it, a
# hint strip naming a chord its own handler does not dispatch, a no-op keystroke marking a
# buffer dirty — and each fix so far has been written for the one or two panes where the bug
# was reported (see `ctrl_letter_guard_spec.cr`, which pins exactly two controllers, and
# `TabController#chord_of?`, added for exactly two panes). The rule was never the problem; the
# coverage was. A contract spec states the rule ONCE and applies it to every controller,
# including ones that do not exist yet: the list below is generated from
# `TabController.all_subclasses`, so a new tab joins every contract the day it compiles.
#
# What belongs here: a property that must hold for EVERY tab, expressible through the base
# class's own interface (`handle_body_key`, `body_hint`, `render_body`, `body_scroll`). A rule
# that needs a pane's private state belongs in that pane's own spec.
module TuiContract
  # The CA is the slow part of standing a Session up and no contract asserts anything about
  # it, so it is built once for the whole suite.
  CA_ROOT = File.tempname("gori-tui-contract-ca")
  Spec.after_suite { FileUtils.rm_rf(CA_ROOT) }

  # A comfortable terminal: every pane the shell can draw has room for its full geometry at
  # this size, so a render-then-press ladder sees each controller in its normal shape rather
  # than in a clamped one. (`Layout.usable?` is 40x8 — the small-terminal paths are their own
  # specs' business, e.g. `short_pane_clamp_spec`.)
  AREA = Gori::Tui::Rect.new(0, 0, 100, 40)

  # A `Host` whose `active_tab` follows the controller under test. `FakeHost` hardcodes
  # `:project`, which is fine for a spec about one pane and wrong for a sweep: several
  # controllers gate work on `@host.active_tab == tab` (the Repeater's reconcile is the
  # loudest), so a roster that left it at `:project` would exercise 22 of the 23 in a state
  # the shell never puts them in.
  class Host < FakeHost
    property tab : Symbol = :history
    property focus_pane : Symbol = :body

    def active_tab : Symbol
      @tab
    end

    def focus : Symbol
      @focus_pane
    end
  end

  def self.with_session(name : String = "contract", &)
    root = File.tempname("gori-#{name}")
    Dir.mkdir_p(root)
    project = Gori::ProjectRegistry.new(root).temp(name)
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      Gori::Proxy::Tls::CertAuthority.load_or_create(CA_ROOT), Gori::Verbs.registry, project)
    begin
      yield session
    ensure
      session.close
      FileUtils.rm_rf(root) if Dir.exists?(root)
    end
  end

  # Every tab controller, each with its OWN `Host` so one pane's toasts and overlay requests
  # cannot be read as another's. Built from `all_subclasses`, so this list cannot fall behind
  # `Runner#build_tabs`: every controller there is a subclass, and a subclass that is not
  # wired into the shell yet is still bound by the same contracts.
  #
  # A render comes first because several panes only settle their focusable regions while
  # drawing (`ColormarkerController`'s colours pane is the example `ctrl_letter_guard_spec`
  # names), and the shell always draws before it routes a key.
  #
  # Restricted to `Gori::Tui::` for two reasons, and both matter: a contract is about
  # PRODUCTION panes, and several specs define their own `private class Spy…Controller <
  # TabController` — those join `all_subclasses` but their constants are file-private, so
  # naming one here does not even compile.
  def self.each_controller(session : Gori::Session, & : Gori::Tui::TabController, Host ->) : Nil
    {% for t in Gori::Tui::TabController.all_subclasses.reject { |c| c.abstract? || !c.name.starts_with?("Gori::Tui::") } %}
      begin
        host = Host.new(session)
        controller = {{ t }}.new(host)
        host.tab = controller.tab
        render(controller)
        yield controller, host
      end
    {% end %}
  end

  # Draw the controller's body into a throwaway backend, the way the shell does before it
  # routes anything. Returns the backend so a caller can read what the operator would see.
  def self.render(controller : Gori::Tui::TabController, focus : Symbol = :body) : MemoryBackend
    backend = MemoryBackend.new(AREA.w, AREA.h)
    controller.render_body(Gori::Tui::Screen.new(backend), AREA, focus)
    backend
  end

  # The event a terminal really delivers for Ctrl+<letter>: the letter key plus the Ctrl
  # modifier and NO explicit char, so `Event::Key#char` has to fall back to `key.to_char` —
  # which is why a bare `c == 'a'` arm fires on the Ctrl form unless something refuses it.
  def self.ctrl(ch : Char) : Termisu::Event::Key
    Termisu::Event::Key.new(Termisu::Input::Key.from_char(ch), Termisu::Input::Modifier::Ctrl)
  end

  def self.alt(ch : Char) : Termisu::Event::Key
    Termisu::Event::Key.new(Termisu::Input::Key.from_char(ch), Termisu::Input::Modifier::Alt)
  end

  # A plain printable keystroke, spelled the way the parser delivers one.
  def self.plain(ch : Char) : Termisu::Event::Key
    Termisu::Event::Key.new(Termisu::Input::Key.from_char(ch), Termisu::Input::Modifier::None, ch)
  end

  def self.key(k : Termisu::Input::Key, mods : Termisu::Input::Modifier = :none) : Termisu::Event::Key
    Termisu::Event::Key.new(k, mods)
  end

  # Run `blk` with `Settings.keymap_overrides` set, restoring whatever was there. The
  # overrides are a process-wide singleton, so a contract that rebinds a verb has to put it
  # back or every later example in the same run inherits the rebind.
  def self.with_keymap(overrides : Hash(String, Array(String)), &)
    prev = Gori::Settings.keymap_overrides
    begin
      Gori::Settings.keymap_overrides = overrides
      yield
    ensure
      Gori::Settings.keymap_overrides = prev
    end
  end
end
