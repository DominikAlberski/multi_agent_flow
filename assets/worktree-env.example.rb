# frozen_string_literal: true

# worktree-env.rb - example project hook for `coord worktree` (Rails).
#
# Copy this file to coordination/worktree-env.rb and commit it.
# `coord worktree` runs the hook for each worktree and appends the output
# to the worktree's coord-env.sh.
#
# Input:  COORD_SLOT (1, 2, ...; the main worktree is slot 0) and
#         COORD_WORKTREE (absolute path of the worktree).
# Output: one `export NAME=VALUE` line per variable. Other lines are ignored
#         by `maf start`.
#
# Use the variables in the project, for example in config/database.yml:
#   test:
#     database: app_test<%= ENV["TEST_ENV_NUMBER"] %>
# Then create each worktree's test database one time:
#   bin/rails db:test:prepare

slot = ENV.fetch("COORD_SLOT").to_i

puts "export TEST_ENV_NUMBER=#{slot}"
puts "export PORT=#{3000 + slot}"
puts "export CAPYBARA_SERVER_PORT=#{4000 + slot}"
