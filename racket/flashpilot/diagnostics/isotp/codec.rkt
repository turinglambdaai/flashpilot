#lang racket/base

;; IsotpCodec.cs port: ISO 15765-2 frames on classic 8-byte CAN and CAN FD,
;; standard addressing. SF escape, the FF escape for lengths over 4095 and
;; CAN FD data lengths (8..64) are supported; every encode entry point takes
;; an optional dlen (default 8) and classic behavior is bit-identical at 8.

(require racket/contract
         racket/format
         racket/list
         racket/math)

(require flashpilot/core/contracts)

(provide (struct-out isotp-frame)
         isotp-frame-type?
         flow-control-status?
         classic-data-length
         can-fd-next-dlen
         can-fd-dlen?
         try-decode-frame
         encode-single
         encode-first-prefix
         encode-consecutive
         encode-flow-control
         encode-st-min
         decode-st-min
         (struct-out can-frame))

;; ----------------------------------------------------------------------------
;; Model
;; ----------------------------------------------------------------------------

(struct isotp-frame (type sequence payload flow-status block-size st-min-ms) #:transparent)
(struct can-frame (id extended? data) #:transparent)

;; frame types: 'single 'first 'consecutive 'flow-control
(define (isotp-frame-type? v)
  (memq v '(single first consecutive flow-control)))
;; flow statuses: 'continue-to-send 'wait 'overflow
(define (flow-control-status? v)
  (memq v '(continue-to-send wait overflow)))

(define classic-data-length 8)
(define type-mask #xF0)
(define nibble-mask #x0F)

;; Legal CAN FD data lengths, ascending; a frame's dlen is one of these.
(define can-fd-data-lengths '(8 12 16 20 24 32 48 64))

(define (can-fd-dlen? v)
  (and (member v can-fd-data-lengths) #t))

;; Smallest legal CAN FD data length >= n (8 stays 8; 65+ is an error).
(define (can-fd-next-dlen n)
  (or (for/first ([d (in-list can-fd-data-lengths)] #:when (<= n d)) d)
      (raise-argument-error 'can-fd-next-dlen "n at most 64" n)))

;; ----------------------------------------------------------------------------
;; Decode
;; ----------------------------------------------------------------------------

(define (try-decode-frame data #:fd? [fd? #f])
  (cond
    [(null? data) #f]
    [else
     (define pci (car data))
     (case (arithmetic-shift (bitwise-and pci type-mask) -4)
       [(0)
        ;; Single frame; zero length nibble escapes. On CAN FD the escape is
        ;; [0x00][DL] with DL in 8..62; on classic the project's 12-bit form
        ;; [0x00][HI][LO] is kept for compatibility.
        (define nibble (bitwise-and pci nibble-mask))
        (cond
          [(not (zero? nibble))
           (define len nibble)
           (if (< (length data) (add1 len))
               #f
               (isotp-frame 'single 0 (take (cdr data) len) #f 0 0))]
          [fd?
           (cond
             [(< (length data) 2) #f]
             [else
              (define len (second data))
              (cond
                [(or (< len 8) (> len 62) (< (length data) (+ 2 len))) #f]
                [else (isotp-frame 'single 0 (take (list-tail data 2) len) #f 0 0)])])]
          [else
           (cond
             [(< (length data) 2) #f]
             [else
              (define len
                (bitwise-ior (arithmetic-shift (bitwise-and (second data) nibble-mask) 8)
                             (third data)))
              (cond
                [(or (zero? len) (< (length data) (+ 3 len))) #f]
                [else (isotp-frame 'single 0 (take (list-tail data 3) len) #f 0 0)])])])]
       [(1)
        ;; First frame; the escaped form is exactly 0x10 0x00 + 32-bit length.
        (define short-form?
          (or (not (zero? (bitwise-and pci nibble-mask)))
              (and (> (length data) 1) (not (zero? (second data))))))
        (if short-form?
            (if (< (length data) 2)
                #f
                (isotp-frame 'first 0 (drop data 2) #f 0 0))
            (if (< (length data) 6)
                #f
                (isotp-frame 'first 0 (drop data 6) #f 0 0)))]
       [(2)
        (if (< (length data) 2)
            #f
            (isotp-frame 'consecutive (bitwise-and pci nibble-mask) (cdr data) #f 0 0))]
       [(3)
        (cond
          [(< (length data) 3) #f]
          [else
           (define status-nibble (bitwise-and pci nibble-mask))
           (define status
             (case status-nibble
               [(0) 'continue-to-send]
               [(1) 'wait]
               [(2) 'overflow]
               [else #f]))
           (if (not status)
               #f
               (isotp-frame 'flow-control 0 '() status (second data) (decode-st-min (third data))))])]
       [else #f])]))

;; ----------------------------------------------------------------------------
;; Encode
;; ----------------------------------------------------------------------------

;; Pad/truncate a frame's data list to exactly dlen bytes.
(define (pad-to frame dlen)
  (take (append frame (make-list dlen 0)) dlen))

(define (encode-single payload [dlen classic-data-length])
  (cond
    [(> dlen classic-data-length)
     ;; CAN FD: 1..7 short form, 8..62 the standard single-byte escape.
     (cond
       [(<= (length payload) 7) (pad-to (cons (length payload) payload) dlen)]
       [(<= (length payload) 62)
        (pad-to (append (list #x00 (length payload)) payload) dlen)]
       [else
        (raise-argument-error
         'encode-single
         "CAN FD single frames carry at most 62 bytes; use first/consecutive frames"
         payload)])]
    [(<= (length payload) 7)
     (pad-to (cons (length payload) payload) dlen)]
    [else
     (raise-argument-error
      'encode-single
      "payload of at most 7 bytes (classic CAN single frames); use first/consecutive frames"
      payload)]))

(define (encode-first-prefix payload [dlen classic-data-length])
  (define n (length payload))
  (if (<= n 4095)
      (pad-to (append (list (bitwise-ior #x10 (arithmetic-shift (bitwise-and n #x0F00) -8))
                            (bitwise-and n #xFF))
                      (take payload (min (- dlen 2) n))
                      (make-list dlen 0))
              dlen)
      (pad-to (append (list #x10
                            #x00
                            (bitwise-and (arithmetic-shift n -24) #xFF)
                            (bitwise-and (arithmetic-shift n -16) #xFF)
                            (bitwise-and (arithmetic-shift n -8) #xFF)
                            (bitwise-and n #xFF))
                      (take payload (min (- dlen 6) n))
                      (make-list dlen 0))
              dlen)))

(define (encode-consecutive sequence chunk [dlen classic-data-length])
  (pad-to (cons (bitwise-ior #x20 (bitwise-and sequence nibble-mask))
                (take chunk (min (length chunk) (sub1 dlen))))
          dlen))

(define (encode-flow-control status block-size st-min-ms [dlen classic-data-length])
  (define status-nibble
    (case status
      [(continue-to-send) 0]
      [(wait) 1]
      [(overflow) 2]
      [else (raise-argument-error 'encode-flow-control "flow-control-status?" status)]))
  (pad-to (list (bitwise-ior #x30 status-nibble) block-size (encode-st-min st-min-ms))
          dlen))

;; ----------------------------------------------------------------------------
;; STmin: 0x00-0x7F milliseconds, 0xF1-0xF9 hundreds of microseconds.
;; ----------------------------------------------------------------------------

(define (encode-st-min st-min-ms)
  (cond
    [(<= st-min-ms 0) #x00]
    [(< st-min-ms 1)
     (define hundreds-of-us (exact-round (* st-min-ms 10)))
     (+ #xF0 (min (max hundreds-of-us 1) 9))]
    [else (min (exact-round st-min-ms) #x7F)]))

(define (decode-st-min value)
  (cond
    [(and (>= value #xF1) (<= value #xF9)) (* (- value #xF0) 0.1)]
    [(<= value #x7F) value]
    [else 0]))
