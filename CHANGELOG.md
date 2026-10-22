# Changelog

## [Unreleased]

- New: `.maf/sandbox.json` key `scope`. `dispatch` (the default) runs only the dispatched runs
  and the analyst in the sandbox. `all` also runs the interactive sessions in it, as before.
  An interactive session has approvals, so it now runs on the host by default. Set
  `"scope": "all"` to keep the old behavior. A project manager in an interactive session with
  `dispatch` can start a dispatcher on macOS.
- Fix: in the macOS sandbox, a copy did not paste. `pbcopy` could not reach
  `com.apple.lsd.mapdb`, so it wrote the text with a type that no app reads. The sandbox now
  allows this service. It only reads type names; `open` and Apple Events stay blocked.

## [0.5.0] - 2026-10-22

- Fix: in the macOS sandbox, headless Chrome aborted at start, and macOS showed a crash dialog
  for each try. New `.maf/sandbox.json` key `launch_services` lists the apps that can use
  LaunchServices. After each run, the dispatcher reports apps that the run started and that
  crashed, and LaunchServices denials, once for each app to the project manager.
- Fix: after Ctrl+C or SIGHUP, the dispatcher stopped, but the agent run continued in its own
  session. The dispatcher now stops the process group of the agent first.
- New: `steward`, a daemon outside the sandbox that runs a fixed list of host operations for the
  leads: `worker-restart`, `worker-retire`, `worktree-sync`, `goal-sync`, `runtime-restore`. An
  agent asks with `coord op request OPERATION [ARGUMENT]`. steward checks each argument, runs no
  shell, allows 3 runs per hour for one argument, and sends the result to the inbox of the role
  that asked. `maf start` starts steward. The project manager and the architect prompts list the
  operations. `maf update` installs `.maf/bin/steward`.
- New: operations that wait for the user: `worker-start`, `worker-model WORKER MODEL`, and
  `bundle-install` (frozen to `Gemfile.lock`). `maf op list|approve ID|deny ID` handles them.
  `.maf/sandbox.json` key `ops` sets the level of each operation: `auto`, `approve`, or `off`.
- After `maf untrack`, maf moves the old branches. `maf start` fast-forwards a worker branch
  also when the only changes are in flow files that the base branch no longer tracks: maf
  discards them first. `maf update` runs the new `coord goal migrate`, which merges the base
  branch into each goal branch that still tracks the flow files. Before, the user did these
  steps by hand, because the sandbox blocks an agent from deleting the flow files.
- Fix: `maf worker stop` did nothing for a session that `maf worker list` showed as running.
  `stop` read only the presence file, and that file can name an older session. `stop`, `start`,
  and `status` now find the session from the records of `maf start`, as `list` does.
- `maf worker stop` reports a session that does not stop after TERM, and prints the `kill -9`
  command. A session in a closed terminal can ignore TERM.

## [0.4.0] - 2026-10-21

- Fix: in the macOS sandbox, a worker that the project manager started failed on each run with
  `sandbox_apply: Operation not permitted`. macOS cannot start a sandbox inside a sandbox. The
  sandbox now sets `MAF_SEATBELT=1`. In the sandbox, `maf prepare --dispatch` prepares the worker
  and prints the start commands, and a dispatcher stops at once with the reason in its log.
- The project manager no longer adds workers on its own. Without a team budget, `maf prepare`
  refuses when an agent runs it. Only the user sets the budget: `maf team set` refuses when an
  agent runs it.
- Backup of the flow config. Each maf command copies `.maf/config.json`, `roles.yml`,
  `workflow.md`, and `sandbox.json` to `.git/maf/backup/` when they changed, and keeps 10
  copies. New command `maf restore [--list] [BACKUP] [--force]` puts them back and runs
  `maf update`. When `.maf/` exists without `config.json`, maf names the backup. Before, a
  merge of the `maf untrack` commit into a branch that still tracked the flow deleted the
  config, and the agents, `base_branch`, and `github` settings were lost.

## [0.3.0] - 2026-10-21

- Fix: each dispatched Hermes run failed. Hermes 0.22 refuses `--run-budget` with `--format
  stream-json`. maf no longer passes `--run-budget`. The `--timeout` of the dispatcher still
  stops a run.
- Fix: in a Hermes run, `coord` did not get `COORD_WORKER` and the other flow variables, so
  `coord done` refused to close the task. Hermes runs each session in a shared gateway and
  passes only the names in `terminal.client_env_passthrough`. `maf add` and `maf update` print
  the `hermes config set` command that adds the flow names to that list.
