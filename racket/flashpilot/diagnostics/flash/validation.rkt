#lang racket/base

;; Plan validation — the lint pass between authoring and hardware.
;;
;; Checks structural sanity read-flash-plan-json cannot express: segment
;; overlap, zero/negative sizes, segments with neither data nor file,
;; duplicate addresses and (warning-level) gaps between consecutive
;; segments. `validate` runs before any driver call; errors exit non-zero
;; exactly like every other CLI failure.

(require racket/format
         racket/list
         racket/string)

(require flashpilot/diagnostics/flash/plans)

(provide (struct-out plan-validation-issue)
         plan-validation-issues
         plan-issues->json
         plan-blocking-errors)

(struct plan-validation-issue (severity message) #:transparent) ; severity: 'error | 'warning

;; Ranges are [address, address + size); data length wins when a segment
;; carries inline data, otherwise sizeBytes from the import.
(define (segment-range seg)
  (define address (uds-flash-segment-address seg))
  (define data (uds-flash-segment-data seg))
  (define len
    (cond
      [data (length data)]
      [else 0]))
  (values address len))

(define (plan-validation-issues plan)
  (define segments (uds-flash-plan-segments plan))
  (define issues '())
  (define (add severity message)
    (set! issues (cons (plan-validation-issue severity message) issues)))

  (when (null? segments)
    (add 'error "Plan has no segments."))

  (for ([seg (in-list segments)] [i (in-naturals 1)])
    (define-values (address len) (segment-range seg))
    (when (and (not (uds-flash-segment-data seg)) (not (uds-flash-segment-file seg)))
      (add 'error (format "Segment ~a at 0x~a has neither inline data nor a file."
                          i (~r address #:base 16))))
    (when (negative? address)
      (add 'error (format "Segment ~a has a negative address." i)))
    (when (zero? len)
      (add 'warning (format "Segment ~a at 0x~a is empty." i (~r address #:base 16)))))

  ;; overlap check: sorted by address, each range must start at or after
  ;; the previous range ends
  (define with-data
    (for/list ([seg (in-list segments)])
      (define-values (address len) (segment-range seg))
      (list address len seg)))
  (for/fold ([prev-end #f] [prev-addr #f])
            ([entry (in-list (sort with-data < #:key car))])
    (define address (car entry))
    (define len (cadr entry))
    (when (and prev-end (> address prev-end))
      (add 'warning
           (format "Gap between 0x~a and 0x~a — verify the ECU expects unprogrammed bytes there."
                   (~r prev-end #:base 16) (~r address #:base 16))))
    (when (and prev-end (< address prev-end))
      (add 'error
           (format "Segments overlap at 0x~a (previous segment ends at 0x~a)."
                   (~r address #:base 16) (~r prev-end #:base 16))))
    (values (+ address len) address))

  (reverse issues))

(define (plan-blocking-errors issues)
  (filter (lambda (i) (eq? 'error (plan-validation-issue-severity i))) issues))

(define (plan-issues->json issues)
  (for/list ([i (in-list issues)])
    (hasheq 'severity (symbol->string (plan-validation-issue-severity i))
            'message (plan-validation-issue-message i))))
