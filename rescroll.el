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
;; or forces redisplay.  A window-local cache reuses rendered strings for
;; the four most recent quantized geometries.  Enable
;; globally with `rescroll-mode', or place (:eval (rescroll-mode-line))
;; in your own mode-line format.
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

(defconst rescroll--props
  (list 'face 'rescroll-track 'mouse-face 'highlight
        'local-map rescroll--map
        'help-echo "Drag/click: seek; wheel: scroll")
  "Constant text properties shared by every rendered bar; never mutated.")

(defconst rescroll--props-thumb
  (list 'face 'rescroll-thumb 'mouse-face 'highlight
        'local-map rescroll--map
        'help-echo "Drag/click: seek; wheel: scroll")
  "Like `rescroll--props' but with the thumb face over the whole bar.")

(defun rescroll--render (width left thumb graphical)
  "Build a WIDTH-cell bar with LEFT track cells and THUMB thumb cells.
GRAPHICAL selects spaces with colored backgrounds instead of ASCII."
  ;; A single marker run keeps the bar at O(1) intervals; the fresh cons
  ;; carries the width and keeps bars rendered separately distinct when
  ;; concatenated.  The cell index is recovered at event time via
  ;; `previous-single-property-change'.  Two directly adjacent copies of
  ;; the same cached string still merge, in which case the second bar's
  ;; cells clamp to its rightmost cell.
  (if (= thumb width)
      ;; A buffer that fits entirely in the window: one interval.
      (let ((bar (make-string width (if graphical ?\s ?=))))
        (add-text-properties 0 width rescroll--props-thumb bar)
        (put-text-property 0 width 'rescroll-bar (cons width bar) bar)
        bar)
    (let ((bar (make-string width (if graphical ?\s ?-))))
      (unless graphical
        (dotimes (i thumb) (aset bar (+ left i) ?=)))
      (add-text-properties 0 width rescroll--props bar)
      (put-text-property left (+ left thumb) 'face 'rescroll-thumb bar)
      (put-text-property 0 width 'rescroll-bar (cons width bar) bar)
      bar)))

;; Two-entry memo for the per-window cache; covers one- and two-window
;; frames without touching `window-parameter' on the steady-state path.
(defvar rescroll--memo-win nil)
(defvar rescroll--memo-cache nil)
(defvar rescroll--memo-win2 nil)
(defvar rescroll--memo-cache2 nil)

(defsubst rescroll--evaluate (win)
  "Return the scrollbar string for live window WIN.
WIN's buffer must be the current buffer."
  (let* ((width (if (<= 3 rescroll-width 512)
                    rescroll-width
                  (max 3 (min 512 rescroll-width))))
         (lo (point-min))
         (hi (point-max))
         (span (- hi lo))
         (start (max lo (min hi (window-start win))))
         (end (let ((e (window-end win)))
                (if e (max start (min hi e)) start)))
         (visible (- end start))
         (thumb (if (zerop span) width
                  (max 1 (min width (/ (* width visible) span)))))
         (travel (- span visible))
         (left (if (<= travel 0) 0
                 (min (- width thumb)
                      (/ (* (- width thumb) (- start lo)) travel))))
         ;; `window-parameter' costs more than its short `assq' suggests;
         ;; memoize the lookups.  The vector is self-validating, so a
         ;; stale entry can only return a geometry-correct bar.
         (cache (cond
                 ((eq win rescroll--memo-win) rescroll--memo-cache)
                 ((eq win rescroll--memo-win2) rescroll--memo-cache2)
                 (t
                  (let ((c (window-parameter win 'rescroll--cache)))
                    (setq rescroll--memo-win2 rescroll--memo-win
                          rescroll--memo-cache2 rescroll--memo-cache
                          rescroll--memo-win win
                          rescroll--memo-cache c)
                    c)))))
    ;; Do not allocate even a cache-key list on the steady-state path.
    ;; A buffer switch/edit with identical geometry reuses the same bar.
    ;; The display type is constant for a live window (windows never
    ;; migrate between frames), so it is not part of the cache key.
    ;; Slots 5-16 hold the three previous geometries' keys and bars, so
    ;; revisiting any of the last four (scroll reversal, undo, ...) skips
    ;; the render entirely.  Entries are FIFO: hits never reorder them,
    ;; which already keeps any resident oscillation rendering-free.
    (cond
     ((and cache
           (= left (aref cache 1))
           (= thumb (aref cache 2))
           (= width (aref cache 0)))
      (aref cache 3))
     ((and cache (> (length cache) 8) (aref cache 8)
           (= left (aref cache 6))
           (= thumb (aref cache 7))
           (= width (aref cache 5)))
      (aref cache 8))
     ((and cache (> (length cache) 12) (aref cache 12)
           (= left (aref cache 10))
           (= thumb (aref cache 11))
           (= width (aref cache 9)))
      (aref cache 12))
     ((and cache (> (length cache) 16) (aref cache 16)
           (= left (aref cache 14))
           (= thumb (aref cache 15))
           (= width (aref cache 13)))
      (aref cache 16))
     (t
      (let* ((graphical (if (and cache (> (length cache) 4))
                            (aref cache 4)
                          (display-graphic-p (window-frame win))))
             (bar (rescroll--render width left thumb graphical)))
        (if (and cache (> (length cache) 16))
            (progn
              ;; Shift entries down; the oldest geometry evicts.
              (aset cache 13 (aref cache 9))
              (aset cache 14 (aref cache 10))
              (aset cache 15 (aref cache 11))
              (aset cache 16 (aref cache 12))
              (aset cache 9 (aref cache 5))
              (aset cache 10 (aref cache 6))
              (aset cache 11 (aref cache 7))
              (aset cache 12 (aref cache 8))
              (aset cache 5 (aref cache 0))
              (aset cache 6 (aref cache 1))
              (aset cache 7 (aref cache 2))
              (aset cache 8 (aref cache 3))
              (aset cache 0 width)
              (aset cache 1 left)
              (aset cache 2 thumb)
              (aset cache 3 bar))
          ;; A short vector predates the four-entry layout; replace it.
          (let ((new (vector width left thumb bar graphical
                             -1 -1 -1 nil -1 -1 -1 nil -1 -1 -1 nil)))
            (set-window-parameter win 'rescroll--cache new)
            ;; On a second-slot hit `rescroll--memo-win' holds another
            ;; window; promote WIN to the first slot first.
            (unless (eq win rescroll--memo-win)
              (setq rescroll--memo-win2 rescroll--memo-win
                    rescroll--memo-cache2 rescroll--memo-cache
                    rescroll--memo-win win))
            (setq rescroll--memo-cache new)))
        bar)))))

;;;###autoload
(defun rescroll-mode-line (&optional window)
  "Return the cached scrollbar string for WINDOW, or the selected window.
During mode-line evaluation Emacs selects the window being formatted.
Only character positions and cached redisplay bounds are inspected.  If the
window end is not yet known, display a minimal thumb until redisplay supplies
it; do not call `window-end' with UPDATE non-nil from a mode-line evaluator."
  (let ((win (or window (selected-window))))
    ;; The selected window is always live; only check explicit arguments.
    (when (or (not window) (window-live-p win))
      ;; Mode-line evaluation already runs with the window's buffer current;
      ;; skip the buffer switch bookkeeping in that common case.
      (let ((buf (window-buffer win)))
        (if (eq buf (current-buffer))
            (rescroll--evaluate win)
          (with-current-buffer buf
            (rescroll--evaluate win)))))))

(defun rescroll--seek (window fraction)
  "Move WINDOW to FRACTION of its accessible character range.
Do not select WINDOW or change another window's point.  Seeking is bounded
by character positions; do not scan to a logical line boundary."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (let* ((lo (point-min))
             (span (- (point-max) lo))
             (target (+ lo (round (* span (max 0.0 (min 1.0 fraction)))))))
        ;; Both setters flag the window for redisplay even when the values
        ;; are unchanged, so skip them when WINDOW already sits at TARGET.
        ;; Both must match: redisplay can legitimately move start away
        ;; from an unreachable target, which a point-only check would
        ;; leave uncorrected.
        (unless (and (= (window-point window) target)
                     (= (window-start window) target))
          (set-window-point window target)
          (set-window-start window target t))))))

(defun rescroll--coordinate (position)
  "Return (WINDOW CELL WIDTH) for scrollbar POSITION, or nil."
  (let* ((window (posn-window position))
         (text (posn-string position))
         (string (car-safe text))
         (index (cdr-safe text)))
    (when (and (window-live-p window) (stringp string)
               (integerp index) (<= 0 index) (< index (length string)))
      (let ((marker (get-text-property index 'rescroll-bar string)))
        ;; The marker run also works when Emacs concatenated this string into
        ;; a larger mode-line string: its start is the bar's first cell.
        ;; Adjacent identical bars merge into one run; clamping keeps CELL
        ;; inside the bar instead of corrupting the seek.
        (when (and (consp marker) (integerp (car marker)) (> (car marker) 1))
          (let* ((width (car marker))
                 (start (or (previous-single-property-change
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
             (last (/ (float cell) (1- width)))
             (done nil))
        (rescroll--seek window last)
        (track-mouse
          (while (and (not done) (window-live-p window))
            (let ((next (read-event)))
              (cond
               ((or (mouse-movement-p next)
                    (and (consp next) (eq (event-basic-type next) 'mouse-1)))
                (let* ((end (event-end next))
                       (exact (rescroll--coordinate end)))
                  (when (eq window (posn-window end))
                    (let ((fraction
                           (if (and exact (= width (nth 2 exact)))
                               (/ (float (nth 1 exact)) (1- width))
                             (/ (+ cell (/ (- (car (posn-x-y end)) origin)
                                           (float unit)))
                                (1- width)))))
                      ;; Mouse events often repeat the same cell; do not
                      ;; re-seek (and re-display) for an unchanged fraction.
                      (unless (= fraction last)
                        (setq last fraction)
                        (rescroll--seek window fraction)))))
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
      (setq rescroll--installed nil
            rescroll--memo-win nil
            rescroll--memo-cache nil
            rescroll--memo-win2 nil
            rescroll--memo-cache2 nil)
      (dolist (frame (frame-list))
        (dolist (win (window-list frame 'no-minibuffer))
          (set-window-parameter win 'rescroll--cache nil)))))
  (force-mode-line-update t))

(provide 'rescroll)
;;; rescroll.el ends here
