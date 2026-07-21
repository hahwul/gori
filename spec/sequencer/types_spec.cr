require "../spec_helper"

private alias Q = Gori::Sequencer

# A configurable Config so max_sends clamp math can be exercised without repeating
# the long positional/keyword initializer at every call site.
private def config(goal : Int32 = 500, max_requests : Int64? = nil) : Q::Config
  Q::Config.new(goal: goal, max_requests: max_requests)
end

describe Gori::Sequencer::Mode do
  describe ".parse?" do
    it "maps the LiveReplay aliases" do
      Q::Mode.parse?("live").should eq(Q::Mode::LiveReplay)
      Q::Mode.parse?("replay").should eq(Q::Mode::LiveReplay)
      Q::Mode.parse?("live-replay").should eq(Q::Mode::LiveReplay)
      Q::Mode.parse?("l").should eq(Q::Mode::LiveReplay)
    end

    it "maps the Manual aliases" do
      Q::Mode.parse?("manual").should eq(Q::Mode::Manual)
      Q::Mode.parse?("paste").should eq(Q::Mode::Manual)
      Q::Mode.parse?("m").should eq(Q::Mode::Manual)
    end

    it "is case-insensitive and whitespace-insensitive" do
      Q::Mode.parse?(" LIVE ").should eq(Q::Mode::LiveReplay)
      Q::Mode.parse?("Manual").should eq(Q::Mode::Manual)
      Q::Mode.parse?("\tLive-Replay\n").should eq(Q::Mode::LiveReplay)
      Q::Mode.parse?("PASTE").should eq(Q::Mode::Manual)
    end

    it "returns nil for unknown, empty, and multibyte tokens" do
      Q::Mode.parse?("nope").should be_nil
      Q::Mode.parse?("").should be_nil
      Q::Mode.parse?("   ").should be_nil
      Q::Mode.parse?("안녕").should be_nil
      Q::Mode.parse?("世界🌍").should be_nil
      # a prefix of a valid alias must not match (whole-token only)
      Q::Mode.parse?("liv").should be_nil
      Q::Mode.parse?("live replay").should be_nil # space, not hyphen
    end
  end

  describe "#label" do
    it "renders a human label per value" do
      Q::Mode::LiveReplay.label.should eq("live replay")
      Q::Mode::Manual.label.should eq("manual")
    end
  end
end

describe Gori::Sequencer::ExtractKind do
  describe ".parse?" do
    it "maps every alias including single-letter forms" do
      Q::ExtractKind.parse?("cookie").should eq(Q::ExtractKind::Cookie)
      Q::ExtractKind.parse?("c").should eq(Q::ExtractKind::Cookie)
      Q::ExtractKind.parse?("header").should eq(Q::ExtractKind::Header)
      Q::ExtractKind.parse?("h").should eq(Q::ExtractKind::Header)
      Q::ExtractKind.parse?("regex").should eq(Q::ExtractKind::Regex)
      Q::ExtractKind.parse?("re").should eq(Q::ExtractKind::Regex)
      Q::ExtractKind.parse?("r").should eq(Q::ExtractKind::Regex)
      Q::ExtractKind.parse?("position").should eq(Q::ExtractKind::Position)
      Q::ExtractKind.parse?("pos").should eq(Q::ExtractKind::Position)
      Q::ExtractKind.parse?("p").should eq(Q::ExtractKind::Position)
      Q::ExtractKind.parse?("jsonpath").should eq(Q::ExtractKind::JsonPath)
      Q::ExtractKind.parse?("json").should eq(Q::ExtractKind::JsonPath)
      Q::ExtractKind.parse?("j").should eq(Q::ExtractKind::JsonPath)
    end

    it "disambiguates 'r' to Regex (not Position's 'r')" do
      Q::ExtractKind.parse?("r").should eq(Q::ExtractKind::Regex)
    end

    it "is case-insensitive and whitespace-insensitive" do
      Q::ExtractKind.parse?(" COOKIE ").should eq(Q::ExtractKind::Cookie)
      Q::ExtractKind.parse?("JsonPath").should eq(Q::ExtractKind::JsonPath)
      Q::ExtractKind.parse?("\tPOS\n").should eq(Q::ExtractKind::Position)
    end

    it "returns nil for unknown, empty, and multibyte tokens" do
      Q::ExtractKind.parse?("nope").should be_nil
      Q::ExtractKind.parse?("").should be_nil
      Q::ExtractKind.parse?("   ").should be_nil
      Q::ExtractKind.parse?("cook").should be_nil
      Q::ExtractKind.parse?("안녕").should be_nil
      Q::ExtractKind.parse?("🍪").should be_nil
    end
  end

  describe "#label" do
    it "renders a human label per value" do
      Q::ExtractKind::Cookie.label.should eq("cookie")
      Q::ExtractKind::Header.label.should eq("header")
      Q::ExtractKind::Regex.label.should eq("regex")
      Q::ExtractKind::Position.label.should eq("position")
      Q::ExtractKind::JsonPath.label.should eq("jsonpath")
    end
  end
