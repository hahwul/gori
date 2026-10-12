require "./spec_helper"
require "file_utils"

# `Gori::Android` (#1600). The plans are pure, so what a device gets is pinned here argv by
# argv; only `run` touches a process, and a stand-in adb plays the device.

# `openssl x509 -subject_hash_old` prints c317345c for this one.
private SPEC_CA = <<-PEM
  -----BEGIN CERTIFICATE-----
  MIIBgzCCASigAwIBAgIUKrWW7AqQ+kIN+md02x9hWYiTBuswCgYIKoZIzj0EAwIw
  JjEVMBMGA1UEAwwMZ29yaSBzcGVjIENBMQ0wCwYDVQQKDARnb3JpMCAXDTI2MTAx
  MjA0NTQyMVoYDzIxMjYwOTE4MDQ1NDIxWjAmMRUwEwYDVQQDDAxnb3JpIHNwZWMg
  Q0ExDTALBgNVBAoMBGdvcmkwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATimVBa
  AnYLAuo3N8V61rtP03aa1lFbPKaGOIin7eSbT2o0S4RgphRIETOp8jQItgNHAkeg
  oJxiCbiGzcgPM4LAozIwMDAdBgNVHQ4EFgQUe/tmyLv8LbztTsAlnl/pgpa0sO0w
  DwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNJADBGAiEA9d/taXRszL84QnDW
  qWXhRzy8Vcl9KsIbNtNBY4O9g7ECIQCAHYdyFfvV4KNGE1LJrdOElGgp7ChPUNtn
  oXoJmtuWJw==
  -----END CERTIFICATE-----
  PEM

private def probe(sdk = 33, root : Gori::Android::Root? = Gori::Android::Root::Su0) : Gori::Android::Probe
  Gori::Android::Probe.new(sdk, true, root, nil)
end

private def setup(mode, p = probe) : Array(Gori::Android::Step) | String
  Gori::Android.plan_setup("emulator-5554", 8071, 8070, "/ca/ca.crt", "c317345c", mode, p)
end

