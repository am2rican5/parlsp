(in-package #:parlsp)

;;;; CLI entry point. Supports:
;;;;   --stdio                Use stdio transport (default).
;;;;   --tcp [HOST:]PORT      Listen on TCP for a single connection.
;;;;   --log-level LEVEL      One of debug, info, warn, error.
;;;;   --log-file PATH        Write logs to PATH instead of stderr.
;;;;   --version              Print version and exit.
;;;;   --help                 Print help and exit.

(defparameter +version+ "0.1.0")

(defparameter +help-text+
  "parlsp — Language Server for Common Lisp

USAGE:
  parlsp [OPTIONS]

OPTIONS:
  --stdio                  Communicate over stdin/stdout (default).
  --tcp [HOST:]PORT        Listen on TCP for a single client connection.
  --log-level LEVEL        debug | info | warn | error (default: info)
  --log-file PATH          Append logs to PATH instead of stderr.
  --version                Print version and exit.
  --help, -h               Show this help and exit.
")

(defun parse-tcp-arg (s)
  "Parse [HOST:]PORT into (values HOST PORT)."
  (let ((colon (position #\: s :from-end t)))
    (if colon
        (values (subseq s 0 colon) (parse-integer (subseq s (1+ colon))))
        (values "127.0.0.1" (parse-integer s)))))

(defun parse-args (args)
  "Parse ARGS into a plist describing the requested run mode."
  (let ((mode :stdio)
        (host "127.0.0.1")
        (port 5050)
        (log-level :info)
        (log-file nil)
        (i 0))
    (loop while (< i (length args)) do
      (let ((a (nth i args)))
        (cond
          ((or (string= a "--help") (string= a "-h"))
           (return-from parse-args (list :mode :help)))
          ((string= a "--version")
           (return-from parse-args (list :mode :version)))
          ((string= a "--stdio") (setf mode :stdio))
          ((string= a "--tcp")
           (setf mode :tcp)
           (incf i)
           (multiple-value-bind (h p) (parse-tcp-arg (nth i args))
             (setf host h port p)))
          ((string= a "--log-level")
           (incf i)
           (setf log-level (intern (string-upcase (nth i args)) :keyword)))
          ((string= a "--log-file")
           (incf i)
           (setf log-file (nth i args)))
          (t (error "Unknown argument: ~A" a))))
      (incf i))
    (list :mode mode
          :host host
          :port port
          :log-level log-level
          :log-file log-file)))

(defun command-line-args ()
  "Return the user-supplied command line arguments as a list of strings,
stripping the program name. Implementation-specific."
  #+sbcl (rest sb-ext:*posix-argv*)
  #+ccl (rest ccl:*command-line-argument-list*)
  #+ecl (rest (ext:command-args))
  #+clisp (rest ext:*args*)
  #-(or sbcl ccl ecl clisp) nil)

(defun configure-logging (level log-file)
  (setf *log-level* level)
  (when log-file
    (let ((stream (open log-file :direction :output
                                 :if-exists :append
                                 :if-does-not-exist :create
                                 :element-type 'character)))
      (setf *log-stream* stream))))

(defun exit-with-code (code)
  #+sbcl (sb-ext:exit :code code)
  #+ccl (ccl:quit code)
  #+ecl (ext:quit code)
  #+clisp (ext:exit code)
  #-(or sbcl ccl ecl clisp) (when (zerop code) nil))

(defun main (&rest argv)
  "CLI entry point. ARGV may be supplied for testing; otherwise the
implementation's process arguments are used."
  (handler-case
      (let* ((args (or argv (command-line-args)))
             (opts (parse-args args)))
        (case (getf opts :mode)
          (:help    (princ +help-text+) (terpri) (exit-with-code 0))
          (:version (format t "parlsp ~A~%" +version+)
                    (exit-with-code 0))
          (otherwise
           (configure-logging (getf opts :log-level) (getf opts :log-file))
           (log-info "Starting parlsp ~A (mode=~A)" +version+ (getf opts :mode))
           (let ((code (ecase (getf opts :mode)
                         (:stdio (run-stdio))
                         (:tcp (run-tcp (getf opts :host)
                                        (getf opts :port))))))
             (exit-with-code (or code 0))))))
    (error (e)
      (format *error-output* "parlsp: ~A~%" e)
      (exit-with-code 2))))
