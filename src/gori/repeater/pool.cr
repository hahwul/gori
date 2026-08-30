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
    # One request over a pooled connection when this request and the pool's state allow it.
    # Never raises: every failure comes back as an error `Result`, exactly as the unpooled
    # engines do.
    abstract def send(bytes : Bytes) : Repeater::Result

    # Close every parked connection. Idempotent; call when a run ends so a stopped sweep
    # does not leave file descriptors open until GC.
    abstract def close_all : Nil

    abstract def dialed : Int64
    abstract def reused : Int64
    abstract def stale_retries : Int64
    abstract def stale_checkouts : Int64
    abstract def unsafe_stale : Int64
    abstract def pooling? : Bool
  end
end
