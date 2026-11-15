module Gori::Tui
  # Shared exit ordering; controllers report whether their editor buffers reached storage.
  module ExitGuard
    private def finish_exit(outcome : Symbol) : Nil
      failed = commit_pending_edits
      if failed.empty?
        stop_all_jobs
        @outcome = outcome
      else
        @quit_armed = false
        status("#{failed.join(", ")} NOT saved — kept the project open; retry exiting or copy your edits", :error)
        action = outcome == :quit ? "quit" : "leave"
        confirm("UNSAVED EDITS", "#{failed.join(", ")} could not be saved.\nDiscard these edits and #{action}?",
          confirm_label: "discard", danger: true) do
          stop_all_jobs
          @outcome = outcome
        end
      end
    end

    private def commit_pending_edits : Array(String)
      [
        {"Notes", notes_controller.commit},
        {"Project", project_controller.commit},
        {"Repeater", repeater_controller.save_all},
        {"Fuzzer", fuzzer_controller.save_all},
        {"Miner", miner_controller.save_all},
        {"Sequencer", sequencer_controller.save_all},
        {"Issues", issues_controller.commit},
        {"Decoder", decoder_controller.commit},
        {"Rewriter", rewriter_controller.commit},
      ].reject { |_, saved| saved }.map(&.[0])
    end
  end
end
