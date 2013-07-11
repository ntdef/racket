#lang scheme/base

(require scribble/xref
         scheme/fasl
         scheme/path
         racket/promise
         setup/dirs
         setup/getinfo
         setup/private/path-utils
         setup/doc-db)

(provide load-collections-xref
         make-collections-xref)

(define cached-xref #f)

(define (get-dests tag no-user?)
  (define main-dirs
    (for/hash ([k (in-list (find-relevant-directories (list tag) 'no-user))])
      (values k #t)))
  (apply
   append
   (for*/list ([dir (find-relevant-directories (list tag) 'all-available)]
               [d (let ([info-proc (get-info/full dir)])
                    (if info-proc
                        (info-proc tag)
                        '()))])
     (unless (and (list? d) (pair? d))
       (error 'xref "bad scribblings entry: ~e" d))
     (let* ([len   (length d)]
            [flags (if (len . >= . 2) (cadr d) '())]
            [name  (if (len . >= . 4)
                       (cadddr d)
                       (path->string
                        (path-replace-suffix (file-name-from-path (car d))
                                             #"")))]
            [out-count (if (len . >= . 5)
                           (list-ref d 4)
                           1)])
       (if (not (and (len . >= . 3) (memq 'omit (caddr d))))
           (let ([d (doc-path dir name flags (hash-ref main-dirs dir #f) 
                              (if no-user? 'never 'false-if-missing))])
             (if d
                 (for*/list ([i (in-range (add1 out-count))]
                             [p (in-value (build-path d (format "out~a.sxref" i)))]
                             #:when (file-exists? p))
                   p)
                 null))
           null)))))

(define ((dest->source done-ht quiet-fail?) dest)
  (if (hash-ref done-ht dest #f)
      (lambda () #f)
      (lambda ()
        (hash-set! done-ht dest #t)
        (with-handlers ([exn:fail? (lambda (exn)
                                     (unless quiet-fail?
                                       (log-warning
                                        "warning: ~a"
                                        (if (exn? exn)
                                            (exn-message exn)
                                            (format "~e" exn))))
                                     #f)])
          (make-data+root
           ;; data to deserialize:
           (cadr (call-with-input-file* dest fasl->s-exp))
           ;; provide a root for deserialization:
           (path-only dest))))))

(define (make-key->source db-path no-user? quiet-fail?)
  (define main-db (cons (or db-path
                            (build-path (find-doc-dir) "docindex.sqlite"))
                        ;; cache for a connection:
                        (box #f)))
  (define user-db (and (not no-user?)
                       (cons (build-path (find-user-doc-dir) "docindex.sqlite")
                             ;; cache for a connection:
                             (box #f))))
  (define done-ht (make-hash)) ; tracks already-loaded documents
  (define forced-all? #f)
  (define (force-all)
    ;; force all documents
    (define thunks (get-reader-thunks no-user? quiet-fail? done-ht))
    (set! forced-all? #t)
    (lambda () 
      ;; return a procedure so we can produce a list of results:
      (lambda () 
        (for/list ([thunk (in-list thunks)])
          (thunk)))))
  (lambda (key)
    (cond
     [forced-all? #f]
     [key
      (define (try p)
        (and p
             (let* ([maybe-db (unbox (cdr p))]
                    [db 
                     ;; Use a cached connection, or...
                     (or (and (box-cas! (cdr p) maybe-db #f)
                              maybe-db)
                         ;; ... create a new one
                         (and (file-exists? (car p))
                              (doc-db-file->connection (car p))))])
               (and 
                db
                (let ()
                  ;; The db query:
                  (begin0
                   (doc-db-key->path db key)
                   ;; cache the connection, if none is already cached:
                   (or (box-cas! (cdr p) #f db)
                       (doc-db-disconnect db))))))))
      (define dest (or (try main-db) (try user-db)))
      (and dest
           (if (eq? dest #t)
               (force-all)
               ((dest->source done-ht quiet-fail?) dest)))]
     [else
      (unless forced-all?
        (force-all))])))

(define (get-reader-thunks no-user? quiet-fail? done-ht)
  (map (dest->source done-ht quiet-fail?)
       (filter values (append (get-dests 'scribblings no-user?)
                              (get-dests 'rendered-scribblings no-user?)))))

(define (load-collections-xref [report-loading void])
  (or cached-xref
      (begin (report-loading)
             (set! cached-xref 
                   (make-collections-xref))
             cached-xref)))

(define (make-collections-xref #:no-user? [no-user? #f]
                               #:doc-db [db-path #f]
                               #:quiet-fail? [quiet-fail? #f])
  (if (doc-db-available?)
      (load-xref null
                 #:demand-source (make-key->source db-path no-user? quiet-fail?))
      (load-xref (get-reader-thunks no-user? quiet-fail? (make-hash)))))