describe Gori::Android do
  it "names the CA file by the subject hash openssl's -subject_hash_old prints" do
    path = File.tempname("gori-android-ca", ".crt")
    File.write(path, SPEC_CA)
    Gori::Proxy::Tls::Cert.read_pem(path).subject_hash_old.should eq("c317345c")
  ensure
    path.try { |p| File.delete?(p) }
  end

  it "parses adb devices -l, skipping the header and daemon notices" do
    text = <<-OUT
      adb server version (40) doesn't match this client (41); killing...
      * daemon not running; starting now at tcp:5037
      * daemon started successfully
      List of devices attached
      emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
      R58M42ABCDE            unauthorized usb:1-1 transport_id:3
      0123456789ABCDEF       offline transport_id:4
      ZY22                   no permissions (user in plugdev group; are your udev rules wrong?); see [http://developer.android.com/tools/device.html]

      OUT
    devices = Gori::Android.parse_devices(text)
    devices.map(&.serial).should eq(%w[emulator-5554 R58M42ABCDE 0123456789ABCDEF ZY22])
    devices[3].state.should eq("no permissions")
    devices[0].model.should eq("sdk_gphone64_arm64")
    devices[0].ready?.should be_true
    devices[1].state.should eq("unauthorized")
    devices[1].model.should be_nil
  end

  it "reads the probe's lines, with adbd as root only when id -u says 0" do
    p = Gori::Android.parse_probe("34\n\n1\n2000\n127.0.0.1:8070\n")
    p.sdk.should eq(34)
    p.emulator.should be_true
    p.root.should be_nil
    p.http_proxy.should eq("127.0.0.1:8070")
    root = Gori::Android.parse_probe("33\n1\n\n0\nnull\n")
    root.root.should eq(Gori::Android::Root::Adbd)
    root.http_proxy.should be_nil
    Gori::Android.parse_probe("").sdk.should be_nil
  end

  it "plans a user setup: the CA first, the proxy last, then verify" do
    steps = setup(Gori::Android::Mode::User).as(Array(Gori::Android::Step))
    steps.map(&.args).should eq([
      %w[-s emulator-5554 push /ca/ca.crt /sdcard/Download/gori-ca.crt],
      %w[-s emulator-5554 shell am start -a android.settings.SECURITY_SETTINGS],
      %w[-s emulator-5554 reverse tcp:8071 tcp:8070],
      %w[-s emulator-5554 shell settings put global http_proxy 127.0.0.1:8071],
      %w[-s emulator-5554 shell settings get global http_proxy],
    ])
    steps[1].fatal.should be_false
    steps.last.expect.should eq("127.0.0.1:8071")
  end

  it "plans a system setup as root: a tmpfs over cacerts with <hash>.0 added" do
    steps = setup(Gori::Android::Mode::System).as(Array(Gori::Android::Step))
    steps[0].args.should eq(%w[-s emulator-5554 push /ca/ca.crt /data/local/tmp/gori-c317345c.0])
    root = steps[1].args.last
    root.should start_with("su 0 sh -c 'set -e; ")
    root.should end_with("echo gori-ok'")
    root.should contain("mount -t tmpfs tmpfs /system/etc/security/cacerts")
    root.should contain("mv /data/local/tmp/gori-c317345c.0 /system/etc/security/cacerts/c317345c.0")
    # A failure after the mount takes the half-filled store back down.
    root.should contain("else umount /system/etc/security/cacerts;")
    root.should contain("/data/local/tmp/gori-cacerts-$$")
    steps[1].expect.should eq("gori-ok")
    steps[3].args.should eq(%w[-s emulator-5554 shell settings put global http_proxy 127.0.0.1:8071])
    setup(Gori::Android::Mode::System, probe(root: Gori::Android::Root::SuC))
      .as(Array(Gori::Android::Step))[1].args.last.should start_with("su -c 'set -e; ")
  end

  it "never escalates: system needs root, and Android 14+ is refused until its APEX step exists" do
    setup(Gori::Android::Mode::System, probe(root: nil)).as(String).should contain("needs root")
    setup(Gori::Android::Mode::System, probe(sdk: 34)).as(String).should contain("Android 14+")
    # A rooted device asked for --user gets the user steps, not the root ones.
    setup(Gori::Android::Mode::User).as(Array(Gori::Android::Step)).none?(&.args.last.includes?("su ")).should be_true
  end

  it "plans an undo that is best-effort after the proxy reset, so it is safe to repeat" do
    steps = Gori::Android.plan_undo("emulator-5554", 8071, Gori::Android::Root::Adbd)
    steps.map(&.args).should eq([
      %w[-s emulator-5554 shell settings put global http_proxy :0],
      %w[-s emulator-5554 reverse --remove tcp:8071],
      %w[-s emulator-5554 shell rm -f /sdcard/Download/gori-ca.crt],
      ["-s", "emulator-5554", "shell",
       %(if [ "$(cat /data/local/tmp/gori-system-ca 2>/dev/null)" = "$(cat /proc/sys/kernel/random/boot_id)" ] && ) +
       %(grep -q " /system/etc/security/cacerts tmpfs " /proc/mounts; then umount /system/etc/security/cacerts; fi; ) +
       %(rm -f /data/local/tmp/gori-system-ca)],
    ])
    steps.map(&.fatal).should eq([true, false, false, false])
    Gori::Android.plan_undo("emulator-5554", nil, nil).size.should eq(2)
  end

  it "reads the mapped port back from the proxy it set" do
    Gori::Android.mapped_port("127.0.0.1:8071").should eq(8071)
    Gori::Android.mapped_port("10.0.2.2:8070").should be_nil
    Gori::Android.mapped_port(":0").should be_nil
    Gori::Android.mapped_port(nil).should be_nil
  end

  it "only reverses to a gori on this machine's loopback" do
    Gori::Android.reverse_reaches?("127.0.0.1").should be_true
    Gori::Android.reverse_reaches?("0.0.0.0").should be_true
    Gori::Android.reverse_reaches?("[::1]").should be_true
    Gori::Android.reverse_reaches?("192.168.1.5").should be_false
  end

  it "runs steps in order and stops at the first fatal failure" do
    posix_only!("a stand-in adb is a shell script")
    dir = File.tempname("gori-android-adb")
    Dir.mkdir_p(dir)
    adb = File.join(dir, "adb")
    # Echoes its last argument; `fail` exits 1, `get` prints the proxy back with stderr noise
    # after it, which must not count against `expect`.
    File.write(adb, <<-SH)
      #!/bin/sh
      for a; do last=$a; done
      case "$last" in
        fail) echo "error: boom" >&2; exit 1 ;;
        get) echo 127.0.0.1:8071; echo "WARNING: linker: unused DT entry" >&2 ;;
        *) echo "$last" ;;
      esac
      SH
    File.chmod(adb, 0o755)
    steps = [
      Gori::Android::Step.new(%w[get], "check", expect: "127.0.0.1:8071"),
      Gori::Android::Step.new(%w[fail], "soft", fatal: false),
      Gori::Android::Step.new(%w[other], "expects", expect: "nope"),
      Gori::Android::Step.new(%w[never], "unreached"),
    ]
    seen = [] of String
    outcomes = Gori::Android.run(adb, steps) { |o| seen << o.step.what }
    seen.should eq(%w[check soft expects])
    outcomes.map(&.ok).should eq([true, false, false])
    outcomes[1].detail.should eq("error: boom")
    outcomes[2].detail.should eq(%(got "other"))
  ensure
    dir.try { |d| FileUtils.rm_rf(d) }
  end
end
