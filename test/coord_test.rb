#!/usr/bin/env ruby
# frozen_string_literal: true

# test/coord_test.rb - behavioral tests for assets/coord.
#
# Run: ruby test/coord_test.rb
#
# Scopes tests are pure and always run. Taskwarrior tests are real
# integration tests against a disposable, project-local task database (never
# the global ~/.task); they skip cleanly if `task` is not installed.
require "minitest/autorun"
require "tmpdir"
# `coord` has no .rb suffix (it's an installed executable), so `require` can't
# find it; `load` takes the literal path instead.
load File.expand_path("../assets/coord", __dir__)

# An agent session exports TASKRC/COORD_DIR for the shared board. A test must
# never use them. This module points the process at the test's own board and
# restores the session values after the test.
module CoordEnvIsolation
  KEYS = %w[TASKRC COORD_DIR COORD_ROLE COORD_WORKER].freeze

  def isolate_env(env)
    @inherited_env = KEYS.to_h { |key| [key, ENV[key]] }
    KEYS.each { |key| ENV[key] = env[key] }
  end

  def restore_env
    return unless @inherited_env

    @inherited_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def assert_isolated_env(env)
    KEYS.each { |key| assert_equal env[key], ENV[key], "the test leaked #{key}" }
  end
end

class ScopesTest < Minitest::Test
  def test_prefix_overlap_is_detected
    assert Coord::Scopes.overlap?("src/**", "src/utils/**")
  end

  def test_disjoint_scopes_do_not_overlap
    refute Coord::Scopes.overlap?("src/queries/**", "src/models/**")
  end

  def test_exact_paths_do_not_false_positive_on_shared_prefix
    refute Coord::Scopes.overlap?("src/foo.rb", "src/foobar.rb")
  end
end

class ArgsTest < Minitest::Test
  def test_take_command_splits_at_the_separator
    args = Coord::Args.new(["ollama", "--ttl", "30", "--", "echo", "--ttl", "5"])
    assert_equal "ollama", args.shift

    command = args.take_command

    assert_equal ["echo", "--ttl", "5"], command
    assert_equal 30, args.ttl
  end

  def test_take_command_returns_nil_without_a_separator
    assert_nil Coord::Args.new(["echo", "hi"]).take_command
  end
end

class LeaseTest < Minitest::Test
  def with_lease_env(value)
    old = ENV["COORD_LEASE_TTL"]
    value.nil? ? ENV.delete("COORD_LEASE_TTL") : ENV["COORD_LEASE_TTL"] = value
    yield
  ensure
    old.nil? ? ENV.delete("COORD_LEASE_TTL") : ENV["COORD_LEASE_TTL"] = old
  end

  def test_defaults_when_unset
    with_lease_env(nil) { assert_equal Coord::DEFAULT_LEASE_TTL, Coord::Lease.ttl }
  end

  def test_honors_a_positive_override
    with_lease_env("120") { assert_equal 120, Coord::Lease.ttl }
  end

  # Regression: a non-numeric COORD_LEASE_TTL used to collapse to 0, making
  # every claim look instantly expired.
  def test_invalid_override_falls_back_to_the_default
    _, err = capture_io do
      with_lease_env("soon") { assert_equal Coord::DEFAULT_LEASE_TTL, Coord::Lease.ttl }
    end
    assert_match(/invalid COORD_LEASE_TTL/, err)
  end

  def test_non_positive_override_falls_back_to_the_default
    with_lease_env("0") { assert_equal Coord::DEFAULT_LEASE_TTL, Coord::Lease.ttl }
  end
end

