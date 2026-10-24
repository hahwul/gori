require "./engine"

module Gori::Repeater
  # What a sweep's senders need from a keep-alive connection pool, whatever protocol it
  # pools. Two implementations: `ConnPool` (HTTP/1.1 sockets) and `H2Pool` (HTTP/2
  # connections, one request at a time each).
  #
  # It exists because the SURFACES have to be one shape. `gori run fuzz` and `gori run mine`
  # each end with a "connections · N dialed · M reused" line assembled from these counters,
  # and a sweep against an h2 origin has exactly the same thing to report as one against an
  # h1 origin — so the reporting seam takes a `Pool`, not a `ConnPool`, and neither reporter
  # learns which protocol produced the numbers.
  #
  # The counters mean the same thing on both:
  #
  #   dialed          connections opened == handshakes paid. `dialed + reused == sends` for a
  #                   run that never hit a stale retry.
  #   reused          requests served over a connection that was already open.
  #   stale_checkouts parked connections found ALREADY CLOSED before a byte of the next
  #                   request went onto them — so nothing was re-sent, and the redial carries
  #                   the request's first and only copy.
  #   stale_retries   requests that WERE put on the wire twice: the peer's close landed
  #                   between the checkout probe and the write, so gori could not tell whether
  #                   the origin had read the first copy, and the method allowed a replay.
  #   unsafe_stale    the same event on a method that may NOT be replayed (see
  #                   `ConnPool::REPLAYABLE_METHODS`) — reported as errors rather than
  #                   silently re-sent, which is the whole point of the distinction.
  #   pooling?        false once the pool has given up on reuse for the rest of the run.
  abstract class Pool
    # An origin that refuses reuse turns every park into a wasted probe and a redial, so after
    # this many consecutive stale checkouts the pool runs in dial-per-send mode for the rest of
    # the run. `ConnPool` documents what it bounds.
    STALE_GIVE_UP = 3

    getter dialed : Int64 = 0_i64
    getter reused : Int64 = 0_i64
    getter stale_retries : Int64 = 0_i64
    getter stale_checkouts : Int64 = 0_i64
    getter unsafe_stale : Int64 = 0_i64
    getter? pooling : Bool = true
    @consecutive_stale = 0

    # Asked right before a stale RE-SEND (the `stale_retries` case): nil lets it go, a reason
    # keeps it off the wire and the request ends with the failure its first copy got. A re-send
    # is a whole second request at the origin, so the run's budget (the project's
    # `outbound_max_requests`, a tool's `max_requests`) has to admit it like any other; asked
    # below the caller's own count, it was the one send neither ever saw. Nil admits everything.
    property resend_gate : Proc(String?)? = nil

    # One request over a pooled connection when this request and the pool's state allow it.
    # Never raises: every failure comes back as an error `Result`, exactly as the unpooled
    # engines do.
    abstract def send(bytes : Bytes) : Repeater::Result

    # Close every parked connection. Idempotent; call when a run ends so a stopped sweep
    # does not leave file descriptors open until GC.
    def close_all : Nil
      drain
    end

    # Close and forget every parked connection.
    private abstract def drain : Nil

    private def resend_refused? : Bool
      !@resend_gate.try(&.call).nil?
    end

    # One more parked connection that turned out to be dead, from EITHER discovery point. Give
    # up on pooling for the rest of the run rather than pay a wasted probe-and-redial on every
    # send; already-parked connections are dropped, because they are the same vintage.
    private def note_stale : Nil
      @consecutive_stale += 1
      return if @consecutive_stale < STALE_GIVE_UP
      @pooling = false
      drain
    end
  end
end
