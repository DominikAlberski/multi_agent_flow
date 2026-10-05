# frozen_string_literal: true

module Bootstrap
  # Project holds the target directory and answers questions about the files
  # in it. Planners and the writer share one Project.
  class Project
    APPEND_FILES = { taskrc: "taskrc.append", contract: "agents-contract.md", gitignore: "gitignore.append",
                     post_commit: "git-hooks/post-commit", post_merge: "git-hooks/post-merge" }.freeze

    attr_reader :target, :assets

    def initialize(target, force)
      @target = File.realpath(target)
      @force = force
      @assets = File.expand_path("../../../assets", __dir__)
    end

    def path(*parts)
      File.join(@target, *parts)
    end

    # A script that this tool copies from assets/NAME into .maf/bin/.
    def bin_path(name)
      path(MAF_DIR, "bin", name)
    end

    def force?
      @force
    end

    def ours?(file, signature)
      File.read(file).include?(signature)
    end

    def marked?(file)
      File.exist?(file) && ours?(file, MARKER)
    end

    def changed_script?(dest, name)
      File.read(dest) != File.read(File.join(@assets, name))
    end

    # Status of a script that this tool copies from assets/NAME to DEST.
    def script_status(dest, name, signature)
      return :create unless File.exist?(dest)
      return :refuse if File.directory?(dest) || (!ours?(dest, signature) && !force?)

      ours?(dest, signature) && !changed_script?(dest, name) ? :skip : :update
    end

    def taskrc_path
      path(MAF_DIR, "coordination", "taskrc")
    end

    def taskdata_path
      path(MAF_DIR, "coordination", "taskdata")
    end

    def append_content(source)
      File.read(File.join(@assets, APPEND_FILES.fetch(source)))
    end

    def action(kind, file, label = file, source = nil)
      { kind: kind, path: file, label: label, source: source }
    end

    def refuse_label(status, file, text = "exists and is not ours; use --force")
      status == :refuse ? "#{file} (#{text})" : file
    end

    ACTION_WORDS = { skip: "skip  ", refuse: "REFUSE", upgrade_taskrc: "upgrade" }.freeze

    def format_action(act) = "#{ACTION_WORDS.fetch(act[:kind], act[:kind])} #{act[:label]}"
  end
end
