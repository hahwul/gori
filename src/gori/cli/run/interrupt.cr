module Gori
  module CLI
    module Run
      # Ctrl-C during a long sweep, for every `gori run` subcommand that drives an engine.
      #
      # A raw SIGINT used to just kill the process, and for the three buffering subcommands
      # that meant total data loss: `gori run fuzz --format json` and `gori run mine --format
      # json` accumulate every row and print ONCE after the drain, so forty minutes of results
      # went to the garbage collector. `gori run discover` had this fixed (its `pending` rows
      # never reached the DB); fuzz, mine and sequence never got it. Same defect, three
      # surfaces — so it lives here now rather than being copied a fourth time.
      #
      # The trap body does the minimal safe thing only: a send into a buffered channel, the
      # same shape `Gori::App#install_signal_traps` uses. The actual stop runs on a fiber.
      # `stop` is expected to make the engine drain in-flight work and close its event channel
      # exactly like a normal finish, so the caller's `engine.run` returns on its own and
      # whatever flush/emit the normal path already does covers the interrupted path too —
      # no separate write from inside the trap or the watcher.
      #
      # A SECOND signal EXITS. Without that escalation the first Ctrl-C consumed the token, the
      # watcher fiber was gone, and `Signal::INT.trap` had permanently replaced the default
      # disposition — so every later Ctrl-C did nothing at all and the operator's only way out
      # of a slow stop (a `stop` bounded by in-flight retries against a dead origin) was SIGKILL
      # from another terminal. 130 is the conventional "terminated by SIGINT" status.
      #
      # Returns a proc reading the `interrupted` flag, so the caller can report the run as cut
      # short without threading a second value through its own signature.
      def self.install_interrupt_trap(fiber_name : String, notice : String,
                                      &stop : -> Nil) : -> Bool
        interrupted = false
        seen = false
        shutdown = Channel(Nil).new(1)
        # Escalate on the SECOND signal inside the trap, not after `stop` returns. The
        # previous second `receive` sat behind `stop.call`, so a drain blocked on
        # in-flight retries never reached it; a third `send` then blocked inside the
        # trap (capacity-1 channel, `send` waits rather than raising) and INT/TERM
        # stayed trapped — SIGKILL was the only way out, the failure this helper's
        # header says it exists to close.
        escalate = -> {
          if seen
            STDERR.puts "\ninterrupted again — exiting without finishing"
            exit 130
          end
          seen = true
          select
          when shutdown.send(nil)
          else
          end
        }
        Signal::INT.trap { escalate.call }
        Signal::TERM.trap { escalate.call }
        spawn(name: fiber_name) do
          shutdown.receive
          interrupted = true
          STDERR.puts "\n#{notice}"
          stop.call
        end
        -> { interrupted }
      end

      # The other half every interrupted stream needs: say how much survived, and exit
      # non-zero so a scripted `… || die` fires on a run that was cut short.
      #
      # Called BEFORE each subcommand's own "everything was refused" backstop, and that order
      # is load-bearing: a sweep stopped after zero results has not demonstrated that every
      # request failed, so falling through would print a diagnosis of the wrong cause. 130 is
      # the conventional status for "terminated by SIGINT".
      def self.report_interrupted(count : Int, noun : String, verb : String) : NoReturn
        STDERR.puts "interrupted — #{count} #{noun}#{count == 1 ? "" : "s"} #{verb}"
        exit 130
      end
    end
  end
end
