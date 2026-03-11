;;;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;;;; SPDX-License-Identifier: BSD-3-Clause

;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10 -*-
;;;; message.lisp - Message structures for cl-pubsub-gossip
;;;;
;;;; Provides message types, seen cache, and message cache.

(in-package #:cl-pubsub-gossip)

;;; ============================================================================
;;; PROTOCOL CONSTANTS
;;; ============================================================================

(defconstant +floodsub-protocol-id+
  (if (boundp '+floodsub-protocol-id+)
      (symbol-value '+floodsub-protocol-id+)
      "/floodsub/1.0.0")
  "FloodSub protocol identifier.")

(defconstant +gossipsub-v10+
  (if (boundp '+gossipsub-v10+)
      (symbol-value '+gossipsub-v10+)
      "/meshsub/1.0.0")
  "GossipSub v1.0 protocol ID.")

(defconstant +gossipsub-v11+
  (if (boundp '+gossipsub-v11+)
      (symbol-value '+gossipsub-v11+)
      "/meshsub/1.1.0")
  "GossipSub v1.1 protocol ID.")

;; FloodSub defaults
(defconstant +default-seen-cache-size+ 10000)
(defconstant +default-seen-cache-ttl+ 120)
(defconstant +default-max-message-size+ 1048576)
(defconstant +default-max-topics+ 1000)
(defconstant +default-max-peers-per-topic+ 1000)

;; GossipSub defaults
(defconstant +default-d+ 6)
(defconstant +default-d-low+ 4)
(defconstant +default-d-high+ 12)
(defconstant +default-d-lazy+ 6)
(defconstant +default-d-out+ 2)
(defconstant +default-d-score+ 4)
(defconstant +default-heartbeat-interval+ 1000)
(defconstant +default-fanout-ttl+ 60000)
(defconstant +default-mcache-len+ 5)
(defconstant +default-mcache-gossip+ 3)
(defconstant +default-seen-ttl+ 120000)
(defconstant +default-prune-backoff+ 60000)
(defconstant +default-graft-flood-threshold+ 10)
(defconstant +max-ihave-length+ 5000)
(defconstant +max-ihave-messages+ 10)

;; Validation results
(defconstant +validation-accept+ :accept)
(defconstant +validation-reject+ :reject)
(defconstant +validation-ignore+ :ignore)
(defconstant +validation-throttle+ :throttle)

;; Score thresholds
(defconstant +gossip-threshold+ 0.0)
(defconstant +publish-threshold+ 0.0)
(defconstant +graylist-threshold+ -1000.0)
(defconstant +accept-px-threshold+ 0.0)
(defconstant +opportunistic-graft-threshold+ 1.0)

;;; ============================================================================
;;; MESSAGE STRUCTURE
;;; ============================================================================

(defstruct (message (:constructor %make-message))
  "PubSub message carrying topic data."

  (id nil
   :type (or null (simple-array (unsigned-byte 8) (*))))

  (from ""
   :type string)

  (data nil
   :type (or null (simple-array (unsigned-byte 8) (*)) string))

  (topic ""
   :type string)

  (seqno 0
   :type (unsigned-byte 64))

  (timestamp 0
   :type (unsigned-byte 64)))

(defun compute-message-id (from seqno &optional data)
  "Compute message ID from source, sequence number, and optional data."
  (let ((hash (make-array 32 :element-type '(unsigned-byte 8)
                             :initial-element 0)))
    ;; Combine source + seqno + data
    (let* ((source-bytes (map '(vector (unsigned-byte 8)) #'char-code from))
           (len (min 16 (length source-bytes))))
      (dotimes (i len)
        (setf (aref hash i) (aref source-bytes i)))
      (setf (aref hash 16) (ldb (byte 8 0) seqno))
      (setf (aref hash 17) (ldb (byte 8 8) seqno))
      (setf (aref hash 18) (ldb (byte 8 16) seqno))
      (setf (aref hash 19) (ldb (byte 8 24) seqno))
      (when data
        (cond
          ((typep data '(simple-array (unsigned-byte 8) (*)))
           (dotimes (i (min 12 (length data)))
             (setf (aref hash (+ 20 i))
                   (logxor (aref hash (+ 20 i)) (aref data i)))))
          ((stringp data)
           (dotimes (i (min 12 (length data)))
             (setf (aref hash (+ 20 i))
                   (logxor (aref hash (+ 20 i)) (char-code (char data i)))))))))
    hash))

(defun make-message (&key from data topic (seqno 0))
  "Create a new message.

   Arguments:
     FROM - Source peer ID
     DATA - Message payload (bytes or string)
     TOPIC - Target topic name
     SEQNO - Sequence number

   Returns:
     MESSAGE structure."
  (let ((msg (%make-message
              :from (or from "")
              :data data
              :topic (or topic "")
              :seqno seqno
              :timestamp (get-universal-time))))
    (setf (message-id msg)
          (compute-message-id (message-from msg)
                              (message-seqno msg)
                              (message-data msg)))
    msg))

(defun message-size (message)
  "Get the size of a message in bytes."
  (let ((data (message-data message)))
    (+ (length (message-from message))
       (length (message-topic message))
       8  ; seqno
       8  ; timestamp
       (if data
           (if (stringp data)
               (length data)
               (length data))
           0))))

(defun message-id-equal (id1 id2)
  "Check if two message IDs are equal."
  (equalp id1 id2))

;;; ============================================================================
;;; SUBSCRIPTION MESSAGE
;;; ============================================================================

(defstruct (subscription-message (:constructor %make-subscription-message))
  "Subscription announcement message."
  (topic "" :type string)
  (subscribe-p t :type boolean))

(defun make-subscription-message (topic subscribe-p)
  "Create a subscription message."
  (%make-subscription-message :topic topic :subscribe-p subscribe-p))

;;; ============================================================================
;;; CONTROL MESSAGES (GossipSub)
;;; ============================================================================

(defstruct (control-message (:constructor %make-control-message))
  "Control message container for GossipSub."
  (ihave nil :type list)
  (iwant nil :type list)
  (graft nil :type list)
  (prune nil :type list)
  (idontwant nil :type list))

(defun make-control-message ()
  "Create empty control message."
  (%make-control-message))

(defstruct (ihave-message (:constructor %make-ihave-message))
  "IHAVE control message advertising available messages."
  (topic-id "" :type string)
  (message-ids nil :type list))

(defun make-ihave-message (topic ids)
  "Create IHAVE message."
  (%make-ihave-message :topic-id topic :message-ids ids))

(defstruct (iwant-message (:constructor %make-iwant-message))
  "IWANT control message requesting messages."
  (message-ids nil :type list))

(defun make-iwant-message (ids)
  "Create IWANT message."
  (%make-iwant-message :message-ids ids))

(defstruct (graft-message (:constructor %make-graft-message))
  "GRAFT control message to join mesh."
  (topic-id "" :type string))

(defun make-graft-message (topic)
  "Create GRAFT message."
  (%make-graft-message :topic-id topic))

(defstruct (prune-message (:constructor %make-prune-message))
  "PRUNE control message to leave mesh."
  (topic-id "" :type string)
  (peers nil :type list)
  (backoff 0 :type (integer 0)))

(defun make-prune-message (topic &key peers backoff)
  "Create PRUNE message."
  (%make-prune-message
   :topic-id topic
   :peers peers
   :backoff (or backoff 0)))

;;; ============================================================================
;;; SEEN CACHE
;;; ============================================================================

(defstruct (seen-entry (:constructor %make-seen-entry))
  "Entry in the seen message cache."
  (message-id nil)
  (timestamp 0 :type (unsigned-byte 64)))

(defstruct (seen-cache (:constructor %make-seen-cache))
  "Cache for tracking seen messages to prevent duplicates."

  (entries (make-hash-table :test 'equalp)
   :type hash-table)

  (max-size +default-seen-cache-size+
   :type (integer 1))

  (ttl +default-seen-cache-ttl+
   :type (integer 1))

  (lock nil
   :type (or null sb-thread:mutex)))

(defun make-seen-cache (&key (max-size +default-seen-cache-size+)
                              (ttl +default-seen-cache-ttl+))
  "Create a new seen message cache."
  (%make-seen-cache
   :max-size max-size
   :ttl ttl
   :lock (sb-thread:make-mutex :name "seen-cache")))

(defmacro with-seen-lock ((cache) &body body)
  "Execute body with seen cache lock held."
  `(sb-thread:with-mutex ((seen-cache-lock ,cache))
     ,@body))

(defun seen-cache-add (cache message-id)
  "Add a message ID to the seen cache.
   Returns T if added (not previously seen), NIL if duplicate."
  (with-seen-lock (cache)
    (let ((existing (gethash message-id (seen-cache-entries cache))))
      (when existing
        (return-from seen-cache-add nil))
      ;; Prune if at capacity
      (when (>= (hash-table-count (seen-cache-entries cache))
                (seen-cache-max-size cache))
        (seen-cache-prune-internal cache))
      ;; Add entry
      (setf (gethash message-id (seen-cache-entries cache))
            (%make-seen-entry :message-id message-id
                              :timestamp (get-universal-time)))
      t)))

(defun seen-cache-contains-p (cache message-id)
  "Check if a message ID is in the seen cache."
  (with-seen-lock (cache)
    (not (null (gethash message-id (seen-cache-entries cache))))))

(defun seen-cache-prune-internal (cache)
  "Remove expired entries (internal, no locking)."
  (let ((now (get-universal-time))
        (ttl (seen-cache-ttl cache))
        (removed 0))
    (maphash (lambda (key entry)
               (when (> (- now (seen-entry-timestamp entry)) ttl)
                 (remhash key (seen-cache-entries cache))
                 (incf removed)))
             (seen-cache-entries cache))
    removed))

(defun seen-cache-prune (cache)
  "Remove expired entries from the cache."
  (with-seen-lock (cache)
    (seen-cache-prune-internal cache)))

(defun seen-cache-clear (cache)
  "Clear all entries from the cache."
  (with-seen-lock (cache)
    (clrhash (seen-cache-entries cache))))

(defun seen-cache-size (cache)
  "Get the number of entries in the cache."
  (with-seen-lock (cache)
    (hash-table-count (seen-cache-entries cache))))

;;; ============================================================================
;;; MESSAGE CACHE (for GossipSub IWANT fulfillment)
;;; ============================================================================

(defstruct (message-cache (:constructor %make-message-cache))
  "Multi-window message cache for IWANT fulfillment."

  ;; message-id -> message
  (messages (make-hash-table :test 'equalp)
   :type hash-table)

  ;; List of (window-time . message-ids)
  (windows nil
   :type list)

  (history-len 5
   :type (integer 1))

  (gossip-windows 3
   :type (integer 1))

  (lock nil
   :type (or null sb-thread:mutex)))

(defun make-message-cache (&key (len 5) (gossip 3))
  "Create new message cache."
  (%make-message-cache
   :history-len len
   :gossip-windows gossip
   :lock (sb-thread:make-mutex :name "message-cache")))

(defun mcache-put (cache msg-id message)
  "Store a message in the cache."
  (sb-thread:with-mutex ((message-cache-lock cache))
    ;; Store in messages table
    (setf (gethash msg-id (message-cache-messages cache)) message)
    ;; Add to current window
    (if (null (message-cache-windows cache))
        (push (list (get-internal-real-time) msg-id)
              (message-cache-windows cache))
        (push msg-id (cdr (first (message-cache-windows cache)))))))

(defun mcache-get (cache msg-id)
  "Retrieve a message from the cache."
  (sb-thread:with-mutex ((message-cache-lock cache))
    (gethash msg-id (message-cache-messages cache))))

(defun mcache-has-p (cache msg-id)
  "Check if message is in cache."
  (sb-thread:with-mutex ((message-cache-lock cache))
    (gethash msg-id (message-cache-messages cache))))

(defun mcache-get-gossip-ids (cache)
  "Get message IDs for gossip (from recent windows)."
  (sb-thread:with-mutex ((message-cache-lock cache))
    (let ((ids nil)
          (count 0))
      (dolist (window (message-cache-windows cache))
        (when (>= count (message-cache-gossip-windows cache))
          (return))
        (dolist (id (cdr window))
          (push id ids))
        (incf count))
      ids)))

(defun mcache-shift (cache)
  "Shift the cache windows, removing oldest.
   Call this periodically (every heartbeat)."
  (sb-thread:with-mutex ((message-cache-lock cache))
    ;; Add new window
    (push (list (get-internal-real-time)) (message-cache-windows cache))
    ;; Trim to history length
    (when (> (length (message-cache-windows cache))
             (message-cache-history-len cache))
      (let ((oldest (car (last (message-cache-windows cache)))))
        ;; Remove messages from oldest window
        (dolist (id (cdr oldest))
          (remhash id (message-cache-messages cache)))
        ;; Remove window
        (setf (message-cache-windows cache)
              (butlast (message-cache-windows cache)))))))
