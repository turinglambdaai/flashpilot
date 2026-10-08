#lang racket/base

;; FlashPilot CLI — the agent-first interface to the flashing engine.
;; Deterministic JSON, exit codes that never lie, safe by default.

(require json
         racket/file
         racket/format
         racket/list
         racket/port
         racket/string)

(require flashpilot/core/contracts
         (only-in flashpilot/diagnostics/flash/engine exn:fail:flash?)
         flashpilot/diagnostics/channels/sim-uds-channel
         flashpilot/diagnostics/doip/doip
         flashpilot/diagnostics/flash/plans
         flashpilot/diagnostics/uds/protocol)

;; ----------------------------------------------------------------------------
;; Output + errors
;; ----------------------------------------------------------------------------

(define (print-result jsexpr)
  (write-json jsexpr)
  (newline))

(struct cli-error (code message exit-code) #:transparent)

(define (fail code message exit-code)
  (print-result (hasheq 'ok #f 'code code 'error message))
  (exit exit-code))

;; ----------------------------------------------------------------------------
;; Args: `--opt value` pairs; bare positionals collected under 'args
;; ----------------------------------------------------------------------------

(define (args->hash argv)
  (define h (make-hasheq))
  (define pos '())
  (let loop ([rest argv])
    (cond
      [(null? rest) (hash-set! h 'args (reverse pos)) h]
      [(string-prefix? (car rest) "--")
       (define name (string->symbol (substring (car rest) 2)))
       (cond
         [(and (pair? (cdr rest)) (not (string-prefix? (cadr rest) "--")))
          (hash-set! h name (cadr rest))
          (loop (cddr rest))]
         [else (hash-set! h name #t) (loop (cdr rest))])]
      [else
       (set! pos (cons (car rest) pos))
       (loop (cdr rest))])))

(define (arg-positional args index)
  (define p (hash-ref args 'args #f))
  (and (pair? p) (< index (length p)) (list-ref p index)))

;; ----------------------------------------------------------------------------
;; Channel: sim ECU by default; DoIP with --transport doip --host H
;; ----------------------------------------------------------------------------

(define (make-channel args)
  (case (hash-ref args 'transport #f)
    [(doip)
     (define host (or (hash-ref args 'host #f)
                      (fail "validation" "--transport doip requires --host." 2)))
     (make-doip-uds-channel host
                            (doip-port)
                            (or (string->number
                                 (format "0x~a" (hash-ref args 'tester "0E00")))
                                #x0E00)
                            (or (string->number
                                 (format "0x~a" (hash-ref args 'ecu "0E10")))
                                #x0E10))]
    [else (make-sim-uds-channel)]))

(define (channel-request ch request)
  (if (sim-uds-channel? ch)
      (sim-channel-request ch request 1000 5000)
      (can-uds-channel-request ch request 1000 5000)))

(define (channel-flash ch plan)
  (if (sim-uds-channel? ch)
      (sim-channel-flash ch plan)
      (can-uds-channel-flash ch plan)))

;; ----------------------------------------------------------------------------
;; Usage
;; ----------------------------------------------------------------------------

(define (usage)
  (displayln
   (string-append
    "FlashPilot — AI-native ECU flashing (UDS over CAN/DoIP; LIN planned)\n"
    "\n"
    "Usage:\n"
    "  flashpilot flash <plan.json>          run a declarative flash plan\n"
    "  flashpilot verify <plan.json>         plan + fingerprint checks only\n"
    "  flashpilot dtc [read|clear]           diagnostic trouble codes\n"
    "  flashpilot request <hex>              one raw UDS request\n"
    "  flashpilot udid <did>                 read a DID (22 XX XX)\n"
    "\n"
    "Options:\n"
    "  --transport doip --host H [--port N]  DoIP transport (default sim ECU)\n"
    "\n"
    "Exit codes: 0 ok · 1 flash/assert failed · 2 usage · 3 not found · 4 transport\n")))

;; ----------------------------------------------------------------------------
;; Commands
;; ----------------------------------------------------------------------------

(define (load-plan-segments plan-path)
  (define base-dir
    (let-values ([(dir _ __)
                  (split-path (simplify-path (path->complete-path plan-path)))])
      (path->string dir)))
  (define hardening (read-flash-plan-json (file->string plan-path)))
  (define plan (uds-flash-hardening-plan hardening))
  (define plan*
    (struct-copy uds-flash-plan plan
                 [segments
                  (for/list ([seg (in-list (uds-flash-plan-segments plan))])
                    (if (and (uds-flash-segment-data seg)
                             (not (null? (uds-flash-segment-data seg))))
                        seg
                        (struct-copy uds-flash-segment seg
                                     [data (bytes->list
                                            (read-segment-file (uds-flash-segment-file seg)
                                                               base-dir))])))]))
  (values hardening plan*))

(define (cmd-flash args)
  (define plan-path
    (or (arg-positional args 0) (fail "validation" "Missing plan path." 2)))
  (define-values (hardening plan*) (load-plan-segments plan-path))
  (define fingerprint (flash-plan-fingerprint (uds-flash-plan-segments plan*)))
  (define expected (uds-flash-hardening-expected-fingerprint hardening))
  (when (and expected (not (string-ci=? expected fingerprint)))
    (fail "fingerprint_mismatch"
          (format "Image fingerprint ~a does not match expectedFingerprint ~a."
                  fingerprint expected)
          1))
  (define channel (make-channel args))
  (define result (channel-flash channel plan*))
  (print-result (hasheq 'ok (uds-flash-result-ok result)
                        'bytes (uds-flash-result-total-bytes result)
                        'fingerprint fingerprint
                        'steps (map flash-step-summary-step
                                    (uds-flash-result-steps result))
                        'error (or (uds-flash-result-error result) 'null)))
  (if (uds-flash-result-ok result) 0 1))

(define (cmd-verify args)
  (define plan-path
    (or (arg-positional args 0) (fail "validation" "Missing plan path." 2)))
  (define base-dir
    (let-values ([(dir _ __)
                  (split-path (simplify-path (path->complete-path plan-path)))])
      (path->string dir)))
  (define hardening (read-flash-plan-json (file->string plan-path)))
  (define plan (uds-flash-hardening-plan hardening))
  (define plan*
    (struct-copy uds-flash-plan plan
                 [segments
                  (for/list ([seg (in-list (uds-flash-plan-segments plan))])
                    (if (and (uds-flash-segment-data seg)
                             (not (null? (uds-flash-segment-data seg))))
                        seg
                        (struct-copy uds-flash-segment seg
                                     [data (bytes->list
                                            (read-segment-file (uds-flash-segment-file seg)
                                                               base-dir))])))]))
  (define fingerprint (flash-plan-fingerprint (uds-flash-plan-segments plan*)))
  (define expected (uds-flash-hardening-expected-fingerprint hardening))
  (print-result (hasheq 'ok #t
                        'fingerprint fingerprint
                        'expected (or expected 'null)
                        'match (if expected (string-ci=? expected fingerprint) 'null)
                        'segments (length (uds-flash-plan-segments plan*))))
  0)

(define (cmd-dtc args)
  (define action
    (string->symbol (string-downcase (or (arg-positional args 0) "read"))))
  (define channel (make-channel args))
  (define request
    (if (eq? action 'clear)
        (uds-clear-dtcs #xFFFFFF)
        (uds-read-dtcs #xFF)))
  (define result (channel-request channel request))
  (unless (uds-request-result-positive result)
    (fail "negative_response" "ECU answered negatively." 1))
  (define payload (hex-parse (uds-request-result-response-hex result)))
  (print-result (hasheq 'ok #t 'dtcs (parse-dtc-response payload)))
  0)

(define (cmd-request args)
  (define hex (or (arg-positional args 0) (fail "validation" "Missing request hex." 2)))
  (define channel (make-channel args))
  (define result (channel-request channel (hex-parse hex)))
  (print-result (hasheq 'ok (uds-request-result-ok result)
                        'positive (uds-request-result-positive result)
                        'responseHex (or (uds-request-result-response-hex result) 'null)
                        'nrc (or (uds-request-result-nrc result) 'null)))
  (if (uds-request-result-positive result) 0 1))

(define (cmd-udid args)
  (define did-text (or (arg-positional args 0) (fail "validation" "Missing DID." 2)))
  (define did
    (or (string->number (let ([t (string-trim did-text)])
                              (if (string-prefix? (string-downcase t) "0x")
                                  (substring t 2)
                                  t)) 16)
        (fail "validation" (format "Invalid DID '~a'." did-text) 2)))
  (define channel (make-channel args))
  (define result (channel-request channel (uds-read-did did)))
  (print-result (hasheq 'ok (uds-request-result-ok result)
                        'positive (uds-request-result-positive result)
                        'responseHex (or (uds-request-result-response-hex result) 'null)))
  (if (uds-request-result-positive result) 0 1))

(define (main argv)
  (cond
    [(null? argv) (usage) 0]
    [(member (car argv) '("-h" "--help" "help")) (usage) 0]
    [else
     (define command (string->symbol (string-downcase (car argv))))
     (define args (args->hash (cdr argv)))
     (define channel #f)
     (define exit-code
       (with-handlers
           ([cli-error? cli-error-exit-code]
            [exn:benchpilot:validation?
             (lambda (e)
               (print-result (hasheq 'ok #f 'code "validation" 'error (exn-message e)))
               2)]
            [exn:fail:flash?
             (lambda (e)
               (print-result (hasheq 'ok #f 'code "flash_failed" 'error (exn-message e)))
               1)])
         (set! channel (make-channel args))
         (case command
           [(flash) (cmd-flash args)]
           [(verify) (cmd-verify args)]
           [(dtc) (cmd-dtc args)]
           [(request) (cmd-request args)]
           [(udid) (cmd-udid args)]
           [else (fail "validation" (format "Unknown command: ~a" command) 2)])))
     exit-code]))

(module+ main
  (exit (with-handlers ([exn:fail?
                         (lambda (e)
                           (print-result (hasheq 'ok #f 'code "internal" 'error (exn-message e)))
                           4)])
          (main (vector->list (current-command-line-arguments))))))
