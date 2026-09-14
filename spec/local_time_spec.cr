require "./spec_helper"

# `Time#to_local` raises when the instant plus the local utc offset lands past `Time::MAX`, so a
# stored `created_at` near the far end renders in `TZ=UTC` and raises in `TZ=Asia/Seoul`. Eight
# call sites read `created_at` micros straight into `to_local`, seven of them TUI render paths
# (three failed frames trip the Runner's tick breaker and the process ends) and one a QL `date:`
# filter, which raises while FILTERING. The data half is ordinary: a HAR entry dated
# `9999-12-31T23:59:59.999Z` imports without complaint, and `spec/import/har_stream_spec.cr`
# pins that it is storable.
private FAR_FUTURE = 253_402_300_799_999_000_i64 # 9999-12-31T23:59:59.999Z
private ORDINARY   =   1_700_000_000_123_456_i64 # 2023-11-14T22:13:20.123Z

private def in_zone(tz : String, &)
  Time::Location.local = Time::Location.load(tz)
  yield
ensure
  Time::Location.local = Time::Location.load_local
end

describe Gori::LocalTime do
  # East of UTC is the half that used to raise; west of it never did. Both must answer.
  {"Asia/Seoul", "Europe/Berlin", "UTC", "America/New_York"}.each do |tz|
    it "renders a far-future instant under #{tz}" do
      in_zone(tz) do
        Gori::LocalTime.format(FAR_FUTURE, "%Y-%m-%d").should contain("9999-12-31")
        Gori::LocalTime.at(FAR_FUTURE).should_not be_nil
      end
    end

    it "renders an ordinary instant in local time under #{tz}" do
      in_zone(tz) do
        t = Gori::LocalTime.at(ORDINARY).should_not be_nil
        t.to_unix.should eq(1_700_000_000)
        # Localised, not silently left in UTC: the offset is the zone's own.
        t.offset.should eq(Time::Location.load(tz).lookup(t).offset)
      end
    end
  end

  # A column far past any real date — hand-edited, or a database from another tool — fails in
  # `Time.unix` itself, before any timezone is involved. That reads as the surfaces' em dash
  # rather than taking the frame down.
  it "reads a created_at past the end of Time as the no-value dash" do
    Gori::LocalTime.at(Int64::MAX).should be_nil
    Gori::LocalTime.format(Int64::MAX, "%Y-%m-%d").should eq("—")
    Gori::LocalTime.format(Int64::MAX, "%Y-%m-%d", "").should eq("")
  end

  # `of` takes a Time that already exists (a file mtime, a session's created_at) and answers
  # the same way: localised where that is representable, the instant itself where it is not.
  it "falls back to the instant itself when the local offset would push it out of range" do
    in_zone("Asia/Seoul") do
      t = Time.unix(FAR_FUTURE // 1_000_000)
      Gori::LocalTime.of(t).to_unix.should eq(t.to_unix)
      Gori::LocalTime.of(Time.unix(1_700_000_000)).to_unix.should eq(1_700_000_000)
    end
  end
end
