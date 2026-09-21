;;; rescroll-test.el --- Tests for rescroll -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'rescroll)

(defmacro rescroll-test--window (&rest body)
  "Run BODY with a disposable displayed buffer."
  (declare (indent 0) (debug t))
  `(save-window-excursion
     (with-temp-buffer
       (switch-to-buffer (current-buffer))
       (set-window-parameter nil 'rescroll--cache nil)
       ,@body)))

(ert-deftest rescroll-empty ()
  (rescroll-test--window
    (let* ((rescroll-width 10)
           (bar (rescroll-mode-line)))
      (should (= 10 (length bar)))
      (dotimes (i 10)
        (should (eq 'rescroll-thumb (get-text-property i 'face bar)))))))

(ert-deftest rescroll-geometry-and-cache ()
  (rescroll-test--window
    (insert (make-string 1000 ?x))
    (set-window-start nil 1)
    (let ((rescroll-width 10))
      (cl-letf (((symbol-function 'window-end) (lambda (&rest _) 101)))
        (let ((bar (rescroll-mode-line)))
          (should (eq (get-text-property 0 'face bar) 'rescroll-thumb))
          (should (eq (get-text-property 1 'face bar) 'rescroll-track))
          (should (eq bar (rescroll-mode-line)))
          ;; Same-width edit must not invalidate a geometry cache.
          (goto-char 500)
          (delete-char 1)
          (insert "z")
          (should (eq bar (rescroll-mode-line)))))
      (set-window-start nil 901)
      (cl-letf (((symbol-function 'window-end) (lambda (&rest _) 1001)))
        (let ((bar (rescroll-mode-line)))
          (should (eq (get-text-property 9 'face bar) 'rescroll-thumb))
          (should (eq (get-text-property 8 'face bar) 'rescroll-track)))))))

(ert-deftest rescroll-no-text-scan-or-forced-window-end ()
  (rescroll-test--window
    (insert (make-string 1000000 ?x))
    (cl-letf (((symbol-function 'count-lines) (lambda (&rest _) (ert-fail "scan")))
              ((symbol-function 'line-number-at-pos) (lambda (&rest _) (ert-fail "scan")))
              ((symbol-function 'buffer-substring) (lambda (&rest _) (ert-fail "copy")))
              ((symbol-function 'window-end)
               (lambda (&optional _win update)
                 (should-not update)
                 nil)))
      (should (stringp (rescroll-mode-line))))))

(ert-deftest rescroll-narrowing-and-seek ()
  (rescroll-test--window
    (insert (make-string 1000 ?x))
    (narrow-to-region 101 501)
    (rescroll--seek (selected-window) 0.5)
    (should (= (window-point) 301))
    (should (= (window-start) 301))
    (rescroll--seek (selected-window) -1)
    (should (= (window-start) 101))
    (rescroll--seek (selected-window) 2)
    (should (= (window-point) 501))
    (widen)
    (rescroll--seek (selected-window) 1)
    (should (= (window-point) 1001))))

(ert-deftest rescroll-window-isolation ()
  (rescroll-test--window
    (insert (make-string 1000 ?x))
    (let* ((first (selected-window))
           (second (split-window-below))
           (point-before (window-point first)))
      (set-window-start first 1)
      (rescroll--seek second 0.75)
      (should (eq first (selected-window)))
      (should (= point-before (window-point first)))
      (should (= 751 (window-point second)))
      (cl-letf (((symbol-function 'window-end)
                 (lambda (win &rest _) (+ 100 (window-start win)))))
        (should-not (equal (rescroll-mode-line first)
                           (rescroll-mode-line second)))))))

(ert-deftest rescroll-width-and-stale-end ()
  (rescroll-test--window
    (insert "abc")
    (dolist (rescroll-width '(0 3 24 512 900))
      (cl-letf (((symbol-function 'window-end) (lambda (&rest _) 9000)))
        (let ((bar (rescroll-mode-line)))
          (should (= (length bar) (max 3 (min 512 rescroll-width)))))))))

(ert-deftest rescroll-render-properties ()
  (dolist (graphical '(nil t))
    (let ((bar (rescroll--render 10 3 2 graphical)))
      (should (equal (substring-no-properties bar)
                     (if graphical "          " "---==-----")))
      (dotimes (i 10)
        (should (get-text-property i 'rescroll-bar bar))
        (should (= 10 (get-text-property i 'rescroll-width bar)))
        (should (eq rescroll--map (get-text-property i 'local-map bar)))))))

(ert-deftest rescroll-mode-restores-and-is-idempotent ()
  (let ((original (default-value 'mode-line-end-spaces)))
    (unwind-protect
        (progn
          (rescroll-mode 1)
          (rescroll-mode 1)
          (should (eq original rescroll--saved-end-spaces))
          (rescroll-mode -1)
          (should (eq original (default-value 'mode-line-end-spaces)))
          (rescroll-mode -1)
          (should (eq original (default-value 'mode-line-end-spaces))))
      (rescroll-mode -1)
      (set-default 'mode-line-end-spaces original))))

(ert-deftest rescroll-mode-preserves-external-and-local-formats ()
  (let ((original (default-value 'mode-line-end-spaces)))
    (unwind-protect
        (with-temp-buffer
          (setq-local mode-line-end-spaces "local")
          (rescroll-mode 1)
          (should (equal mode-line-end-spaces "local"))
          (set-default 'mode-line-end-spaces "external")
          (rescroll-mode -1)
          (should (equal (default-value 'mode-line-end-spaces) "external"))
          (should (equal mode-line-end-spaces "local")))
      (rescroll-mode -1)
      (set-default 'mode-line-end-spaces original))))

(ert-deftest rescroll-mouse-preserves-unrelated-input ()
  (rescroll-test--window
    (insert (make-string 100 ?x))
    (let ((unread-command-events nil)
          (window (selected-window)))
      (cl-letf (((symbol-function 'read-event) (lambda (&rest _) ?a)))
        (rescroll-mouse
         (list 'down-mouse-1
               (list window 'mode-line '(0 . 0) 0
                     (cons (rescroll--render 24 0 1 nil) 0))))
        (should (equal unread-command-events '(97)))))))

(ert-deftest rescroll-coordinate-survives-concatenation ()
  (rescroll-test--window
    (let ((bar (rescroll--render 10 0 1 nil)))
      (let ((text (concat "prefix" bar)))
        (should (equal (rescroll--coordinate
                        (list (selected-window) 'mode-line '(0 . 0) 0
                              (cons text 9)))
                       (list (selected-window) 3 10)))
        (should (equal (rescroll--coordinate
                        (list (selected-window) 'mode-line '(0 . 0) 0
                              (cons text 6)))
                       (list (selected-window) 0 10))))
      ;; Two distinct bars keep separate marker runs.
      (let ((text (concat bar (rescroll--render 10 0 1 nil))))
        (should (equal (rescroll--coordinate
                        (list (selected-window) 'mode-line '(0 . 0) 0
                              (cons text 15)))
                       (list (selected-window) 5 10))))
      ;; Two adjacent copies of the same cached string merge into one run;
      ;; the cell clamps to the bar's rightmost cell instead of corrupting
      ;; the seek.
      (let ((text (concat bar bar)))
        (should (equal (rescroll--coordinate
                        (list (selected-window) 'mode-line '(0 . 0) 0
                              (cons text 15)))
                       (list (selected-window) 9 10)))))))

(ert-deftest rescroll-undo-and-revert-shape ()
  (rescroll-test--window
    (buffer-enable-undo)
    (insert (make-string 1000 ?x))
    (setq buffer-undo-list nil)
    (let ((bar (rescroll-mode-line)))
      (undo-boundary)
      (insert "abc")
      (undo-boundary)
      (undo 1)
      (should (equal bar (rescroll-mode-line)))
      (erase-buffer)
      (should (eq 'rescroll-thumb
                  (get-text-property 0 'face (rescroll-mode-line)))))))

(ert-deftest rescroll-drag-release ()
  (rescroll-test--window
    (insert (make-string 1000 ?x))
    (let* ((window (selected-window))
           (bar (rescroll--render 10 0 1 nil))
           (start (list window 'mode-line '(0 . 0) 0 (cons bar 0)))
           (end (list window 'mode-line '(9 . 0) 1 (cons bar 9)))
           (events (list (list 'mouse-movement end)
                         (list 'drag-mouse-1 start end)))
           (unread-command-events nil))
      (cl-letf (((symbol-function 'read-event)
                 (lambda (&rest _) (or (pop events) (ert-fail "read past release")))))
        (rescroll-mouse (list 'down-mouse-1 start))
        (should (= (window-point) (point-max)))
        (should-not events)
        (should-not unread-command-events)))))

(ert-deftest rescroll-indirect-buffer ()
  (rescroll-test--window
    (insert (make-string 1000 ?x))
    (let ((indirect (clone-indirect-buffer " *rescroll indirect*" nil)))
      (unwind-protect
          (progn
            (switch-to-buffer indirect)
            (narrow-to-region 201 401)
            (rescroll--seek (selected-window) 0.5)
            (should (= (window-point) 301))
            (should (stringp (rescroll-mode-line))))
        (kill-buffer indirect)))))

;;; rescroll-test.el ends here
