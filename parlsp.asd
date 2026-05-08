(defsystem "parlsp"
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
  :build-pathname "dist/parlsp"
  :entry-point "parlsp:main"
  :in-order-to ((test-op (test-op "parlsp/tests"))))

(defsystem "parlsp/tests"
  :author "Henry"
  :license "MIT"
  :depends-on ("parlsp"
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
  :description "Test system for parlsp"
  :perform (test-op (op c) (symbol-call :rove :run c)))
