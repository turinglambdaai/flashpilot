#lang racket/base

;; Declarative flash plans: the portable, AI-authorable artifact at the
;; center of FlashPilot. A plan describes one complete UDS flashing
;; transaction — memory segments, session, security access, erase/verify
;; routines, transport timings — plus hardening options (recovery
;; strategy, in-programming power guard) and the image fingerprint gate.

(require json
         racket/file
         racket/format
         racket/list
         racket/string)

(require flashpilot/core/contracts
         flashpilot/diagnostics/flash/image)

(provide (struct-out uds-flash-plan)
         (struct-out uds-flash-segment)
         (struct-out flash-power-guard)
         (struct-out uds-flash-hardening)
         uds-flash-hardening-plan
         uds-flash-hardening-on-fail
         uds-flash-hardening-power-guard
         uds-flash-hardening-expected-fingerprint
         flash-plan-fingerprint
         read-flash-plan-json
         read-segment-file)

(struct uds-flash-plan
        (segments max-block-payload
                  session
                  security-level
                  key-deriver
                  erase-routine-id
                  verify-routine-id
                  block-retries
                  p2-timeout-ms
                  p2-star-timeout-ms)
  #:transparent)
(struct uds-flash-segment (address data file) #:transparent)

(struct flash-power-guard (min-ma max-ma poll-ms) #:transparent)
(struct uds-flash-hardening (plan on-fail power-guard expected-fingerprint)
  #:transparent)

;; Deterministic FNV-1a over addresses + lengths + data, in plan order.
;; 16 hex chars — a fingerprint, not a crypto hash.
(define (flash-plan-fingerprint segments)
  (define h-box (box #xcbf29ce484222325))
  (define (mix byte)
    (set-box! h-box
              (bitwise-and #xFFFFFFFFFFFFFFFF
                           (* (bitwise-and #xFFFFFFFFFFFFFFFF
                                           (bitwise-xor (unbox h-box) byte))
                              #x100000001b3))))
  (for ([seg (in-list segments)])
    (mix (bitwise-and (uds-flash-segment-address seg) #xFF))
    (for ([shift (in-range 8 64 8)])
      (mix (bitwise-and (arithmetic-shift (uds-flash-segment-address seg)
                                          (- shift))
                        #xFF)))
    (define data (uds-flash-segment-data seg))
    (mix (length data))
    (for ([b (in-list data)]) (mix b)))
  (substring (~r (unbox h-box) #:base 16 #:min-width 16 #:pad-string "0") 0 16))

;; Parses a plan JSON document into plan + hardening. The plan struct is
;; the engine-facing part; hardening carries onFail / powerGuard /
;; expectedFingerprint.
(define (read-flash-plan-json text)
  (define doc
    (with-handlers ([exn:fail? (lambda (e)
                                 (raise-validation (format "Invalid flash plan JSON: ~a"
                                                           (exn-message e))))])
      (read-json (open-input-string text))))
  (unless (hash? doc)
    (raise-validation "Invalid flash plan JSON: expected an object."))
  (define segments-raw (hash-ref doc 'segments #f))
  (define segments
    (if (list? segments-raw)
        (for/list ([seg (in-list segments-raw)])
          (unless (hash? seg)
            (raise-validation "Invalid flash plan segment: expected an object."))
          (define (address-value v)
            (cond
              [(exact-integer? v) v]
              [(and (string? v) (string-prefix? (string-downcase v) "0x"))
               (or (string->number (substring v 2) 16)
                   (raise-validation (format "Invalid segment address '~a'." v)))]
              [(string? v)
               (or (string->number v)
                   (raise-validation (format "Invalid segment address '~a'." v)))]
              [else (raise-validation (format "Invalid segment address '~a'." v))]))
          (uds-flash-segment
           (address-value
            (hash-ref seg
                      'address
                      (lambda () (raise-validation "Flash plan segment is missing 'address'."))))
           (let ([data (hash-ref seg 'data #f)])
             (cond
               [(string? data) (hex-parse data)]
               [(list? data) (map (lambda (x) (if (exact-integer? x) x 0)) data)]
               [else #f]))
           (hash-ref seg 'file #f)))
        '()))
  (define plan
    (uds-flash-plan segments
                    (or (hash-ref doc 'maxBlockPayload #f) 1024)
                    (or (hash-ref doc 'session #f) #x02)
                    (hash-ref doc 'securityLevel #f)
                    (hash-ref doc 'keyDeriver #f)
                    (or (hash-ref doc 'eraseRoutineId #f) #xFF00)
                    (or (hash-ref doc 'verifyRoutineId #f) #xFF01)
                    (or (hash-ref doc 'blockRetries #f) 0)
                    (or (hash-ref doc 'p2TimeoutMs #f) 1000)
                    (or (hash-ref doc 'p2StarTimeoutMs #f) 10000)))
  (define on-fail-raw (hash-ref doc 'onFail #f))
  (define on-fail
    (cond
      [(not on-fail-raw) #f]
      [(member on-fail-raw '("retry" "resetAndRetry") string-ci=?)
       => (lambda (m) (string->symbol (first m)))]
      [else
       (raise-validation
        (format "Flash plan onFail must be 'retry' or 'resetAndRetry' (got '~a')." on-fail-raw))]))
  (define guard-raw (hash-ref doc 'powerGuard #f))
  (define power-guard
    (and guard-raw
         (begin
           (unless (hash? guard-raw)
             (raise-validation "Flash plan powerGuard must be an object."))
           (flash-power-guard
            (hash-ref guard-raw 'minMa #f)
            (hash-ref guard-raw 'maxMa #f)
            (or (hash-ref guard-raw 'pollMs #f) 200)))))
  (uds-flash-hardening plan on-fail power-guard (hash-ref doc 'expectedFingerprint #f)))

(define (read-segment-file file base-directory)
  (when (or (not file) (string-blank? file))
    (raise-validation "Flash plan segment has no data and no file reference."))
  (define path
    (if (or (absolute-path? file) (regexp-match? #rx"^[A-Za-z]:" file))
        file
        (path->string (build-path base-directory file))))
  (unless (file-exists? path)
    (raise-validation (format "Flash plan segment file not found: ~a" path)))
  (file->bytes path))
