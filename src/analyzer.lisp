(in-package #:common-lisp-lsp)

;;;; Lightweight static analysis of a Common Lisp source string.
;;;; We never EVAL user code. We use the standard reader against an
;;;; isolated sandbox package to extract top-level forms, plus a
;;;; character-level scanner to find symbol boundaries at a given offset.

;;; ---------------------------------------------------------------------------
;;; Symbol-at-position

(defparameter *cl-symbol-terminators*
  '(#\Space #\Tab #\Newline #\Return #\( #\) #\' #\` #\, #\; #\" #\#)
  "Characters that end an unquoted Lisp symbol.")

(defun symbol-char-p (ch)
  (and ch (not (find ch *cl-symbol-terminators*))))

(defun symbol-at-position (text offset)
  "Return (values name start-offset end-offset) for the symbol surrounding
OFFSET in TEXT, or NIL if OFFSET is not inside a symbol."
  (let ((len (length text)))
    (when (or (< offset 0) (> offset len))
      (return-from symbol-at-position nil))
    ;; Walk left to find the start.
    (let ((start offset))
      (loop while (and (> start 0)
                       (symbol-char-p (char text (1- start))))
            do (decf start))
      (let ((end offset))
        (loop while (and (< end len)
                         (symbol-char-p (char text end)))
              do (incf end))
        (if (= start end)
            nil
            (values (subseq text start end) start end))))))

;;; ---------------------------------------------------------------------------
;;; Top-level form scanner

(defun skip-whitespace-and-comments (text idx)
  "Return the next non-whitespace, non-comment index in TEXT starting at IDX."
  (let ((len (length text))
        (i idx))
    (loop while (< i len) do
      (let ((c (char text i)))
        (cond
          ((member c '(#\Space #\Tab #\Newline #\Return #\Page))
           (incf i))
          ((char= c #\;)
           ;; line comment to end-of-line
           (loop while (and (< i len) (char/= (char text i) #\Newline))
                 do (incf i)))
          ((and (char= c #\#)
                (< (1+ i) len)
                (char= (char text (1+ i)) #\|))
           ;; block comment #| ... |#
           (incf i 2)
           (loop while (< (1+ i) len)
                 until (and (char= (char text i) #\|)
                            (char= (char text (1+ i)) #\#))
                 do (incf i))
           (incf i 2))
          (t (return)))))
    i))

(defun scan-string (text idx)
  "Skip a Common Lisp string literal starting at TEXT[IDX] (which is #\\\")."
  (let ((len (length text))
        (i (1+ idx)))
    (loop while (< i len)
          for c = (char text i) do
            (cond
              ((char= c #\\) (incf i 2))
              ((char= c #\") (return-from scan-string (1+ i)))
              (t (incf i))))
    len))

(defun scan-form (text idx)
  "Return the index just past the top-level form starting at IDX in TEXT,
or NIL if IDX is past end of input."
  (let ((len (length text))
        (i (skip-whitespace-and-comments text idx)))
    (when (>= i len) (return-from scan-form nil))
    (let ((c (char text i)))
      (cond
        ((char= c #\()
         (let ((depth 1)
               (j (1+ i)))
           (loop while (and (< j len) (> depth 0)) do
             (let ((cj (char text j)))
               (cond
                 ((char= cj #\;)
                  (loop while (and (< j len) (char/= (char text j) #\Newline))
                        do (incf j)))
                 ((char= cj #\")
                  (setf j (scan-string text j)))
                 ((char= cj #\\) (incf j 2))
                 ((char= cj #\() (incf depth) (incf j))
                 ((char= cj #\)) (decf depth) (incf j))
                 (t (incf j)))))
           j))
        ((char= c #\")
         (scan-string text i))
        (t
         ;; atom (or reader macro abbreviation): consume until terminator
         (let ((j i))
           (loop while (and (< j len) (symbol-char-p (char text j)))
                 do (incf j))
           (max (1+ i) j)))))))

(defun scan-form-with-start (text idx)
  "Return (values start-idx end-idx) of the next top-level form on or after
IDX, or NIL if none."
  (let ((start (skip-whitespace-and-comments text idx)))
    (when (>= start (length text)) (return-from scan-form-with-start nil))
    (let ((end (scan-form text start)))
      (when end (values start end)))))

;;; ---------------------------------------------------------------------------
;;; Top-level definition extraction

(defparameter *definition-forms*
  '(("DEFUN"          . :function)
    ("DEFGENERIC"     . :function)
    ("DEFMETHOD"      . :method)
    ("DEFMACRO"       . :function)
    ("DEFINE-COMPILER-MACRO" . :function)
    ("DEFVAR"         . :variable)
    ("DEFPARAMETER"   . :variable)
    ("DEFCONSTANT"    . :constant)
    ("DEFCLASS"       . :class)
    ("DEFSTRUCT"      . :struct)
    ("DEFTYPE"        . :type)
    ("DEFPACKAGE"     . :package)
    ("DEFINE-CONDITION" . :class)))

(defun lsp-symbol-kind (kind)
  "Map our internal definition kind to LSP SymbolKind numbers."
  (ecase kind
    (:function 12) ; Function
    (:method 6)    ; Method
    (:variable 13) ; Variable
    (:constant 14) ; Constant
    (:class 5)     ; Class
    (:struct 23)   ; Struct
    (:type 26)     ; TypeParameter (closest)
    (:package 4)   ; Package
    (:other 1)))   ; File

(defun lsp-completion-kind (kind)
  (case kind
    (:function 3)  ; Function
    (:method 2)    ; Method
    (:variable 6)  ; Variable
    (:constant 21) ; Constant
    (:class 7)     ; Class
    (:struct 22)   ; Struct
    (:type 25)     ; TypeParameter
    (:package 9)   ; Module
    (otherwise 14)))

(defun parse-form-head (text start end)
  "Given a top-level form occupying [START,END) in TEXT, return
(values head-symbol-name name-symbol-name)
where HEAD is the operator (e.g. DEFUN) and NAME is the second element
(the defined symbol's printed representation), both upcased and trimmed
of package prefixes if any. Returns NIL components if shape doesn't match."
  (let ((s (subseq text start end)))
    (when (and (> (length s) 0) (char= (char s 0) #\())
      (let ((tokens (tokenize-list-prefix s 2)))
        (values (first tokens) (second tokens))))))

(defun tokenize-list-prefix (form-string max-tokens)
  "Pull up to MAX-TOKENS leading atom-tokens out of a parenthesized form
string (which begins with '('). Skips reader-macro chars like ' ` , @.
Strips surrounding pipes |...| and lower-cases nothing — we return
upper-cased printed names suitable for matching."
  (let ((len (length form-string))
        (i 1)                             ; skip the leading '('
        (out '()))
    (loop while (and (< i len) (< (length out) max-tokens)) do
      (setf i (skip-whitespace-and-comments form-string i))
      (when (>= i len) (return))
      (let ((c (char form-string i)))
        (cond
          ((char= c #\)) (return))
          ((char= c #\() ; nested list: skip it whole, do not record
           (let ((end (scan-form form-string i)))
             (setf i (or end len))
             (push :list out)))
          ((char= c #\")
           (setf i (scan-string form-string i))
           (push :string out))
          ((member c '(#\' #\` #\, #\@))
           (incf i))
          (t
           (multiple-value-bind (tok new-i)
               (read-bare-token form-string i)
             (setf i new-i)
             (push tok out))))))
    (let ((tokens (nreverse out)))
      ;; filter pseudo-tokens before returning printable strings
      (mapcar (lambda (tok) (when (stringp tok) (string-upcase tok)))
              tokens))))

(defun read-bare-token (text idx)
  "Read a bare symbol-like token starting at IDX. Handles |escaped names|.
Returns (values token-string new-idx)."
  (let ((len (length text)))
    (cond
      ;; |escaped| symbol: keep contents, drop the bars
      ((char= (char text idx) #\|)
       (let ((j (1+ idx)))
         (loop while (< j len)
               for c = (char text j) do
                 (cond
                   ((char= c #\\) (incf j 2))
                   ((char= c #\|) (return))
                   (t (incf j))))
         (values (subseq text (1+ idx) (min j len))
                 (min (1+ j) len))))
      (t
       (let ((j idx))
         (loop while (and (< j len) (symbol-char-p (char text j)))
               do (incf j))
         (values (strip-package-prefix (subseq text idx j)) j))))))

(defun strip-package-prefix (token)
  "If TOKEN contains '::' or ':', strip everything up to and including
the colon(s). Keep keyword leading colon as empty package."
  (let ((p (position #\: token)))
    (if p
        (let ((after (if (and (< (1+ p) (length token))
                              (char= (char token (1+ p)) #\:))
                         (+ p 2) (1+ p))))
          (subseq token after))
        token)))

(defstruct toplevel-def
  name              ; printed name string (upper-cased, package-stripped)
  kind              ; keyword from *DEFINITION-FORMS* values
  start-offset      ; integer
  end-offset)       ; integer

(defun document-symbols (text)
  "Scan TEXT and return a list of TOPLEVEL-DEF for each definition form."
  (let ((defs '()))
    (loop with i = 0
          while (< i (length text)) do
            (multiple-value-bind (start end)
                (scan-form-with-start text i)
              (unless start (return))
              (multiple-value-bind (head name)
                  (parse-form-head text start end)
                (let ((kind (and head
                                 (cdr (assoc head *definition-forms*
                                             :test #'string=)))))
                  (when (and kind name)
                    (push (make-toplevel-def
                           :name name
                           :kind kind
                           :start-offset start
                           :end-offset end)
                          defs))))
              (setf i end)))
    (nreverse defs)))

;;; ---------------------------------------------------------------------------
;;; Diagnostics

(defun diagnostics-for-text (text)
  "Return a list of diagnostic alists for TEXT. Currently surfaces unbalanced
parentheses and reader errors."
  (let ((diags '())
        (paren-stack '()))      ; each entry: (line column)
    ;; Pass 1: bracket balance using the raw scanner.
    (let ((line 0)
          (col 0)
          (i 0)
          (len (length text)))
      (loop while (< i len) do
        (let ((c (char text i)))
          (cond
            ((char= c #\Newline) (incf line) (setf col 0) (incf i))
            ((member c '(#\Space #\Tab #\Return #\Page)) (incf col) (incf i))
            ((char= c #\;)
             ;; line comment
             (loop while (and (< i len) (char/= (char text i) #\Newline))
                   do (incf i) (incf col)))
            ((and (char= c #\#)
                  (< (1+ i) len)
                  (char= (char text (1+ i)) #\|))
             ;; block comment
             (incf i 2) (incf col 2)
             (loop while (< (1+ i) len)
                   until (and (char= (char text i) #\|)
                              (char= (char text (1+ i)) #\#))
                   do (cond ((char= (char text i) #\Newline)
                             (incf line) (setf col 0))
                            (t (incf col)))
                      (incf i))
             (incf i 2) (incf col 2))
            ((char= c #\")
             ;; track newlines inside string for accurate positions
             (let ((j (1+ i)))
               (loop while (< j len) do
                 (let ((cj (char text j)))
                   (cond
                     ((char= cj #\\)
                      (incf j 2) (incf col 2))
                     ((char= cj #\Newline)
                      (incf line) (setf col 0) (incf j))
                     ((char= cj #\")
                      (incf j) (incf col)
                      (return))
                     (t (incf j) (incf col)))))
               (when (>= j len)
                 (push (json-obj
                        :range (json-obj
                                :start (json-obj :line line :character col)
                                :end   (json-obj :line line :character (1+ col)))
                        :severity 1
                        :source "cl-lsp"
                        :message "Unterminated string literal")
                       diags))
               (setf i j)))
            ((char= c #\()
             (push (list line col) paren-stack)
             (incf i) (incf col))
            ((char= c #\))
             (cond
               ((null paren-stack)
                (push (json-obj
                       :range (json-obj
                               :start (json-obj :line line :character col)
                               :end   (json-obj :line line :character (1+ col)))
                       :severity 1
                       :source "cl-lsp"
                       :message "Unmatched closing parenthesis")
                      diags))
               (t (pop paren-stack)))
             (incf i) (incf col))
            (t (incf i) (incf col))))))
    ;; Any remaining opens are unmatched.
    (dolist (open paren-stack)
      (destructuring-bind (line col) open
        (push (json-obj
               :range (json-obj
                       :start (json-obj :line line :character col)
                       :end   (json-obj :line line :character (1+ col)))
               :severity 1
               :source "cl-lsp"
               :message "Unmatched opening parenthesis")
              diags)))
    (nreverse diags)))

;;; ---------------------------------------------------------------------------
;;; Completion source: every external symbol of COMMON-LISP plus the names
;;; defined in the current document.

(defparameter *cl-symbol-cache*
  (let ((names '()))
    (do-external-symbols (s (find-package :common-lisp))
      (push (symbol-name s) names))
    (sort (delete-duplicates names :test #'string=) #'string<))
  "Sorted list of every external symbol name of the COMMON-LISP package.")

(defun completions-for-prefix (prefix doc-text &key (limit 200))
  "Return a list of (name . kind) candidates whose names start with PREFIX."
  (let* ((up (string-upcase prefix))
         (cl (loop for n in *cl-symbol-cache*
                   when (and (>= (length n) (length up))
                             (string= up n :end2 (length up)))
                     collect (cons n :function)))
         (doc-defs (loop for def in (document-symbols doc-text)
                         when (and (>= (length (toplevel-def-name def))
                                       (length up))
                                   (string= up (toplevel-def-name def)
                                            :end2 (length up)))
                           collect (cons (toplevel-def-name def)
                                         (toplevel-def-kind def))))
         (all (append doc-defs cl)))
    (subseq all 0 (min limit (length all)))))

;;; ---------------------------------------------------------------------------
;;; Hover / signature: pull the documentation string and arg-list for known
;;; CL symbols at runtime via FIND-SYMBOL + DOCUMENTATION.

(defun describe-cl-symbol (name)
  "Return a markdown documentation string for the named symbol if it's
present in COMMON-LISP. Returns NIL otherwise."
  (let ((sym (find-symbol (string-upcase name) :common-lisp)))
    (when (and sym (eq (symbol-package sym) (find-package :common-lisp)))
      (let* ((kinds '((function "function")
                      (variable "variable")
                      (type "type")))
             (parts '()))
        (when (and (fboundp sym) (not (macro-function sym)))
          (push (format nil "**~A** _function_~%~%```lisp~%~A~%```"
                        (string-downcase name)
                        (or (lambda-list-string sym) ""))
                parts))
        (when (macro-function sym)
          (push (format nil "**~A** _macro_~%~%```lisp~%~A~%```"
                        (string-downcase name)
                        (or (lambda-list-string sym) ""))
                parts))
        (when (boundp sym)
          (push (format nil "**~A** _variable_" (string-downcase name)) parts))
        (loop for (key label) in kinds
              for doc = (documentation sym key)
              when doc do (push (format nil "_~A doc_:~%~A" label doc) parts))
        (when parts
          (format nil "~{~A~^~%~%~}" (nreverse parts)))))))

(defun lambda-list-string (sym)
  #+sbcl (handler-case (format nil "(~A~{ ~A~})" (string-downcase (symbol-name sym))
                               (sb-introspect:function-lambda-list sym))
           (error () nil))
  #-sbcl nil)
