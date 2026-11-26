module Gori::Tui
  # How a tool tab's background run fiber hands engine events to the Runner fiber.
  #
  # Fuzzer, Miner, Sequencer and Discover each spawn one forwarding fiber per run. It reads
  # `engine.run` and pushes every event into a bounded channel owned by the controller and
  # shared by all of that tool's tabs, and the Runner tick's `drain_events` is the channel's one
  # reader. Results, findings, samples and the terminal Done/Error block on a full channel by
  # design, so a row is never dropped while the Runner is alive.
  #
  # A project-level exit (`stop_all`, from leave project / quit) ends that reader for good. A
  # stopped run still emits an event for every request it had in flight, then its Done, and
  # once those overran the channel each forwarder parked in `send` forever. A parked fiber is
  # still a GC root, so it pinned its view (up to 5000 rows), its engine and spool run, and in
  # the Fuzzer's case the controller and the old Runner graph, on every leave/reopen. Past
  # ~512 events it also stopped consuming `engine.run`, which parked the engine's own workers
  # and kept its keep-alive pool's sockets open.
  #
  # `detach` is that exit. It wakes any forwarder already parked on a full channel, and every
  # later delivery returns at once. The forwarder must KEEP consuming `engine.run` to the end
  # (the engine has already been told to stop) so the engine unwinds and closes its pool.
  class RunFeed
    # Close-only signal: closing it is the one way to wake a fiber parked in a `select`.
    @detached = Channel(Nil).new

    # The Runner will never drain these channels again. Terminal: only a project-level
    # `stop_all` may call it, never a per-tab close, because the Runner keeps draining the
    # other tabs' rows then. Idempotent.
    def detach : Nil
      @detached.close
    end

    def detached? : Bool
      @detached.closed?
    end

    # Blocking delivery while the Runner lives: the plain `send` it replaces, in the same FIFO
    # order. False once detached, including for a send that was already parked when `detach`
    # ran, and then nothing is enqueued.
    def deliver(ch : Channel(T), value : T) : Bool forall T
      return false if @detached.closed?
      select
      when ch.send(value)
        true
      when @detached.receive?
        false
      end
    end

    # Droppable delivery, for progress: dropped when the channel is full, and once detached
    # nothing is enqueued at all, so a buffer nobody will read again does not fill up.
    def offer(ch : Channel(T), value : T) : Nil forall T
      return if @detached.closed?
      select
      when ch.send(value)
      else
      end
    end
  end
end
