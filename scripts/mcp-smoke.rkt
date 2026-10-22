#lang racket/base

;; MCP smoke: spawn the server, initialize, flash the simulated ECU
;; through the flashpilot_flash tool. Exit 0 = the whole agent surface
;; works end to end. Run from the repo root: racket scripts/mcp-smoke.rkt

(require json
         racket/file
         racket/port
         racket/string)

(define racket-bin
  (or (find-executable-path "racket") (find-system-path 'exec-file)))
(define mcp-path (path->string (build-path (current-directory) "app" "mcp.rkt")))

(define plan-json
  "{\"segments\":[{\"address\":\"0x08000000\",\"data\":\"AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF001122334455667788\"}],\"session\":2,\"securityLevel\":1,\"keyDeriver\":\"xor0x5a\"}")

(define-values (proc stdout stdin stderr)
  (subprocess #f #f #f racket-bin mcp-path))
(define (send! msg)
  (display (jsexpr->string msg) stdin)
  (newline stdin)
  (flush-output stdin))

(send! (hasheq 'jsonrpc "2.0" 'id 1 'method "initialize" 'params (hasheq)))
(define init-line (read-line stdout))
(send! (hasheq 'jsonrpc "2.0" 'id 2 'method "tools/call"
               'params (hasheq 'name "flashpilot_flash"
                               'arguments (hasheq 'plan_json plan-json))))
(define flash-line (read-line stdout))
(close-output-port stdin)
(subprocess-wait proc)

(define (fail! message)
  (eprintf "mcp smoke FAIL: ~a\n" message)
  (exit 1))

(define init (and (string? init-line) (string->jsexpr init-line)))
(unless (and (hash? init)
             (string=? (hash-ref (hash-ref init 'result (hasheq)) 'protocolVersion "")
                       "2024-11-05"))
  (fail! (format "initialize: ~s" init-line)))

(define flash (and (string? flash-line) (string->jsexpr flash-line)))
(define payload
  (and (hash? flash)
       (let* ([content (hash-ref (hash-ref flash 'result (hasheq)) 'content #f)]
              [text (and (pair? content) (hash-ref (car content) 'text #f))])
         (and text (string->jsexpr text)))))
(unless (and (hash? payload) (hash-ref payload 'ok #f))
  (fail! (format "flash: ~s" flash-line)))
(unless (member "ecu-reset" (hash-ref payload 'steps '()))
  (fail! (format "flash steps incomplete: ~s" payload)))

(printf "mcp smoke: ok (bytes ~a, steps ~a)\n"
        (hash-ref payload 'bytes)
        (length (hash-ref payload 'steps)))
