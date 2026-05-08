(eval-when (:compile-toplevel :load-toplevel :execute)
  #+sbcl (require :sb-introspect))

(uiop:define-package #:parlsp
  (:use #:cl)
  (:export
   ;; entry points
   #:main
   #:start
   #:run-stdio
   #:run-tcp
   ;; configuration
   #:*log-stream*
   #:*log-level*
   ;; testable internals
   #:read-message
   #:write-message
   #:dispatch
   #:make-server
   #:server-shutdown-requested-p
   #:make-document
   #:document-text
   #:document-uri
   #:document-version
   #:document-set-text
   #:document-apply-change
   #:position-to-offset
   #:offset-to-position
   #:document-line-count
   #:document-line
   #:symbol-at-position
   #:document-symbols
   #:diagnostics-for-text
   #:json-obj
   #:json-encode
   #:json-decode))
