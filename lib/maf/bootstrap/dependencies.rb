# frozen_string_literal: true

module Bootstrap
  # Dependencies reports required and optional tools. It installs the
  # required tools only when the options ask for it.
  class Dependencies
    def initialize(options)
      @options = options
    end

    def report
      REQUIRED_DEPS.each { |bin, meta| report_required(bin, meta) }
      OPTIONAL_DEPS.each { |bin, hint| report_optional(bin, hint) }
    end

    private

    def report_required(bin, meta)
      return Bootstrap.say("#{bin}: present") if Bootstrap.which(bin)
      return install(bin, meta) if @options.install_deps && !@options.check

      Bootstrap.say("#{bin}: MISSING (required - #{meta[:why]}). Re-run with --install-deps or install it yourself.")
    end

    def install(bin, meta)
      Bootstrap.say("#{bin}: missing -> installing (#{meta[:why]})")
      meta[:install].call || abort("bootstrap: failed to install #{bin}")
    end

    def report_optional(bin, hint)
      state = Bootstrap.which(bin) ? "present" : "missing (optional - #{hint})"
      Bootstrap.say("#{bin}: #{state}")
    end
  end
end
