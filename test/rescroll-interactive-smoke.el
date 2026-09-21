;;; rescroll-interactive-smoke.el --- Real redisplay smoke test -*- lexical-binding: t; -*-

;; Run in an isolated interactive Emacs:
;; emacs -Q -nw -L . -l test/rescroll-interactive-smoke.el
;; Exits automatically.  Also usable without -nw on a GUI-capable host.

(require 'rescroll)
(switch-to-buffer (get-buffer-create "rescroll-smoke"))
(dotimes (_ 1000) (insert "A line in the scrollbar smoke test.\n"))
(goto-char (point-min))
(rescroll-mode 1)

(run-at-time
 0.5 nil
 (lambda ()
   (condition-case err
       (progn
         (redisplay t)
         (let ((formatted (format-mode-line mode-line-format)))
           (unless (text-property-not-all 0 (length formatted) 'rescroll-bar nil formatted)
             (error "Scrollbar missing from formatted mode line")))
         (rescroll--seek (selected-window) 0.5)
         (redisplay t)
         (unless (> (window-start) 1) (error "Seek did not move window"))
         (rescroll-mode -1)
         (redisplay t)
         (kill-emacs 0))
     (error (message "RESCROLL SMOKE FAILED: %S" err) (kill-emacs 1)))))
;;; rescroll-interactive-smoke.el ends here