class TaskwarriorTest < Minitest::Test
  include CoordEnvIsolation

  def setup
    skip "Taskwarrior ('task') not installed" unless Coord::TaskCli.new.available?

    @dir = Dir.mktmpdir("coord-test")
    coord_dir = File.join(@dir, "coordination")
    @env = { "COORD_DIR" => coord_dir, "TASKRC" => File.join(coord_dir, "taskrc"),
             "COORD_ROLE" => "backend-developer", "COORD_WORKER" => "backend-1" }
    isolate_env(@env)
    Coord::CLI.new(["init"], env: @env).run
  end

  def teardown
    restore_env
    FileUtils.remove_entry(@dir)
  end

  # A suite that inherits the session board writes strays to it. The process
  # must point at the disposable board for the whole test.
  def test_the_suite_uses_its_own_board
    assert_isolated_env(@env)
  end

  def tasks = Coord::Tasks.new

  def add(title)
    tasks.add(title: title, role: "backend-developer")
  end

  def find(id)
    Coord::Tasks.new.pending.find { |t| t["uuid"] == id }
  end

  def test_add_stores_the_role_in_the_role_field
    id = add("role field")
    assert_equal "backend-developer", find(id)["role"]
  end

  def test_next_takes_the_role_from_coord_role
    add("for the env role")
    out, = capture_io { Coord::CLI.new(["next"], env: @env).run }
    assert_includes out, "for the env role"
  end

  def test_status_groups_tasks_by_role
    add("status row")
    out, = capture_io { Coord::CLI.new(["status"], env: @env).run }
    assert_match(/^backend-developer: /, out)
  end

  def test_taskrc_declares_the_role_attribute
    assert_includes File.read(@env["TASKRC"]), "uda.role.type=string"
  end

  # A title or annotation that happens to look like "attr:value" must survive
  # as literal text, not be parsed as a Taskwarrior attribute assignment.
  def test_attribute_shaped_title_survives_round_trip
    id = add("scope:auth due:tomorrow")
    assert_equal "scope:auth due:tomorrow", find(id)["description"]
    assert_nil find(id)["due"]
  end

  def test_annotate_with_attribute_shaped_text_stays_literal
    id = add("seed task")
    tasks.annotate(id, "priority:H not an attribute")
    assert_equal "priority:H not an attribute", find(id)["annotations"].first["description"]
    assert_nil find(id)["priority"]
  end

  def test_claim_refuses_a_second_worker
    id = add("task one")
    tasks.claim(id, "backend-1")
    error = assert_raises(Coord::Error) { Coord::Tasks.new.claim(id, "backend-2") }
    assert_match(/already claimed/, error.message)
  end

  def test_claim_force_steals_and_reports_prior_holder
    id = add("task two")
    tasks.claim(id, "backend-1")
    holder = Coord::Tasks.new.claim(id, "backend-2", force: true)
    assert_equal "backend-1", holder.worker
    assert_equal "backend-developer", holder.role
  end

  def test_unclaim_frees_a_task_for_reclaim
    id = add("task three")
    tasks.claim(id, "backend-1")
    tasks.unclaim(id)
    assert_empty find(id)["worker"].to_s
    assert_nil find(id)["start"]
    assert_nil Coord::Tasks.new.claim(id, "backend-2")
  end

  def test_expired_lease_is_reclaimable_without_force
    id = add("task four")
    tasks.claim(id, "backend-1")
    stale = (Time.now - Coord::Lease.ttl - 10).utc.strftime("%Y%m%dT%H%M%SZ")
    system("task", "rc.confirmation=no", id, "modify", "start:#{stale}", out: File::NULL, err: File::NULL)
    holder = Coord::Tasks.new.claim(id, "backend-2")
    assert_equal "backend-1", holder.worker
  end

  # Regression: the steal notice went to the prior holder's worker-id inbox
  # (e.g. inbox/backend-developer-1/), which no agent polls. It must land in
  # the role inbox the prior holder reads with `coord inbox`.
  def test_force_steal_notifies_the_prior_holder_role_inbox
    id = add("steal me")
    tasks.claim(id, "backend-1")
    capture_io do
      Coord::CLI.new(["claim", id, "--force"],
                     env: @env.merge("COORD_WORKER" => "backend-2")).run
    end

    files = Dir.glob(File.join(@env["COORD_DIR"], "inbox", "backend-developer", "*.md"))
    refute_empty files, "expected a message in the role inbox"
    assert_includes File.read(files.first), "backend-1"
  end

  # Regression: `coord with-lock NAME --ttl S -- CMD` used to strip the `--`
  # before parsing `--ttl`, so the separator became the command's first word
  # and the command never ran.
  def test_with_lock_accepts_ttl_before_the_separator
    error = assert_raises(SystemExit) do
      capture_io do
        Coord::CLI.new(["with-lock", "ollama", "--ttl", "30", "--", "true"], env: @env).run
      end
    end
    assert_equal 0, error.status
    refute Dir.exist?(File.join(@env["COORD_DIR"], "locks", "ollama.d")), "lock must be released"
  end

  # Regression: `next --wait` used to re-query through the CLI-memoized Tasks
  # instance, freezing on the first (empty) snapshot forever; and `--timeout`,
  # parsed after the positional ROLE `shift`, was swallowed as the ROLE
  # argument instead of recognized as a flag.
  def test_next_wait_detects_a_task_added_during_the_wait
    Thread.new { sleep 0.3; add("arrives during wait") }
    out, = capture_io do
      Coord::CLI.new(["next", "--wait", "--interval", "1", "--timeout", "5"], env: @env).run
    end
    assert_match(/arrives during wait/, out)
  end

  def test_next_wait_times_out_cleanly_when_nothing_arrives
    error = assert_raises(SystemExit) do
      capture_io { Coord::CLI.new(["next", "--wait", "--interval", "1", "--timeout", "1"], env: @env).run }
    end
    assert_equal 1, error.status
  end

  # An agent that waits for tasks must also wake up for a message. Before,
  # `next --wait` watched tasks only, so a message never reached the agent.
  def test_next_wait_returns_when_a_message_arrives
    Thread.new { sleep 0.3; Coord::CLI.new(["msg", "--from", "architect", "backend-developer", "hi"], env: @env).run }
    out, = capture_io do
      Coord::CLI.new(["next", "--wait", "--interval", "1", "--timeout", "5"], env: @env).run
    end
    assert_match(/1 unread message/, out)
    assert_match(%r{\./coord inbox}, out)
  end

  # Regression: a failed `task add` used to return nil, so `coord add` printed
  # a blank line and exited 0 while creating nothing.
  def test_add_raises_when_taskwarrior_cannot_create_the_task
    blocker = File.join(@dir, "not-a-directory")
    File.write(blocker, "x")
    File.write(@env["TASKRC"], "data.location=#{blocker}\n")

    error = assert_raises(Coord::Error) do
      Coord::Tasks.new.add(title: "boom", role: "backend-developer")
    end
    assert_match(/task add failed/, error.message)
  end

  def test_inbox_wait_with_no_positional_agent_still_recognizes_wait
    Thread.new { sleep 0.3; Coord::CLI.new(["msg", "--from", "architect", "backend-developer", "hi"], env: @env).run }
    out, = capture_io do
      Coord::CLI.new(["inbox", "--wait", "--interval", "1", "--timeout", "5"], env: @env).run
    end
    assert_match(/hi/, out)
  end

  # Broadcast sends to every role that has a pending task, not just the
  # sender's own role. The architect uses it for cross-cutting announcements.
  def test_broadcast_delivers_to_all_roles_with_tasks
    add("shared task")
    Coord::CLI.new(["add", "--role", "reviewer", "--scope", "test/**", "--title", "review task"], env: @env).run
    out, = capture_io do
      Coord::CLI.new(["broadcast", "--from", "architect", "scope change: all tests move to spec/"], env: @env).run
    end
    assert_match(/broadcast -> 2/, out)
    # Both role inboxes should have a message.
    refute_empty Dir.glob(File.join(@env["COORD_DIR"], "inbox", "backend-developer", "*.md"))
    refute_empty Dir.glob(File.join(@env["COORD_DIR"], "inbox", "reviewer", "*.md"))
  end

  # The event log records claims and completions so any agent can see what
  # happened without reading individual inboxes.
  def test_log_records_claims_and_completions
    id = add("logged task")
    capture_io { Coord::CLI.new(["claim", id], env: @env).run }
    capture_io { Coord::CLI.new(["done", id], env: @env).run }
    out, = capture_io { Coord::CLI.new(["log"], env: @env).run }
    assert_match(/claim\t.*#{id}/, out)
    assert_match(/done\t.*#{id}/, out)
  end

  def test_lock_records_the_worker_as_holder
    capture_io { Coord::CLI.new(["lock", "db", "--worker", "backend-2"], env: @env).run }
    meta = JSON.parse(File.read(File.join(@env["COORD_DIR"], "locks", "db.d", "meta.json")))
    assert_equal "backend-2", meta["worker"]
  end

  def test_lock_defaults_the_holder_to_coord_worker
    capture_io { Coord::CLI.new(["lock", "db"], env: @env).run }
    meta = JSON.parse(File.read(File.join(@env["COORD_DIR"], "locks", "db.d", "meta.json")))
    assert_equal "backend-1", meta["worker"]
  end

def test_stale_lock_is_reclaimed_and_leaves_no_tombstone
  dir = File.join(@env["COORD_DIR"], "locks", "db.d")
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "meta.json"), JSON.generate(worker: "old", ts: 0, ttl: 1))
  capture_io { Coord::CLI.new(["lock", "db", "--worker", "new"], env: @env).run }
  assert_equal "new", JSON.parse(File.read(File.join(dir, "meta.json")))["worker"]
  assert_equal ["db.d"], Dir.children(File.join(@env["COORD_DIR"], "locks")) - [".gitkeep"]
