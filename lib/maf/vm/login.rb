# frozen_string_literal: true

require "open3"
require_relative "../prompt"

module Maf
  class Vm
    # Login copies the login of each harness from the host into the VM. maf asks
    # the user first, for each harness. mode: :ask, :all (copy without a
    # question), or :none (copy nothing). A harness that maf cannot copy gets a hint.
    class Login
      # The command runs in the VM. It writes stdin to ~/DEST, readable by the user only.
      WRITE = 'cd && umask 077 && mkdir -p "$(dirname "$1")" && cat > "$1"'

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

        @mode == :all || @prompt.confirm?("Copy your #{harness.name} login from this Mac into the VM?")
      end

      def copy(harness)
        logins = harness.vm_credentials.filter_map { |credential| (text = credential.read) && [credential.dest, text] }
        return hint(harness, "maf found no login on this Mac. ") if logins.empty?

        logins.each { |dest, text| written?(dest, text) || abort(not_running) }
        @prompt.say("copied  #{harness.name} login")
      end

      def not_running = "maf: cannot write to the VM #{@name}. Run: maf vm start"

      def written?(dest, text)
        command = [LIMACTL, "shell", "--workdir", "/", @name, "sh", "-c", WRITE, "sh", dest]
        Open3.capture2e(*command, stdin_data: text).last.success?
      end

      def hint(harness, reason = "")
        @prompt.say("#{harness.name}: #{reason}Log in in the VM: #{harness.vm_login_hint}")
      end
    end
  end
end
