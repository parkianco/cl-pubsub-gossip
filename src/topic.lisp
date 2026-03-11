;;;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;;;; SPDX-License-Identifier: BSD-3-Clause

;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10 -*-
;;;; topic.lisp - Topic management for cl-pubsub-gossip
;;;;
;;;; Provides topic structures, peer tracking, and mesh state management.

(in-package #:cl-pubsub-gossip)

;;; ============================================================================
;;; TOPIC STRUCTURE
;;; ============================================================================

(defstruct (topic (:constructor %make-topic))
  "PubSub topic with subscriber tracking.

   Maintains the list of subscribed peers and message handlers."

  (name ""
   :type string
   :read-only t)

  (peers nil
   :type list)

  (handlers nil
   :type list)

  (validators nil
   :type list)

  (message-count 0
   :type (unsigned-byte 64))

  (created-at 0
   :type (unsigned-byte 64))

  (lock nil
   :type (or null sb-thread:mutex)))

(defun make-topic (name)
  "Create a new topic.

   Arguments:
     NAME - Topic name

   Returns:
     TOPIC structure."
  (%make-topic
   :name name
   :created-at (get-universal-time)
   :lock (sb-thread:make-mutex :name (format nil "topic-~A" name))))

(defmacro with-topic-lock ((topic) &body body)
  "Execute body with topic lock held."
  `(sb-thread:with-mutex ((topic-lock ,topic))
     ,@body))

(defun topic-add-peer (topic peer-id)
  "Add a peer to topic subscribers.

   Arguments:
     TOPIC - Topic structure
     PEER-ID - Peer ID string

   Returns:
     T if added, NIL if already subscribed."
  (with-topic-lock (topic)
    (unless (member peer-id (topic-peers topic) :test #'string=)
      (push peer-id (topic-peers topic))
      t)))

(defun topic-remove-peer (topic peer-id)
  "Remove a peer from topic subscribers.

   Arguments:
     TOPIC - Topic structure
     PEER-ID - Peer ID string

   Returns:
     T if removed."
  (with-topic-lock (topic)
    (let ((original-len (length (topic-peers topic))))
      (setf (topic-peers topic)
            (remove peer-id (topic-peers topic) :test #'string=))
      (/= original-len (length (topic-peers topic))))))

(defun topic-peer-count (topic)
  "Get number of peers subscribed to topic."
  (with-topic-lock (topic)
    (length (topic-peers topic))))

(defun topic-add-handler (topic handler)
  "Add a message handler to the topic.

   Arguments:
     TOPIC - Topic structure
     HANDLER - Function taking (message) argument"
  (with-topic-lock (topic)
    (pushnew handler (topic-handlers topic))))

(defun topic-remove-handler (topic handler)
  "Remove a message handler from the topic."
  (with-topic-lock (topic)
    (setf (topic-handlers topic)
          (remove handler (topic-handlers topic)))))

(defun topic-add-validator (topic validator)
  "Add a message validator to the topic.

   Arguments:
     TOPIC - Topic structure
     VALIDATOR - Function (message) -> validation-result"
  (with-topic-lock (topic)
    (pushnew validator (topic-validators topic))))

;;; ============================================================================
;;; MESH STATE (for GossipSub)
;;; ============================================================================

(defstruct (mesh-state (:constructor %make-mesh-state))
  "State for a single topic's mesh in GossipSub.

   Tracks the set of peers in the mesh and outbound connections."

  (topic ""
   :type string
   :read-only t)

  ;; Set of peer IDs in mesh
  (peers (make-hash-table :test 'equal)
   :type hash-table)

  ;; Outbound peers (for D_out quota)
  (outbound (make-hash-table :test 'equal)
   :type hash-table)

  (lock nil
   :type (or null sb-thread:mutex)))

(defun make-mesh-state (topic)
  "Create new mesh state for a topic."
  (%make-mesh-state
   :topic topic
   :lock (sb-thread:make-mutex :name (format nil "mesh-~A" topic))))

(defmacro with-mesh-lock ((mesh) &body body)
  "Execute body with mesh lock held."
  `(sb-thread:with-mutex ((mesh-state-lock ,mesh))
     ,@body))

(defun mesh-add-peer (mesh peer-id &optional outbound-p)
  "Add a peer to the mesh.

   Arguments:
     MESH - mesh-state
     PEER-ID - peer ID string
     OUTBOUND-P - if T, count toward outbound quota

   Returns:
     T if added, NIL if already present."
  (with-mesh-lock (mesh)
    (unless (gethash peer-id (mesh-state-peers mesh))
      (setf (gethash peer-id (mesh-state-peers mesh)) t)
      (when outbound-p
        (setf (gethash peer-id (mesh-state-outbound mesh)) t))
      t)))

(defun mesh-remove-peer (mesh peer-id)
  "Remove a peer from the mesh.

   Returns:
     T if removed, NIL if not present."
  (with-mesh-lock (mesh)
    (let ((was-present (gethash peer-id (mesh-state-peers mesh))))
      (remhash peer-id (mesh-state-peers mesh))
      (remhash peer-id (mesh-state-outbound mesh))
      was-present)))

(defun mesh-get-peers (mesh)
  "Get list of peers in the mesh."
  (with-mesh-lock (mesh)
    (loop for peer-id being the hash-keys of (mesh-state-peers mesh)
          collect peer-id)))

(defun mesh-size (mesh)
  "Get number of peers in mesh."
  (with-mesh-lock (mesh)
    (hash-table-count (mesh-state-peers mesh))))

(defun mesh-needs-peers-p (mesh d-low)
  "Check if mesh needs more peers (below D_low)."
  (< (mesh-size mesh) d-low))

(defun mesh-has-excess-p (mesh d-high)
  "Check if mesh has excess peers (above D_high)."
  (> (mesh-size mesh) d-high))

(defun mesh-contains-p (mesh peer-id)
  "Check if peer is in mesh."
  (with-mesh-lock (mesh)
    (gethash peer-id (mesh-state-peers mesh))))

(defun mesh-outbound-count (mesh)
  "Get count of outbound peers in mesh."
  (with-mesh-lock (mesh)
    (hash-table-count (mesh-state-outbound mesh))))

;;; ============================================================================
;;; BACKOFF STATE
;;; ============================================================================

(defstruct (backoff-state (:constructor %make-backoff-state))
  "Tracks GRAFT backoff state for peers.

   Prevents peers from immediately re-grafting after being pruned."

  ;; peer-id -> (topic -> expiry-time)
  (entries (make-hash-table :test 'equal)
   :type hash-table)

  (lock nil
   :type (or null sb-thread:mutex)))

(defun make-backoff-state ()
  "Create new backoff state."
  (%make-backoff-state
   :lock (sb-thread:make-mutex :name "backoff-state")))

(defun add-backoff (state peer-id topic duration)
  "Add backoff for peer on topic.

   Arguments:
     STATE - backoff-state
     PEER-ID - peer ID string
     TOPIC - topic string
     DURATION - backoff duration in milliseconds"
  (sb-thread:with-mutex ((backoff-state-lock state))
    (let ((peer-backoffs (or (gethash peer-id (backoff-state-entries state))
                             (setf (gethash peer-id (backoff-state-entries state))
                                   (make-hash-table :test 'equal))))
          (expiry (+ (get-internal-real-time)
                     (ms-to-internal-time duration))))
      (setf (gethash topic peer-backoffs) expiry))))

(defun in-backoff-p (state peer-id topic)
  "Check if peer is in backoff for topic."
  (sb-thread:with-mutex ((backoff-state-lock state))
    (let ((peer-backoffs (gethash peer-id (backoff-state-entries state))))
      (when peer-backoffs
        (let ((expiry (gethash topic peer-backoffs)))
          (and expiry (> expiry (get-internal-real-time))))))))

(defun clear-expired-backoffs (state)
  "Remove expired backoff entries."
  (let ((now (get-internal-real-time)))
    (sb-thread:with-mutex ((backoff-state-lock state))
      (maphash
       (lambda (peer-id peer-backoffs)
         (maphash
          (lambda (topic expiry)
            (when (<= expiry now)
              (remhash topic peer-backoffs)))
          peer-backoffs)
         ;; Remove peer entry if no more backoffs
         (when (zerop (hash-table-count peer-backoffs))
           (remhash peer-id (backoff-state-entries state))))
       (backoff-state-entries state)))))
