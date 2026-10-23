#lang racket/base

;; ISO-TP over LIN endpoint: segmentation and reassembly of UDS payloads
;; across 0x3C/0x3D diagnostic frames. There is no flow control — the
;; master paces every frame by the configured gap, so a sender streams its
;; windows and a receiver reassembles whatever arrives for its NAD.

(require racket/contract
         racket/list)

(require flashpilot/core/contracts
         flashpilot/core/cancel
         flashpilot/diagnostics/isotp/codec
         flashpilot/diagnostics/isotp/lin-tp
         flashpilot/diagnostics/transport/can-bus)

(provide (struct-out lin-endpoint)
         (struct-out lin-options)
         (struct-out exn:fail:lin)
         make-lin-endpoint
         lin-endpoint-send!
         lin-endpoint-receive!
         lin-endpoint-dispose!)

(struct exn:fail:lin exn:fail () #:transparent)
(define (lin-error message)
  (raise (exn:fail:lin message (current-continuation-marks))))

(struct lin-options (frame-gap-ms poll-seconds) #:transparent)

;; tx-frame-id/rx-frame-id: 0x3C for the master's transmit direction,
;; 0x3D for the master's receive direction (the slave mirrors them).
(struct lin-endpoint (bus nad tx-frame-id rx-frame-id
                          options received-sema received-box
                          rx-box ; #(vector buffer length offset expected-seq)
                          send-gate listener)
  #:transparent)

(define (make-lin-endpoint bus nad tx-frame-id rx-frame-id
                           [options (lin-options 10 0.002)])
  (define ep-box (box #f))
  (define ep
    (lin-endpoint bus nad tx-frame-id rx-frame-id options
                  (make-semaphore 0)
                  (box #f)
                  (box (vector #f 0 0 1))
                  (make-semaphore 1)
                  (lambda (frame) (on-frame-received! (unbox ep-box) frame))))
  (set-box! ep-box ep)
  (can-bus-on-frame! bus (lin-endpoint-listener ep))
  ep)

(define (lin-endpoint-dispose! ep)
  (can-bus-on-frame! (lin-endpoint-bus ep) #f))

(define (send-frame! ep frame-id body)
  (define id
    (if (eq? frame-id lin-frame-master-req)
        lin-frame-master-req
        lin-frame-slave-resp))
  (can-bus-send! (lin-endpoint-bus ep)
                 (can-frame id (> id #x7FF) body)))

(define (lin-frame-gap-seconds ep)
  (/ (lin-options-frame-gap-ms (lin-endpoint-options ep)) 1000.0))

;; Segment one UDS payload into 0x3C/0x3D windows and stream them. No flow
;; control: the gap IS the pacing contract.
(define (lin-endpoint-send! ep payload #:cancel [cancel #f])
  (when (null? payload)
    (raise-argument-error 'lin-endpoint-send! "non-empty UDS payload" payload))
  (semaphore-wait/enable-break (lin-endpoint-send-gate ep))
  (dynamic-wind
      (lambda () (void))
      (lambda ()
        (define gap (lin-frame-gap-seconds ep))
        (define total (length payload))
        (define (window-at offset)
          (take (list-tail payload offset)
                (min lin-window-size (- total offset))))
        (cond
          [(<= total lin-window-size)
           (send-frame! ep (lin-endpoint-tx-frame-id ep)
                        (lin-encode-frame 'single (lin-endpoint-nad ep) payload))]
          [else
           (send-frame! ep (lin-endpoint-tx-frame-id ep)
                        (lin-encode-first (lin-endpoint-nad ep) total
                                          (take payload 4)))
           (when (> gap 0) (cancel-wait* cancel gap))
           (let loop ([offset 4] [sequence 1])
             (when (< offset total)
               (send-frame! ep (lin-endpoint-tx-frame-id ep)
                            (lin-encode-frame 'consecutive
                                              (lin-endpoint-nad ep)
                                              (window-at offset)
                                              sequence))
               (when (> gap 0) (cancel-wait* cancel gap))
               (loop (+ offset lin-window-size)
                     (bitwise-and (+ sequence 1) #x0F))))]))
      (lambda () (semaphore-post (lin-endpoint-send-gate ep)))))

(define (cancel-wait* cancel seconds)
  (when cancel
    (when (sync/timeout seconds (cancel-evt cancel))
      (raise (make-cancelled-error)))))

;; Polls for the next complete payload addressed to this endpoint.
(define (lin-endpoint-receive! ep #:cancel [cancel #f])
  (let loop ()
    (cond
      [(unbox (lin-endpoint-received-box ep))
       =>
       (lambda (received)
         (define payload (car received))
         (set-box! (lin-endpoint-received-box ep)
                   (let ([rest (cdr received)]) (if (null? rest) #f rest)))
         payload)]
      [else
       (define poll (lin-options-poll-seconds (lin-endpoint-options ep)))
       (when cancel
         (when (sync/timeout poll (cancel-evt cancel))
           (raise (make-cancelled-error))))
       (unless cancel (sleep poll))
       (loop)])))

(define (enqueue-received! ep payload)
  (define b (lin-endpoint-received-box ep))
  (set-box! b (append (or (unbox b) '()) (list payload))))

(define (reset-receive! ep)
  (set-box! (lin-endpoint-rx-box ep) (vector #f 0 0 1)))

;; The slave never waits for a flow control; every reassembled payload is
;; delivered as soon as the last window lands.
(define (on-frame-received! ep frame)
  (unless (= (can-frame-id frame) (lin-endpoint-rx-frame-id ep))
    (void))
  (when (= (can-frame-id frame) (lin-endpoint-rx-frame-id ep))
    (define decoded (lin-try-decode (can-frame-data frame)))
    (when decoded
      (define rs (lin-endpoint-rx-box ep))
      (case (lin-frame-type decoded)
        [(single)
         (reset-receive! ep)
         (enqueue-received! ep (lin-frame-payload decoded))]
        [(first)
         (reset-receive! ep)
         (define total (lin-frame-sequence decoded)) ; PCI carries the length
         (define prefix (lin-frame-payload decoded))
         (when (> total (length prefix))
           (set-box! rs
                     (vector (make-bytes total 0)
                             total
                             (length prefix)
                             1))
           (for ([b (in-list prefix)]
                 [i (in-naturals)])
             (bytes-set! (vector-ref (unbox rs) 0) i b)))]
        [(consecutive)
         (define state (unbox rs))
         (when (vector-ref state 0)
           (define expected (vector-ref state 3))
           (if (not (= (lin-frame-sequence decoded) expected))
               ;; Desynchronized: drop; the next single/first frame re-arms.
               (reset-receive! ep)
               (let* ([buffer (vector-ref state 0)]
                      [remaining (- (vector-ref state 1) (vector-ref state 2))]
                      [take (min remaining (length (lin-frame-payload decoded)))])
                 (for ([b (in-list (lin-frame-payload decoded))]
                       [i (in-range take)])
                   (bytes-set! buffer (+ (vector-ref state 2) i) b))
                 (define next-offset (+ (vector-ref state 2) take))
                 (set-box! rs (vector buffer
                                      (vector-ref state 1)
                                      next-offset
                                      (bitwise-and (+ expected 1) #x0F)))
                 (when (>= next-offset (vector-ref state 1))
                   (define done buffer)
                   (reset-receive! ep)
                   (enqueue-received! ep (bytes->list done))))))]))))
