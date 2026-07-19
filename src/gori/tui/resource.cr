{% if flag?(:darwin) %}
  # libproc lives in libSystem (already linked), so no @[Link] is needed. PROC_PIDTASKINFO
  # is the cheapest way to read our own resident size on macOS: one syscall, no mach-port
  # dance. This is `struct proc_taskinfo` from <sys/proc_info.h> — the field order and
  # widths are ABI-stable (96 bytes); only `resident_size` is actually read.
  lib LibProc
    struct TaskInfo
      virtual_size : UInt64
      resident_size : UInt64
      total_user : UInt64
      total_system : UInt64
      threads_user : UInt64
      threads_system : UInt64
      policy : Int32
      faults : Int32
      pageins : Int32
      cow_faults : Int32
      messages_sent : Int32
      messages_received : Int32
      syscalls_mach : Int32
      syscalls_unix : Int32
      csw : Int32
      threadnum : Int32
      numrunning : Int32
      priority : Int32
    end

    fun proc_pidinfo(pid : Int32, flavor : Int32, arg : UInt64, buffer : Void*, buffersize : Int32) : Int32
  end
{% end %}

module Gori::Tui
  # The bottom bar's far-right CPU/MEM readout — how much this gori process is costing
  # the machine right now. Opt-out via settings:display (`resource_meter`); while off it
  # samples nothing at all.
  #
  # CPU comes from `Process.times` (stdlib, portable): the utime+stime delta over the
  # wall-clock delta between two ticks. Because gori is single-threaded, 100% is the ceiling.
  # RSS is platform-specific — libproc on macOS, /proc/self/statm on Linux — with the GC
  # heap as a last-resort proxy on anything else (an undercount, but never a wrong-order lie).
  #
  # IDLE-ZERO-CPU INVARIANT: the render loop only repaints when `dirty`, so a meter that
  # updated every tick would defeat the very thing it measures. Both numbers are therefore
  # rounded hard (integer percent, integer MiB) and `tick` reports a change ONLY when the
  # rendered STRING differs — same trick as the top-bar clock. A parked gori repaints
  # roughly never; a busy one repaints at most once per INTERVAL.
  class ResourceMeter
    # How often the sample is taken. Slow enough that the syscalls are free in aggregate,
    # fast enough that a fuzzing run visibly moves the number.
    INTERVAL = 2.seconds

    # <sys/proc_info.h> PROC_PIDTASKINFO.
    PROC_PIDTASKINFO = 4

    # The rendered chip text, or nil while disabled / before the first sample.
    getter label : String? = nil

    def initialize
      @last_sampled = nil.as(Time::Instant?)
      @last_cpu_secs = 0.0
    end

    # Re-sample if INTERVAL has elapsed. Returns true only when the drawn string changed
    # (so the caller can leave `dirty` alone and keep an idle TUI quiet).
    def tick(now : Time::Instant) : Bool
      unless Settings.resource_meter?
        # Disable edge: drop the chip once, then stay silent. Clearing @last_sampled also
        # resets the CPU baseline, so a re-enable measures a fresh window instead of
        # averaging across however long the meter was off.
        return false if @label.nil?
        @label = nil
        @last_sampled = nil
        return true
      end

      last = @last_sampled
      return false if last && now - last < INTERVAL
      @last_sampled = now

      cpu_secs = cpu_seconds
      elapsed = last ? (now - last).total_seconds : 0.0
      # The first sample has no baseline to difference against, so it reports 0% rather
      # than process-lifetime-average CPU (which would read as a bogus spike at startup).
      percent = elapsed > 0 ? (cpu_secs - @last_cpu_secs) / elapsed * 100.0 : 0.0
      @last_cpu_secs = cpu_secs

      next_label = format(percent, rss_bytes)
      return false if next_label == @label
      @label = next_label
      true
    end

    # UNPADDED CPU field — one space before the number, always. Any fixed width wider than
    # the common case leaves a gap that reads as a rendering glitch, and padding to the
    # widest case can't be justified by stability anyway: `human_bytes` is variable-width,
    # so MEM already shifts the right-anchored chip's left edge whenever RSS crosses a digit
    # or 1 GiB. Let the number be its own width and accept the same shift on 9→10.
    private def format(percent : Float64, rss : UInt64) : String
      pct = percent.clamp(0.0, 100.0).round.to_i
      String.build do |io|
        io << "CPU " << pct << "% MEM " << human_bytes(rss)
      end
    end

    # MiB up to 1 GiB, then one decimal of GiB. Deliberately coarse: a byte-exact readout
    # would change every sample and repaint the bar forever.
    private def human_bytes(bytes : UInt64) : String
      mib = bytes / (1024.0 * 1024.0)
      return "#{mib.round.to_i}M" if mib < 1024
      "#{(mib / 1024.0).round(1)}G"
    end

    # CPU seconds burned by THIS process (children excluded — the statusline's `sh` and the
    # browser/editor launches are not ours to report).
    private def cpu_seconds : Float64
      t = Process.times
      t.utime + t.stime
    end

    # Resident set size in bytes. Every path is best-effort: a probe that fails falls
    # through to the GC heap rather than raising into the render loop.
    private def rss_bytes : UInt64
      {% if flag?(:darwin) %}
        info = LibProc::TaskInfo.new
        n = LibProc.proc_pidinfo(Process.pid, PROC_PIDTASKINFO, 0_u64,
          pointerof(info), sizeof(LibProc::TaskInfo))
        return info.resident_size if n == sizeof(LibProc::TaskInfo)
      {% elsif flag?(:linux) %}
        # /proc/self/statm field 2 is the resident page count.
        if pages = read_statm_resident
          return pages * LibC.sysconf(LibC::SC_PAGESIZE).to_u64
        end
      {% end %}
      GC.stats.heap_size
    end

    {% if flag?(:linux) %}
      private def read_statm_resident : UInt64?
        raw = File.read("/proc/self/statm")
        raw.split[1]?.try(&.to_u64?)
      rescue
        nil
      end
    {% end %}
  end
end
