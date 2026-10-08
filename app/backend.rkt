#lang racket/base

;; FlashPilot Studio backend — the Racket domain core serving the native
;; shells. BenchPilot's value, rewritten on Rivet: one typed RPC surface
;; over the flashing engine, plans, readiness and evidence.

(require rivet/backend
         json
         racket/file
         racket/format
         racket/list
         racket/string)

(require flashpilot/core/contracts
         flashpilot/diagnostics/channels/sim-uds-channel
         flashpilot/diagnostics/doip/doip
         flashpilot/diagnostics/flash/plans
         flashpilot/diagnostics/uds/protocol)

(provide start)

(define-event plan-progress : String)
(define-state flash-count : Int64 0)

(define sim-channel (make-sim-uds-channel))

(define (jsexpr->text j)
  (let loop ([v j])
    (cond
      [(hash? v)
       (string-append
        "{"
        (string-join
         (for/list ([(k val) (in-hash v)])
           (format "~a:~a" (jsexpr->string (format "~a" k)) (loop val)))
         ",")
        "}")]
      [(list? v)
       (string-append "[" (string-join (map loop v) ",") "]")]
      [(string? v) (format "~s" v)]
      [(eq? v 'null) "null"]
      [(boolean? v) (if v "true" "false")]
      [(real? v) (~r v #:precision '(= 3))]
      [else (format "~s" (format "~a" v))])))

;; Read-only: the simulated bench identity + capability surface. Real
;; transports (DoIP/CAN) attach where this state is created today.
(define-rpc (bench-status : String)
  (jsexpr->string
   (hasheq 'product "FlashPilot"
           'version "0.1.0"
           'transport "sim-uds"
           'ecu "BenchPilot sim-ecu v1.0.4"
           'ready #t)))

;; Readiness: the plan-less preflight — transports configured, ECU alive.
(define-rpc (bench-validate : String)
  (define probe (sim-channel-request sim-channel (uds-read-dtcs #xFF) 1000 5000))
  (jsexpr->string
   (hasheq 'ok (uds-request-result-ok probe)
           'positive (uds-request-result-positive probe)
           'checks
           (list (hasheq 'code "transport.alive"
                         'passed (uds-request-result-ok probe)
                         'severity "error"
                         'summary "Simulated ECU answers UDS requests.")))))

;; Plan verification without ECU contact: structure + fingerprint gate.
(define-rpc (verify-plan [planPath String] : String)
  (define hardening (read-flash-plan-json (file->string planPath)))
  (define plan (uds-flash-hardening-plan hardening))
  (define fingerprint
    (flash-plan-fingerprint
     (for/list ([seg (in-list (uds-flash-plan-segments plan))])
       (if (and (uds-flash-segment-data seg) (not (null? (uds-flash-segment-data seg))))
           seg
           (uds-flash-segment (uds-flash-segment-address seg)
                              (or (and (uds-flash-segment-file seg)
                                       (file->bytes (uds-flash-segment-file seg))
                                       (let () (void))
                                       '())
                                  (uds-flash-segment-data seg))
                              (uds-flash-segment-file seg))))))
  (define expected (uds-flash-hardening-expected-fingerprint hardening))
  (jsexpr->string
   (hasheq 'ok #t
           'segments (length (uds-flash-plan-segments plan))
           'fingerprint fingerprint
           'expected (or expected 'null)
           'match (if expected (string-ci=? expected fingerprint) 'null)
           'onFail (or (uds-flash-hardening-on-fail hardening) 'null)
           'powerGuard (if (uds-flash-hardening-power-guard hardening) 'configured 'null))))

;; DTC read against the attached ECU.
(define-rpc (dtc-read : String)
  (define result (sim-channel-request sim-channel (uds-read-dtcs #xFF) 1000 5000))
  (if (uds-request-result-positive result)
      (jsexpr->string (hasheq 'ok #t
                              'dtcs (parse-dtc-response
                                     (hex-parse (uds-request-result-response-hex result)))))
      (jsexpr->string (hasheq 'ok #f 'error "Negative response."))))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
