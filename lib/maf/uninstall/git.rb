# frozen_string_literal: true

module Maf
  module Uninstall
    module Git
      def self.lines(project, *args)
        IO.popen(["git", "-C", project, *args], err: File::NULL, &:readlines).map(&:chomp)
      rescue Errno::ENOENT
        []
      end
    end
  end
end
