(defpackage #:common-lisp-lsp/tests/main
  (:use #:cl #:rove))
(in-package #:common-lisp-lsp/tests/main)

;; All other test files re-use this package via in-package, so loading
;; this file first sets up symbol resolution. To run the entire suite:
;;
;;   (asdf:test-system :common-lisp-lsp)

(deftest smoke-package-loads
  (testing "common-lisp-lsp package is loaded"
    (ok (find-package :common-lisp-lsp))))
