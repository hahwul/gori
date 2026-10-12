require "../../spec_helper"

# `gori run android` (#1600). The steps are `Android`'s (spec/android_spec.cr) and the capture
# lookup is `gori run shell`'s; pinned here are the flag refusals and the device pick.

private def usage(verb, user = false, system = false, port = nil, proxy = nil, project = nil, extra = [] of String)
  Gori::CLI::Run.android_usage_error(verb, extra, user, system, port, proxy, project, nil, nil)
end

private def device(serial, state = "device")
  Gori::Android::Device.new(serial, state, nil)
end

describe "gori run android" do
  it "accepts each verb with its own flags" do
    usage("devices").should be_nil
    usage("setup", system: true, port: "8071").should be_nil
    usage("undo", port: "8071").should be_nil
  end

  it "refuses what cannot mean anything" do
    usage(nil).not_nil!.should contain("devices, setup or undo")
    usage("setpu").not_nil!.should contain("did you mean 'setup'")
    usage("setup", user: true, system: true).not_nil!.should contain("not both")
    usage("undo", system: true).not_nil!.should contain("--system only applies to setup")
    usage("devices", proxy: "127.0.0.1:8070").not_nil!.should contain("--proxy only applies to setup")
    usage("setup", port: "0").not_nil!.should contain("1-65535")
    usage("setup", proxy: "127.0.0.1:8070", project: "demo").not_nil!.should contain("not both")
    usage("setup", extra: ["now"]).not_nil!.should contain("unexpected argument")
  end

  it "picks --serial, else the only ready device, and says why when it cannot" do
    one = [device("emulator-5554"), device("R58", "unauthorized")]
    Gori::CLI::Run.android_device(one, nil).as(Gori::Android::Device).serial.should eq("emulator-5554")
    Gori::CLI::Run.android_device(one, "R58").as(String).should contain("accept the USB debugging prompt")
    Gori::CLI::Run.android_device(one, "nope").as(String).should contain("no device \"nope\"")
    two = [device("emulator-5554"), device("emulator-5556")]
    Gori::CLI::Run.android_device(two, nil).as(String).should contain("pick one with --serial")
    Gori::CLI::Run.android_device([] of Gori::Android::Device, nil).as(String).should contain("no device connected")
  end
end
