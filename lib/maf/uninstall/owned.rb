# frozen_string_literal: true

module Maf
  module Uninstall
    module Owned
      def self.signed?(path, signature) = File.file?(path) && File.read(path).include?(signature)
      def self.marked?(path) = signed?(path, Bootstrap::MARKER)
      def self.prune(dir) = Dir.exist?(dir) && Dir.empty?(dir) && Dir.rmdir(dir)
      def self.remove(path) = Step.new("remove #{path}", -> { FileUtils.rm(path) })
    end
  end
end
