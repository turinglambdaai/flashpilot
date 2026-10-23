#lang racket/base

;; SocketCanBus.cs port: SocketCAN transport (Linux). One raw CAN socket
;; bound to one interface. Frame layout is the kernel's struct can_frame;
;; the diagnostic stack owns everything above the frame layer.
;;
;; The libc bindings load lazily at first bus use (SocketCAN is Linux-only)
;; so this module is importable everywhere; the wire-frame encode/decode is
;; pure and unit-tested on every platform.

(require ffi/unsafe
         racket/generic)

(require flashpilot/core/contracts
         flashpilot/diagnostics/isotp/codec
         flashpilot/diagnostics/transport/can-bus)

(provide (struct-out socketcan-bus)
         make-socketcan-bus
         can-frame-encode
         can-frame-try-decode
         canfd-frame-encode)

(define pf-can 29)
(define sock-raw 3)
(define can-frame-size 16)
(define canfd-frame-size 72)
(define can-fd-max-data 64)
(define can-eff-flag #x80000000)
(define can-rtr-flag #x40000000)
(define siocgifindex #x8933)
(define sol-socket 1)
(define so-rcvtimeo 20)
(define sol-can-raw 1)
(define can-raw-fd-frames 5)

;; ----------------------------------------------------------------------------
;; Wire-frame codec (kernel struct can_frame, little-endian)
;; ----------------------------------------------------------------------------

(define (can-frame-encode frame)
  (define buf (make-bytes can-frame-size 0))
  (define id (can-frame-id frame))
  (define wire-id
    (if (can-frame-extended? frame) (bitwise-ior id can-eff-flag) id))
  (bytes-set! buf 0 (bitwise-and wire-id #xFF))
  (bytes-set! buf 1 (bitwise-and (arithmetic-shift wire-id -8) #xFF))
  (bytes-set! buf 2 (bitwise-and (arithmetic-shift wire-id -16) #xFF))
  (bytes-set! buf 3 (bitwise-and (arithmetic-shift wire-id -24) #xFF))
  (define data (can-frame-data frame))
  (bytes-set! buf 4 (length data))
  (for ([b (in-list data)]
        [i (in-naturals)])
    (bytes-set! buf (+ 8 i) b))
  buf)

;; Returns a (can-frame ...) or #f for RTR frames and illegal DLCs. A
;; 16-byte buffer decodes as struct can_frame, a 72-byte one as
;; struct canfd_frame (len @4 is the byte count, up to 64).
(define (can-frame-try-decode buf [n (bytes-length buf)])
  (define raw-id (+ (bytes-ref buf 0)
                    (* (bytes-ref buf 1) 256)
                    (* (bytes-ref buf 2) 65536)
                    (* (bytes-ref buf 3) 16777216)))
  (cond
    [(= n canfd-frame-size)
     (define len (bytes-ref buf 4))
     (cond
       [(> len can-fd-max-data) #f]
       [(not (zero? (bitwise-and raw-id can-rtr-flag))) #f]
       [else
        (can-frame (bitwise-and raw-id (bitwise-not can-eff-flag))
                   (not (zero? (bitwise-and raw-id can-eff-flag)))
                   (for/list ([i (in-range len)]) (bytes-ref buf (+ 8 i))))])]
    [else
     (define dlc (bytes-ref buf 4))
     (cond
       [(> dlc 8) #f]
       [(not (zero? (bitwise-and raw-id can-rtr-flag))) #f]
       [else
        (can-frame (bitwise-and raw-id (bitwise-not (bitwise-ior can-eff-flag can-rtr-flag)))
                   (not (zero? (bitwise-and raw-id can-eff-flag)))
                   (for/list ([i (in-range dlc)]) (bytes-ref buf (+ 8 i))))])]))

;; struct canfd_frame: id u32le, len u8, flags u8, two reserved bytes,
;; then up to 64 payload bytes. len is the byte count (not a DLC code).
(define (canfd-frame-encode frame)
  (define data (can-frame-data frame))
  (when (> (length data) can-fd-max-data)
    (raise-validation (format "CAN FD frames carry at most ~a data bytes."
                              can-fd-max-data)))
  (define buf (make-bytes canfd-frame-size 0))
  (define id (can-frame-id frame))
  (define wire-id
    (if (can-frame-extended? frame) (bitwise-ior id can-eff-flag) id))
  (bytes-set! buf 0 (bitwise-and wire-id #xFF))
  (bytes-set! buf 1 (bitwise-and (arithmetic-shift wire-id -8) #xFF))
  (bytes-set! buf 2 (bitwise-and (arithmetic-shift wire-id -16) #xFF))
  (bytes-set! buf 3 (bitwise-and (arithmetic-shift wire-id -24) #xFF))
  (bytes-set! buf 4 (length data))
  (bytes-set! buf 5 0) ; flags: no BRS/ESI (correctness first)
  (for ([b (in-list data)]
        [i (in-naturals)])
    (bytes-set! buf (+ 8 i) b))
  buf)

;; ----------------------------------------------------------------------------
;; Bus
;; ----------------------------------------------------------------------------

(struct socketcan-bus (interface-name canfd? mutex fd-box listener-box pump-thread-box stop-box)
  #:methods gen:can-bus
  [(define (can-bus-name b) (socketcan-bus-interface-name b))
   (define (can-bus-open! b) (socketcan-open! b))
   (define (can-bus-send! b frame) (socketcan-send! b frame))
   (define (can-bus-on-frame! b listener) (set-box! (socketcan-bus-listener-box b) listener))
   (define (can-bus-dispose! b) (socketcan-dispose! b))])

(define (make-socketcan-bus interface-name #:canfd? [canfd? #f])
  (unless (and (eq? (system-path-convention-type) 'unix)
               (not (regexp-match? #rx"macosx" (format "~a" (system-library-subpath)))))
    (raise-argument-error 'make-socketcan-bus "SocketCAN requires Linux" interface-name))
  (socketcan-bus interface-name
                 canfd?
                 (make-semaphore 1)
                 (box #f)
                 (box #f)
                 (box #f)
                 (box #f)))

(define (with-bus-mutex bus proc)
  (semaphore-wait/enable-break (socketcan-bus-mutex bus))
  (dynamic-wind
 (lambda () (void))
 proc
 (lambda () (semaphore-post (socketcan-bus-mutex bus)))))

;; ----------------------------------------------------------------------------
;; libc bindings (lazy, cached; errno is read right after a failing call)
;; ----------------------------------------------------------------------------

(struct socketcan-ffi (socket ioctl bind send recv close setsockopt errno-box))

(define ffi-box (box #f))

(define (socketcan-ffi*)
  (or (unbox ffi-box)
      (let ([f (load-socketcan-ffi!)])
        (set-box! ffi-box f)
        f)))

;; errno captured by the immediately preceding foreign call.
(define (last-errno-text ffi)
  (with-handlers ([exn:fail? (lambda (_) "unknown errno")])
    (format "errno ~a" (lookup-errno (unbox (socketcan-ffi-errno-box ffi))))))

(define (load-socketcan-ffi!)
  (define lib (ffi-lib "libc.so.6"))
  (define errno-box (box 0))
  (socketcan-ffi
   (get-ffi-obj "socket" lib (_fun #:save-errno errno-box _int _int _int -> _int))
   (get-ffi-obj "ioctl" lib (_fun #:save-errno errno-box _int _uint _pointer -> _int))
   (get-ffi-obj "bind" lib (_fun #:save-errno errno-box _int _pointer _int -> _int))
   (get-ffi-obj "send" lib (_fun #:save-errno errno-box _int _bytes _int _int -> _int))
   (get-ffi-obj "recv" lib (_fun #:save-errno errno-box _int _bytes _int _int -> _int))
   (get-ffi-obj "close" lib (_fun #:save-errno errno-box _int -> _int))
   (get-ffi-obj "setsockopt" lib
                (_fun #:save-errno errno-box _int _int _int _pointer _int -> _int))
   errno-box))

;; ----------------------------------------------------------------------------
;; Lifecycle
;; ----------------------------------------------------------------------------

(define (socketcan-open! bus)
  (with-bus-mutex
   bus
   (lambda ()
     (unless (unbox (socketcan-bus-fd-box bus))
       (define ffi (socketcan-ffi*))
       (define fd ((socketcan-ffi-socket ffi) pf-can sock-raw 0))
       (when (< fd 0)
         (raise (exn:fail (format "SocketCAN: socket() failed (~a)."
                                  (last-errno-text ffi))
                          (current-continuation-marks))))
       (define ifr (make-bytes 40 0))
       (define name-bytes (string->bytes/utf-8 (socketcan-bus-interface-name bus)))
       (when (> (bytes-length name-bytes) 15)
         ((socketcan-ffi-close ffi) fd)
         (raise (exn:fail (format "SocketCAN: interface name '~a' is too long."
                                  (socketcan-bus-interface-name bus))
                          (current-continuation-marks))))
       (bytes-copy! ifr 0 name-bytes)
       (when (< ((socketcan-ffi-ioctl ffi) fd siocgifindex ifr) 0)
         ((socketcan-ffi-close ffi) fd)
         (raise (exn:fail
                 (format
                  "SocketCAN: interface '~a' not found (~a). Bring the interface up first, for example: sudo ip link set can0 up type can bitrate 500000"
                  (socketcan-bus-interface-name bus)
                  (last-errno-text ffi))
                 (current-continuation-marks))))
       (define ifindex (ptr-ref ifr _sint32 4))
       (define addr (make-bytes 16 0))
       (integer->integer-bytes pf-can 2 #t #f addr 0)
       (integer->integer-bytes ifindex 4 #f #f addr 4)
       (when (< ((socketcan-ffi-bind ffi) fd addr 16) 0)
         ((socketcan-ffi-close ffi) fd)
         (raise (exn:fail (format "SocketCAN: bind failed (~a)." (last-errno-text ffi))
                          (current-continuation-marks))))
       (when (socketcan-bus-canfd? bus)
         (define one (make-bytes 4 0))
         (bytes-set! one 0 1)
         (when (< ((socketcan-ffi-setsockopt ffi) fd sol-can-raw can-raw-fd-frames one 4) 0)
           ((socketcan-ffi-close ffi) fd)
           (raise (exn:fail (format "SocketCAN: enabling CAN FD frames failed (~a)."
                                    (last-errno-text ffi))
                            (current-continuation-marks)))))
       ;; SO_RCVTIMEO bounds each blocking recv so the pump notices stop.
       (define tv (make-bytes 16 0))
       (integer->integer-bytes 0 8 #t #f tv 0)
       (integer->integer-bytes 200000 8 #t #f tv 8)
       ((socketcan-ffi-setsockopt ffi) fd sol-socket so-rcvtimeo tv 16)
       (set-box! (socketcan-bus-fd-box bus) fd)
       (set-box! (socketcan-bus-stop-box bus) #f)
       (set-box! (socketcan-bus-pump-thread-box bus)
                 (thread (lambda () (pump bus fd))))))))

(define (pump bus fd)
  (define ffi (socketcan-ffi*))
  (define buf (make-bytes canfd-frame-size 0))
  (let loop ()
    (cond
      [(unbox (socketcan-bus-stop-box bus)) (void)]
      [else
       (define n
         ((socketcan-ffi-recv ffi) fd buf
                                  (if (socketcan-bus-canfd? bus)
                                      canfd-frame-size
                                      can-frame-size)
                                  0))
       (cond
         [(unbox (socketcan-bus-stop-box bus)) (void)]
         [(>= n can-frame-size)
          (define frame (can-frame-try-decode buf n))
          (when frame
            (define listener (unbox (socketcan-bus-listener-box bus)))
            (when listener (listener frame)))
          (loop)]
         [else (loop)])])))

(define (socketcan-send! bus frame)
  (define fd (unbox (socketcan-bus-fd-box bus)))
  (unless fd
    (raise (exn:fail "SocketCAN: bus is not open." (current-continuation-marks))))
  (define data-len (length (can-frame-data frame)))
  (cond
    [(and (not (socketcan-bus-canfd? bus)) (> data-len 8))
     (raise-validation "Classic CAN frames carry at most 8 data bytes.")]
    [(or (socketcan-bus-canfd? bus) (> data-len 8))
     (define buf (canfd-frame-encode frame))
     (define ffi (socketcan-ffi*))
     (when (< ((socketcan-ffi-send ffi) fd buf canfd-frame-size 0) 0)
       (raise (exn:fail (format "SocketCAN: send failed (~a)." (last-errno-text ffi))
                        (current-continuation-marks))))]
    [else
     (define buf (can-frame-encode frame))
     (define ffi (socketcan-ffi*))
     (when (< ((socketcan-ffi-send ffi) fd buf can-frame-size 0) 0)
       (raise (exn:fail (format "SocketCAN: send failed (~a)." (last-errno-text ffi))
                        (current-continuation-marks))))]))

(define (socketcan-dispose! bus)
  (set-box! (socketcan-bus-stop-box bus) #t)
  (define pump-thread (unbox (socketcan-bus-pump-thread-box bus)))
  (when pump-thread
    (sync/timeout 1.5 (thread-dead-evt pump-thread)))
  (define fd (unbox (socketcan-bus-fd-box bus)))
  (when fd
    (with-handlers ([exn:fail? (lambda (_) (void))])
      ((socketcan-ffi-close (socketcan-ffi*)) fd))
    (set-box! (socketcan-bus-fd-box bus) #f)))
