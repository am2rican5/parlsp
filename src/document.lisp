(in-package #:common-lisp-lsp)

;;;; In-memory document model. LSP positions are zero-based (line, character).
;;;; We maintain the document text plus a cached vector of line-start byte
;;;; offsets so we can map between (line, character) and absolute offsets
;;;; cheaply.

(defclass document ()
  ((uri      :initarg :uri      :reader document-uri)
   (language :initarg :language :reader document-language :initform "lisp")
   (version  :initarg :version  :accessor document-version :initform 0)
   (text     :initarg :text     :reader document-text     :initform "")
   (lines    :accessor document-lines    :initform #(0))))

(defun make-document (&key uri (language "lisp") (version 0) (text ""))
  (let ((doc (make-instance 'document
                            :uri uri
                            :language language
                            :version version
                            :text text)))
    (recompute-lines doc)
    doc))

(defun recompute-lines (doc)
  "Recompute line-start offsets for DOC.
Stores them in (document-lines doc) as a simple vector of unsigned-fixnum."
  (let* ((s (document-text doc))
         (len (length s))
         (offsets (list 0)))
    (loop for i below len
          for ch = (char s i)
          when (char= ch #\Newline)
            do (push (1+ i) offsets))
    (setf (document-lines doc)
          (coerce (nreverse offsets) 'vector))))

(defun document-set-text (doc new-text &optional new-version)
  (setf (slot-value doc 'text) new-text)
  (when new-version (setf (document-version doc) new-version))
  (recompute-lines doc)
  doc)

(defun document-line-count (doc)
  (length (document-lines doc)))

(defun document-line (doc line-index)
  "Return the text of LINE-INDEX (0-based) without the trailing newline."
  (let* ((lines (document-lines doc))
         (text (document-text doc))
         (count (length lines)))
    (cond
      ((>= line-index count) "")
      (t
       (let* ((start (aref lines line-index))
              (end (if (< (1+ line-index) count)
                       (aref lines (1+ line-index))
                       (length text)))
              ;; strip trailing newline if present
              (line-end (if (and (> end start)
                                 (char= (char text (1- end)) #\Newline))
                            (1- end)
                            end)))
         (subseq text start line-end))))))

(defun position-to-offset (doc line character)
  "Convert an LSP (line, character) position to a 0-based string offset.
Out-of-range positions clamp to text length to avoid crashes on bad clients."
  (let* ((text (document-text doc))
         (lines (document-lines doc))
         (text-len (length text))
         (line (max 0 (min line (1- (length lines))))))
    (when (zerop (length lines)) (return-from position-to-offset 0))
    (let* ((start (aref lines line))
           (next  (if (< (1+ line) (length lines))
                      (aref lines (1+ line))
                      text-len))
           (line-end (if (and (> next start)
                              (char= (char text (1- next)) #\Newline))
                         (1- next)
                         next))
           (line-len (- line-end start))
           (col (max 0 (min character line-len))))
      (+ start col))))

(defun offset-to-position (doc offset)
  "Inverse of POSITION-TO-OFFSET. Returns (values line character)."
  (let* ((lines (document-lines doc))
         (text-len (length (document-text doc)))
         (offset (max 0 (min offset text-len))))
    ;; binary search for the largest line whose start <= offset
    (loop with lo = 0
          with hi = (1- (length lines))
          while (< lo hi)
          for mid = (ceiling (+ lo hi) 2)
          do (if (<= (aref lines mid) offset)
                 (setf lo mid)
                 (setf hi (1- mid)))
          finally (return (values lo (- offset (aref lines lo)))))))

(defun apply-range-change (doc range new-text)
  "Apply an incremental textDocument/didChange update."
  (let* ((start (json-getf range "start"))
         (end   (json-getf range "end"))
         (start-off (position-to-offset doc
                                        (json-get start "line" 0)
                                        (json-get start "character" 0)))
         (end-off   (position-to-offset doc
                                        (json-get end "line" 0)
                                        (json-get end "character" 0)))
         (text (document-text doc)))
    (when (> start-off end-off)
      (rotatef start-off end-off))
    (document-set-text doc
                       (concatenate 'string
                                    (subseq text 0 start-off)
                                    new-text
                                    (subseq text end-off)))))

(defun document-apply-change (doc change)
  "Apply a single LSP TextDocumentContentChangeEvent (CHANGE is alist).
If it has a RANGE field we apply incrementally; otherwise treat TEXT as
the full document content."
  (let ((range (json-get change "range"))
        (text  (json-get change "text" "")))
    (if range
        (apply-range-change doc range text)
        (document-set-text doc text))))
