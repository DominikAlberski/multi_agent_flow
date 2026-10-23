# frozen_string_literal: true

require "open3"
require_relative "../prompt"

module Maf
  class Vm
    # Login copies the login of each harness from the host into the VM.
    class Login
      # The command runs in the VM. It writes stdin to a new file with mode 600,
      # then moves the file to ~/DEST. An old file at DEST does not keep its mode.
      WRITE = 'cd && umask 077 && mkdir -p "$(dirname "$1")" && tmp=$(mktemp "$1.XXXXXX") && ' \
              'cat > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$1"'

      def initialize(name, harnesses, mode, prompt = Prompt.new)
        @name = name
        @harnesses = harnesses
        @mode = mode
        @prompt = prompt
      end

      def run = @harnesses.each { |harness| copy?(harness) ? copy(harness) : hint(harness) }

      private

      def copy?(harness)
        return false if harness.vm_credentials.empty? || @mode == :none

        @mode == :all || @prompt.confirm?("Copy your #{harness.name} login from this computer into the VM?")
      end

      def copy(harness)
        logins = harness.vm_credentials.filter_map { |credential| (text = credential.read) && [credential.dest, text] }
        return hint(harness, "maf found no login on this computer. ") if logins.empty?

        logins.each { |dest, text| written?(dest, text) || abort(not_running) }
        @prompt.say("copied  #{harness.name} login")
      end

      def not_running = "maf: cannot write to the VM #{@name}. Run: maf vm start"

      def written?(dest, text)
        command = [LIMACTL, "shell", "--workdir", "/", @name, "sh", "-c", WRITE, "sh", "--", dest]
        Open3.capture2e(*command, stdin_data: text).last.success?
      end

      def hint(harness, reason = "")
        @prompt.say("#{harness.name}: #{reason}Log in in the VM: #{harness.vm_login_hint}")
      end
    end
  end
end