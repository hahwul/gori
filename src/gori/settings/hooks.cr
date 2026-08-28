require "../process_hook"

# HOOKS section: the one knob the external process hooks share (#818). See settings.cr for the
# module-level overview and the load/save/serialize orchestration.
module Gori::Settings
  # The wall-clock budget one hook run gets, in seconds.
  #
  # ONE knob for all three seams — the Rewriter `pipe` op, the Decoder `exec:` step, the Probe
  # `exec` rule — because they run the same primitive over the same kind of command and an
  # operator tuning "how long may my script take" is answering one question, not three (P0).
  #
  # Clamped into 1..`ProcessHook::MAX_TIMEOUT`, and the ceiling is not negotiable: P6 says the
  # data path never stalls, so a settings file cannot buy a hook the right to hold a proxied
  # message for a minute and a half. A value outside the range is clamped rather than rejected,
  # the way `network.capture_max_mib` is — an out-of-range number in a hand-edited file must not
  # take the section (or, through `load`'s blanket rescue, the whole file) down with it.
  DEFAULT_HOOK_TIMEOUT_SECS = ProcessHook::DEFAULT_TIMEOUT.total_seconds.to_i
  MAX_HOOK_TIMEOUT_SECS     = ProcessHook::MAX_TIMEOUT.total_seconds.to_i

  class_property hook_timeout_secs : Int32 = DEFAULT_HOOK_TIMEOUT_SECS

  private def self.parse_hooks(node : JSON::Any?) : Nil
    h = node.try(&.as_h?)
    return unless h
    int_field(h, "timeout_secs").try { |v| self.hook_timeout_secs = v.clamp(1, MAX_HOOK_TIMEOUT_SECS) }
  end

  private def self.reset_hooks : Nil
    self.hook_timeout_secs = DEFAULT_HOOK_TIMEOUT_SECS
  end

  # Omitted while it is the default, so an install that has never configured a hook writes no
  # `hooks` block — the same rule every other optional section follows.
  private def self.serialize_hooks(j : JSON::Builder) : Nil
    return if hook_timeout_secs == DEFAULT_HOOK_TIMEOUT_SECS
    j.field "hooks" do
      j.object { j.field "timeout_secs", hook_timeout_secs }
    end
  end
end