end

describe Gori::Sequencer::TokenLoc do
  describe "#label" do
    it "quotes the cookie selector via inspect" do
      Q::TokenLoc.new(Q::ExtractKind::Cookie, "SESSIONID").label.should eq(%(cookie "SESSIONID"))
      # the .cookie factory produces the same value
      Q::TokenLoc.cookie("SESSIONID").label.should eq(%(cookie "SESSIONID"))
      # empty selector still renders quoted
      Q::TokenLoc.new(Q::ExtractKind::Cookie).label.should eq(%(cookie ""))
    end

    it "renders the header selector bare" do
      Q::TokenLoc.new(Q::ExtractKind::Header, "X-Csrf-Token").label.should eq("header X-Csrf-Token")
    end

    it "wraps the regex source in slashes" do
      Q::TokenLoc.new(Q::ExtractKind::Regex, %("token":"(\\w+)")).label
        .should eq(%(regex /"token":"(\\w+)"/))
    end

    it "renders a half-open byte range for Position" do
      Q::TokenLoc.new(Q::ExtractKind::Position, "", 4, 20).label.should eq("body[4...20]")
      # default zero range
      Q::TokenLoc.new(Q::ExtractKind::Position).label.should eq("body[0...0]")
    end

    it "renders the jsonpath selector bare" do
      Q::TokenLoc.new(Q::ExtractKind::JsonPath, "data.token").label.should eq("jsonpath data.token")
    end

    it "handles a multibyte selector without mangling" do
      Q::TokenLoc.new(Q::ExtractKind::Header, "X-안녕").label.should eq("header X-안녕")
      Q::TokenLoc.new(Q::ExtractKind::Cookie, "세션🍪").label.should eq(%(cookie "세션🍪"))
    end
  end

  it "has value equality across identical records" do
    Q::TokenLoc.new(Q::ExtractKind::Cookie, "a", 1, 2)
      .should eq(Q::TokenLoc.new(Q::ExtractKind::Cookie, "a", 1, 2))
    Q::TokenLoc.cookie("a").should eq(Q::TokenLoc.new(Q::ExtractKind::Cookie, "a"))
  end
end

