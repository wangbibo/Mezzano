(defun indent-log (file)
  (with-open-file (output (make-pathname :type "logout" :defaults file)
                          :direction :output)
    (iter (for c in-file file using #'read-char)
          (with indentation = 0)
          (write-char c output)
          (case c
            (#\> (incf indentation))
            (#\< (decf indentation))
            (#\Newline
             (format output "~D " indentation))))))

(defgeneric image-physical-word (image address)
  (:documentation "Read a word at a physical address from IMAGE"))

(defgeneric image-nil (image)
  (:documentation "Return the value of NIL in IMAGE."))

(defclass file-image ()
  ((path :initarg :path :reader file-image-path)
   (data :reader file-image-data)))

(defmethod initialize-instance :after ((instance file-image) &key &allow-other-keys)
  (with-open-file (s (file-image-path instance)
                     :element-type '(unsigned-byte 8))
    (file-position s :end)
    (let ((size (- (file-position s) 512)))
      (file-position s 512)
      (setf (slot-value instance 'data) (make-array size :element-type '(unsigned-byte 8)))
      (read-sequence (file-image-data instance) s))))

(defmethod image-nil ((image file-image))
  #x200012)

(defmethod image-physical-word ((image file-image) address)
  (nibbles:ub64ref/le (file-image-data image) (- address #x200000)))

(defun ptbl-lookup (image address)
  "Convert ADDRESS to a physical address."
  (assert (zerop (ldb (byte 16 48) address)) (address) "Non-canonical or upper-half address.")
  (let ((pml4 (image-physical-word image (+ #x400000 (* (ldb (byte 9 39) address) 8)))))
    (when (not (logtest pml4 1))
      (error "Address ~X not present." address))
    (let ((pml3 (image-physical-word image (+ (logand pml4 (lognot #xFFF))
                                              (* (ldb (byte 9 30) address) 8)))))
      (when (not (logtest pml3 1))
        (error "Address ~X not present." address))
      (let ((pml2 (image-physical-word image (+ (logand pml3 (lognot #xFFF))
                                                (* (ldb (byte 9 21) address) 8)))))
        (when (not (logtest pml2 1))
          (error "Address ~X not present." address))
        (when (logtest pml2 #x80)
          ;; Large page.
          (return-from ptbl-lookup (logior (logand pml2 (lognot #xFFF))
                                           (ldb (byte 21 0) address))))
        (let ((pml1 (image-physical-word image (+ (logand pml2 (lognot #xFFF))
                                                  (* (ldb (byte 9 12) address) 8)))))
          (when (not (logtest pml2 1))
            (error "Address ~X not present." address))
          (logior (logand pml1 (lognot #xFFF))
                  (ldb (byte 12 0) address)))))))

(defun image-word (image address)
  "Read a word at ADDRESS from IMAGE."
  (image-physical-word image (ptbl-lookup image address)))

(defun map-array-like-object (fn image seen-objects address)
  (let* ((header (image-word image address))
         (type (ldb (byte 5 3) header))
         (length (ldb (byte 48 8) header)))
    (ecase type
      ((0 29 31) ; simple-vector, std-instance and structure-object
       (dotimes (i length)
         (map-object fn image seen-objects (image-word image (+ address 8 (* i 8))))))
      (30 ; stack-group
       (dotimes (i (- 511 64))
         (map-object fn image seen-objects (image-word image (+ address 8 (* i 8))))))
      ((1 2 3 4 5 6 7 8 9
        10 11 12 13 14 15
        16 17 18 19 20 21
        22 23)) ; numeric arrays
      (25)))) ; bignum

(defun map-object (fn image seen-objects object)
  (unless (gethash object seen-objects)
    (setf (gethash object seen-objects) t)
    (funcall fn object)
    (let ((address (logand object (lognot #b1111))))
      (ecase (ldb (byte 4 0) object)
        (#b0000) ; even-fixnum
        (#b0001 ; cons
         (map-object fn image seen-objects (image-word image address))
         (map-object fn image seen-objects (image-word image (+ address 8))))
        (#b0010 ; symbol
         (dotimes (i 6)
           (map-object fn image seen-objects (image-word image (+ address (* i 8))))))
        (#b0011 ; array-header
         (dotimes (i 4)
           (map-object fn image seen-objects (image-word image (+ address (* i 8))))))
        ;; #b0100
        ;; #b0101
        ;; #b0110
        (#b0111 ; array-like
         (map-array-like-object fn image seen-objects address))
        (#b1000) ; odd-fixnum
        ;; #b1001
        (#b1010) ; character
        (#b1011) ; single-float
        (#b1100 ; function
         (let* ((header (image-word image address))
                (mc-size (* (ldb (byte 16 16) header) 16))
                (n-constants (ldb (byte 16 32) header)))
           (dotimes (i n-constants)
             (map-object fn image seen-objects (image-word image (+ address mc-size (* i 8)))))))
        (#b1110) ; unbound-value
        (#b1111))))) ; gc-forwarding-pointer

(defun map-objects (fn image)
  "Call FN for every object in IMAGE. Returns a hash-table whose keys are the seen objects.
Assumes that everything can be reached from NIL."
  (let ((objects (make-hash-table :test 'eq)))
    (map-object fn image objects (image-nil image))
    (make-array (hash-table-count objects)
                :element-type '(unsigned-byte 64)
                :initial-contents (alexandria:hash-table-keys objects))))

(defun extract-image-array (image address element-width)
  (let* ((size (ldb (byte 56 8) (image-word image address)))
         (array (make-array size))
         (elements-per-word (/ 64 element-width)))
    (dotimes (i size)
      (multiple-value-bind (word offset)
          (truncate i elements-per-word)
        (setf (aref array i) (ldb (byte element-width (* offset element-width))
                                  (image-word image (+ address 8 (* word 8)))))))
    array))

(defstruct image-symbol
  address
  image
  name
  package-name)

(defmethod print-object ((object image-symbol) stream)
  (if (or *print-escape* *print-readably*)
      (call-next-method)
      (format stream "~A::~A"
              (image-symbol-package-name object)
              (image-symbol-name object))))

(defun extract-image-object (image value)
  (let ((address (logand value (lognot #b1111))))
    (ecase (ldb (byte 4 0) value)
      ((#.+tag-even-fixnum+
        #.+tag-odd-fixnum+)
       ;; Make sure negative numbers are negative.
       (if (ldb-test (byte 1 63) value)
           (ash (logior (lognot (ldb (byte 64 0) -1)) value) -3)
           (ash value -3)))
      (#.+tag-cons+
       (cons (extract-image-object image (image-word image address))
             (extract-image-object image (image-word image (+ address 8)))))
      (#.+tag-symbol+
       (when (eql value (image-nil image))
         (return-from extract-image-object nil))
       (let ((name (extract-image-object image (image-word image address)))
             (package (image-word image (+ address 8))))
         (when (eql package (image-nil image))
           (error "Attemping to extract an uninterned symbol."))
         ;; package groveling...
         (let ((package-name (extract-image-object image
                                                   (image-word image
                                                               (+ (logand package (lognot #b1111)) 16)))))
           (make-image-symbol :address address
                              :image image
                              :name name
                              :package-name package-name))))
      (#.+tag-array-like+
       (ecase (ldb (byte 5 3) (image-word image address))
         (#.+array-type-base-char+
          (map 'simple-string 'code-char (extract-image-array image address 8)))
         (#.+array-type-character+
          (map 'simple-string 'code-char (extract-image-array image address 32)))
         (#.sys.int::+array-type-std-instance+
          (cons (extract-image-object image (image-word image (+ address 8)))
                (extract-image-object image (image-word image (+ address 16))))))))))

(defun identify-symbols (image)
  "Detect all symbols in IMAGE, returning a list of (symbol-name address)."
  (let ((symbols '()))
    (map-objects (lambda (value)
                   (when (eql (logand value #b1111) +tag-symbol+)
                     (push (list (extract-image-object image (image-word image (logand value (lognot #b1111))))
                                 value)
                           symbols)))
                 image)
    symbols))

(defun build-map-file (image)
  (map-objects (lambda (value)
                 (with-simple-restart (continue "Ignore value ~X" value)
                   (when (eql (logand value #b1111) +tag-function+)
                     (let* ((address (logand value (lognot #b1111)))
                            (header (image-word image address))
                            (tag (ldb (byte 16 0) header))
                            (mc-size (* (ldb (byte 16 16) header) 16))
                            (n-constants (ldb (byte 16 32) header)))
                       (when (and (= tag 0)
                                  (/= n-constants 0))
                         (format t "~8,'0X ~A~%" value (extract-image-object image (image-word image (+ address mc-size)))))))))
               image)
  (values))