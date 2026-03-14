;; Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
;; SPDX-License-Identifier: BSD-3-Clause

;;;; -*- Mode: Lisp; Syntax: ANSI-Common-Lisp; Base: 10 -*-
;;;; cl-pubsub-gossip.asd - ASDF system definition
;;;;
;;;; A standalone, pure Common Lisp implementation of flood-routing
;;;; publish-subscribe messaging with GossipSub v1.1 protocol support.
;;;;
;;;; Features:
;;;; - FloodSub: Simple flood-based message propagation
;;;; - GossipSub v1.1: Mesh-based with peer scoring, GRAFT/PRUNE, IHAVE/IWANT
;;;; - Topic subscription and message propagation
;;;; - Thread-safe operations (SBCL sb-thread)
;;;; - No external dependencies beyond SBCL
;;;;
;;;; Copyright (c) 2024
;;;; License: MIT

(asdf:defsystem #:cl-pubsub-gossip
  :name "cl-pubsub-gossip"
  :version "0.1.0"
  :author "Parkian Company LLC"
  :license "MIT"
  :description "Flood-routing pub/sub messaging with GossipSub v1.1 support"
  :long-description "A standalone Common Lisp implementation of publish-subscribe
messaging protocols including FloodSub and GossipSub v1.1. Provides topic-based
subscription, message propagation, peer scoring, mesh management, and message
validation."
  :depends-on ()  ; Pure CL, no dependencies
  :serial t
  :components
  ((:file "package")
   (:module "src"
    :serial t
    :components
    ((:file "util")
     (:file "topic")
     (:file "message")
     (:file "router")
     (:file "gossip")))))

(asdf:defsystem #:cl-pubsub-gossip/test
  :name "cl-pubsub-gossip/test"
  :version "0.1.0"
  :description "Tests for cl-pubsub-gossip"
  :depends-on (#:cl-pubsub-gossip)
  :serial t
  :components
  ((:module "test"
    :components
    ((:file "test-pubsub-gossip")))))
