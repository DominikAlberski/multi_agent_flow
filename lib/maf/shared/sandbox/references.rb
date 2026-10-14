# frozen_string_literal: true

# maf shared library - code that the maf CLI and the scripts in .maf/bin share.
# The installer copies this folder to .maf/lib/maf/shared/. maf update replaces it.
# Use the Ruby stdlib only: a script loads this file without a gem bundle.
require "json"

module Maf
  module Shared
    module Sandbox
      # References finds the files that a config file of a harness names.
      module References
        # A path in a command or a setting: ~/x, $HOME/x, ${HOME}/x, or /x.
        PATH = %r{(?:~|\$\{?HOME\}?)?/[^\s"'`;|&()<>,\\]+}
        # A relative path with a folder (scripts/hook.sh). A hook runs in the project folder.
        RELATIVE = /(?<![\w.\/~}$-])[\w.-]+(?:\/[\w.-]+)+/
        # An import in a Markdown file: @path, at the start of a line or after a space.
        # A period or a comma after the path ends the sentence.
        IMPORT = /(?:^|\s)@([^\s]+?)[.,;:!?)]*(?=\s|$)/
        # Claude Code sets this variable to the project folder for a hook. It becomes ".", so RELATIVE finds the path.
        PROJECT_DIR = /\$\{?CLAUDE_PROJECT_DIR\}?/
        DEPTH = 5
        MAX_SIZE = 1_000_000

        def self.of(files, root, keep) = walk(files, root, DEPTH).select(&keep)

        def self.walk(files, root, depth)
          found = files.flat_map { |file| named_in(file, root) }.uniq - files
          depth.zero? || found.empty? ? found : (found + walk(found, root, depth - 1)).uniq
        end

        def self.named_in(file, root)
          text = read(file)
          paths = file.end_with?(".md") ? imports(text, file) : commands(text, file, root)
          paths.select { |path| File.file?(path) }
        rescue SystemCallError, ArgumentError
          []
        end

        def self.imports(text, file) = text.scan(IMPORT).flatten.map { |path| expand(path, file) }

        def self.commands(text, file, root)
          text = text.gsub(PROJECT_DIR, ".")
          text.scan(PATH).map { |path| expand(path, file) } +
            text.scan(RELATIVE).map { |path| File.expand_path(path, root) }
        end

        def self.read(file)
          text = File.file?(file) && File.size(file) < MAX_SIZE ? File.read(file) : ""
          file.end_with?(".json") ? without_permissions(text) : text
        end

        def self.without_permissions(text)
          data = JSON.parse(text)
          data.is_a?(Hash) ? JSON.generate(data.except("permissions")) : text
        rescue JSON::ParserError
          text
        end

        def self.expand(path, file) = File.expand_path(path.sub(/\A\$\{?HOME\}?/, "~"), File.dirname(file))
      end
    end
  end
end
