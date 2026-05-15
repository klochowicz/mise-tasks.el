;;; mise-tasks.el --- Run mise tasks from Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Mariusz Klochowicz

;; Author: Mariusz Klochowicz <mariusz@klochowicz.com>
;; Maintainer: Mariusz Klochowicz <mariusz@klochowicz.com>
;; URL: https://github.com/klochowicz/mise-tasks
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, processes, mise

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Discover, run, and cancel `mise' tasks from inside Emacs.  Complements
;; the env-injection packages (`mise.el', `gmise', `emacs-misery') by
;; covering the task-runner side that none of them touch.
;;
;; Quick start:
;;
;;   M-x mise-tasks-run          ; pick a task, run it in `*mise: <project>*'
;;   M-x mise-tasks-run-last     ; re-run the last task for this project
;;   M-x mise-tasks-list         ; tabulated browser of tasks
;;   M-x mise-tasks-kill         ; SIGINT the running task (repeat for SIGKILL)
;;
;; The compilation buffer uses `compilation-mode', so the standard
;; \\[kill-compilation] (C-c C-k) and \\[recompile] (g) work as usual.
;;
;; Discovery runs `mise tasks --json' once at the project root.  When
;; the root config sets `experimental_monorepo_root = true', `--all' is
;; added and `MISE_EXPERIMENTAL=1' is set in the subprocess environment
;; so mise's monorepo task discovery engages even from GUI Emacs sessions
;; that don't inherit the user's shell environment.

;;; Code:

(require 'compile)
(require 'json)
(require 'seq)
(require 'subr-x)

;;;; Customisation

(defgroup mise-tasks nil
  "Run mise tasks from Emacs."
  :group 'tools
  :prefix "mise-tasks-")

(defcustom mise-tasks-executable "mise"
  "Path to the `mise' executable."
  :type 'string
  :group 'mise-tasks)

(defcustom mise-tasks-monorepo-mode 'auto
  "How to handle mise's experimental monorepo task discovery.

- `auto' (default): scan the root config for
  `experimental_monorepo_root = true' and engage monorepo behaviour
  when present.
- `always': always engage monorepo behaviour.
- `never': never engage monorepo behaviour."
  :type '(choice (const :tag "Auto-detect" auto)
                 (const :tag "Always" always)
                 (const :tag "Never" never))
  :group 'mise-tasks)

(defcustom mise-tasks-config-files
  '("mise.local.toml"
    "mise.toml"
    ".mise.toml"
    "mise/config.toml"
    ".mise/config.toml"
    ".config/mise.toml"
    ".config/mise/config.toml")
  "Filenames that mark the root of a mise-managed project.
Discovery walks up from `default-directory' until one of these exists."
  :type '(repeat string)
  :group 'mise-tasks)

(defcustom mise-tasks-experimental-env "1"
  "Value used for `MISE_EXPERIMENTAL' when calling mise.

Set to nil to leave the variable unset (and inherit whatever the user's
environment already has).  The default `\"1\"' ensures monorepo and
other experimental features actually engage in GUI Emacs sessions that
don't inherit the shell environment."
  :type '(choice (const :tag "Don't set" nil)
                 (string :tag "Value"))
  :group 'mise-tasks)

(defcustom mise-tasks-buffer-name-function #'mise-tasks--default-buffer-name
  "Function that returns the compilation buffer name for a project root.
Called with one argument: the project root directory."
  :type 'function
  :group 'mise-tasks)

;;;; State

(defvar mise-tasks--last-task-by-root (make-hash-table :test 'equal)
  "Map of project root (string) to most recently run task plist.")

;;;; Public commands

;;;###autoload
(defun mise-tasks-run (&optional task)
  "Run a mise task in the current project.

Interactively, prompt for the task with completion.  With a prefix
argument, also prompt for trailing arguments appended after `--'.

TASK, when supplied programmatically, may be either a task name (string)
or a task plist as returned by `mise-tasks--list-tasks'."
  (interactive)
  (let* ((root (mise-tasks--project-root))
         (tasks (mise-tasks--list-tasks root))
         (chosen (cond
                  ((null task) (mise-tasks--read-task tasks))
                  ((stringp task) (mise-tasks--resolve-task task tasks))
                  (t task)))
         (extra-args (and current-prefix-arg
                          (read-string
                           (format "Extra args for `%s': "
                                   (plist-get chosen :name)))))
         (command (mise-tasks--build-command
                   (plist-get chosen :name) extra-args)))
    (puthash root chosen mise-tasks--last-task-by-root)
    (mise-tasks--compile root command)))

