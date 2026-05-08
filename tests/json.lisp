(in-package #:parlsp/tests/main)

(deftest json-roundtrip
  (testing "object with string keys roundtrips"
    (let* ((obj (parlsp::json-obj :jsonrpc "2.0"
                                           :id 1
                                           :method "initialize"))
           (s (parlsp::json-encode obj))
           (decoded (parlsp::json-decode s)))
      (ok (equal "2.0" (parlsp::json-get decoded "jsonrpc")))
      (ok (= 1 (parlsp::json-get decoded "id")))
      (ok (equal "initialize" (parlsp::json-get decoded "method")))))
  (testing "nested objects encode/decode"
    (let* ((obj (parlsp::json-obj
                 :params (parlsp::json-obj
                          :text-document (parlsp::json-obj
                                         :uri "file:///foo.lisp"))))
           (s (parlsp::json-encode obj))
           (decoded (parlsp::json-decode s)))
      (ok (equal "file:///foo.lisp"
                 (parlsp::json-getf decoded "params" "textDocument" "uri"))))))

(deftest json-special-values
  (testing "encoded JSON contains the right literal tokens"
    (let ((s (parlsp::json-encode
              (parlsp::json-obj :a :null :b :false :c t))))
      (ok (search "\"a\":null" s))
      (ok (search "\"b\":false" s))
      (ok (search "\"c\":true" s)))))

(deftest json-no-value-omits-fields
  (testing "json-obj drops :no-value fields"
    (let ((obj (parlsp::json-obj :present 1 :absent :no-value)))
      (ok (= 1 (parlsp::json-get obj "present")))
      (ok (null (assoc "absent" obj :test #'string=))))))
