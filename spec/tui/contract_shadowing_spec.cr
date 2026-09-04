require "../support/tui_contract"

# CONTRACT: no subclass redefines a base hook under a DIFFERENT argument list.
#
# Crystal has no `override`. A subclass method whose name matches a base one but whose
# arguments do not is neither an error nor a warning — it is a second overload, and which one
# a call site binds to depends on the arity that caller happens to use. The shell calls the
# base arity, so either the subclass's version is never reached (a dead override) or a helper
# that merely borrowed the name intercepts the shell's dispatch (a hijacked hook). AGENTS.md
# lists this under Traps: "audit overlay and controller subclasses for accidental shadowing."
#
# The audit is mechanical, so it should not be a human's job. `all_subclasses` + `methods` is
# the whole check, and it costs nothing at runtime: the report is computed at COMPILE time and
# the example only asserts it is empty.
#
# The rule is one-directional, because the hazard is: a subclass must accept every call shape
# the BASE accepts. So it must not require more arguments than the base does, must not accept
# fewer, and must agree on splat / double-splat / block. Being MORE permissive is harmless —
# every call the base's interface allows still lands on the subclass — which is why
# `ConfirmDialog#move(_dir : Int32 = 1)` against `Overlay#move(step : Int32)` is not reported:
# the default only widens what it takes, and the `_` marks the argument as deliberately
# ignored (the dialog's ↑/↓ both flip between the two buttons).
#
# What is deliberately NOT compared:
#   * The return type. Narrowing a nilable base return to the non-nil case is legal and common
#     here — eleven controllers declare `subtab_labels : Array(String)` against the base's
#     `Array(String)?`, and `ConfirmDialog#overlay_box` always has a box. Matching arity means
#     the subclass really REPLACES the base method, so no dispatch can pick the wrong one.
#   * Argument NAMES. Renaming a positional argument only affects a named-argument call, and
#     the shell calls these hooks positionally; the `_`-prefixed spelling for an ignored
#     argument is worth more than the theoretical `move(step: 1)`.
#   * `initialize`. A subclass constructor legitimately differs and reaches the base one
#     through `super`.
#
# `only` narrows the sweep to a namespace: the real bases are audited over `Gori::Tui::`,
# because several specs define their own `private class Spy…Controller < TabController` and a
# contract is about production panes, not a spec's stand-in.
private macro shadow_report(base, only = "")
  begin
    drift = [] of String
    {% b = base.resolve %}
    {% by_name = {} of MacroId => Def %}
    {% for m in b.methods %}
      {% by_name[m.name.id] = m %}
    {% end %}
    {% for sub in b.all_subclasses.select(&.name.starts_with?(only)) %}
      {% for m in sub.methods %}
        {% if m.name.id != "initialize".id && (base_m = by_name[m.name.id]) %}
          {% required = m.args.reject { |a| !a.default_value.is_a?(Nop) }.size %}
          {% base_required = base_m.args.reject { |a| !a.default_value.is_a?(Nop) }.size %}
          {% if required > base_required || m.args.size < base_m.args.size ||
                  m.splat_index != base_m.splat_index ||
                  m.double_splat.is_a?(Nop) != base_m.double_splat.is_a?(Nop) ||
                  m.block_arg.is_a?(Nop) != base_m.block_arg.is_a?(Nop) %}
            {% mine = m.args.map(&.name).join(", ") %}
            {% theirs = base_m.args.map(&.name).join(", ") %}
            drift << {{ "#{sub}##{m.name}(#{mine.id}) shadows #{b}##{base_m.name}(#{theirs.id})" }}
          {% end %}
        {% end %}
      {% end %}
    {% end %}
    drift
  end
end

# The detector's own self-test, on a throwaway pair rather than on a fixture subclass of the
# real bases: a spec-local `TabController` subclass would join `all_subclasses` for the whole
# compiled suite and land in `TuiContract.each_controller`'s roster.
private abstract class ShadowProbeBase
  def hook(a : Int32) : Bool
    false
  end

  def optional_hook(a : Int32 = 0) : Bool
    false
  end

  def clean(a : Int32) : Bool
    false
  end

  def widened(a : Int32) : Bool
    false
  end
end

private class ShadowProbeChild < ShadowProbeBase
  # The trap: `hook` looks overridden and is not — the shell's one-argument call still lands
  # on the base.
  def hook(a : Int32, b : Int32) : Bool
    true
  end

  # The other direction of the same trap: the base's zero-argument call no longer binds here.
  def optional_hook(a : Int32) : Bool
    true
  end

  def clean(a : Int32) : Bool
    true
  end

  # Tolerated: more permissive than the base, so every call the base allows still lands here.
  # This is `ConfirmDialog#move`'s shape.
  def widened(a : Int32 = 1) : Bool
    true
  end
end

describe "TUI subclass contract — a base hook is overridden, never shadowed" do
  it "detects an argument list that drifted, in either direction, and tolerates a widened one" do
    report = shadow_report(ShadowProbeBase)
    report.size.should eq(2)
    report.any?(&.includes?("ShadowProbeChild#hook")).should be_true
    report.any?(&.includes?("ShadowProbeChild#optional_hook")).should be_true
    report.any?(&.includes?("widened")).should be_false
    report.any?(&.includes?("clean")).should be_false
  end

  it "no TabController subclass redefines a hook with a different argument list" do
    shadow_report(Gori::Tui::TabController, "Gori::Tui::").should be_empty
  end

  it "no Overlay subclass redefines a hook with a different argument list" do
    shadow_report(Gori::Tui::Overlay, "Gori::Tui::").should be_empty
  end
end
