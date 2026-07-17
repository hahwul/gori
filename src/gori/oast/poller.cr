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
      @provider.poll(@http, @session).each do |interaction|
        break if @state.stopped?
        @events.send(CallbackEvent.new(@session.id, interaction))
      end
    rescue ex
      return if @state.stopped?
      @events.send(OastErrorEvent.new(@session.id, ex.message || "poll error"))
    end

    private def poke : Nil
      select
      when @wake.send(nil)
      else
      end
    end
  end
end
