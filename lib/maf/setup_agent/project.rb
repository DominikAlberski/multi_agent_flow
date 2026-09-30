# frozen_string_literal: true

module SetupAgent
  # Project finds the main checkout from any worktree. `git rev-parse
  # --git-common-dir` returns the main repo's .git dir (relative at the root,
  # absolute in a worktree), so its parent is the main checkout.
  # NOTE: dispatcher carries the same logic; both run standalone.
  module Project
    def self.root
      common = IO.popen(%w[git rev-parse --git-common-dir], err: File::NULL, &:read).to_s.strip
      common.empty? ? Dir.pwd : File.dirname(File.expand_path(common))
    end

    def self.manifest
      JSON.parse(File.read(File.join(root, MANIFEST)))
    rescue Errno::ENOENT, JSON::ParserError
      {}
    end
  end
end
