{% if flag?(:win32) %}
  # Windows has no POSIX signals: the stdlib's `Signal#trap`, `#reset`, `#ignore` and
  # `#trap_handler?` raise NotImplementedError, and gori's TUI, `gori run capture` and every
  # interruptible `gori run` command trap INT and TERM at startup. The console's control
  # events stand in for those two, so the callers stay as they are: Ctrl-C and Ctrl-Break
  # deliver INT; a closed console window, a logoff or a shutdown deliver TERM, though there
  # Windows ends the process soon after the handler returns, so a TERM trap gets little time.
  #
  # `Process.on_terminate` holds ONE handler, so this keeps a handler per signal and installs
  # a dispatcher over them. Like a POSIX trap it runs on its own fiber.
  module Gori::ConsoleSignals
    @@handlers = {} of Signal => Proc(Signal, Nil)

    def self.trap(sig : Signal, handler : Proc(Signal, Nil)) : Nil
      @@handlers[sig] = handler
      install
    end

    def self.reset(sig : Signal) : Nil
      @@handlers.delete(sig)
      install
    end

    def self.handler?(sig : Signal) : Proc(Signal, Nil)?
      @@handlers[sig]?
    end

    private def self.install : Nil
      if @@handlers.empty?
        Process.restore_interrupts!
      else
        Process.on_terminate do |reason|
          sig = reason.interrupted? ? Signal::INT : Signal::TERM
          # The other event, untrapped, keeps its default: the process ends.
          if handler = @@handlers[sig]?
            handler.call(sig)
          else
            exit 128 + sig.value
          end
        end
      end
    end
  end

  enum Signal
    def trap(&handler : Signal ->) : Nil
      Gori::ConsoleSignals.trap(self, handler)
    end

    def trap_handler?
      Gori::ConsoleSignals.handler?(self)
    end

    def reset : Nil
      Gori::ConsoleSignals.reset(self)
    end

    def ignore : Nil
      trap { }
    end
  end
{% end %}
