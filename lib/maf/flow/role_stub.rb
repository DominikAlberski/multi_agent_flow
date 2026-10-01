# frozen_string_literal: true

module Flow
  # RoleStub adds a stub role to .maf/roles.yml. The stub holds the four duty
  # parts. A role that exists already stays as it is.
  class RoleStub
    TEMPLATE = File.join(TEMPLATES, "role-stub.yml.erb")

    def initialize(project, name)
      @catalog = RoleCatalog.new(project)
      @name = name
    end

    # Returns :create or :skip.
    def add
      abort "flow: invalid role name '#{@name}' (use a-z, 0-9, hyphen)" unless @name.match?(/\A[a-z][a-z0-9-]*\z/)
      return :skip if @catalog.custom.key?(@name)

      write
      :create
    end

    private

    def write
      FileUtils.mkdir_p(File.dirname(@catalog.path))
      File.write(@catalog.path, existing + entry)
    end

    def existing
      @catalog.custom.empty? ? "roles:\n" : File.read(@catalog.path).sub(/\n*\z/, "\n\n")
    end

    def entry = ERB.new(File.read(TEMPLATE), trim_mode: "-").result_with_hash(name: @name)
  end
end
