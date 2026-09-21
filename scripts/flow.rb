#!/usr/bin/env ruby
# frozen_string_literal: true

# flow.rb - generate harness-specific agent files for the multi-agent flow.
#
# Usage:
#   ruby scripts/flow.rb --project DIR --agent HARNESS:ROLE [--agent ...] \
#        [--model ROLE=MODEL] [--hermes-dir DIR] [--check] [--force] [--no-bootstrap]
#   ruby scripts/flow.rb --list-roles
#
# HARNESS is one of: opencode, claude, codex, hermes.
# Idempotent: identical files are skipped, changed files are updated, and
# foreign files are refused unless --force is given.
require "fileutils"
require "yaml"
require "erb"
require "json"
require "optparse"
require "rbconfig"
require "time"

module Flow
  ROOT = File.expand_path("..", __dir__)
  TEMPLATES = File.join(ROOT, "templates")
  ASSETS = File.join(ROOT, "assets")
  HARNESSES = %w[opencode claude codex hermes].freeze
  DEFAULT_HERMES_DIR = File.join(Dir.home, ".hermes", "skills")

  WORKER_LOOP = <<~LOOP
    Work loop:
    1. Read messages: `./coord inbox`.
    2. List unclaimed tasks for your role: `./coord next`.
    3. Claim one: `./coord claim <id>`.
    4. Do the work. Stay inside the task scope.
    5. Before any local model generation: `./coord with-lock ollama -- <command>`.
    6. Report: `./coord annotate <id> "<short summary>"`.
    7. Finish: `./coord done <id>`.

    Rules:
    - You are one worker in a role pool. COORD_WORKER identifies you.
    - One writer per path. Never edit outside the task scope.
    - Do not create tasks. Ask the architect: `./coord msg --from %{role} architect "<text>"`.
    - If no task is available, wait 60 seconds before checking again. Do not spin.
    - Record durable knowledge in the shared vault or `docs/decisions/`.
  LOOP

  ARCHITECT_LOOP = <<~LOOP
    Work loop:
    1. Read the request and the shared knowledge base.
    2. Decompose it into tasks. Keep scopes disjoint (one writer per path).
    3. Create each task:
         ./coord add --agent <role> --scope "<paths>" --title "<title>"
    4. Watch progress: `./coord status`, `./coord conflicts`, `./coord inbox architect`.
    5. Answer worker questions. Resolve conflicts. Close finished tasks.
    6. Record decisions in `docs/decisions/`.

    Available roles: %{roles}.
    Rules:
    - Never edit files directly. Dispatch work.
    - Take the `ollama` lock only if you run a local model yourself.
  LOOP

  class Generator
    def initialize(argv)
      @argv = argv
      @project = nil
      @agents = []
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
      write_manifest
      print_instructions(results)
    end

    private

    def parse
      option_parser.parse!(@argv)
    end

    def option_parser
      OptionParser.new do |o|
        o.banner = "Usage: ruby scripts/flow.rb --project DIR --agent HARNESS:ROLE [--agent ...]"
        o.on("--project DIR") { |v| @project = v }
        o.on("--agent SPEC", "HARNESS:ROLE[:MODEL]") { |v| @agents << parse_agent(v) }
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
      validate_agents
    end

    def validate_project
      abort "flow: --project is required" if @project.nil?
      abort "flow: project is not a directory: #{@project}" unless Dir.exist?(@project)

      @project = File.realpath(@project)
    end

    def validate_agents
      abort "flow: at least one --agent HARNESS:ROLE is required" if @agents.empty?

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

      ensure_claude_md
      args = [RbConfig.ruby, File.join(ASSETS, "bootstrap.rb"), @project, "--roles", roles_arg]
      args << "--force" if @force
      ok = system(*args)
      abort "flow: coordination bootstrap failed" unless ok
    end

    # bootstrap.rb only appends the contract to an existing CLAUDE.md (it
    # doesn't know which harnesses were requested, so it never creates one
    # unprompted). If this run actually asked for the claude harness, create
    # an empty CLAUDE.md first so bootstrap has something to append to.
    def ensure_claude_md
      return unless @agents.any? { |a| a[:harness] == "claude" }

      path = File.join(@project, "CLAUDE.md")
      FileUtils.touch(path) unless File.exist?(path)
    end

    def roles_arg
      @agents.map { |a| a[:role] }.uniq.join(",")
    end

    def generate
      @agents.map { |agent| generate_agent(agent) }
    end

    def generate_agent(agent)
      role = agent[:role]
      model = agent[:model] || @models[role]
      dest = destination(agent[:harness], role)
      content = render(agent[:harness], role, @roles.fetch(role), model)
      { agent: agent, dest: dest, status: write(dest, content), model: model }
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
        prompt: build_prompt(role, data),
        model: model,
        can_edit: data.fetch("can_edit")
      )
    end

    def build_prompt(role, data)
      role == "architect" ? architect_prompt(data) : worker_prompt(role, data)
    end

    def worker_prompt(role, data)
      "#{intro(data)}\n\n#{duties_block(data)}\n\n#{format(WORKER_LOOP, role: role)}"
    end

    def architect_prompt(data)
      "#{intro(data)} You do not implement code yourself.\n\n#{duties_block(data)}\n\n" \
        "#{format(ARCHITECT_LOOP, roles: roles_arg)}"
    end

    def intro(data)
      "You are the #{data.fetch("title")} for this project."
    end

    def duties_block(data)
      lines = data.fetch("duties").strip.lines.map { |line| "  #{line}" }
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
        agents: @agents.map { |a| { harness: a[:harness], role: a[:role], model: a[:model] || @models[a[:role]] } }
      }
      # Only record hermes_dir when it differs from the default: the default is
      # an absolute home path that would leak into a committed manifest.
      data[:hermes_dir] = @hermes_dir unless @hermes_dir == DEFAULT_HERMES_DIR
      File.write(path, JSON.pretty_generate(data))
    end

    def print_instructions(results)
      puts
      puts "Generated agent files:"
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
      puts "In the architect session, describe what you want built."
    end

    def print_unembeddable(results)
      list = results.select { |r| r[:model] && %w[codex hermes].include?(r[:agent][:harness]) }
      return if list.empty?

      puts
      puts "These harnesses cannot embed a model in the agent file. Set it in the harness:"
      list.each { |r| puts "  #{r[:agent][:harness]}:#{r[:agent][:role]} -> #{model_command(r)}" }
    end

    def model_command(result)
      result[:agent][:harness] == "codex" ? "codex -m #{result[:model]}" : "hermes model"
    end
  end
end

Flow::Generator.new(ARGV).run
