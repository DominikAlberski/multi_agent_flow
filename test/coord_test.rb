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
require_relative "board_guard"
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
    coord_dir = File.join(@dir, ".maf/coordination")
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

  def run_cli(*argv, env: @env) = capture_io { Coord::CLI.new(argv, env: env).run }.first

  # Taskwarrior sets `modified` at the claim, so only a limit of 0 minutes finds the claim stale here.
  def test_reap_releases_a_stale_claim_and_tells_the_architect
    id = add("stalled")
    tasks.claim(id, "backend-1")

    assert_includes run_cli("reap", "--minutes", "90"), "no stale claims"
    capture_io { run_cli("reap", "--minutes", "0") }
    assert_empty find(id)["worker"].to_s
    inbox = run_cli("inbox", "architect", env: @env.merge("COORD_ROLE" => "architect"))
    assert_includes inbox, "backend-1 was not seen"
  end

  # A run on a local model can take hours. The live dispatcher resumes its claims itself.
  def test_reap_keeps_the_claim_of_a_live_dispatcher
    id = add("long local run")
    tasks.claim(id, "backend-1")
    presence = File.join(@env["COORD_DIR"], "presence")
    FileUtils.mkdir_p(presence)
    record = { worker: "backend-1", mode: "dispatch", pid: Process.pid,
               started: Maf::Shared::Processes.started_at(Process.pid) }
    File.write(File.join(presence, "backend-1.json"), JSON.generate(record))

    capture_io { run_cli("reap", "--minutes", "0") }
    assert_equal "backend-1", find(id)["worker"]
  end

  def test_reap_reads_its_limit_from_the_team_section
    File.write(File.join(File.dirname(@env["COORD_DIR"]), "config.json"), JSON.generate(team: { reap_minutes: 0 }))
    id = add("stalled")
    tasks.claim(id, "backend-1")

    capture_io { run_cli("reap") }
    assert_empty find(id)["worker"].to_s
  end

  # Regression: a stalled run woke up and closed a task that another worker held.
  def test_done_is_refused_for_a_task_of_another_worker
    id = add("taken over")
    tasks.claim(id, "backend-2")

    error = assert_raises(SystemExit) { run_cli("done", id) }
    assert_includes error.message, "belongs to backend-2"
  end

  def test_done_is_refused_for_a_closed_task
    id = add("closed")
    capture_io { run_cli("done", id) }

    error = assert_raises(SystemExit) { run_cli("done", id) }
    assert_includes error.message, "already completed"
  end

  # Regression: two waiters on one inbox split the messages between two agents.
  def test_a_second_inbox_waiter_for_a_role_is_refused
    other = Process.spawn("sleep 30")
    locks = File.join(@env["COORD_DIR"], "locks")
    FileUtils.mkdir_p(locks)
    File.write(File.join(locks, "inbox-wait-architect.pid"), other.to_s)

    error = assert_raises(SystemExit) { run_cli("inbox", "architect", "--wait", "--timeout", "1") }
    assert_includes error.message, "another coord inbox --wait for architect"
  ensure
    Process.kill("KILL", other) && Process.wait(other) if other
  end

  def test_an_inbox_waiter_frees_its_slot_after_the_wait
    run_cli("msg", "--from", "tester", "architect", "hello")
    assert_includes run_cli("inbox", "architect", "--wait", "--timeout", "1"), "hello"
    refute File.exist?(File.join(@env["COORD_DIR"], "locks", "inbox-wait-architect.pid"))
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
    assert_match(/coord inbox/, out)
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

  def run_coord(*argv) = capture_io { Coord::CLI.new(argv, env: @env).run }.first

  def test_show_prints_the_fields_and_the_annotations_of_a_task
    id = add("show me")
    tasks.annotate(id, "Goal: x. Acceptance: y.")

    out = run_coord("show", id)

    assert_includes out, "description: show me"
    assert_includes out, "role: backend-developer"
    assert_match(/^note .*: Goal: x\. Acceptance: y\.$/, out)
  end

  def test_show_refuses_an_unknown_task
    _, err = capture_io do
      assert_raises(SystemExit) { Coord::CLI.new(["show", "00000000-0000-0000-0000-000000000000"], env: @env).run }
    end

    assert_includes err, "no task found"
  end

  def test_add_and_annotate_write_events
    id = run_coord("add", "--role", "tester", "--title", "log me").strip
    run_coord("annotate", id, "a note")

    log = run_coord("log")

    assert_match(/\tadd\tbackend-1\t#{id} log me$/, log)
    assert_match(/\tannotate\tbackend-1\t#{id}$/, log)
  end

  def test_with_lock_writes_an_event_with_the_result
    assert_raises(SystemExit) { capture_io { Coord::CLI.new(["with-lock", "suite", "--", "false"], env: @env).run } }

    assert_match(/\twith-lock\tbackend-1\tsuite failed \d+s$/, run_coord("log"))
  end

  def escalate_env(role) = @env.merge("COORD_ROLE" => role, "COORD_WORKER" => role)

  def write_manifest(*roles)
    File.write(File.join(@dir, ".maf", "config.json"), JSON.generate("agents" => roles.map { |r| { "role" => r } }))
  end

  def inbox_files(role) = Dir.glob(File.join(@dir, ".maf/coordination/inbox", role, "*.md"))

  def test_escalate_messages_the_project_manager_and_copies_the_architect
    write_manifest("project-manager", "architect", "backend-developer")
    id = add("blocked task")

    capture_io { Coord::CLI.new(["escalate", "--task", id, "no ameba installed"], env: @env).run }

    assert_match(/ESCALATION from backend-1 \(task #{id}\): no ameba installed/, File.read(inbox_files("project-manager").first))
    assert_equal 1, inbox_files("architect").size
    assert_match(/\tescalate\tbackend-1\t#{id} no ameba/, run_coord("log"))
    assert_equal "ESCALATED: no ameba installed", find(id)["annotations"].last["description"]
  end

  # A worker has no inbox of its own. Mail for backend-developer-3 must reach
  # backend-developer-1 when only that worker runs.
  def test_msg_to_a_worker_goes_to_the_role_inbox
    write_manifest("architect", "backend-developer")
    capture_io { Coord::CLI.new(["msg", "--from", "architect", "backend-developer-3", "merge"], env: @env).run }

    assert_empty inbox_files("backend-developer-3")
    assert_match(/^# for: backend-developer-3$/, File.read(inbox_files("backend-developer").first))
  end

  def test_msg_to_an_unknown_name_fails
    write_manifest("architect", "backend-developer")

    error = assert_raises(SystemExit) { capture_io { Coord::CLI.new(["msg", "backend-dev", "hi"], env: @env).run } }
    assert_includes error.message, "unknown recipient 'backend-dev'"
  end

  def test_msg_with_a_task_saves_the_text_as_a_task_note
    write_manifest("architect", "backend-developer")
    id = add("task with mail")
    capture_io { Coord::CLI.new(["msg", "--from", "architect", "--task", id, "backend-developer", "use A"], env: @env).run }

    assert_equal "MSG from architect: use A", find(id)["annotations"].last["description"]
    assert_match(/Task #{id}: use A/, File.read(inbox_files("backend-developer").first))
  end

  # An FYI message waits for the next run of the role. It wakes no one: no
  # hook runs, and `coord inbox --wait` does not return for it.
  def test_msg_fyi_wakes_no_one
    write_manifest("architect", "backend-developer")
    hook = install_hook("backend-developer", "echo fired > \"$0.out\"\n")
    capture_io { Coord::CLI.new(["msg", "--fyi", "--from", "architect", "backend-developer", "note"], env: @env).run }

    assert_match(/\.fyi\.md\z/, inbox_files("backend-developer").first)
    refute wait_for_file("#{hook}.out", timeout: 1), "the hook ran for an FYI message"
    assert_empty Coord::Messages.new(Coord::Paths.new(@env["COORD_DIR"]), "x").wake_files("backend-developer")
  end

  def test_await_arms_the_stop_hook_of_the_worker
    out, = capture_io { Coord::CLI.new(["await", "--timeout", "120"], env: @env).run }

    arm = JSON.parse(File.read(File.join(@env["COORD_DIR"], "locks", "await-backend-1.json")))
    assert_equal "backend-developer", arm["role"]
    assert_in_delta Time.now.to_i + 120, arm["until"], 5
    assert_includes out, "Then end your turn"
  end

  def test_await_refuses_a_dispatched_run
    env = @env.merge("COORD_DISPATCHED" => "1")
    error = assert_raises(SystemExit) { capture_io { Coord::CLI.new(["await"], env: env).run } }
    assert_includes error.message, "dispatched run cannot wait"
  end

  def test_inbox_reads_the_old_worker_inbox_folders
    old = File.join(@dir, ".maf/coordination/inbox/backend-developer-3")
    FileUtils.mkdir_p(old)
    File.write(File.join(old, "1.md"), "# to: backend-developer-3\n# from: architect\n\nlost mail\n")

    assert_includes run_cli("inbox", "backend-developer"), "lost mail"
    assert_empty Dir.glob(File.join(old, "*.md"))
  end

  def test_escalate_without_a_project_manager_goes_to_the_architect_only
    write_manifest("architect", "backend-developer")

    capture_io { Coord::CLI.new(["escalate", "disk full"], env: @env).run }

    assert_equal 1, inbox_files("architect").size
    assert_empty inbox_files("project-manager")
  end

  def test_the_project_manager_cannot_escalate_to_itself
    write_manifest("project-manager")
    env = escalate_env("project-manager")

    _, err = capture_io { assert_raises(SystemExit) { Coord::CLI.new(["escalate", "x"], env: env).run } }

    assert_includes err, "cannot escalate to itself"
  end

  def test_a_task_without_a_scope_never_conflicts
    run_coord("add", "--role", "reviewer", "--title", "review one")
    run_coord("add", "--role", "reviewer", "--title", "review two")

    assert_includes run_coord("conflicts"), "no scope conflicts"
  end

  def test_taskrc_hides_the_override_footnote
    refute_includes File.read(@env["TASKRC"])[/^verbose=.*$/], "override"
  end

  # `coord log N` must reject a non-numeric N instead of silently printing
  # nothing (the old `&.to_i` turned garbage into 0).
  def test_log_rejects_non_numeric_count
    assert_raises(SystemExit) do
      capture_io { Coord::CLI.new(["log", "abc"], env: @env).run }
    end
  end

  # A hook at .maf/coordination/message-hooks/<role>.sh runs when a message is delivered
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

  # Hook output goes to .maf/coordination/message-hooks/<role>.log, not /dev/null, so a
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
    File.write(File.join(@dir, ".maf/config.json"), JSON.generate(manifest))
    capture_io { Coord::CLI.new(["broadcast", "--from", "architect", "heads up"], env: @env).run }
    refute_empty Dir.glob(File.join(@env["COORD_DIR"], "inbox", "tester", "*.md"))
  end

  def inbox(role) = Dir.glob(File.join(@env["COORD_DIR"], "inbox", role, "*.md"))

  def write_team_manifest
    roles = %w[project-manager architect tester]
    manifest = { agents: roles.map { |role| { harness: "claude", role: role } } }
    File.write(File.join(@dir, ".maf/config.json"), JSON.generate(manifest))
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

  def write_verify(command) = File.write(File.join(@dir, ".maf/config.json"), JSON.generate(verify: command))

  def test_status_shows_the_token_totals_per_worker
    FileUtils.mkdir_p(File.join(@dir, ".maf/coordination", "usage"))
    usage = { "input_tokens" => 120, "cached_input_tokens" => 90, "output_tokens" => 30, "runs" => 2 }
    File.write(File.join(@dir, ".maf/coordination", "usage", "tester-bot.json"), JSON.generate(usage))
    out, = capture_io { Coord::CLI.new(["status"], env: @env).run }

    assert_includes out, "tokens tester-bot: input=120 cached=90 output=30 runs=2"
  end

def write_vault(body)
  FileUtils.mkdir_p(File.join(@dir, ".maf", "bin"))
  File.write(File.join(@dir, ".maf", "bin", "vault"), body)
end

def test_status_shows_the_graph_age
  write_vault("puts '{\"state\":\"stale\",\"commits\":3}'\n")
  out, = capture_io { Coord::CLI.new(["status"], env: @env).run }

  assert_includes out, "graph age: 3 commits (stale)"
end

def test_status_shows_no_graph_line_without_the_vault_script
  out, = capture_io { Coord::CLI.new(["status"], env: @env).run }

  refute_includes out, "graph age"
end

def test_status_survives_a_broken_vault_script
  write_vault("exit 1\n")
  out, = capture_io { Coord::CLI.new(["status"], env: @env).run }

  refute_includes out, "graph age"
end

  # The verify command is a mechanical gate: a failing check refuses done.
  def test_done_is_refused_while_the_verify_command_fails
    write_verify("echo 2 failures; exit 1")
    id = add("unverified work")
    error = assert_raises(SystemExit) { capture_io { Coord::CLI.new(["done", "--force", id], env: @env).run } }

    assert_includes error.message, "2 failures"
    assert find(id), "the task must stay pending"
  end

  def test_done_passes_when_the_verify_command_passes
    write_verify("true")
    id = add("verified work")
    out, = capture_io { Coord::CLI.new(["done", id], env: @env).run }

    assert_includes out, "done #{id}"
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

    assert_includes err, "coord inbox --wait"
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

  def presence_path = File.join(@env["COORD_DIR"], "presence", "reviewer-1.json")

  def record_presence
    capture_io { Coord::CLI.new(["status"], env: session_env("reviewer", "reviewer-1")).run }
    JSON.parse(File.read(presence_path))
  end

  def test_presence_shows_a_reused_pid_as_gone
    record = record_presence.merge("started" => "Mon Jan  1 00:00:00 2001")
    File.write(presence_path, JSON.generate(record))

    assert_match(/^reviewer-1\treviewer\tsession\tgone\t/, who)
  end

  def test_presence_without_identity_stays_readable
    File.write(presence_path, JSON.generate(record_presence.except("started")))

    assert_match(/^reviewer-1\treviewer\tsession\tlive\t/, who)
  end

  def with_env(key, value)
    saved = ENV[key]
    ENV[key] = value
    yield
  ensure
    saved.nil? ? ENV.delete(key) : ENV[key] = saved
  end

  def test_presence_survives_a_timezone_change_between_write_and_read
    with_env("TZ", "Asia/Tokyo") { record_presence }

    with_env("TZ", "America/New_York") do
      assert_match(/^reviewer-1\treviewer\tsession\tlive\t/, who)
    end
  end

  def test_board_guard_reads_task_pairs_from_a_board_with_taskrc_set
    rc = File.join(@dir, "verbose_rc")
    File.write(rc, "data.location=#{File.join(@dir, "verbose_data")}\n")

    with_env("TASKRC", rc) { assert_kind_of Array, BoardGuard.tasks }
  end

  def test_presence_without_identity_and_old_seen_at_is_gone
    record = record_presence.except("started").merge("seen_at" => (Time.now - 7200).utc.iso8601)
    File.write(presence_path, JSON.generate(record))

    assert_match(/^reviewer-1\treviewer\tsession\tgone\t/, who)
  end

  def next_output(worker, *args)
    env = session_env("backend-developer", worker)
    capture_io { Coord::CLI.new(["next", *args], env: env).run }.first
  end

  def hold_until_expired(worker)
    id = add("held")
    capture_io { Coord::CLI.new(["claim", id], env: session_env("backend-developer", worker)).run }
    sleep 1.1
    id
  end

  def test_next_lists_an_expired_claim_of_another_worker
    with_env("COORD_LEASE_TTL", "1") do
      id = hold_until_expired("backend-developer-2")

      assert_includes next_output("backend-developer-1", "backend-developer"), id
    end
  end

  def test_next_skips_a_task_the_caller_holds
    with_env("COORD_LEASE_TTL", "1") do
      id = hold_until_expired("backend-developer-1")

      refute_includes next_output("backend-developer-1", "backend-developer"), id
    end
  end

  def test_next_wait_output_skips_an_expired_claim_of_the_caller
    with_env("COORD_LEASE_TTL", "1") do
      held = hold_until_expired("backend-developer-1")
      Thread.new { sleep 0.3; add("fresh task") }
      out = next_output("backend-developer-1", "--wait", "--interval", "1", "--timeout", "5")

      assert_includes out, "fresh task"
      refute_includes out, held
    end
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
    File.write(File.join(@dir, ".maf/config.json"), JSON.generate(manifest))
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
    coord_dir = File.join(@dir, ".maf/coordination")
    taskrc = File.join(coord_dir, "taskrc")
    Coord::Setup.new(Coord::Paths.new(coord_dir), taskrc).ensure_taskrc

    assert_match(/^data\.location=/, File.read(taskrc))
  end

  # Regression: a user's own TASKRC (e.g. ~/.taskrc, pointed at their real
  # Taskwarrior database) must never be rewritten to point at this project.
  def test_ensure_taskrc_refuses_to_redirect_an_external_taskrc
    coord_dir = File.join(@dir, ".maf/coordination")
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
    coord_dir = File.join(@dir, ".maf/coordination")
    external_taskrc = File.join(@dir, "external", ".taskrc")
    personal_data = File.join(@dir, "my-tasks")
    FileUtils.mkdir_p(File.dirname(external_taskrc))
    File.write(external_taskrc, "data.location=#{personal_data}\n")

    _, err = capture_io { Coord::Setup.new(Coord::Paths.new(coord_dir), external_taskrc).ensure_taskrc }

    assert_match(%r{outside \.maf/coordination/}, err)
    assert_includes File.read(external_taskrc), "data.location=#{personal_data}"
  end

  # Regression: a marked taskrc from an older install that has no
  # data.location would silently fall back to the global ~/.task database.
  def test_ensure_taskrc_adds_data_location_to_an_old_marked_taskrc
    coord_dir = File.join(@dir, ".maf/coordination")
    taskrc = File.join(coord_dir, "taskrc")
    FileUtils.mkdir_p(coord_dir)
    File.write(taskrc, "# #{Coord::MARKER}\nuda.role.type=string\n")

    Coord::Setup.new(Coord::Paths.new(coord_dir), taskrc).ensure_taskrc

    content = File.read(taskrc)
    assert_match(/^data\.location=/, content)
    assert_includes content, "uda.role.type=string"
    assert_equal 1, content.scan(Coord::MARKER).size
  end

  def test_an_older_taskrc_gets_the_verbose_line
    coord_dir = File.join(@dir, ".maf/coordination")
    taskrc = File.join(coord_dir, "taskrc")
    FileUtils.mkdir_p(coord_dir)
    File.write(taskrc, "# #{Coord::MARKER}\nuda.role.type=string\ndata.location=#{coord_dir}\n# <<< multi-agent-flow <<<\n")

    Coord::Setup.new(Coord::Paths.new(coord_dir), taskrc).ensure_taskrc

    assert_match(/^verbose=/, File.read(taskrc))
  end
end

class WorktreeTest < Minitest::Test
  def setup
    skip "git not installed" unless system("git", "--version", out: File::NULL)

    @root = Dir.mktmpdir("coord-worktree-test")
    run_git("init", "-q")
    # `.maf/bin/coord` is normally tracked in git, so a fresh worktree checks
    # out its own real copy of it.
    FileUtils.mkdir_p([File.join(@root, ".maf", "bin"), File.join(@root, ".maf", "coordination")])
    FileUtils.touch(File.join(@root, ".maf", "bin", "coord"))
    File.write(File.join(@root, ".gitignore"), ".maf/env.sh\n")
    run_git("add", ".maf/bin/coord", ".gitignore")
    run_git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def run_git(*args)
    system("git", "-C", @root, *args, out: File::NULL) || raise("git #{args.join(" ")} failed")
  end

  # All worktrees live inside the project, under <project>/.maf/worktrees/<slug>.
  def worktrees_root
    File.join(@root, ".maf/worktrees")
  end

  def test_worktree_lives_under_the_worktrees_folder
    Coord::Worktree.new(@root).create("tester", nil)
    @worktree_dir = File.join(worktrees_root, "tester")
    env_file = File.read(File.join(@worktree_dir, ".maf/env.sh"))

    assert_equal "#{@root}/.maf/worktrees/tester", @worktree_dir
    assert Dir.exist?(@worktree_dir)
    assert_includes env_file, "COORD_DIR=#{File.join(@root, ".maf/coordination")}"
    assert_includes env_file, "TASKRC=#{File.join(@root, ".maf/coordination", "taskrc")}"
    assert_includes env_file, "MAF_BIN=#{File.join(@root, ".maf", "bin")}"
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

  # The HEAD of the main checkout can be a task branch of another role.
  def test_a_new_worker_branch_starts_on_the_base_branch_not_on_the_main_head
    run_git("checkout", "-q", "-B", "main")
    base = `git -C #{@root} rev-parse main`.strip
    run_git("checkout", "-q", "-b", "task/aaaa1111")
    File.write(File.join(@root, "foreign.txt"), "x")
    run_git("add", "foreign.txt")
    run_git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "foreign")

    Coord::Worktree.new(@root).create("pr-organizer", nil)

    assert_equal base, `git -C #{File.join(worktrees_root, "pr-organizer")} rev-parse HEAD`.strip
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

  def env_file(slug) = File.read(File.join(worktrees_root, slug, ".maf/env.sh"))

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
    slots = Coord::Slots.new(File.join(@root, ".maf/coordination"))

    assert_equal 1, slots.assign("tester")
    assert_equal 2, slots.assign("reviewer")
    FileUtils.remove_entry(File.join(worktrees_root, "reviewer"))

    assert_equal 2, slots.assign("backend-developer")
  end

  def test_the_project_hook_output_is_appended_to_the_env_file
    File.write(File.join(@root, ".maf/coordination", "worktree-env.rb"),
               'puts "export PORT=#{3000 + ENV.fetch("COORD_SLOT").to_i}"')
    Coord::Worktree.new(@root).create("tester", nil)

    assert_includes env_file("tester"), "export PORT=3001\n"
  end

  # A shell sources .maf/env.sh. Keep only exports, so a hook that prints
  # other text cannot run a command in every later shell.
  def test_the_project_hook_output_keeps_only_export_lines
    File.write(File.join(@root, ".maf/coordination", "worktree-env.rb"), <<~RUBY)
      puts "echo not allowed"
      puts "export OK=1"
    RUBY
    Coord::Worktree.new(@root).create("tester", nil)

    assert_includes env_file("tester"), "export OK=1\n"
    refute_includes env_file("tester"), "echo not allowed"
  end

  def test_a_failing_project_hook_does_not_stop_the_worktree
    File.write(File.join(@root, ".maf/coordination", "worktree-env.rb"), "exit 1")
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
# coord and showed .maf/env.sh as untracked. The command must copy coord in
# and keep .maf/env.sh out of the worktree's status.
class WorktreeFirstRunTest < Minitest::Test
  def setup
    skip "git not installed" unless system("git", "--version", out: File::NULL)

    @root = Dir.mktmpdir("coord-worktree-first")
    run_git("init", "-q")
    File.write(File.join(@root, "README.md"), "x\n")
    run_git("add", "README.md")
    run_git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init")
    FileUtils.mkdir_p(File.join(@root, ".maf", "bin"))
    File.write(File.join(@root, ".maf", "bin", "coord"), "#!/usr/bin/env ruby\n")
    @worktree_dir = File.join(@root, ".maf/worktrees", "tester")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def run_git(*args)
    system("git", "-C", @root, *args, out: File::NULL) || raise("git #{args.join(" ")} failed")
  end

  def test_worktree_copies_uncommitted_coord_and_hides_env_file
    Coord::Worktree.new(@root).create("tester", nil)

    assert File.exist?(File.join(@worktree_dir, ".maf", "bin", "coord"))
    status = `git -C #{@worktree_dir} status --porcelain`
    refute_includes status, ".maf/env.sh"
  end

  # Regression: dispatch mode failed in each new worktree, because only coord was copied.
  def test_worktree_copies_every_uncommitted_script_of_the_bin_folder
    %w[dispatcher vault].each { |name| File.write(File.join(@root, ".maf", "bin", name), "#!/usr/bin/env ruby\n") }
    Coord::Worktree.new(@root).create("tester", nil)

    %w[coord dispatcher vault].each { |name| assert File.exist?(File.join(@worktree_dir, ".maf", "bin", name)), name }
  end

  # The scripts of the bin folder load the shared library from .maf/lib.
  def test_worktree_copies_the_shared_library
    lib = ".maf/lib/maf/shared/processes.rb"
    FileUtils.mkdir_p(File.dirname(File.join(@root, lib)))
    File.write(File.join(@root, lib), "# shared\n")
    Coord::Worktree.new(@root).create("tester", nil)

    assert File.exist?(File.join(@worktree_dir, lib))
  end

  # The graph is not committed. Each worktree gets a symlink to the graph of
  # the main checkout, and git does not show it.
  def test_worktree_links_the_graph_of_the_main_checkout
    write("graphify-out/graph.json")
    Coord::Worktree.new(@root).create("tester", nil)

    link = File.join(@worktree_dir, "graphify-out")
    assert File.symlink?(link)
    assert_equal File.realpath(File.join(@root, "graphify-out")), File.realpath(link)
    refute_includes `git -C #{@worktree_dir} status --porcelain`, "graphify-out"
  end

  HOOK_FILES = %w[.maf/coordination/harness-hooks/context-watch.rb .maf/coordination/harness-hooks/board-watch.rb
                  .maf/coordination/harness-hooks/next-task.rb .opencode/plugins/board-watch.js].freeze

  # The flow is not committed, so a worktree gets the hook scripts as copies.
  # Claude Code reads the hook settings from .maf/claude/settings.json of the main project.
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
    coord_dir = File.join(@root, ".maf/coordination")
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
    # coord land and coord goal sync commit with the git identity of the repo.
    git(@root, "config", "user.email", "t@t")
    git(@root, "config", "user.name", "t")
    File.write(File.join(@root, ".gitignore"), ".maf/coordination/\n.maf/worktrees/\n")
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
    dir = File.join(@root, ".maf/worktrees", "goal-#{short(uuid)}")

    assert_equal "goal/#{short(uuid)}", `git -C #{dir} branch --show-current`.strip
    assert_includes coord("goal", "list"), "Show prices"
  end

  def test_goal_add_refuses_a_missing_base_branch
    assert_raises(SystemExit) { coord("goal", "add", "--title", "x", "--base", "nope") }
  end

  # An empty base_branch is not a branch. Fall back to the default branch
  # instead of aborting with "base branch  does not exist".
  def test_an_empty_base_branch_falls_back_to_the_default_branch
    File.write(File.join(@root, ".maf/config.json"), JSON.generate(base_branch: ""))
    uuid = add_goal

    dir = File.join(@root, ".maf/worktrees", "goal-#{short(uuid)}")
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
    goal_dir = File.join(@root, ".maf/worktrees", "goal-#{short(uuid)}")
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
    File.join(@root, ".maf/worktrees", "tester-1")
  end

  # A task with own commits and a goal branch that moved on after the start.
  def started_task_behind_goal
    uuid = add_goal
    task = coord("add", "--role", "tester", "--scope", "test/**", "--goal", uuid, "--title", "t").strip
    worker_dir = worker_worktree
    coord("start-task", task, dir: worker_dir)
    commit(worker_dir, "task work")
    commit(File.join(@root, ".maf/worktrees", "goal-#{short(uuid)}"), "sibling task merged")
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
    commit(File.join(@root, ".maf/worktrees", "goal-#{short(uuid)}"), "sibling task merged")

    assert_includes coord("done", task, dir: worker_dir), "done #{task}"
  end

  def goal_dir(uuid) = File.join(@root, ".maf/worktrees", "goal-#{short(uuid)}")
  def branch?(name) = system("git", "-C", @root, "show-ref", "--quiet", "refs/heads/#{name}")

  # A done task with two commits and a worker report.
  def done_task_with_work
    uuid = add_goal
    task = coord("add", "--role", "tester", "--scope", "test/**", "--goal", uuid, "--title", "Add price test").strip
    worker_dir = worker_worktree
    coord("start-task", task, dir: worker_dir)
    File.write(File.join(worker_dir, "price_test.rb"), "# test\n")
    commit(worker_dir, "wip 1")
    commit(worker_dir, "wip 2")
    coord("annotate", task, "STATUS: done. FILES: price_test.rb. TESTS: 3 runs, 0 failures. NOTES: none")
    coord("done", task, dir: worker_dir)
    [uuid, task, worker_dir]
  end

  def test_land_squashes_the_task_into_one_goal_commit_with_trailers
    uuid, task, = done_task_with_work

    assert_includes coord("land", task, "--subject", "test(prices): add price test"), "landed task/#{short(task)}"
    message = `git -C #{goal_dir(uuid)} log -1 --format=%B`
    ["test(prices): add price test", "Task: #{task}", "Goal: #{uuid}", "Tests: 3 runs, 0 failures."].each do |line|
      assert_includes message, line
    end
    assert_equal 1, `git -C #{goal_dir(uuid)} rev-list --count main..HEAD`.to_i
    assert File.exist?(File.join(goal_dir(uuid), "price_test.rb"))
  end

  def test_land_deletes_the_task_branch_and_returns_the_worker_to_its_branch
    _uuid, task, worker_dir = done_task_with_work
    coord("land", task)

    refute branch?("task/#{short(task)}")
    assert_equal "worker/tester-1", `git -C #{worker_dir} branch --show-current`.strip
    assert_includes coord("show", task), "LANDED:"
  end

  def test_land_refuses_a_task_that_is_not_done
    uuid = add_goal
    task = coord("add", "--role", "tester", "--scope", "test/**", "--goal", uuid, "--title", "t").strip
    coord("start-task", task, dir: worker_worktree)

    error = assert_raises(SystemExit) { coord("land", task) }
    assert_includes error.message, "is not done"
  end

  # A review task commits nothing, so it lands nothing.
  def test_land_of_a_task_without_own_commits_records_no_changes
    uuid = add_goal
    task = coord("add", "--role", "tester", "--scope", "test/**", "--goal", uuid, "--title", "t").strip
    worker_dir = worker_worktree
    coord("start-task", task, dir: worker_dir)
    coord("done", task, dir: worker_dir)

    assert_includes coord("land", task), "no changes"
    refute branch?("task/#{short(task)}")
  end

  def test_land_refuses_a_task_branch_that_lacks_the_goal_head
    _uuid, task, worker_dir = started_task_behind_goal
    coord("done", "--force", task, dir: worker_dir)

    error = assert_raises(SystemExit) { coord("land", task) }
    assert_includes error.message, "lacks the head"
  end

  def test_goal_done_is_refused_until_the_goal_contains_the_base_head
    uuid = add_goal
    commit(@root, "base moved")

    error = assert_raises(SystemExit) { coord("goal", "done", uuid) }
    assert_includes error.message, "coord goal sync"
    assert_includes coord("goal", "sync", uuid), "merged main into goal/#{short(uuid)}"
    assert_includes coord("goal", "done", uuid), "goal/#{short(uuid)}"
  end

  def test_gc_is_a_dry_run_without_yes
    uuid, task, = done_task_with_work
    coord("land", task)
    coord("goal", "done", uuid)
    git(@root, "merge", "-q", "--no-ff", "--no-edit", "goal/#{short(uuid)}")

    assert_includes coord("gc"), "delete  goal goal/#{short(uuid)}"
    assert branch?("goal/#{short(uuid)}")
  end

  def test_gc_deletes_a_merged_goal_and_its_worktree
    uuid, task, = done_task_with_work
    coord("land", task)
    coord("goal", "done", uuid)
    git(@root, "merge", "-q", "--no-ff", "--no-edit", "goal/#{short(uuid)}")

    out = coord("gc", "--yes")
    assert_includes out, "deleted goal goal/#{short(uuid)}"
    assert_includes out, "keep    branch worker/tester-1: checked out in"
    refute branch?("goal/#{short(uuid)}")
    refute Dir.exist?(goal_dir(uuid))
  end

  def test_gc_keeps_open_goals_and_unlanded_task_branches
    uuid, task, worker_dir = done_task_with_work
    git(worker_dir, "switch", "-q", "worker/tester-1")

    out = coord("gc", "--yes")
    assert_includes out, "keep    goal goal/#{short(uuid)} and its worktree: goal is not done"
    assert_includes out, "keep    branch task/#{short(task)}: task is done but not landed"
  end

  # The test repo becomes a clone of a bare origin. A second clone pushes to it.
  def with_origin
    origin = File.join(@root, "..", "#{File.basename(@root)}-origin.git")
    git(@root, "clone", "-q", "--bare", @root, origin)
    git(@root, "remote", "add", "origin", origin)
    git(@root, "fetch", "-q", "origin")
    yield origin
  ensure
    FileUtils.rm_rf(origin)
  end

  def push_upstream_commit(origin)
    other = Dir.mktmpdir("coord-ff-other")
    git(other, "clone", "-q", origin, ".")
    commit(other, "upstream change")
    git(other, "push", "-q", "origin", "HEAD:main")
    `git -C #{other} rev-parse HEAD`.strip
  ensure
    FileUtils.rm_rf(other)
  end

  def head(dir) = `git -C #{dir} rev-parse HEAD`.strip

  def test_reuse_fast_forwards_the_worker_branch_from_origin
    with_origin do |origin|
      dir = worker_worktree
      upstream = push_upstream_commit(origin)
      out = coord("worktree", "tester", "1")

      assert_equal upstream, head(dir)
      assert_includes out, "fast-forwarded worker/tester-1 to origin/main"
    end
  end

  def test_reuse_skips_the_fast_forward_in_a_dirty_worktree
    with_origin do |origin|
      dir = worker_worktree
      before = head(dir)
      File.write(File.join(dir, ".gitignore"), "changed\n")
      push_upstream_commit(origin)
      _out, err = capture_io { Dir.chdir(@root) { Coord::CLI.new(%w[worktree tester 1], env: @env).run } }

      assert_equal before, head(dir)
      assert_includes err, "the worktree has uncommitted changes"
    end
  end

  def test_reuse_skips_a_branch_that_is_not_a_fast_forward
    with_origin do |origin|
      dir = worker_worktree
      commit(dir, "local work")
      local = head(dir)
      push_upstream_commit(origin)
      _out, err = capture_io { Dir.chdir(@root) { Coord::CLI.new(%w[worktree tester 1], env: @env).run } }

      assert_equal local, head(dir)
      assert_includes err, "has commits that origin/main lacks"
    end
  end

  def write_copy_list(list)
    File.write(File.join(@root, ".maf/config.json"), JSON.generate(copy_to_worktree: list))
  end

  # Untracked host files like .env never reach a new worktree through git.
  def test_worktree_copies_the_declared_host_files
    FileUtils.mkdir_p(File.join(@root, "config"))
    File.write(File.join(@root, ".env"), "KEY=1")
    File.write(File.join(@root, "config", "master.key"), "secret")
    write_copy_list([".env", "config/master.key", "missing.txt"])
    dir = worker_worktree

    assert_equal "KEY=1", File.read(File.join(dir, ".env"))
    assert_equal "secret", File.read(File.join(dir, "config", "master.key"))
    refute File.exist?(File.join(dir, "missing.txt"))
  end

  def test_a_reused_worktree_keeps_the_file_the_agent_changed
    File.write(File.join(@root, ".env"), "KEY=1")
    write_copy_list([".env"])
    dir = worker_worktree
    File.write(File.join(dir, ".env"), "KEY=agent")
    worker_worktree

    assert_equal "KEY=agent", File.read(File.join(dir, ".env"))
  end

  def test_copy_list_skips_paths_outside_the_project
    File.write(File.join(File.dirname(@root), "outside-#{File.basename(@root)}"), "x")
    write_copy_list(["../outside-#{File.basename(@root)}", "/etc/hosts"])
    _out, err = capture_io { Dir.chdir(@root) { Coord::CLI.new(%w[worktree tester 1], env: @env).run } }

    assert_includes err, "copy_to_worktree skips paths outside the project"
    refute File.exist?(File.join(@root, ".maf/worktrees", "outside-#{File.basename(@root)}"))
  ensure
    FileUtils.rm_f(File.join(File.dirname(@root), "outside-#{File.basename(@root)}"))
  end

  def test_worktree_warns_when_a_harness_has_no_file_for_the_role
    manifest = { agents: [{ harness: "claude", role: "architect" }, { harness: "opencode", role: "tester" }] }
    File.write(File.join(@root, ".maf/config.json"), JSON.generate(manifest))
    _out, err = capture_io { Dir.chdir(@root) { Coord::CLI.new(%w[worktree tester 1], env: @env).run } }

    assert_includes err, "maf add claude:tester"
  end
end

# GoalPrTest checks the pull request flow against a fake gh. The fake logs
# each call and answers from files in its own folder.
class GoalPrTest < GoalTest
  # Run only the tests of this class, not the inherited GoalTest tests.
  def self.runnable_methods = public_instance_methods(false).grep(/\Atest_/).map(&:to_s)

  GITHUB = { bot_user: "maf-bot", bot_email: "bot@example.com", reviewer: "dominik", repo: "o/r" }.freeze

  FAKE_GH = <<~'RUBY'
    #!/usr/bin/env ruby
    dir = File.dirname(__dir__)
    File.open(File.join(dir, "calls.log"), "a") { |f| f.puts("#{ENV["GH_TOKEN"]} #{ARGV.join(" ")}") }
    File.write(File.join(dir, "input"), $stdin.read) if ARGV.include?("-")
    case ARGV.first(2)
    in ["auth", "token"] then puts "tok"
    in ["pr", "create"] then puts "https://github.com/o/r/pull/7"
    in ["pr", "view"] then print File.read(File.join(dir, "view.json"))
    in ["api", *] then print File.read(File.join(dir, "inline.json"))
    else nil
    end
  RUBY

  def setup
    super
    @gh_dir = Dir.mktmpdir("coord-fake-gh")
    FileUtils.mkdir_p(File.join(@gh_dir, "bin"))
    File.write(File.join(@gh_dir, "bin", "gh"), FAKE_GH)
    File.chmod(0o755, File.join(@gh_dir, "bin", "gh"))
    @saved = ENV.to_h.slice("PATH", "MAF_NOTIFY")
    ENV["PATH"] = "#{File.join(@gh_dir, "bin")}:#{ENV["PATH"]}"
    ENV["MAF_NOTIFY"] = "0"
  end

  def teardown
    @saved&.each { |key, value| ENV[key] = value }
    ENV.delete("MAF_NOTIFY") unless @saved&.key?("MAF_NOTIFY")
    FileUtils.rm_rf(@gh_dir) if @gh_dir
    super
  end

  def configure_github = File.write(File.join(@root, ".maf/config.json"), JSON.generate(github: GITHUB))
  def calls = File.read(File.join(@gh_dir, "calls.log"))
  def gh_input = File.read(File.join(@gh_dir, "input"))
  def answer(name, data) = File.write(File.join(@gh_dir, name), JSON.generate(data))

  # A goal with one landed task and an open pull request.
  def goal_with_pr
    configure_github
    uuid, task, = done_task_with_work
    coord("land", task, "--subject", "test(prices): add price test")
    coord("goal", "pr", uuid)
    uuid
  end

  def review(id, login, state, body) = { id: id, author: { login: login }, state: state, body: body }

  def test_goal_pr_pushes_the_goal_and_opens_a_pull_request_as_the_bot
    with_origin do |origin|
      uuid = goal_with_pr

      assert_includes calls, "tok pr create --repo o/r --head goal/#{short(uuid)} --base main"
      assert_includes calls, "--reviewer dominik"
      assert_includes gh_input, "test(prices): add price test"
      assert system("git", "-C", origin, "show-ref", "--quiet", "refs/heads/goal/#{short(uuid)}")
      assert_includes coord("show", uuid), "PR: https://github.com/o/r/pull/7"
      assert_equal "maf-bot", `git -C #{goal_dir(uuid)} log -1 --format=%an`.strip
    end
  end

  def test_a_second_goal_pr_comments_and_asks_for_a_new_review
    with_origin do
      uuid = goal_with_pr
      commit(goal_dir(uuid), "fix after review")
      coord("goal", "pr", uuid)

      assert_includes calls, "pr edit https://github.com/o/r/pull/7 --add-reviewer dominik"
      assert_includes gh_input, "fix after review"
    end
  end

  def test_goal_pr_is_refused_without_github_settings
    uuid = add_goal

    error = assert_raises(SystemExit) { coord("goal", "pr", uuid) }
    assert_includes error.message, "no github section"
  end

  def test_review_watch_sends_requested_changes_of_the_reviewer_to_the_architect
    with_origin do
      uuid = goal_with_pr
      answer("view.json", state: "OPEN", comments: [],
                          reviews: [review("R1", "dominik", "CHANGES_REQUESTED", "Fix names"),
                                    review("R2", "someone", "COMMENTED", "Ignore me")])
      answer("inline.json", [{ id: 5, user: { login: "dominik" }, path: "price_test.rb", line: 1, body: "Rename" }])
      coord("review-watch", "--once")

      inbox = coord("inbox", "architect")
      expected = ["CHANGES_REQUESTED: Fix names", "price_test.rb:1: Rename", "coord goal pr #{uuid}"]
      expected.each { |text| assert_includes inbox, text }
      refute_includes inbox, "Ignore me"
    end
  end

  def test_review_watch_forwards_each_review_only_once
    with_origin do
      goal_with_pr
      answer("view.json", state: "OPEN", comments: [], reviews: [review("R1", "dominik", "APPROVED", "")])
      answer("inline.json", [])
      2.times { coord("review-watch", "--once") }

      assert_equal 1, coord("inbox", "architect").scan("APPROVED").size
    end
  end

  def test_review_watch_closes_a_merged_goal_and_cleans_its_branches
    with_origin do
      uuid = goal_with_pr
      git(@root, "merge", "-q", "--no-ff", "--no-edit", "goal/#{short(uuid)}")
      git(@root, "push", "-q", "origin", "main")
      answer("view.json", state: "MERGED", comments: [], reviews: [])
      coord("review-watch", "--once")

      assert_includes coord("show", uuid), "status: completed"
      refute branch?("goal/#{short(uuid)}")
      assert_includes coord("inbox", "architect"), "was merged"
    end
  end
end

# WorkMemoryTest checks the graphify memory notes of coord done and coord
# lesson against a fake graphify. The fake logs each call, one argument a line.
class WorkMemoryTest < GoalTest
  def self.runnable_methods = public_instance_methods(false).grep(/\Atest_/).map(&:to_s)

  def setup
    super
    @bin = File.join(@root, ".fake-bin")
    FileUtils.mkdir_p(@bin)
    File.write(File.join(@bin, "graphify"), "#!/bin/sh\nprintf '%s\\n' \"$@\" '--' >> \"#{@root}/.graphify-calls\"\n")
    FileUtils.chmod(0o755, File.join(@bin, "graphify"))
    @path = ENV.fetch("PATH", nil)
    ENV["PATH"] = "#{@bin}:#{@path}"
  end

  def teardown
    ENV["PATH"] = @path
    super
  end

  def write_graph
    nodes = [{ id: "price_test", label: "price_test.rb", source_file: "price_test.rb" },
             { id: "price_test_helper", label: "helper", source_file: "price_test.rb" }]
    FileUtils.mkdir_p(File.join(@root, "graphify-out"))
    File.write(File.join(@root, "graphify-out", "graph.json"), JSON.generate(nodes: nodes))
  end

  def calls
    path = File.join(@root, ".graphify-calls")
    File.exist?(path) ? File.read(path).split("--\n").map { |call| call.lines(chomp: true) } : []
  end

  def arg(call, flag) = call[call.index(flag) + 1]

  def test_done_saves_a_useful_note_on_the_changed_files_and_reflects
    write_graph
    done_task_with_work
    save, reflect = calls

    assert_equal ["save-result", "Add price test", "useful", "price_test"],
                 [save[0], arg(save, "--question"), arg(save, "--outcome"), arg(save, "--nodes")]
    assert_includes arg(save, "--answer"), "TESTS: 3 runs, 0 failures."
    assert_equal "reflect", reflect[0]
  end

  def test_done_without_a_graph_saves_nothing
    done_task_with_work

    assert_empty calls
  end

  def test_lesson_dead_end_saves_the_text_as_the_answer
    write_graph
    _uuid, task, = done_task_with_work
    coord("lesson", task, "dead_end", "a cache in the model failed")
    save = calls[2]

    assert_equal "dead_end", arg(save, "--outcome")
    assert_equal "a cache in the model failed", arg(save, "--answer")
    assert_equal "Add price test: a cache in the model failed", arg(save, "--question")
  end

  def test_lesson_corrected_saves_the_text_as_the_correction
    write_graph
    _uuid, task, = done_task_with_work
    coord("lesson", task, "corrected", "use the price service")

    assert_equal "use the price service", arg(calls[2], "--correction")
  end

  def test_lesson_without_a_graph_is_refused
    task = coord("add", "--role", "tester", "--scope", "test/**", "--title", "t").strip

    assert_raises(SystemExit) { capture_io { coord("lesson", task, "dead_end", "x") } }
  end

  def test_lesson_refuses_an_unknown_outcome
    write_graph
    task = coord("add", "--role", "tester", "--scope", "test/**", "--title", "t").strip

    assert_raises(SystemExit) { capture_io { coord("lesson", task, "useful", "x") } }
  end
end
