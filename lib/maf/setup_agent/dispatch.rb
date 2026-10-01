# frozen_string_literal: true

module SetupAgent
  # Dispatch runs dispatcher in the worktree instead of an interactive
  # session. The worktree's own copy of the dispatcher is used, so the
  # project must have committed it. The current Ruby runs it, so an old
  # system Ruby on the shebang path never parses it.
  module Dispatch
    DISPATCHER = ".maf/bin/dispatcher"

    def self.launch(args, model)
      require_dispatcher!
      cmd = [RbConfig.ruby, DISPATCHER, args.role, "--harness", args.harness]
      cmd += ["--model", model] if model
      cmd += args.dispatcher_args
      args.detach ? detach(cmd, args.worker) : Launcher.exec_or_die(cmd)
    end

    # setsid gives the dispatcher its own session, so it keeps running when
    # the terminal or the harness session that started it ends.
    def self.detach(cmd, worker)
      log = File.join(ENV.fetch("COORD_DIR"), "sessions", "#{worker}.log")
      pid = spawn_detached(cmd, log)
      Maf::Workers.at(Project.root).update(worker, "pid" => pid)
      puts "Started #{worker} in the background (pid #{pid}). Log: #{log}"
    end

    def self.spawn_detached(cmd, log)
      FileUtils.mkdir_p(File.dirname(log))
      io = { in: File::NULL, out: [log, "a"], err: %i[child out] }
      pid = fork { Process.setsid && exec({ "DISPATCHER_LOG" => log, "PWD" => Dir.pwd }, *cmd, **io) }
      Process.detach(pid) && pid
    end

    def self.require_dispatcher!
      return if File.exist?(DISPATCHER)

      main = ENV["COORD_DIR"] ? File.dirname(File.expand_path(ENV["COORD_DIR"])) : nil
      hint = main ? "\n  Fix:\n    cd #{main}\n    git add .maf/bin && git commit -m 'Add dispatcher'\n  Then re-run setup_agent." \
                  : " Commit dispatcher from your main project directory first, then re-run."
      abort "setup_agent: dispatcher missing in this worktree (worktrees only contain committed files).#{hint}"
    end
  end
end