- `maf worker stop|start|restart|status ROLE` finds the worker when the role has one worker,
  for example `tester-bot`.
- `maf worker list` names the stopped workers also when no worker runs.
- A worker does not start a team of its own. `.maf/claude/settings.json` sets
  `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0`, so a subagent that Claude names in a `maf start`
  session does not start as a teammate. `maf update` adds the setting.
- Hermes: each role gets a toolset list. A role that edits no longer gets `kanban`,
  `delegation`, `cronjob`, `computer_use`, and the other toolsets outside the list.
- Fix: a Hermes role with `can_edit: false` did not get the graph MCP server, because its
  toolset list did not name `mcp-graphify-<project>`.
- The dispatcher blocks a task after 3 runs in a row that leave it claimed and not done, and
  escalates it to the project manager. Before, it resumed such a task each hour without end.
  New commands: `coord block ID [--kind K] TEXT` holds a task out of `coord next`, and
  `coord unblock ID` returns it. `coord status` and `coord board` show blocked tasks.
- A worker that cannot finish a task blocks it with a kind: `needs_input`, `dependency`, or
  `capability`. coord tells the architect (dependency) or the project manager (the other kinds).
  Before, the worker kept the claim, and the dispatcher resumed the task each hour.
- `maf worker list` shows each running worker: its role, harness, mode (session or dispatch),
  pid, and start time. A worker that runs twice, for example as a session and as a
  dispatcher, gets a warning. The last line names the registered workers that do not run.
