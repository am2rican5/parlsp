(in-package #:common-lisp-lsp/tests/main)

(deftest position-and-offset-conversion
  (testing "round-trip on a multi-line buffer"
    (let* ((doc (common-lisp-lsp:make-document
                 :uri "test://buf"
                 :text (format nil "(defun foo ()~%  42)~%"))))
      (ok (= 0 (common-lisp-lsp:position-to-offset doc 0 0)))
      (ok (= 14 (common-lisp-lsp:position-to-offset doc 1 0)))
      (multiple-value-bind (l c)
          (common-lisp-lsp:offset-to-position doc 14)
        (ok (= 1 l))
        (ok (= 0 c)))
      (ok (= 3 (common-lisp-lsp:document-line-count doc))))))

(deftest symbol-at-position-finds-defun-name
  (testing "cursor on 'foo' returns FOO"
    (let* ((text "(defun foo (x) (* x x))"))
      (ok (equal "foo"
                 (common-lisp-lsp:symbol-at-position text 8))))))

(deftest document-symbols-extracts-definitions
  (testing "defun, defvar, defclass all surface"
    (let* ((text (format nil "(defun foo () 1)~%~
                              (defvar *bar* 2)~%~
                              (defclass baz () ())~%"))
           (defs (common-lisp-lsp:document-symbols text)))
      (ok (= 3 (length defs)))
      (ok (equal '("FOO" "*BAR*" "BAZ")
                 (mapcar (lambda (d) (common-lisp-lsp::toplevel-def-name d))
                         defs))))))

(deftest diagnostics-report-unmatched-parens
  (testing "missing close paren produces diagnostic"
    (let ((diags (common-lisp-lsp:diagnostics-for-text "(defun foo ()")))
      (ok (>= (length diags) 1))
      (ok (search "Unmatched"
                  (common-lisp-lsp::json-get (first diags) "message")))))
  (testing "balanced text produces no diagnostics"
    (ok (null (common-lisp-lsp:diagnostics-for-text "(defun foo () 42)")))))

(deftest incremental-change-replaces-range
  (testing "didChange-style range replacement"
    (let ((doc (common-lisp-lsp:make-document
                :uri "u" :text "(defun foo () 1)")))
      (common-lisp-lsp::apply-range-change
       doc
       (common-lisp-lsp::json-obj
        :start (common-lisp-lsp::json-obj :line 0 :character 14)
        :end   (common-lisp-lsp::json-obj :line 0 :character 15))
       "999")
      (ok (equal "(defun foo () 999)" (common-lisp-lsp:document-text doc))))))