end

  def test_log_records_the_worker_as_message_sender
    capture_io { Coord::CLI.new(["msg", "reviewer", "hello"], env: @env).run }
    out, = capture_io { Coord::CLI.new(["log"], env: @env).run }
    assert_match(/msg\tbackend-1\t/, out)
  end

  def test_log_with_no_events_says_so
    out, = capture_io { Coord::CLI.new(["log"], env: @env).run }
    assert_match(/no events yet/, out)
  end

  # `coord log N` must reject a non-numeric N instead of silently printing
  # nothing (the old `&.to_i` turned garbage into 0).
  def test_log_rejects_non_numeric_count
    assert_raises(SystemExit) do
      capture_io { Coord::CLI.new(["log", "abc"], env: @env).run }
    end
  end

  # A hook at coordination/message-hooks/<role>.sh runs when a message is delivered
  # to that role. The hook is a plain shell script — coord does not know or
  # care what harness the agent runs in.
  def test_msg_fires_hook_when_installed
    hook_dir = File.join(@env["COORD_DIR"], "message-hooks")
    FileUtils.mkdir_p(hook_dir)
    hook = File.join(hook_dir, "backend-developer.sh")
    File.write(hook, <<~SH)
      #!/bin/sh
      echo "hook fired: $COORD_ROLE from $COORD_FROM" > "#{hook}.out"
    SH
    FileUtils.chmod("+x", hook)

    capture_io { Coord::CLI.new(["msg", "--from", "architect", "backend-developer", "hello"], env: @env).run }

    assert wait_for_file("#{hook}.out"), "hook did not run"
    assert_match(/hook fired: backend-developer from architect/, File.read("#{hook}.out"))
  end

  # A slow hook (one that starts a whole agent run) must not block the sender.
  def test_msg_does_not_wait_for_hook
    hook = install_hook("backend-developer", "sleep 5\n")
    started = Time.now
    capture_io { Coord::CLI.new(["msg", "--from", "architect", "backend-developer", "hi"], env: @env).run }
    assert_operator Time.now - started, :<, 2
    File.delete(hook)
  end

  # Hook output goes to coordination/message-hooks/<role>.log, not /dev/null, so a
  # broken hook is debuggable.
  def test_hook_output_goes_to_role_log
    install_hook("backend-developer", "echo from-hook\n")
    capture_io { Coord::CLI.new(["msg", "--from", "architect", "backend-developer", "hi"], env: @env).run }
    log = File.join(@env["COORD_DIR"], "message-hooks", "backend-developer.log")
    assert wait_for_file(log) { File.read(log).include?("from-hook") }, "hook log not written"
  end

  def test_broadcast_skips_the_sender
    add("backend task")
    Coord::CLI.new(["add", "--role", "architect", "--scope", "docs/**", "--title", "plan"], env: @env).run
    out, = capture_io { Coord::CLI.new(["broadcast", "--from", "architect", "heads up"], env: @env).run }
    assert_match(/broadcast -> 1 role\b/, out)
    assert_empty Dir.glob(File.join(@env["COORD_DIR"], "inbox", "architect", "*.md"))
  end

  # Idle roles (no pending task) still hear a broadcast when the project
  # manifest declares them.
  def test_broadcast_reaches_roles_from_the_manifest
    manifest = { agents: [{ harness: "claude", role: "tester" }] }
    File.write(File.join(@dir, ".agent-flow.json"), JSON.generate(manifest))
    capture_io { Coord::CLI.new(["broadcast", "--from", "architect", "heads up"], env: @env).run }
    refute_empty Dir.glob(File.join(@env["COORD_DIR"], "inbox", "tester", "*.md"))
  end

  def inbox(role) = Dir.glob(File.join(@env["COORD_DIR"], "inbox", role, "*.md"))

  def write_team_manifest
    roles = %w[project-manager architect tester]
    manifest = { agents: roles.map { |role| { harness: "claude", role: role } } }
    File.write(File.join(@dir, ".agent-flow.json"), JSON.generate(manifest))
  end

  # Notices about ports or test databases are for workers. The project
  # manager must not have to process each one.
  def test_broadcast_reaches_only_workers_by_default
    write_team_manifest
    capture_io { Coord::CLI.new(["broadcast", "--from", "architect", "use port 3001"], env: @env).run }

    refute_empty inbox("tester")
    assert_empty inbox("project-manager")
  end

  def test_broadcast_to_all_reaches_the_leads
    write_team_manifest
    capture_io { Coord::CLI.new(["broadcast", "--from", "architect", "--to", "all", "goal moved"], env: @env).run }

    refute_empty inbox("project-manager")
    refute_empty inbox("tester")
  end

  def test_broadcast_rejects_an_unknown_audience
    assert_raises(SystemExit) do
      capture_io { Coord::CLI.new(["broadcast", "--from", "architect", "--to", "nobody", "x"], env: @env).run }
    end
  end

  # A dispatched architect starts only on a message, so a done task must
  # send one.
  def test_done_tells_the_architect
    id = add("finished work")
    capture_io { Coord::CLI.new(["done", id], env: @env).run }

    assert_includes File.read(inbox("architect").first), "Task #{id} is done: finished work."
  end

  def lead_env = @env.merge("COORD_ROLE" => "architect", "COORD_WORKER" => "architect-1")

  # A lead role owns no task. A claim by a lead breaks the role split.
  def test_claim_is_refused_for_a_lead_role
    id = add("lead must not take this")
    _out, err = capture_io { assert_raises(SystemExit) { Coord::CLI.new(["claim", id], env: lead_env).run } }

    assert_includes err, "lead role"
    assert_empty find(id)["worker"].to_s
  end

  def test_next_wait_is_refused_for_a_lead_role
    _out, err = capture_io { assert_raises(SystemExit) { Coord::CLI.new(%w[next --wait], env: lead_env).run } }

    assert_includes err, "./coord inbox --wait"
  end

  def session_env(role, worker, pid = Process.pid)
    @env.merge("COORD_ROLE" => role, "COORD_WORKER" => worker, "COORD_SESSION_PID" => pid.to_s)
  end

  def who = capture_io { Coord::CLI.new(["who"], env: @env).run }.first

  def test_presence_records_a_session_as_live
    capture_io { Coord::CLI.new(["status"], env: session_env("reviewer", "reviewer-1")).run }

    assert_match(/^reviewer-1\treviewer\tsession\tlive\t/, who)
  end

  def test_presence_shows_a_dead_pid_as_gone
    pid = spawn("true").tap { |child| Process.wait(child) }
    capture_io { Coord::CLI.new(["status"], env: session_env("reviewer", "reviewer-1", pid)).run }

    assert_match(/^reviewer-1\treviewer\tsession\tgone\t/, who)
  end

  # The dispatcher owns the presence file of a dispatched worker.
  def test_presence_skips_a_dispatched_run
    env = session_env("reviewer", "reviewer-1").merge("COORD_DISPATCHED" => "1")
    capture_io { Coord::CLI.new(["status"], env: env).run }

    assert_equal "no presence records\n", who
  end

  def test_msg_warns_when_the_role_has_no_push_path
    _out, err = capture_io { Coord::CLI.new(["msg", "--from", "tester", "architect", "decide"], env: @env).run }

    assert_includes err, "architect has no live session and no message hook"
  end

  def test_msg_is_quiet_when_the_role_is_live
    capture_io { Coord::CLI.new(["status"], env: session_env("architect", "architect-1")).run }
    _out, err = capture_io { Coord::CLI.new(["msg", "--from", "tester", "architect", "decide"], env: @env).run }

    refute_includes err, "no live session"
  end

  def write_registry(workers)
    File.write(File.join(@env["COORD_DIR"], "workers.json"), JSON.generate(workers))
  end

  def test_a_task_for_a_role_without_a_worker_alerts_the_project_manager_once
    write_team_manifest
    write_registry("architect-1" => { "role" => "architect" })
    2.times { |n| capture_io { Coord::CLI.new(["add", "--role", "backend-developer", "--title", "t#{n}"], env: @env).run } }

    assert_equal 1, inbox("project-manager").size
    assert_includes File.read(inbox("project-manager").first), "No worker runs role backend-developer."
  end

  def test_a_staffed_role_raises_no_alert
    write_team_manifest
    write_registry("backend-1" => { "role" => "backend-developer" })
    capture_io { Coord::CLI.new(["add", "--role", "backend-developer", "--title", "t"], env: @env).run }

    assert_empty inbox("project-manager")
  end

  # Without a project-manager role, no message records the notice. The warning
  # must still appear only once per role, not on every `coord add`.
  def test_an_unstaffed_role_warns_once_without_a_project_manager
    manifest = { agents: [{ harness: "claude", role: "architect" }] }
    File.write(File.join(@dir, ".agent-flow.json"), JSON.generate(manifest))
    write_registry("architect-1" => { "role" => "architect" })

    _out, err = capture_io do
      2.times { |n| Coord::CLI.new(["add", "--role", "backend-developer", "--title", "t#{n}"], env: @env).run }
    end

    assert_equal 1, err.scan("No worker runs role backend-developer.").size
  end

  # A taskrc from an older coord has the marker block but not the goal UDA.
  def test_init_adds_a_missing_uda_to_an_older_taskrc
    taskrc = @env["TASKRC"]
    File.write(taskrc, File.read(taskrc).sub("uda.goalid.type=string\n", ""))
    Coord::CLI.new(["init"], env: @env).run

    assert_includes File.read(taskrc), "uda.goalid.type=string\n"
  end

  def test_log_records_messages_on_one_line
    text = "line one\nline\ttwo"
    capture_io { Coord::CLI.new(["msg", "--from", "architect", "reviewer", text], env: @env).run }
    lines = File.readlines(File.join(@env["COORD_DIR"], "events.log"))
    assert_equal 1, lines.size
    assert_equal 4, lines.first.chomp.split("\t").size
    assert_match(/msg\tbackend-1\tto reviewer: line one line two/, lines.first)
  end

  def install_hook(role, body)
    hook = File.join(@env["COORD_DIR"], "message-hooks", "#{role}.sh")
    File.write(hook, "#!/bin/sh\n#{body}")
    FileUtils.chmod("+x", hook)
    hook
  end

  def wait_for_file(path, timeout: 5)
    deadline = Time.now + timeout
    sleep 0.05 until (File.exist?(path) && (!block_given? || yield)) || Time.now > deadline
    File.exist?(path) && (!block_given? || yield)
  end

  # No hook installed means coord is silent — the inbox file is still written,
  # the agent picks it up on its next `coord inbox`.
  def test_msg_silent_when_no_hook
    # No hook directory or hook script — should not error.
    out, = capture_io do
      Coord::CLI.new(["msg", "--from", "architect", "backend-developer", "hello"], env: @env).run
    end
    assert_match(/msg ->/, out)
    refute_match(/hook/, out)
  end

  # `coord hooks` lists installed hooks and their status.
  def test_hooks_lists_installed_hooks
    hook_dir = File.join(@env["COORD_DIR"], "message-hooks")
    FileUtils.mkdir_p(hook_dir)
    hook = File.join(hook_dir, "backend-developer.sh")
    File.write(hook, "#!/bin/sh\necho hi\n")
    FileUtils.chmod("+x", hook)

    out, = capture_io { Coord::CLI.new(["hooks"], env: @env).run }
    assert_match(/backend-developer\.sh/, out)
    assert_match(/active/, out)
  end

  def test_hooks_filters_by_role
    install_hook("backend-developer", "true\n")
    install_hook("reviewer", "true\n")
    out, = capture_io { Coord::CLI.new(["hooks", "reviewer"], env: @env).run }
    assert_match(/reviewer\.sh/, out)
    refute_match(/backend-developer\.sh/, out)
  end

  # Harness hook scripts are not message hooks. `coord hooks` must not list
  # them as hooks for a role such as "next-task-hermes".
  def test_hooks_ignores_harness_hooks
    harness_dir = File.join(@env["COORD_DIR"], "harness-hooks")
    FileUtils.mkdir_p(harness_dir)
    File.write(File.join(harness_dir, "next-task-hermes.sh"), "#!/bin/sh\n")
    out, = capture_io { Coord::CLI.new(["hooks"], env: @env).run }
    refute_match(/next-task-hermes/, out)
  end

  def test_init_creates_the_message_hooks_dir
    assert Dir.exist?(File.join(@env["COORD_DIR"], "message-hooks"))
  end

  def test_hooks_with_no_hooks_says_so
    out, = capture_io { Coord::CLI.new(["hooks"], env: @env).run }
    assert_match(/no hooks/, out)
  end
