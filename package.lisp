;;;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;;;; SPDX-License-Identifier: BSD-3-Clause

;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10 -*-
;;;; package.lisp - Package definitions for cl-pubsub-gossip
;;;;
;;;; Provides publish-subscribe messaging with FloodSub and GossipSub v1.1.

(defpackage #:cl-pubsub-gossip
  (:use #:cl)
  (:nicknames #:pubsub #:gossipsub)
  (:documentation "Flood-routing publish-subscribe messaging with GossipSub v1.1.

This package provides a complete implementation of topic-based pub/sub messaging:

FloodSub (/floodsub/1.0.0):
  - Simple flood-based message propagation
  - Reliable delivery to all topic subscribers
  - Higher bandwidth usage

GossipSub v1.1 (/meshsub/1.1.0):
  - Mesh-based topology with configurable degree
  - Peer scoring for Sybil resistance
  - GRAFT/PRUNE for mesh maintenance
  - IHAVE/IWANT for lazy message propagation
  - Backoff management
  - Message validation pipeline

All operations are thread-safe using SBCL's sb-thread primitives.")

  (:export
   ;; =========================================================================
   ;; Protocol Constants
   ;; =========================================================================
   #:+floodsub-protocol-id+
   #:+gossipsub-v10+
   #:+gossipsub-v11+

   ;; FloodSub constants
   #:+default-seen-cache-size+
   #:+default-seen-cache-ttl+
   #:+default-max-message-size+
   #:+default-max-topics+
   #:+default-max-peers-per-topic+

   ;; GossipSub constants
   #:+default-d+
   #:+default-d-low+
   #:+default-d-high+
   #:+default-d-lazy+
   #:+default-heartbeat-interval+
   #:+default-fanout-ttl+
   #:+default-mcache-len+
   #:+default-mcache-gossip+
   #:+default-seen-ttl+
   #:+default-prune-backoff+
   #:+default-graft-flood-threshold+
   #:+max-ihave-length+
   #:+max-ihave-messages+

   ;; Validation results
   #:+validation-accept+
   #:+validation-reject+
   #:+validation-ignore+
   #:+validation-throttle+

   ;; Score thresholds
   #:+gossip-threshold+
   #:+publish-threshold+
   #:+graylist-threshold+
   #:+accept-px-threshold+
   #:+opportunistic-graft-threshold+

   ;; =========================================================================
   ;; Topic Management
   ;; =========================================================================
   #:topic
   #:make-topic
   #:topic-p
   #:topic-name
   #:topic-peers
   #:topic-handlers
   #:topic-validators
   #:topic-message-count
   #:topic-add-peer
   #:topic-remove-peer
   #:topic-peer-count
   #:topic-add-handler
   #:topic-remove-handler
   #:topic-add-validator

   ;; =========================================================================
   ;; Message Types
   ;; =========================================================================
   #:message
   #:make-message
   #:message-p
   #:message-id
   #:message-from
   #:message-data
   #:message-topic
   #:message-seqno
   #:message-timestamp
   #:message-size
   #:compute-message-id
   #:message-id-equal

   ;; Subscription message
   #:subscription-message
   #:make-subscription-message
   #:subscription-message-topic
   #:subscription-message-subscribe-p

   ;; Control messages
   #:control-message
   #:make-control-message
   #:ihave-message
   #:make-ihave-message
   #:ihave-message-topic-id
   #:ihave-message-message-ids
   #:iwant-message
   #:make-iwant-message
   #:iwant-message-message-ids
   #:graft-message
   #:make-graft-message
   #:graft-message-topic-id
   #:prune-message
   #:make-prune-message
   #:prune-message-topic-id
   #:prune-message-peers
   #:prune-message-backoff

   ;; =========================================================================
   ;; Seen Cache
   ;; =========================================================================
   #:seen-cache
   #:make-seen-cache
   #:seen-cache-add
   #:seen-cache-contains-p
   #:seen-cache-prune
   #:seen-cache-clear
   #:seen-cache-size

   ;; =========================================================================
   ;; Peer Management
   ;; =========================================================================
   #:peer
   #:make-peer
   #:peer-p
   #:peer-id
   #:peer-topics
   #:peer-connected-at
   #:peer-messages-sent
   #:peer-messages-received
   #:peer-add-topic
   #:peer-remove-topic
   #:peer-subscribed-p

   ;; =========================================================================
   ;; FloodSub Router
   ;; =========================================================================
   #:floodsub-router
   #:make-floodsub-router
   #:floodsub-router-p
   #:floodsub-router-id
   #:floodsub-router-topics
   #:floodsub-router-peers
   #:floodsub-router-seen-cache
   #:floodsub-router-running-p

   #:floodsub-config
   #:make-floodsub-config
   #:floodsub-config-max-message-size
   #:floodsub-config-seen-cache-size
   #:floodsub-config-seen-cache-ttl
   #:floodsub-config-max-topics
   #:floodsub-config-max-peers-per-topic
   #:floodsub-config-validate-messages

   ;; =========================================================================
   ;; GossipSub Router
   ;; =========================================================================
   #:gossipsub-router
   #:make-gossipsub-router
   #:gossipsub-router-p
   #:gossipsub-router-id
   #:gossipsub-router-config
   #:gossipsub-router-topics
   #:gossipsub-router-mesh
   #:gossipsub-router-fanout
   #:gossipsub-router-peers
   #:gossipsub-router-mcache
   #:gossipsub-router-score-params
   #:gossipsub-router-peer-scores
   #:gossipsub-router-backoff
   #:gossipsub-router-running-p

   #:gossipsub-config
   #:make-gossipsub-config
   #:gossipsub-config-d
   #:gossipsub-config-d-low
   #:gossipsub-config-d-high
   #:gossipsub-config-d-lazy
   #:gossipsub-config-d-out
   #:gossipsub-config-d-score
   #:gossipsub-config-heartbeat-interval
   #:gossipsub-config-fanout-ttl
   #:gossipsub-config-mcache-len
   #:gossipsub-config-mcache-gossip
   #:gossipsub-config-seen-ttl
   #:gossipsub-config-prune-backoff
   #:gossipsub-config-graft-flood-threshold
   #:gossipsub-config-opportunistic-graft-ticks
   #:gossipsub-config-max-ihave-length
   #:gossipsub-config-max-ihave-messages
   #:gossipsub-config-iwant-followup-time
   #:gossipsub-config-flood-publish

   ;; =========================================================================
   ;; Router Operations (shared interface)
   ;; =========================================================================
   #:router-start
   #:router-stop
   #:router-subscribe
   #:router-unsubscribe
   #:router-publish
   #:router-add-peer
   #:router-remove-peer
   #:router-get-topics
   #:router-get-peers
   #:router-get-peers-for-topic
   #:router-is-subscribed-p
   #:router-heartbeat

   ;; =========================================================================
   ;; Message Handling
   ;; =========================================================================
   #:handle-incoming-message
   #:handle-subscription
   #:forward-message
   #:deliver-message

   ;; =========================================================================
   ;; GossipSub Specific Operations
   ;; =========================================================================
   ;; GRAFT/PRUNE
   #:send-graft
   #:send-prune
   #:handle-graft
   #:handle-prune
   #:opportunistic-graft

   ;; IHAVE/IWANT
   #:send-ihave
   #:send-iwant
   #:handle-ihave
   #:handle-iwant
   #:emit-gossip

   ;; =========================================================================
   ;; Mesh Management
   ;; =========================================================================
   #:mesh-state
   #:make-mesh-state
   #:mesh-add-peer
   #:mesh-remove-peer
   #:mesh-get-peers
   #:mesh-size
   #:mesh-needs-peers-p
   #:mesh-has-excess-p
   #:mesh-contains-p

   ;; Backoff
   #:backoff-state
   #:make-backoff-state
   #:add-backoff
   #:in-backoff-p
   #:clear-expired-backoffs

   ;; =========================================================================
   ;; Message Cache
   ;; =========================================================================
   #:message-cache
   #:make-message-cache
   #:mcache-put
   #:mcache-get
   #:mcache-get-gossip-ids
   #:mcache-shift
   #:mcache-has-p

   ;; =========================================================================
   ;; Peer Scoring
   ;; =========================================================================
   #:peer-score-params
   #:make-peer-score-params
   #:peer-score-params-topic-score-cap
   #:peer-score-params-app-specific-weight
   #:peer-score-params-ip-colocation-factor-weight
   #:peer-score-params-ip-colocation-factor-threshold
   #:peer-score-params-behaviour-penalty-weight
   #:peer-score-params-behaviour-penalty-decay
   #:peer-score-params-decay-interval
   #:peer-score-params-decay-to-zero
   #:peer-score-params-retain-score

   #:topic-score-params
   #:make-topic-score-params
   #:topic-score-params-topic-weight
   #:topic-score-params-time-in-mesh-weight
   #:topic-score-params-time-in-mesh-quantum
   #:topic-score-params-time-in-mesh-cap
   #:topic-score-params-first-message-deliveries-weight
   #:topic-score-params-first-message-deliveries-decay
   #:topic-score-params-first-message-deliveries-cap
   #:topic-score-params-mesh-message-deliveries-weight
   #:topic-score-params-mesh-message-deliveries-decay
   #:topic-score-params-mesh-message-deliveries-cap
   #:topic-score-params-mesh-message-deliveries-threshold
   #:topic-score-params-mesh-message-deliveries-activation
   #:topic-score-params-mesh-failure-penalty-weight
   #:topic-score-params-mesh-failure-penalty-decay
   #:topic-score-params-invalid-message-deliveries-weight
   #:topic-score-params-invalid-message-deliveries-decay

   #:peer-score-state
   #:make-peer-score-state
   #:calculate-peer-score
   #:update-peer-score
   #:apply-score-decay

   ;; =========================================================================
   ;; Validation
   ;; =========================================================================
   #:message-validator
   #:make-message-validator
   #:add-topic-validator
   #:remove-topic-validator
   #:validate-message

   #:validation-pipeline
   #:make-validation-pipeline
   #:submit-for-validation
   #:process-validation-result

   ;; =========================================================================
   ;; Metrics & Statistics
   ;; =========================================================================
   #:router-stats
   #:topic-stats
   #:peer-stats
   #:gossipsub-metrics
   #:make-gossipsub-metrics
   #:get-router-metrics
   #:reset-router-metrics

   ;; =========================================================================
   ;; Event Callbacks
   ;; =========================================================================
   #:*on-message-received*
   #:*on-message-sent*
   #:*on-peer-subscribed*
   #:*on-peer-unsubscribed*
   #:*on-validation-failed*
   #:*on-duplicate-message*))

(in-package #:cl-pubsub-gossip)

;;; Package initialization marker
(defvar *pubsub-version* "1.0.0"
  "cl-pubsub-gossip library version.")
