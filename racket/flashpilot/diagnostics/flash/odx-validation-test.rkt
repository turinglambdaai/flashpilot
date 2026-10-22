#lang racket/base

;; Tests for the ODX import subset and plan validation lint.

(module+ test
  (require json
           racket/file
           racket/path
           racket/string
           rackunit)

  (require flashpilot/diagnostics/flash/odx
           flashpilot/diagnostics/flash/plans
           flashpilot/diagnostics/flash/validation)

  (define tmp-dir (make-temporary-file "flashpilot-odx-test~a" 'directory))

  (define odx-path (build-path tmp-dir "demo.odx"))
  (call-with-output-file odx-path
    (lambda (out)
      (display
       #<<XML
<?xml version="1.0" encoding="UTF-8"?>
<ODX version="1.0.0">
  <FLASH>
    <SHORT-NAME>demo-ecu</SHORT-NAME>
    <MEM>
      <SEGMENTS>
        <MEMORY-SEGMENT ID="S1">
          <SHORT-NAME>APP</SHORT-NAME>
          <ADDRESS>0x08010000</ADDRESS>
          <LENGTH>65536</LENGTH>
          <DATA>YWJj</DATA>
        </MEMORY-SEGMENT>
        <MEMORY-SEGMENT ID="S2">
          <SHORT-NAME>CAL</SHORT-NAME>
          <ADDRESS>134348800</ADDRESS>
          <LENGTH>16384</LENGTH>
          <DATAFILE>cal.bin</DATAFILE>
        </MEMORY-SEGMENT>
        <MEMORY-SEGMENT ID="S3">
          <SHORT-NAME>BAD</SHORT-NAME>
          <LENGTH>4096</LENGTH>
        </MEMORY-SEGMENT>
      </SEGMENTS>
    </MEM>
  </FLASH>
</ODX>
XML
       out)))

  (test-case "odx import maps segments and reports honestly"
    (define result (odx-import-file odx-path))
    (define plan (hash-ref result 'plan))
    (define segments (hash-ref plan 'segments))
    (check-equal? (length segments) 2)  ; BAD (no ADDRESS) is skipped and reported
    (check-equal? (hash-ref (car segments) 'address) #x8010000)
    ;; inline base64 DATA "abc" materializes as hex
    (check-equal? (hash-ref (car segments) 'data) "616263")
    (check-equal? (hash-ref (cadr segments) 'file) "cal.bin")
    (define issues (hash-ref result 'issues))
    (check-true (ormap (lambda (i) (string-contains? i "DATAFILE")) issues))
    (check-true (ormap (lambda (i) (string-contains? i "no ADDRESS/LENGTH")) issues)))

  (test-case "imported plan parses through read-flash-plan-json"
    (define result (odx-import-file odx-path))
    (define plan
      (uds-flash-hardening-plan
       (read-flash-plan-json (jsexpr->string (hash-ref result 'plan)))))
    (check-equal? (length (uds-flash-plan-segments plan)) 2)
    (check-equal? (uds-flash-segment-address (car (uds-flash-plan-segments plan)))
                  #x8010000)
    ;; inline data arrived as the byte list 'a 'b 'c
    (check-equal? (uds-flash-segment-data (car (uds-flash-plan-segments plan)))
                  (list #x61 #x62 #x63)))

  (test-case "validation accepts the imported plan structure"
    (define plan
      (uds-flash-hardening-plan
       (read-flash-plan-json
        (jsexpr->string (hash-ref (odx-import-file odx-path) 'plan)))))
    (define issues (plan-validation-issues plan))
    (check-false (ormap (lambda (i) (eq? 'error (plan-validation-issue-severity i))) issues)))

  (test-case "validation flags overlapping segments"
    (define hardening
      (read-flash-plan-json
       "{\"segments\":[{\"address\":\"0x1000\",\"data\":\"AABB\"},{\"address\":\"0x1001\",\"data\":\"CC\"}]}"))
    (define issues (plan-validation-issues (uds-flash-hardening-plan hardening)))
    (check-true (ormap (lambda (i)
                         (and (eq? 'error (plan-validation-issue-severity i))
                              (string-contains? (plan-validation-issue-message i) "overlap")))
                       issues)))

  (test-case "validation warns on empty plan"
    (define hardening (read-flash-plan-json "{\"segments\":[]}"))
    (define issues (plan-validation-issues (uds-flash-hardening-plan hardening)))
    (check-true (ormap (lambda (i)
                         (and (eq? 'error (plan-validation-issue-severity i))
                              (string-contains? (plan-validation-issue-message i) "no segments")))
                       issues))))
