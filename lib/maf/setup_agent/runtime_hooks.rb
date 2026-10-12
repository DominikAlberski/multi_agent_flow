# frozen_string_literal: true

require_relative "../bootstrap"

module Maf
  module SetupAgent
    # Refresh owned hooks before the harness starts in an existing worktree.
    module RuntimeHooks
      def self.install(dir, harness)
        %w[next-task.rb board-watch.rb session-guard.rb context-watch.rb].each { |name| copy(dir, name) }
        Maf::Shared::Harness.fetch(harness).runtime_hooks(dir)
      end

      def self.copy(dir, name, relative = ".maf/coordination/harness-hooks/#{name}")
        path = File.join(dir, relative)
        abort "maf: #{path} is a foreign hook; the worker was not started" if foreign?(path, name)

        Flow::HookFiles.copy(File.join(Flow::ASSETS, "harness-hooks", name), path)
      end

      def self.foreign?(path, name)
        File.exist?(path) && !File.read(path).include?("#{name} -")
      end
    end
  end
end
