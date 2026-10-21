# Sandbox mode

This manual is for users who run maf agents in a sandbox or in a VM.
Read it before you let agents run without approvals.

- [1. Why use a sandbox](#1-why-use-a-sandbox)
- [2. Choose a level of isolation](#2-choose-a-level-of-isolation)
- [3. Quick start](#3-quick-start)
- [4. Configure the sandbox](#4-configure-the-sandbox)
- [5. What the agent can do in the sandbox](#5-what-the-agent-can-do-in-the-sandbox)
- [6. Run agents in the sandbox](#6-run-agents-in-the-sandbox)
- [7. Notes for each harness](#7-notes-for-each-harness)
- [8. macOS details](#8-macos-details)
- [9. Linux details](#9-linux-details)
- [10. Limits of the sandbox](#10-limits-of-the-sandbox)
- [11. Run the team in a VM](#11-run-the-team-in-a-vm)
- [12. Troubleshooting](#12-troubleshooting)
- [13. Reference](#13-reference)

---

## 1. Why use a sandbox

A dispatched agent runs without approval prompts:

| Harness | Flag in a dispatched run |
|---|---|
| claude | `--permission-mode bypassPermissions` |
| codex | `--dangerously-bypass-approvals-and-sandbox` |
| hermes | `--yolo` |
| cursor | `--force` |
| opencode | the permissions of its role file |

Without a sandbox, such an agent can change each file that your user can change.
One wrong command can delete your home folder, change your shell profile, or
install a git hook that runs later on your machine.

The maf sandbox stops these writes. The agent can still work in the project:
edit code, run tests, commit, and use the board.

### What the sandbox protects against

An agent seldom tries to leave the sandbox on purpose. These are the real risks, from the most frequent:

| Risk | Example | What stops it |
|---|---|---|
| A mistake | `rm -rf` of the wrong folder, a change to your shell profile | the sandbox: the agent can write only the project and the state of its harness |
| A work-around | a write fails, so the agent changes a hook, a config, or the policy to finish its task | the sandbox: maf, git, and the harnesses run these files on the host, so they are protected (see [Protected files](#protected-files)) |
| A prompt injection | an issue, a web page, or a file of a dependency tells the agent to run a command | the VM: an attacker can know the limits of the sandbox (see [10. Limits of the sandbox](#10-limits-of-the-sandbox)) |

The sandbox does not protect the code of the project. The agent writes code, and
a bad change is a bad commit. Keep the work on branches, set a `verify` command in
`.maf/config.json`, and merge to `main` only after a review or a CI run.

If the team runs without your attention, or the agents read untrusted text, use the VM.

## 2. Choose a level of isolation

| Level | Command | What the agent can change | Cost |
|---|---|---|---|
| None | the default | each file of your user | none |
| Sandbox | `.maf/sandbox.json` | the project, the board, and the state paths of the harnesses | none: the agents run on the host |
| VM | `maf vm create` | only the VM and the project folder | about 10 minutes to create, 4 GiB of memory and up to 20 GiB of disk by default |
| VM and sandbox | both | as the sandbox, but inside the VM | as the VM |

Use the sandbox for daily work. It costs nothing and stops most accidents.

Use the VM if the agents must not read your files. The sandbox does not stop
reads (see [10. Limits of the sandbox](#10-limits-of-the-sandbox)). The VM sees only the project folder.

Use both if you want a second wall inside the VM.

## 3. Quick start

### macOS

The sandbox uses `sandbox-exec`. It is part of macOS. You install nothing.

```sh
cd ~/Projects/my-app
echo '{ "mode": "auto" }' > .maf/sandbox.json
maf start claude reviewer --dispatch
```

The first lines of the dispatcher log show the sandbox:

```
dispatcher: sandbox: seatbelt, writes to /Users/me/Projects/my-app, ...
```

### Linux

The sandbox uses bubblewrap 0.10 or later. Ubuntu 26.04 has 0.11. Ubuntu 24.04 has 0.9, which is too old.

```sh
sudo apt install bubblewrap
bwrap --version                  # must be 0.10 or later
cd ~/Projects/my-app
echo '{ "mode": "auto" }' > .maf/sandbox.json
maf start claude reviewer --dispatch
```

The log shows `sandbox: bwrap, writes to ...`.

### VM

```sh
brew install lima                # macOS. On Linux, see section 11.
cd ~/Projects/my-app
maf add claude:architect codex:backend-developer
maf vm create
maf vm shell
```

See [11. Run the team in a VM](#11-run-the-team-in-a-vm).

## 4. Configure the sandbox

### The policy file

The policy is in `.maf/sandbox.json`:

```json
{
  "mode": "auto",
  "write": ["~/.npm", "~/.gem", "~/.bundle"]
}
```

| Key | Value | Default |
|---|---|---|
| `mode` | `off`, `auto`, `seatbelt`, or `bwrap` | `off` |
| `write` | more folders or files that the agent can change. `~` is your home folder. | `[]` |

| Mode | Meaning |
|---|---|
| `off` | no sandbox |
| `auto` | `seatbelt` on macOS, `bwrap` on Linux. Use it if the team works on both. |
| `seatbelt` | the macOS sandbox. maf stops on Linux. |
| `bwrap` | the Linux sandbox. maf stops on macOS. |

Rules for the policy file:

- Change the file on the host, in your own terminal. An agent in the sandbox cannot change it.
- If the file is missing, the first sandboxed run creates it as `{}`. Then an agent cannot create its own policy.
- If the file is not a valid JSON object, maf stops with an error. A typo does not turn the sandbox off.
- A relative path in `write` starts at the project root.
- `maf uninstall` removes the file.

### Turn the sandbox on for one session

`MAF_SANDBOX` overrides the `mode` of the file. The `write` list of the file stays.

```sh
MAF_SANDBOX=auto maf start codex backend-developer --dispatch
MAF_SANDBOX=off  maf start claude architect
```

### Check the sandbox

- A dispatcher writes `sandbox: <mode>, writes to <paths>` in its first log lines.
- An interactive `maf start` writes `maf: sandbox: <mode>, writes to <paths>` before the harness starts.
- If the log shows `sandbox: off`, or `maf start` writes no sandbox line, the sandbox is off.

## 5. What the agent can do in the sandbox

### Read

The agent can read each file that your user can read. See [10. Limits of the sandbox](#10-limits-of-the-sandbox).

### Write

The agent can create, change, and remove files only in these paths:

| Path | Why |
|---|---|
| the project folder, with the worktrees, `.git/`, and `.maf/` | the work of the agent, its commits, and the board |
| the board folder (`COORD_DIR`), if you moved it out of the project | messages, tasks, and locks |
| `/tmp`, `/var/tmp`, and the temporary folder of your user | temporary files of tools |
| the state paths of each harness of the project, for example `~/.claude/projects` and `~/.codex/sessions` | sessions, logs, and logins of the harness. Each other path in the folder of a harness is protected. See [7. Notes for each harness](#7-notes-for-each-harness). |
| the paths in the `write` list | your additions |

Tools of the host load code from `~/.cache` and `~/Library/Caches`, so the agent cannot write there.
On macOS, maf sets `XDG_CACHE_HOME` to the private temporary folder of the project.
On Linux, a write to `~/.cache` succeeds, but the file is gone after the run.

Each other write fails. On macOS, the error is `Operation not permitted`.
On Linux, a write outside the home folder fails with `Read-only file system`.
A write in the home folder succeeds, but the file is gone after the run (see [9. Linux details](#9-linux-details)).

### Protected files

maf or git runs some files of the project outside the sandbox. If an agent
could change them, the change would run on your machine without a sandbox.
So the agent can read these files, but it cannot change them:

| Path | Who runs or reads it outside the sandbox |
|---|---|
| `.maf/sandbox.json` | maf, before each run |
| `.maf/bin/` | the dispatcher runs `coord` from here |
| `.maf/lib/` | each maf script |
| `.maf/env.sh` | your shell, when you run `source .maf/env.sh` |
| `.maf/claude/` and `.maf/mcp/` | the harness: `maf start` and the dispatcher give it these files with `--settings` and `--mcp-config` |
| `.maf/coordination/message-hooks/` | `coord msg`, also in a process outside the sandbox |
| `.maf/coordination/taskrc` | Taskwarrior, when the dispatcher or you run `coord` |
| `.maf/coordination/worktree-env.rb` | `coord worktree` |
| `.maf/coordination/taskdata/hooks/` | Taskwarrior runs each hook script in it, also when you run `task` or `coord` on the host |
| `.git/hooks/` | git, when you commit on the host |
| `.git/config` | git: `core.hooksPath`, `core.fsmonitor`, and aliases can run commands |
| `.git/commondir` | git: the file points git at another git folder, with its own config (macOS only) |
| `.maf/worktrees/*/.git`, `.git/worktrees/*/commondir`, `.git/worktrees/*/gitdir` | git: these files point git at the git folder of a worktree |
| `.git/config.worktree`, `.git/worktrees/*/config.worktree` | git, when `extensions.worktreeConfig` is on |
| `config` and `hooks/` of each submodule in `.git/modules/` | git, when it works in the submodule on the host |
| each path in the folder of a harness that is not a state path, for example `~/.claude/settings.json`, `~/.claude/RTK.md`, `~/.codex/config.toml`, and `~/.hermes/tools` | the harness, in a later session outside the sandbox |
| the config of each harness in the project: `.mcp.json`, `.claude/settings.json`, `.claude/settings.local.json`, `.claude/hooks`, `.claude/commands`, `.claude/skills`, `.claude/agents`, `.codex/config.toml`, `.codex/hooks.json`, `.codex/hooks`, `.agents/skills`, `.cursor/mcp.json`, `.cursor/hooks.json`, `opencode.json`, `.opencode/`, and more | a session of a harness on the host, in the project |
| `.maf/bin/`, `.maf/lib/`, `.maf/env.sh`, `.maf/coordination/harness-hooks/`, and the config of each harness in each worktree | your shell and a session of a harness on the host, in the worktree |
| each file that a protected file of a harness names, if the file is in an allowed path. Examples: a hook script in `settings.json` (also a relative path such as `scripts/hook.sh`, and `$CLAUDE_PROJECT_DIR/scripts/hook.sh`). maf reads the config of a worktree with the paths of that worktree, a status line script, and an import (`@RTK.md`) in `CLAUDE.md`. In a Markdown file, maf follows only the imports. | the harness, in a later session outside the sandbox |

A harness folder is an allowlist: maf knows the state paths of each harness, and
each other path is protected. On macOS, a new name in an update of a harness is protected too.
On Linux, a new name stays writable, except the config names of the harness (see below).
If a harness then fails to write a new state path, add the path to the `write` list.

In the sandbox, Claude Code cannot save a permission in `.claude/settings.local.json`. Allow it on the host.

The agent also cannot rename or remove `.maf/`, `.git/`, the board folder, or a folder of a harness.
Else it could move a protected file away and put its own file in its place.

If a protected path is a symlink, the agent cannot change the link or its target.
On Linux, bwrap protects only the target: the agent can replace the link. So maf records
each protected link before a run. After the run, maf puts back each changed link and shows a warning.

The agent also cannot rename or remove a worktree that existed when its run started.
So remove such a worktree on the host: `coord gc --yes` or `maf retire`.

On Linux, bwrap can protect only a path that exists. So bwrap binds each existing path
in the folder of a harness that is not state read-only. maf creates the missing
protected folders (also `.maf/coordination/taskdata/hooks/`) and an empty `worktree-env.rb` before each run. maf also creates
each missing config path of a harness (see [7. Notes for each harness](#7-notes-for-each-harness)):
a folder, `{}` for a JSON file, or an empty file. An empty Markdown or YAML file changes
what the harness loads, so maf does not create it. maf also does not create `~/.codex/packages`,
`~/.cursor/cli-config.json`, and `~/.hermes/hermes-agent`: an empty one breaks the harness. bwrap cannot protect:

- a new name in the folder of a harness that is not in the config list of the harness
- a missing Markdown or YAML file of a harness, and the three paths above
- a missing config file of a harness in the project, for example `.mcp.json`
- a missing `.git/commondir`

On both platforms, the sandbox protects only the worktrees that exist when a run starts.
A lead adds worktrees during its run, so a new worktree stays writable until the next run.
Check `.maf/env.sh`, `.maf/bin/`, and the harness config of such a worktree before you use it on the host.

To change a protected file, change it on the host. `maf update` also works on the host.

### Sockets

A host service can run a command for the agent outside the sandbox.
Examples: tmux (`tmux send-keys`), Docker, `systemd-run --user`, D-Bus, and an SSH agent.
The service listens on a Unix socket, so the sandbox controls the sockets:

| Platform | The agent can connect to |
|---|---|
| macOS | the sockets in the project, in the board folder, and in the private temporary folder of the project, and the DNS resolver |
| Linux | each socket in a path that the sandbox does not hide. `/tmp` is private, `/run/user` and `/run/dbus` are empty, and the Docker, Podman, and containerd sockets are hidden. |

Thus these tools do not work in the sandbox:

- `docker` and `podman`
- `git push` over SSH with an SSH agent. Push on the host.
- the tmux server of the host

### Apps (macOS)

An app that macOS starts for the agent runs outside the sandbox. So on macOS the
sandbox also blocks LaunchServices and Apple Events. launchd already refuses a
job from the sandbox. Thus these tools do not work in the sandbox:

- `open`, also `open` of a URL. A harness cannot open the browser for a login,
  so log in to the harness on the host.
- `osascript` that sends an Apple Event to an app

## 6. Run agents in the sandbox

### Interactive sessions

```sh
maf start claude architect
```

maf starts the harness in the sandbox. The harness works as before: you see its screen, and you type.

The harness gets its own terminal. maf copies the input and the output between that
terminal and your terminal. A process can push text into its terminal as if you typed it.
Without its own terminal, an agent could push a command into the input of your shell.
Your shell would run the command outside the sandbox after the harness stops.

`maf stop` sends TERM to maf, and maf sends it to the harness. On Linux, the signal goes to bwrap.
If bwrap stops first, the kernel kills the harness, and the harness cannot stop cleanly.
A stop of a dispatcher has the same effect on its run: the run can end before the harness
writes its result, so the run counts as failed.

### Dispatched workers

```sh
maf start claude reviewer --dispatch
maf start codex backend-developer --dispatch --detach
```

The dispatcher runs on the host. Each agent run of the dispatcher starts in the sandbox.
The dispatcher reads the policy before each run.

Each run starts in a new session without a terminal, so the agent cannot push input into your terminal.
The verify command of `.maf/config.json` also runs in the sandbox, because the agent can change that file.
So the verify command cannot write `~/.cache`, `~/Library/Caches`, or `~/.npm` either. If a tool of the
command needs its cache (for example `~/Library/Caches/go-build`), add the folder to the `write` list.
The dispatcher runs `coord` of the main checkout, not the copy in the worktree.

The analyst of the dashboard (the "analyze" button) runs the command of `team.analyst.command`
in `.maf/config.json`. That command also runs in the sandbox, in a new session without a terminal. The sandbox opens the state paths of the
harness of the command, for example `~/.claude` for `claude`.

### Workers that a lead starts

The project manager can start workers with `maf prepare ... --dispatch`.
Such a worker starts inside the sandbox of the lead:

| Platform | What happens |
|---|---|
| macOS | macOS cannot start a sandbox inside a sandbox. `sandbox-exec` fails with `sandbox_apply: Operation not permitted`. `maf prepare --dispatch` sees the sandbox of the lead (`MAF_SEATBELT=1`): it prepares the worker and prints `cd <worktree>` and `maf start`. The user runs them in a terminal. A dispatcher that starts in the sandbox stops at once and writes the reason to its log. |
| Linux | bubblewrap cannot start inside bubblewrap. maf sees that it already runs in the sandbox, so the worker keeps the sandbox of the lead. |

Because of this, each sandbox opens the folders of each harness of the project,
not only the folders of its own harness. A codex worker that a claude lead
starts can then write to `~/.codex`.

### The team budget

Only the user sets the budget. `maf team set` refuses when an agent runs it (`COORD_ROLE` is set).
Without a budget, `maf prepare` refuses when an agent runs it. So the project manager cannot add
workers on its own. The budget is in `.maf/config.json`, which is not protected: an agent that edits
the file directly can still change the budget. The refusal stops a mistake, not an attack. The policy is in `.maf/sandbox.json`, so the project manager cannot change the sandbox.
The verify command and the analyst command in `.maf/config.json` run in the sandbox, so a change to them
cannot run a command on the host.

### Host operations (steward)

Some repairs need the host: a restart of a worker, a merge that deletes protected files, a new
`maf update`. An agent cannot run them in the sandbox. `steward` runs a fixed list of them for the agents.

- `maf start` starts `steward` outside the sandbox, one daemon per project. `steward` refuses to start
  in the sandbox.
- An agent runs `coord op request OPERATION [ARGUMENT]`. coord writes the request to
  `.maf/coordination/ops/requests/`.
- `steward` runs only these operations:

  | Operation | Argument | Command |
  |---|---|---|
  | `worker-restart` | worker | `maf worker restart WORKER` |
  | `worker-retire` | worker | `maf retire WORKER` |
  | `worktree-sync` | worker | `coord worktree ROLE ID` (fast-forward of the worker branch) |
  | `goal-sync` | goal short id | `coord goal sync ID` |
  | `runtime-restore` | none | `maf update` |

- `steward` checks each argument against the project, not against the request. A worker must be in
  `workers.json`, with its folder in `.maf/worktrees/`. A goal id must be 8 hex characters with a
  branch `goal/ID`. The command is an argument list without a shell.
- `steward` runs an operation at most 3 times per hour for one argument. Then it refuses and sends an
  escalation to the project manager.
- `steward` sends the result to the inbox of the role that asked. Each request, result, and refusal is
  an `op` line in `events.log`. The request files stay in `.maf/coordination/ops/done/`.
- No operation runs new code, changes a protected file, pushes, or changes the team budget.

## 7. Notes for each harness

| Harness | Folders of the harness | Notes |
|---|---|---|
| claude | `~/.claude` (or `CLAUDE_CONFIG_DIR`) and `~/.claude.json` | Turn off the sandbox of Claude Code itself for the project. A second sandbox can fail. |
| codex | `~/.codex` (or `CODEX_HOME`) | An interactive session starts with `--sandbox danger-full-access`. The maf sandbox replaces the Codex sandbox. The Codex sandbox blocks the network, but the maf sandbox does not. Codex saves the trust of the project hooks in `config.toml`, which is protected. So trust the hooks once in a session on the host, in the project root. A worktree uses the hooks and the trust of the main checkout. |
| opencode | `~/.local/share/opencode`, `~/.local/state/opencode`, `~/.config/opencode` | |
| cursor | `~/.cursor` and `~/.config/cursor` | |
| hermes | `~/.hermes` | |

In these folders, the agent can write only the state paths. A `*` matches a part of a name:

| Harness | State paths |
|---|---|
| claude | `projects`, `sessions`, `session-env`, `shell-snapshots`, `file-history`, `todos`, `tasks`, `plans`, `paste-cache`, `statsig`, `telemetry`, `ide`, `debug`, `logs`, `cache`, `backups`, `jobs`, `downloads`, `feedback`, `state`, `daemon`, `daemon.log*`, `daemon-auth-*`, `history.jsonl*`, `stats-cache.json*`, `*-cache.json*`, `.last-*`, `.credentials*`, `.claude.json*`. Also the MCP logs in `~/Library/Caches/claude-cli-nodejs` and `~/.cache/claude-cli-nodejs`. |
| codex | `sessions`, `archived_sessions`, `memories`, `log`, `logs*`, `*.sqlite*`, `history.jsonl*`, `session_index.jsonl*`, `auth.json*`, `models_cache.json*`, `version.json*`, `installation_id*`, `.sqlite-maintenance.lock`, `tmp`, `.tmp`, `shell_snapshots`, `attachments`, `thread-writer-locks`, `tui-*` |
| opencode | in `~/.local/share/opencode`: `auth.json*`, `log`, `opencode.db*`, `repos`, `snapshot`, `tool-output`, `storage`, `project`. All of `~/.local/state/opencode`. Nothing in `~/.config/opencode`. |
| cursor | in `~/.cursor`: `agent-cli-state.json*`, `statsig-cache.json*`, `chats`, `projects`, `ai-tracking`. In `~/.config/cursor`: `auth.json*` and `*.lock` |
| hermes | `sessions`, `logs`, `cache`, `memories`, `state`, `*.db*`, `pastes`, `composer-pastes`, `image_cache`, `audio_cache`, `locks`, `pending`, `runtime`, `telemetry`, `terminal-sessions`, `processes.json*`, `spawn-ledger.json*`, `auth.json*`, `auth.lock`, `google_token.json*`, `models_dev_cache*`, `provider_models_cache.json*`, `context_length_cache.yaml*`, `.hermes_history*`, `.*lock*` |

A harness that writes another path fails with `Operation not permitted` or `Read-only file system`.
Add the path to the `write` list.

bwrap can protect only an existing path. So on Linux the sandbox also protects these config names, also when they are missing:

| Harness | Protected files and folders |
|---|---|
| claude | `settings.json`, `settings.local.json`, `CLAUDE.md`, `hooks`, `skills`, `agents`, `commands`, `plugins`, `output-styles`, `rules` |
| codex | `config.toml`, `hooks.json`, `hooks`, `rules`, `skills`, `plugins`, `prompts`, `packages`, `AGENTS.md`, `AGENTS.override.md` |
| opencode | in `~/.config/opencode`: `opencode.json`, `opencode.jsonc`, `config.json`, `package.json`, `node_modules`, `plugin(s)`, `agent(s)`, `command(s)`, `skills`, `AGENTS.md` |
| cursor | in `~/.cursor`: `cli-config.json`, `hooks.json`, `mcp.json`, `hooks`, `agents`, `skills`, `plugins`, `rules` |
| hermes | `config.yaml`, `.env`, `shell_init.sh`, `SOUL.md`, `hooks`, `agent-hooks`, `shell-hooks-allowlist.json`, `bin`, `scripts`, `cron`, `skills`, `plugins`, `hermes-agent` |

The sandbox also protects each file that these files name. See [Protected files](#protected-files).

So in the sandbox, a harness cannot change its settings, install a plugin, or update a plugin.
Claude Code cannot sync `plugins`. Codex cannot update its app server in `packages`, and it cannot
refresh `cache`, which holds the code of its remote plugins. Hermes cannot update its programs in `tools`.
Do these steps on the host.

## 8. macOS details

- The sandbox is a Seatbelt profile. maf builds it for each run and passes it to `sandbox-exec -p`.
- The profile allows all reads and denies each write outside the allowed paths.
  In the folder of a harness, a regex rule allows each state path.
  It then denies each write to a protected path, because a later rule wins.
- Each project gets one private temporary folder: `/private/tmp/maf-sandbox-<uid>-<hash>`.
  maf sets `TMPDIR` to it for each run. maf creates the folder with mode 700. If another user
  owns the folder or others can open it, maf stops.
- The agent can connect to the DNS resolver (`mDNSResponder`), so host names resolve.
- The profile denies LaunchServices (`com.apple.coreservices.*`, `com.apple.lsd.*`) and Apple Events.
- In a test, `launchctl submit` and `launchctl bootstrap` did not start a process outside the sandbox.

## 9. Linux details

- The sandbox is a bubblewrap command. maf builds it for each run.
- The whole file system is read-only. Each allowed path and each folder of a harness is bound read-write on top.
  Each protected path, and each existing path in the folder of a harness that is not state, is bound read-only on top of that.
- `/tmp` is a new, empty, private folder for each run. A file that the agent writes there
  is gone after the run. Use the project folder for files that must stay.
  A protected file in `/tmp` (for example a hook script that a harness config names) is bound read-only,
  but maf does not bind its folder: that bind would show the host sockets in `/tmp` again.
- `/dev/shm` is private too, so the agent cannot change the shared memory of host programs.
- maf does not take `bwrap` from a folder on `PATH` that the agent can write (the project, `/tmp`).
  On macOS, maf runs `/usr/bin/sandbox-exec`.
- The home folder gets a temporary overlay. A write to the home folder outside the allowed
  folders succeeds, but the file is gone after the run. Claude Code needs this: it starts
  each save of `~/.claude.json` with a temporary file in the home folder. maf binds
  `~/.claude.json` itself, so Claude Code writes the file in place and the change stays.
  If the file is missing, maf creates it as `{}` first.
- `/run/user` and `/run/dbus` are empty. `XDG_RUNTIME_DIR` exists, but it is empty.
  A tool that needs the session bus (for example a keyring) does not work.
  These folders stay empty also when `TMPDIR` or the `write` list names a folder in them or above them.
- The sandbox keeps the network of the host. Thus an abstract socket (for example the X11 display) stays reachable.
- The overlay needs bubblewrap 0.10 or later. With an older bubblewrap, maf stops:
  `maf: sandbox mode bwrap needs bubblewrap 0.10 or later.`

## 10. Limits of the sandbox

The sandbox stops writes. It does not stop:

- **Reads.** The agent can read `~/.ssh`, `~/.aws`, and the files of other projects.
- **Network access.** The agent can send what it reads to the internet.
- **The code that the agent writes.** If you run the tests of the project on the host, the
  code runs without a sandbox. Review the changes first.
- **Files that tools of the host load from the project.** Examples: `.envrc` (direnv),
  `.mise.toml` (mise), `.tool-versions`, `package.json` scripts, a `Makefile`, and git hooks in a
  `core.hooksPath` folder of the project (for example `.husky/`).
  An agent can put `MAF_SANDBOX=off` or a command into such a file. Review such files
  before your shell or your tools load them.
- **A git folder that the agent makes in the project.** If you run git in a folder
  of the project that has its own `.git`, git reads the config of that folder.
  On Linux, the agent can also add `.git/commondir`, or change the `.git` file of a
  worktree that it added. Check these files before you run git on such a folder.
- **State files of a harness.** The harness writes them in each run, so the sandbox
  cannot protect them. `~/.claude.json` holds the MCP servers of Claude Code, and an
  MCP server is a command. Hermes keeps its own code in `~/.hermes`. Check these
  files before you start the harness outside the sandbox.
- **The memory of a harness.** The agent writes it in each run, for example
  `~/.claude/projects/*/memory/` and `~/.codex/memories_1.sqlite`. A later session
  outside the sandbox loads it as instructions. Check the memory before such a session.
- **Temporary folders.** The agent can write `/tmp`, `/var/tmp`, and the temporary folder
  of your user. Do not run a program from these folders on the host.
- **On Linux: abstract sockets and other processes.** bwrap keeps the network of the
  host, because the agent needs the API of its model. So the agent can connect to an
  abstract Unix socket, for example of the X server. The agent also sees the processes
  of the host. If `kernel.yama.ptrace_scope` is 0, it can attach to a process of yours.
  Through `/proc/<pid>/root` of a process of yours, the agent can also reach the files of
  the host and write past the protected paths. So on Linux, the sandbox stops mistakes, not
  an agent that tries to break out. For a strict wall, use `maf vm`.
- **Scripts that a command or a skill runs.** In a Markdown file, maf follows only the
  imports. If a slash command or a skill runs a script of the project (for example
  `!./scripts/release.sh`), the agent can change the script. Review it before you run
  the command on the host. A file in a state path of a harness (for example a script in
  `~/.claude/cache`) also stays writable, even if a config names it.
- **On Linux: sockets in the home folder.** bwrap does not hide a socket in a folder of a
  harness, for example the app server of Codex in `~/.codex/app-server-daemon`. A server
  on such a socket can run a command for the agent outside the sandbox.
- **On Linux: a background process of the agent.** The agent can start a process that
  leaves its session. That process can stay after the run, and it keeps the write access of
  the sandbox. maf does not stop it, because a lead can start a worker that must stay
  (`maf start ... --dispatch --detach`). After a run, look for such processes with `ps`.
- **Presence records.** The agent can write the records of the board in `.maf/coordination/presence/`.
  A forged record can name the pid and the start time of another process of yours. `maf stop` and
  `maf retire` would then send TERM to that process.
- **A process of the host that you start from the project.** The sandbox applies only
  to the agent runs that maf starts.

If the agents must not read your files, or you need a strict sandbox on Linux, run the team in a VM.

## 11. Run the team in a VM

`maf vm` runs the whole team in a Linux VM with [Lima](https://lima-vm.io).
The VM sees only the project folder. It does not see your home folder, your keys, or your other projects.
If an agent breaks the VM, delete the VM and create it again.

### Requirements

| Host | Requirements | The VM uses |
|---|---|---|
| macOS on Apple silicon | Lima 2.2.0 or later: `brew install lima` | Apple Virtualization and virtiofs |
| Linux | KVM, QEMU, and Lima 2.2.0 or later: see https://lima-vm.io/docs/installation/ | QEMU and 9p |

The VM runs Ubuntu 26.04.

### Create the VM

Add the agents first. `maf vm create` installs the CLI of each harness in `.maf/config.json`.

```sh
cd ~/Projects/my-app
maf add claude:architect codex:backend-developer
maf vm create
```

`maf vm create`:

1. Makes the VM `maf-<project>-<hash>`. The hash comes from the project path, so
   two projects with the same folder name get two VMs.
2. Mounts the project folder at the same path as on the host. The worktrees hold
   absolute paths, so git works on both sides. Use the board only in the VM.
3. Installs Ruby, git, tmux, bubblewrap, Rust, Taskwarrior 3, maf, and the CLI of each harness.
   The VM gets the maf version of this computer.
   maf cannot install Hermes. Install Hermes in the VM yourself.
4. Asks for each harness: `Copy your <harness> login from this computer into the VM? [y/N]`.

The first create takes about 10 minutes: the VM builds Taskwarrior from source.

Flags of `maf vm create`:

| Flag | Default | Meaning |
|---|---|---|
| `--cpus N` | 4 | the CPUs of the VM |
| `--memory GIB` | 4 | the memory of the VM |
| `--disk GIB` | 20 | the disk of the VM |
| `--gem FILE` | `maf` from RubyGems, the version of this computer | install maf from a local gem file |
| `--copy-logins` | ask | copy each login without a question |
| `--no-copy-logins` | ask | copy no login |

Without a terminal, maf copies no login.

### Logins

| Harness | Login on the host | Login in the VM |
|---|---|---|
| claude | macOS: the Keychain item `Claude Code-credentials`. macOS can ask you to allow the access. Linux: `~/.claude/.credentials.json` | `~/.claude/.credentials.json` |
| codex | `~/.codex/auth.json` | `~/.codex/auth.json` |
| opencode | `~/.local/share/opencode/auth.json` | the same path |
| hermes | `~/.hermes/.env` (the API keys) | `~/.hermes/.env` |
| cursor | not documented, so maf cannot copy it | log in in the VM: `NO_OPEN_BROWSER=1 agent login`, or set `CURSOR_API_KEY` |

- maf writes each login in the VM with mode 600. Only the VM user can read it.
- A copied login is a second copy of your tokens. `maf vm delete` removes it.
- If a harness refreshes the login on one side, the other side can lose its login. Then log in again on that side.
- `maf vm login` asks again, for example after you add a harness.
- If you do not copy a login, run `maf vm shell`, start the harness once, and log in. The VM keeps the login.

### Work in the VM

```sh
maf vm shell                        # a shell in the VM, in the project folder
tmux new -s team                    # one tmux window for each agent
maf start claude architect          # in the first window
maf start codex backend-developer --dispatch   # in the second window
```

`maf vm shell` loads `.maf/env.sh`, so `coord` is on PATH.
`maf vm shell COMMAND` runs one command in the project folder:

```sh
maf vm shell coord status
maf vm shell maf team
```

Read and review the work on the host. Git on the host sees the same worktrees and branches.

### VM and sandbox together

The VM user can run `sudo` without a password, so an agent in the VM can change each file of the VM.
The VM has bubblewrap. Set `"mode": "auto"` in `.maf/sandbox.json`, and each agent in the VM
also runs in the sandbox. In the sandbox, `sudo` does not work, and the agent can write only
to the allowed paths. The login files of most harnesses stay writable, so the agent can still change them in the VM.

### Rules for the VM

- Run all agents, dispatchers, `coord`, and `maf` commands in the VM. Use `maf vm shell COMMAND`.
- Do not use the board on the host while the VM uses it. The host and the VM cannot lock the
  Taskwarrior database for each other. In a test, writes from both sides at the same time
  damaged the database: tasks were lost, and Taskwarrior reported `database disk image is malformed`.
- A process ID in the VM is not a process ID on the host, so `coord who`, `maf worker list`,
  `maf worker stop`, and `maf retire` on the host do not see the agents in the VM.
- On the host, use git to read and review the work.
- A local model on the host (Ollama) is not in the VM. In the VM, use the host address `host.lima.internal`.
- The macOS notification hook (`osascript`) does not work in the VM.

### Commands

| Command | What it does |
|---|---|
| `maf vm create [FLAGS]` | create and start the VM of the project |
| `maf vm login [--copy-logins]` | copy the harness logins into the VM |
| `maf vm shell [COMMAND]` | open a shell in the VM, or run one command, in the project folder |
| `maf vm start` | start the VM |
| `maf vm stop` | stop the VM |
| `maf vm status` | show the VM |
| `maf vm delete` | delete the VM, with its logins and installed tools. The project folder stays. |

Each command except `create` first checks that the VM mounts this project. If not, maf stops
and does not touch the VM.

### Recreate the VM

```sh
maf vm delete
maf vm create
```

The project, the board, and the worktrees are on the host, so they stay.

## 12. Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| A tool fails with `Operation not permitted` (macOS) | the tool writes outside the allowed paths | add the folder to the `write` list, for example `~/.npm` |
| A tool fails with `Read-only file system` (Linux) | the tool writes outside the allowed paths | add the folder to the `write` list |
| A file in the home folder is gone after the run (Linux) | the home folder has a temporary overlay | add the folder to the `write` list |
| A file in `/tmp` is gone after the run (Linux) | `/tmp` is private to each run | write the file to the project folder |
| `maf: sandbox mode bwrap needs bubblewrap 0.10 or later.` | bubblewrap is missing or too old | install bubblewrap 0.10 or later |
| `maf: sandbox mode seatbelt needs sandbox-exec (macOS only).` | `seatbelt` on Linux | use `auto` or `bwrap` |
| `maf: unknown sandbox mode 'X'` | a wrong `mode` or `MAF_SANDBOX` | use `off`, `auto`, `seatbelt`, or `bwrap` |
| The agent cannot change `.maf/sandbox.json`, `.git/hooks`, `.maf/bin`, or the settings of its harness | these files are protected | change them on the host |
| `open` or `osascript` fails in the sandbox (macOS) | the sandbox blocks LaunchServices and Apple Events | run the command on the host |
| `coord: cannot write .../.maf/env.sh` in the sandbox | `coord worktree` must change the protected `.maf/env.sh` of a worktree | run `coord worktree` on the host |
| `coord gc --yes` cannot remove a worktree in the sandbox | the worktree existed when the run started, so it is protected | run `coord gc --yes` on the host |
| `docker`, `git push` with an SSH agent, or tmux fails in the sandbox | the sandbox blocks the sockets of host services | run the command on the host |
| `maf: /tmp/maf-sandbox-... belongs to another user or is open to others. Remove it.` | another user created the folder, or its mode is not 700 | remove the folder |
| `maf: no VM for this project. Run: maf vm create` | the project has no VM | run `maf vm create` |
| `maf: the VM ... does not mount ...` | the VM belongs to another project | run the command in the correct project |
| `database disk image is malformed`, or tasks are lost | the host and the VM used the board at the same time | stop all agents, restore `.maf/coordination/taskdata` from a backup, and use the board only in the VM |
| A harness in the VM is not logged in | the login was not copied, or it expired | run `maf vm login`, or log in with `maf vm shell` |

## 13. Reference

### Files

| File | Who writes it | Meaning |
|---|---|---|
| `.maf/sandbox.json` | you, on the host | the sandbox policy |
| `/private/tmp/maf-sandbox-<uid>-<hash>` (macOS) | maf | the private temporary folder of the project |
| `.maf/vm/` | `maf vm create --gem` | the local gem file for the VM |

### Environment variables

| Variable | Meaning |
|---|---|
| `MAF_SANDBOX` | overrides the `mode` of `.maf/sandbox.json` for one session |
| `COORD_DIR` | the board folder. The sandbox allows writes to it. |
| `CLAUDE_CONFIG_DIR`, `CODEX_HOME` | the harness folders that the sandbox allows |

### For harness authors

A harness file in `lib/maf/shared/harnesses/` tells the sandbox what the harness needs:

| Method | Meaning |
|---|---|
| `sandbox_dirs` | folders of the harness outside the project. The agent can write only the state paths in them. |
| `sandbox_state` | the state paths in those folders: sessions, logs, and logins. A `*` matches a part of a name. |
| `sandbox_prefixes` | files outside the project whose names start with a prefix, for example `~/.claude.json` |
| `sandbox_protected` | the config names in those folders. On Linux, maf creates each missing one, so bwrap can protect it. |
| `sandbox_project` | the config of the harness in the project, relative to the project folder |
| `sandboxed(cmd)` | changes the command for the sandbox, for example to turn off the sandbox of the harness |
| `vm_install` | the shell command that installs the CLI in the VM |
| `vm_credentials` | the login files that `maf vm` can copy |
| `vm_login_hint` | how to log in in the VM if maf cannot copy the login |
