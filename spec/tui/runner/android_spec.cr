require "../../spec_helper"
require "file_utils"

class Gori::Tui::Runner
  def stop_android_for_spec(jobs : Gori::Tui::Jobs, cancelled : Array(Bool)) : Nil
    @jobs = jobs
    @android_cancel = cancelled
    stop_android
  end
end

describe "Runner Android lifecycle" do
  it "stops the worker and finishes its job without stopping unrelated jobs" do
    jobs = Gori::Tui::Jobs.new
    android = jobs.start(:android, "fixture")
    other = jobs.start(:fuzz, "fixture")
    cancelled = [false]
    Gori::Tui::Runner.allocate.stop_android_for_spec(jobs, cancelled)
    cancelled[0].should be_true
    jobs.active.map(&.id).should eq([other])
    jobs.active.map(&.id).should_not contain(android)
  end

  it "does not begin setup or undo commands when cancelled during the probe" do
    posix_only!("the stand-in adb is a shell script")
    root = File.tempname("gori-android-cancel")
    Dir.mkdir_p(root)
    trace = File.join(root, "trace")
    adb = File.join(root, "adb")
    File.write(adb, "#!/bin/sh\necho call >> #{Process.quote_posix(trace)}\nprintf '33\\n0\\n0\\n0\\nnull\\n'\n")
    File.chmod(adb, 0o755)
    ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "ca"))
    {Gori::Android::Mode::User, Gori::Android::Mode::System, nil}.each do |mode|
      File.delete?(trace)
      expect_raises(Gori::Error, "Android operation stopped") do
        Gori::Tui::Runner.android_task(adb, "fixture", mode, 8070, ca.ca_cert_path,
          cancelled: -> { File.exists?(trace) })
      end
      File.read(trace).lines.should eq(["call"])
    end
  ensure
    root.try { |dir| FileUtils.rm_rf(dir) }
  end
end
