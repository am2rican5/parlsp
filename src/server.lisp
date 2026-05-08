(in-package #:parlsp)

;;;; Server runtime: state, the read/dispatch/write loop, and stdio/tcp
;;;; transports.

(define-condition server-exit ()
  ((code :initarg :code :reader server-exit-code :initform 0)))

(defclass server ()
  ((documents          :initform (make-hash-table :test 'equal)
                       :reader server-documents)
   (input              :initarg :input  :accessor server-input)
   (output             :initarg :output :accessor server-output)
   (shutdown-requested :initform nil    :accessor server-shutdown-requested-p)))

(defun make-server (&key input output)
  (make-instance 'server :input input :output output))

(defun serve (server)
  "Run the read/dispatch/write loop until EOF or an exit notification."
  (handler-case
      (loop
        (let ((message (read-message (server-input server))))
          (when (null message)
            (log-info "EOF on input; exiting loop")
            (return))
          (let ((response (dispatch server message)))
            (when response
              (write-message (server-output server) response)))))
    (server-exit (e)
      (log-info "Exit signal received (code=~A)" (server-exit-code e))
      (server-exit-code e))
    (lsp-protocol-error (e)
      (log-error "Protocol error: ~A" e)
      1)
    (end-of-file ()
      (log-info "End-of-file on input stream")
      0)))

;;; ---------------------------------------------------------------------------
;;; stdio transport

#+sbcl
(defun stdio-binary-streams ()
  "Return (values input-stream output-stream) for SBCL stdio as binary."
  (values (sb-sys:make-fd-stream 0
                                 :input t
                                 :element-type '(unsigned-byte 8)
                                 :buffering :none
                                 :name "<lsp-stdin>")
          (sb-sys:make-fd-stream 1
                                 :output t
                                 :element-type '(unsigned-byte 8)
                                 :buffering :none
                                 :name "<lsp-stdout>")))

#-sbcl
(defun stdio-binary-streams ()
  (error "stdio transport currently requires SBCL."))

(defun run-stdio ()
  "Start the LSP server on stdin/stdout. Returns an integer exit code."
  (multiple-value-bind (in out) (stdio-binary-streams)
    (let ((server (make-server :input in :output out)))
      (or (serve server) 0))))

;;; ---------------------------------------------------------------------------
;;; TCP transport (single connection, useful for debugging clients)

(defun run-tcp (host port)
  "Listen on HOST:PORT and serve a single LSP client connection.
Requires usocket (which we already depend on at the system level when
this function is called)."
  (let ((usocket-package (find-package :usocket)))
    (unless usocket-package
      (asdf:load-system :usocket))
    (let* ((listener (funcall (intern "SOCKET-LISTEN" :usocket)
                              host port
                              :reuse-address t
                              :element-type '(unsigned-byte 8)))
           (connection nil))
      (unwind-protect
           (progn
             (log-info "TCP listener up on ~A:~A" host port)
             (setf connection (funcall (intern "SOCKET-ACCEPT" :usocket)
                                       listener
                                       :element-type '(unsigned-byte 8)))
             (let ((stream (funcall (intern "SOCKET-STREAM" :usocket)
                                    connection)))
               (let ((server (make-server :input stream :output stream)))
                 (or (serve server) 0))))
        (when connection
          (ignore-errors
           (funcall (intern "SOCKET-CLOSE" :usocket) connection)))
        (ignore-errors
         (funcall (intern "SOCKET-CLOSE" :usocket) listener))))))

(defun start (&key (transport :stdio) (host "127.0.0.1") (port 5050))
  "Programmatic entry. TRANSPORT is :stdio or :tcp."
  (ecase transport
    (:stdio (run-stdio))
    (:tcp   (run-tcp host port))))
