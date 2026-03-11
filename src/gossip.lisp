;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10 -*-
;;;; gossip.lisp - GossipSub v1.1 protocol for cl-pubsub-gossip
;;;;
;;;; Provides GossipSub v1.1 router with mesh management, peer scoring,
;;;; GRAFT/PRUNE operations, and IHAVE/IWANT protocol.

(in-package #:cl-pubsub-gossip)

;;; ============================================================================
;;; GOSSIPSUB CONFIGURATION
;;; ============================================================================

(defstruct (gossipsub-config (:constructor %make-gossipsub-config))
  "GossipSub router configuration parameters."

  ;; Mesh degree parameters
  (d +default-d+ :type (integer 1))
  (d-low +default-d-low+ :type (integer 1))
  (d-high +default-d-high+ :type (integer 1))
  (d-lazy +default-d-lazy+ :type (integer 1))
  (d-out +default-d-out+ :type (integer 0))
  (d-score +default-d-score+ :type (integer 0))

  ;; Timing
  (heartbeat-interval +default-heartbeat-interval+ :type (integer 100))
  (fanout-ttl +default-fanout-ttl+ :type (integer 1000))
  (mcache-len +default-mcache-len+ :type (integer 1))
  (mcache-gossip +default-mcache-gossip+ :type (integer 1))
  (seen-ttl +default-seen-ttl+ :type (integer 1000))
  (prune-backoff +default-prune-backoff+ :type (integer 1000))
  (graft-flood-threshold +default-graft-flood-threshold+ :type (integer 1))
  (opportunistic-graft-ticks 60 :type (integer 1))
  (max-ihave-length +max-ihave-length+ :type (integer 1))
  (max-ihave-messages +max-ihave-messages+ :type (integer 1))
  (iwant-followup-time 3000 :type (integer 100))
  (flood-publish t :type boolean))

(defun make-gossipsub-config (&rest args)
  "Create GossipSub configuration with defaults and validation."
  (let ((config (apply #'%make-gossipsub-config args)))
    (assert (<= (gossipsub-config-d-low config)
                (gossipsub-config-d config)
                (gossipsub-config-d-high config))
            nil "D constraints violated: D_low <= D <= D_high required")
    config))

;;; ============================================================================
;;; PEER SCORING
;;; ============================================================================

(defstruct (topic-score-params (:constructor %make-topic-score-params))
  "Per-topic scoring parameters for peer evaluation."

  (topic-weight 1.0 :type single-float)
  (time-in-mesh-weight 0.01 :type single-float)
  (time-in-mesh-quantum 1000 :type (integer 1))
  (time-in-mesh-cap 3600.0 :type single-float)
  (first-message-deliveries-weight 1.0 :type single-float)
  (first-message-deliveries-decay 0.5 :type single-float)
  (first-message-deliveries-cap 100.0 :type single-float)
  (mesh-message-deliveries-weight -1.0 :type single-float)
  (mesh-message-deliveries-decay 0.5 :type single-float)
  (mesh-message-deliveries-cap 100.0 :type single-float)
  (mesh-message-deliveries-threshold 1.0 :type single-float)
  (mesh-message-deliveries-activation 5000 :type (integer 1))
  (mesh-failure-penalty-weight -1.0 :type single-float)
  (mesh-failure-penalty-decay 0.5 :type single-float)
  (invalid-message-deliveries-weight -100.0 :type single-float)
  (invalid-message-deliveries-decay 0.1 :type single-float))

(defun make-topic-score-params (&rest args)
  "Create topic score parameters."
  (apply #'%make-topic-score-params args))

(defstruct (peer-score-params (:constructor %make-peer-score-params))
  "Global peer scoring parameters."

  (topic-score-cap 1000.0 :type single-float)
  (app-specific-weight 1.0 :type single-float)
  (ip-colocation-factor-weight -10.0 :type single-float)
  (ip-colocation-factor-threshold 3 :type (integer 1))
  (behaviour-penalty-weight -1.0 :type single-float)
  (behaviour-penalty-decay 0.9 :type single-float)
  (decay-interval 1000 :type (integer 100))
  (decay-to-zero 0.01 :type single-float)
  (retain-score 3600000 :type (integer 1000)))

(defun make-peer-score-params (&rest args)
  "Create peer score parameters."
  (apply #'%make-peer-score-params args))

(defstruct (peer-score-state (:constructor %make-peer-score-state))
  "Runtime state for tracking peer scores."

  (peer-id "" :type string)
  (topic-scores (make-hash-table :test 'equal) :type hash-table)
  (app-specific-score 0.0 :type single-float)
  (ip-colocation-factor 0.0 :type single-float)
  (behaviour-penalty 0.0 :type single-float)
  (connected-at 0 :type (unsigned-byte 64))
  (last-decay 0 :type (unsigned-byte 64))
  (disconnected-at 0 :type (unsigned-byte 64)))

(defstruct (topic-score-state (:constructor %make-topic-score-state))
  "Per-topic score state for a peer."

  (in-mesh nil :type boolean)
  (mesh-time 0 :type (unsigned-byte 64))
  (first-message-deliveries 0.0 :type single-float)
  (mesh-message-deliveries 0.0 :type single-float)
  (mesh-failure-penalty 0.0 :type single-float)
  (invalid-message-deliveries 0.0 :type single-float))

(defun make-peer-score-state (peer-id)
  "Create new peer score state."
  (%make-peer-score-state
   :peer-id peer-id
   :connected-at (get-internal-real-time)))

(defun make-topic-score-state ()
  "Create new topic score state."
  (%make-topic-score-state))

(defun calculate-peer-score (state params topic-params)
  "Calculate current score for a peer."
  (let ((topic-score 0.0)
        (now (get-internal-real-time)))
    ;; Calculate per-topic scores
    (maphash
     (lambda (topic tstate)
       (let ((tparams (gethash topic topic-params)))
         (when tparams
           (incf topic-score
                 (* (topic-score-params-topic-weight tparams)
                    (calculate-topic-score tstate tparams now))))))
     (peer-score-state-topic-scores state))
    ;; Cap topic score
    (setf topic-score (min topic-score
                           (peer-score-params-topic-score-cap params)))
    ;; Combine with global components
    (+ topic-score
       (* (peer-score-params-app-specific-weight params)
          (peer-score-state-app-specific-score state))
       (* (peer-score-params-ip-colocation-factor-weight params)
          (peer-score-state-ip-colocation-factor state))
       (* (peer-score-params-behaviour-penalty-weight params)
          (peer-score-state-behaviour-penalty state)))))

(defun calculate-topic-score (tstate tparams now)
  "Calculate score for a single topic."
  (let ((score 0.0))
    ;; Time in mesh contribution
    (when (topic-score-state-in-mesh tstate)
      (let* ((mesh-time (- now (topic-score-state-mesh-time tstate)))
             (quantums (/ (float mesh-time)
                          (topic-score-params-time-in-mesh-quantum tparams)))
             (capped (min quantums (topic-score-params-time-in-mesh-cap tparams))))
        (incf score (* (topic-score-params-time-in-mesh-weight tparams) capped))))
    ;; First message deliveries
    (incf score (* (topic-score-params-first-message-deliveries-weight tparams)
                   (topic-score-state-first-message-deliveries tstate)))
    ;; Mesh message deliveries (can be negative)
    (let ((deficit (max 0.0
                        (- (topic-score-params-mesh-message-deliveries-threshold tparams)
                           (topic-score-state-mesh-message-deliveries tstate)))))
      (incf score (* (topic-score-params-mesh-message-deliveries-weight tparams)
                     deficit deficit)))
    ;; Mesh failure penalty
    (incf score (* (topic-score-params-mesh-failure-penalty-weight tparams)
                   (topic-score-state-mesh-failure-penalty tstate)))
    ;; Invalid message deliveries
    (incf score (* (topic-score-params-invalid-message-deliveries-weight tparams)
                   (topic-score-state-invalid-message-deliveries tstate)))
    score))

(defun apply-score-decay (state params topic-params)
  "Apply periodic decay to all score components."
  (let ((decay-to-zero (peer-score-params-decay-to-zero params)))
    ;; Decay behaviour penalty
    (setf (peer-score-state-behaviour-penalty state)
          (decay-value (peer-score-state-behaviour-penalty state)
                       (peer-score-params-behaviour-penalty-decay params)
                       decay-to-zero))
    ;; Decay per-topic scores
    (maphash
     (lambda (topic tstate)
       (let ((tparams (gethash topic topic-params)))
         (when tparams
           (decay-topic-scores tstate tparams decay-to-zero))))
     (peer-score-state-topic-scores state))
    ;; Update last decay time
    (setf (peer-score-state-last-decay state) (get-internal-real-time))))

(defun decay-topic-scores (tstate tparams decay-to-zero)
  "Apply decay to topic score components."
  (setf (topic-score-state-first-message-deliveries tstate)
        (decay-value (topic-score-state-first-message-deliveries tstate)
                     (topic-score-params-first-message-deliveries-decay tparams)
                     decay-to-zero))
  (setf (topic-score-state-mesh-message-deliveries tstate)
        (decay-value (topic-score-state-mesh-message-deliveries tstate)
                     (topic-score-params-mesh-message-deliveries-decay tparams)
                     decay-to-zero))
  (setf (topic-score-state-mesh-failure-penalty tstate)
        (decay-value (topic-score-state-mesh-failure-penalty tstate)
                     (topic-score-params-mesh-failure-penalty-decay tparams)
                     decay-to-zero))
  (setf (topic-score-state-invalid-message-deliveries tstate)
        (decay-value (topic-score-state-invalid-message-deliveries tstate)
                     (topic-score-params-invalid-message-deliveries-decay tparams)
                     decay-to-zero)))

(defun update-peer-score (state event &rest args)
  "Update peer score based on an event."
  (case event
    (:first-message-delivery
     (let* ((topic (first args))
            (tstate (ensure-topic-score-state state topic)))
       (incf (topic-score-state-first-message-deliveries tstate))))
    (:mesh-message-delivery
     (let* ((topic (first args))
            (tstate (ensure-topic-score-state state topic)))
       (incf (topic-score-state-mesh-message-deliveries tstate))))
    (:mesh-failure
     (let* ((topic (first args))
            (tstate (ensure-topic-score-state state topic)))
       (incf (topic-score-state-mesh-failure-penalty tstate))))
    (:invalid-message
     (let* ((topic (first args))
            (tstate (ensure-topic-score-state state topic)))
       (incf (topic-score-state-invalid-message-deliveries tstate))))
    (:graft
     (let* ((topic (first args))
            (tstate (ensure-topic-score-state state topic)))
       (setf (topic-score-state-in-mesh tstate) t
             (topic-score-state-mesh-time tstate) (get-internal-real-time))))
    (:prune
     (let* ((topic (first args))
            (tstate (ensure-topic-score-state state topic)))
       (setf (topic-score-state-in-mesh tstate) nil)))
    (:behaviour-penalty
     (incf (peer-score-state-behaviour-penalty state) (or (first args) 1.0)))))

(defun ensure-topic-score-state (state topic)
  "Get or create topic score state for a peer."
  (or (gethash topic (peer-score-state-topic-scores state))
      (setf (gethash topic (peer-score-state-topic-scores state))
            (make-topic-score-state))))

;;; ============================================================================
;;; MESSAGE VALIDATOR
;;; ============================================================================

(defstruct (message-validator (:constructor %make-message-validator))
  "Message validation pipeline."

  (validators (make-hash-table :test 'equal) :type hash-table)
  (default-validators nil :type list)
  (signature-verifier nil :type (or null function))
  (lock nil :type (or null sb-thread:mutex)))

(defun make-message-validator (&key signature-verifier)
  "Create new message validator."
  (%make-message-validator
   :signature-verifier signature-verifier
   :lock (sb-thread:make-mutex :name "message-validator")))

(defun add-topic-validator (validator topic fn)
  "Add a validator function for a topic."
  (sb-thread:with-mutex ((message-validator-lock validator))
    (push fn (gethash topic (message-validator-validators validator)))))

(defun remove-topic-validator (validator topic fn)
  "Remove a validator function from a topic."
  (sb-thread:with-mutex ((message-validator-lock validator))
    (let ((validators (gethash topic (message-validator-validators validator))))
      (setf (gethash topic (message-validator-validators validator))
            (remove fn validators)))))

(defstruct (validation-pipeline (:constructor %make-validation-pipeline))
  "Asynchronous validation pipeline."

  (pending (make-hash-table :test 'equal) :type hash-table)
  (results nil :type list)
  (validator nil :type (or null message-validator))
  (lock nil :type (or null sb-thread:mutex)))

(defun make-validation-pipeline (validator)
  "Create new validation pipeline."
  (%make-validation-pipeline
   :validator validator
   :lock (sb-thread:make-mutex :name "validation-pipeline")))

(defun submit-for-validation (pipeline msg-id message from-peer)
  "Submit a message for asynchronous validation."
  (sb-thread:with-mutex ((validation-pipeline-lock pipeline))
    (setf (gethash msg-id (validation-pipeline-pending pipeline))
          (list message from-peer (get-internal-real-time)))))

(defun process-validation-result (pipeline msg-id result)
  "Record validation result for a message."
  (sb-thread:with-mutex ((validation-pipeline-lock pipeline))
    (let ((entry (gethash msg-id (validation-pipeline-pending pipeline))))
      (when entry
        (remhash msg-id (validation-pipeline-pending pipeline))
        (push (list msg-id (first entry) (second entry) result)
              (validation-pipeline-results pipeline))))))

;;; ============================================================================
;;; GOSSIPSUB ROUTER
;;; ============================================================================

(defstruct (gossipsub-router (:constructor %make-gossipsub-router))
  "GossipSub v1.1 protocol router."

  (id "" :type string :read-only t)
  (config nil :type (or null gossipsub-config))
  (topics nil :type list)
  (mesh (make-hash-table :test 'equal) :type hash-table)
  (fanout (make-hash-table :test 'equal) :type hash-table)
  (peers (make-hash-table :test 'equal) :type hash-table)
  (peer-topics (make-hash-table :test 'equal) :type hash-table)
  (mcache nil :type (or null message-cache))
  (seen (make-hash-table :test 'equal) :type hash-table)
  (score-params nil :type (or null peer-score-params))
  (topic-score-params (make-hash-table :test 'equal) :type hash-table)
  (peer-scores (make-hash-table :test 'equal) :type hash-table)
  (backoff nil :type (or null backoff-state))
  (graft-flood (make-hash-table :test 'equal) :type hash-table)
  (iwant-pending (make-hash-table :test 'equal) :type hash-table)
  (ihave-counts (make-hash-table :test 'equal) :type hash-table)
  (validator nil :type (or null message-validator))
  (running-p nil :type boolean)
  (heartbeat-counter 0 :type (unsigned-byte 64))
  (lock nil :type (or null sb-thread:mutex)))

(defun make-gossipsub-router (id &key config score-params)
  "Create a new GossipSub router."
  (let ((cfg (or config (make-gossipsub-config))))
    (%make-gossipsub-router
     :id id
     :config cfg
     :mcache (make-message-cache
              :len (gossipsub-config-mcache-len cfg)
              :gossip (gossipsub-config-mcache-gossip cfg))
     :score-params (or score-params (make-peer-score-params))
     :backoff (make-backoff-state)
     :validator (make-message-validator)
     :lock (sb-thread:make-mutex :name "gossipsub-router"))))

(defmacro with-gossipsub-lock ((router) &body body)
  "Execute body with router lock held."
  `(sb-thread:with-mutex ((gossipsub-router-lock ,router))
     ,@body))

;;; ============================================================================
;;; GOSSIPSUB SUBSCRIPTION
;;; ============================================================================

(defun gossipsub-subscribe (router topic handler)
  "GossipSub subscribe implementation."
  (with-gossipsub-lock (router)
    (when (member topic (gossipsub-router-topics router) :test #'string=)
      (return-from gossipsub-subscribe nil))
    (push topic (gossipsub-router-topics router))
    (unless (gethash topic (gossipsub-router-mesh router))
      (setf (gethash topic (gossipsub-router-mesh router))
            (make-mesh-state topic)))
    (join-topic-mesh router topic))
  (when handler
    (declare (ignore handler)))
  t)

(defun gossipsub-unsubscribe (router topic)
  "GossipSub unsubscribe implementation."
  (with-gossipsub-lock (router)
    (unless (member topic (gossipsub-router-topics router) :test #'string=)
      (return-from gossipsub-unsubscribe nil))
    (setf (gossipsub-router-topics router)
          (remove topic (gossipsub-router-topics router) :test #'string=))
    (leave-topic-mesh router topic))
  t)

(defun join-topic-mesh (router topic)
  "Join the mesh for a topic by grafting to available peers."
  (let* ((mesh (gethash topic (gossipsub-router-mesh router)))
         (config (gossipsub-router-config router))
         (target-d (gossipsub-config-d config))
         (candidates (get-topic-peer-candidates router topic)))
    (let ((selected (select-peers-by-score router candidates target-d)))
      (dolist (peer-id selected)
        (mesh-add-peer mesh peer-id)
        (send-graft router peer-id topic)))))

(defun leave-topic-mesh (router topic)
  "Leave the mesh for a topic by pruning all mesh peers."
  (let ((mesh (gethash topic (gossipsub-router-mesh router))))
    (when mesh
      (dolist (peer-id (mesh-get-peers mesh))
        (mesh-remove-peer mesh peer-id)
        (send-prune router peer-id topic)))))

(defun get-topic-peer-candidates (router topic)
  "Get peers subscribed to topic that aren't in mesh."
  (let ((mesh (gethash topic (gossipsub-router-mesh router)))
        (candidates nil))
    (maphash
     (lambda (peer-id topics)
       (when (and (member topic topics :test #'string=)
                  (not (mesh-contains-p mesh peer-id)))
         (push peer-id candidates)))
     (gossipsub-router-peer-topics router))
    candidates))

(defun select-peers-by-score (router peers n)
  "Select up to N peers sorted by score (highest first)."
  (let ((scored (mapcar
                 (lambda (peer-id)
                   (cons peer-id (get-peer-score router peer-id)))
                 peers)))
    (setf scored (sort scored #'> :key #'cdr))
    (mapcar #'car (subseq scored 0 (min n (length scored))))))

(defun get-peer-score (router peer-id)
  "Get current score for a peer."
  (let ((state (gethash peer-id (gossipsub-router-peer-scores router))))
    (if state
        (calculate-peer-score state
                              (gossipsub-router-score-params router)
                              (gossipsub-router-topic-score-params router))
        0.0)))

;;; ============================================================================
;;; PEER MANAGEMENT
;;; ============================================================================

(defun gossipsub-add-peer (router peer-id)
  "Add a connected peer to GossipSub."
  (with-gossipsub-lock (router)
    (unless (gethash peer-id (gossipsub-router-peers router))
      (setf (gethash peer-id (gossipsub-router-peers router)) t)
      (setf (gethash peer-id (gossipsub-router-peer-topics router)) nil)
      (setf (gethash peer-id (gossipsub-router-peer-scores router))
            (make-peer-score-state peer-id))
      t)))

(defun gossipsub-remove-peer (router peer-id)
  "Remove a disconnected peer from GossipSub."
  (with-gossipsub-lock (router)
    (when (gethash peer-id (gossipsub-router-peers router))
      ;; Remove from all meshes
      (maphash
       (lambda (topic mesh)
         (declare (ignore topic))
         (mesh-remove-peer mesh peer-id))
       (gossipsub-router-mesh router))
      ;; Clean up state
      (remhash peer-id (gossipsub-router-peers router))
      (remhash peer-id (gossipsub-router-peer-topics router))
      ;; Mark peer score as disconnected
      (let ((score-state (gethash peer-id (gossipsub-router-peer-scores router))))
        (when score-state
          (setf (peer-score-state-disconnected-at score-state)
                (get-internal-real-time))))
      t)))

(defun get-all-topic-peers (router topic)
  "Get all peers subscribed to a topic."
  (let ((peers nil))
    (maphash
     (lambda (peer-id topics)
       (when (member topic topics :test #'string=)
         (push peer-id peers)))
     (gossipsub-router-peer-topics router))
    peers))

;;; ============================================================================
;;; GRAFT/PRUNE OPERATIONS
;;; ============================================================================

(defun send-graft (router peer-id topic)
  "Send GRAFT message to peer for topic."
  (let ((msg (make-graft-message topic)))
    (declare (ignore msg))
    ;; Update peer score state
    (let ((score-state (gethash peer-id (gossipsub-router-peer-scores router))))
      (when score-state
        (update-peer-score score-state :graft topic))))
  t)

(defun send-prune (router peer-id topic)
  "Send PRUNE message to peer for topic."
  (let* ((config (gossipsub-router-config router))
         (backoff (gossipsub-config-prune-backoff config))
         (msg (make-prune-message topic :backoff backoff)))
    (declare (ignore msg))
    ;; Add backoff
    (add-backoff (gossipsub-router-backoff router) peer-id topic backoff)
    ;; Update peer score state
    (let ((score-state (gethash peer-id (gossipsub-router-peer-scores router))))
      (when score-state
        (update-peer-score score-state :prune topic))))
  t)

(defun handle-graft (router peer-id graft-msg)
  "Handle incoming GRAFT message."
  (let* ((topic (graft-message-topic-id graft-msg))
         (config (gossipsub-router-config router)))
    ;; Check if we're subscribed
    (unless (member topic (gossipsub-router-topics router) :test #'string=)
      (send-prune router peer-id topic)
      (return-from handle-graft nil))
    ;; Check peer score
    (when (< (get-peer-score router peer-id) +graylist-threshold+)
      (send-prune router peer-id topic)
      (return-from handle-graft nil))
    ;; Check backoff
    (when (in-backoff-p (gossipsub-router-backoff router) peer-id topic)
      (let ((score-state (gethash peer-id (gossipsub-router-peer-scores router))))
        (when score-state
          (update-peer-score score-state :behaviour-penalty 1.0)))
      (send-prune router peer-id topic)
      (return-from handle-graft nil))
    ;; Check GRAFT flood
    (when (graft-flooding-p router peer-id config)
      (send-prune router peer-id topic)
      (return-from handle-graft nil))
    ;; Accept GRAFT
    (let ((mesh (gethash topic (gossipsub-router-mesh router))))
      (when mesh
        (mesh-add-peer mesh peer-id)
        (let ((score-state (gethash peer-id (gossipsub-router-peer-scores router))))
          (when score-state
            (update-peer-score score-state :graft topic)))))
    t))

(defun handle-prune (router peer-id prune-msg)
  "Handle incoming PRUNE message."
  (let* ((topic (prune-message-topic-id prune-msg))
         (mesh (gethash topic (gossipsub-router-mesh router)))
         (backoff (prune-message-backoff prune-msg)))
    (when mesh
      (mesh-remove-peer mesh peer-id))
    (when (> backoff 0)
      (add-backoff (gossipsub-router-backoff router) peer-id topic backoff))
    t))

(defun graft-flooding-p (router peer-id config)
  "Check if peer is flooding GRAFTs."
  (let* ((now (get-internal-real-time))
         (window internal-time-units-per-second)
         (threshold (gossipsub-config-graft-flood-threshold config))
         (timestamps (gethash peer-id (gossipsub-router-graft-flood router))))
    (setf timestamps (remove-if (lambda (ts) (< ts (- now window))) timestamps))
    (push now timestamps)
    (setf (gethash peer-id (gossipsub-router-graft-flood router)) timestamps)
    (> (length timestamps) threshold)))

(defun opportunistic-graft (router)
  "Attempt opportunistic grafting for under-connected meshes."
  (let ((config (gossipsub-router-config router)))
    (maphash
     (lambda (topic mesh)
       (when (mesh-needs-peers-p mesh (gossipsub-config-d-low config))
         (let ((candidates (get-topic-peer-candidates router topic)))
           (dolist (peer-id candidates)
             (when (and (>= (get-peer-score router peer-id)
                            +opportunistic-graft-threshold+)
                        (not (in-backoff-p (gossipsub-router-backoff router)
                                           peer-id topic)))
               (mesh-add-peer mesh peer-id)
               (send-graft router peer-id topic)
               (return))))))
     (gossipsub-router-mesh router))))

;;; ============================================================================
;;; IHAVE/IWANT PROTOCOL
;;; ============================================================================

(defun send-ihave (router peer-id topic msg-ids)
  "Send IHAVE message to peer."
  (when msg-ids
    (let ((max-len (gossipsub-config-max-ihave-length
                    (gossipsub-router-config router))))
      (loop for chunk = (subseq msg-ids 0 (min max-len (length msg-ids)))
            for rest = (nthcdr max-len msg-ids)
            do (let ((msg (make-ihave-message topic chunk)))
                 (declare (ignore msg peer-id)))
            while rest
            do (setf msg-ids rest)))))

(defun send-iwant (router peer-id msg-ids)
  "Send IWANT message to peer."
  (when msg-ids
    (let ((msg (make-iwant-message msg-ids)))
      (declare (ignore msg peer-id))
      ;; Track pending IWANTs
      (let ((now (get-internal-real-time)))
        (dolist (id msg-ids)
          (setf (gethash id (gossipsub-router-iwant-pending router))
                (cons now peer-id)))))))

(defun handle-ihave (router peer-id ihave-msg)
  "Handle incoming IHAVE message."
  (let* ((config (gossipsub-router-config router))
         (max-messages (gossipsub-config-max-ihave-messages config)))
    ;; Check peer score
    (when (< (get-peer-score router peer-id) +gossip-threshold+)
      (return-from handle-ihave nil))
    ;; Check IHAVE count
    (let ((count (or (gethash peer-id (gossipsub-router-ihave-counts router)) 0)))
      (when (>= count max-messages)
        (return-from handle-ihave nil))
      (incf (gethash peer-id (gossipsub-router-ihave-counts router))))
    ;; Find messages we don't have
    (let ((want nil))
      (dolist (msg-id (ihave-message-message-ids ihave-msg))
        (unless (or (gethash msg-id (gossipsub-router-seen router))
                    (mcache-has-p (gossipsub-router-mcache router) msg-id))
          (push msg-id want)))
      (when want
        (send-iwant router peer-id want)))
    t))

(defun handle-iwant (router peer-id iwant-msg)
  "Handle incoming IWANT message."
  (when (< (get-peer-score router peer-id) +gossip-threshold+)
    (return-from handle-iwant nil))
  (dolist (msg-id (iwant-message-message-ids iwant-msg))
    (let ((message (mcache-get (gossipsub-router-mcache router) msg-id)))
      (when message
        ;; Would send message to peer here
        (declare (ignore message)))))
  t)

(defun emit-gossip (router)
  "Emit IHAVE gossip to non-mesh peers."
  (let* ((config (gossipsub-router-config router))
         (mcache (gossipsub-router-mcache router))
         (d-lazy (gossipsub-config-d-lazy config)))
    (let ((gossip-ids (mcache-get-gossip-ids mcache)))
      (when gossip-ids
        (dolist (topic (gossipsub-router-topics router))
          (let ((peers (get-topic-peer-candidates router topic)))
            (let ((targets (random-select peers d-lazy)))
              (dolist (peer-id targets)
                (when (>= (get-peer-score router peer-id) +gossip-threshold+)
                  (send-ihave router peer-id topic gossip-ids))))))))))

;;; ============================================================================
;;; MESSAGE PUBLISHING
;;; ============================================================================

(defun gossipsub-publish (router topic data)
  "GossipSub publish implementation."
  (unless (gossipsub-router-running-p router)
    (return-from gossipsub-publish nil))
  (let* ((config (gossipsub-router-config router))
         (msg-id (generate-gossipsub-message-id router topic data))
         (message (make-gossipsub-message router topic data msg-id)))
    ;; Add to seen cache
    (setf (gethash msg-id (gossipsub-router-seen router))
          (get-internal-real-time))
    ;; Add to message cache
    (mcache-put (gossipsub-router-mcache router) msg-id message)
    ;; Publish to mesh or fanout
    (if (member topic (gossipsub-router-topics router) :test #'string=)
        (publish-to-mesh router topic message)
        (publish-to-fanout router topic message))
    ;; Flood publish if enabled
    (when (gossipsub-config-flood-publish config)
      (flood-publish-gossipsub router topic message))
    msg-id))

(defun generate-gossipsub-message-id (router topic data)
  "Generate unique message ID."
  (declare (ignore data))
  (format nil "~A-~A-~A"
          (gossipsub-router-id router)
          topic
          (incf (gossipsub-router-heartbeat-counter router))))

(defun make-gossipsub-message (router topic data msg-id)
  "Create message structure for GossipSub."
  (list :id msg-id
        :from (gossipsub-router-id router)
        :topic topic
        :data data
        :timestamp (get-internal-real-time)))

(defun publish-to-mesh (router topic message)
  "Publish message to all mesh peers for topic."
  (let ((mesh (gethash topic (gossipsub-router-mesh router))))
    (when mesh
      (dolist (peer-id (mesh-get-peers mesh))
        (when (>= (get-peer-score router peer-id) +publish-threshold+)
          ;; Would send message to peer here
          (declare (ignore peer-id message)))))))

(defun publish-to-fanout (router topic message)
  "Publish message to fanout peers for topic."
  (let* ((config (gossipsub-router-config router))
         (d (gossipsub-config-d config))
         (fanout-entry (gethash topic (gossipsub-router-fanout router)))
         (peers nil))
    (if fanout-entry
        (progn
          (setf peers (cdr fanout-entry))
          (setf (car fanout-entry) (get-internal-real-time)))
        (let ((candidates (get-all-topic-peers router topic)))
          (setf peers (random-select candidates d))
          (setf (gethash topic (gossipsub-router-fanout router))
                (cons (get-internal-real-time) peers))))
    (dolist (peer-id peers)
      (when (>= (get-peer-score router peer-id) +publish-threshold+)
        ;; Would send message to peer here
        (declare (ignore peer-id message))))))

(defun flood-publish-gossipsub (router topic message)
  "Flood publish to all peers subscribed to topic."
  (let ((peers (get-all-topic-peers router topic)))
    (dolist (peer-id peers)
      (when (>= (get-peer-score router peer-id) +publish-threshold+)
        ;; Would send message to peer here
        (declare (ignore peer-id message))))))

;;; ============================================================================
;;; MESSAGE HANDLING
;;; ============================================================================

(defun handle-gossipsub-message (router message from-peer)
  "Handle incoming GossipSub message."
  (let ((msg-id (if (listp message)
                    (getf message :id)
                    (message-id message))))
    ;; Check if already seen
    (when (gethash msg-id (gossipsub-router-seen router))
      (when *on-duplicate-message*
        (funcall *on-duplicate-message* msg-id))
      (return-from handle-gossipsub-message :duplicate))
    ;; Add to seen
    (setf (gethash msg-id (gossipsub-router-seen router))
          (get-internal-real-time))
    ;; Update peer score
    (let ((score-state (gethash from-peer (gossipsub-router-peer-scores router)))
          (topic (if (listp message)
                     (getf message :topic)
                     (message-topic message))))
      (when score-state
        (update-peer-score score-state :first-message-delivery topic)))
    ;; Fire callback
    (when *on-message-received*
      (funcall *on-message-received* message from-peer))
    :accepted))

;;; ============================================================================
;;; HEARTBEAT
;;; ============================================================================

(defun router-heartbeat (router)
  "Periodic heartbeat for mesh maintenance."
  (etypecase router
    (floodsub-router
     ;; FloodSub doesn't need heartbeat
     t)
    (gossipsub-router
     (gossipsub-heartbeat router))))

(defun gossipsub-heartbeat (router)
  "GossipSub heartbeat implementation."
  (let ((config (gossipsub-router-config router)))
    ;; Clear IHAVE counts
    (clrhash (gossipsub-router-ihave-counts router))
    ;; Maintain mesh for each topic
    (dolist (topic (gossipsub-router-topics router))
      (maintain-mesh router topic config))
    ;; Clean expired fanout
    (clean-fanout router config)
    ;; Shift message cache
    (mcache-shift (gossipsub-router-mcache router))
    ;; Clean expired seen entries
    (clean-seen router config)
    ;; Clear expired backoffs
    (clear-expired-backoffs (gossipsub-router-backoff router))
    ;; Apply score decay
    (decay-all-scores router)
    ;; Emit gossip
    (emit-gossip router)
    ;; Opportunistic grafting
    (incf (gossipsub-router-heartbeat-counter router))
    (when (zerop (mod (gossipsub-router-heartbeat-counter router)
                      (gossipsub-config-opportunistic-graft-ticks config)))
      (opportunistic-graft router))
    t))

(defun maintain-mesh (router topic config)
  "Maintain mesh degree for a topic."
  (let* ((mesh (gethash topic (gossipsub-router-mesh router)))
         (d (gossipsub-config-d config))
         (d-low (gossipsub-config-d-low config))
         (d-high (gossipsub-config-d-high config))
         (size (mesh-size mesh)))
    (cond
      ;; Need more peers
      ((< size d-low)
       (let* ((need (- d size))
              (candidates (get-topic-peer-candidates router topic))
              (selected (select-peers-by-score router candidates need)))
         (dolist (peer-id selected)
           (unless (in-backoff-p (gossipsub-router-backoff router) peer-id topic)
             (mesh-add-peer mesh peer-id)
             (send-graft router peer-id topic)))))
      ;; Too many peers
      ((> size d-high)
       (let* ((excess (- size d))
              (peers (mesh-get-peers mesh))
              (sorted (sort (copy-list peers)
                            (lambda (a b)
                              (< (get-peer-score router a)
                                 (get-peer-score router b)))))
              (to-prune (subseq sorted 0 excess)))
         (dolist (peer-id to-prune)
           (mesh-remove-peer mesh peer-id)
           (send-prune router peer-id topic)))))))

(defun clean-fanout (router config)
  "Remove stale fanout entries."
  (let ((ttl (gossipsub-config-fanout-ttl config))
        (now (get-internal-real-time))
        (to-remove nil))
    (maphash
     (lambda (topic entry)
       (when (> (- now (car entry))
                (ms-to-internal-time ttl))
         (push topic to-remove)))
     (gossipsub-router-fanout router))
    (dolist (topic to-remove)
      (remhash topic (gossipsub-router-fanout router)))))

(defun clean-seen (router config)
  "Remove expired seen entries."
  (let ((ttl (gossipsub-config-seen-ttl config))
        (now (get-internal-real-time))
        (to-remove nil))
    (maphash
     (lambda (id ts)
       (when (> (- now ts) (ms-to-internal-time ttl))
         (push id to-remove)))
     (gossipsub-router-seen router))
    (dolist (id to-remove)
      (remhash id (gossipsub-router-seen router)))))

(defun decay-all-scores (router)
  "Apply decay to all peer scores."
  (maphash
   (lambda (peer-id state)
     (declare (ignore peer-id))
     (apply-score-decay state
                        (gossipsub-router-score-params router)
                        (gossipsub-router-topic-score-params router)))
   (gossipsub-router-peer-scores router)))

;;; ============================================================================
;;; METRICS
;;; ============================================================================

(defstruct (gossipsub-metrics (:constructor %make-gossipsub-metrics))
  "GossipSub router metrics."

  (topics 0 :type (unsigned-byte 32))
  (mesh-peers 0 :type (unsigned-byte 32))
  (total-peers 0 :type (unsigned-byte 32))
  (messages-published 0 :type (unsigned-byte 64))
  (messages-received 0 :type (unsigned-byte 64))
  (grafts-sent 0 :type (unsigned-byte 64))
  (grafts-received 0 :type (unsigned-byte 64))
  (prunes-sent 0 :type (unsigned-byte 64))
  (prunes-received 0 :type (unsigned-byte 64))
  (ihave-sent 0 :type (unsigned-byte 64))
  (ihave-received 0 :type (unsigned-byte 64))
  (iwant-sent 0 :type (unsigned-byte 64))
  (iwant-received 0 :type (unsigned-byte 64)))

(defun make-gossipsub-metrics ()
  "Create new metrics."
  (%make-gossipsub-metrics))

(defun get-router-metrics (router)
  "Get current router metrics."
  (let ((metrics (make-gossipsub-metrics))
        (total-mesh 0))
    (setf (gossipsub-metrics-topics metrics)
          (length (gossipsub-router-topics router)))
    (maphash
     (lambda (topic mesh)
       (declare (ignore topic))
       (incf total-mesh (mesh-size mesh)))
     (gossipsub-router-mesh router))
    (setf (gossipsub-metrics-mesh-peers metrics) total-mesh)
    (setf (gossipsub-metrics-total-peers metrics)
          (hash-table-count (gossipsub-router-peers router)))
    metrics))

(defun reset-router-metrics (router)
  "Reset router metrics."
  (declare (ignore router))
  t)
