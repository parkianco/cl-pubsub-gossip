;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10 -*-
;;;; router.lisp - FloodSub router for cl-pubsub-gossip
;;;;
;;;; Provides FloodSub protocol router with flood-based message propagation.

(in-package #:cl-pubsub-gossip)

;;; ============================================================================
;;; EVENT CALLBACKS
;;; ============================================================================

(defvar *on-message-received* nil
  "Callback when a message is received. Called with (message peer-id).")

(defvar *on-message-sent* nil
  "Callback when a message is sent. Called with (message peer-id).")

(defvar *on-peer-subscribed* nil
  "Callback when a peer subscribes to a topic. Called with (peer-id topic).")

(defvar *on-peer-unsubscribed* nil
  "Callback when a peer unsubscribes from a topic. Called with (peer-id topic).")

(defvar *on-validation-failed* nil
  "Callback when message validation fails. Called with (message reason).")

(defvar *on-duplicate-message* nil
  "Callback when a duplicate message is detected. Called with (message-id).")

;;; ============================================================================
;;; PEER STRUCTURE
;;; ============================================================================

(defstruct (peer (:constructor %make-peer))
  "Information about a connected peer."

  (id ""
   :type string
   :read-only t)

  (topics nil
   :type list)

  (connected-at 0
   :type (unsigned-byte 64))

  (messages-sent 0
   :type (unsigned-byte 64))

  (messages-received 0
   :type (unsigned-byte 64))

  (last-message-at 0
   :type (unsigned-byte 64))

  (lock nil
   :type (or null sb-thread:mutex)))

(defun make-peer (id)
  "Create a new peer."
  (%make-peer
   :id id
   :connected-at (get-universal-time)
   :lock (sb-thread:make-mutex :name (format nil "peer-~A" id))))

(defmacro with-peer-lock ((peer) &body body)
  "Execute body with peer lock held."
  `(sb-thread:with-mutex ((peer-lock ,peer))
     ,@body))

(defun peer-add-topic (peer topic)
  "Add a topic to peer's subscriptions."
  (with-peer-lock (peer)
    (unless (member topic (peer-topics peer) :test #'string=)
      (push topic (peer-topics peer))
      t)))

(defun peer-remove-topic (peer topic)
  "Remove a topic from peer's subscriptions."
  (with-peer-lock (peer)
    (let ((original-len (length (peer-topics peer))))
      (setf (peer-topics peer)
            (remove topic (peer-topics peer) :test #'string=))
      (/= original-len (length (peer-topics peer))))))

(defun peer-subscribed-p (peer topic)
  "Check if peer is subscribed to a topic."
  (with-peer-lock (peer)
    (member topic (peer-topics peer) :test #'string=)))

;;; ============================================================================
;;; FLOODSUB CONFIGURATION
;;; ============================================================================

(defstruct (floodsub-config (:constructor %make-floodsub-config))
  "Configuration for FloodSub router."

  (max-message-size +default-max-message-size+
   :type (integer 1))

  (seen-cache-size +default-seen-cache-size+
   :type (integer 1))

  (seen-cache-ttl +default-seen-cache-ttl+
   :type (integer 1))

  (max-topics +default-max-topics+
   :type (integer 1))

  (max-peers-per-topic +default-max-peers-per-topic+
   :type (integer 1))

  (validate-messages t
   :type boolean))

(defun make-floodsub-config (&key (max-message-size +default-max-message-size+)
                                   (seen-cache-size +default-seen-cache-size+)
                                   (seen-cache-ttl +default-seen-cache-ttl+)
                                   (max-topics +default-max-topics+)
                                   (max-peers-per-topic +default-max-peers-per-topic+)
                                   (validate-messages t))
  "Create FloodSub configuration."
  (%make-floodsub-config
   :max-message-size max-message-size
   :seen-cache-size seen-cache-size
   :seen-cache-ttl seen-cache-ttl
   :max-topics max-topics
   :max-peers-per-topic max-peers-per-topic
   :validate-messages validate-messages))

;;; ============================================================================
;;; FLOODSUB ROUTER
;;; ============================================================================

(defstruct (floodsub-router (:constructor %make-floodsub-router))
  "FloodSub protocol router.

   Manages topics, peers, and message routing using simple flooding."

  (id ""
   :type string
   :read-only t)

  (topics (make-hash-table :test 'equal)
   :type hash-table)

  (peers (make-hash-table :test 'equal)
   :type hash-table)

  (subscriptions nil
   :type list)

  (seen-cache nil
   :type (or null seen-cache))

  (config nil
   :type (or null floodsub-config))

  (seqno 0
   :type (unsigned-byte 64))

  (running-p nil
   :type boolean)

  (stats nil
   :type list)

  (lock nil
   :type (or null sb-thread:mutex)))

(defun make-floodsub-router (id &optional config)
  "Create a new FloodSub router.

   Arguments:
     ID - Local peer ID
     CONFIG - Optional configuration"
  (let ((cfg (or config (make-floodsub-config))))
    (%make-floodsub-router
     :id id
     :seen-cache (make-seen-cache
                  :max-size (floodsub-config-seen-cache-size cfg)
                  :ttl (floodsub-config-seen-cache-ttl cfg))
     :config cfg
     :stats (list :messages-sent 0
                  :messages-received 0
                  :messages-forwarded 0
                  :messages-dropped 0
                  :started-at 0)
     :lock (sb-thread:make-mutex :name "floodsub-router"))))

(defmacro with-floodsub-lock ((router) &body body)
  "Execute body with router lock held."
  `(sb-thread:with-mutex ((floodsub-router-lock ,router))
     ,@body))

(defun router-next-seqno (router)
  "Get next sequence number."
  (with-floodsub-lock (router)
    (incf (floodsub-router-seqno router))))

;;; ============================================================================
;;; ROUTER LIFECYCLE
;;; ============================================================================

(defun router-start (router)
  "Start the router."
  (etypecase router
    (floodsub-router
     (with-floodsub-lock (router)
       (setf (floodsub-router-running-p router) t)
       (setf (getf (floodsub-router-stats router) :started-at)
             (get-universal-time))))
    (gossipsub-router
     (sb-thread:with-mutex ((gossipsub-router-lock router))
       (setf (gossipsub-router-running-p router) t))))
  t)

(defun router-stop (router)
  "Stop the router."
  (etypecase router
    (floodsub-router
     (with-floodsub-lock (router)
       (setf (floodsub-router-running-p router) nil)))
    (gossipsub-router
     (sb-thread:with-mutex ((gossipsub-router-lock router))
       (setf (gossipsub-router-running-p router) nil))))
  t)

;;; ============================================================================
;;; SUBSCRIPTION MANAGEMENT
;;; ============================================================================

(defun router-subscribe (router topic &optional handler)
  "Subscribe to a topic."
  (etypecase router
    (floodsub-router (floodsub-subscribe router topic handler))
    (gossipsub-router (gossipsub-subscribe router topic handler))))

(defun router-unsubscribe (router topic)
  "Unsubscribe from a topic."
  (etypecase router
    (floodsub-router (floodsub-unsubscribe router topic))
    (gossipsub-router (gossipsub-unsubscribe router topic))))

(defun floodsub-subscribe (router topic handler)
  "FloodSub subscribe implementation."
  (with-floodsub-lock (router)
    (when (member topic (floodsub-router-subscriptions router) :test #'string=)
      (return-from floodsub-subscribe nil))
    (push topic (floodsub-router-subscriptions router))
    (unless (gethash topic (floodsub-router-topics router))
      (setf (gethash topic (floodsub-router-topics router))
            (make-topic topic)))
    (when handler
      (topic-add-handler (gethash topic (floodsub-router-topics router))
                         handler)))
  (announce-subscription router topic t)
  t)

(defun floodsub-unsubscribe (router topic)
  "FloodSub unsubscribe implementation."
  (with-floodsub-lock (router)
    (unless (member topic (floodsub-router-subscriptions router) :test #'string=)
      (return-from floodsub-unsubscribe nil))
    (setf (floodsub-router-subscriptions router)
          (remove topic (floodsub-router-subscriptions router) :test #'string=)))
  (announce-subscription router topic nil)
  t)

(defun announce-subscription (router topic subscribe-p)
  "Announce subscription change to all peers."
  (let ((msg (make-subscription-message topic subscribe-p)))
    (etypecase router
      (floodsub-router
       (maphash (lambda (peer-id peer)
                  (declare (ignore peer))
                  (send-subscription-to-peer router peer-id msg))
                (floodsub-router-peers router)))
      (gossipsub-router
       ;; GossipSub announcement handled separately
       (declare (ignore msg))))))

(defun send-subscription-to-peer (router peer-id message)
  "Send subscription message to a peer (placeholder for network)."
  (declare (ignore router peer-id message))
  t)

(defun router-is-subscribed-p (router topic)
  "Check if we are subscribed to a topic."
  (etypecase router
    (floodsub-router
     (with-floodsub-lock (router)
       (member topic (floodsub-router-subscriptions router) :test #'string=)))
    (gossipsub-router
     (sb-thread:with-mutex ((gossipsub-router-lock router))
       (member topic (gossipsub-router-topics router) :test #'string=)))))

;;; ============================================================================
;;; PEER MANAGEMENT
;;; ============================================================================

(defun router-add-peer (router peer-id)
  "Add a connected peer."
  (etypecase router
    (floodsub-router
     (with-floodsub-lock (router)
       (or (gethash peer-id (floodsub-router-peers router))
           (setf (gethash peer-id (floodsub-router-peers router))
                 (make-peer peer-id)))))
    (gossipsub-router
     (gossipsub-add-peer router peer-id))))

(defun router-remove-peer (router peer-id)
  "Remove a disconnected peer."
  (etypecase router
    (floodsub-router
     (with-floodsub-lock (router)
       (let ((peer (gethash peer-id (floodsub-router-peers router))))
         (when peer
           (remhash peer-id (floodsub-router-peers router))
           (maphash (lambda (name topic)
                      (declare (ignore name))
                      (topic-remove-peer topic peer-id))
                    (floodsub-router-topics router)))
         peer)))
    (gossipsub-router
     (gossipsub-remove-peer router peer-id))))

(defun router-get-peers (router)
  "Get list of all connected peers."
  (let ((peers nil))
    (etypecase router
      (floodsub-router
       (with-floodsub-lock (router)
         (maphash (lambda (id peer)
                    (declare (ignore peer))
                    (push id peers))
                  (floodsub-router-peers router))))
      (gossipsub-router
       (sb-thread:with-mutex ((gossipsub-router-lock router))
         (maphash (lambda (id peer)
                    (declare (ignore peer))
                    (push id peers))
                  (gossipsub-router-peers router)))))
    peers))

(defun router-get-peers-for-topic (router topic)
  "Get list of peers subscribed to a topic."
  (etypecase router
    (floodsub-router
     (with-floodsub-lock (router)
       (let ((topic-obj (gethash topic (floodsub-router-topics router))))
         (when topic-obj
           (with-topic-lock (topic-obj)
             (copy-list (topic-peers topic-obj)))))))
    (gossipsub-router
     (get-all-topic-peers router topic))))

(defun router-get-topics (router)
  "Get list of all known topics."
  (let ((topics nil))
    (etypecase router
      (floodsub-router
       (with-floodsub-lock (router)
         (maphash (lambda (name topic)
                    (declare (ignore topic))
                    (push name topics))
                  (floodsub-router-topics router))))
      (gossipsub-router
       (sb-thread:with-mutex ((gossipsub-router-lock router))
         (setf topics (copy-list (gossipsub-router-topics router))))))
    topics))

;;; ============================================================================
;;; MESSAGE PUBLISHING
;;; ============================================================================

(defun router-publish (router topic data)
  "Publish a message to a topic.

   Returns message ID on success, NIL on failure."
  (etypecase router
    (floodsub-router (floodsub-publish router topic data))
    (gossipsub-router (gossipsub-publish router topic data))))

(defun floodsub-publish (router topic data)
  "FloodSub publish implementation."
  (unless (floodsub-router-running-p router)
    (return-from floodsub-publish nil))
  ;; Check message size
  (let ((size (if (stringp data) (length data) (length data))))
    (when (> size (floodsub-config-max-message-size
                   (floodsub-router-config router)))
      (return-from floodsub-publish nil)))
  ;; Create message
  (let* ((seqno (router-next-seqno router))
         (message (make-message
                   :from (floodsub-router-id router)
                   :data data
                   :topic topic
                   :seqno seqno))
         (msg-id (message-id message)))
    ;; Add to seen cache
    (seen-cache-add (floodsub-router-seen-cache router) msg-id)
    ;; Flood to all subscribed peers
    (flood-message router message)
    ;; Update stats
    (with-floodsub-lock (router)
      (incf (getf (floodsub-router-stats router) :messages-sent)))
    msg-id))

(defun flood-message (router message)
  "Flood a message to all subscribed peers."
  (let ((topic (message-topic message))
        (from (message-from message))
        (sent 0))
    (with-floodsub-lock (router)
      (let ((topic-obj (gethash topic (floodsub-router-topics router))))
        (when topic-obj
          (dolist (peer-id (with-topic-lock (topic-obj)
                             (copy-list (topic-peers topic-obj))))
            (unless (string= peer-id from)
              (when (send-message-to-peer router peer-id message)
                (incf sent)
                (when *on-message-sent*
                  (funcall *on-message-sent* message peer-id))))))))
    sent))

(defun send-message-to-peer (router peer-id message)
  "Send a message to a specific peer (placeholder for network)."
  (let ((peer (gethash peer-id (floodsub-router-peers router))))
    (when peer
      (with-peer-lock (peer)
        (incf (peer-messages-sent peer))
        (setf (peer-last-message-at peer) (get-universal-time)))
      t)))

;;; ============================================================================
;;; MESSAGE HANDLING
;;; ============================================================================

(defun handle-incoming-message (router message from-peer)
  "Handle an incoming message from a peer.

   Returns:
     :ACCEPTED - Message was accepted
     :DUPLICATE - Message was already seen
     :REJECTED - Message failed validation
     :IGNORED - Message was ignored"
  (etypecase router
    (floodsub-router (handle-floodsub-message router message from-peer))
    (gossipsub-router (handle-gossipsub-message router message from-peer))))

(defun handle-floodsub-message (router message from-peer)
  "Handle incoming FloodSub message."
  (let ((msg-id (message-id message)))
    ;; Check if already seen
    (when (seen-cache-contains-p (floodsub-router-seen-cache router) msg-id)
      (when *on-duplicate-message*
        (funcall *on-duplicate-message* msg-id))
      (return-from handle-floodsub-message :duplicate))
    ;; Validate message
    (when (floodsub-config-validate-messages
           (floodsub-router-config router))
      (let ((result (validate-message router message)))
        (unless (eq result +validation-accept+)
          (when *on-validation-failed*
            (funcall *on-validation-failed* message result))
          (with-floodsub-lock (router)
            (incf (getf (floodsub-router-stats router) :messages-dropped)))
          (return-from handle-floodsub-message
            (if (eq result +validation-reject+) :rejected :ignored)))))
    ;; Add to seen cache
    (seen-cache-add (floodsub-router-seen-cache router) msg-id)
    ;; Update peer stats
    (let ((peer (gethash from-peer (floodsub-router-peers router))))
      (when peer
        (with-peer-lock (peer)
          (incf (peer-messages-received peer))
          (setf (peer-last-message-at peer) (get-universal-time)))))
    ;; Fire callback
    (when *on-message-received*
      (funcall *on-message-received* message from-peer))
    ;; Update stats
    (with-floodsub-lock (router)
      (incf (getf (floodsub-router-stats router) :messages-received)))
    ;; Deliver to handlers
    (deliver-message router message)
    ;; Forward to other peers
    (forward-message router message from-peer)
    :accepted))

(defun forward-message (router message from-peer)
  "Forward a message to other subscribed peers."
  (let ((topic (message-topic message))
        (forwarded 0))
    (with-floodsub-lock (router)
      (let ((topic-obj (gethash topic (floodsub-router-topics router))))
        (when topic-obj
          (dolist (peer-id (with-topic-lock (topic-obj)
                             (copy-list (topic-peers topic-obj))))
            (unless (or (string= peer-id from-peer)
                        (string= peer-id (message-from message)))
              (when (send-message-to-peer router peer-id message)
                (incf forwarded)))))))
    (when (> forwarded 0)
      (with-floodsub-lock (router)
        (incf (getf (floodsub-router-stats router) :messages-forwarded)
              forwarded)))
    forwarded))

(defun deliver-message (router message)
  "Deliver a message to local handlers."
  (let* ((topic-name (message-topic message))
         (topic (etypecase router
                  (floodsub-router
                   (gethash topic-name (floodsub-router-topics router)))
                  (gossipsub-router
                   (gethash topic-name (gossipsub-router-mesh router))))))
    (when (and topic (typep topic 'topic))
      (with-topic-lock (topic)
        (incf (topic-message-count topic))
        (dolist (handler (topic-handlers topic))
          (handler-bind ((error (lambda (c)
                                  (declare (ignore c))
                                  (invoke-restart 'continue))))
            (funcall handler message)))))))

;;; ============================================================================
;;; SUBSCRIPTION HANDLING
;;; ============================================================================

(defun handle-subscription (router peer-id topic subscribe-p)
  "Handle a subscription message from a peer."
  (etypecase router
    (floodsub-router
     (with-floodsub-lock (router)
       (unless (gethash topic (floodsub-router-topics router))
         (setf (gethash topic (floodsub-router-topics router))
               (make-topic topic)))
       (let ((topic-obj (gethash topic (floodsub-router-topics router)))
             (peer (gethash peer-id (floodsub-router-peers router))))
         (when (and topic-obj peer)
           (if subscribe-p
               (progn
                 (topic-add-peer topic-obj peer-id)
                 (peer-add-topic peer topic)
                 (when *on-peer-subscribed*
                   (funcall *on-peer-subscribed* peer-id topic)))
               (progn
                 (topic-remove-peer topic-obj peer-id)
                 (peer-remove-topic peer topic)
                 (when *on-peer-unsubscribed*
                   (funcall *on-peer-unsubscribed* peer-id topic))))))))
    (gossipsub-router
     ;; Handle via GRAFT/PRUNE for GossipSub
     nil)))

;;; ============================================================================
;;; MESSAGE VALIDATION
;;; ============================================================================

(defun validate-message (router message)
  "Validate a message using topic validators."
  ;; Check message size
  (etypecase router
    (floodsub-router
     (when (> (message-size message)
              (floodsub-config-max-message-size
               (floodsub-router-config router)))
       (return-from validate-message +validation-reject+))
     ;; Run topic validators
     (let* ((topic-name (message-topic message))
            (topic (gethash topic-name (floodsub-router-topics router))))
       (when topic
         (dolist (validator (with-topic-lock (topic)
                              (copy-list (topic-validators topic))))
           (let ((result (funcall validator message)))
             (unless (eq result +validation-accept+)
               (return-from validate-message result)))))))
    (gossipsub-router
     ;; GossipSub validation handled separately
     nil))
  +validation-accept+)

;;; ============================================================================
;;; STATISTICS
;;; ============================================================================

(defun router-stats (router)
  "Get router statistics."
  (etypecase router
    (floodsub-router
     (with-floodsub-lock (router)
       (list :id (floodsub-router-id router)
             :running-p (floodsub-router-running-p router)
             :topics (hash-table-count (floodsub-router-topics router))
             :peers (hash-table-count (floodsub-router-peers router))
             :subscriptions (length (floodsub-router-subscriptions router))
             :seen-cache-size (seen-cache-size (floodsub-router-seen-cache router))
             :messages-sent (getf (floodsub-router-stats router) :messages-sent)
             :messages-received (getf (floodsub-router-stats router) :messages-received)
             :messages-forwarded (getf (floodsub-router-stats router) :messages-forwarded)
             :messages-dropped (getf (floodsub-router-stats router) :messages-dropped)
             :uptime (let ((started (getf (floodsub-router-stats router) :started-at)))
                       (if (and started (> started 0))
                           (- (get-universal-time) started)
                           0)))))
    (gossipsub-router
     (get-router-metrics router))))

(defun topic-stats (router topic-name)
  "Get statistics for a specific topic."
  (etypecase router
    (floodsub-router
     (with-floodsub-lock (router)
       (let ((topic (gethash topic-name (floodsub-router-topics router))))
         (when topic
           (with-topic-lock (topic)
             (list :name (topic-name topic)
                   :peers (length (topic-peers topic))
                   :handlers (length (topic-handlers topic))
                   :validators (length (topic-validators topic))
                   :message-count (topic-message-count topic)
                   :created-at (topic-created-at topic)))))))
    (gossipsub-router
     (let ((mesh (gethash topic-name (gossipsub-router-mesh router))))
       (when mesh
         (list :name topic-name
               :mesh-size (mesh-size mesh)))))))

(defun peer-stats (router peer-id)
  "Get statistics for a specific peer."
  (etypecase router
    (floodsub-router
     (with-floodsub-lock (router)
       (let ((peer (gethash peer-id (floodsub-router-peers router))))
         (when peer
           (with-peer-lock (peer)
             (list :id (peer-id peer)
                   :topics (length (peer-topics peer))
                   :connected-at (peer-connected-at peer)
                   :messages-sent (peer-messages-sent peer)
                   :messages-received (peer-messages-received peer)
                   :last-message-at (peer-last-message-at peer)))))))
    (gossipsub-router
     (let ((score-state (gethash peer-id (gossipsub-router-peer-scores router))))
       (when score-state
         (list :id peer-id
               :score (calculate-peer-score score-state
                                            (gossipsub-router-score-params router)
                                            (gossipsub-router-topic-score-params router))))))))