end

class TaskrcSafetyTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("coord-taskrc-test")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_ensure_taskrc_writes_data_location_for_its_own_project_local_file
    coord_dir = File.join(@dir, "coordination")
    taskrc = File.join(coord_dir, "taskrc")
    Coord::Setup.new(Coord::Paths.new(coord_dir), taskrc).ensure_taskrc

    assert_match(/^data\.location=/, File.read(taskrc))
  end

  # Regression: a user's own TASKRC (e.g. ~/.taskrc, pointed at their real
  # Taskwarrior database) must never be rewritten to point at this project.
  def test_ensure_taskrc_refuses_to_redirect_an_external_taskrc
    coord_dir = File.join(@dir, "coordination")
    external_taskrc = File.join(@dir, "external", ".taskrc")
    FileUtils.mkdir_p(File.dirname(external_taskrc))
    File.write(external_taskrc, "# pre-existing personal config\n")

    capture_io { Coord::Setup.new(Coord::Paths.new(coord_dir), external_taskrc).ensure_taskrc }
    content = File.read(external_taskrc)

    refute_match(/^data\.location=/, content)
    assert_includes content, "# pre-existing personal config"
    assert_includes content, Coord::MARKER
  end

  # Regression: the external-taskrc warning must still fire when the external
  # taskrc already has data.location (e.g. a personal ~/.taskrc), not only when
  # it is missing.
  def test_ensure_taskrc_warns_for_an_external_taskrc_with_data_location
    coord_dir = File.join(@dir, "coordination")
    external_taskrc = File.join(@dir, "external", ".taskrc")
    personal_data = File.join(@dir, "my-tasks")
    FileUtils.mkdir_p(File.dirname(external_taskrc))
    File.write(external_taskrc, "data.location=#{personal_data}\n")

    _, err = capture_io { Coord::Setup.new(Coord::Paths.new(coord_dir), external_taskrc).ensure_taskrc }

    assert_match(/outside coordination\//, err)
    assert_includes File.read(external_taskrc), "data.location=#{personal_data}"
  end

  # Regression: a marked taskrc from an older install that has no
  # data.location would silently fall back to the global ~/.task database.
  def test_ensure_taskrc_adds_data_location_to_an_old_marked_taskrc
    coord_dir = File.join(@dir, "coordination")
    taskrc = File.join(coord_dir, "taskrc")
    FileUtils.mkdir_p(coord_dir)
    File.write(taskrc, "# #{Coord::MARKER}\nuda.role.type=string\n")

    Coord::Setup.new(Coord::Paths.new(coord_dir), taskrc).ensure_taskrc

    content = File.read(taskrc)
    assert_match(/^data\.location=/, content)
    assert_includes content, "uda.role.type=string"
    assert_equal 1, content.scan(Coord::MARKER).size
  end
end

class WorktreeTest < Minitest::Test
  def setup
    skip "git not installed" unless system("git", "--version", out: File::NULL)

    @root = Dir.mktmpdir("coord-worktree-test")
    run_git("init", "-q")
    # `coordination/.../.gitkeep` and `coord` are normally tracked in git, so a
    # fresh worktree checks out its own real copies of them.
    FileUtils.mkdir_p(File.join(@root, "coordination", "exports"))
    FileUtils.touch(File.join(@root, "coordination", "exports", ".gitkeep"))
    FileUtils.touch(File.join(@root, "coord"))
    File.write(File.join(@root, ".gitignore"), "coord-env.sh\n")
    run_git("add", "coord", "coordination", ".gitignore")
    run_git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def run_git(*args)
    system("git", "-C", @root, *args, out: File::NULL) || raise("git #{args.join(" ")} failed")
  end

  # All worktrees live inside the project, under <project>/.worktrees/<slug>.
  def worktrees_root
    File.join(@root, ".worktrees")
  end

  def test_worktree_lives_under_the_worktrees_folder
    Coord::Worktree.new(@root).create("tester", nil)
    @worktree_dir = File.join(worktrees_root, "tester")
    env_file = File.read(File.join(@worktree_dir, "coord-env.sh"))

    assert_equal "#{@root}/.worktrees/tester", @worktree_dir
    assert Dir.exist?(@worktree_dir)
    assert_includes env_file, "COORD_DIR=#{File.join(@root, "coordination")}"
    assert_includes env_file, "TASKRC=#{File.join(@root, "coordination", "taskrc")}"
  end

  # The tracked coord/coordination checked out into the worktree must be left
  # alone: a dirty worktree, or an absolute-path symlink some agent later
  # commits over them, is exactly the failure this design avoids.
  def test_worktree_leaves_tracked_files_untouched
    Coord::Worktree.new(@root).create("tester", nil)
    @worktree_dir = File.join(worktrees_root, "tester")
    status = `git -C #{@worktree_dir} status --porcelain`

    assert_empty status.strip
  end

  # Calling `coord worktree` again for the same role/worker (e.g. a second
  # `setup_agent` run) must reuse the existing worktree, not abort.
  def test_create_is_idempotent_when_the_worktree_still_exists
    worktree = Coord::Worktree.new(@root)
    worktree.create("tester", nil)
    @worktree_dir = File.join(worktrees_root, "tester")

    worktree.create("tester", nil)

    assert Dir.exist?(@worktree_dir)
  end

  # Regression: `git worktree remove` deletes the worktree directory but not
  # its branch. A later `setup_agent` run then hit `git worktree add -b
  # worker/tester` against a branch that already existed and aborted with
  # "fatal: a branch named ... already exists".
  def test_create_recreates_the_worktree_when_only_the_branch_survives
    worktree = Coord::Worktree.new(@root)
    worktree.create("tester", nil)
    @worktree_dir = File.join(worktrees_root, "tester")
    run_git("worktree", "remove", @worktree_dir)
    refute Dir.exist?(@worktree_dir)

    worktree.create("tester", nil)

    assert Dir.exist?(@worktree_dir)
    assert_equal "worker/tester", `git -C #{@worktree_dir} branch --show-current`.strip
  end

  def env_file(slug) = File.read(File.join(worktrees_root, slug, "coord-env.sh"))

  def test_each_worktree_gets_its_own_slot
    worktree = Coord::Worktree.new(@root)
    worktree.create("tester", nil)
    worktree.create("reviewer", nil)

    assert_includes env_file("tester"), "export COORD_SLOT=1\n"
    assert_includes env_file("reviewer"), "export COORD_SLOT=2\n"
  end

  def test_a_reused_worktree_keeps_its_slot
    worktree = Coord::Worktree.new(@root)
    worktree.create("tester", nil)
    worktree.create("reviewer", nil)
    worktree.create("tester", nil)

    assert_includes env_file("tester"), "export COORD_SLOT=1\n"
  end

  # A retired worker must give its slot back, or the port map climbs forever.
  def test_a_removed_worktree_frees_its_slot
    %w[tester reviewer].each { |slug| FileUtils.mkdir_p(File.join(worktrees_root, slug)) }
    slots = Coord::Slots.new(File.join(@root, "coordination"))

    assert_equal 1, slots.assign("tester")
    assert_equal 2, slots.assign("reviewer")
    FileUtils.remove_entry(File.join(worktrees_root, "reviewer"))

    assert_equal 2, slots.assign("backend-developer")
  end

  def test_the_project_hook_output_is_appended_to_the_env_file
    File.write(File.join(@root, "coordination", "worktree-env.rb"),
               'puts "export PORT=#{3000 + ENV.fetch("COORD_SLOT").to_i}"')
    Coord::Worktree.new(@root).create("tester", nil)

    assert_includes env_file("tester"), "export PORT=3001\n"
  end

  # A shell sources coord-env.sh. Keep only exports, so a hook that prints
  # other text cannot run a command in every later shell.
  def test_the_project_hook_output_keeps_only_export_lines
    File.write(File.join(@root, "coordination", "worktree-env.rb"), <<~RUBY)
      puts "echo not allowed"
      puts "export OK=1"
    RUBY
    Coord::Worktree.new(@root).create("tester", nil)

    assert_includes env_file("tester"), "export OK=1\n"
    refute_includes env_file("tester"), "echo not allowed"
  end

  def test_a_failing_project_hook_does_not_stop_the_worktree
    File.write(File.join(@root, "coordination", "worktree-env.rb"), "exit 1")
    _out, err = capture_subprocess_io { Coord::Worktree.new(@root).create("tester", nil) }

    assert_includes env_file("tester"), "export COORD_SLOT=1\n"
    assert_includes err, "worktree-env.rb failed"
  end

  def test_a_worker_name_with_the_role_is_not_repeated
    assert_equal "frontend-developer-2", Coord::Worktree.slug("frontend-developer", "frontend-developer-2")
    assert_equal "frontend-developer-2", Coord::Worktree.slug("frontend-developer", "2")
    assert_equal "tester", Coord::Worktree.slug("tester", nil)
  end
end

# Regression: on a first run, `coord` and the flow's .gitignore block are not
# committed yet. `git worktree add` then brings neither, so the worktree had no
# ./coord and showed coord-env.sh as untracked. The command must copy coord in
# and keep coord-env.sh out of the worktree's status.
class WorktreeFirstRunTest < Minitest::Test
  def setup
    skip "git not installed" unless system("git", "--version", out: File::NULL)

    @root = Dir.mktmpdir("coord-worktree-first")
    run_git("init", "-q")
    File.write(File.join(@root, "README.md"), "x\n")
    run_git("add", "README.md")
    run_git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init")
    File.write(File.join(@root, "coord"), "#!/usr/bin/env ruby\n")
    @worktree_dir = File.join(@root, ".worktrees", "tester")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def run_git(*args)
    system("git", "-C", @root, *args, out: File::NULL) || raise("git #{args.join(" ")} failed")
  end

  def test_worktree_copies_uncommitted_coord_and_hides_env_file
    Coord::Worktree.new(@root).create("tester", nil)

    assert File.exist?(File.join(@worktree_dir, "coord"))
    status = `git -C #{@worktree_dir} status --porcelain`
    refute_includes status, "coord-env.sh"
  end

  HOOK_FILES = %w[.claude/settings.json coordination/harness-hooks/board-watch.rb
                  coordination/harness-hooks/next-task.rb .opencode/plugins/board-watch.js].freeze

  # Regression: an uncommitted .claude/settings.json never reached the
  # worktree, so Claude agents there ran without the board-watch hook.
  def test_worktree_copies_uncommitted_harness_hooks
    HOOK_FILES.each { |path| write(path) }
    Coord::Worktree.new(@root).create("tester", nil)

    HOOK_FILES.each { |path| assert File.exist?(File.join(@worktree_dir, path)), path }
  end

  def test_reused_worktree_gets_hooks_added_after_it_was_created
    Coord::Worktree.new(@root).create("tester", nil)
    HOOK_FILES.each { |path| write(path) }
    Coord::Worktree.new(@root).create("tester", nil)

    HOOK_FILES.each { |path| assert File.exist?(File.join(@worktree_dir, path)), path }
  end

  def write(path)
    full = File.join(@root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, "x\n")
  end
end

# Goals and task branches need both Taskwarrior and git: a goal gets its own
# branch and worktree, and each task branches from its goal's branch.
class GoalTest < Minitest::Test
  include CoordEnvIsolation

  def setup
    skip "Taskwarrior ('task') not installed" unless Coord::TaskCli.new.available?
    skip "git not installed" unless system("git", "--version", out: File::NULL)

    @root = File.realpath(Dir.mktmpdir("coord-goal-test"))
    init_repo
    coord_dir = File.join(@root, "coordination")
    @env = { "COORD_DIR" => coord_dir, "TASKRC" => File.join(coord_dir, "taskrc"),
             "COORD_ROLE" => "architect", "COORD_WORKER" => "architect-1" }
    isolate_env(@env)
    Dir.chdir(@root) { coord("init") }
  end

  def teardown
    restore_env
    FileUtils.remove_entry(@root) if @root
  end

  def init_repo
    git(@root, "init", "-q", "-b", "main")
    File.write(File.join(@root, ".gitignore"), "coordination/\n.worktrees/\n")
    commit(@root, "init")
  end

  def git(dir, *args)
    system("git", "-C", dir, *args, out: File::NULL, err: File::NULL) || raise("git #{args.join(" ")} failed")
  end

  def commit(dir, message)
    git(dir, "add", "-A")
    git(dir, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", message)
  end

  def coord(*args, dir: @root)
    out, = capture_io { Dir.chdir(dir) { Coord::CLI.new(args, env: @env).run } }
    out
  end

  def add_goal = coord("goal", "add", "--title", "Show prices").lines.last.strip
  def short(uuid) = uuid[0, 8]

  def test_goal_add_creates_a_goal_branch_and_worktree_from_the_base_branch
    uuid = add_goal
    dir = File.join(@root, ".worktrees", "goal-#{short(uuid)}")

    assert_equal "goal/#{short(uuid)}", `git -C #{dir} branch --show-current`.strip
    assert_includes coord("goal", "list"), "Show prices"
  end

  def test_goal_add_refuses_a_missing_base_branch
    assert_raises(SystemExit) { coord("goal", "add", "--title", "x", "--base", "nope") }
  end

  # An empty base_branch is not a branch. Fall back to the default branch
  # instead of aborting with "base branch  does not exist".
  def test_an_empty_base_branch_falls_back_to_the_default_branch
    File.write(File.join(@root, ".agent-flow.json"), JSON.generate(base_branch: ""))
    uuid = add_goal

    dir = File.join(@root, ".worktrees", "goal-#{short(uuid)}")
    assert_equal "goal/#{short(uuid)}", `git -C #{dir} branch --show-current`.strip
  end

  def test_goal_show_lists_the_tasks_of_the_goal
    uuid = add_goal
    coord("add", "--role", "tester", "--scope", "test/**", "--goal", uuid, "--title", "price test")

    assert_includes coord("goal", "show", uuid), "price test"
  end

  def test_goal_done_is_refused_while_a_task_is_open
    uuid = add_goal
    task = coord("add", "--role", "tester", "--scope", "test/**", "--goal", uuid, "--title", "t").strip

    assert_raises(SystemExit) { coord("goal", "done", uuid) }
    coord("done", task)
    assert_includes coord("goal", "done", uuid), "goal/#{short(uuid)}"
  end

  def test_start_task_branches_from_the_goal_branch
    uuid = add_goal
    goal_dir = File.join(@root, ".worktrees", "goal-#{short(uuid)}")
    commit(goal_dir, "goal work")
    task = coord("add", "--role", "tester", "--scope", "test/**", "--goal", uuid, "--title", "t").strip
    worker_dir = worker_worktree

    coord("start-task", task, dir: worker_dir)

    assert_equal "task/#{short(task)}", `git -C #{worker_dir} branch --show-current`.strip
    assert_equal "goal work", `git -C #{worker_dir} log -1 --format=%s`.strip
  end

  def test_start_task_refuses_uncommitted_changes
    task = coord("add", "--role", "tester", "--scope", "test/**", "--title", "t").strip
    worker_dir = worker_worktree
    File.write(File.join(worker_dir, ".gitignore"), "changed\n")

    assert_raises(SystemExit) { coord("start-task", task, dir: worker_dir) }
  end

  def worker_worktree
    coord("worktree", "tester", "1")
    File.join(@root, ".worktrees", "tester-1")
  end

  # A task with own commits and a goal branch that moved on after the start.
  def started_task_behind_goal
    uuid = add_goal
    task = coord("add", "--role", "tester", "--scope", "test/**", "--goal", uuid, "--title", "t").strip
    worker_dir = worker_worktree
    coord("start-task", task, dir: worker_dir)
    commit(worker_dir, "task work")
    commit(File.join(@root, ".worktrees", "goal-#{short(uuid)}"), "sibling task merged")
    [uuid, task, worker_dir]
  end

  # Task tests on a branch without the sibling tasks miss semantic conflicts.
  def test_done_is_refused_while_the_task_branch_lacks_the_goal_head
    uuid, task, worker_dir = started_task_behind_goal

    error = assert_raises(SystemExit) { coord("done", task, dir: worker_dir) }
    assert_includes error.message, "git merge goal/#{short(uuid)}"
  end

  def test_done_passes_after_the_goal_branch_is_merged
    uuid, task, worker_dir = started_task_behind_goal
    git(worker_dir, "-c", "user.email=t@t", "-c", "user.name=t", "merge", "-q", "--no-edit", "goal/#{short(uuid)}")

    assert_includes coord("done", task, dir: worker_dir), "done #{task}"
  end

  def test_done_force_skips_the_goal_head_check
    _uuid, task, worker_dir = started_task_behind_goal

    assert_includes coord("done", "--force", task, dir: worker_dir), "done #{task}"
  end

  # A review task commits nothing, so it has nothing to integrate.
  def test_done_passes_for_a_task_branch_without_own_commits
    uuid = add_goal
    task = coord("add", "--role", "tester", "--scope", "test/**", "--goal", uuid, "--title", "t").strip
    worker_dir = worker_worktree
    coord("start-task", task, dir: worker_dir)
    commit(File.join(@root, ".worktrees", "goal-#{short(uuid)}"), "sibling task merged")

    assert_includes coord("done", task, dir: worker_dir), "done #{task}"
  end

  def test_worktree_warns_when_a_harness_has_no_file_for_the_role
    manifest = { agents: [{ harness: "claude", role: "architect" }, { harness: "opencode", role: "tester" }] }
    File.write(File.join(@root, ".agent-flow.json"), JSON.generate(manifest))
    _out, err = capture_io { Dir.chdir(@root) { Coord::CLI.new(%w[worktree tester 1], env: @env).run } }

    assert_includes err, "maf add claude:tester"
  end
end