describe Gori::Sequencer::NotifyMode do
  describe ".parse?" do
    it "maps the WhenDone aliases" do
      Q::NotifyMode.parse?("when-done").should eq(Q::NotifyMode::WhenDone)
      Q::NotifyMode.parse?("whendone").should eq(Q::NotifyMode::WhenDone)
      Q::NotifyMode.parse?("done").should eq(Q::NotifyMode::WhenDone)
    end

    it "maps the Off aliases" do
      Q::NotifyMode.parse?("off").should eq(Q::NotifyMode::Off)
      Q::NotifyMode.parse?("none").should eq(Q::NotifyMode::Off)
      Q::NotifyMode.parse?("no").should eq(Q::NotifyMode::Off)
    end

    it "maps the Always aliases" do
      Q::NotifyMode.parse?("always").should eq(Q::NotifyMode::Always)
      Q::NotifyMode.parse?("on").should eq(Q::NotifyMode::Always)
      Q::NotifyMode.parse?("all").should eq(Q::NotifyMode::Always)
    end

    it "normalizes internal spaces and underscores to hyphens" do
      Q::NotifyMode.parse?("when done").should eq(Q::NotifyMode::WhenDone)
      Q::NotifyMode.parse?("when_done").should eq(Q::NotifyMode::WhenDone)
      Q::NotifyMode.parse?("when   done").should eq(Q::NotifyMode::WhenDone)
      Q::NotifyMode.parse?("when__done").should eq(Q::NotifyMode::WhenDone)
      Q::NotifyMode.parse?("when \t_ done").should eq(Q::NotifyMode::WhenDone)
    end

    it "is case-insensitive and trims surrounding whitespace" do
      Q::NotifyMode.parse?("  WHEN-DONE  ").should eq(Q::NotifyMode::WhenDone)
      Q::NotifyMode.parse?("Always").should eq(Q::NotifyMode::Always)
      Q::NotifyMode.parse?("OFF").should eq(Q::NotifyMode::Off)
    end

    it "returns nil for unknown, empty, and multibyte tokens" do
      Q::NotifyMode.parse?("nope").should be_nil
      Q::NotifyMode.parse?("").should be_nil
      Q::NotifyMode.parse?("   ").should be_nil
      Q::NotifyMode.parse?("안녕").should be_nil
      Q::NotifyMode.parse?("🔔").should be_nil
    end

    it "round-trips every value through its token" do
      Q::NotifyMode.values.each do |m|
        Q::NotifyMode.parse?(m.token).should eq(m)
      end
    end
  end

  describe "#token and #label" do
    it "renders the machine token per value" do
      Q::NotifyMode::WhenDone.token.should eq("when-done")
      Q::NotifyMode::Off.token.should eq("off")
      Q::NotifyMode::Always.token.should eq("always")
    end

    it "renders the human label per value" do
      Q::NotifyMode::WhenDone.label.should eq("when done")
      Q::NotifyMode::Off.label.should eq("off")
      Q::NotifyMode::Always.label.should eq("always")
    end
  end

  describe "#posts_notification?" do
    it "Off never posts, even on error" do
      Q::NotifyMode::Off.posts_notification?(0).should be_false
      Q::NotifyMode::Off.posts_notification?(100).should be_false
      Q::NotifyMode::Off.posts_notification?(0, error: true).should be_false
      Q::NotifyMode::Off.posts_notification?(100, error: true).should be_false
    end

    it "WhenDone posts only when something was collected or an error occurred" do
      Q::NotifyMode::WhenDone.posts_notification?(0).should be_false
      Q::NotifyMode::WhenDone.posts_notification?(1).should be_true
      Q::NotifyMode::WhenDone.posts_notification?(0, error: true).should be_true
      Q::NotifyMode::WhenDone.posts_notification?(500).should be_true
    end

    it "Always posts even at zero collected" do
      Q::NotifyMode::Always.posts_notification?(0).should be_true
      Q::NotifyMode::Always.posts_notification?(0, error: false).should be_true
      Q::NotifyMode::Always.posts_notification?(9999).should be_true
    end
  end
end

describe Gori::Sequencer::Config do
  it "exposes GOAL_CEILING as 50_000" do
    Q::Config::GOAL_CEILING.should eq(50_000)
  end

  it "defaults to LiveReplay, goal 500, and WhenDone notify" do
    c = Q::Config.new
    c.mode.should eq(Q::Mode::LiveReplay)
    c.goal.should eq(500)
    c.notify.should eq(Q::NotifyMode::WhenDone)
    c.token_loc.kind.should eq(Q::ExtractKind::Cookie)
  end

  describe "#max_sends" do
    it "defaults to twice the goal when no explicit cap" do
      config(goal: 500).max_sends.should eq(1000_i64)
      config(goal: 1).max_sends.should eq(2_i64)
    end

    it "clamps twice-the-goal to the GOAL_CEILING" do
      # 30000*2 = 60000 -> clamped down to 50_000
      config(goal: 30_000).max_sends.should eq(50_000_i64)
      # exactly at the ceiling boundary: 25000*2 = 50000
      config(goal: 25_000).max_sends.should eq(50_000_i64)
      # just under: 24999*2 = 49998
      config(goal: 24_999).max_sends.should eq(49_998_i64)
      # goal exactly at the ceiling: clamp min==max is valid, stays at 50_000
      config(goal: 50_000).max_sends.should eq(50_000_i64)
    end

    it "honors an explicit positive max_requests exactly" do
      config(goal: 500, max_requests: 42_i64).max_sends.should eq(42_i64)
      # an explicit cap may exceed the goal-derived ceiling
      config(goal: 500, max_requests: 1_000_000_i64).max_sends.should eq(1_000_000_i64)
      # or be far below the goal
      config(goal: 500, max_requests: 3_i64).max_sends.should eq(3_i64)
    end

    it "falls back to twice-the-goal for a non-positive max_requests" do
      config(goal: 500, max_requests: 0_i64).max_sends.should eq(1000_i64)
      config(goal: 500, max_requests: -5_i64).max_sends.should eq(1000_i64)
    end
  end
end
