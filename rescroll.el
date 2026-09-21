;;; rescroll.el --- Constant-work mode-line scrollbar -*- lexical-binding: t; -*-

;; Author: SuzumiyaAoba
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience, frames
;; URL: https://github.com/SuzumiyaAoba/rescroll
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; An interactive mode-line scrollbar using character positions, not line
;; counts.  Rendering never scans buffer text, creates overlays, runs timers,
;; or forces redisplay.  Window-local caches reuse the rendered string until
;; its quantized geometry changes.  Enable globally with `rescroll-mode', or
;; place (:eval (rescroll-mode-line)) in your own mode-line format.
;;
;; Click/drag to seek; wheel to scroll.  Long lines and invisible text occupy
;; their character-proportional share of the bar.  This deliberate tradeoff
;; avoids a line index and all per-edit maintenance costs.

;;; Code:

(defgroup rescroll nil
  "Low-overhead mode-line scrollbar."
  :group 'convenience)

(defcustom rescroll-width 24
  "Width of the bar in character cells (between 3 and 512)."
  :type '(integer :tag "Cells")
  :group 'rescroll)

(defcustom rescroll-wheel-lines 3
  "Number of screen lines to scroll for each wheel event."
  :type 'natnum
  :group 'rescroll)

(defface rescroll-track
  '((t :inherit shadow :background "gray25"))
  "Face for the track."
  :group 'rescroll)

(defface rescroll-thumb
  '((t :inherit mode-line-emphasis :background "steelblue"))
  "Face for the visible portion of the buffer."
  :group 'rescroll)

(defvar rescroll--map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line down-mouse-1] #'rescroll-mouse)
    (define-key map [mode-line mouse-1] #'ignore)
    (define-key map [mode-line drag-mouse-1] #'ignore)
    (dolist (event '(wheel-up wheel-down mouse-4 mouse-5))
      (define-key map (vector 'mode-line event) #'rescroll-wheel))
    map)
  "Mouse bindings carried by scrollbar text.")

(defun rescroll--render (width left thumb graphical)
  "Build a WIDTH-cell bar with LEFT track cells and THUMB thumb cells.
GRAPHICAL selects spaces with colored backgrounds instead of ASCII."
  (let ((bar (make-string width (if graphical ?\s ?-))))
    (unless graphical
      (dotimes (i thumb) (aset bar (+ left i) ?=)))
    ;; A single marker run keeps the bar at O(1) intervals; the fresh cons
    ;; keeps bars rendered separately distinct when concatenated.  The cell
    ;; index is recovered at event time via `previous-single-property-change'.
    ;; Two directly adjacent copies of the same cached string still merge,
    ;; in which case the second bar's cells clamp to its rightmost cell.
    (add-text-properties
     0 width (list 'face 'rescroll-track 'mouse-face 'highlight
                   'local-map rescroll--map 'rescroll-width width
                   'rescroll-bar (cons nil nil)
                   'help-echo "Drag/click: seek; wheel: scroll") bar)
    (put-text-property left (+ left thumb) 'face 'rescroll-thumb bar)
    bar))

