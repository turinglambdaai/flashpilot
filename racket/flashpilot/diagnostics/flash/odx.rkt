#lang racket/base

;; ODX import — a deliberately small, honest subset of ASAM MCD-2D.
;;
;; Supported: plain .odx / .odx-f XML and .pdx containers (zip of ODX
;; files). Extracted: MEMORY-SEGMENT ranges and their inline base64 DATA
;; blocks / DATAFILE references, mapped onto flash plan segments
;; (camelCase, same shape read-flash-plan-json consumes). Everything the
;; subset cannot convert is reported as an issue in the result — never
;; silently dropped. CDD and VFD are out of scope by design.

(require json
         racket/file
         racket/list
         racket/system
         racket/format
         racket/path
         racket/string
         net/base64
         (prefix-in x: xml))

(require flashpilot/core/contracts)

(provide odx-import-issues
         odx-import-reset!
         odx-import-file)

;; ---- issues --------------------------------------------------------------

;; Import is best-effort with loud reporting: the issues list travels in
;; the result so an agent can decide what to author by hand.
(define issues-box (box '()))
(define (note! message)
  (set-box! issues-box (append (unbox issues-box) (list message))))
(define (odx-import-issues) (unbox issues-box))
(define (odx-import-reset!) (set-box! issues-box '()))

;; ---- minimal XML tree ------------------------------------------------------
;;
;; read-xml structs -> simple trees: (name child...) with strings as text.
;; Element names keep their ODX casing as symbols.

(struct odx-node (name children) #:transparent)

(define (tree-name v)
  (and (odx-node? v) (odx-node-name v)))

(define (child-elements node name)
  (define sym (string->symbol name))
  (for/list ([c (in-list (odx-node-children node))]
             #:when (equal? (tree-name c) sym))
    c))

(define (descendant-elements node name)
  (define sym (string->symbol name))
  (let loop ([n node])
    (if (odx-node? n)
        (append (if (equal? (odx-node-name n) sym) (list n) '())
                (append-map loop (odx-node-children n)))
        '())))

(define (child-text node name)
  (for/first ([c (in-list (child-elements node name))]
              #:when (for/first ([t (in-list (odx-node-children c))]
                                 #:when (string? t))
                       t))
    (for/first ([t (in-list (odx-node-children c))] #:when (string? t)) t)))

;; ODX numbers appear as decimal or hex ("0x…"); accept both, reject the
;; rest loudly.
(define (odx-number text where)
  (define cleaned (string-replace (string-trim text) " " ""))
  (or (and (string-prefix? (string-downcase cleaned) "0x")
           (string->number (substring cleaned 2) 16))
      (string->number cleaned)
      (raise-validation (format "ODX: '~a' is not a number in ~a." text where))))

;; ---- parsing ---------------------------------------------------------------

(define (read-odx-doc in)
  (define doc (x:read-xml in))
  (define (node->tree n)
    (cond
      [(x:element? n)
       (odx-node (x:element-name n)
                 (for/list ([c (in-list (x:element-content n))])
                   (node->tree c)))]
      [(x:pcdata? n) (x:pcdata-string n)]
      [else (void)]))
  (node->tree (x:document-element doc)))

;; PDX is a zip container; Racket ships no zip reader, so the OS extractor
;; does the unpacking (unzip on unix, bsdtar's tar on windows) into a temp
;; dir and the first .odx file (sorted by name) is parsed.
(define (load-odx-doc path)
  (define p (path->string (simple-form-path path)))
  (cond
    [(string-suffix? (string-downcase p) ".pdx")
     (define tmp (path->string (make-temporary-file "flashpilot-odx~a" 'directory)))
     (define ok
       (zero? (if (eq? (system-type 'os) 'windows)
                  (system/exit-code "tar" "-xf" p "-C" tmp)
                  (system/exit-code "unzip" "-o" p "-d" tmp))))
     (unless ok
       (raise-validation (format "ODX: failed to unpack PDX container ~a." p)))
     (define odx-files
       (find-files (lambda (f)
                     (define s (string-downcase (path->string f)))
                     (or (string-suffix? s ".odx") (string-suffix? s ".odx-f")))
                   tmp))
     (unless (pair? odx-files)
       (raise-validation (format "ODX: ~a contains no .odx files." p)))
     (call-with-input-file (car (sort odx-files string<? #:key path->string))
       read-odx-doc)]
    [else
     (call-with-input-file p read-odx-doc)]))

;; ---- ODX -> plan segments ---------------------------------------------------

;; Inline base64 DATA blocks are decoded to hex data strings so the plan
;; stays a single portable JSON document.
(define (base64->hex text)
  (define cleaned
    (string-replace (string-replace (string-trim text) "\n" "") "\r" ""))
  (define raw (base64-decode (string->bytes/utf-8 cleaned)))
  (define out (open-output-string))
  (for ([b (in-bytes raw)])
    (fprintf out "~a" (string-append (substring (number->string (+ #x100 b) 16) 1))))
  (get-output-string out))

(define (segment->json seg path)
  (define name (or (child-text seg "SHORT-NAME") "segment"))
  (define addr-text (child-text seg "ADDRESS"))
  (define len-text (child-text seg "LENGTH"))
  (cond
    [(and addr-text len-text)
     (define address (odx-number addr-text (format "segment ~a ADDRESS" name)))
     (define size (odx-number len-text (format "segment ~a LENGTH" name)))
     (define data-text (child-text seg "DATA"))
     (cond
       [data-text
        (define hex
          (with-handlers ([exn:fail? (lambda (_e)
                                       (note! (format "~a: segment ~a has undecodable base64 DATA."
                                                      path name))
                                       #f)])
            (base64->hex data-text)))
        (when hex
          (note! (format "~a: segment ~a carries ~a bytes of inline DATA; materialized into the plan."
                         path name (/ (string-length hex) 2))))
        (hasheq 'name name
                'address address
                'size size
                'data (or hex "00")
                'source "odx-inline-data")]
       [(child-text seg "DATAFILE")
        (define file (child-text seg "DATAFILE"))
        (note! (format "~a: segment ~a DATAFILE references '~a'; point the plan's file entry at it."
                       path name file))
        (hasheq 'name name
                'address address
                'size size
                'file file
                'source "odx-datafile")]
       [else
        (note! (format "~a: segment ~a has no inline DATA or DATAFILE; import emits the range only."
                       path name))
        (hasheq 'name name 'address address 'size size 'source "odx-range")])]
    [else
     (note! (format "~a: segment ~a has no ADDRESS/LENGTH; skipped." path name))
     #f]))

;; The result: a plan JSON document (camelCase) plus per-segment metadata
;; the agent can use to finish authoring (calibration file names, ranges
;; without content).
(define (odx-doc->plan-json doc path)
  (odx-import-reset!)
  (define segments (descendant-elements doc "MEMORY-SEGMENT"))
  (define ecu-name
    (or (for/first ([n (in-list (descendant-elements doc "SHORT-NAME"))]
                    #:when (child-text n "SHORT-NAME"))
          (child-text n "SHORT-NAME"))
        "odx-ecu"))
  (define seg-json
    (filter values (for/list ([seg (in-list segments)]) (segment->json seg path))))
  (unless (pair? segments)
    (note! (format "~a: no MEMORY-SEGMENT entries found." path)))
  (hasheq 'segments
          (for/list ([s (in-list seg-json)])
            (define base (hasheq 'address (hash-ref s 'address)
                                 'sizeBytes (hash-ref s 'size)))
            (cond
              [(hash-ref s 'data #f)
               (hash-set base 'data (hash-ref s 'data))]
              [(hash-ref s 'file #f)
               (hash-set base 'file (hash-ref s 'file))]
              [else base]))
          'ecuName (or ecu-name "odx-ecu")
          'session #x02
          'defaults (hasheq 'maxBlockPayload 1024
                            'eraseRoutineId #xFF00
                            'verifyRoutineId #xFF01)))

(define (odx-import-file path)
  (odx-import-reset!)
  (define doc (load-odx-doc path))
  (define plan (odx-doc->plan-json doc (path->string (simple-form-path path))))
  (hasheq 'plan plan 'issues (odx-import-issues)))
