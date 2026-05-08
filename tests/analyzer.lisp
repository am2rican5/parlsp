(in-package #:parlsp/tests/main)

(deftest position-and-offset-conversion
  (testing "round-trip on a multi-line buffer"
    (let* ((doc (parlsp:make-document
                 :uri "test://buf"
                 :text (format nil "(defun foo ()~%  42)~%"))))
      (ok (= 0 (parlsp:position-to-offset doc 0 0)))
      (ok (= 14 (parlsp:position-to-offset doc 1 0)))
      (multiple-value-bind (l c)
          (parlsp:offset-to-position doc 14)
        (ok (= 1 l))
        (ok (= 0 c)))
      (ok (= 3 (parlsp:document-line-count doc))))))

(deftest symbol-at-position-finds-defun-name
  (testing "cursor on 'foo' returns FOO"
    (let* ((text "(defun foo (x) (* x x))"))
      (ok (equal "foo"
                 (parlsp:symbol-at-position text 8))))))

(deftest document-symbols-extracts-definitions
  (testing "defun, defvar, defclass all surface"
    (let* ((text (format nil "(defun foo () 1)~%~
                              (defvar *bar* 2)~%~
                              (defclass baz () ())~%"))
           (defs (parlsp:document-symbols text)))
      (ok (= 3 (length defs)))
      (ok (equal '("FOO" "*BAR*" "BAZ")
                 (mapcar (lambda (d) (parlsp::toplevel-def-name d))
                         defs))))))

(deftest diagnostics-report-unmatched-parens
  (testing "missing close paren produces diagnostic"
    (let ((diags (parlsp:diagnostics-for-text "(defun foo ()")))
      (ok (>= (length diags) 1))
      (ok (search "Unmatched"
                  (parlsp::json-get (first diags) "message")))))
  (testing "balanced text produces no diagnostics"
    (ok (null (parlsp:diagnostics-for-text "(defun foo () 42)")))))

(deftest incremental-change-replaces-range
  (testing "didChange-style range replacement"
    (let ((doc (parlsp:make-document
                :uri "u" :text "(defun foo () 1)")))
      (parlsp::apply-range-change
       doc
       (parlsp::json-obj
        :start (parlsp::json-obj :line 0 :character 14)
        :end   (parlsp::json-obj :line 0 :character 15))
       "999")
      (ok (equal "(defun foo () 999)" (parlsp:document-text doc))))))
