require "../../android"

# "Set up Android device" (#1600): pick a device, then what to do with it; adb runs in a
# fiber of its own and the outcome lands as a toast. The steps are `Gori::Android`'s, the same
# ones `gori run android` prints and runs. Reopens Gori::Tui::Runner.
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # {job, toast, ok} from the worker fiber, drained on the tick.
  @android_events = Channel({Int32, String, Bool}).new(4)

  def open_android_picker : Nil
    # One at a time: two system setups on one device would unmount each other's store.
    return status("android: a setup is still running — wait for its toast") if @jobs.active.any? { |j| j.kind == :android }
    adb = Android.adb_path || return status("android: #{Android::MISSING_ADB}")
    devices = begin
      Android.devices(adb).select(&.ready?)
    rescue ex : Gori::Error
      return status("android: #{ex.message}")
    end
    return status("android: #{Android::NO_DEVICE}") if devices.empty?
    return open_android_action(adb, devices.first.serial) if devices.size == 1
    choices = devices.first(9).map_with_index do |d, i|
      ChoicePicker::Choice.new(d.model ? "#{d.serial} — #{d.model}" : d.serial, '1' + i, Theme.text, i)
    end
    open_choice_picker(ChoicePicker.new("ANDROID DEVICE", choices, -1, :android)) do |p|
      open_android_action(adb, devices[p.selected_value].serial)
    end
  end

  private def open_android_action(adb : String, serial : String) : Nil
    cp = ChoicePicker.new("ANDROID · #{serial}", [
      ChoicePicker::Choice.new("SETUP — user CA, no root (an app trusts it only if it opts in)", 'u', Theme.accent, 0),
      ChoicePicker::Choice.new("SETUP — system CA as root, until the device reboots", 's', Theme.orange, 1),
      ChoicePicker::Choice.new("UNDO — clear the proxy, the reverse mapping and the pushed CA", 'r', Theme.text, 2),
    ], -1, :android)
    # The values are `Android::Mode`'s; UNDO's is none of them.
    open_choice_picker(cp) { |p| start_android(adb, serial, Android::Mode.from_value?(p.selected_value)) }
  end

  # `mode` nil is undo.
  private def start_android(adb : String, serial : String, mode : Android::Mode?) : Nil
    host, port, ca = @session.proxy.host, @session.proxy.port, @session.ca.ca_cert_path
    if mode && !Android.reverse_reaches?(host)
      return status("android: adb reverse reaches gori on loopback, and it listens on #{host} — bind 127.0.0.1 or all interfaces")
    end
    off = @session.capturing? ? "" : " (capture is off — start it with c)"
    job = @jobs.start(:android, "android #{serial}")
    events = @android_events
    status("android #{serial}: running adb…", :busy)
    spawn(name: "gori-android") do
      text, ok =
        begin
          Runner.android_task(adb, serial, mode, port, ca)
        rescue ex
          {"android #{serial}: #{ex.message}", false}
        end
      events.send({job, ok ? text + off : text, ok})
    end
  end

  # Probe, plan and run a setup in `mode` (nil: undo) on the worker fiber; the toast and
  # whether it worked.
  def self.android_task(adb : String, serial : String, mode : Android::Mode?, port : Int32, ca : String) : {String, Bool}
    probe = Android.probe(adb, serial)
    unless mode
      # The TUI's setup maps gori's own port, so that is the one to remove when the device's
      # proxy no longer names it. The rest is best-effort; only the proxy reset has to land.
      steps = Android.plan_undo(serial, Android.mapped_port(probe.http_proxy) || port, probe.root)
      outcomes = Android.run(adb, steps) { }
      cleared = outcomes.first
      return {"android #{serial}: could not #{cleared.step.what} — #{cleared.detail}", false} unless cleared.ok
      # Name a best-effort step that failed rather than claim it, as `gori run android undo` lists each.
      missed = outcomes.reject(&.ok).map { |o| " · could not #{o.step.what}" }.join
      tail = probe.root ? "" : " · no root: a system CA stays until reboot"
      return {"android #{serial}: proxy cleared#{missed}#{tail} · a user CA you installed stays in Settings", true}
    end
    hash = Proxy::Tls::Cert.read_pem(ca).subject_hash_old
    plan = Android.plan_setup(serial, port, port, ca, hash, mode, probe)
    return {"android #{serial}: #{plan}", false} if plan.is_a?(String)
    if bad = Android.run(adb, plan) { }.find(&.fatal_failure?)
      return {"android #{serial}: could not #{bad.step.what} — #{bad.detail} (UNDO reverts what ran)", false}
    end
    done = mode.system? ? "gori's CA is a system CA until reboot" : "install #{Android::USER_CA_PATH} as a CA certificate in Settings"
    {"android #{serial}: proxied via 127.0.0.1:#{port} · #{done}", true}
  end

  # Land the worker's outcome. True when one arrived (→ a frame).
  private def drain_android_events : Bool
    select
    when ev = @android_events.receive
      job, text, ok = ev
      @jobs.finish(job, ok ? :done : :error, ok ? "done" : "failed")
      status(text, ok ? :done : :error)
      true
    else
      false
    end
  end
end
