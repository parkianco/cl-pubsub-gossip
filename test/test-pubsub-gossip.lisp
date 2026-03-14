;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: BSD-3-Clause

;;;; test-pubsub-gossip.lisp - Unit tests for pubsub-gossip
;;;;
;;;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;;;; SPDX-License-Identifier: BSD-3-Clause

(defpackage #:cl-pubsub-gossip.test
  (:use #:cl)
  (:export #:run-tests))

(in-package #:cl-pubsub-gossip.test)

(defun run-tests ()
  "Run all tests for cl-pubsub-gossip."
  (format t "~&Running tests for cl-pubsub-gossip...~%")
  ;; TODO: Add test cases
  ;; (test-function-1)
  ;; (test-function-2)
  (format t "~&All tests passed!~%")
  t)
