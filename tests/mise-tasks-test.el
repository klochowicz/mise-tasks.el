;;; mise-tasks-test.el --- Tests for mise-tasks  -*- lexical-binding: t; -*-

;; Tests run without invoking the real mise binary — each test stubs
;; out `mise-tasks--call-mise' with a deterministic fixture so they
;; pass on CI without mise being installed.

;;; Code:

(require 'ert)
(require 'mise-tasks)

;;;; Helpers

(defmacro mise-tasks-test--with-temp-project (tree &rest body)
  "Run BODY inside a temp project whose layout is described by TREE.

TREE is a list of (REL-PATH . CONTENT) pairs.  Each REL-PATH is created
relative to the temp root with CONTENT written to it.  Inside BODY,
`project-root' is bound to the absolute root directory."
  (declare (indent 1))
  `(let* ((project-root (make-temp-file "mise-tasks-test-" t)))
     (unwind-protect
         (progn
           (dolist (entry ,tree)
             (let* ((rel (car entry))
                    (content (cdr entry))
                    (full (expand-file-name rel project-root)))
               (make-directory (file-name-directory full) t)
               (with-temp-file full (insert content))))
           ,@body)
       (delete-directory project-root t))))

(defun mise-tasks-test--stub-call-mise (responses)
  "Return a function suitable as advice for `mise-tasks--call-mise'.

RESPONSES is an alist of (CWD-MATCH . (EXIT . OUTPUT)) entries.
CWD-MATCH is a substring matched against the call's CWD."
  (lambda (_args cwd)
    (or (cdr (seq-find (lambda (entry)
                         (string-match-p (regexp-quote (car entry)) cwd))
                       responses))
        (cons 1 ""))))

;;;; Config detection

