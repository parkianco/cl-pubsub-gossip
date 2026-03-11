;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10 -*-
;;;; util.lisp - Utility functions for cl-pubsub-gossip
;;;;
;;;; Provides helper functions and macros used throughout the library.

(in-package #:cl-pubsub-gossip)

;;; ============================================================================
;;; THREADING UTILITIES
;;; ============================================================================

(defmacro with-lock ((lock) &body body)
  "Execute BODY with LOCK held."
  `(sb-thread:with-mutex (,lock)
     ,@body))

(defun make-lock (name)
  "Create a new mutex with NAME."
  (sb-thread:make-mutex :name name))

;;; ============================================================================
;;; LIST UTILITIES
;;; ============================================================================

(defun shuffle-list (list)
  "Fisher-Yates shuffle of LIST. Returns a new shuffled list."
  (let ((vec (coerce list 'vector)))
    (loop for i from (1- (length vec)) downto 1
          do (rotatef (aref vec i) (aref vec (random (1+ i)))))
    (coerce vec 'list)))

(defun random-select (list n)
  "Randomly select up to N elements from LIST."
  (let ((shuffled (shuffle-list (copy-list list))))
    (subseq shuffled 0 (min n (length shuffled)))))

;;; ============================================================================
;;; TIME UTILITIES
;;; ============================================================================

(defun current-time-ms ()
  "Get current time in milliseconds (internal time)."
  (get-internal-real-time))

(defun ms-to-internal-time (ms)
  "Convert milliseconds to internal time units."
  (* ms internal-time-units-per-second 1/1000))

(defun internal-time-to-ms (units)
  "Convert internal time units to milliseconds."
  (/ (* units 1000) internal-time-units-per-second))

;;; ============================================================================
;;; HASH UTILITIES
;;; ============================================================================

(defun simple-hash-bytes (data &optional (length 32))
  "Compute a simple hash of DATA as a byte array of LENGTH.
   This is NOT cryptographically secure - for deduplication only."
  (let ((hash (make-array length :element-type '(unsigned-byte 8)
                                 :initial-element 0)))
    (etypecase data
      (string
       (loop for i from 0 below (min (length data) length)
             do (setf (aref hash i)
                      (logxor (aref hash i) (char-code (char data i))))))
      ((simple-array (unsigned-byte 8) (*))
       (loop for i from 0 below (min (length data) length)
             do (setf (aref hash i)
                      (logxor (aref hash i) (aref data i)))))
      (list
       (loop for item in data
             for i from 0 below length
             when (integerp item)
               do (setf (aref hash i)
                        (logxor (aref hash i) (logand item #xFF))))))
    hash))

(defun bytes-to-hex (bytes)
  "Convert byte array to hexadecimal string."
  (with-output-to-string (s)
    (loop for byte across bytes
          do (format s "~2,'0X" byte))))

;;; ============================================================================
;;; DECAY UTILITIES
;;; ============================================================================

(defun decay-value (value decay threshold)
  "Apply exponential decay to VALUE.

   Arguments:
     VALUE - current value
     DECAY - decay factor (0-1)
     THRESHOLD - below this, zero out

   Returns:
     Decayed value."
  (let ((decayed (* value decay)))
    (if (< (abs decayed) threshold)
        0.0
        decayed)))
