# frozen_string_literal: true

require_relative "lib/maf/version"

Gem::Specification.new do |spec|
  spec.name = "maf"
  spec.version = Maf::VERSION
  spec.authors = ["Dominik Alberski"]

  spec.summary = "Run several AI coding agents in parallel on one repository."
  spec.description = "multi-agent-flow is a coordination layer for AI coding agents (Claude Code, Codex, " \
                     "opencode, Hermes). Each agent works in its own git worktree. The agents share a " \
                     "Taskwarrior task board, file locks, and a knowledge graph through the coord CLI."
  spec.homepage = "https://github.com/DominikAlberski/multi_agent_flow"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # The gem holds the code, the assets that maf copies into a project, the
  # templates, and install.md (maf guide prints it).
  shipped = %w[lib/ exe/ assets/ templates/]
  docs = %w[install.md README.md LICENSE.txt CHANGELOG.md]
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).select { |f| f.start_with?(*shipped) || docs.include?(f) }
  end
  spec.bindir = "exe"
  spec.executables = ["maf"]
  spec.require_paths = ["lib"]

  # Ruby 3.0 and later do not include webrick. The dashboard needs it.
  spec.add_dependency "webrick", "~> 1.8"
end
