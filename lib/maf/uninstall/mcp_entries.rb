# frozen_string_literal: true

module Uninstall
  # Removes the graphify server that maf add wrote into .mcp.json and
  # opencode.json. A foreign entry and all other settings stay. A file goes
  # only if nothing else is left in it.
  class McpEntries
    def initialize(project)
      @files = Flow::McpConfig.targets.values.map { |t| [File.join(project, t[:file]), t] }
    end

    def steps
      @files.filter_map do |path, target|
        next unless File.exist?(path) && ours?(read(path), target)

        Step.new("remove the graphify server from #{path}", -> { clean(path, target) })
      end
    end

    private

    def read(path)
      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError
      {}
    end

    def ours?(data, target) = data.dig(target[:key], Flow::McpConfig::NAME) == target[:entry]

    def clean(path, target)
      data = read(path)
      section = data.fetch(target[:key]).except(Flow::McpConfig::NAME)
      data = section.empty? ? data.except(target[:key]) : data.merge(target[:key] => section)
      data.except("$schema").empty? ? FileUtils.rm(path) : File.write(path, "#{JSON.pretty_generate(data)}\n")
    end
  end
end
