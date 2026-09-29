require "json"
require "../env"

module Gori
  # Request-time macros (#1350): a short list of saved Repeater sessions a Fuzzer or Miner run
  # replays BEFORE a candidate request, so the value they leave in the session bindings — a form
  # CSRF token, a one-time nonce — is fresh when the candidate resolves its `$BIND.NAME`.
  #
  # #1233 refreshes a session SLOT when its bound credential is about to expire (`jwt-exp`, a
  # `ttl`). That is the wrong clock for a value the application rotates on every page load: it
  # is invalidated long before its session expires, and a sweep whose second candidate carries
  # the first response's token collects a page of 403s that read as "the payloads were tried".
  # This is the same actor on a different clock, counted in candidates rather than in seconds.
  #
  # The macro itself adds no mechanism to the engines. Extraction is the existing extract rules
  # (`TokenExtract`, `Bindings#observe`), injection is the existing `$BIND.NAME` resolved at send
  # time (`Fuzz::Sender#send`), and every step goes through `Repeater::Plan` and the surface's
  # own `Outbound`. What is new is only WHEN the steps run, and what happens around a run that
  # fails — see `Lane`.
  #
  # This file is the configuration and nothing else. It is a leaf on purpose: it rides on
  # `Fuzz::Config` and `Miner::Config`, which every surface already builds, so a surface's whole
  # job is to parse ITS input format into a `Spec` (DESIGN.md §2) and `Plan.build` does the rest.
  module RequestMacro
    # Prefix on the `error` of a candidate the macro refused to send. One spelling, matched by
    # `failed?`, so the engines can tell "the macro failed" from a network error: a retry cannot
    # repair it (the macro would only fail again, and re-run its steps against the login
    # endpoint), and a surface must not read it as the target's answer.
    ERROR_PREFIX = "macro: "

    # A candidate that was waiting at the gate when the operator stopped the run. Nothing was
    # sent, so it is not a failure and not a tested name — the Fuzzer drops the row, and the
    # Miner must not count it either.
    STOPPED_UNSENT = "#{ERROR_PREFIX}the run was stopped before this candidate was sent"

    def self.failed?(err : String?) : Bool
      !!err.try(&.starts_with?(ERROR_PREFIX))
    end

    def self.stopped_unsent?(err : String?) : Bool
      err == STOPPED_UNSENT
    end

    # A macro this run cannot honour. A `Gori::Error` and deliberately NOT a `PlanError::Reason`:
    # that enum is `case … in` in three surfaces' exhaustive matches, and this refusal has no
    # surface idiom to write — the sentence names Repeater sessions and extract rules, which read
    # the same on every surface. `Fuzz::ChainError` is the precedent; every surface's existing
    # `Gori::Error` path carries the message unchanged.
    class Error < Gori::Error
    end

    # How often the macro runs, counted in CANDIDATE requests.
    #
    #   * `off`      — never; the configured steps are kept but not run.
    #   * `request`  — before every candidate (`every == 1`).
    #   * `N`        — before the first candidate, then again once N candidates have used its
    #                  value (`every == N`).
    #
    # There is no separate "once before the first candidate" spelling: the first candidate always
    # opens an epoch, so `every N` with N larger than the run IS "once, up front". See `Lane`
    # for what an epoch is and what it guarantees.
    struct Cadence
      getter every : Int32

      def initialize(@every : Int32 = 1)
        raise ArgumentError.new("a macro cadence cannot be negative") if @every < 0
      end

      def self.off : Cadence
        new(0)
      end

      def self.request : Cadence
        new(1)
      end

      def off? : Bool
        @every == 0
      end

      def per_request? : Bool
        @every == 1
      end

      # `off` | `request` | a non-negative integer (0 = off, 1 = request). nil for anything
      # else, and for blank — the caller decides what "unset" means (the default is `request`).
      def self.parse?(raw : String?) : Cadence?
        s = raw.try(&.strip.downcase)
        return nil if s.nil? || s.empty?
        case s
        when "off", "none", "never"      then off
        when "request", "each", "always" then request
        else
          return nil unless s.each_char.all?(&.ascii_number?)
          n = s.to_i32?
          n ? new(n) : nil
        end
      end

      # What `parse?` reads back: `off`, `request` or the bare number.
      def token : String
        case @every
        when 0 then "off"
        when 1 then "request"
        else        @every.to_s
        end
      end

      # The operator-facing wording, for a run's configuration line.
      def label : String
        case @every
        when 0 then "off"
        when 1 then "before every request"
        else        "before every #{@every} requests"
        end
      end

      def ==(other : Cadence) : Bool
        @every == other.every
      end
    end

    # What a candidate does when the macro cannot produce a fresh value.
    #
    # There is no "send it anyway with the last value" here, and that is a decision, not an
    # omission. The candidate's verdict would then be about a stale token — a 403 that says
    # nothing about the payload — and the point of the whole feature is that such a row must not
    # exist. A run that wants to keep going without a fresh value should turn the macro `off`.
    enum OnFailure
      # The candidate is NOT sent: its row is an error row (`ERROR_PREFIX`), the run goes on, and
      # `Lane::FAILURE_LIMIT` failures in a row end it, so a broken login is not hammered once
      # per payload.
      Skip
      # The first failure ends the run.
      Stop

      def token : String
        to_s.downcase
      end

      def label : String
        case self
        in Skip then "skip the candidate"
        in Stop then "stop the run"
        end
      end

      def self.parse?(raw : String?) : OnFailure?
        case raw.try(&.strip.downcase)
        when "skip" then Skip
        when "stop" then Stop
        end
      end
    end

    # The normalized configuration every surface hands to `Plan.build`.
    #
    # `steps` are Repeater sessions in the order they run, each spelled as the operator typed it:
    # a session id (`3`, `#3`) or the tab's name. They are RESOLVED once, when the plan is built
    # (`Runner.build`), and the resolved requests are frozen for the run — an edit to the tab
    # halfway through a sweep must not change the test, and a tab deleted halfway through must
    # not end it.
    #
    # `expect` optionally names the bindings a run of the steps MUST rebind. Without it a run
    # succeeds when ANY binding this run can see was rebound, which is enough to catch "the
    # extract rule never fired" and not enough to catch "a session cookie rotated on the page
    # but the CSRF rule missed" — the stale-token case this feature exists to remove.
    struct Spec
      getter steps : Array(String)
      getter cadence : Cadence
      getter on_failure : OnFailure
      getter expect : Array(String)

      def initialize(steps : Array(String) = [] of String,
                     @cadence : Cadence = Cadence.request,
                     @on_failure : OnFailure = OnFailure::Skip,
                     expect : Array(String) = [] of String)
        @steps = steps.map(&.strip).reject(&.empty?)
        @expect = expect.map { |n| Env.strip_spelling(n, Env::Namespace::Bind) }.reject(&.empty?).uniq!
      end

      # Whether this spec asks for a macro at all. `off` keeps the steps for the operator and
      # asks for nothing: no validation, no traffic, no lane.
      def active? : Bool
        !@cadence.off?
      end

      # Split a `3,login,#7` style list. Commas and whitespace-around-commas only; a tab name
      # that itself contains a comma cannot be named here, and is reached by its id.
      def self.parse_steps(raw : String?) : Array(String)
        return [] of String unless raw
        raw.split(',').map(&.strip).reject(&.empty?)
      end

      def with_cadence(cadence : Cadence) : Spec
        Spec.new(@steps, cadence, @on_failure, @expect)
      end

      def to_json(j : JSON::Builder) : Nil
        j.object do
          j.field("steps") { j.array { @steps.each { |s| j.string s } } }
          j.field "every", @cadence.token
          j.field "on_failure", @on_failure.token
          j.field("expect") { j.array { @expect.each { |s| j.string s } } }
        end
      end

      # The inverse, tolerant of a config blob written before a key existed or by a peer that
      # spelled something we do not know: an unreadable field reads as its default rather than
      # dropping the whole macro. nil when there is nothing to restore.
      def self.from_json?(any : JSON::Any?) : Spec?
        h = any.try(&.as_h?)
        return nil unless h
        steps = h["steps"]?.try(&.as_a?).try(&.compact_map { |v| v.as_s? || v.as_i64?.try(&.to_s) }) || [] of String
        cadence = Cadence.parse?(h["every"]?.try { |v| v.as_s? || v.as_i64?.try(&.to_s) }) || Cadence.request
        on_failure = OnFailure.parse?(h["on_failure"]?.try(&.as_s?)) || OnFailure::Skip
        expect = h["expect"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
        Spec.new(steps, cadence, on_failure, expect)
      end
    end
  end
end
