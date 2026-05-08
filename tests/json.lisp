(in-package #:common-lisp-lsp/tests/main)

(deftest json-roundtrip
  (testing "object with string keys roundtrips"
    (let* ((obj (common-lisp-lsp::json-obj :jsonrpc "2.0"
                                           :id 1
                                           :method "initialize"))
           (s (common-lisp-lsp::json-encode obj))
           (decoded (common-lisp-lsp::json-decode s)))
      (ok (equal "2.0" (common-lisp-lsp::json-get decoded "jsonrpc")))
      (ok (= 1 (common-lisp-lsp::json-get decoded "id")))
      (ok (equal "initialize" (common-lisp-lsp::json-get decoded "method")))))
  (testing "nested objects encode/decode"
    (let* ((obj (common-lisp-lsp::json-obj
                 :params (common-lisp-lsp::json-obj
                          :text-document (common-lisp-lsp::json-obj
                                         :uri "file:///foo.lisp"))))
           (s (common-lisp-lsp::json-encode obj))
           (decoded (common-lisp-lsp::json-decode s)))
      (ok (equal "file:///foo.lisp"
                 (common-lisp-lsp::json-getf decoded "params" "textDocument" "uri"))))))

(deftest json-special-values
  (testing "encoded JSON contains the right literal tokens"
    (let ((s (common-lisp-lsp::json-encode
              (common-lisp-lsp::json-obj :a :null :b :false :c t))))
      (ok (search "\"a\":null" s))
      (ok (search "\"b\":false" s))
      (ok (search "\"c\":true" s)))))

(deftest json-no-value-omits-fields
  (testing "json-obj drops :no-value fields"
    (let ((obj (common-lisp-lsp::json-obj :present 1 :absent :no-value)))
      (ok (= 1 (common-lisp-lsp::json-get obj "present")))
      (ok (null (assoc "absent" obj :test #'string=))))))
