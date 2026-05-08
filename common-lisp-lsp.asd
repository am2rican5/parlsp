(defsystem "common-lisp-lsp"
  :version "0.1.0"
  :author "Henry"
  :license "MIT"
  :description "A Language Server Protocol implementation for Common Lisp."
  :depends-on ("alexandria"
               "bordeaux-threads"
               "cl-json"
               "cl-ppcre"
               "uiop")
  :components ((:module "src"
                :serial t
                :components
                ((:file "package")
                 (:file "json")
                 (:file "log")
                 (:file "document")
                 (:file "analyzer")
                 (:file "protocol")
                 (:file "handlers")
                 (:file "server")
                 (:file "main"))))
  :build-operation "program-op"
  :build-pathname "bin/cl-lsp"
  :entry-point "common-lisp-lsp:main"
  :in-order-to ((test-op (test-op "common-lisp-lsp/tests"))))

(defsystem "common-lisp-lsp/tests"
  :author "Henry"
  :license "MIT"
  :depends-on ("common-lisp-lsp"
               "rove"
               "trivial-gray-streams")
  :components ((:module "tests"
                :serial t
                :components
                ((:file "main")
                 (:file "json")
                 (:file "protocol")
                 (:file "analyzer")
                 (:file "handlers"))))
  :description "Test system for common-lisp-lsp"
  :perform (test-op (op c) (symbol-call :rove :run c)))
