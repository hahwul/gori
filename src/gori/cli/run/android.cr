# `gori run android` — point an Android emulator or rooted test device at a live gori over adb
# (#1600). The steps are `Android`'s; this file finds the gori and the device, prints the plan,
# and runs it unless `--dry-run`.
module Gori
  module CLI
    module Run
      @[Subcommand("android", help: [
        {"android devices", "List adb devices with their API level, emulator and root flags"},
        {"android setup", "Route an Android device through a live gori over adb and trust its CA (--user | --system)"},
        {"android undo", "Clear the device's proxy, reverse mapping and pushed CA"},
      ])]
      private def self.cmd_android(args : Array(String)) : Nil
        verb = args.first?.try { |a| a unless a.starts_with?('-') }
        serial : String? = nil
        project_name : String? = nil
        db_path : String? = nil
        proxy : String? = nil
        ca_dir : String? = nil
        port_arg : String? = nil
        system = false
        user = false
        dry_run = false
        extra = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run android devices | setup [options] | undo [options]\n\n" \
                     "Point an Android emulator or rooted test device at a live gori over adb: adb reverse\n" \
                     "the proxy port (gori stays on loopback), set the global HTTP proxy, and trust gori's CA.\n" \
                     "--user pushes the CA for Settings to install (apps trust it only if their network\n" \
                     "security config opts in); --system puts it in the system store as root until reboot.\n\n" \
                     "  gori run android setup --dry-run      # print the plan\n" \
                     "  gori run android setup --system\n" \
                     "  gori run android undo\n"
          p.on("--serial=S", "The device (default: the only one connected)") { |v| serial = v }
          p.on("--user", "setup: install gori's CA as a user certificate (default)") { user = true }
          p.on("--system", "setup: trust gori's CA in the system store, as root, until reboot") { system = true }
          p.on("--device-port=N", "The port the device dials on its 127.0.0.1 (default: gori's port; undo: read from the device)") { |v| port_arg = v }
          p.on("--project=NAME", "setup: point at the gori capturing project NAME (#{DEFAULT_PROJECT_HELP})") { |v| project_name = v }
          p.on("--db=PATH", "setup: point at the gori capturing this SQLite db file") { |v| db_path = v }
          p.on("--proxy=HOST:PORT", "setup: use this gori address instead of looking up a live capture") { |v| proxy = v }
          p.on("--ca-dir=DIR", "setup: CA directory (default: the capturing gori's, else ~/.gori/ca)") { |v| ca_dir = v }
          p.on("--dry-run", "Print the adb commands without changing anything (the device is still read)") { dry_run = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort CLI.unknown_option_message("gori run android", f, p) }
          p.missing_option { |f| abort "gori run android: missing value for #{f}" }
          p.unknown_args { |b, a| extra = b + a }
        end
        parser.parse(verb ? args[1..] : args)
        if msg = android_usage_error(verb, extra, user, system, port_arg, proxy, project_name, db_path, ca_dir)
          abort msg
        end
        adb = Android.adb_path || abort "gori run android: #{Android::MISSING_ADB}"
        devices = android_or_abort { Android.devices(adb) }
        return android_devices(adb, devices) if verb == "devices"

        picked = android_device(devices, serial)
        abort "gori run android: #{picked}" if picked.is_a?(String)
        probe = android_or_abort { Android.probe(adb, picked.serial, try_su: system | (verb == "undo")) }
        device_port = port_arg.try(&.to_i)
        ok = if verb == "undo"
               android_undo(adb, picked, probe, device_port, dry_run)
             else
               project = proxy ? nil : resolve_read_project(project_name, db_path)
               target = capture_target(project, proxy, ca_dir, "android")
               abort target if target.is_a?(String)
               mode = system ? Android::Mode::System : Android::Mode::User
               android_setup(adb, picked, probe, target, device_port, mode, dry_run)
             end
        exit(ok ? 0 : 1)
      end

      private def self.android_or_abort(&)
        yield
      rescue ex : Gori::Error
        abort "gori run android: #{ex.message}"
      end

      private def self.android_undo(adb : String, picked : Android::Device, probe : Android::Probe,
                                    device_port : Int32?, dry_run : Bool) : Bool
        steps = Android.plan_undo(picked.serial, device_port || Android.mapped_port(probe.http_proxy), probe.root)
        STDERR.puts "gori android undo · #{android_label(picked, probe)}"
        ok = android_run(adb, steps, dry_run)
        unless dry_run
          STDERR.puts "  a user CA you installed stays under Settings → Security → … → User credentials; remove it there"
          STDERR.puts "  no root: a system CA from setup --system stays until the device reboots" unless probe.root
        end
        ok
      end

      private def self.android_setup(adb : String, picked : Android::Device, probe : Android::Probe,
                                     target : CaptureTarget, device_port : Int32?, mode : Android::Mode,
                                     dry_run : Bool) : Bool
        prefix = "gori run android"
        unless Android.reverse_reaches?(target.host)
          abort "#{prefix}: adb reverse reaches the gori on this machine's loopback, and #{target.authority} " \
                "is not on it — run gori on 127.0.0.1 (or all interfaces)"
        end
        target.warnings.each { |w| STDERR.puts "#{prefix}: #{w}" }
        hash = Proxy::Tls::Cert.read_pem(target.ca_cert_path).subject_hash_old
        plan = Android.plan_setup(picked.serial, device_port || target.port, target.port,
          target.ca_cert_path, hash, mode, probe)
        abort "#{prefix}: #{plan}" if plan.is_a?(String)

        STDERR.puts "gori android setup · #{android_label(picked, probe)} → #{target.label} · #{mode.to_s.downcase} CA"
        ok = android_run(adb, plan, dry_run)
        # The port spelled out: a setup that failed before the proxy step left a reverse mapping
        # that a plain undo, reading the port off the device's proxy, cannot find.
        STDERR.puts "  gori run android undo --serial #{picked.serial} --device-port #{device_port || target.port} reverts the steps that ran" unless ok
        return ok unless ok && !dry_run
        if mode.system?
          STDERR.puts "  gori's CA (#{hash}.0) is a system CA until the device reboots · undo: gori run android undo"
        else
          STDERR.puts "  install #{Android::USER_CA_PATH} under Settings → Security → Encryption & credentials → " \
                      "Install a certificate → CA certificate"
          STDERR.puts "  apps targeting API 24+ trust a user CA only if their network security config opts in; " \
                      "use --system on an emulator for the rest"
        end
        true
      end

      # The flag combinations that cannot mean anything, as one sentence (nil when fine).
      def self.android_usage_error(verb : String?, extra : Array(String), user : Bool, system : Bool,
                                   port_arg : String?, proxy : String?, project_name : String?,
                                   db_path : String?, ca_dir : String?) : String?
        prefix = "gori run android"
        unless verb.in?("devices", "setup", "undo")
          return verb ? unknown_verb_message(prefix, verb, %w[devices setup undo]) : "#{prefix}: name a subcommand: devices, setup or undo"
        end
        return "#{prefix}: unexpected argument #{extra.join(" ").inspect}" unless extra.empty?
        return "#{prefix}: pass --user or --system, not both" if user && system
        if verb != "setup"
          given = {"--user" => user, "--system" => system, "--proxy" => proxy, "--project" => project_name,
                   "--db" => db_path, "--ca-dir" => ca_dir}.compact_map { |flag, v| flag if v }
          return "#{prefix}: #{given.first} only applies to setup" unless given.empty?
        end
        if (v = port_arg) && !v.to_i?.try(&.in?(1..65_535))
          return "#{prefix}: --device-port expects 1-65535, got #{v.inspect}"
        end
        target_flags_error(prefix, proxy, project_name, db_path)
      end

      # `--serial` among the connected devices, else the only usable one. A String is the refusal.
      def self.android_device(devices : Array(Android::Device), serial : String?) : Android::Device | String
        if serial
          found = devices.find { |d| d.serial == serial } || return "no device #{serial.inspect} (gori run android devices lists them)"
          return found.ready? ? found : "#{serial} is #{found.state} — #{android_state_hint(found.state)}"
        end
        ready = devices.select(&.ready?)
        return ready.first if ready.size == 1
        return "#{ready.size} devices connected — pick one with --serial (#{ready.join(", ", &.serial)})" if ready.size > 1
        if other = devices.first?
          return "#{other.serial} is #{other.state} — #{android_state_hint(other.state)}"
        end
        Android::NO_DEVICE
      end

      private def self.android_state_hint(state : String) : String
        case state
        when "unauthorized"   then "accept the USB debugging prompt on the device"
        when "no permissions" then "this user cannot open the USB device (check its udev rules)"
        else                       "wait for it, or reconnect it"
        end
      end

      private def self.android_label(d : Android::Device, probe : Android::Probe) : String
        ([d.serial, d.model].compact + android_flags(probe)).join(" · ")
      end

      private def self.android_flags(probe : Android::Probe) : Array(String)
        flags = probe.sdk ? ["api=#{probe.sdk}"] : [] of String
        flags << "emulator" if probe.emulator
        flags << "root" if probe.root
        flags
      end

      private def self.android_devices(adb : String, devices : Array(Android::Device)) : Nil
        if devices.empty?
          STDERR.puts Android::NO_DEVICE
          return
        end
        devices.each do |d|
          unless d.ready?
            puts "#{d.serial}\t#{d.state}\t#{d.model || "-"}"
            next
          end
          flags = android_flags(Android.probe(adb, d.serial, try_su: false)) rescue [] of String
          puts "#{d.serial}\t#{d.state}\t#{d.model || "-"}\t#{flags.join(",")}"
        end
      end

      # Print each step, and unless `dry_run` run them; true when no fatal step failed.
      private def self.android_run(adb : String, steps : Array(Android::Step), dry_run : Bool) : Bool
        if dry_run
          steps.each { |s| STDERR.puts "  #{s.what}\n    $ #{s.command}" }
          return true
        end
        Android.run(adb, steps) do |o|
          mark = o.ok ? "✓" : (o.step.fatal ? "✗" : "·")
          STDERR.puts "  #{mark} #{o.step.what}#{o.ok ? "" : " — #{o.detail}"}"
        end.none?(&.fatal_failure?)
      end
    end
  end
end
