(defpackage #:parlsp/tests/main
  (:use #:cl #:rove))
(in-package #:parlsp/tests/main)

;; All other test files re-use this package via in-package, so loading
;; this file first sets up symbol resolution. To run the entire suite:
;;
;;   (asdf:test-system :parlsp)

(deftest smoke-package-loads
  (testing "parlsp package is loaded"
    (ok (find-package :parlsp))))
