# frozen_string_literal: true

module SetupAgent
  # Args reads the positional arguments (HARNESS ROLE[_WORKER] [model:M]),
  # then the flags. --dispatch and --model M are setup_agent's own flags; all
  # other flags go to the dispatcher and need --dispatch.
  class Args
    Parsed = Struct.new(:harness, :role, :worker_id, :worker, :model, :dispatch, :detach, :dispatcher_args,
                        keyword_init: true)

    def self.parse(argv)
      dispatch, detach, positional, flags = split(argv)
      model = take_model(flags)
      reject_stray(flags, dispatch)
      abort "setup_agent: --detach works only with --dispatch" if detach && !dispatch
      Parsed.new(**identity(positional, model, dispatch), dispatch: dispatch, detach: detach, dispatcher_args: flags)
    end

    def self.split(argv)
      rest = argv - %w[--dispatch --detach]
      index = rest.index { |arg| arg.start_with?("--") } || rest.size
      [argv.include?("--dispatch"), argv.include?("--detach"), rest[0...index], rest[index..-1]]
    end

    def self.identity(positional, model, dispatch)
      harness, role_spec, model_arg = positional
      abort_usage if harness.nil? || role_spec.nil?
      role, worker_id = split_role(role_spec, dispatch ? "bot" : "1")
      { harness: harness, role: role, worker_id: worker_id, worker: "#{role}-#{worker_id}",
        model: model || model_arg&.sub(/\Amodel:/, "") }
    end

    def self.take_model(flags)
      index = flags.index("--model")
      value = index && flags.slice!(index, 2)[1]
      abort "setup_agent: --model needs a value" if index && (value.nil? || value.start_with?("--"))
      value
    end

    def self.reject_stray(flags, dispatch)
      return if flags.empty? || dispatch

      abort "setup_agent: #{flags.join(" ")} works only with --dispatch"
    end

    def self.split_role(spec, default_id = "1")
      role, _sep, worker_id = spec.rpartition("_")
      role.empty? ? [spec, default_id] : [role, worker_id]
    end

    def self.abort_usage
      abort "usage: maf start HARNESS ROLE[_WORKER] [model:MODEL] [--model MODEL] [--dispatch [FLAGS...]]"
    end
  end
end
