(in-package #:parlsp)

(defvar *log-stream* *error-output*
  "Stream where the server writes diagnostic logs. Never stdout, since
stdout carries LSP traffic in --stdio mode.")

(defvar *log-level* :info
  "One of :debug, :info, :warn, :error.")

(defparameter *log-levels*
  '((:debug . 0) (:info . 1) (:warn . 2) (:error . 3)))

(defun %level-rank (level)
  (or (cdr (assoc level *log-levels*)) 1))

(defun log-message (level fmt &rest args)
  (when (>= (%level-rank level) (%level-rank *log-level*))
    (let ((*print-pretty* nil))
      (format *log-stream* "[parlsp ~A] " (string-upcase (symbol-name level)))
      (apply #'format *log-stream* fmt args)
      (terpri *log-stream*)
      (finish-output *log-stream*))))

(defmacro log-debug (fmt &rest args) `(log-message :debug ,fmt ,@args))
(defmacro log-info  (fmt &rest args) `(log-message :info  ,fmt ,@args))
(defmacro log-warn  (fmt &rest args) `(log-message :warn  ,fmt ,@args))
(defmacro log-error (fmt &rest args) `(log-message :error ,fmt ,@args))
