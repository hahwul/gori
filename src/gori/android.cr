require "./bind_address"

module Gori
  # Point an Android emulator or rooted test device at gori over adb (#1600), the Android
  # counterpart of Open browser / Open shell: `adb reverse` the proxy port so gori keeps its
  # loopback bind, set the device's global HTTP proxy, and trust gori's root — as a user CA,
  # or in the system store until the device reboots (a tmpfs over the cacerts directory, the
  # method HTTP Toolkit uses).
  #
  # Planning is pure and separate from running, so `--dry-run` prints, and the specs assert
  # on, the exact argv the device gets (P4). Every step is an argv for `adb`, never a host
  # shell; the one device-side script is built from constants and an 8-hex-digit hash.
  module Android
    # Where `--user` leaves the CA for Settings → Install a certificate to find.
    USER_CA_PATH  = "/sdcard/Download/gori-ca.crt"
    SYSTEM_CA_DIR = "/system/etc/security/cacerts"
    # Android 14 reads system CAs from the Conscrypt APEX, which needs the mount injected into
    # zygote's and every app's namespace. Not done until it is tested on a device: refused.
    APEX_SDK = 34
    # The reset a bare `settings delete` is not: some builds keep using a deleted proxy.
    PROXY_OFF = ":0"

    MISSING_ADB = "adb not found — install Android platform-tools and put adb on PATH, or set ANDROID_HOME"
    NO_DEVICE   = "no device connected — start an emulator, or plug one in with USB debugging on"

    enum Mode
      User
      System
    end

    # How a device runs a command as root, tried in this order by `probe`.
    enum Root
      Adbd # adbd already runs as root (`adb root`)
      Su0  # AOSP su, on emulator userdebug images: `su 0 sh -c …`
      SuC  # Magisk and friends: `su -c …`
    end

    # A row of `adb devices -l`. `state` is "device" when it can be used.
    record Device, serial : String, state : String, model : String? do
      def ready? : Bool
        state == "device"
      end
    end

    # What setup needs to know about one device.
    record Probe, sdk : Int32?, emulator : Bool, root : Root?, http_proxy : String?

    # One `adb` invocation. `expect` is the last stdout line a success prints.
    record Step, args : Array(String), what : String, fatal : Bool = true, expect : String? = nil do
      def command : String
        Process.quote_posix(["adb"] + args)
      end
    end

    record Outcome, step : Step, ok : Bool, detail : String do
      def fatal_failure? : Bool
        !ok && step.fatal
      end
    end

    # `adb` on PATH, else under `$ANDROID_HOME` / `$ANDROID_SDK_ROOT`. `find_executable` adds
    # `.exe` on Windows.
    def self.adb_path : String?
      Process.find_executable("adb") ||
        {"ANDROID_HOME", "ANDROID_SDK_ROOT"}.each do |var|
          if root = ENV[var]?.presence
            found = Process.find_executable(File.join(root, "platform-tools", "adb"))
            return found if found
          end
        end
    end

    # The rows of `adb devices -l` output: only what follows its header, so a "* daemon
    # started" or version-mismatch notice is never read as a device. A udev refusal's state is
    # several words ("no permissions (…)"); it is kept as "no permissions".
    def self.parse_devices(text : String) : Array(Device)
      rows = text.lines.skip_while { |l| !l.starts_with?("List of devices") }.skip(1)
      rows.compact_map do |line|
        cols = line.split
        next if cols.size < 2
        state = cols[1] == "no" ? "no permissions" : cols[1]
        model = cols[2..].find(&.starts_with?("model:")).try(&.lchop("model:"))
        Device.new(cols[0], state, model)
      end
    end

    def self.devices(adb : String) : Array(Device)
      ok, text, err = capture(adb, ["devices", "-l"], DEVICES_TIMEOUT)
      raise Gori::Error.new("adb devices failed: #{last_line(err, text)}") unless ok
      parse_devices(text)
    end

    PROBE_SCRIPT = "getprop ro.build.version.sdk; getprop ro.boot.qemu; getprop ro.kernel.qemu; " \
                   "id -u; settings get global http_proxy"

    # `PROBE_SCRIPT`'s five lines. `root` is Adbd when adbd already runs as uid 0; `probe`
    # tries su only when it does not.
    def self.parse_probe(text : String) : Probe
      sdk, qemu1, qemu2, uid, proxy = (text.lines.map(&.strip) + [""] * 5).first(5)
      Probe.new(sdk.to_i?, qemu1 == "1" || qemu2 == "1", uid == "0" ? Root::Adbd : nil, proxy.presence.try { |p| p unless p == "null" })
    end

    # `try_su` only where root is used (a system CA, an undo): on a Magisk phone each su try is
    # a superuser prompt that blocks up to its timeout.
    def self.probe(adb : String, serial : String, try_su : Bool = true) : Probe
      ok, text, err = capture(adb, ["-s", serial, "shell", PROBE_SCRIPT])
      raise Gori::Error.new("cannot read #{serial}: #{last_line(err, text)}") unless ok
      found = parse_probe(text)
      return found if found.root || !try_su
      su = {Root::Su0, Root::SuC}.find do |r|
        got, uid, _ = capture(adb, ["-s", serial, "shell", as_root(r, "id -u")])
        got && last_line(uid) == "0"
      end
      found.copy_with(root: su)
    end

    # `script` run as root by `root`. Quoted for the device's shell, which is what reads an
    # `adb shell` argument; the script is gori's own and never carries a quote.
    def self.as_root(root : Root, script : String) : String
      raise ArgumentError.new("quote in root script") if script.includes?('\'')
      case root
      in .adbd? then script
      in .su0?  then "su 0 sh -c '#{script}'"
      in .su_c? then "su -c '#{script}'"
      end
    end

    # The steps that point `serial` at gori on `gori_port`, reached on the device at
    # 127.0.0.1:`device_port`. `ca_path` is the PEM pushed, `hash` its `subject_hash_old`. A
    # String is why `mode` cannot be set up on this device; system never falls back to user.
    def self.plan_setup(serial : String, device_port : Int32, gori_port : Int32, ca_path : String,
                        hash : String, mode : Mode, probe : Probe) : Array(Step) | String
      root = probe.root
      if mode.system? && !root
        return "--system needs root on the device (an emulator image without Play Store, or a rooted " \
               "device); use --user, or run `adb root` first"
      end
      if mode.system? && (sdk = probe.sdk) && sdk >= APEX_SDK
        return "--system is not supported on Android 14+ (SDK #{sdk}) yet: it keeps system CAs in the " \
               "Conscrypt APEX — use --user, or an API 33 or older image"
      end
      raise ArgumentError.new("bad CA hash #{hash.inspect}") unless hash.matches?(/\A[0-9a-f]{8}\z/)
      s = ["-s", serial]
      proxy = "127.0.0.1:#{device_port}"
      # The CA first and the proxy last: a step that fails leaves the device unproxied rather
      # than routed through a gori it does not trust.
      steps = [] of Step
      if mode.system? && root
        staged = "/data/local/tmp/gori-#{hash}.0"
        steps << Step.new(s + ["push", ca_path, staged], "copy gori's CA to the device")
        steps << Step.new(s + ["shell", as_root(root, system_ca_script(staged, hash))],
          "as root: trust it in the system store (a tmpfs over #{SYSTEM_CA_DIR}, gone on reboot)",
          expect: "gori-ok")
      else
        steps << Step.new(s + ["push", ca_path, USER_CA_PATH], "copy gori's CA to #{USER_CA_PATH}")
        steps << Step.new(s + ["shell", "am", "start", "-a", "android.settings.SECURITY_SETTINGS"],
          "open Security settings to install it as a CA certificate", fatal: false)
      end
      steps << Step.new(s + ["reverse", "tcp:#{device_port}", "tcp:#{gori_port}"],
        "map the device's 127.0.0.1:#{device_port} to gori's port #{gori_port}")
      steps << Step.new(s + ["shell", "settings", "put", "global", "http_proxy", proxy], "set the global HTTP proxy to #{proxy}")
      steps << Step.new(s + ["shell", "settings", "get", "global", "http_proxy"], "check the proxy took", expect: proxy)
      steps
    end

    # The tmpfs copy of the system store plus gori's root. An earlier setup's tmpfs is
    # unmounted first, so a regenerated CA does not leave the old one trusted. A step failing
    # after the mount unmounts it again, so a half-filled store never outlives the script. The
    # copy directory is per run (`$$`), so two setups at once do not share it.
    private def self.system_ca_script(staged : String, hash : String) : String
      d = SYSTEM_CA_DIR
      t = "/data/local/tmp/gori-cacerts-$$"
      fill = "mv #{t}/* #{d}/ && mv #{staged} #{d}/#{hash}.0 && chown root:root #{d}/* && " \
             "chmod 644 #{d}/* && chcon u:object_r:system_file:s0 #{d}/*"
      ["set -e", unmount_if_ours,
       "rm -rf #{t}", "mkdir -m 700 #{t}", "cp #{d}/* #{t}/", "mount -t tmpfs tmpfs #{d}",
       "if #{fill}; then rmdir #{t}; else umount #{d}; rm -rf #{t}; exit 1; fi",
       "cat #{BOOT_ID} > #{MOUNT_MARK}", "echo gori-ok"].join("; ")
    end

    # Setup records the boot it mounted in, so only gori's own tmpfs is unmounted: another
    # tool's over the same directory, or a stale record from before a reboot, is left alone.
    private MOUNT_MARK = "/data/local/tmp/gori-system-ca"
    private BOOT_ID    = "/proc/sys/kernel/random/boot_id"

    private def self.unmount_if_ours : String
      %(if [ "$(cat #{MOUNT_MARK} 2>/dev/null)" = "$(cat #{BOOT_ID})" ] && ) +
        %(grep -q " #{SYSTEM_CA_DIR} tmpfs " /proc/mounts; then umount #{SYSTEM_CA_DIR}; fi; rm -f #{MOUNT_MARK})
    end

    # What undoes `plan_setup`, safe to run twice or on a device setup never touched: after the
    # proxy reset, which has to land, every step is best-effort. `device_port` nil skips the
    # reverse removal (there is none to name); `root` nil leaves a system CA to the next reboot.
    def self.plan_undo(serial : String, device_port : Int32?, root : Root?) : Array(Step)
      s = ["-s", serial]
      steps = [Step.new(s + ["shell", "settings", "put", "global", "http_proxy", PROXY_OFF], "clear the global HTTP proxy")]
      device_port.try { |p| steps << Step.new(s + ["reverse", "--remove", "tcp:#{p}"], "remove the tcp:#{p} reverse mapping", fatal: false) }
      steps << Step.new(s + ["shell", "rm", "-f", USER_CA_PATH], "delete #{USER_CA_PATH}", fatal: false)
      if root
        steps << Step.new(s + ["shell", as_root(root, unmount_if_ours)],
          "as root: unmount a system-store tmpfs if there is one", fatal: false)
      end
      steps
    end

    # The device port a setup mapped, read back from the proxy it set (`127.0.0.1:N`).
    def self.mapped_port(http_proxy : String?) : Int32?
      # `[0-9]`, not `\d`: PCRE's `\d` also takes `٨٠`, which `to_i` refuses by raising.
      return nil unless http_proxy && (m = http_proxy.match(/\A127\.0\.0\.1:([0-9]{1,5})\z/))
      m[1].to_i.try { |p| p if p.in?(1..65_535) }
    end

    # Whether `adb reverse` reaches a gori that dials at `host`: the adb server connects to
    # this machine's loopback, so a gori bound to one LAN address alone is out of its reach.
    def self.reverse_reaches?(host : String) : Bool
      h = BindAddress.dial_host(host).downcase
      h.in?("127.0.0.1", "::1", "localhost")
    end

    # Run `steps` in order, stopping after the first fatal failure. Yields each outcome as it
    # lands, so a CLI can print it live.
    def self.run(adb : String, steps : Array(Step), & : Outcome ->) : Array(Outcome)
      outcomes = [] of Outcome
      steps.each do |step|
        ok, text, err = capture(adb, step.args)
        last = last_line(text)
        detail = ok ? last : (last_line(err, text).presence || "failed")
        if ok && (want = step.expect) && last != want
          ok = false
          detail = "got #{last.inspect}"
        end
        outcome = Outcome.new(step, ok, detail)
        outcomes << outcome
        yield outcome
        break if outcome.fatal_failure?
      end
      outcomes
    end

    # How long one adb call may take. A device answers in well under a second; the ceiling is
    # for a wedged adb server or USB stack, and for a root prompt nobody answers. `adb devices`
    # gets less, since the TUI waits for it before it can draw the picker.
    STEP_TIMEOUT    = 30.seconds
    DEVICES_TIMEOUT = 10.seconds

    # Exit success, stdout and stderr, kept apart: the two arrive on separate pipes in no fixed
    # order, and only stdout answers `expect`. An `adb` that cannot start, or outlives
    # `timeout`, is a failure, not a raise.
    private def self.capture(adb : String, args : Array(String), timeout = STEP_TIMEOUT) : {Bool, String, String}
      stdout, stderr = IO::Memory.new, IO::Memory.new
      process = Process.new(adb, args, output: stdout, error: stderr)
      done = Channel(Process::Status).new(1)
      spawn(name: "gori-adb") { done.send(process.wait) }
      select
      when status = done.receive
        {status.success?, stdout.to_s, stderr.to_s}
      when timeout(timeout)
        process.terminate rescue nil
        {false, stdout.to_s, "adb did not answer within #{timeout.total_seconds.to_i}s"}
      end
    rescue ex : File::Error | IO::Error
      {false, "", ex.message || "cannot run #{adb}"}
    end

    # The last non-blank line of the first text that has one.
    private def self.last_line(*texts : String) : String
      texts.each do |t|
        if line = t.lines.map(&.strip).reject(&.empty?).last?
          return line
        end
      end
      ""
    end
  end
end
