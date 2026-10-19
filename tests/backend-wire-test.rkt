#lang racket/base

(require json rackunit racket/match racket/path
         rivet/backend rivet/protocol)

(define test-directory
  (or (current-load-relative-directory) (current-directory)))
(define backend-path
  (simplify-path (build-path test-directory ".." "app" "backend.rkt")))
(void (dynamic-require backend-path #f))

(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe))
(define server-thread (thread (lambda () (serve server-in server-out))))

(define (read-frame/timeout label)
  (define result (box #f))
  (define failure (box #f))
  (define reader
    (thread
     (lambda ()
       (with-handlers ([exn:fail? (lambda (exception)
                                    (set-box! failure exception))])
         (set-box! result (read-frame client-in))))))
  (unless (sync/timeout 30 reader)
    (fail (format "timed out waiting for ~a" label)))
  (when (unbox failure) (raise (unbox failure)))
  (unbox result))

(define next-id 0)
(define (call-rpc name . arguments)
  (set! next-id (add1 next-id))
  (define id next-id)
  (write-frame (frame message:request id (encode-value (cons name arguments)))
               client-out)
  (flush-output client-out)
  (let loop ()
    (define response (read-frame/timeout name))
    (match (frame-type response)
      [(== message:event) (loop)]
      [(== message:response)
       (check-equal? (frame-id response) id)
       (values (decode-value (frame-payload response)) #f)]
      [(== message:error)
       (check-equal? (frame-id response) id)
       (values #f (decode-value (frame-payload response)))]
      [_ (loop)])))

(dynamic-wind
 void
 (lambda ()
   (define hello (read-frame/timeout "RVT1 hello"))
   (check-equal? (frame-type hello) message:hello)
   (check-equal? (decode-value (frame-payload hello))
                 (list "rivet" protocol-version))

   (define-values (status status-error) (call-rpc "bench-status"))
   (check-false status-error)
   (define status-json (string->jsexpr status))
   (check-equal? (hash-ref status-json 'product) "FlashPilot")
   (check-equal? (hash-ref status-json 'ready) #t)

   (define-values (validation validation-error) (call-rpc "bench-validate"))
   (check-false validation-error)
   (define validation-json (string->jsexpr validation))
   (check-equal? (hash-ref validation-json 'ok) #t)
   (check-true (pair? (hash-ref validation-json 'checks)))

   (define-values (dtcs dtc-error) (call-rpc "dtc-read"))
   (check-false dtc-error)
   (check-equal? (hash-ref (string->jsexpr dtcs) 'ok) #t))
 (lambda () (kill-thread server-thread)))
