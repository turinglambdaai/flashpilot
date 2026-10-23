#lang racket/base

;; ISO-TP over LIN — diagnostic framing per ISO 17987-3 (LIN 2.x diagnostic
;; frames 0x3C MasterReq / 0x3D SlaveResp). Each frame carries
;; [NAD][PCI][data...]: one node-address byte, one PCI byte, then a 6-byte
;; payload window. There is no flow control on LIN — the master paces the
;; schedule, so the encoder never emits FC and the receiver never waits
;; for one.

(require racket/contract
         racket/list)

(provide lin-window-size
         lin-frame-master-req
         lin-frame-slave-resp
         lin-encode-frame
         lin-encode-first
         lin-try-decode
         (struct-out lin-frame))

;; Frame ids on the wire (bus-generic transports carry them like CAN ids).
(define lin-frame-master-req #x3C)
(define lin-frame-slave-resp #x3D)

;; 8-byte diagnostic frame = NAD + PCI + 6 payload bytes.
(define lin-window-size 6)

(struct lin-frame (type sequence payload) #:transparent)

;; ---- encode ---------------------------------------------------------------

;; kind: 'single | 'first | 'consecutive; payload is the window content
;; (already sliced to <= 6 bytes by the caller; first frames carry 4).
(define (lin-encode-frame kind nad payload [sequence 0])
  (unless (<= (length payload) lin-window-size)
    (raise-argument-error 'lin-encode-frame
                          (format "payload window of at most ~a bytes" lin-window-size)
                          payload))
  (define pci
    (case kind
      [(single) (length payload)]
      [(consecutive)
       (bitwise-ior #x20 (bitwise-and sequence #x0F))]
      [else (raise-argument-error 'lin-encode-frame "'single or 'consecutive" kind)]))
  (append (list nad pci) payload
          (make-list (- lin-window-size (length payload)) #xFF)))

;; First frames embed the total length: PCI = 0x10 | (total >> 8), then the
;; low byte, then up to 4 payload bytes.
(define (lin-encode-first nad total payload)
  (unless (<= (length payload) 4)
    (raise-argument-error 'lin-encode-first "first frame window of 4 bytes" payload))
  ;; the window holds the length low byte + up to 4 data bytes
  (append (list nad
                (bitwise-ior #x10 (arithmetic-shift (bitwise-and total #x0F00) -8))
                (bitwise-and total #xFF))
          payload
          (make-list (- (sub1 lin-window-size) (length payload)) #xFF)))

;; Decode one diagnostic frame's data bytes (the whole 8-byte LIN frame:
;; NAD, PCI, window). Returns #f for anything not diagnostic-shaped.
(define (lin-try-decode data)
  (cond
    [(or (< (length data) 2) (> (length data) (+ 2 lin-window-size))) #f]
    [else
     (define nad (car data))
     (define pci (cadr data))
     (define window (cddr data))
     (define type (arithmetic-shift (bitwise-and pci #xF0) -4))
     (cond
       [(= type 0)
        (define len (bitwise-and pci #x0F))
        (cond
          [(or (zero? len) (> len lin-window-size) (< (length window) len)) #f]
          [else (lin-frame 'single 0 (take window len))])]
       [(= type 1)
        (cond
          [(< (length window) 5) #f]
          [else
           (define total
             (bitwise-ior (arithmetic-shift (bitwise-and pci #x0F) 8)
                          (list-ref window 0)))
           (lin-frame 'first total (take (cdr window) 4))])]
       [(= type 2)
        (lin-frame 'consecutive (bitwise-and pci #x0F) window)]
       [else #f])]))
