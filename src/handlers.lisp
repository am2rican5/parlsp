(in-package #:common-lisp-lsp)

;;;; LSP method handlers. Each handler is keyed by the JSON-RPC method
;;;; name and receives (SERVER PARAMS) where PARAMS is the decoded
;;;; alist of request params. Request handlers return a result object;
;;;; notification handlers return NIL.

;;; ---------------------------------------------------------------------------
;;; Capabilities

(defun server-capabilities ()
  (json-obj
   :text-document-sync 1                  ; full sync
   :completion-provider (json-obj :trigger-characters '(":" "(" "*"))
   :hover-provider t
   :definition-provider t
   :document-symbol-provider t
   :document-formatting-provider :false
   :workspace-symbol-provider :false))

(defun server-info ()
  (json-obj :name "common-lisp-lsp" :version "0.1.0"))

;;; ---------------------------------------------------------------------------
;;; Lifecycle

(define-handler "initialize" (server params)
  (declare (ignore params))
  (log-info "initialize received")
  (json-obj :capabilities (server-capabilities)
            :server-info (server-info)))

(define-handler "initialized" (server params)
  (declare (ignore server params))
  (log-info "client initialized")
  nil)

(define-handler "shutdown" (server params)
  (declare (ignore params))
  (log-info "shutdown requested")
  (setf (server-shutdown-requested-p server) t)
  :null)

(define-handler "exit" (server params)
  (declare (ignore params))
  (log-info "exit notification")
  (signal 'server-exit :code (if (server-shutdown-requested-p server) 0 1)))

;;; ---------------------------------------------------------------------------
;;; Document lifecycle

(defun ensure-document (server params)
  (let* ((td (json-get params "textDocument"))
         (uri (json-get td "uri"))
         (doc (gethash uri (server-documents server))))
    (values doc uri td)))

(defun publish-diagnostics (server uri text)
  (let ((diags (diagnostics-for-text text)))
    (write-message
     (server-output server)
     (make-notification
      "textDocument/publishDiagnostics"
      (json-obj :uri uri :diagnostics diags)))))

(define-handler "textDocument/didOpen" (server params)
  (let* ((td (json-get params "textDocument"))
         (uri (json-get td "uri"))
         (text (json-get td "text" ""))
         (version (json-get td "version" 0))
         (language (json-get td "languageId" "lisp"))
         (doc (make-document :uri uri :language language
                             :version version :text text)))
    (setf (gethash uri (server-documents server)) doc)
    (publish-diagnostics server uri text))
  nil)

(define-handler "textDocument/didChange" (server params)
  (multiple-value-bind (doc uri td) (ensure-document server params)
    (declare (ignore td))
    (when doc
      (let ((changes (json-get params "contentChanges")))
        (dolist (change changes)
          (document-apply-change doc change)))
      (publish-diagnostics server uri (document-text doc))))
  nil)

(define-handler "textDocument/didSave" (server params)
  (multiple-value-bind (doc uri td) (ensure-document server params)
    (declare (ignore td))
    (when doc
      (publish-diagnostics server uri (document-text doc))))
  nil)

(define-handler "textDocument/didClose" (server params)
  (multiple-value-bind (doc uri) (ensure-document server params)
    (declare (ignore doc))
    (remhash uri (server-documents server))
    ;; Clear diagnostics on close.
    (write-message
     (server-output server)
     (make-notification
      "textDocument/publishDiagnostics"
      (json-obj :uri uri :diagnostics '()))))
  nil)

;;; ---------------------------------------------------------------------------
;;; Helpers for the language features

(defun document-from-params (server params)
  (let* ((td (json-get params "textDocument"))
         (uri (json-get td "uri")))
    (values (gethash uri (server-documents server)) uri)))

(defun position-from-params (params)
  (let ((p (json-get params "position")))
    (values (json-get p "line" 0) (json-get p "character" 0))))

;;; ---------------------------------------------------------------------------
;;; Completion

(define-handler "textDocument/completion" (server params)
  (multiple-value-bind (doc) (document-from-params server params)
    (unless doc (return-from handler nil))
    (multiple-value-bind (line char) (position-from-params params)
      (let* ((text (document-text doc))
             (off  (position-to-offset doc line char))
             ;; back up while we have symbol chars to find prefix
             (start off))
        (loop while (and (> start 0)
                         (symbol-char-p (char text (1- start))))
              do (decf start))
        (let* ((prefix (subseq text start off))
               (cands (completions-for-prefix prefix text)))
          (json-obj
           :is-incomplete :false
           :items (mapcar
                   (lambda (c)
                     (destructuring-bind (name . kind) c
                       (json-obj
                        :label (string-downcase name)
                        :kind (lsp-completion-kind kind))))
                   cands)))))))

;;; ---------------------------------------------------------------------------
;;; Hover

(define-handler "textDocument/hover" (server params)
  (multiple-value-bind (doc) (document-from-params server params)
    (unless doc (return-from handler nil))
    (multiple-value-bind (line char) (position-from-params params)
      (let* ((text (document-text doc))
             (off (position-to-offset doc line char))
             (sym (symbol-at-position text off)))
        (cond
          ((null sym) nil)
          (t
           (let ((doc-string (describe-cl-symbol sym)))
             (when doc-string
               (json-obj
                :contents (json-obj :kind "markdown" :value doc-string))))))))))

;;; ---------------------------------------------------------------------------
;;; Definition (intra-document only — finds matching toplevel def)

(define-handler "textDocument/definition" (server params)
  (multiple-value-bind (doc uri) (document-from-params server params)
    (unless doc (return-from handler nil))
    (multiple-value-bind (line char) (position-from-params params)
      (let* ((text (document-text doc))
             (off (position-to-offset doc line char))
             (name (symbol-at-position text off))
             (target nil))
        (when name
          (let ((up (string-upcase name)))
            (dolist (def (document-symbols text))
              (when (string= up (toplevel-def-name def))
                (setf target def)
                (return)))))
        (when target
          (multiple-value-bind (sl sc)
              (offset-to-position doc (toplevel-def-start-offset target))
            (multiple-value-bind (el ec)
                (offset-to-position doc (toplevel-def-end-offset target))
              (json-obj
               :uri uri
               :range (json-obj
                       :start (json-obj :line sl :character sc)
                       :end   (json-obj :line el :character ec))))))))))

;;; ---------------------------------------------------------------------------
;;; Document symbols

(define-handler "textDocument/documentSymbol" (server params)
  (multiple-value-bind (doc) (document-from-params server params)
    (unless doc (return-from handler nil))
    (let ((text (document-text doc)))
      (mapcar
       (lambda (def)
         (multiple-value-bind (sl sc)
             (offset-to-position doc (toplevel-def-start-offset def))
           (multiple-value-bind (el ec)
               (offset-to-position doc (toplevel-def-end-offset def))
             (let ((range (json-obj
                           :start (json-obj :line sl :character sc)
                           :end   (json-obj :line el :character ec))))
               (json-obj
                :name (string-downcase (toplevel-def-name def))
                :kind (lsp-symbol-kind (toplevel-def-kind def))
                :range range
                :selection-range range)))))
       (document-symbols text)))))

;;; ---------------------------------------------------------------------------
;;; Cancel — accept and ignore (we run synchronously per message).

(define-handler "$/cancelRequest" (server params)
  (declare (ignore server params))
  nil)

(define-handler "$/setTrace" (server params)
  (declare (ignore server params))
  nil)

(define-handler "workspace/didChangeConfiguration" (server params)
  (declare (ignore server params))
  nil)
