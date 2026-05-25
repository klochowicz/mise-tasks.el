# mise-tasks.el

Run [mise](https://mise.jdx.dev) tasks from Emacs. Discovers, executes, and cancels long-running tasks with a `compilation-mode` buffer per project. Plays nicely with Projectile and Spacemacs.

Complements the existing env-injection packages (`mise.el`, `gmise`, `emacs-misery`) — none of which run tasks. `mise-tasks` covers the task-runner side.

## Features

- **Task discovery** via `mise tasks --json`, including global tasks (`~/.config/mise/config.toml`), project tasks (`mise.toml`), and gitignored override tasks (`mise.local.toml`).
- **Monorepo support** — auto-detects `experimental_monorepo_root = true` and engages mise's experimental monorepo discovery (including setting `MISE_EXPERIMENTAL=1` in the subprocess env, which GUI Emacs sessions on macOS otherwise miss).
- **Trust prompt** — when a project's config is not trusted yet (e.g. a repo opened for the first time), discovery asks `y`/`n` and, on confirmation, runs `mise trust` before retrying instead of silently showing no tasks.
- **Process management** — runs through `compile`, so `C-c C-k` / `M-x kill-compilation` works; `mise-tasks-kill` adds a SIGINT-then-SIGKILL escalation.
- **Last-task memory** — `mise-tasks-run-last` re-runs the last task you picked in this project.

## Install

Not yet on MELPA. For now, clone and add to `load-path`:

```elisp
(add-to-list 'load-path "~/path/to/mise-tasks")
(require 'mise-tasks)
```

### Spacemacs

You can add `mise-tasks` into `dotspacemacs-additional-packages` section:

```elisp
  (mise-tasks :location (recipe :fetcher github :repo "klochowicz/mise-tasks.el")
```

and, inside your user-config, configure desired keybindings (example below):

```elisp
(defun dotspacemacs/user-config ()
  (require 'mise-tasks)
  (spacemacs/declare-prefix "pm" "mise")
  (spacemacs/set-leader-keys
    "pmm" '("run task"      . mise-tasks-run)
    "pmr" '("re-run last"   . mise-tasks-run-last)
    "pml" '("list tasks"    . mise-tasks-list)
    "pmk" '("kill running"  . mise-tasks-kill))
  ;; Optional: route SPC p c to mise-tasks-run in mise projects.
  ;; Non-mise projects keep the default projectile-compile-project.
  (mise-tasks-projectile-mode 1))
```

### Routing `projectile-compile-project` through mise

`mise-tasks-projectile-mode` is a global minor mode that advises `projectile-compile-project`. With it on:

- **Inside a mise project** (any of `mise.toml`, `.mise.toml`, `mise.local.toml`, `mise/config.toml`, `.mise/config.toml`, `.config/mise.toml`, `.config/mise/config.toml` found by walking up from `default-directory`): the call is dispatched to `mise-tasks-run`, so picking a task uses your existing `SPC p c` muscle memory.
- **Outside a mise project**: the original `projectile-compile-project` runs unchanged, so the binding stays useful everywhere.

Opt in once with `(mise-tasks-projectile-mode 1)`; disable with `(mise-tasks-projectile-mode -1)`.

## Commands

| Command | Purpose |
|---------|---------|
| `mise-tasks-run` | Pick a task and run it. `C-u` prefix prompts for extra args appended after `--`. |
| `mise-tasks-run-last` | Re-run the last task in this project. |
| `mise-tasks-list` | Tabulated browser of tasks. `RET` runs, `g` refreshes, `k` kills. |
| `mise-tasks-kill` | SIGINT the running task; repeat to SIGKILL. |

## Customisation

```elisp
;; Override monorepo detection
(setq mise-tasks-monorepo-mode 'auto)                  ; 'always | 'never

;; Disable experimental env-var injection
(setq mise-tasks-experimental-env nil)
```

## Discovery

Calls `mise tasks --json --no-header` once at the project root. When `experimental_monorepo_root = true` is found in the root config, also passes `--all` and sets `MISE_EXPERIMENTAL=1` in the subprocess env so mise's monorepo task discovery engages even in GUI Emacs sessions that don't inherit your shell environment.

If mise reports that the config is not trusted, discovery prompts `y`/`n` and, on confirmation, runs `mise trust` for the named config file, then retries. Because trusting the nearest config can reveal the next untrusted one further up the tree, the prompt repeats until everything needed is trusted (one prompt per file). Declining raises a clear error rather than reporting an empty task list.

## Why this package exists

Three Emacs packages already integrate with mise (`mise.el`, `gmise`, `emacs-misery`), and all three only inject env vars. None of them run tasks. This package fills that gap — and stays out of the env-handling business so it composes cleanly with whichever env package you already use.

## Development

Development tasks are defined in [`mise.toml`](./mise.toml) and run through [mise](https://mise.jdx.dev) — yes, the same tool this package integrates with.

```bash
mise tasks            # list everything
mise run              # default: check + test
mise run check        # byte-compile + checkdoc
mise run test         # run ERT tests
mise run lint         # package-lint (auto-installs from MELPA)
mise run clean        # remove .elc files
```

CI on GitHub Actions runs against Emacs 28.1, 29.4, and 30.1 snapshot.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
