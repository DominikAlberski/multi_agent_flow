# frozen_string_literal: true

module Maf
  module Flow
    # SandboxPolicy writes the mode and the scope of .maf/sandbox.json.
    # A new install gets DEFAULT. A later run changes the file only for a --sandbox flag.
    class SandboxPolicy
      FILE = File.join(MAF_DIR, "sandbox.json")
      CHOICES = { "mode" => %w[off auto seatbelt bwrap], "scope" => %w[dispatch all] }.freeze
      DEFAULT = { "mode" => "auto", "scope" => "dispatch" }.freeze
      HINT = "  Change it with: maf add --sandbox off|auto|seatbelt|bwrap --sandbox-scope dispatch|all"

      def self.validate!(chosen)
        chosen.each do |key, value|
          allowed = CHOICES.fetch(key)
          abort "flow: unknown sandbox #{key} '#{value}' (use #{allowed.join(", ")})" unless allowed.include?(value)
        end
      end

      def initialize(options)
        @options = options
        @fresh = !File.exist?(File.join(options.project, MAF_DIR, "config.json"))
      end

      def write
        return if @options.check? || (!@fresh && @options.sandbox.empty?)

        @policy = (@fresh ? DEFAULT.merge(current) : current).merge(@options.sandbox)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{JSON.pretty_generate(@policy)}\n")
      end

      def report
        return unless @policy

        puts "", "Sandbox: #{summary} (#{FILE})", HINT
        warn_bwrap if bwrap? && !bwrap_installed?
      end

      private

      def path = File.join(@options.project, FILE)

      def current
        File.exist?(path) ? JSON.parse(File.read(path)) : {}
      rescue JSON::ParserError
        abort "flow: #{FILE} is not valid JSON. Fix the file, or delete it."
      end

      def mode = @policy["mode"] || "off"
      def summary = mode == "off" ? "off" : "#{mode}, scope #{@policy["scope"] || "dispatch"}"
      def bwrap? = mode == "bwrap" || (mode == "auto" && !RUBY_PLATFORM.include?("darwin"))
      def bwrap_installed? = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { File.executable?("#{_1}/bwrap") }

      def warn_bwrap
        puts "WARNING: the Linux sandbox needs bubblewrap 0.10 or later. Install it before a dispatched run,",
             "  or turn the sandbox off: maf add --sandbox off"
      end
    end
  end
end