(ert-deftest mise-tasks-test-config-files-at-finds-mise-toml ()
  (mise-tasks-test--with-temp-project '(("mise.toml" . "[tasks.x]\nrun = \"x\""))
    (should (equal (mise-tasks--config-files-at project-root)
                   '("mise.toml")))))

(ert-deftest mise-tasks-test-config-files-at-returns-nil-when-empty ()
  (mise-tasks-test--with-temp-project nil
    (should (null (mise-tasks--config-files-at project-root)))))

(ert-deftest mise-tasks-test-walk-up-finds-root-from-subdir ()
  (mise-tasks-test--with-temp-project
      '(("mise.toml" . "[tasks.x]\nrun = \"x\"")
        ("sub/.keep" . ""))
    (let* ((sub (expand-file-name "sub" project-root))
           (found (mise-tasks--walk-up sub)))
      (should (file-equal-p found project-root)))))

;;;; Monorepo detection

(ert-deftest mise-tasks-test-monorepo-detection-positive ()
  (mise-tasks-test--with-temp-project
      '(("mise.toml" . "experimental_monorepo_root = true\n[monorepo]\nconfig_roots = []\n"))
    (let ((mise-tasks-monorepo-mode 'auto))
      (should (mise-tasks--monorepo-p project-root)))))

(ert-deftest mise-tasks-test-monorepo-detection-negative ()
  (mise-tasks-test--with-temp-project
      '(("mise.toml" . "[tasks.x]\nrun = \"x\"\n"))
    (let ((mise-tasks-monorepo-mode 'auto))
      (should-not (mise-tasks--monorepo-p project-root)))))

(ert-deftest mise-tasks-test-monorepo-detection-respects-false ()
  (mise-tasks-test--with-temp-project
      '(("mise.toml" . "experimental_monorepo_root = false\n"))
    (let ((mise-tasks-monorepo-mode 'auto))
      (should-not (mise-tasks--monorepo-p project-root)))))

(ert-deftest mise-tasks-test-monorepo-override-always ()
  (mise-tasks-test--with-temp-project '(("mise.toml" . ""))
    (let ((mise-tasks-monorepo-mode 'always))
      (should (mise-tasks--monorepo-p project-root)))))

(ert-deftest mise-tasks-test-monorepo-override-never ()
  (mise-tasks-test--with-temp-project
      '(("mise.toml" . "experimental_monorepo_root = true\n"))
    (let ((mise-tasks-monorepo-mode 'never))
      (should-not (mise-tasks--monorepo-p project-root)))))

;;;; Command building

(ert-deftest mise-tasks-test-build-command-no-args ()
  ;; Regression: `--' must NOT appear before the task name.  mise treats
  ;; `mise run -- TASK' as "run a missing task with TASK as an argument",
  ;; which drops into mise's interactive picker.
  (let ((mise-tasks-executable "mise"))
    (should (equal (mise-tasks--build-command "lint" nil)
                   "mise run lint"))
    (should-not (string-match-p " -- " (mise-tasks--build-command "lint" nil)))))

(ert-deftest mise-tasks-test-build-command-with-extra-args ()
  ;; `--' is the separator BETWEEN the task name and arguments passed
  ;; through to the task, so it must appear only when extra args exist.
  (let ((mise-tasks-executable "mise"))
    (should (equal (mise-tasks--build-command "test" "--release")
                   "mise run test -- --release"))))

(ert-deftest mise-tasks-test-build-command-quotes-special-chars ()
  (let ((mise-tasks-executable "mise"))
    (should (string-match-p "mise run //rust:test\\|mise run //rust\\\\:test"
                            (mise-tasks--build-command "//rust:test" nil)))))

(ert-deftest mise-tasks-test-build-command-empty-extra-args ()
  ;; Empty string for extra-args must still produce a clean command.
  (let ((mise-tasks-executable "mise"))
    (should (equal (mise-tasks--build-command "lint" "")
                   "mise run lint"))))

;;;; JSON parsing

(ert-deftest mise-tasks-test-json-to-plist-basic ()
  (let* ((alist '((name . "lint")
                  (description . "Run linters")
                  (source . "/p/mise.toml")
                  (global . :json-false)))
         (plist (mise-tasks--json-to-plist alist)))
    (should (equal (plist-get plist :name) "lint"))
    (should (equal (plist-get plist :description) "Run linters"))
    (should-not (plist-get plist :global))))

(ert-deftest mise-tasks-test-json-to-plist-global-task ()
  (let* ((alist '((name . "deploy") (description . "") (source . "/g/c.toml")
                  (global . t)))
         (plist (mise-tasks--json-to-plist alist)))
    (should (plist-get plist :global))))

(ert-deftest mise-tasks-test-json-to-plist-monorepo-name-preserved ()
  ;; Monorepo names (e.g. //rust:test) come through unchanged — display
  ;; and run name are the same, and mise itself resolves cwd from the
  ;; name when running.
  (let* ((alist '((name . "//rust:test") (description . "T")
                  (source . "/p/rust/mise.toml") (global . :json-false)))
         (plist (mise-tasks--json-to-plist alist)))
    (should (equal (plist-get plist :name) "//rust:test"))))

;;;; Annotation function

(ert-deftest mise-tasks-test-annotation-fn-returns-nil-when-empty ()
  (let* ((by-name (make-hash-table :test 'equal))
         (task '(:name "lint" :description "" :global nil)))
    (puthash "lint" task by-name)
    (let ((annotate (mise-tasks--make-annotation-function by-name)))
      (should-not (funcall annotate "lint")))))

(ert-deftest mise-tasks-test-annotation-fn-shows-description ()
  (let* ((by-name (make-hash-table :test 'equal))
         (task '(:name "lint" :description "Run linters" :global nil)))
    (puthash "lint" task by-name)
    (let* ((annotate (mise-tasks--make-annotation-function by-name))
           (result (funcall annotate "lint")))
      (should result)
      (should (string-match-p "Run linters" result)))))

(ert-deftest mise-tasks-test-annotation-fn-marks-global ()
  (let* ((by-name (make-hash-table :test 'equal))
         (task '(:name "deploy" :description "Ship it" :global t)))
    (puthash "deploy" task by-name)
    (let* ((annotate (mise-tasks--make-annotation-function by-name))
           (result (funcall annotate "deploy")))
      (should (string-match-p "\\[global\\]" result))
      (should (string-match-p "Ship it" result)))))

(ert-deftest mise-tasks-test-annotation-fn-handles-missing-task ()
  ;; When the completion framework hands back a candidate that was never
  ;; registered (shouldn't happen with REQUIRE-MATCH=t but be defensive),
  ;; the annotation function must not crash.
  (let* ((by-name (make-hash-table :test 'equal))
         (annotate (mise-tasks--make-annotation-function by-name)))
    (should-not (funcall annotate "phantom"))))

;;;; Candidate labelling (collision disambiguation)

(ert-deftest mise-tasks-test-candidate-label-no-collision ()
  (let ((task '(:name "lint" :global nil :source "/p/mise.toml")))
    (should (equal (mise-tasks--candidate-label task nil) "lint"))))

(ert-deftest mise-tasks-test-candidate-label-collision-with-source ()
  ;; A global `deploy' colliding with a project `deploy' must end up
  ;; with a distinguishing suffix that includes the source filename so
  ;; both remain selectable in completion.
  (let ((task '(:name "deploy" :global t :source "/g/config.toml")))
    (should (equal (mise-tasks--candidate-label task t)
                   "deploy [global:config.toml]"))))

(ert-deftest mise-tasks-test-candidate-label-collision-without-source ()
  ;; The name-only fallback path produces tasks with :source = nil;
  ;; disambiguation must still produce a unique label.
  (let ((task '(:name "deploy" :global nil :source nil)))
    (should (equal (mise-tasks--candidate-label task t)
                   "deploy [local]"))))

;;;; Completion table metadata

(ert-deftest mise-tasks-test-completion-table-exposes-metadata ()
  (let* ((annotate (lambda (_) "  hint"))
         (table (mise-tasks--make-completion-table '("a" "b") annotate))
         (meta (funcall table "" nil 'metadata)))
    (should (eq (car meta) 'metadata))
    (should (eq (cdr (assq 'annotation-function (cdr meta))) annotate))
    (should (eq (cdr (assq 'category (cdr meta))) 'mise-task))))

;;;; Resolve task

(ert-deftest mise-tasks-test-resolve-task-finds-match ()
  (let* ((tasks '((:name "a") (:name "b")))
         (resolved (mise-tasks--resolve-task "b" tasks)))
    (should (equal (plist-get resolved :name) "b"))))

(ert-deftest mise-tasks-test-resolve-task-falls-back ()
  (let* ((tasks '((:name "a")))
         (resolved (mise-tasks--resolve-task "missing" tasks)))
    (should (equal (plist-get resolved :name) "missing"))
    (should-not (plist-get resolved :global))))

;;;; Projectile integration

(ert-deftest mise-tasks-test-in-mise-project-p-positive ()
  (mise-tasks-test--with-temp-project
      '(("mise.toml" . "[tasks.x]\nrun = \"x\""))
    (let ((default-directory project-root))
      (should (mise-tasks--in-mise-project-p)))))

(ert-deftest mise-tasks-test-in-mise-project-p-negative ()
  (let ((scratch (make-temp-file "mise-tasks-no-config-" t)))
    (unwind-protect
        (let ((default-directory scratch))
          (should-not (mise-tasks--in-mise-project-p)))
      (delete-directory scratch t))))

(ert-deftest mise-tasks-test-projectile-mode-installs-advice ()
  ;; Stub projectile-compile-project so we don't need projectile loaded.
  (let ((stub (lambda () 'original)))
    (defalias 'projectile-compile-project stub)
    (unwind-protect
        (progn
          (mise-tasks-projectile-mode 1)
          (should (advice-member-p
                   #'mise-tasks--projectile-compile-advice
                   'projectile-compile-project))
          (mise-tasks-projectile-mode -1)
          (should-not (advice-member-p
                       #'mise-tasks--projectile-compile-advice
                       'projectile-compile-project)))
      (fmakunbound 'projectile-compile-project))))

(ert-deftest mise-tasks-test-projectile-advice-falls-back-outside-mise ()
  ;; Stub projectile-compile-project; stub the advice's in-mise check
  ;; to return nil; ensure the original (stub) runs unchanged.
  (let ((called nil))
    (defalias 'projectile-compile-project
      (lambda () (interactive) (setq called 'original)))
    (unwind-protect
        (cl-letf (((symbol-function 'mise-tasks--in-mise-project-p)
                   (lambda () nil)))
          (mise-tasks-projectile-mode 1)
          (call-interactively 'projectile-compile-project)
          (should (eq called 'original))
          (mise-tasks-projectile-mode -1))
      (fmakunbound 'projectile-compile-project))))

(ert-deftest mise-tasks-test-projectile-advice-routes-to-mise-in-project ()
  (let ((called nil))
    (defalias 'projectile-compile-project
      (lambda () (interactive) (setq called 'original)))
    (unwind-protect
        (cl-letf (((symbol-function 'mise-tasks--in-mise-project-p)
                   (lambda () t))
                  ((symbol-function 'mise-tasks-run)
                   (lambda (&optional _) (interactive) (setq called 'mise))))
          (mise-tasks-projectile-mode 1)
          (call-interactively 'projectile-compile-project)
          (should (eq called 'mise))
          (mise-tasks-projectile-mode -1))
      (fmakunbound 'projectile-compile-project))))

;;;; Trust flow (untrusted-config detection)

(ert-deftest mise-tasks-test-untrusted-config-extracts-path ()
  ;; The trust error names the offending config on stderr; we must surface
  ;; that exact path so we can `mise trust' it.
  (let ((stderr (concat
                 "mise ERROR error parsing config file: /p/mise.toml\n"
                 "mise ERROR Config files in /p/mise.toml are not trusted.\n"
                 "Trust them with `mise trust'.\n")))
    (should (equal (mise-tasks--untrusted-config 1 stderr) "/p/mise.toml"))))

(ert-deftest mise-tasks-test-untrusted-config-nil-on-success ()
  ;; A zero exit is never an untrusted error, regardless of stderr text.
  (should-not (mise-tasks--untrusted-config
               0 "Config files in /p/mise.toml are not trusted.")))

(ert-deftest mise-tasks-test-untrusted-config-nil-on-other-error ()
  ;; A non-trust parse failure must not be mistaken for an untrusted config.
  (should-not (mise-tasks--untrusted-config 1 "mise ERROR invalid TOML at line 3")))

(ert-deftest mise-tasks-test-untrusted-config-nil-on-empty-stderr ()
  (should-not (mise-tasks--untrusted-config 1 ""))
  (should-not (mise-tasks--untrusted-config 1 nil)))

;;;; Trust flow (prompt + trust + retry loop)

(ert-deftest mise-tasks-test-trusting-passes-through-on-success ()
  ;; When mise succeeds, there is no prompt and no `mise trust' call —
  ;; just the result.
  (let ((prompted nil) (trusted nil))
    (cl-letf (((symbol-function 'mise-tasks--call-mise)
               (lambda (args _root)
                 (if (equal (car args) "trust")
                     (progn (setq trusted t) (list 0 "" ""))
                   (list 0 "[]" ""))))
              ((symbol-function 'y-or-n-p)
               (lambda (&rest _) (setq prompted t) t)))
      (should (equal (mise-tasks--call-mise-trusting '("tasks" "--json") "/r/")
                     (list 0 "[]" "")))
      (should-not prompted)
      (should-not trusted))))

(ert-deftest mise-tasks-test-trusting-trusts-and-retries-on-confirm ()
  ;; Untrusted -> confirm -> `mise trust <path>' -> retry succeeds.
  (let ((trusted-path nil)
        (responses (list
                    (list 1 "" "mise ERROR Config files in /r/mise.toml are not trusted.")
                    (list 0 "[]" ""))))
    (cl-letf (((symbol-function 'mise-tasks--call-mise)
               (lambda (args _root)
                 (if (equal (car args) "trust")
                     (progn (setq trusted-path (cadr args)) (list 0 "" ""))
                   (pop responses))))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (should (equal (mise-tasks--call-mise-trusting '("tasks" "--json") "/r/")
                     (list 0 "[]" "")))
      (should (equal trusted-path "/r/mise.toml")))))

(ert-deftest mise-tasks-test-trusting-signals-on-decline ()
  ;; Declining the prompt must raise a clear error, not silently return
  ;; "no tasks", and must not run `mise trust'.
  (let ((trusted nil))
    (cl-letf (((symbol-function 'mise-tasks--call-mise)
               (lambda (args _root)
                 (if (equal (car args) "trust")
                     (progn (setq trusted t) (list 0 "" ""))
                   (list 1 "" "mise ERROR Config files in /r/mise.toml are not trusted."))))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
      (should-error (mise-tasks--call-mise-trusting '("tasks" "--json") "/r/")
                    :type 'user-error)
      (should-not trusted))))

(ert-deftest mise-tasks-test-trusting-handles-nested-untrusted ()
  ;; Trusting the nearest config reveals the next one up the tree; the
  ;; loop must resolve both with one prompt each.
  (let ((trust-calls 0)
        (responses (list
                    (list 1 "" "mise ERROR Config files in /r/sub/mise.toml are not trusted.")
                    (list 1 "" "mise ERROR Config files in /r/mise.toml are not trusted.")
                    (list 0 "[]" ""))))
    (cl-letf (((symbol-function 'mise-tasks--call-mise)
               (lambda (args _root)
                 (if (equal (car args) "trust")
                     (progn (setq trust-calls (1+ trust-calls)) (list 0 "" ""))
                   (pop responses))))
              ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (should (equal (mise-tasks--call-mise-trusting '("tasks" "--json") "/r/")
                     (list 0 "[]" "")))
      (should (= trust-calls 2)))))

;;;; Lockfile major mode (font-lock)

(defconst mise-tasks-test--lock-fixture "\
# @generated - this file is auto-generated by `mise lock` https://mise.en.dev/dev-tools/mise-lock.html

[[tools.node]]
version = \"20.20.2\"
backend = \"core:node\"

[tools.node.\"platforms.linux-arm64\"]
checksum = \"sha256:47ef73d543ecf6eb19435f6c03a0ac4809b3bf0dd6b26c7c571efc2a6572a74d\"
url = \"https://nodejs.org/dist/v20.20.2/node-v20.20.2-linux-arm64.tar.gz\"

[[tools.prettier]]
version = \"3.6.2\"
backend = \"npm:prettier\"
"
  "A real `mise.lock' excerpt used as a font-lock fixture.")

(defun mise-tasks-test--face-present-p (needle face)
  "Return non-nil when FACE is active at the start of NEEDLE.
Fontifies `mise-tasks-test--lock-fixture' in `mise-tasks-lock-mode' and
inspects the `face' text property at the first match of NEEDLE."
  (with-temp-buffer
    (insert mise-tasks-test--lock-fixture)
    (mise-tasks-lock-mode)
    (font-lock-ensure)
    (goto-char (point-min))
    (unless (search-forward needle nil t)
      (error "Needle %S not found in fixture" needle))
    (let ((got (get-text-property (match-beginning 0) 'face)))
      (if (listp got) (memq face got) (eq got face)))))

(ert-deftest mise-tasks-test-lock-mode-is-defined ()
  (should (fboundp 'mise-tasks-lock-mode)))

(ert-deftest mise-tasks-test-lock-highlights-generated-marker ()
  ;; The `@generated' marker signals "do not hand-edit"; it must stand out
  ;; from the surrounding comment.
  (should (mise-tasks-test--face-present-p "@generated"
                                           'font-lock-warning-face)))

(ert-deftest mise-tasks-test-lock-highlights-tool-name ()
  ;; The tool name in `[[tools.NAME]]' is the thing a reader scans for.
  (should (mise-tasks-test--face-present-p "node]]"
                                           'font-lock-function-name-face)))

(ert-deftest mise-tasks-test-lock-highlights-platform ()
  (should (mise-tasks-test--face-present-p "linux-arm64"
                                           'font-lock-constant-face)))

(ert-deftest mise-tasks-test-lock-highlights-backend-kind ()
  ;; Only the backend kind (before the `:') is emphasised, not the whole value.
  (should (mise-tasks-test--face-present-p "core:node"
                                           'font-lock-builtin-face)))

(ert-deftest mise-tasks-test-lock-highlights-checksum-algo ()
  (should (mise-tasks-test--face-present-p "sha256:"
                                           'font-lock-builtin-face)))

(ert-deftest mise-tasks-test-lock-auto-mode-alist ()
  ;; Both the project lockfile and the gitignored local override map to the
  ;; lockfile mode.
  (should (eq (assoc-default "/some/project/mise.lock" auto-mode-alist
                             #'string-match-p)
              'mise-tasks-lock-mode))
  (should (eq (assoc-default "/some/project/mise.local.lock" auto-mode-alist
                             #'string-match-p)
              'mise-tasks-lock-mode)))

(ert-deftest mise-tasks-test-lock-auto-mode-alist-is-strict ()
  ;; The pattern must match every place mise writes a lockfile but never
  ;; hijack unrelated `.lock' files (Cargo.lock, flake.lock, ...).  mise always
  ;; names the file `mise.lock'/`mise.local.lock' regardless of the config
  ;; filename, including in subdirectories (e.g. `mise/config.toml' locks to
  ;; `mise/mise.lock').
  (let ((regexp (car (rassq 'mise-tasks-lock-mode auto-mode-alist))))
    (should regexp)
    (dolist (name '("mise.lock"
                    "/p/mise.lock"
                    "/p/mise.local.lock"
                    "/p/mise/mise.lock"
                    "/p/.config/mise/mise.lock"))
      (should (string-match-p regexp name)))
    (dolist (name '("/p/Cargo.lock"
                    "/p/flake.lock"
                    "/p/poetry.lock"
                    "/p/yarn.lock"
                    "/p/premise.lock"
                    "/p/.mise.lock"))
      (should-not (string-match-p regexp name)))))

(provide 'mise-tasks-test)

;;; mise-tasks-test.el ends here
