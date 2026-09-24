#!/usr/bin/env ruby
# frozen_string_literal: true

# flow.rb - generate harness-specific role files for the multi-agent flow.
#
# Usage:
#   ruby scripts/flow.rb --project DIR [--agent HARNESS:ROLE ...] [--remove HARNESS:ROLE ...] \
#        [--model ROLE=MODEL] [--hermes-dir DIR] [--check] [--force] [--no-bootstrap]
#   ruby scripts/flow.rb --list-roles
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
  ROOT = File.expand_path("..", __dir__)
  TEMPLATES = File.join(ROOT, "templates")
  ASSETS = File.join(ROOT, "assets")
  HARNESSES = %w[opencode claude codex hermes].freeze
  DEFAULT_HERMES_DIR = File.join(Dir.home, ".hermes", "skills")

  # Model a harness gets when neither --agent nor --model names one.
  # Other harnesses have no safe default, so their CLI picks the model.
  DEFAULT_MODELS = { "claude" => "claude-opus-5-5" }.freeze

  # Roles that dispatch or coordinate instead of implementing. They are never
  # advertised as dispatch targets in the architect prompt.
  DISPATCH_EXCLUDE = %w[architect project-manager].freeze

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

  WORKER_LOOP = <<~LOOP
    Work loop:
    1. Read messages: `./coord inbox`.
    2. List unclaimed tasks for your role: `./coord next`.
    3. Claim one: `./coord claim <id>`.
    4. Do the work. Stay inside the task scope.
    5. Before any local model generation: `./coord with-lock ollama -- <command>`.
    6. Run the tests. Check the task's acceptance criteria.
    7. Report. If the task spec has a Report format, use it. Otherwise use:
         ./coord annotate <id> "STATUS: done or blocked. FILES: <paths>. TESTS: <one-line result>. NOTES: <assumptions or risks>"
    8. Finish: `./coord done <id>`.

    Rules:
    - You are one worker in a role pool. COORD_WORKER identifies you.
    - One writer per path. Never edit outside the task scope.
    - Do not create tasks. Ask the architect: `./coord msg --from %{role} architect "<text>"`.
    - Finish the whole task. Report done only when each acceptance criterion passes.
    - If you cannot finish, do the parts you can. Keep the claim. Annotate the
      blocker and the missing parts. Message the architect. Stop. Do not retry
      a failing approach.
    %{no_task_instruction}
    - Record durable knowledge in the shared vault or `docs/decisions/`.
    - Never write ad-hoc verification scripts. The test suite is the verification.
    #{STE_RULE}
    #{SUBAGENT_RULE}
  LOOP

  # The architect takes goals from the project manager when that role exists,
  # and takes requests from the user directly when it does not. Two variants so
  # the generated file never points at a role nobody runs.
  ARCHITECT_LOOP_PM = <<~LOOP
    Work loop:
    1. Read goals from the project manager: `./coord inbox architect`.
    2. Decompose each goal into tasks. Keep scopes disjoint (one writer per path).
    3. Create each task, then add its spec:
         ./coord add --role <role> --scope "<paths>" --title "<title>"
         ./coord annotate <id> "Goal: <goal>. Inputs: <files or context>. Out of scope: <paths or work>. Acceptance: <done condition>. Report format: <what to annotate>."
    4. Watch progress: `./coord status`, `./coord conflicts`, `./coord inbox architect`.
    5. Answer worker questions. Resolve conflicts.
    6. Before you trust a done task, inspect its diff and rerun its tests in the
       worker's worktree: `git -C ../<project>.worktrees/<role>-<worker> diff`.
       If something is wrong, open a new task for the fix.
    7. Report back: `./coord msg --from architect project-manager "<summary>"`.
    8. Record decisions in `docs/decisions/`.
    9. Use `./coord broadcast --from architect "<text>"` for scope changes or
       blockers that affect every worker. Use `./coord log` to see what happened.

    Available roles:
    %{roles}

    Rules:
    - Never edit files directly. Dispatch work.
    - Take goals only from the project manager. Never take requests directly from the user.
    - Take the `ollama` lock only if you run a local model yourself.
    #{STE_RULE}
    #{SUBAGENT_RULE}
  LOOP

  ARCHITECT_LOOP_DIRECT = <<~LOOP
    Work loop:
    1. Read the user's request from this session.
    2. Decompose the request into tasks. Keep scopes disjoint (one writer per path).
    3. Create each task, then add its spec:
         ./coord add --role <role> --scope "<paths>" --title "<title>"
         ./coord annotate <id> "Goal: <goal>. Inputs: <files or context>. Out of scope: <paths or work>. Acceptance: <done condition>. Report format: <what to annotate>."
    4. Watch progress: `./coord status`, `./coord conflicts`.
    5. Answer worker questions. Resolve conflicts.
    6. Before you trust a done task, inspect its diff and rerun its tests in the
       worker's worktree: `git -C ../<project>.worktrees/<role>-<worker> diff`.
       If something is wrong, open a new task for the fix.
    7. Report the outcome to the user in this session.
    8. Record decisions in `docs/decisions/`.
    9. Use `./coord broadcast --from architect "<text>"` for scope changes or
       blockers that affect every worker. Use `./coord log` to see what happened.

    Available roles:
    %{roles}

    Rules:
    - Never edit files directly. Dispatch work.
    - Take requests from the user directly. This project has no project manager.
    - Take the `ollama` lock only if you run a local model yourself.
    #{STE_RULE}
    #{SUBAGENT_RULE}
  LOOP

  PM_LOOP = <<~LOOP
    Work loop:
    1. Read the user's request.
    2. Turn it into one goal. Hand it to the architect:
         ./coord msg --from project-manager architect "<goal>"
    3. Wait for the architect's report: `./coord inbox project-manager --wait`.
    4. Summarize the report for the user.
    5. Record decisions in `docs/decisions/`.

    Rules:
    - Never edit files directly. Never create tasks; only the architect creates tasks.
    - Send goals to the architect only. Never dispatch work to other roles directly.
    - If no report has arrived yet, tell the user and check again with `./coord inbox project-manager`.
    #{STE_RULE}
    #{SUBAGENT_RULE}
  LOOP

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
      run_bootstrap
      results = generate
      install_hooks unless @check
      write_manifest
      print_instructions(results)
    end

    private

    def parse
      option_parser.parse!(@argv)
    end

    def option_parser
      OptionParser.new do |o|
        o.banner = "Usage: ruby scripts/flow.rb --project DIR [--agent HARNESS:ROLE ...] [--remove HARNESS:ROLE ...]"
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

    def validate_agents
      abort "flow: no agents. Add one with --agent HARNESS:ROLE" if @agents.empty?

      @agents.each { |agent| validate_agent(agent) }
    end

    def validate_agent(agent)
      unless HARNESSES.include?(agent[:harness])
        abort "flow: unknown harness '#{agent[:harness]}' (use #{HARNESSES.join(", ")})"
      end
      abort "flow: unknown role '#{agent[:role]}'" unless @roles.key?(agent[:role])
    end

    def run_bootstrap
      return unless @bootstrap
      return if @check

      # Bootstrap adds the Claude Code hooks only if .claude/ exists. Flow
      # writes .claude/agents/ after bootstrap, so create .claude/ first.
      FileUtils.mkdir_p(File.join(@project, ".claude")) if @agents.any? { |a| a[:harness] == "claude" }
      args = [RbConfig.ruby, File.join(ASSETS, "bootstrap.rb"), @project, "--roles", roles_arg]
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
      when "opencode" then File.join(@project, ".opencode", "agents", "#{role}.md")
      when "claude"   then File.join(@project, ".claude", "agents", "#{role}.md")
      when "codex"    then File.join(@project, ".codex", "prompts", "#{role}.md")
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
      data = {
        generated_at: Time.now.utc.iso8601,
        agents: @agents.map { |a| { harness: a[:harness], role: a[:role], model: model_for(a) } }
      }
      # Only record hermes_dir when it differs from the default: the default is
      # an absolute home path that would leak into a committed manifest.
      data[:hermes_dir] = @hermes_dir unless @hermes_dir == DEFAULT_HERMES_DIR
      File.write(path, JSON.pretty_generate(data))
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
      hooks_dir = File.join(Dir.home, ".hermes", "agent-hooks")
      FileUtils.mkdir_p(hooks_dir)
      dest = File.join(hooks_dir, "next-task.sh")
      src  = File.join(ASSETS, "harness-hooks", "next-task-hermes.sh")
      if !File.exist?(dest) || File.read(dest) != File.read(src)
        FileUtils.cp(src, dest)
        FileUtils.chmod("+x", dest)
        puts "  hook install: #{dest}"
      end
      config_yaml = File.join(Dir.home, ".hermes", "config.yaml")
      return if hermes_hook_configured?(config_yaml, dest)

      puts
      puts "  Hermes hook: add the following block to ~/.hermes/config.yaml:"
      puts "  (If a hooks: key already exists, merge on_session_end into it.)"
      puts
      puts hermes_hook_yaml_snippet(dest).gsub(/^/, "  ")
      @hermes_hook_pending = true
    end

    def hermes_hook_configured?(config_yaml, script_path)
      return false unless File.exist?(config_yaml)
      content = File.read(config_yaml)
      content.include?(script_path) || content.include?("next-task.sh")
    end

    def hermes_hook_yaml_snippet(script_path)
      <<~YAML
        hooks:
          on_session_end:
            - command: "#{script_path}"
              timeout: 30
      YAML
    end

    def print_instructions(results)
      puts
      puts "Generated role files:"
      results.each { |result| puts generated_line(result) }
      print_missing_models(results)
      print_unembeddable(results)
      print_sessions(results)
    end

    def generated_line(result)
      "  #{result[:status].to_s.ljust(7)} #{result[:agent][:harness]}:" \
        "#{result[:agent][:role]} -> #{result[:dest]}"
    end

    def print_missing_models(results)
      missing = results.reject { |result| result[:model] }
      return if missing.empty?

      puts
      puts "No model chosen for these roles. flow.rb leaves the choice to you. Suggestions:"
      missing.each { |result| puts "  #{result[:agent][:role]}: #{model_hint(result)}" }
      puts "  Set one with: --model <role>=<provider/model>"
    end

    def model_hint(result)
      @roles.fetch(result[:agent][:role]).fetch("model_hint")
    end

    def print_sessions(results)
      puts
      puts "Next: open one session per agent in #{@project}, in the chosen harness:"
      results.each { |result| puts "  - #{result[:agent][:harness]} -> #{result[:agent][:role]}" }
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

Flow::Generator.new(ARGV).run if __FILE__ == $PROGRAM_NAME
