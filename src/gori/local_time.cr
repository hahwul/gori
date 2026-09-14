module Gori
  # Rendering a STORED instant in the operator's timezone, without letting the timezone decide
  # whether the row can be displayed at all.
  #
  # `Time#to_local` RAISES `ArgumentError: Invalid time: seconds out of range` when the instant
  # plus the local utc offset lands past `Time::MAX` — so an instant near the far end of the
  # range renders in `TZ=UTC` and `TZ=America/New_York` and raises in `TZ=Asia/Seoul` and
  # `TZ=Europe/Berlin`. The data half is just as ordinary: a HAR entry dated
  # `9999-12-31T23:59:59.999Z` imports without complaint, and `Time.unix` itself refuses a
  # `created_at` column far past that (a hand-edited or foreign database).
  #
  # That made a stored row able to end a session. Eight call sites read `created_at` micros
  # straight into `Time.unix(...).to_local.to_s(...)`, seven of them on TUI render paths, where
  # the same frame is asked for again 50ms later: three failures trip the Runner's tick breaker
  # and the process ends. The eighth is a QL `date:` filter, which raises while FILTERING — the
  # row does not even have to be drawn.
  #
  # The fallback is UTC rather than an error, because the question the cell answers ("when did
  # this happen") still has an answer; only the operator's preferred spelling of it does not.
  # A `%:z` format therefore shows `+00:00` on exactly the rows that could not be localised,
  # which is the honest reading, and every other row is unaffected.
  module LocalTime
    extend self

    # A stored `created_at` (unix MICROseconds) as local time, or nil when the instant is too
    # far out for `Time` to hold at all.
    def at(micros : Int64) : Time?
      of(Time.unix(micros // 1_000_000))
    rescue ArgumentError
      nil
    end

    # A `Time` in the operator's timezone, or the instant itself (UTC) when the local offset
    # would push it out of range.
    def of(t : Time) : Time
      t.to_local
    rescue ArgumentError
      t
    end

    # The rendering every caller actually wanted: local, formatted, and never raising.
    # `fallback` is what an unrepresentable instant reads as — the module-wide em dash, which
    # every surface here already uses for "no value".
    def format(micros : Int64, fmt : String, fallback : String = "—") : String
      at(micros).try(&.to_s(fmt)) || fallback
    end
  end
end
