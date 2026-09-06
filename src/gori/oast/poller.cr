require "./types"
require "./http"
require "./session"
require "./provider"

module Gori::Oast
  # One interruptible poll loop per listening session (mirrors Miner/Discover's stop idiom:
  # a state flag + a wake channel poked on stop so the pacing sleep cancels immediately).
  # New interactions and poll errors flow out on the shared `events` channel the controller
  # (or CLI/MCP) drains; the loop never touches Store/TUI.
  class Poller
    enum State
      Running
      Stopped
    end

    getter session : Session

    # Did the LAST poll reach the provider? "Nothing came back" and "the server refused us" are
    # the two states an out-of-band listener must never conflate (`Provider#poll` raises rather
    # than answering an empty batch for exactly that reason), and a CONSUMER needs the same
    # distinction: `last_poll_at` is a LIVENESS signal, not a "we tried" counter. The probe
    # out-of-band minter picks the most-recently-polled session to plant payloads against
    # (`Probe::OutOfBand::StoreMinter.pick_session`), so a listener whose endpoint 401s or 500s
    # on every tick used to keep winning that pick — and win it harder the longer it stayed
    # broken — while the callbacks arrived nowhere and the scan read clean. `gori run oast`
    # already stamps only for a poll that answered; this is what lets the tab do the same.
    #
    # TRUE until a poll actually fails: the session was registered (or resumed) a moment ago,
    # and that round trip succeeded.
    getter? answering : Bool = true

    def initialize(@provider : Provider, @session : Session, @http : Http,
                   @interval : Time::Span, @events : Channel(Event))
      @state = State::Running
      @wake = Channel(Nil).new(1)
    end

    def start : Nil
      spawn(name: "gori-oast-#{@session.id}") { run }
    end

    def stop : Nil
      @state = State::Stopped
      poke
    end

    def running? : Bool
      @state.running?
    end

    private def run : Nil
      until @state.stopped?
        poll_once
        break if @state.stopped?
        select
        when @wake.receive
          # woken by stop → loop re-checks @state and exits
        when timeout(@interval)
        end
      end
    end

    private def poll_once : Nil
      interactions = poll_answering
      return unless interactions
      interactions.each do |interaction|
        break if @state.stopped?
        @events.send(CallbackEvent.new(@session.id, interaction))
      end
    rescue
      # The FAN-OUT's own failure — a channel closed under a teardown — is not the provider's.
      # It must not flip `answering?`, and it must not take this fiber down with a backtrace
      # onto the TUI's alternate screen.
    end

    # One poll, and the record of whether it was ANSWERED. Split from the fan-out above so
    # `answering?` reports the PROVIDER's verdict and nothing else — see its comment. nil means
    # the poll failed and the error is already on the event stream.
    private def poll_answering : Array(Interaction)?
      out = @provider.poll(@http, @session)
      @answering = true # an EMPTY batch is an answer
      out
    rescue ex
      @answering = false
      return nil if @state.stopped?
      @events.send(OastErrorEvent.new(@session.id, ex.message || "poll error"))
      nil
    end

    private def poke : Nil
      select
      when @wake.send(nil)
      else
      end
    end
  end
end
