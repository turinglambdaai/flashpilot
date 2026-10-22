#lang racket/base

;; FlashPilot MCP server — the agent-facing surface over stdio JSON-RPC 2.0
;; (MCP stdio transport). Exposes the same engine the CLI drives:
;; validate plans, run flashes, send raw UDS requests, import ODX.
;; One process, sequential requests, exits 0 on EOF. Nothing may be
;; written to stdout except protocol responses.

(require json
         racket/file
         racket/path
         racket/port
         racket/string)

(require flashpilot/core/contracts
         (only-in flashpilot/diagnostics/flash/engine exn:fail:flash?)
         flashpilot/diagnostics/channels/sim-uds-channel
         flashpilot/diagnostics/doip/doip
         flashpilot/diagnostics/flash/odx
         flashpilot/diagnostics/flash/plans
         flashpilot/diagnostics/flash/validation
         flashpilot/diagnostics/uds/protocol)

(define PROTOCOL-VERSION "2024-11-05")

;; ---- plan loading (same path the CLI uses) --------------------------------

(define (load-plan hardening*)
  (struct-copy uds-flash-plan (uds-flash-hardening-plan hardening*)
               [segments
                (for/list ([seg (in-list (uds-flash-plan-segments
                                          (uds-flash-hardening-plan hardening*)))])
                  (if (and (uds-flash-segment-data seg)
                           (not (null? (uds-flash-segment-data seg))))
                      seg
                      (struct-copy uds-flash-segment seg
                                   [data (bytes->list
                                          (read-segment-file (uds-flash-segment-file seg)
                                                             (current-directory)))])))]))

(define (load-plan-from-string text)
  (load-plan (read-flash-plan-json text)))

