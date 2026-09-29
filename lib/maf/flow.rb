# frozen_string_literal: true

# flow.rb - generate harness-specific role files for the multi-agent flow.
#
# maf add, maf remove, maf update, and maf roles run Flow::Generator.
# Options: --project DIR [--agent HARNESS:ROLE ...] [--remove HARNESS:ROLE ...]
#          [--model ROLE=MODEL] [--hermes-dir DIR] [--check] [--force] [--no-bootstrap]
#          [--list-roles]
#
# HARNESS is one of: opencode, claude, codex, hermes.
# A re-run keeps the agents in .agent-flow.json. --agent adds an agent.
# --remove drops an agent. Without --agent, a re-run regenerates the current agents.
# Idempotent: identical files are skipped, changed files are updated, and
# foreign files are refused unless --force is given.
require "fileutils"
require "yaml"
require "erb"
require "json"
require "optparse"
require "rbconfig"
require "time"

abort "flow: Ruby 3.0+ required (current: #{RUBY_VERSION})." if RUBY_VERSION.split(".").first.to_i < 3

module Flow
  ROOT = File.expand_path("../..", __dir__)
  TEMPLATES = File.join(ROOT, "templates")
  ASSETS = File.join(ROOT, "assets")
  HARNESSES = %w[opencode claude codex hermes].freeze
  DEFAULT_HERMES_DIR = File.join(Dir.home, ".hermes", "skills")

  # Model a harness gets when neither --agent nor --model names one.
  # Other harnesses have no safe default, so their CLI picks the model.
  DEFAULT_MODELS = { "claude" => "claude-opus-5-5" }.freeze

  # Roles that dispatch or coordinate instead of implementing. They are never
  # advertised as dispatch targets in the architect prompt.
  LEADS = %w[project-manager architect].freeze
  DISPATCH_EXCLUDE = LEADS

  # Hermes toolsets for a role with can_edit false: no file, code_execution,
  # or delegation toolset. The shell stays, because the role needs ./coord and git.
  # NOTE: assets/dispatcher carries the same list; both run standalone.
  READ_ONLY_TOOLSETS = "terminal,web,skills,todo,memory,session_search,clarify"

  # Applies to every `coord msg`, `coord annotate`, and task title/scope an
  # agent writes. Generated role files ship standalone (opencode/codex/hermes
  # sessions never see the user's own CLAUDE.md), so the rules are spelled
  # out here instead of referenced.
  STE_RULE = <<~TEXT.strip
    - Write `coord msg`, `coord annotate`, and task titles in Simplified
      Technical English: one instruction per sentence, active voice, name the
      subject, max 20 words per sentence, no idioms.
  TEXT

  # Current Claude models start subagents readily and verify their own work
  # without a prompt. Each subagent adds cost and time, so keep the use small.
  SUBAGENT_RULE = <<~TEXT.strip
    - Do the work yourself. Start a subagent only for a large, independent
      search that you cannot finish in a few tool calls.
    - Do not use subagents to verify your work.
  TEXT

  NO_TASK_STOP = "- If no task and no message is available, stop. The board watcher wakes you when work arrives."
  NO_TASK_WAIT = <<~TEXT.strip
    - If no task is available, run `./coord next --wait --timeout 540`. It returns
      when a task or a message arrives. If it times out, run it again. Do not poll by hand.
  TEXT

  DECISIONS = "the decisions folder: `.agent/decisions/` if it exists, else `docs/decisions/`"

  WORKER_LOOP = <<~LOOP
    Work loop:
    1. Read messages: `./coord inbox`.
    2. List unclaimed tasks for your role: `./coord next`.
    3. Claim one: `./coord claim <id>`.
    4. Check out the task branch: `./coord start-task <id>`. It starts from the goal branch.
    5. Do the work. Stay inside the task scope.
    6. Before any local model generation: `./coord with-lock ollama -- <command>`.
    7. If the task has a goal, merge the goal branch into the task branch: `git merge goal/<goal-short-id>`.
       Then run the task tests. Do not run the merge suite. Check the task's acceptance criteria.
       `./coord done` refuses a task branch that lacks the goal branch head.
    8. Commit the work on the task branch. The architect merges the task branch.
    9. Report. If the task spec has a Report format, use it. Otherwise use:
         ./coord annotate <id> "STATUS: done or blocked. FILES: <paths>. TESTS: <one-line result>. NOTES: <assumptions or risks>"
    10. Finish: `./coord done <id>`.

    Rules:
    - You are one worker in a role pool. COORD_WORKER identifies you.
    - One writer per path. Never edit outside the task scope.
    - Do not create tasks. Ask the architect: `./coord msg --from %{role} architect "<text>"`.
    - Finish the whole task. Report done only when each acceptance criterion passes.
    - If you cannot finish, do the parts you can. Keep the claim. Annotate the
      blocker and the missing parts. Message the architect. Stop. Do not retry
      a failing approach.
    %{no_task_instruction}
    - Record durable knowledge in the shared vault or #{DECISIONS}.
    - Never write ad-hoc verification scripts. The test suite is the verification.
    #{STE_RULE}
    #{SUBAGENT_RULE}
  LOOP

  # Steps 2 to 9 are the same with and without a project manager.
  ARCHITECT_GOAL_STEPS = <<~TEXT.strip
    2. Decompose the goal into tasks. Keep scopes disjoint (one writer per path).
    3. Create each task with the goal id, then add its spec:
         ./coord add --role <role> --scope "<paths>" --goal <goal-id> --title "<title>"
         ./coord annotate <id> "Goal: <goal>. Inputs: <files or context>. Out of scope: <paths or work>. Acceptance: <done condition>. Report format: <what to annotate>."
    4. Watch progress: `./coord goal show <goal-id>`, `./coord conflicts`, `./coord inbox architect`.
       Each done task sends you a message. A task for a role without a worker alerts the project manager.
    5. Answer worker questions. Resolve conflicts.
    6. Before you trust a done task, inspect its diff and its TESTS line:
       `git diff goal/<goal-short-id>...task/<task-short-id>`. Do not rerun the task tests.
       If something is wrong, open a new task for the fix. Name the old task branch in Inputs.
    7. Merge each accepted task branch into the goal worktree:
       `git -C .worktrees/goal-<goal-short-id> merge task/<task-short-id>`.
       If the merge conflicts, run `git merge --abort` and open a fix task.
    8. When every task of the goal is merged, run the merge suite one time in the goal worktree:
       `./coord with-lock system-test -- <merge suite command>`. Source its `coord-env.sh` first.
    9. Close the goal: `./coord goal done <goal-id>`. The pull request starts from branch goal/<goal-short-id>.
  TEXT

  ARCHITECT_RULES = <<~TEXT.strip
    - Never edit files directly. Dispatch work. Merges of task branches are allowed.
    - Start each goal from the base branch. Never start a goal from another goal branch.
    - Take the `ollama` lock only if you run a local model yourself.
  TEXT

  # The architect takes goals from the project manager when that role exists,
  # and takes requests from the user directly when it does not. Two variants so
  # the generated file never points at a role nobody runs.
  ARCHITECT_LOOP_PM = <<~LOOP
    Work loop:
    1. Read goals from the project manager: `./coord inbox architect`. Each goal message names a goal id.
    #{ARCHITECT_GOAL_STEPS}
    10. Report back: `./coord msg --from architect project-manager "<summary>"`.
    11. Record decisions in #{DECISIONS}.
    12. Use `./coord broadcast --from architect "<text>"` for notices to workers.
        Add `--to all` only for a change that the project manager must know. Use `./coord log` to see what happened.

    Available roles:
    %{roles}

    Rules:
    #{ARCHITECT_RULES}
    - Take goals only from the project manager. Never take requests directly from the user.
    #{STE_RULE}
    #{SUBAGENT_RULE}
  LOOP

  ARCHITECT_LOOP_DIRECT = <<~LOOP
    Work loop:
    1. Read the user's request from this session. Create a goal for it:
       `./coord goal add --title "<outcome>"`. The command prints the goal id.
    #{ARCHITECT_GOAL_STEPS}
    10. Report the outcome to the user in this session.
    11. Record decisions in #{DECISIONS}.
    12. Use `./coord broadcast --from architect "<text>"` for notices to workers.
        Use `./coord log` to see what happened.

    Available roles:
    %{roles}

    Rules:
    #{ARCHITECT_RULES}
    - Take requests from the user directly. This project has no project manager.
    #{STE_RULE}
    #{SUBAGENT_RULE}
  LOOP

  # The user can give the project manager a budget (`maf team set`) and let it
  # run the team. Dispatched workers cost no tokens while idle, so the rules
  # scale on backlog, not on cost.
  TEAM_RULES = <<~TEXT.strip
    - If the user gives you a team budget, record it: `maf team set --max <n> --allow <harness[:model]> ...`.
      Then manage the team yourself in dispatch mode. `maf prepare ... --dispatch` starts the worker in the background.
    - Check the team with `maf team`. It shows the budget, each worker, and the tasks by role.
    - Staff the architect first, with `--dispatch`. A goal needs the architect before any other worker.
      A dispatched architect starts on each message. An idle interactive architect reads nothing.
    - Check who runs with `./coord who`. A role without a live worker does not read its messages.
    - If coord reports "No worker runs role <role>", add a worker for that role.
    - If a role has more than three backlog tasks and the budget has a free slot, add a worker for that role.
    - If a role has no tasks and no open goal needs it, retire its extra workers. Keep one worker per role that an open goal needs.
    - If the budget is full, replace an idle worker: `--replace <idle-worker>`.
    - Report each team change to the user in one line.
  TEXT

  PM_LOOP = <<~LOOP
    Work loop:
    1. Read the user's request.
    2. Turn it into one goal. Create the goal: `./coord goal add --title "<outcome>"`.
       The command prints the goal id and creates the goal branch.
    3. Hand the goal to the architect:
         ./coord msg --from project-manager architect "GOAL <goal-id>: <goal>"
    4. Check status with `./coord goal list` and `./coord goal show <goal-id>`.
       Wait for reports with `./coord inbox project-manager --wait`.
    5. Summarize the report for the user.
    6. Record decisions in #{DECISIONS}.

    Rules:
    - Never edit source files. Never create tasks; only the architect creates tasks.
    - Change the team when the user asks. Do not ask the user to run setup steps.
      Add a worker: `maf prepare <harness> <role>_<n>`.
      Replace a worker: `maf prepare <harness> <role>_<n> --replace <old-role>_<n>`.
      Remove a worker: `maf retire <role>_<n>`.
      Give the user the two commands that `maf prepare` prints: `cd <worktree>` and `maf start`.
      If `maf` reports that the old worker still runs, ask the user to stop that session. Then run the command again.
    #{TEAM_RULES}
    - Run goals in parallel only if the goals change different parts of the code.
    - Send goals to the architect only. Never dispatch work to other roles directly.
    - If no report has arrived yet, tell the user and check again with `./coord inbox project-manager`.
    #{STE_RULE}
    #{SUBAGENT_RULE}
  LOOP

  PROJECT_ROLE_PATHS = { "opencode" => ".opencode/agents/%s.md", "claude" => ".claude/agents/%s.md",
                         "codex" => ".codex/prompts/%s.md" }.freeze

  # The role file path inside the project. Hermes keeps role files outside
  # the project, so it has no path here.
  def self.role_path(harness, role)
    template = PROJECT_ROLE_PATHS[harness]
    template && format(template, role)
  end

  # HermesHook reports the state of the hook that picks up tasks when a Hermes
  # session ends. Hermes keeps hooks in the global config.yaml and asks for a
  # one-time consent, so the flow prints commands instead of editing the file.
  # Every method takes a path, so a test can use fixtures.
  module HermesHook
    EVENT = "on_session_end"
    SCRIPT_NAME = "next-task.sh"
    TIMEOUT = 30
    # Hermes rounds the recorded approval time to microseconds, so compare with
    # a small tolerance. A rewritten hook moves the mtime far past it.
    MTIME_TOLERANCE = 2

    def self.declared?(config_yaml, script_path)
      return false unless File.exist?(config_yaml)

      content = File.read(config_yaml)
      content.include?(script_path) || content.include?(SCRIPT_NAME)
    end

    def self.approved?(allowlist, script_path, mtime)
      entry = approvals(allowlist).find { |item| item["command"] == script_path && item["event"] == EVENT }
      return false unless entry

      recorded = Time.iso8601(entry["script_mtime_at_approval"].to_s)
      (mtime - recorded).abs <= MTIME_TOLERANCE
    rescue ArgumentError, TypeError
      false
    end

    def self.approvals(allowlist)
      return [] unless File.exist?(allowlist)

      JSON.parse(File.read(allowlist)).fetch("approvals", [])
    rescue JSON::ParserError
      []
    end

    def self.config_command(script_path)
      %(hermes config set hooks.#{EVENT} '[{"command":"#{script_path}","timeout":#{TIMEOUT}}]')
    end

    def self.approve_command = "hermes chat --oneshot --accept-hooks -q ok"

    def self.check_command = "hermes hooks doctor"
  end

  class Generator
    def initialize(argv)
      @argv = argv
      @project = nil
      @agents = []
      @removed = []
      @models = {}
      @hermes_dir = DEFAULT_HERMES_DIR
      @check = false
      @force = false
      @bootstrap = true
      @list_roles = false
    end

    def run
      parse
      @roles = YAML.load_file(File.join(TEMPLATES, "roles.yml")).fetch("roles")
      return print_roles if @list_roles
      validate
      return finish_without_agents if @agents.empty?

      run_bootstrap
      results = generate
      install_hooks unless @check
      write_manifest
      print_instructions(results)
    end

    # Flags that take a value. maf uses them to tell flag values from agent specs.
    def self.value_flags = new([]).value_flags

    def value_flags
      option_parser.top.list.grep(OptionParser::Switch::RequiredArgument).flat_map(&:long)
    end

    private

    def parse
      option_parser.parse!(@argv)
    end

    def option_parser
      OptionParser.new do |o|
        o.banner = "Usage: maf add|remove|update [HARNESS:ROLE ...] [options]"
        o.on("--project DIR") { |v| @project = v }
        o.on("--agent SPEC", "HARNESS:ROLE[:MODEL]") { |v| @agents << parse_agent(v) }
        o.on("--remove SPEC", "HARNESS:ROLE") { |v| @removed << parse_agent(v) }
        o.on("--model PAIR", "ROLE=MODEL") { |v| k, m = v.split("=", 2); @models[k] = m }
        o.on("--hermes-dir DIR") { |v| @hermes_dir = File.expand_path(v) }
        o.on("--check") { @check = true }
        o.on("--force") { @force = true }
        o.on("--no-bootstrap") { @bootstrap = false }
        o.on("--list-roles") { @list_roles = true }
        o.on("-h", "--help") { puts o; exit 0 }
      end
    end

    def parse_agent(spec)
      harness, role, model = spec.split(":", 3)
      { harness: harness, role: role, model: model }
    end

    def print_roles
      puts "Available roles (model_hint is a recommendation only):"
      @roles.each do |key, data|
        puts
        puts "  #{key}"
        puts "    #{data.fetch("description")}"
        puts "    model hint: #{data.fetch("model_hint")}"
      end
    end

    def validate
      validate_project
      @agents = Roster.new(@project).merge(@agents, @removed)
      validate_agents
    end

    def validate_project
      abort "flow: --project is required" if @project.nil?
      abort "flow: project is not a directory: #{@project}" unless Dir.exist?(@project)

      @project = File.realpath(@project)
    end

    # A removal may leave no agents. Only a run that removes nothing needs one.
    def validate_agents
      abort "flow: no agents. Add one with --agent HARNESS:ROLE" if @agents.empty? && @removed.empty?

      @agents.each { |agent| validate_agent(agent) }
    end

    def validate_agent(agent)
      unless HARNESSES.include?(agent[:harness])
        abort "flow: unknown harness '#{agent[:harness]}' (use #{HARNESSES.join(", ")})"
      end
      abort "flow: unknown role '#{agent[:role]}'" unless @roles.key?(agent[:role])
    end

    def finish_without_agents
      write_manifest
      puts "No agents left. Add one: maf add HARNESS:ROLE. Remove the flow: maf uninstall."
    end

    def run_bootstrap
      return unless @bootstrap
      return if @check

      # Bootstrap adds the Claude Code hooks only if .claude/ exists. Flow
      # writes .claude/agents/ after bootstrap, so create .claude/ first.
      FileUtils.mkdir_p(File.join(@project, ".claude")) if @agents.any? { |a| a[:harness] == "claude" }
      args = [RbConfig.ruby, File.join(__dir__, "bootstrap.rb"), @project, "--roles", roles_arg]
      args << "--force" if @force
      ok = system(*args)
      abort "flow: coordination bootstrap failed" unless ok
    end

    def roles_arg
      @agents.map { |a| a[:role] }.uniq.join(",")
    end

    # What the architect can dispatch to: this run's worker roles, not every
    # role in roles.yml. Advertising a role nobody generated a session for
    # means tasks pile up unclaimed forever.
    def dispatch_roles
      @agents.map { |a| a[:role] }.uniq - DISPATCH_EXCLUDE
    end

    def dispatch_roles_text
      return "  (none requested yet in this run)" if dispatch_roles.empty?

      dispatch_roles.map { |r| "  - #{r}: #{@roles.fetch(r).fetch("description")}" }.join("\n")
    end

    def generate
      @agents.map { |agent| generate_agent(agent) }
    end

    def generate_agent(agent)
      role = agent[:role]
      model = model_for(agent)
      dest = destination(agent[:harness], role)
      content = render(agent[:harness], role, @roles.fetch(role), model)
      { agent: agent, dest: dest, status: write(dest, content), model: model }
    end

    def model_for(agent)
      agent[:model] || @models[agent[:role]] || agent[:saved_model] || DEFAULT_MODELS[agent[:harness]]
    end

    def destination(harness, role)
      case harness
      when "opencode", "claude", "codex" then File.join(@project, Flow.role_path(harness, role))
      # Hermes skills live in a global ~/.hermes/skills/ directory, not the
      # project. Namespace by project so two projects using the same role
      # don't overwrite each other's skill.
      when "hermes"   then File.join(@hermes_dir, "#{File.basename(@project)}-#{role}", "SKILL.md")
      end
    end

    def render(harness, role, data, model)
      template = File.read(File.join(TEMPLATES, "#{harness}.md.erb"))
      ERB.new(template, trim_mode: "-").result_with_hash(
        role: role,
        title: data.fetch("title"),
        description: data.fetch("description"),
        prompt: build_prompt(harness, role, data),
        model: model,
        can_edit: data.fetch("can_edit")
      )
    end

    def build_prompt(harness, role, data)
      case role
      when "project-manager" then project_manager_prompt(data)
      when "architect" then architect_prompt(data)
      else worker_prompt(harness, role, data)
      end
    end

    def worker_prompt(harness, role, data)
      "#{intro(data)}\n\n#{duties_block(data)}\n\n#{format(WORKER_LOOP, role: role, no_task_instruction: no_task_line(harness))}"
    end

    # Only Claude Code can wake an idle session (the board-watch hook). Other
    # harnesses block in `coord next --wait`, which also returns on a message.
    def no_task_line(harness)
      harness == "claude" ? NO_TASK_STOP : NO_TASK_WAIT
    end

    def architect_prompt(data)
      loop_text = project_manager? ? ARCHITECT_LOOP_PM : ARCHITECT_LOOP_DIRECT
      "#{intro(data)} You do not implement code yourself.\n\n#{duties_block(data)}\n\n" \
        "#{format(loop_text, roles: dispatch_roles_text)}"
    end

    def project_manager?
      @agents.any? { |a| a[:role] == "project-manager" }
    end

    def project_manager_prompt(data)
      "#{intro(data)} You do not plan tasks or implement code yourself.\n\n" \
        "#{duties_block(data)}\n\n#{PM_LOOP}"
    end

    def intro(data)
      "You are the #{data.fetch("title")} for this project."
    end

    def duties_block(data)
      lines = data.fetch("duties").strip.lines.map { |line| line.strip.empty? ? line : "  #{line}" }
      "Duties:\n#{lines.join}"
    end

    def write(dest, content)
      existed = File.exist?(dest)
      return :skip if existed && File.read(dest) == content
      return :refuse if existed && refuse?(dest)
      return :check if @check

      FileUtils.mkdir_p(File.dirname(dest))
      File.write(dest, content)
      existed ? :update : :create
    end

    def refuse?(dest)
      !File.read(dest).include?(">>> multi-agent-flow >>>") && !@force
    end

    def write_manifest
      return if @check
      path = File.join(@project, ".agent-flow.json")
      data = kept_manifest_keys(path).merge(
        "generated_at" => Time.now.utc.iso8601,
        "agents" => @agents.map { |a| manifest_entry(a) }
      )
      # Only record hermes_dir when it differs from the default: the default is
      # an absolute home path that would leak into a committed manifest.
      data["hermes_dir"] = @hermes_dir unless @hermes_dir == DEFAULT_HERMES_DIR
      File.write(path, JSON.pretty_generate(data))
    end

    # can_edit lets maf start, the dispatcher, and the git commit guard limit
    # a role without the role definitions.
    def manifest_entry(agent)
      { harness: agent[:harness], role: agent[:role], model: model_for(agent),
        can_edit: @roles.fetch(agent[:role]).fetch("can_edit") }
    end

    # Other tools own other keys (maf team: "team"; users: "base_branch").
    # A re-run must keep them.
    def kept_manifest_keys(path)
      return {} unless File.exist?(path)

      JSON.parse(File.read(path)).except("generated_at", "agents", "hermes_dir")
    rescue JSON::ParserError
      {}
    end

    def install_hooks
      harnesses = @agents.map { |a| a[:harness] }.uniq
      harnesses.each { |h| install_harness_hooks(h) }
    end

    def install_harness_hooks(harness)
      case harness
      when "codex"  then install_codex_hooks
      when "hermes" then install_hermes_hooks
      end
    end

    def install_codex_hooks
      hooks_dir = File.join(Dir.home, ".codex", "hooks")
      FileUtils.mkdir_p(hooks_dir)
      dest = File.join(hooks_dir, "next-task.rb")
      src  = File.join(ASSETS, "harness-hooks", "next-task.rb")
      if !File.exist?(dest) || File.read(dest) != File.read(src)
        FileUtils.cp(src, dest)
        FileUtils.chmod("+x", dest)
        puts "  hook install: #{dest}"
      end
      merge_codex_stop_hook(File.join(Dir.home, ".codex", "hooks.json"), dest)
    end

    def merge_codex_stop_hook(hooks_json, script_path)
      data = File.exist?(hooks_json) ? (JSON.parse(File.read(hooks_json)) rescue {}) : {}
      data["hooks"] ||= {}
      data["hooks"]["Stop"] ||= []
      return if data["hooks"]["Stop"].any? { |e| e.dig("hooks", 0, "command").to_s.include?("next-task.rb") }

      data["hooks"]["Stop"] << {
        "matcher" => "",
        "hooks" => [{ "type" => "command", "command" => "ruby #{script_path}" }]
      }
      File.write(hooks_json, JSON.pretty_generate(data))
      puts "  hook merge:   #{hooks_json} (Stop hook added)"
    end

    def install_hermes_hooks
      dest = install_hermes_hook_script
      steps = hermes_hook_steps(dest, File.mtime(dest))
      return puts("  hook ready:   #{dest}") if steps.empty?

      print_hermes_hook_steps(dest, steps)
      @hermes_hook_pending = true
    end

    def install_hermes_hook_script
      hooks_dir = File.join(Dir.home, ".hermes", "agent-hooks")
      FileUtils.mkdir_p(hooks_dir)
      dest = hermes_hook_script
      src  = File.join(ASSETS, "harness-hooks", "next-task-hermes.sh")
      if !File.exist?(dest) || File.read(dest) != File.read(src)
        FileUtils.cp(src, dest)
        FileUtils.chmod("+x", dest)
        puts "  hook install: #{dest}"
      end
      dest
    end

    def hermes_hook_script = File.join(Dir.home, ".hermes", "agent-hooks", HermesHook::SCRIPT_NAME)
    def hermes_config_yaml = File.join(Dir.home, ".hermes", "config.yaml")
    def hermes_allowlist = File.join(Dir.home, ".hermes", "shell-hooks-allowlist.json")

    # The flow never edits the Hermes config: the file is comment-rich, and
    # Hermes guards it as security-sensitive. Print the commands instead, and
    # print only the step that is still missing.
    def print_hermes_hook_steps(dest, steps)
      puts
      puts "  Hermes hook: #{dest}"
      puts "  The hook does not run yet. Do these steps one time."
      puts
      steps.each_with_index { |step, index| puts hermes_hook_step(step, index) }
    end

    def hermes_hook_step(step, index)
      lines = ["    #{index + 1}. #{step[:title]}", "         #{step[:command]}"]
      lines << "         #{step[:note]}" if step[:note]
      "#{lines.join("\n")}\n"
    end

    def hermes_hook_steps(dest, mtime)
      steps = [hermes_declare_step(dest), hermes_approve_step(dest, mtime)]
      steps.reject! { |step| step[:done] }
      steps << hermes_check_step unless steps.empty?
      steps
    end

    def hermes_declare_step(dest)
      { done: HermesHook.declared?(hermes_config_yaml, dest),
        title: "Declare the hook in the Hermes config:",
        command: HermesHook.config_command(dest),
        note: "Keep your other on_session_end entries. Add this entry to that list." }
    end

    def hermes_approve_step(dest, mtime)
      { done: HermesHook.approved?(hermes_allowlist, dest, mtime),
        title: "Approve the hook one time:",
        command: HermesHook.approve_command,
        note: "Hermes stores the consent for this version of the script." }
    end

    def hermes_check_step
      { done: false, title: "Check the hook:", command: HermesHook.check_command, note: nil }
    end

    def print_instructions(results)
      puts
      puts "Generated role files:"
      results.each { |result| puts generated_line(result) }
      print_missing_models(results)
      print_unembeddable(results)
      print_sessions(results)
      print_hermes_hook_reminder
    end

    # The hook steps print at install time, far above the last lines the user
    # reads. Repeat the state here so the flow is not started with a dead hook.
    def print_hermes_hook_reminder
      return unless @hermes_hook_pending

      puts "The Hermes hook is not active yet. Finish the steps above."
      puts "Then run `maf update` to confirm the hook is ready."
    end

    def generated_line(result)
      "  #{result[:status].to_s.ljust(7)} #{result[:agent][:harness]}:" \
        "#{result[:agent][:role]} -> #{result[:dest]}"
    end

    def print_missing_models(results)
      missing = results.reject { |result| result[:model] }
      return if missing.empty?

      puts
      puts "No model chosen for these roles. maf leaves the choice to you. Suggestions:"
      missing.each { |result| puts "  #{result[:agent][:role]}: #{model_hint(result)}" }
      puts "  Set one with: --model <role>=<provider/model>"
    end

    def model_hint(result)
      @roles.fetch(result[:agent][:role]).fetch("model_hint")
    end

    def print_sessions(results)
      puts
      puts "Next: start one session per agent in #{@project}:"
      results.each { |result| puts "  maf start #{result[:agent][:harness]} #{result[:agent][:role]}" }
      puts
      puts "In each worker session, paste:"
      puts %(  "Run ./coord inbox <role>. Then work the pending tasks assigned to you. Repeat.")
      puts entry_point_hint(results)
    end

    def entry_point_hint(results)
      roles = results.map { |result| result[:agent][:role] }
      return "Talk to the project manager session. It hands goals to the architect." if roles.include?("project-manager")

      "In the architect session, describe what you want built."
    end

    def print_unembeddable(results)
      list = results.select { |r| r[:model] && %w[codex hermes].include?(r[:agent][:harness]) }
      return if list.empty?

      puts
      puts "These harnesses cannot embed a model in the role file. Set it in the harness:"
      list.each { |r| puts "  #{r[:agent][:harness]}:#{r[:agent][:role]} -> #{model_command(r)}" }
    end

    def model_command(result)
      result[:agent][:harness] == "codex" ? "codex -m #{result[:model]}" : "hermes model"
    end
  end

  # Roster merges the agents saved in .agent-flow.json with the --agent and
  # --remove specs of this run. A saved model ranks below --model.
  class Roster
    def initialize(project)
      path = File.join(project, ".agent-flow.json")
      @saved = File.exist?(path) ? JSON.parse(File.read(path)).fetch("agents", []) : []
    end

    def merge(added, removed)
      kept = saved.map { |a| added.find { |b| same?(a, b) }&.merge(saved_model: a[:saved_model]) || a }
      agents = kept + added.reject { |b| kept.any? { |a| same?(a, b) } }
      agents.reject { |a| removed.any? { |b| same?(a, b) } }
    end

    private

    def saved
      @saved.map { |a| { harness: a["harness"], role: a["role"], saved_model: a["model"] } }
    end

    def same?(one, other) = one[:harness] == other[:harness] && one[:role] == other[:role]
  end
end
