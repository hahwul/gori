require "./spec_helper"

private alias I18n = Gori::I18n

# A catalog with the shapes the shipped one will carry, installed under "ko" so these examples
# do not depend on what has been translated so far.
private SYNTHETIC = {
  "ui" => {
    "History"             => "히스토리",
    "sent → %{host}"      => "%{host}(으)로 전송",
    "%{n} flow"           => "플로우 %{n}개",
    "%{n} flows"          => "플로우 %{n}개",
    "empty"               => "",
    "broken %{missing}"   => "%{nope}",
    "100%% done, %{name}" => "%{name}, 100%% 완료",
  },
  "system"    => {"settings saved" => "설정 저장됨"},
  "companion" => {"hi! ready when you are" => "안녕! 준비되면 시작해요"},
}

private NO_ENV = {} of String => String

private def with_synthetic_ko(default = "ko", overrides = {} of I18n::Domain => String, &)
  I18n.install("ko", SYNTHETIC)
  I18n.apply(default, overrides, env: NO_ENV)
  yield
ensure
  I18n.reset_catalogs!
  I18n.apply("en", env: NO_ENV)
end

describe Gori::I18n do
  it "knows its languages by code and endonym" do
    I18n.codes.should eq(["en", "ko"])
    I18n.known?("ko").should be_true
    I18n.known?("fr").should be_false
    I18n.endonym("ko").should eq("한국어")
    I18n.endonym("xx").should eq("xx")
    I18n::Domain::System.key.should eq("system")
    I18n::Domain::Companion.key.should eq("companion")
  end

  describe ".t" do
    it "is the identity under English, for every domain" do
      I18n.apply("en", env: NO_ENV)
      I18n::Domain.values.each { |d| I18n.locale_for(d).should eq("en") }
      I18n.ui("History").should eq("History")
      I18n.sys("settings saved").should eq("settings saved")
      I18n.help("anything at all").should eq("anything at all")
      I18n.ring("hi! ready when you are").should eq("hi! ready when you are")
    end

    it "looks a msgid up in the domain's own slice" do
      with_synthetic_ko do
        I18n.ui("History").should eq("히스토리")
        I18n.sys("settings saved").should eq("설정 저장됨")
        I18n.ring("hi! ready when you are").should eq("안녕! 준비되면 시작해요")
        # The same English under another domain is a different key.
        I18n.sys("History").should eq("History")
      end
    end

    it "falls back to the msgid when the entry is missing or empty" do
      with_synthetic_ko do
        I18n.ui("no such string").should eq("no such string")
        I18n.ui("empty").should eq("empty")
      end
    end

    it "records what fell back, for the specs that want to know" do
      with_synthetic_ko do
        seen = I18n.collect_missing do
          I18n.ui("History")
          I18n.ui("no such string")
          I18n.sys("nor this")
        end
        seen.should eq(Set{"ui:no such string", "system:nor this"})
      end
      I18n.collect_missing { I18n.ui("anything") }.should be_empty # English falls back to nothing
    end
  end

  describe "interpolation" do
    it "fills %{name} placeholders in either language" do
      I18n.sys("sent → %{host}", host: "a.test").should eq("sent → a.test")
      with_synthetic_ko { I18n.ui("sent → %{host}", host: "a.test").should eq("a.test(으)로 전송") }
    end

    it "ignores an argument the text does not use" do
      with_synthetic_ko { I18n.ui("History", host: "x").should eq("히스토리") }
    end

    it "shows the English template when a translation names a placeholder the caller did not pass" do
      with_synthetic_ko { I18n.ui("broken %{missing}", missing: "x").should eq("broken x") }
    end

    it "leaves a literal percent alone" do
      I18n.ui("100%").should eq("100%")
      I18n.ui("100%% done, %{name}", name: "you").should eq("100% done, you")
      with_synthetic_ko do
        I18n.ui("100%").should eq("100%")
        I18n.ui("100%% done, %{name}", name: "you").should eq("you, 100% 완료")
      end
    end

    it "picks the singular or plural msgid by count" do
      I18n.ui_n(1, "%{n} flow", "%{n} flows", n: 1).should eq("1 flow")
      I18n.ui_n(2, "%{n} flow", "%{n} flows", n: 2).should eq("2 flows")
      I18n.ui_n(0, "%{n} flow", "%{n} flows", n: 0).should eq("0 flows")
      with_synthetic_ko { I18n.ui_n(2, "%{n} flow", "%{n} flows", n: 2).should eq("플로우 2개") }
    end
  end

  describe ".apply" do
    it "resolves every domain to the default when nothing overrides it" do
      with_synthetic_ko do
        I18n::Domain.values.each { |d| I18n.locale_for(d).should eq("ko") }
        I18n.default_code.should eq("ko")
      end
    end

    it "lets one domain follow its own language" do
      with_synthetic_ko("ko", {I18n::Domain::System => "en"}) do
        I18n.ui("History").should eq("히스토리")
        I18n.sys("settings saved").should eq("settings saved")
        I18n.locale_for(I18n::Domain::System).should eq("en")
      end
      with_synthetic_ko("en", {I18n::Domain::Companion => "ko"}) do
        I18n.ui("History").should eq("History")
        I18n.ring("hi! ready when you are").should eq("안녕! 준비되면 시작해요")
      end
    end

    it "treats inherit and an unknown code as following the default" do
      with_synthetic_ko("ko", {I18n::Domain::Ui => "inherit", I18n::Domain::Help => "xx"}) do
        I18n.locale_for(I18n::Domain::Ui).should eq("ko")
        I18n.locale_for(I18n::Domain::Help).should eq("ko")
      end
    end

    it "treats an unknown default as English rather than raising" do
      with_synthetic_ko("xx") { I18n.locale_for(I18n::Domain::Ui).should eq("en") }
    end

    it "bumps the revision only when a language actually changed" do
      I18n.apply("en", env: NO_ENV)
      before = I18n.revision
      I18n.apply("en", env: NO_ENV).should be_false
      I18n.revision.should eq(before)
      begin
        I18n.install("ko", SYNTHETIC)
        I18n.apply("ko", env: NO_ENV).should be_true
        I18n.revision.should eq(before &+ 1)
        I18n.apply("ko", env: NO_ENV).should be_false
        I18n.revision.should eq(before &+ 1)
      ensure
        I18n.reset_catalogs!
        I18n.apply("en", env: NO_ENV)
      end
    end
  end

  describe ".resolve_auto" do
    it "reads the language subtag of the first locale variable that is set" do
      I18n.resolve_auto({"LANG" => "ko_KR.UTF-8"}).should eq("ko")
      I18n.resolve_auto({"LC_MESSAGES" => "ko"}).should eq("ko")
      I18n.resolve_auto({"LANG" => "KO_kr"}).should eq("ko")
      I18n.resolve_auto({"LANG" => "ko@hangul"}).should eq("ko")
    end

    it "honours libc precedence: GORI_LANG, LC_ALL, LC_MESSAGES, then LANG" do
      I18n.resolve_auto({"GORI_LANG" => "ko", "LC_ALL" => "en_US.UTF-8"}).should eq("ko")
      I18n.resolve_auto({"LC_ALL" => "C", "LANG" => "ko_KR"}).should eq("en")
      I18n.resolve_auto({"LC_MESSAGES" => "en_GB", "LANG" => "ko_KR"}).should eq("en")
      I18n.resolve_auto({"LC_ALL" => "", "LANG" => "ko_KR"}).should eq("ko") # empty is unset
    end

    it "answers English for C/POSIX, an unknown language, and nothing at all" do
      I18n.resolve_auto({"LANG" => "C"}).should eq("en")
      I18n.resolve_auto({"LANG" => "POSIX"}).should eq("en")
      I18n.resolve_auto({"LANG" => "fr_FR.UTF-8"}).should eq("en")
      I18n.resolve_auto(NO_ENV).should eq("en")
    end

    it "is what `auto` applies" do
      begin
        I18n.install("ko", SYNTHETIC)
        I18n.apply("auto", env: {"LANG" => "ko_KR.UTF-8"})
        I18n.ui("History").should eq("히스토리")
        I18n.default_code.should eq("ko")
        I18n.apply("auto", env: {"LANG" => "en_US.UTF-8"})
        I18n.ui("History").should eq("History")
      ensure
        I18n.reset_catalogs!
        I18n.apply("en", env: NO_ENV)
      end
    end
  end
end
