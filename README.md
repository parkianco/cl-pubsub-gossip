# cl-pubsub-gossip

Flood-routing pub/sub messaging with GossipSub v1.1 support with **zero external dependencies**.

## Features

- **GossipSub v1.1**: Efficient topic-based gossip
- **Flood publishing**: Reliable message broadcast
- **Peer scoring**: Reputation-based routing
- **Message validation**: Pluggable validators
- **Pure Common Lisp**: No CFFI, no external libraries

## Installation

```lisp
(asdf:load-system :cl-pubsub-gossip)
```

## Quick Start

```lisp
(use-package :cl-pubsub-gossip)

;; Create gossipsub router
(let ((router (make-gossipsub)))
  ;; Subscribe to topic
  (gossipsub-subscribe router "blocks"
                       :handler (lambda (msg)
                                  (process-block msg)))
  ;; Publish message
  (gossipsub-publish router "blocks" *new-block*))
```

## API Reference

### Subscription

- `(make-gossipsub)` - Create GossipSub router
- `(gossipsub-subscribe router topic &key handler)` - Subscribe to topic
- `(gossipsub-unsubscribe router topic)` - Unsubscribe from topic

### Publishing

- `(gossipsub-publish router topic message)` - Publish to topic
- `(gossipsub-validate-message router message)` - Validate message

### Peer Management

- `(gossipsub-add-peer router peer)` - Add peer
- `(gossipsub-remove-peer router peer)` - Remove peer
- `(gossipsub-peer-score router peer)` - Get peer score

## Testing

```lisp
(asdf:test-system :cl-pubsub-gossip)
```

## License

BSD-3-Clause

Copyright (c) 2024-2026 Parkian Company LLC. All rights reserved.
