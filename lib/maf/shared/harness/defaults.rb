# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
require_relative "../project"
require_relative "vm_credential"

module Maf
  module Shared
    module Harness
      AGENTS_DIR = File.join(".maf", "agents")
      # The command of the graphify MCP server. It runs in the project folder.
      VAULT_MCP = %w[ruby .maf/bin/vault mcp].freeze

      # RoleFiles: maf add writes one role file per agent.
      module RoleFiles
        # The folder where the harness reads role files. maf links it to
        # .maf/agents/<name>/. nil: the harness reads no role folder.
        def role_dir = nil
        def role_path(role) = role_dir && File.join(AGENTS_DIR, name, "#{role}.md")

        # settings: the data of .maf/config.json. A harness that keeps role
        # files outside the project reads its folder there.
        def role_destination(project, role, _settings = {}) = role_path(role) && File.join(project, role_path(role))

        # An ERB template. It gets role, title, description, can_edit, project, prompt, and model.
        def role_template = raise(NotImplementedError, "#{name}: role_template")
        def render_role(values) = ERB.new(role_template, trim_mode: "-").result_with_hash(**values)

        # nil: the harness lists no models, so every name counts as known.
        def models = nil
        # list: the models of the harness. A caller with a cached list passes it.
        def known_model?(model, list = models) = list.nil? || list.include?(model)
        def default_model = nil

        # The command that sets the model, for a harness whose role file cannot set it.
        def model_hint(_model) = nil

        # How an idle agent waits for work. :watch - a watcher wakes the idle
        # session. :await - the stop hook waits after `coord await`.
        # :poll - the agent blocks in `coord next --wait`.
        def wait = :poll

        # One more rule line for the architect prompt, or nil.
        def architect_rule = nil
      end

      # Setup: maf add, maf start, bootstrap, untrack, retire, and uninstall.
      module Setup
        # The graphify MCP server in a config file of the flow:
        # { file: ".maf/mcp/x.json", key: "mcpServers", entry: {...} }. nil: no file.
        def mcp = nil
        # The command that adds the server to a global config of the harness, or nil.
        def mcp_command(_server, _vault) = nil
        # The project file where an older maf wrote the MCP server, or nil.
        def legacy_mcp_file = nil

        # maf add installs the hooks. A truthy result: the user has steps left.
        def install_hooks(_project) = nil
        # maf start refreshes the hooks in the worktree before the session starts.
        def runtime_hooks(_worktree) = nil
        # Bootstrap installs the hooks of the harness only if this folder exists.
        def bootstrap_dir = nil

        # Uninstall: objects with #steps that remove the files of the flow.
        def cleaners(_project) = []
        # Uninstall and untrack: objects with #steps that remove what an older
        # maf wrote into the project's own files.
        def legacy_cleaners(_project) = []
        # Files outside the project that uninstall keeps: other projects can use them.
        def global_files = []

        # The shell command that installs the CLI in a Linux VM (maf vm create).
        # nil: the user installs the CLI in the VM.
        def vm_install = nil
        # The login files that maf vm can copy into the VM (VmCredential). []: the user logs in in the VM.
        def vm_credentials = []
        # How to log in in the VM when maf cannot copy the login.
        def vm_login_hint = "maf vm shell, then start #{command} and log in"

        # The top folder of the harness. maf retire ignores changes in it.
        def home_dir = role_dir&.split("/")&.first
        # Files that the flow writes in a worktree. coord keeps them out of git.
        def runtime_files = []
        # Folders that uninstall removes when they are empty. Children come first.
        def empty_dirs = [role_dir, home_dir].compact.uniq

        # The paths that git tracks for the flow. tracked.call(path) lists the
        # tracked files below path. By default, the links into .maf/agents/.
        def untrack_paths(root, tracked)
          return [] unless role_dir

          tracked.call(role_dir).select do |path|
            File.symlink?(File.join(root, path)) && File.readlink(File.join(root, path)).include?(AGENTS_DIR)
          end
        end
      end

      # Run: maf start (an interactive session) and the dispatcher (one run per task).
      module Run
        # The command of an interactive session.
        def launch(_role, _model) = raise(NotImplementedError, "#{name}: launch")
        def launch_env = {}

        # The sandbox (Maf::Shared::Sandbox) lets the harness write to these
        # folders, and to the files that start with a prefix. Both are outside the project.
        def sandbox_dirs = []
        def sandbox_prefixes = []
        # A harness with its own OS sandbox turns it off: a sandbox cannot start inside a sandbox.
        def sandboxed(cmd) = cmd

        # The command of one dispatched run. session_id is nil for a fresh session.
        def build_command(_config, _prompt, _session_id) = raise(NotImplementedError, "#{name}: build_command")
        def run_env(_config) = {}
        # The dispatcher calls it once after it parses the options.
        def prepare(config) = config
        # Seconds that the prompt cache of the harness stays warm, or nil for the default.
        def cache_window = nil
        def peak_rate?(_config) = false

        # The parts of the run output. nil: the harness does not report it.
        def stale_session?(_output) = false
        def session_id(_output) = nil
        def result_text(_output) = nil
        def usage(_output) = nil
        def context(_output) = nil
        def model(_output) = nil

        # A file of the flow in .maf/ of the main checkout. The dispatcher finds
        # .maf/ next to its coordination folder, which COORD_DIR can move.
        def flow_file(*parts) = File.join(Project.root, ".maf", *parts)
        def run_file(config, *parts) = File.join(File.dirname(config.coord_dir), *parts)
        def flag_if(flag, path) = File.exist?(path) ? [flag, path] : []

        def present(value) = value.to_s.empty? ? nil : value
        def model_flag(model, flag = "--model") = model ? [flag, model] : []
        def resume(session_id, *flag) = session_id ? [*flag, session_id] : []
      end
    end
  end
end