;;;###autoload
(defun rescroll-mode-line (&optional window)
  "Return the cached scrollbar string for WINDOW, or the selected window.
During mode-line evaluation Emacs selects the window being formatted.
Only character positions and cached redisplay bounds are inspected.  If the
window end is not yet known, display a minimal thumb until redisplay supplies
it; do not call `window-end' with UPDATE non-nil from a mode-line evaluator."
  (let ((win (or window (selected-window))))
    (when (window-live-p win)
      (with-current-buffer (window-buffer win)
        (let* ((width (max 3 (min 512 rescroll-width)))
               (lo (point-min))
               (hi (point-max))
               (span (- hi lo))
               (start (max lo (min hi (window-start win))))
               (end (max start (min hi (or (window-end win) start))))
               (visible (- end start))
               (thumb (if (zerop span) width
                        (max 1 (min width (/ (* width visible) span)))))
               (travel (- span visible))
               (left (if (<= travel 0) 0
                       (min (- width thumb)
                            (/ (* (- width thumb) (- start lo)) travel))))
               (cache (window-parameter win 'rescroll--cache)))
          ;; Do not allocate even a cache-key list on the steady-state path.
          ;; A buffer switch/edit with identical geometry reuses the same bar.
          ;; The display type is constant for a live window (windows never
          ;; migrate between frames), so it is not part of the cache key.
          (if (and cache
                   (= width (aref cache 0))
                   (= left (aref cache 1))
                   (= thumb (aref cache 2)))
              (aref cache 3)
            (let ((bar (rescroll--render
                        width left thumb
                        (display-graphic-p (window-frame win)))))
              (set-window-parameter
               win 'rescroll--cache (vector width left thumb bar))
              bar)))))))

(defun rescroll--seek (window fraction)
  "Move WINDOW to FRACTION of its accessible character range.
Do not select WINDOW or change another window's point.  Seeking is bounded
by character positions; do not scan to a logical line boundary."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (let* ((lo (point-min))
             (span (- (point-max) lo))
             (target (+ lo (round (* span (max 0.0 (min 1.0 fraction)))))))
        (set-window-point window target)
        (set-window-start window target t)))))

(defun rescroll--coordinate (position)
  "Return (WINDOW CELL WIDTH) for scrollbar POSITION, or nil."
  (let* ((window (posn-window position))
         (text (posn-string position))
         (string (car-safe text))
         (index (cdr-safe text)))
    (when (and (window-live-p window) (stringp string)
               (integerp index) (<= 0 index) (< index (length string)))
      (let ((width (get-text-property index 'rescroll-width string)))
        ;; The marker run also works when Emacs concatenated this string into
        ;; a larger mode-line string: its start is the bar's first cell.
        ;; Adjacent identical bars merge into one run; clamping keeps CELL
        ;; inside the bar instead of corrupting the seek.
        (when (and (integerp width) (> width 1)
                   (get-text-property index 'rescroll-bar string))
          (let ((start (or (previous-single-property-change
                            (1+ index) 'rescroll-bar string)
                           0)))
            (list window (min (1- width) (max 0 (- index start)))
                  width)))))))

(defun rescroll-mouse (event)
  "Seek and track a drag starting at mouse EVENT on the scrollbar.
Unrelated input is returned to the command loop, not swallowed."
  (interactive "e")
  (let* ((position (event-start event))
         (coordinate (rescroll--coordinate position)))
    (when coordinate
      (let* ((window (nth 0 coordinate))
             (cell (nth 1 coordinate))
             (width (nth 2 coordinate))
             (origin (car (posn-x-y position)))
             ;; posn-x-y uses pixels in GUI frames, character cells in TTYs.
             (unit (if (display-graphic-p (window-frame window))
                       (frame-char-width (window-frame window)) 1))
             (done nil))
        (rescroll--seek window (/ (float cell) (1- width)))
        (track-mouse
          (while (and (not done) (window-live-p window))
            (let ((next (read-event)))
              (cond
               ((or (mouse-movement-p next)
                    (and (consp next) (eq (event-basic-type next) 'mouse-1)))
                (let* ((end (event-end next))
                       (exact (rescroll--coordinate end)))
                  (when (eq window (posn-window end))
                    (rescroll--seek
                     window
                     (if (and exact (= width (nth 2 exact)))
                         (/ (float (nth 1 exact)) (1- width))
                       (/ (+ cell (/ (- (car (posn-x-y end)) origin)
                                     (float unit)))
                          (1- width))))))
                (unless (mouse-movement-p next) (setq done t)))
               (t
                (setq unread-command-events (cons next unread-command-events)
                      done t))))))))))

(defun rescroll-wheel (event)
  "Scroll the window under wheel EVENT without changing selected window."
  (interactive "e")
  (let ((window (posn-window (event-start event))))
    (when (window-live-p window)
      (with-selected-window window
        (condition-case nil
            (if (memq (event-basic-type event) '(wheel-up mouse-4))
                (scroll-down rescroll-wheel-lines)
              (scroll-up rescroll-wheel-lines))
          (beginning-of-buffer nil)
          (end-of-buffer nil))))))

(defvar rescroll--saved-end-spaces nil)
(put 'rescroll--saved-end-spaces 'risky-local-variable t)
(defconst rescroll--entry '(:eval (rescroll-mode-line)))
(put 'rescroll--entry 'risky-local-variable t)
;; A leading string makes this a sequence, not a mode-line conditional.
(defconst rescroll--format '("" rescroll--entry rescroll--saved-end-spaces))
(defvar rescroll--installed nil)

;;;###autoload
(define-minor-mode rescroll-mode
  "Display an interactive scrollbar in the default mode-line end spaces.
Buffer-local mode-line overrides are left untouched.  For custom mode lines,
insert (:eval (rescroll-mode-line)) yourself instead of enabling this mode.
The original end spaces are restored on disable unless another package has
replaced our format in the meantime."
  :global t
  :group 'rescroll
  (if rescroll-mode
      (unless rescroll--installed
        (setq rescroll--saved-end-spaces (default-value 'mode-line-end-spaces)
              rescroll--installed t)
        (set-default 'mode-line-end-spaces rescroll--format))
    (when rescroll--installed
      (when (eq (default-value 'mode-line-end-spaces) rescroll--format)
        (set-default 'mode-line-end-spaces rescroll--saved-end-spaces))
      (setq rescroll--installed nil)
      (dolist (frame (frame-list))
        (dolist (win (window-list frame 'no-minibuffer))
          (set-window-parameter win 'rescroll--cache nil)))))
  (force-mode-line-update t))

(provide 'rescroll)
;;; rescroll.el ends here