- Effort levels per role (#44): `maf add --effort ROLE=LEVEL`, `maf start` and `maf prepare
  --effort LEVEL`, and `dispatcher --effort LEVEL`. maf passes the level to the harness in its
  own form: `--effort` (Claude Code), `model_reasoning_effort` (Codex), `--reasoning` (Hermes),
  `--variant` (opencode), and the model name for Cursor (`gpt-5.3-codex` + `high` =
  `gpt-5.3-codex-high`). Each role has a default level in `roles.yml` (`effort:`), used when the
  harness lists it. After `maf update`, the claude, codex, hermes, and cursor agents get the
  default of their role. The interactive mode shows the levels of each model and asks for one.
- Fix: Codex 0.163 ran the commands of a worker in its shared background server. The commands
  got the environment of the shell that started the server, not of the worker: no `.maf/bin` on
  PATH, no `COORD_ROLE` and `COORD_WORKER`. maf now starts Codex with `--no-daemon`.
- Fix: after a message run, the dispatcher counted the unclaimed tasks as dispatched and backed
  off: 2 minutes, then 4, then more. A message run must not claim a task, so the task waited
  without a reason. The task now runs in the next cycle.

## [0.2.0] - 2026-10-14

- The sandbox also protects the flow config in `.maf/claude/` and `.maf/mcp/`, and each script
  that it names. `maf start` and the dispatcher give these files to the harness on the host.
- Fix: `maf start` of a Codex worker in the sandbox stopped with `Errno::EPERM` on the protected
  `.codex/hooks.json`. maf now writes the file only on a change.
- The sandbox also protects `.maf/coordination/taskdata/hooks/`: Taskwarrior runs each script
  in it, also on the host.
- Fix: on Linux, a protected file in `/tmp` (for example a hook script in a harness config)
  made bwrap bind the host `/tmp`, with the sockets of host services. bwrap now binds a parent
  folder only in an allowed folder.
- Fix: `coord worktree` in the sandbox stopped with an error on the protected `.maf/env.sh` of a
  worktree. coord now writes the file only on a change, and it shows a warning if it cannot.
- Fix: `maf retire` did not stop a dispatcher of an older maf during a run longer than one
  hour. maf now also finds the dispatcher from its command in the worktree.
- `maf vm create` installs the maf version of the host, not the newest maf.
- The sandbox also protects `.maf/coordination/harness-hooks` of the main checkout.
- On Linux, maf no longer creates an empty `~/.codex/packages` or a `{}` `~/.cursor/cli-config.json`.
- Fix: `maf team` showed a running dispatcher of an older maf as stopped.
- maf does not take `bwrap` from a folder of the `write` list.
- Fix: a broken `.maf/sandbox.json` turned the sandbox off. maf now stops with an error.
- Fix: maf ran `sandbox-exec` and `bwrap` from `PATH`. maf now runs `/usr/bin/sandbox-exec`,
  and it does not take `bwrap` from the project or a temporary folder.
- On Linux, each sandboxed run gets a private `/dev/shm`.
- The analyst command starts in a new session without a terminal.
- Fix: an empty start time in `workers.json` made a running dispatcher look stopped.
- The sandbox also protects a hook script that `$CLAUDE_PROJECT_DIR` names, the scripts that
  the harness config of a worktree names, and `config` and `hooks/` of each submodule.
- Fix: `maf retire` stopped for good when another process had the pid of an old dispatcher.
  For a record without a start time, maf now uses the heartbeat.
- In a worktree, maf checks the Codex hook trust of the main checkout, because Codex uses
  the hooks of the main checkout there. The warning tells you to trust the hooks on the host.
- Fix: on Linux, a `TMPDIR` in `/run/user` (or a `write` path in or above a masked folder)
  opened the session bus again. bwrap now skips such a path.
- Fix: `maf retire` and `maf worker restart` went on when maf could not check the pid of a
  worker from an older maf. They now stop and show the `kill` command.
- Fix: in the dispatcher, a failed start of a run could run the exit handlers of the
  dispatcher in the child process.
- Fix: `printf task | maf start` (input without a final newline) waited forever in the sandbox.
- Fix: on macOS, a run could take the temporary folder of another project from `TMPDIR`.
- `maf vm login` says "this computer" instead of "this Mac", because it also runs on Linux.
- Fix: the dashboard ran the analyst command of `.maf/config.json` on the host. The agent
  can change that file, so the command now runs in the sandbox.
- The sandbox also protects `.maf/coordination/harness-hooks` in each worktree, and
  `.git/config.worktree` of the project and of each worktree.
- Fix: a relative path in the `write` list of `.maf/sandbox.json` started at the current
  folder. It now starts at the project root.
- Fix: on Linux, a home folder with its own overlay made maf think that it already ran in the
  sandbox, so it did not wrap the agent. The sandbox now also sets `MAF_BWRAP=1`.
- Fix: `echo task | maf start` with the sandbox on waited forever. The terminal relay now
  sends ^D when the input ends.
- Fix: `maf vm` stopped with an error for a VM without mounts.
- Fix: `maf start` could start a second dispatcher for a worker whose presence record has no
  start time. Such a record now counts as live while its heartbeat is recent. `maf stop` then
  shows the `kill` command instead of a signal to an unknown pid.
- Fix: in the sandbox, `maf stop` of an interactive worker stopped only the terminal relay.
  The relay now passes TERM, HUP, and INT to the harness, and waits for it.
- On Linux, maf puts back a protected symlink (for example `~/.claude/CLAUDE.md` into your
  dotfiles) that the agent changed during a run, and shows a warning.
- The sandbox also protects the harness config in each worktree.
- Fix: on Linux, a worker that a lead starts failed when the home folder has a space in its path.
- `docs/sandbox.md` has a new section: what the sandbox protects against.
- The sandbox uses an allowlist in the folder of each harness: the agent can write only
  the state paths, for example `~/.claude/projects` and `~/.codex/sessions`. Each other
  path is protected, also a new name in an update of the harness. On Linux, each existing
  path that is not state is bound read-only.
- Fix: the dispatcher ran the verify command of `.maf/config.json` on the host. The agent
  can change that file, so the command now runs in the sandbox.
- Fix: a dispatched run could push a command into the terminal of the dispatcher (TIOCSTI).
  Each run now starts in a new session without a terminal.
- Fix: the dispatcher ran `coord` from the worktree, where the agent can change it. It now
  runs `coord` of the main checkout.
- Fix: a sandboxed run of a worker with `--command` stopped with `NoMethodError`.
- The sandbox protects the config of each harness in the project (`.mcp.json`,
  `.claude/settings.json`, `.codex/config.toml`, `.opencode/`, and more), and `.maf/bin`,
  `.maf/lib`, and `.maf/env.sh` in each worktree.
- The sandbox no longer opens `~/.cache` and `~/Library/Caches`. On macOS, `XDG_CACHE_HOME`
  is a private folder of the project.
- The sandbox also protects a file that a config names with a relative path, and a named file of
  1 MB or more. In a Markdown file, maf follows only the imports, so the text of a skill does not
  protect the files of the project.
- `maf vm create` finds the agents of the project also in a subfolder or in a worktree.
- Fix: an agent in the sandbox could push a command into the terminal of an interactive
  `maf start` (TIOCSTI). The shell ran the command outside the sandbox after the harness stopped.
  With the sandbox on, the harness now gets its own terminal.
- The sandbox also protects each file that the config of a harness names: hook scripts,
  status line scripts, and imports in `CLAUDE.md`. It also protects `~/.claude/rules`, and
  `prompts`, `packages`, and `AGENTS.override.md` in `~/.codex`.
- On Linux, maf creates each missing config file of a harness before each run, so bwrap can protect it.
- `maf uninstall` removes `.maf/vm/` and tells you if the VM of the project still exists.
- `maf vm create` checks the checksum of the Taskwarrior download, and accepts only sizes above 0.
- The sandbox also protects `.maf/coordination/taskrc`, `.maf/coordination/worktree-env.rb`,
  `.git/commondir`, the git links of each worktree, and the config, hooks, and plugins of each harness.
  If a protected path is a symlink, the link is protected too. On Linux, maf creates the missing
  protected folders before each run.
- On macOS, the sandbox blocks LaunchServices (`open`) and Apple Events: they started apps outside the sandbox.
- `maf vm` with a missing or unknown action, or an unknown flag, shows the usage.
- A VM boot no longer installs the harness CLIs again. `maf vm create` makes a smaller VM by default:
  4 GiB of memory and a 20 GiB disk.
- Fix: `maf retire` could stop an unrelated process that got the pid of an ended dispatcher.
  maf now signals a pid only if its start time matches the recorded one. `maf start --detach`
  records the start time. `maf team`, `maf worker`, and the dashboard use the same check.
- The sandbox policy moved to `.maf/sandbox.json`. The agent cannot change it, the flow scripts,
  the message hooks, the git hooks, or `.git/config`. On macOS, each run gets a private `TMPDIR`,
  and the agent can connect only to the sockets of its own folders.
- `maf vm shell` loads `.maf/env.sh`, so `coord` is on PATH.
- The sandbox blocks host service sockets (tmux, Docker, systemd --user, D-Bus, SSH agent).
  On Linux, `/tmp` is private to the run, and bwrap keeps the Claude Code state file.
- `maf vm`: the VM name holds a hash of the project path, and each command checks that the VM
  mounts the project. The VM runs Ubuntu 26.04 and needs Lima 2.2.0 or later. The copied logins are always mode 600.
- Sandbox mode `bwrap` needs bubblewrap 0.10 or later. maf stops with an older bubblewrap.
- Linux support: sandbox mode `bwrap` (bubblewrap) and mode `auto` (seatbelt on macOS, bwrap on Linux).
  `maf vm` also runs on a Linux host with QEMU, and copies the claude login from `~/.claude/.credentials.json`.
- New command `maf vm`: run the whole team in a Lima VM on macOS. `maf vm create` makes a VM that
  sees only the project folder, at the same path as on the host. It installs Ruby, git, tmux,
  Taskwarrior 3, maf, and the CLI of each harness of the project. Then it asks for each harness
  if it can copy the login from this Mac into the VM (`--copy-logins`, `--no-copy-logins`, `maf vm login`).
- New sandbox for the agents on macOS: `{"mode": "seatbelt"}` in `.maf/sandbox.json`
  or `MAF_SANDBOX=seatbelt`. `maf start` and the dispatcher run the harness in `sandbox-exec`.
  The agent can write only to the project, the board, the temporary folders, and the folders of its harness.
- Each harness is one file in `lib/maf/shared/harnesses/`. To add a harness, add one
  file, one test file, and one row in the Harnesses table of the user manual.
  `test/harnesses/contract_test.rb` checks every harness file.
- The dispatcher has no default harness. Give `--harness NAME` or `--command TEMPLATE`.
  `maf start` gives the harness, so `maf start` does not change.
- A dispatched run gets `OPENCODE_CONFIG` only on the `opencode` harness.
- `maf untrack` untracks only the role links in `.cursor/agents/`, not the whole folder.
- New harness `cursor` (the Cursor CLI, `agent`): `maf add cursor:ROLE`, `maf start cursor ROLE`,
  and `dispatcher ROLE --harness cursor`. Role files go to `.cursor/agents/` as Cursor subagents.
  Cursor has no wake-up hook yet, so its agents wait with `coord next --wait`.

## [0.1.0] - 2026-10-08

- First release as a gem: `gem install maf`.
- All code is in the `Maf` module.
- The command moved from `bin/maf` to `exe/maf`. `bin/maf` stays for the links
  that point to it. A later version removes it.
- New commands: `maf version` and `maf guide` (prints the agent setup guide).
