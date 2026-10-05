# frozen_string_literal: true

module Bootstrap
  # HookMerger puts the flow block at the top of a git hook. The rest of the
  # hook stays. A hook in another language than sh stays as it is.
  class HookMerger
    SH_SHEBANG = %r{\A#!\s*(?:/usr/bin/env\s+)?(?:\S*/)?(?:ba)?sh(?:\s|\z)}

    def initialize(project)
      @project = project
    end

    # Returns true when the hook changed.
    def merge(file, source)
      return skip_foreign_hook(file) if foreign_interpreter?(file)

      body = File.exist?(file) ? MarkedBlock.new(File.read(file)).remove : "#!/bin/sh\n"
      write_hook(file, prepend_block(body, @project.append_content(source)))
    end

    private

    def foreign_interpreter?(file)
      return false unless File.exist?(file)

      first = File.open(file, &:gets).to_s
      first.start_with?("#!") && !first.match?(SH_SHEBANG)
    end

    def skip_foreign_hook(file)
      Bootstrap.say("skip   #{file}: foreign hook with a non-sh shebang, doc-graph refresh is off")
      false
    end

    def prepend_block(body, block)
      shebang, rest = split_shebang(body)
      "#{shebang}#{block.chomp}\n#{rest.lstrip}"
    end

    def split_shebang(body)
      first, *rest = body.lines
      first&.start_with?("#!") ? [first, rest.join] : ["", body]
    end

    def write_hook(file, text)
      File.write(file, text)
      FileUtils.chmod("+x", file)
      true
    end
  end
end
