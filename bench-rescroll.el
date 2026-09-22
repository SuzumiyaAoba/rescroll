;;; bench-rescroll.el --- Synthetic rescroll benchmarks -*- lexical-binding: t; -*-

;; Keep background compilation from changing the package mid-measurement.
(setq native-comp-jit-compilation nil)
(require 'benchmark)
(require 'rescroll)

(defun rescroll-benchmark--case (size long-line &optional width)
  "Measure a SIZE-character buffer; LONG-LINE omits newlines.
WIDTH overrides `rescroll-width' to expose width-dependent render costs."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (set-window-parameter nil 'rescroll--cache nil)
      (let ((rescroll-width (or width rescroll-width))
            (chunk (concat (make-string 99 ?x) (if long-line "x" "\n"))))
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
                 ;; Cycle five positions so every call is a real render:
                 ;; the four-entry window cache still misses.
                 (benchmark-run-compiled 10000
                   (set-window-start
                    nil (let ((p (/ (point-max) 6)))
                          (cond ((= (window-start) 1) p)
                                ((= (window-start) p) (* 2 p))
                                ((= (window-start) (* 2 p)) (* 3 p))
                                ((= (window-start) (* 3 p)) (* 4 p))
                                (t 1)))
                    t)
                   (rescroll-mode-line))))
            (princ (format "%9d %9s w=%-3d cached-100k=%S edit-10k=%S changed-10k=%S\n"
                           size (if long-line "long-line" "lines")
                           (or width 24) cached edited changed))))))))

(princ (format "Emacs %s; (elapsed seconds, GC count, GC seconds)\n" emacs-version))
(dolist (size '(50000 5000000 50000000))
  (rescroll-benchmark--case size nil))
(rescroll-benchmark--case 50000000 t)
;; Wide bars stress the cache-miss render path, not the cached path.
(rescroll-benchmark--case 5000000 nil 512)
;;; bench-rescroll.el ends here
