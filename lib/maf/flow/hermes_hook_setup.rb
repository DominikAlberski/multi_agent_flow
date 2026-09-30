# frozen_string_literal: true

module Flow
  # HermesHookSetup installs the Hermes hook script. It prints the steps that
  # the user must do. The flow never edits the Hermes config: the file is
  # comment-rich, and Hermes guards it as security-sensitive. It prints only
  # the step that is still missing.
  class HermesHookSetup
    def initialize
      @home = File.join(Dir.home, ".hermes")
      @script = File.join(@home, "agent-hooks", HermesHook::SCRIPT_NAME)
    end

    # Returns true when the user has steps left.
    def install
      HookFiles.copy(File.join(ASSETS, "harness-hooks", "next-task-hermes.sh"), @script)
      steps = self.steps(File.mtime(@script))
      return puts("  hook ready:   #{@script}") || false if steps.empty?

      print_steps(steps)
      true
    end

    private

    def print_steps(steps)
      puts
      puts "  Hermes hook: #{@script}"
      puts "  The hook does not run yet. Do these steps one time."
      puts
      steps.each_with_index { |step, index| puts format_step(step, index) }
    end

    def format_step(step, index)
      lines = ["    #{index + 1}. #{step[:title]}", "         #{step[:command]}"]
      lines << "         #{step[:note]}" if step[:note]
      "#{lines.join("\n")}\n"
    end

    def steps(mtime)
      steps = [declare_step, approve_step(mtime)].reject { |step| step[:done] }
      steps << check_step unless steps.empty?
      steps
    end

    def declare_step
      { done: HermesHook.declared?(File.join(@home, "config.yaml"), @script),
        title: "Declare the hook in the Hermes config:",
        command: HermesHook.config_command(@script),
        note: "Keep your other on_session_end entries. Add this entry to that list." }
    end

    def approve_step(mtime)
      { done: HermesHook.approved?(File.join(@home, "shell-hooks-allowlist.json"), @script, mtime),
        title: "Approve the hook one time:",
        command: HermesHook.approve_command,
        note: "Hermes stores the consent for this version of the script." }
    end

    def check_step
      { done: false, title: "Check the hook:", command: HermesHook.check_command, note: nil }
    end
  end
end
