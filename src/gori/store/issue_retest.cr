require "db"

module Gori
  class Store
    # --- issue retest steps and runs (V27, #1036) ----------------------------
    #
    # Retest semantics are kept OUT of `entity_links` on purpose (the issue's data-model
    # note): an evidence link answers what material is related, a retest step additionally
    # carries order, role, an assertion and execution state. Unlinking a piece of evidence
    # must not delete a test step, and linking one must not add one.

    # Why a step write did not happen. `Ok` is the only status that changed anything.
    enum RetestStatus
      Ok
      IssueGone # the issue was deleted between the operator's pick and the write
      StepGone  # the step was deleted/re-ordered away underneath this edit
      Busy      # the batch never committed (SQLite busy/locked, or the store is closing)
    end

    # Append a step to an issue's retest. Returns `{id, status}`; `id` is 0 unless Ok.
    #
    # `position` is chosen INSIDE the writer's transaction rather than by the caller, for the
    # reason `Store#next_repeater_position` exists and `#904` records the cost of getting
    # wrong: two surfaces appending at once both read the same "next" a moment earlier and
    # write the same number, and the run order then depends on the rowid tiebreak instead of
    # on what either operator asked for. A caller that wants a specific slot moves the step
    # afterwards (`move_retest_step`), which is an explicit re-order rather than a race.
    def add_retest_step(issue_id : Int64, role : RetestRole, ref_kind : LinkRefKind,
                        ref_id : Int64, assertion : String = "") : {Int64, RetestStatus}
      ts = now_us
      row_id = 0_i64
      status = RetestStatus::Busy
      ok = exec_task_ok ->(c : DB::Connection) {
        if c.scalar("SELECT COUNT(*) FROM issues WHERE id = ?", issue_id).as(Int64) == 0
          status = RetestStatus::IssueGone
        else
          pos = c.scalar(
            "SELECT COALESCE(MAX(position), 0) + 1 FROM issue_retest_steps WHERE issue_id = ?",
            issue_id).as(Int64).to_i
          c.exec(
            "INSERT INTO issue_retest_steps (issue_id, position, role, ref_kind, ref_id, assertion, created_at, updated_at) " \
            "VALUES (?,?,?,?,?,?,?,?)",
            issue_id, pos, role.label, ref_kind.label, ref_id, assertion, ts, ts)
          row_id = c.scalar("SELECT last_insert_rowid()").as(Int64)
          status = RetestStatus::Ok
        end
        nil
      }
      return {0_i64, RetestStatus::Busy} unless ok
      status.ok? ? {row_id, status} : {0_i64, status}
    end

    # Edit one step's role and/or assertion. Both are optional; supplying neither is a no-op
    # that reports Ok (nothing to persist, nothing failed) — the contract `update_issue`
    # keeps for the same shape.
    def update_retest_step(id : Int64, *, role : RetestRole? = nil,
                           assertion : String? = nil) : RetestStatus
      return RetestStatus::Ok if role.nil? && assertion.nil?
      status = RetestStatus::Busy
      ts = now_us
      ok = exec_task_ok ->(c : DB::Connection) {
        if c.scalar("SELECT COUNT(*) FROM issue_retest_steps WHERE id = ?", id).as(Int64) == 0
          status = RetestStatus::StepGone
        else
          sets = ["updated_at = ?"]
          args = [ts] of DB::Any
          role.try { |r| sets << "role = ?"; args << r.label }
          assertion.try { |a| sets << "assertion = ?"; args << a }
          args << id
          c.exec("UPDATE issue_retest_steps SET #{sets.join(", ")} WHERE id = ?", args: args)
          status = RetestStatus::Ok
        end
        nil
      }
      ok ? status : RetestStatus::Busy
    end

    # Remove one step and CLOSE THE GAP its position left.
    #
    # Re-packing matters because `position` is what the operator reorders with: leaving a
    # hole makes "move step 3 up" and "the third row" disagree the moment anything is
    # deleted, and the two surfaces that show a number (the TUI card, `gori run retest
    # steps`) would then print positions no move command can name.
    def remove_retest_step(id : Int64) : RetestStatus
      status = RetestStatus::Busy
      ok = exec_task_ok ->(c : DB::Connection) {
        issue_id = nil.as(Int64?)
        c.query("SELECT issue_id FROM issue_retest_steps WHERE id = ?", id) do |rs|
          issue_id = rs.read(Int64) if rs.move_next
        end
        if iid = issue_id
          c.exec("DELETE FROM issue_retest_steps WHERE id = ?", id)
          repack_retest_positions(c, iid)
          status = RetestStatus::Ok
        else
          status = RetestStatus::StepGone
        end
        nil
      }
      ok ? status : RetestStatus::Busy
    end

    # Move one step to `position` (1-based), shifting the rest. Clamped to the list rather
    # than refused: "move it to the top" is the common ask and spelling it `1` must not fail
    # on a list whose first row is already there.
    def move_retest_step(id : Int64, position : Int32) : RetestStatus
      status = RetestStatus::Busy
      ts = now_us
      ok = exec_task_ok ->(c : DB::Connection) {
        issue_id = nil.as(Int64?)
        c.query("SELECT issue_id FROM issue_retest_steps WHERE id = ?", id) do |rs|
          issue_id = rs.read(Int64) if rs.move_next
        end
        if iid = issue_id
          ordered = [] of Int64
          c.query(
            "SELECT id FROM issue_retest_steps WHERE issue_id = ? ORDER BY position, id", iid) do |rs|
            rs.each { ordered << rs.read(Int64) }
          end
          ordered.delete(id)
          target = (position - 1).clamp(0, ordered.size)
          ordered.insert(target, id)
          ordered.each_with_index do |sid, i|
            c.exec("UPDATE issue_retest_steps SET position = ?, updated_at = ? WHERE id = ?", i + 1, ts, sid)
          end
          status = RetestStatus::Ok
        else
          status = RetestStatus::StepGone
        end
        nil
      }
      ok ? status : RetestStatus::Busy
    end

    # Drop every step of one issue's retest — the card's "clear". Returns whether the write
    # committed. Runs are left alone: they are the record of what already happened, and
    # re-planning the check does not un-run it.
    def clear_retest_steps(issue_id : Int64) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("DELETE FROM issue_retest_steps WHERE issue_id = ?", issue_id)
        nil
      }
    end

    def retest_steps(issue_id : Int64) : Array(RetestStep)
      list = [] of RetestStep
      @db.query(
        "SELECT id, issue_id, position, role, ref_kind, ref_id, assertion, created_at, updated_at " \
        "FROM issue_retest_steps WHERE issue_id = ? ORDER BY position, id", issue_id) do |rs|
        rs.each { try_read_retest_step(rs).try { |s| list << s } }
      end
      list
    end

    def get_retest_step(id : Int64) : RetestStep?
      @db.query(
        "SELECT id, issue_id, position, role, ref_kind, ref_id, assertion, created_at, updated_at " \
        "FROM issue_retest_steps WHERE id = ?", id) do |rs|
        return try_read_retest_step(rs) if rs.move_next
      end
      nil
    end

    def count_retest_steps(issue_id : Int64) : Int32
      @db.scalar("SELECT COUNT(*) FROM issue_retest_steps WHERE issue_id = ?", issue_id).as(Int64).to_i
    end

    # Persist one completed run and its result rows, then prune this issue's history down to
    # `keep`. ONE transaction for all three, so a partial failure cannot leave a run summary
    # whose step rows are missing — which would read as a run of zero steps that passed.
    #
    # The run row is written at the END rather than reserved at the start: a summary is a
    # statement that a run FINISHED, and a reserved row left behind by a killed process would
    # claim a verdict for a check that never completed. The provenance a caller wants during
    # the run (a History flow's `source_ref`) names the ISSUE, which is stable, not this id.
    def record_retest_run(issue_id : Int64, started_at : Int64, finished_at : Int64,
                          verdict : RetestVerdict, tally : Retest::Tally,
                          results : Array(Retest::StepResult),
                          *, surface : String? = nil, note : String? = nil,
                          keep : Int32 = Retest::RUN_HISTORY) : {Int64, RetestStatus}
      row_id = 0_i64
      status = RetestStatus::Busy
      ok = exec_task_ok ->(c : DB::Connection) {
        if c.scalar("SELECT COUNT(*) FROM issues WHERE id = ?", issue_id).as(Int64) == 0
          status = RetestStatus::IssueGone
        else
          c.exec(
            "INSERT INTO issue_retest_runs (issue_id, started_at, finished_at, surface, verdict, " \
            "total, passed, failed, inconclusive, errored, blocked, skipped, note) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
            issue_id, started_at, finished_at, surface, verdict.label, tally.total, tally.passed,
            tally.failed, tally.inconclusive, tally.errored, tally.blocked, tally.skipped, note)
          row_id = c.scalar("SELECT last_insert_rowid()").as(Int64)
          results.each_with_index { |r, i| insert_retest_run_step(c, row_id, i + 1, r) }
          prune_retest_runs(c, issue_id, keep)
          status = RetestStatus::Ok
        end
        nil
      }
      return {0_i64, RetestStatus::Busy} unless ok
      status.ok? ? {row_id, status} : {0_i64, status}
    end

    # An issue's runs, NEWEST FIRST — a regression check reads the last one, and the list is
    # bounded by `record_retest_run`'s prune.
    def retest_runs(issue_id : Int64, limit : Int32 = Retest::RUN_HISTORY) : Array(RetestRun)
      list = [] of RetestRun
      @db.query(
        "SELECT #{RETEST_RUN_COLS} FROM issue_retest_runs WHERE issue_id = ? " \
        "ORDER BY started_at DESC, id DESC LIMIT ?", issue_id, limit) do |rs|
        rs.each { try_read_retest_run(rs).try { |r| list << r } }
      end
      list
    end

    def get_retest_run(id : Int64) : RetestRun?
      @db.query("SELECT #{RETEST_RUN_COLS} FROM issue_retest_runs WHERE id = ?", id) do |rs|
        return try_read_retest_run(rs) if rs.move_next
      end
      nil
    end

    # The most recent run of one issue — the Issue detail's one-line retest state.
    def last_retest_run(issue_id : Int64) : RetestRun?
      retest_runs(issue_id, 1).first?
    end

    def retest_run_steps(run_id : Int64) : Array(RetestRunStep)
      list = [] of RetestRunStep
      @db.query(
        "SELECT id, run_id, position, role, ref_kind, ref_id, label, method, url, assertion, " \
        "outcome, detail, status, duration_us, bytes, flow_id FROM issue_retest_run_steps " \
        "WHERE run_id = ? ORDER BY position, id", run_id) do |rs|
        rs.each { try_read_retest_run_step(rs).try { |s| list << s } }
      end
      list
    end

    # Delete one run and its rows. The steps that produced it are untouched.
    def delete_retest_run(id : Int64) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("DELETE FROM issue_retest_run_steps WHERE run_id = ?", id)
        c.exec("DELETE FROM issue_retest_runs WHERE id = ?", id)
        nil
      }
    end

    # One issue's retest cascade, on an OPEN connection — called from `delete_issue_one` and
    # `clear_issues`. Unlike frozen evidence, this DOES cascade: a run summary is a statement
    # about one issue's check and means nothing detached from it.
    protected def delete_issue_retest(c : DB::Connection, id : Int64) : Nil
      c.exec("DELETE FROM issue_retest_run_steps WHERE run_id IN " \
             "(SELECT id FROM issue_retest_runs WHERE issue_id = ?)", id)
      c.exec("DELETE FROM issue_retest_runs WHERE issue_id = ?", id)
      c.exec("DELETE FROM issue_retest_steps WHERE issue_id = ?", id)
    end

    # The unqualified twin, for `clear_issues` — the same argument it makes for not reading
    # the id list back just to name in `IN (…)` what an unqualified DELETE already covers.
    protected def clear_issue_retest(c : DB::Connection) : Nil
      c.exec("DELETE FROM issue_retest_run_steps")
      c.exec("DELETE FROM issue_retest_runs")
      c.exec("DELETE FROM issue_retest_steps")
    end

    private def insert_retest_run_step(c : DB::Connection, run_id : Int64, position : Int32,
                                       r : Retest::StepResult) : Nil
      p = r.planned
      obs = r.observation
      c.exec(
        "INSERT INTO issue_retest_run_steps (run_id, position, role, ref_kind, ref_id, label, " \
        "method, url, assertion, outcome, detail, status, duration_us, bytes, flow_id) " \
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        run_id, position, p.step.role.label, p.step.ref_kind.label, p.step.ref_id,
        Retest.clip(p.label), p.method, Retest.clip(p.url), p.step.assertion,
        r.outcome.label, r.detail, obs.status, obs.duration_us, obs.bytes, obs.flow_id)
    end

    # Keep the newest `keep` runs of one issue. `keep <= 0` keeps them all — a caller that
    # means "no history" deletes, and silently wiping on a zero-valued argument is the shape
    # a misread config turns into data loss.
    private def prune_retest_runs(c : DB::Connection, issue_id : Int64, keep : Int32) : Nil
      return if keep <= 0
      c.exec(
        "DELETE FROM issue_retest_run_steps WHERE run_id IN (SELECT id FROM issue_retest_runs " \
        "WHERE issue_id = ? ORDER BY started_at DESC, id DESC LIMIT -1 OFFSET ?)", issue_id, keep)
      c.exec(
        "DELETE FROM issue_retest_runs WHERE id IN (SELECT id FROM issue_retest_runs " \
        "WHERE issue_id = ? ORDER BY started_at DESC, id DESC LIMIT -1 OFFSET ?)", issue_id, keep)
    end

    # Renumber one issue's steps 1..N in their current order.
    private def repack_retest_positions(c : DB::Connection, issue_id : Int64) : Nil
      ids = [] of Int64
      c.query("SELECT id FROM issue_retest_steps WHERE issue_id = ? ORDER BY position, id", issue_id) do |rs|
        rs.each { ids << rs.read(Int64) }
      end
      ids.each_with_index do |sid, i|
        c.exec("UPDATE issue_retest_steps SET position = ? WHERE id = ?", i + 1, sid)
      end
    end

    private RETEST_RUN_COLS = "id, issue_id, started_at, finished_at, surface, verdict, total, " \
                              "passed, failed, inconclusive, errored, blocked, skipped, note"

    # nil on a role/kind this build cannot name — the skip `try_read_entity_link` makes, so a
    # row a newer gori wrote is left alone rather than crashing the Issue detail.
    private def try_read_retest_step(rs : DB::ResultSet) : RetestStep?
      id = rs.read(Int64)
      issue_id = rs.read(Int64)
      position = rs.read(Int64).to_i
      role = RetestRole.parse?(rs.read(String))
      kind = LinkRefKind.parse(rs.read(String))
      ref_id = rs.read(Int64)
      assertion = rs.read(String)
      created_at = rs.read(Int64)
      updated_at = rs.read(Int64)
      return nil unless role && kind
      RetestStep.new(id, issue_id, position, role, kind, ref_id, assertion, created_at, updated_at)
    end

    private def try_read_retest_run(rs : DB::ResultSet) : RetestRun?
      id = rs.read(Int64)
      issue_id = rs.read(Int64)
      started_at = rs.read(Int64)
      finished_at = rs.read(Int64)
      surface = rs.read(String?)
      verdict = RetestVerdict.parse?(rs.read(String))
      total = rs.read(Int64).to_i
      passed = rs.read(Int64).to_i
      failed = rs.read(Int64).to_i
      inconclusive = rs.read(Int64).to_i
      errored = rs.read(Int64).to_i
      blocked = rs.read(Int64).to_i
      skipped = rs.read(Int64).to_i
      note = rs.read(String?)
      return nil unless verdict
      RetestRun.new(id, issue_id, started_at, finished_at, surface, verdict, total, passed,
        failed, inconclusive, errored, blocked, skipped, note)
    end

    private def try_read_retest_run_step(rs : DB::ResultSet) : RetestRunStep?
      id = rs.read(Int64)
      run_id = rs.read(Int64)
      position = rs.read(Int64).to_i
      role = RetestRole.parse?(rs.read(String))
      kind = LinkRefKind.parse(rs.read(String))
      ref_id = rs.read(Int64)
      label = rs.read(String)
      method = rs.read(String)
      url = rs.read(String)
      assertion = rs.read(String)
      outcome = RetestOutcome.parse?(rs.read(String))
      detail = rs.read(String)
      status = rs.read(Int64?).try(&.to_i)
      duration_us = rs.read(Int64?)
      bytes = rs.read(Int64)
      flow_id = rs.read(Int64?)
      return nil unless role && kind && outcome
      RetestRunStep.new(id, run_id, position, role, kind, ref_id, label, method, url, assertion,
        outcome, detail, status, duration_us, bytes, flow_id)
    end
  end
end
