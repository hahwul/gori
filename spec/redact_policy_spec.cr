require "./spec_helper"
require "../src/gori/redact/policy"

# `Settings.redaction_*` is process-wide state that every other example in the suite reads
# through `Redact::Policy`, so each example here puts back exactly what it found — and the
# salt with it, since `arm_redaction` mints one on first use.
private def with_global(profiles = [] of Gori::Redact::Profile, active = "", default = false, &)
  prev_profiles = Gori::Settings.redaction_profiles
  prev_active = Gori::Settings.redaction_active
  prev_default = Gori::Settings.redaction_default?
  prev_salt = Gori::Redact.salt
  Gori::Settings.redaction_profiles = profiles
  Gori::Settings.redaction_active = active
  Gori::Settings.redaction_default = default
  begin
    yield
  ensure
    Gori::Settings.redaction_profiles = prev_profiles
    Gori::Settings.redaction_active = prev_active
    Gori::Settings.redaction_default = prev_default
    Gori::Redact.salt = prev_salt
  end
end

private def profile(name, field = "password")
  Gori::Redact::Profile.new(name: name, json_fields: [field])
end

describe Gori::Redact::Policy do
  describe "the scope fold" do
    it "lists project profiles first, then global, then the built-ins" do
      with_store do |store|
        with_global([profile("mine")]) do
          Gori::Redact::Policy.write_project_scope(store,
            Gori::Redact::Policy::ProjectScope.new(profiles: [profile("theirs")]))
          Gori::Redact::Policy.names(store).should eq ["theirs", "mine", "default"]
        end
      end
    end

    it "lets a project profile shadow a global one of the same name" do
      with_store do |store|
        with_global([profile("shared", "global_only")]) do
          Gori::Redact::Policy.write_project_scope(store,
            Gori::Redact::Policy::ProjectScope.new(profiles: [profile("shared", "project_only")]))
          found = Gori::Redact::Policy.profile(store, "shared").not_nil!
          found.json_fields.should eq ["project_only"]
          Gori::Redact::Policy.names(store).count("shared").should eq 1
        end
      end
    end

    it "lets a user profile shadow a built-in of the same name" do
      with_global([profile("default", "only_this")]) do
        Gori::Redact::Policy.profile(nil, "default").not_nil!.json_fields.should eq ["only_this"]
      end
    end

    it "degrades to the global config when the project row is not parseable" do
      with_store do |store|
        store.set_setting(Gori::Store::REDACTION_KEY, "{not json")
        with_global { Gori::Redact::Policy.names(store).should eq ["default"] }
      end
    end

    it "round-trips a written project scope" do
      with_store do |store|
        written = Gori::Redact::Policy::ProjectScope.new(
          active: "p", default: false,
          profiles: [Gori::Redact::Profile.new("p", "why", ["f"], ["/a/b"], ["k"], ["r[0-9]"])])
        Gori::Redact::Policy.write_project_scope(store, written).should be_true
        read = Gori::Redact::Policy.project_scope(store)
        read.active.should eq "p"
        read.default.should be_false
        read.profiles.first.should eq written.profiles.first
      end
    end

    it "deletes the row when every field is back at its default" do
      with_store do |store|
        Gori::Redact::Policy.write_project_scope(store,
          Gori::Redact::Policy::ProjectScope.new(active: "x"))
        Gori::Redact::Policy.write_project_scope(store, Gori::Redact::Policy::ProjectScope.new)
        store.setting(Gori::Store::REDACTION_KEY).should be_nil
      end
    end
  end

  describe "resolve" do
    it "is off when nothing asks for it" do
      with_global { Gori::Redact::Policy.resolve(nil).on?.should be_false }
    end

    it "is on when the global default says so" do
      with_global(default: true) do
        Gori::Redact::Policy.resolve(nil).matcher.not_nil!.profile.name.should eq "default"
      end
    end

    it "lets a project turn a global default OFF for one engagement" do
      with_store do |store|
        with_global(default: true) do
          Gori::Redact::Policy.write_project_scope(store,
            Gori::Redact::Policy::ProjectScope.new(default: false))
          Gori::Redact::Policy.resolve(store).on?.should be_false
        end
      end
    end

    it "lets a project turn redaction on where the global config has not" do
      with_store do |store|
        with_global do
          Gori::Redact::Policy.write_project_scope(store,
            Gori::Redact::Policy::ProjectScope.new(default: true))
          Gori::Redact::Policy.resolve(store).on?.should be_true
        end
      end
    end

    it "treats naming a profile as asking for redaction" do
      with_global([profile("strict")]) do
        Gori::Redact::Policy.resolve(nil, "strict").matcher.not_nil!.profile.name.should eq "strict"
      end
    end

    it "obeys --no-redact over every configured default" do
      with_global([profile("strict")], active: "strict", default: true) do
        Gori::Redact::Policy.resolve(nil, "strict", false).on?.should be_false
      end
    end

    it "refuses an unknown profile rather than exporting raw" do
      with_global do
        choice = Gori::Redact::Policy.resolve(nil, "nope")
        choice.on?.should be_false
        choice.error.not_nil!.should contain "no redaction profile named \"nope\""
        choice.error.not_nil!.should contain "have: default"
      end
    end

    it "refuses a profile with no rules, which would sanitize nothing" do
      with_global([Gori::Redact::Profile.new("hollow")]) do
        Gori::Redact::Policy.resolve(nil, "hollow").error.not_nil!
          .should contain "has no rules"
      end
    end

    it "refuses when the CONFIGURED active profile has been deleted" do
      # Not a silent fall back to the built-in: the operator picked a profile, and quietly
      # sanitizing with a different set of rules than the one they named is the failure mode
      # this whole feature is about.
      with_global(active: "deleted", default: true) do
        Gori::Redact::Policy.resolve(nil).error.not_nil!.should contain "deleted"
      end
    end

    it "arms the engine, so the matcher it hands back can mint a placeholder" do
      with_global(default: true) do
        Gori::Redact.salt = ""
        Gori::Redact::Policy.resolve(nil).on?.should be_true
        Gori::Redact.salt.should_not be_empty
        Gori::Redact.placeholder("x").should start_with "[REDACTED:"
      end
    end
  end
end
