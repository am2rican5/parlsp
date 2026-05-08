(in-package #:common-lisp-lsp/tests/main)

(defclass byte-vector-input-stream
    (trivial-gray-streams:fundamental-binary-input-stream)
  ((buffer :initarg :buffer :accessor bv-buffer)
   (index  :initarg :index  :accessor bv-index :initform 0)))

(defmethod trivial-gray-streams:stream-read-byte ((s byte-vector-input-stream))
  (let ((i (bv-index s)) (b (bv-buffer s)))
    (cond ((>= i (length b)) :eof)
          (t (prog1 (aref b i) (setf (bv-index s) (1+ i)))))))

(defmethod trivial-gray-streams:stream-read-sequence
    ((s byte-vector-input-stream) sequence start end &key)
  (let* ((buf (bv-buffer s))
         (idx (bv-index s))
         (avail (- (length buf) idx))
         (want (- end start))
         (n (min want avail)))
    (loop for i from 0 below n do
      (setf (aref sequence (+ start i)) (aref buf (+ idx i))))
    (incf (bv-index s) n)
    (+ start n)))

(defclass byte-vector-output-stream (trivial-gray-streams:fundamental-binary-output-stream)
  ((bytes :initform (make-array 64 :element-type '(unsigned-byte 8)
                                   :fill-pointer 0 :adjustable t)
          :accessor bvo-bytes)))

(defmethod trivial-gray-streams:stream-write-byte
    ((s byte-vector-output-stream) byte)
  (vector-push-extend byte (bvo-bytes s))
  byte)

(defmethod trivial-gray-streams:stream-write-sequence
    ((s byte-vector-output-stream) sequence start end &key)
  (loop for i from start below end do
    (vector-push-extend (aref sequence i) (bvo-bytes s)))
  sequence)

(defmethod trivial-gray-streams:stream-finish-output
    ((s byte-vector-output-stream))
  nil)

(defmethod trivial-gray-streams:stream-force-output
    ((s byte-vector-output-stream))
  nil)

(defun make-input-from-string (s)
  (make-instance 'byte-vector-input-stream
                 :buffer (common-lisp-lsp::utf8-encode s)))

(defun make-output ()
  (make-instance 'byte-vector-output-stream))

(defun output-string (out)
  (common-lisp-lsp::utf8-decode (coerce (bvo-bytes out)
                                        '(simple-array (unsigned-byte 8) (*)))))

(deftest read-message-parses-headers-and-body
  (testing "simple initialize request roundtrip"
    (let* ((body "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}")
           (msg (format nil "Content-Length: ~D~A~A~A"
                        (length body)
                        #.(coerce '(#\Return #\Newline) 'string)
                        #.(coerce '(#\Return #\Newline) 'string)
                        body))
           (in (make-input-from-string msg))
           (decoded (common-lisp-lsp:read-message in)))
      (ok (equal "2.0" (common-lisp-lsp::json-get decoded "jsonrpc")))
      (ok (= 1 (common-lisp-lsp::json-get decoded "id")))
      (ok (equal "initialize" (common-lisp-lsp::json-get decoded "method"))))))

(deftest write-message-frames-correctly
  (testing "Content-Length matches UTF-8 byte length"
    (let* ((out (make-output))
           (obj (common-lisp-lsp::json-obj :jsonrpc "2.0" :id 7 :result :null)))
      (common-lisp-lsp:write-message out obj)
      (let* ((wire (output-string out))
             (cl-pos (search "Content-Length:" wire))
             (eol (position #\Return wire))
             (n (parse-integer (string-trim '(#\Space)
                                            (subseq wire
                                                    (+ cl-pos (length "Content-Length:"))
                                                    eol))))
             (separator (search (coerce '(#\Return #\Newline #\Return #\Newline) 'string)
                                wire))
             (body (subseq wire (+ separator 4))))
        (ok (= n (common-lisp-lsp::utf8-byte-length body)))
        (ok (search "\"id\":7" body))))))

(deftest dispatch-unknown-method-returns-method-not-found
  (testing "unknown request gets -32601"
    (let* ((server (common-lisp-lsp:make-server
                    :input nil
                    :output (make-output)))
           (msg (common-lisp-lsp::json-obj
                 :jsonrpc "2.0" :id 99 :method "no/such/method"))
           (resp (common-lisp-lsp:dispatch server msg)))
      (ok (= 99 (common-lisp-lsp::json-get resp "id")))
      (ok (= -32601
             (common-lisp-lsp::json-getf resp "error" "code"))))))

(deftest dispatch-notification-returns-nil
  (testing "notifications produce no response"
    (let ((server (common-lisp-lsp:make-server
                   :input nil
                   :output (make-output))))
      (ok (null (common-lisp-lsp:dispatch
                 server
                 (common-lisp-lsp::json-obj
                  :jsonrpc "2.0" :method "no/such/method")))))))