;;;###autoload
(defun mise-tasks-run-last ()
  "Re-run the last mise task that was run in this project."
  (interactive)
  (let* ((root (mise-tasks--project-root))
         (last (gethash root mise-tasks--last-task-by-root)))
    (unless last
      (user-error "No previous mise task for %s" root))
    (mise-tasks--compile root
                         (mise-tasks--build-command
                          (plist-get last :name) nil))))

;;;###autoload
(defun mise-tasks-kill ()
  "Interrupt the running mise task for the current project.

First invocation sends SIGINT; a second invocation while the process is
still running sends SIGKILL."
  (interactive)
  (let* ((root (mise-tasks--project-root))
         (buf (get-buffer (funcall mise-tasks-buffer-name-function root)))
         (proc (and buf (get-buffer-process buf))))
    (unless (and proc (process-live-p proc))
      (user-error "No running mise task for %s" root))
    (if (process-get proc 'mise-tasks-interrupted)
        (progn (kill-process proc)
               (message "Sent SIGKILL to mise task"))
      (process-put proc 'mise-tasks-interrupted t)
      (interrupt-process proc)
      (message "Sent SIGINT to mise task (repeat to SIGKILL)"))))

;;;###autoload
(defun mise-tasks-list ()
  "Open a tabulated browser of mise tasks for the current project.

RET runs the task at point; `g' refreshes; `k' kills the running task."
  (interactive)
  (let* ((root (mise-tasks--project-root))
         (tasks (mise-tasks--list-tasks root))
         (buf (get-buffer-create (format "*mise tasks: %s*"
                                         (file-name-nondirectory
                                          (directory-file-name root))))))
    (with-current-buffer buf
      (mise-tasks-list-mode)
      (setq-local mise-tasks--list-root root)
      (setq-local mise-tasks--list-tasks tasks)
      (mise-tasks--list-refresh))
    (pop-to-buffer buf)))

;;;; Projectile integration

(defun mise-tasks--in-mise-project-p ()
  "Return non-nil when `default-directory' is inside a mise project.

Unlike `mise-tasks--project-root', this never raises — it just answers
yes or no.  Used by the projectile-compile-project advice to decide
whether to dispatch to `mise-tasks-run' or fall through to the original
compile flow."
  (and (mise-tasks--walk-up default-directory) t))

(defun mise-tasks--projectile-compile-advice (orig &rest args)
  "Around-advice: dispatch to `mise-tasks-run' in mise projects, else ORIG.

ORIG is the advised `projectile-compile-project'; ARGS its arguments.
This is the routing function used by `mise-tasks-projectile-mode'."
  (if (mise-tasks--in-mise-project-p)
      (call-interactively #'mise-tasks-run)
    (apply orig args)))

;;;###autoload
(define-minor-mode mise-tasks-projectile-mode
  "Toggle delegating `projectile-compile-project' to `mise-tasks-run'.

In projects that contain a mise config file, the standard
`projectile-compile-project' command (often bound to \\[projectile-compile-project]
or `SPC p c' in Spacemacs) instead prompts for a mise task and runs
it.  Projects without a mise config retain the original behaviour, so
the binding stays useful everywhere."
  :global t
  :group 'mise-tasks
  (if mise-tasks-projectile-mode
      (advice-add 'projectile-compile-project :around
                  #'mise-tasks--projectile-compile-advice)
    (advice-remove 'projectile-compile-project
                   #'mise-tasks--projectile-compile-advice)))

;;;; Project root detection

(defun mise-tasks--project-root ()
  "Return the root directory of the enclosing mise project.

Prefers `projectile-project-root' when projectile is loaded and the
project root has a mise config; otherwise walks up from
`default-directory' looking for any file in `mise-tasks-config-files'."
  (let ((from default-directory))
    (or (and (fboundp 'projectile-project-root)
             (let ((p (ignore-errors (projectile-project-root))))
               (and p (mise-tasks--config-files-at p) p)))
        (mise-tasks--walk-up from)
        (user-error "Not inside a mise project (no mise.toml found above %s)"
                    from))))

(defun mise-tasks--walk-up (dir)
  "Walk up from DIR; return the first directory holding a mise config."
  (let ((current (expand-file-name dir)))
    (catch 'found
      (while current
        (when (mise-tasks--config-files-at current)
          (throw 'found (file-name-as-directory current)))
        (let ((parent (file-name-directory (directory-file-name current))))
          (if (or (null parent) (string= parent current))
              (throw 'found nil)
            (setq current parent)))))))

(defun mise-tasks--config-files-at (dir)
  "Return the list of mise config files present in DIR, or nil."
  (let ((dir (file-name-as-directory dir)))
    (seq-filter (lambda (name) (file-exists-p (expand-file-name name dir)))
                mise-tasks-config-files)))

;;;; Calling mise

(defun mise-tasks--call-mise (args cwd)
  "Run `mise ARGS' in CWD; return (EXIT . OUTPUT).

OUTPUT is the captured stdout as a string.  Sets `MISE_EXPERIMENTAL' in
the subprocess environment according to `mise-tasks-experimental-env'
so monorepo and other experimental features engage even when the user
runs Emacs from a GUI launcher that doesn't inherit shell env."
  (let* ((default-directory (or cwd default-directory))
         (process-environment
          (if mise-tasks-experimental-env
              (cons (concat "MISE_EXPERIMENTAL=" mise-tasks-experimental-env)
                    process-environment)
            process-environment)))
    (with-temp-buffer
      (let ((exit (apply #'call-process mise-tasks-executable nil
                         (list (current-buffer) nil) nil args)))
        (cons exit (buffer-string))))))

;;;; Task discovery

(defun mise-tasks--list-tasks (root)
  "Return the list of tasks visible from ROOT.

Calls `mise tasks --json' once at ROOT.  When the root config sets
`experimental_monorepo_root = true', `--all' is added so tasks defined
in sub-configs are included; mise then emits names like `//path:name'
that are used unchanged for both display and `mise run'.

Each task is a plist with keys:
- :name        Display and run name (e.g. `//:lint' or `//rust:test')
- :description Human-readable description (may be empty)
- :source      Absolute path of the defining config file (may be nil)
- :global      Non-nil when defined in the user's global mise config"
  (let* ((monorepo (mise-tasks--monorepo-p root))
         (args (append '("tasks" "--no-header" "--json")
                       (and monorepo '("--all")))))
    (or (mise-tasks--parse-json-output args root)
        (mise-tasks--parse-name-only root monorepo))))

(defun mise-tasks--parse-json-output (args cwd)
  "Run `mise ARGS' in CWD and parse JSON output into task plists.
Returns nil on parse failure so callers can fall back."
  (pcase-let ((`(,exit . ,output) (mise-tasks--call-mise args cwd)))
    (when (zerop exit)
      (condition-case _
          (mapcar #'mise-tasks--json-to-plist
                  (mise-tasks--read-json-array output))
        (error nil)))))

(defun mise-tasks--read-json-array (string)
  "Parse STRING as a JSON array using whichever parser is available."
  (if (fboundp 'json-parse-string)
      (json-parse-string string
                         :object-type 'alist
                         :array-type 'list
                         :null-object nil
                         :false-object nil)
    (let ((json-array-type 'list)
          (json-object-type 'alist)
          (json-key-type 'symbol))
      (json-read-from-string string))))

(defun mise-tasks--json-to-plist (alist)
  "Convert a single task ALIST from mise JSON output to a plist."
  (list :name (alist-get 'name alist)
        :description (or (alist-get 'description alist) "")
        :source (alist-get 'source alist)
        :global (eq t (alist-get 'global alist))))

(defun mise-tasks--parse-name-only (root monorepo)
  "Fallback: run `mise tasks --name-only' at ROOT and synthesise plists.
Passes `--all' when MONOREPO is non-nil."
  (let* ((args (append '("tasks" "--no-header" "--name-only")
                       (and monorepo '("--all")))))
    (pcase-let ((`(,_ . ,output) (mise-tasks--call-mise args root)))
      (mapcar (lambda (n)
                (list :name n :description "" :source nil :global nil))
              (split-string output "\n" t "[ \t]+")))))

;;;; Monorepo detection

(defun mise-tasks--monorepo-p (root)
  "Return non-nil when ROOT should be treated as a mise monorepo."
  (pcase mise-tasks-monorepo-mode
    ('always t)
    ('never nil)
    (_ (mise-tasks--config-opts-into-monorepo root))))

(defun mise-tasks--config-opts-into-monorepo (root)
  "Return non-nil when any mise config at ROOT enables monorepo mode."
  (seq-some
   (lambda (name)
     (let ((path (expand-file-name name root)))
       (and (file-readable-p path)
            (with-temp-buffer
              (insert-file-contents path)
              (and (re-search-forward
                    "^[ \t]*experimental_monorepo_root[ \t]*=[ \t]*true"
                    nil t)
                   t)))))
   (mise-tasks--config-files-at root)))

;;;; Running

(defun mise-tasks--build-command (run-name extra-args)
  "Build the shell command to run RUN-NAME with optional EXTRA-ARGS.

For `mise run', the task name comes first as a positional argument, and
`--' is the separator between the task name and arguments passed through
to the task itself.  Putting `--' before the task name causes mise to
treat everything that follows as arguments to a missing task and drop
into its interactive picker — which then renders garbled into a
`compilation-mode' buffer and looks like a hung second prompt.

RUN-NAME is shell-quoted because it's a single token that may contain
`:' or `/'.  EXTRA-ARGS, when non-empty, is appended verbatim after `--'
so the shell tokenises it the way the user typed it at the prompt
\(e.g. `--release -p foo' becomes two arguments to the task)."
  (let ((parts (list mise-tasks-executable "run"
                     (shell-quote-argument run-name))))
    (when (and extra-args (not (string-empty-p extra-args)))
      (setq parts (append parts (list "--" extra-args))))
    (mapconcat #'identity parts " ")))

(defun mise-tasks--compile (root command)
  "Run COMMAND inside ROOT.
Uses a single per-project buffer so a new run reuses the existing one."
  (let* ((default-directory root)
         (buffer-name (funcall mise-tasks-buffer-name-function root))
         (process-environment
          (if mise-tasks-experimental-env
              (cons (concat "MISE_EXPERIMENTAL=" mise-tasks-experimental-env)
                    process-environment)
            process-environment))
         (compilation-buffer-name-function
          (lambda (_mode) buffer-name)))
    (compile command)))

(defun mise-tasks--default-buffer-name (root)
  "Return the compilation buffer name for ROOT."
  (format "*mise: %s*"
          (file-name-nondirectory (directory-file-name root))))

;;;; Completion UI

(defun mise-tasks--resolve-task (name tasks)
  "Find the task plist in TASKS whose :name matches NAME.
Falls back to a minimal synthesised plist."
  (or (seq-find (lambda (task) (string= (plist-get task :name) name)) tasks)
      (list :name name :description "" :source nil :global nil)))

(defun mise-tasks--read-task (tasks)
  "Prompt the user to pick one of TASKS; return the chosen task plist.

Candidates are the task `:name' values, with description and `[global]'
scope marker exposed via the standard `annotation-function' metadata
that `vertico'/`marginalia'/`helm'/`ivy'/default completion all render
correctly.  When two or more tasks share a `:name' — typically a global
task colliding with a same-named project task — the colliding candidates
are suffixed with `[scope:source]' so both remain selectable.
Post-selection lookup is a hash get against the candidate string, which
survives any completion-framework quirks around whitespace
normalisation."
  (unless tasks
    (user-error "No mise tasks defined in this project"))
  (let ((counts (make-hash-table :test 'equal)))
    (dolist (task tasks)
      (let ((name (plist-get task :name)))
        (puthash name (1+ (gethash name counts 0)) counts)))
    (let* ((by-label (make-hash-table :test 'equal))
           (names (mapcar
                   (lambda (task)
                     (let* ((collides-p (> (gethash (plist-get task :name) counts) 1))
                            (label (mise-tasks--candidate-label task collides-p)))
                       (puthash label task by-label)
                       label))
                   tasks))
           (annotate (mise-tasks--make-annotation-function by-label))
           (table (mise-tasks--make-completion-table names annotate))
           (chosen (completing-read "mise task: " table nil t)))
      (or (gethash chosen by-label)
          (mise-tasks--resolve-task chosen tasks)))))

(defun mise-tasks--candidate-label (task collides-p)
  "Return the completion candidate string for TASK.
When COLLIDES-P is non-nil, another task in the list shares this task's
`:name', so the label is suffixed with scope and (when known) source
filename to keep both selectable."
  (let ((name (plist-get task :name)))
    (if (not collides-p)
        name
      (let ((scope (if (plist-get task :global) "global" "local"))
            (src (and (plist-get task :source)
                      (file-name-nondirectory (plist-get task :source)))))
        (if src
            (format "%s [%s:%s]" name scope src)
          (format "%s [%s]" name scope))))))

(defun mise-tasks--make-annotation-function (by-name)
  "Return an `annotation-function' that resolves names through BY-NAME."
  (lambda (name)
    (let* ((task (gethash name by-name))
           (desc (or (plist-get task :description) ""))
           (scope (if (and task (plist-get task :global)) " [global]" "")))
      (cond
       ((and (string-empty-p desc) (string-empty-p scope)) nil)
       (t (concat "  "
                  (propertize (concat scope (and (not (string-empty-p scope))
                                                 (not (string-empty-p desc))
                                                 " ")
                                      desc)
                              'face 'completions-annotations)))))))

(defun mise-tasks--make-completion-table (names annotate)
  "Build a completion table over NAMES with ANNOTATE as the annotation fn."
  (lambda (string pred action)
    (if (eq action 'metadata)
        `(metadata
          (annotation-function . ,annotate)
          (category . mise-task)
          (display-sort-function . identity)
          (cycle-sort-function . identity))
      (complete-with-action action names string pred))))

;;;; List mode

(defvar-local mise-tasks--list-root nil
  "Project root the current `mise-tasks-list-mode' buffer is bound to.")
(defvar-local mise-tasks--list-tasks nil
  "Cached task plists for the current `mise-tasks-list-mode' buffer.")

(defvar mise-tasks-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'mise-tasks-list-run-at-point)
    (define-key map (kbd "g") #'mise-tasks-list-refresh)
    (define-key map (kbd "k") #'mise-tasks-list-kill)
    map)
  "Keymap for `mise-tasks-list-mode'.")

(define-derived-mode mise-tasks-list-mode tabulated-list-mode "mise-tasks"
  "Major mode for browsing mise tasks."
  (setq tabulated-list-format
        [("Scope" 8 t)
         ("Task" 40 t)
         ("Description" 50 t)
         ("Source" 0 t)])
  (setq tabulated-list-padding 1)
  (tabulated-list-init-header))

(defun mise-tasks--list-refresh ()
  "Repopulate the current `mise-tasks-list-mode' buffer."
  (setq tabulated-list-entries
        (mapcar (lambda (task)
                  (list (plist-get task :name)
                        (vector
                         (if (plist-get task :global) "global" "local")
                         (or (plist-get task :name) "")
                         (or (plist-get task :description) "")
                         (or (and (plist-get task :source)
                                  (file-name-nondirectory
                                   (plist-get task :source)))
                             ""))))
                mise-tasks--list-tasks))
  (tabulated-list-print t))

(defun mise-tasks-list-refresh ()
  "Re-query mise and refresh the task list."
  (interactive)
  (setq mise-tasks--list-tasks (mise-tasks--list-tasks mise-tasks--list-root))
  (mise-tasks--list-refresh))

(defun mise-tasks-list-run-at-point ()
  "Run the mise task on the current row."
  (interactive)
  (let ((id (tabulated-list-get-id)))
    (unless id (user-error "No task on this line"))
    (let* ((task (seq-find (lambda (entry)
                             (string= (plist-get entry :name) id))
                           mise-tasks--list-tasks))
           (default-directory mise-tasks--list-root))
      (mise-tasks-run (or task id)))))

(defun mise-tasks-list-kill ()
  "Kill the running task for this buffer's project."
  (interactive)
  (let ((default-directory mise-tasks--list-root))
    (mise-tasks-kill)))

(provide 'mise-tasks)

;;; mise-tasks.el ends here
