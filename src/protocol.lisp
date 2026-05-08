(in-package #:parlsp)

;;;; JSON-RPC 2.0 framing on top of the LSP base protocol.
;;;;
;;;; Wire format:
;;;;   Content-Length: <bytes>\r\n
;;;;   [Content-Type: ...\r\n]
;;;;   \r\n
;;;;   <UTF-8 JSON body of exactly <bytes> octets>
;;;;
;;;; Because Content-Length counts BYTES, not characters, we operate on
;;;; (unsigned-byte 8) streams and decode/encode UTF-8 ourselves.

(define-condition lsp-protocol-error (error)
  ((message :initarg :message :reader lsp-protocol-error-message))
  (:report (lambda (c s) (format s "LSP protocol error: ~A"
                                 (lsp-protocol-error-message c)))))

;;; ---------------------------------------------------------------------------
;;; Tiny UTF-8 codec (avoids depending on babel)

(defun utf8-byte-length (string)
  "Number of UTF-8 octets STRING would encode to."
  (length (utf8-encode string)))

(defun utf8-encode (string)
  "Return a (simple-array (unsigned-byte 8)) UTF-8 encoding of STRING."
  (let ((bytes (make-array (* 4 (length string))
                           :element-type '(unsigned-byte 8)
                           :fill-pointer 0
                           :adjustable t)))
    (loop for c across string
          for code = (char-code c)
          do (cond
               ((< code #x80)
                (vector-push-extend code bytes))
               ((< code #x800)
                (vector-push-extend (logior #xC0 (ash code -6)) bytes)
                (vector-push-extend (logior #x80 (logand code #x3F)) bytes))
               ((< code #x10000)
                (vector-push-extend (logior #xE0 (ash code -12)) bytes)
                (vector-push-extend (logior #x80 (logand (ash code -6) #x3F)) bytes)
                (vector-push-extend (logior #x80 (logand code #x3F)) bytes))
               (t
                (vector-push-extend (logior #xF0 (ash code -18)) bytes)
                (vector-push-extend (logior #x80 (logand (ash code -12) #x3F)) bytes)
                (vector-push-extend (logior #x80 (logand (ash code -6) #x3F)) bytes)
                (vector-push-extend (logior #x80 (logand code #x3F)) bytes))))
    (coerce bytes '(simple-array (unsigned-byte 8) (*)))))

(defun utf8-decode (bytes)
  "Decode a sequence of UTF-8 octets to a string. Replaces malformed sequences
with U+FFFD."
  (let ((s (make-array (length bytes) :element-type 'character
                                      :fill-pointer 0 :adjustable t))
        (len (length bytes))
        (i 0))
    (loop while (< i len) do
      (let ((b (aref bytes i)))
        (cond
          ((< b #x80)
           (vector-push-extend (code-char b) s)
           (incf i))
          ((< b #xC0)
           (vector-push-extend #\? s)
           (incf i))
          ((< b #xE0)
           (cond ((< (+ i 1) len)
                  (let ((b2 (aref bytes (+ i 1))))
                    (vector-push-extend
                     (code-char (logior (ash (logand b #x1F) 6)
                                        (logand b2 #x3F)))
                     s))
                  (incf i 2))
                 (t (incf i))))
          ((< b #xF0)
           (cond ((< (+ i 2) len)
                  (let ((b2 (aref bytes (+ i 1)))
                        (b3 (aref bytes (+ i 2))))
                    (vector-push-extend
                     (code-char (logior (ash (logand b #x0F) 12)
                                        (ash (logand b2 #x3F) 6)
                                        (logand b3 #x3F)))
                     s))
                  (incf i 3))
                 (t (incf i))))
          (t
           (cond ((< (+ i 3) len)
                  (let ((b2 (aref bytes (+ i 1)))
                        (b3 (aref bytes (+ i 2)))
                        (b4 (aref bytes (+ i 3))))
                    (vector-push-extend
                     (code-char (logior (ash (logand b #x07) 18)
                                        (ash (logand b2 #x3F) 12)
                                        (ash (logand b3 #x3F) 6)
                                        (logand b4 #x3F)))
                     s))
                  (incf i 4))
                 (t (incf i)))))))
    (coerce s 'simple-string)))

;;; ---------------------------------------------------------------------------
;;; Header parsing on a binary stream

(defun read-byte* (stream)
  (read-byte stream nil nil))

(defun read-header-line-bytes (stream)
  "Read one header line terminated by CRLF (or bare LF). Returns the line
as a string (ASCII) or NIL on clean EOF before any byte was read."
  (let ((bytes (make-array 64 :element-type '(unsigned-byte 8)
                              :fill-pointer 0 :adjustable t))
        (saw-any nil))
    (loop
      (let ((b (read-byte* stream)))
        (cond
          ((null b)
           (return-from read-header-line-bytes
             (if saw-any
                 (utf8-decode bytes)
                 nil)))
          ((= b 13)                     ; CR
           (setf saw-any t)
           (let ((n (read-byte* stream)))
             (cond
               ((and n (= n 10)) (return-from read-header-line-bytes
                                   (utf8-decode bytes)))
               (t (error 'lsp-protocol-error
                         :message "Malformed header: CR without LF")))))
          ((= b 10)                     ; bare LF
           (setf saw-any t)
           (return-from read-header-line-bytes (utf8-decode bytes)))
          (t (setf saw-any t)
             (vector-push-extend b bytes)))))))

(defun parse-headers (stream)
  "Read header lines until the blank separator. Returns an alist of
(lower-case-name . trimmed-value), or NIL on EOF before any data."
  (let ((headers '())
        (got-any nil))
    (loop
      (let ((line (read-header-line-bytes stream)))
        (cond
          ((null line)
           (return-from parse-headers (if got-any (nreverse headers) nil)))
          ((zerop (length line))
           (return-from parse-headers (nreverse headers)))
          (t
           (setf got-any t)
           (let ((colon (position #\: line)))
             (unless colon
               (error 'lsp-protocol-error
                      :message (format nil "Malformed header: ~A" line)))
             (let ((name (string-trim '(#\Space #\Tab) (subseq line 0 colon)))
                   (value (string-trim '(#\Space #\Tab) (subseq line (1+ colon)))))
               (push (cons (string-downcase name) value) headers)))))))))

;;; ---------------------------------------------------------------------------
;;; Public read/write API

(defun read-message (stream)
  "Read one complete JSON-RPC message from binary STREAM. Returns the
decoded JSON object (alist) or NIL on clean EOF."
  (let ((headers (parse-headers stream)))
    (when (null headers)
      (return-from read-message nil))
    (let* ((cl-cell (assoc "content-length" headers :test #'string=))
           (cl-string (and cl-cell (cdr cl-cell))))
      (unless cl-string
        (error 'lsp-protocol-error
               :message "Missing Content-Length header"))
      (let* ((n (parse-integer cl-string))
             (buf (make-array n :element-type '(unsigned-byte 8))))
        (let ((read (read-sequence buf stream)))
          (unless (= read n)
            (error 'lsp-protocol-error
                   :message (format nil
                                    "Short read: expected ~D bytes, got ~D"
                                    n read))))
        (json-decode (utf8-decode buf))))))

(defparameter +crlf-bytes+
  (make-array 2 :element-type '(unsigned-byte 8) :initial-contents '(13 10)))

(defun write-message (stream object)
  "Encode OBJECT as JSON-RPC and write it (with framing) to binary STREAM."
  (let* ((body-bytes (utf8-encode (json-encode object)))
         (n (length body-bytes))
         (header (utf8-encode (format nil "Content-Length: ~D" n))))
    (write-sequence header stream)
    (write-sequence +crlf-bytes+ stream)
    (write-sequence +crlf-bytes+ stream)
    (write-sequence body-bytes stream)
    (finish-output stream)))

(defun make-response (id result)
  (json-obj :jsonrpc "2.0" :id id :result result))

(defun make-error-response (id code message &optional data)
  (json-obj :jsonrpc "2.0"
            :id (or id :null)
            :error (json-obj :code code
                             :message message
                             :data (or data :no-value))))

(defun make-notification (method params)
  (json-obj :jsonrpc "2.0" :method method :params params))

;;; ---------------------------------------------------------------------------
;;; Method dispatch

(defvar *handlers* (make-hash-table :test 'equal)
  "Method name (string) -> function (server params) -> result.")

(defun register-handler (method fn)
  (setf (gethash method *handlers*) fn))

(defmacro define-handler (method (server params) &body body)
  "Register a handler for METHOD. The body executes inside a block named
HANDLER, so handlers can early-return with (return-from handler ...).
Leading DECLARE forms are lifted out to the lambda."
  (let ((decls '())
        (forms body))
    (loop while (and (consp forms)
                     (consp (first forms))
                     (eq (caar forms) 'declare))
          do (push (pop forms) decls))
    `(register-handler ,method
                       (lambda (,server ,params)
                         ,@(nreverse decls)
                         (block handler ,@forms)))))

(defun dispatch (server message)
  "Process a decoded MESSAGE. Return a response object (to send back) or
NIL when no response is required."
  (let* ((method (json-get message "method"))
         (id     (json-get message "id"))
         (params (json-get message "params")))
    (cond
      ((and (null method) id)
       (log-debug "Ignoring response from client: ~A" message)
       nil)
      ((null method)
       (make-error-response id -32600 "Invalid request: no method"))
      (t
       (let ((handler (gethash method *handlers*)))
         (cond
           ((null handler)
            (log-debug "Unhandled method: ~A" method)
            (when id
              (make-error-response
               id -32601 (format nil "Method not found: ~A" method))))
           (t
            (handler-case
                (let ((result (funcall handler server params)))
                  (when id
                    (make-response id (or result :null))))
              (error (e)
                (log-error "Handler ~A signaled: ~A" method e)
                (when id
                  (make-error-response
                   id -32603
                   (format nil "Internal error: ~A" e))))))))))))