(define (channel-for args)
  (case (hash-ref args 'transport #f)
    [("doip")
     (make-doip-uds-channel
      (hash-ref args 'host)
      (doip-port)
      #x0E00
      #x0E10)]
    [else (make-sim-uds-channel)]))

(define (channel-request ch request)
  (if (sim-uds-channel? ch)
      (sim-channel-request ch request 1000 5000)
      (can-uds-channel-request ch request 1000 5000)))

(define (channel-flash ch plan)
  (if (sim-uds-channel? ch)
      (sim-channel-flash ch plan)
      (can-uds-channel-flash ch plan)))

;; ---- tool schemas -----------------------------------------------------------

(define (schema-of properties required)
  (hasheq 'type "object"
          'properties properties
          'required required
          'additionalProperties #f))

(define (str-schema desc)
  (hasheq 'type "string" 'description desc))

(define (tool-def name desc schema)
  (hasheq 'name name 'description desc 'inputSchema schema))

(define TOOL-DEFS
  (list
   (tool-def
    "flashpilot_validate"
    "Lint a flash plan (JSON text): segment overlap, empty segments, missing data/file, gaps. Run this before flashing; errors mean the plan must not flash."
    (schema-of (hasheq 'plan_json (str-schema "Flash plan as a JSON string"))
               '("plan_json")))
   (tool-def
    "flashpilot_flash"
    "Run a declarative flash plan against a transport. Default is the built-in simulated ECU (hardware-free); pass transport=doip + host for real Ethernet ECUs. Returns the step-by-step flash result."
    (schema-of (hasheq 'plan_json (str-schema "Flash plan as a JSON string")
                       'transport (str-schema "\"doip\" for real ECUs; omit for the simulated ECU")
                       'host (str-schema "DoIP gateway host (transport=doip only)"))
               '("plan_json")))
   (tool-def
    "flashpilot_request"
    "Send one raw UDS request as hex bytes and get the response plus NRC name. Read-level services only unless the user explicitly authorized writes."
    (schema-of (hasheq 'request_hex (str-schema "UDS request bytes as hex, e.g. 22f195")
                       'transport (str-schema "\"doip\" for real ECUs; omit for the simulated ECU")
                       'host (str-schema "DoIP gateway host (transport=doip only)"))
               '("request_hex")))
   (tool-def
    "flashpilot_udid"
    "Read one data identifier (UDS 22 XX XX) and return its hex payload."
    (schema-of (hasheq 'did (str-schema "DID as hex text, e.g. F195")
                       'transport (str-schema "\"doip\" for real ECUs; omit for the simulated ECU")
                       'host (str-schema "DoIP gateway host (transport=doip only)"))
               '("did")))
   (tool-def
    "flashpilot_odx_import"
    "Import an ODX/.pdx file into a flash plan (supported subset: MEMORY-SEGMENT ranges, inline base64 DATA, DATAFILE references). Unconverted constructs come back in `issues` — never silently dropped."
    (schema-of (hasheq 'path (str-schema "Path to the .odx, .odx-f or .pdx file"))
               '("path")))))

;; ---- tool dispatch -----------------------------------------------------------

(define (call-tool name args)
  (case name
    [("flashpilot_validate")
     (define plan* (load-plan-from-string (hash-ref args 'plan_json)))
     (define issues (plan-validation-issues plan*))
     (define errors (plan-blocking-errors issues))
     (hasheq 'ok (null? errors)
             'valid (null? errors)
             'fingerprint (flash-plan-fingerprint (uds-flash-plan-segments plan*))
             'segments (length (uds-flash-plan-segments plan*))
             'issues (plan-issues->json issues))]
    [("flashpilot_flash")
     (define plan* (load-plan-from-string (hash-ref args 'plan_json)))
     (define issues (plan-blocking-errors (plan-validation-issues plan*)))
     (unless (null? issues)
       (error "plan failed validation; run flashpilot_validate first: ~a"
              (plan-validation-issue-message (car issues))))
     (define fingerprint (flash-plan-fingerprint (uds-flash-plan-segments plan*)))
     (define result (channel-flash (channel-for args) plan*))
     (hasheq 'ok (uds-flash-result-ok result)
             'bytes (uds-flash-result-total-bytes result)
             'fingerprint fingerprint
             'steps (map flash-step-summary-step (uds-flash-result-steps result))
             'error (or (uds-flash-result-error result) 'null))]
    [("flashpilot_request")
     (define hex (hash-ref args 'request_hex))
     (define result (channel-request (channel-for args) (hex-parse hex)))
     (hasheq 'ok (uds-request-result-ok result)
             'positive (uds-request-result-positive result)
             'responseHex (or (uds-request-result-response-hex result) 'null)
             'nrc (or (uds-request-result-nrc result) 'null))]
    [("flashpilot_udid")
     (define did-text (hash-ref args 'did))
     (define did
       (string->number
        (let ([t (string-trim did-text)])
          (if (string-prefix? (string-downcase t) "0x") (substring t 2) t))
        16))
     (unless did (error "invalid DID '~a'" did-text))
     (define result (channel-request (channel-for args) (uds-read-did did)))
     (hasheq 'ok (uds-request-result-ok result)
             'positive (uds-request-result-positive result)
             'responseHex (or (uds-request-result-response-hex result) 'null))]
    [("flashpilot_odx_import")
     (define path (hash-ref args 'path))
     (unless (file-exists? path) (error "ODX file not found: ~a" path))
     (odx-import-file path)]
    [else (error "unknown tool: ~a" name)]))

;; ---- protocol loop ------------------------------------------------------------

(define (handle msg)
  (define id (hash-ref msg 'id #f))
  (define method (hash-ref msg 'method #f))
  (case method
    [("initialize")
     (hasheq 'jsonrpc "2.0" 'id id
             'result (hasheq 'protocolVersion PROTOCOL-VERSION
                             'capabilities (hasheq 'tools (hasheq))
                             'serverInfo (hasheq 'name "flashpilot"
                                                 'version "0.1.0")))]
    [("notifications/initialized") (void)]
    [("tools/list")
     (hasheq 'jsonrpc "2.0" 'id id 'result (hasheq 'tools TOOL-DEFS))]
    [("tools/call")
     (define params (hash-ref msg 'params (hasheq)))
     (define name (hash-ref params 'name ""))
     (define args (hash-ref params 'arguments (hasheq)))
     (with-handlers ([exn:fail?
                      (lambda (e)
                        (hasheq 'jsonrpc "2.0" 'id id
                                'result (hasheq 'content
                                                (list (hasheq 'type "text"
                                                              'text (format "error: ~a"
                                                                            (exn-message e)))))
                                'isError #t))])
       (define payload (call-tool name args))
       (hasheq 'jsonrpc "2.0" 'id id
               'result (hasheq 'content
                               (list (hasheq 'type "text" 'text (jsexpr->string payload))))))]
    [("ping") (hasheq 'jsonrpc "2.0" 'id id 'result (hasheq))]
    [else
     (if id
         (hasheq 'jsonrpc "2.0" 'id id
                 'error (hasheq 'code -32601 'message "method not found"))
         (void))]))

(define (serve)
  (let loop ()
    (define line (read-line))
    (unless (eof-object? line)
      (define msg
        (with-handlers ([exn:fail? (lambda (_e) #f)])
          (string->jsexpr line)))
      (when (hash? msg)
        (define response (handle msg))
        (when (hash? response)
          (write-json response)
          (newline)
          (flush-output)))
      (loop))))

(module+ main (serve))
