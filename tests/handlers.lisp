(in-package #:parlsp/tests/main)

(defun open-doc (server uri text)
  (parlsp:dispatch
   server
   (parlsp::json-obj
    :jsonrpc "2.0"
    :method "textDocument/didOpen"
    :params (parlsp::json-obj
             :text-document (parlsp::json-obj
                            :uri uri
                            :language-id "lisp"
                            :version 1
                            :text text)))))

(defun new-server-for-test ()
  (parlsp:make-server
   :input nil
   :output (make-output)))

(deftest initialize-returns-capabilities
  (testing "initialize result advertises completion + hover"
    (let* ((server (new-server-for-test))
           (resp (parlsp:dispatch
                  server
                  (parlsp::json-obj
                   :jsonrpc "2.0" :id 1 :method "initialize"
                   :params (parlsp::json-obj))))
           (caps (parlsp::json-getf resp "result" "capabilities")))
      (ok (eq t (parlsp::json-get caps "hoverProvider")))
      (ok (= 1 (parlsp::json-get caps "textDocumentSync")))
      (ok (parlsp::json-get caps "completionProvider")))))

(deftest didopen-stores-document-and-publishes-diagnostics
  (testing "open + close lifecycle"
    (let ((server (new-server-for-test)))
      (open-doc server "file:///foo.lisp" "(defun foo () 1)")
      (ok (= 1 (hash-table-count (parlsp::server-documents server))))
      (parlsp:dispatch
       server
       (parlsp::json-obj
        :jsonrpc "2.0"
        :method "textDocument/didClose"
        :params (parlsp::json-obj
                 :text-document (parlsp::json-obj
                                :uri "file:///foo.lisp"))))
      (ok (zerop (hash-table-count
                  (parlsp::server-documents server)))))))

(deftest completion-returns-symbol-prefix-matches
  (testing "prefix DEF expands to many defining forms"
    (let ((server (new-server-for-test)))
      (open-doc server "file:///c.lisp"
                "(def")
      (let* ((resp (parlsp:dispatch
                    server
                    (parlsp::json-obj
                     :jsonrpc "2.0" :id 2 :method "textDocument/completion"
                     :params (parlsp::json-obj
                              :text-document (parlsp::json-obj
                                             :uri "file:///c.lisp")
                              :position (parlsp::json-obj
                                         :line 0 :character 4)))))
             (items (parlsp::json-getf resp "result" "items"))
             (labels (mapcar (lambda (i)
                               (parlsp::json-get i "label"))
                             items)))
        (ok (member "defun" labels :test #'string=))
        (ok (member "defclass" labels :test #'string=))))))

(deftest documentsymbol-lists-toplevel-defs
  (testing "documentSymbol surfaces defun + defvar"
    (let ((server (new-server-for-test)))
      (open-doc server "file:///d.lisp"
                (format nil "(defun foo () 1)~%(defvar *bar* 2)"))
      (let* ((resp (parlsp:dispatch
                    server
                    (parlsp::json-obj
                     :jsonrpc "2.0" :id 3 :method "textDocument/documentSymbol"
                     :params (parlsp::json-obj
                              :text-document (parlsp::json-obj
                                             :uri "file:///d.lisp")))))
             (syms (parlsp::json-get resp "result")))
        (ok (= 2 (length syms)))
        (ok (member "foo"
                    (mapcar (lambda (s) (parlsp::json-get s "name"))
                            syms)
                    :test #'string=))))))

(deftest definition-finds-local-defun
  (testing "definition jumps to in-buffer defun"
    (let ((server (new-server-for-test)))
      (open-doc server "file:///e.lisp"
                (format nil "(defun foo () 1)~%(foo)"))
      (let* ((resp (parlsp:dispatch
                    server
                    (parlsp::json-obj
                     :jsonrpc "2.0" :id 4 :method "textDocument/definition"
                     :params (parlsp::json-obj
                              :text-document (parlsp::json-obj
                                             :uri "file:///e.lisp")
                              :position (parlsp::json-obj
                                         :line 1 :character 2)))))
             (loc (parlsp::json-get resp "result")))
        (ok loc)
        (ok (= 0 (parlsp::json-getf loc "range" "start" "line")))))))

(deftest hover-returns-markdown-for-cl-symbol
  (testing "hover on CL:CAR gives back markdown"
    (let ((server (new-server-for-test)))
      (open-doc server "file:///h.lisp" "(car '(1 2))")
      (let* ((resp (parlsp:dispatch
                    server
                    (parlsp::json-obj
                     :jsonrpc "2.0" :id 5 :method "textDocument/hover"
                     :params (parlsp::json-obj
                              :text-document (parlsp::json-obj
                                             :uri "file:///h.lisp")
                              :position (parlsp::json-obj
                                         :line 0 :character 2)))))
             (contents (parlsp::json-getf resp "result" "contents")))
        (ok contents)
        (ok (search "car" (parlsp::json-get contents "value")
                    :test #'char-equal))))))
