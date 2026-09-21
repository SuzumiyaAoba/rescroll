;;; bench-rescroll.el --- Synthetic rescroll benchmarks -*- lexical-binding: t; -*-

;; Keep background compilation from changing the package mid-measurement.
(setq native-comp-jit-compilation nil)
(require 'benchmark)
(require 'rescroll)

(defun rescroll-benchmark--case (size long-line)
  "Measure a SIZE-character buffer; LONG-LINE omits newlines."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (set-window-parameter nil 'rescroll--cache nil)
      (let ((chunk (concat (make-string 99 ?x) (if long-line "x" "\n"))))
        (dotimes (_ (/ size 100)) (insert chunk)))
      (goto-char (point-min))
      (set-window-start nil (point-min))
      ;; Batch does not perform GUI redisplay.  This intentionally exercises
      ;; the unknown/cached-end evaluator, not destination fontification.
      (rescroll-mode-line)
      (garbage-collect)
      (let ((cached (benchmark-run-compiled 100000 (rescroll-mode-line))))
        (garbage-collect)
        (let ((edited
               (benchmark-run-compiled 10000
                 (goto-char (point-min))
                 (insert "x")
                 (delete-char 1)
                 (rescroll-mode-line))))
          (garbage-collect)
          (let ((changed
                 (benchmark-run-compiled 10000
                   (set-window-start
                    nil (if (= (window-start) 1) (/ (point-max) 2) 1) t)
                   (rescroll-mode-line))))
            (princ (format "%9d %9s cached-100k=%S edit-10k=%S changed-10k=%S\n"
                           size (if long-line "long-line" "lines")
                           cached edited changed))))))))

(princ (format "Emacs %s; (elapsed seconds, GC count, GC seconds)\n" emacs-version))
(dolist (size '(50000 5000000 50000000))
  (rescroll-benchmark--case size nil))
(rescroll-benchmark--case 50000000 t)
;;; bench-rescroll.el ends here
