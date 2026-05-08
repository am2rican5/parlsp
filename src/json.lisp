(in-package #:common-lisp-lsp)

;;;; JSON helpers wrapping cl-json with LSP-friendly conventions.
;;;;
;;;; Decoded representation:
;;;;   JSON object  -> alist of (string . value) pairs
;;;;   JSON array   -> list
;;;;   JSON null    -> :null
;;;;   true / false -> t / :false
;;;;
;;;; Encoded representation accepts:
;;;;   alists of (string-or-keyword . value), hash-tables, lists, atoms,
;;;;   the keywords :null and :false, and t.

(defun json-decode (string)
  "Parse STRING as JSON. Object keys are returned as strings, arrays as lists.
Note: cl-json conflates JSON null and false with NIL. We accept that on the
decode path because LSP traffic rarely needs to distinguish them in client
messages; the encode path preserves :NULL and :FALSE distinctly."
  (let ((json:*json-array-type* 'list)
        (json:*json-symbols-package* nil)
        (json:*json-identifier-name-to-lisp* #'identity)
        (json:*identifier-name-to-key* #'identity))
    (json:decode-json-from-string string)))

(defun %encode-value (value stream)
  (cond
    ((eq value :null)  (write-string "null" stream))
    ((eq value :false) (write-string "false" stream))
    ((eq value t)      (write-string "true" stream))
    ((null value)      (write-string "[]" stream))
    ((stringp value)   (json:encode-json value stream))
    ((numberp value)   (json:encode-json value stream))
    ((symbolp value)
     (json:encode-json (symbol-name-to-camel-case (symbol-name value)) stream))
    ((hash-table-p value) (%encode-hash value stream))
    ((and (consp value) (json-alistp value)) (%encode-alist value stream))
    ((listp value) (%encode-array value stream))
    (t (json:encode-json value stream))))

(defun json-alistp (x)
  "True when X looks like an alist of (string-or-keyword . any) pairs."
  (and (consp x)
       (every (lambda (cell)
                (and (consp cell)
                     (or (stringp (car cell))
                         (keywordp (car cell)))))
              x)))

(defun symbol-name-to-camel-case (name)
  "Convert a Lisp symbol-name like \"TEXT-DOCUMENT\" to \"textDocument\".
Single-word names like \"URI\" become \"uri\". This matches the cl-json
default lispy<->JSON identifier convention."
  (let ((result (make-array (length name) :element-type 'character
                                          :fill-pointer 0
                                          :adjustable t))
        (capitalize-next nil)
        (seen-letter nil))
    (loop for c across name do
      (cond
        ((char= c #\-) (setf capitalize-next t))
        ((char= c #\$)
         ;; pass through; treats $/foo style intact when used
         (vector-push-extend c result))
        (t
         (vector-push-extend
          (cond
            ((and capitalize-next seen-letter) (char-upcase c))
            (t (char-downcase c)))
          result)
         (setf capitalize-next nil)
         (setf seen-letter t))))
    (coerce result 'simple-string)))

(defun key-to-string (key)
  (etypecase key
    (string key)
    (keyword (symbol-name-to-camel-case (symbol-name key)))
    (symbol (symbol-name-to-camel-case (symbol-name key)))))

(defun %encode-key (key stream)
  (json:encode-json (key-to-string key) stream))

(defun %encode-alist (alist stream)
  (write-char #\{ stream)
  (loop for (cell . rest) on alist
        for first = t then nil
        do (unless first (write-char #\, stream))
           (%encode-key (car cell) stream)
           (write-char #\: stream)
           (%encode-value (cdr cell) stream))
  (write-char #\} stream))

(defun %encode-array (list stream)
  (write-char #\[ stream)
  (loop for (item . rest) on list
        for first = t then nil
        do (unless first (write-char #\, stream))
           (%encode-value item stream))
  (write-char #\] stream))

(defun %encode-hash (table stream)
  (write-char #\{ stream)
  (let ((first t))
    (maphash (lambda (k v)
               (unless first (write-char #\, stream))
               (setf first nil)
               (%encode-key k stream)
               (write-char #\: stream)
               (%encode-value v stream))
             table))
  (write-char #\} stream))

(defun json-encode (value)
  "Encode VALUE to a JSON string."
  (with-output-to-string (out)
    (%encode-value value out)))

(defun json-obj (&rest pairs)
  "Build an alist with string keys from a flat plist of (key value ...).
Keys may be strings, keywords, or symbols. Values that are :no-value are
omitted. This makes optional LSP fields easy to express."
  (loop for (k v) on pairs by #'cddr
        unless (eq v :no-value)
          collect (cons (key-to-string k) v)))

(defun json-get (object key &optional default)
  "Look up KEY (string) in OBJECT (alist) returning DEFAULT if missing."
  (let ((cell (assoc key object :test #'string=)))
    (if cell (cdr cell) default)))

(defun json-getf (object &rest keys)
  "Walk a chain of keys through nested alists."
  (let ((cur object))
    (dolist (k keys cur)
      (setf cur (json-get cur k)))))
