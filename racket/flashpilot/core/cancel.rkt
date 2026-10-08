#lang racket/base

;; Time + cooperative cancellation primitives shared by the transport and
;; protocol layers. A cancel token is a zero-count semaphore: posting it
;; fires every waiter's cancel-evt and requests cooperative abort.

(require racket/format)

(require flashpilot/core/contracts)

(provide make-cancel-token
         cancel-token!
         cancel-token-cancelled?
         cancel-evt)

(struct cancel-token (sema))

(define (make-cancel-token) (cancel-token (make-semaphore 0)))

(define (cancel-token! t)
  (semaphore-post (cancel-token-sema t)))

(define (cancel-token-cancelled? t)
  (and t (sync/timeout 0 (cancel-token-sema t)) #t))

;; A synchronizable event that fires when the token is cancelled.
(define (cancel-evt t)
  (if t
      (handle-evt (semaphore-peek-evt (cancel-token-sema t)) (lambda (_) (void)))
      never-evt))

