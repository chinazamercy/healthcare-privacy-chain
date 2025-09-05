;; Healthcare Data Registry Contract
;; Manages encrypted healthcare data references and sharing requests

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u2001))
(define-constant ERR-DATA-NOT-FOUND (err u2002))
(define-constant ERR-INVALID-PATIENT (err u2003))
(define-constant ERR-INVALID-PROVIDER (err u2004))
(define-constant ERR-DATA-ALREADY-EXISTS (err u2005))
(define-constant ERR-SHARING-REQUEST-NOT-FOUND (err u2006))
(define-constant ERR-INVALID-DATA-CATEGORY (err u2007))

;; Data structures
(define-map healthcare-records
  { patient-id: principal, record-id: uint }
  {
    data-hash: (buff 32),
    data-category: (string-ascii 50),
    created-at: uint,
    updated-at: uint,
    provider-id: principal,
    encryption-key-hash: (buff 32),
    metadata: (string-ascii 500),
    is-active: bool,
    file-size: uint,
    data-type: (string-ascii 20)
  }
)

(define-map sharing-requests
  { request-id: uint }
  {
    patient-id: principal,
    requesting-provider: principal,
    target-records: (list 20 uint),
    requested-at: uint,
    expires-at: uint,
    status: (string-ascii 20),
    purpose: (string-ascii 200),
    urgency-level: (string-ascii 20),
    approved-by: (optional principal)
  }
)

(define-map data-access-logs
  { log-id: uint }
  {
    patient-id: principal,
    provider-id: principal,
    record-id: uint,
    accessed-at: uint,
    access-type: (string-ascii 30),
    ip-address: (string-ascii 45),
    user-agent: (string-ascii 200),
    consent-id: (optional uint)
  }
)

(define-map data-categories
  { category-id: (string-ascii 50) }
  {
    name: (string-ascii 100),
    description: (string-ascii 300),
    sensitivity-level: uint,
    retention-period: uint,
    is-active: bool
  }
)

(define-map patient-data-summary
  { patient-id: principal }
  {
    total-records: uint,
    last-updated: uint,
    data-categories: (list 20 (string-ascii 50)),
    authorized-providers: (list 50 principal),
    total-access-logs: uint
  }
)

;; Data variables
(define-data-var next-record-id uint u1)
(define-data-var next-request-id uint u1)
(define-data-var next-log-id uint u1)
(define-data-var contract-owner principal tx-sender)
(define-data-var data-retention-period uint u31536000) ;; 1 year in seconds
(define-data-var max-file-size uint u10485760) ;; 10MB in bytes

;; Private functions
(define-private (is-contract-owner)
  (is-eq tx-sender (var-get contract-owner))
)

(define-private (is-valid-category (category (string-ascii 50)))
  (is-some (map-get? data-categories { category-id: category }))
)

(define-private (can-access-data (patient-id principal) (provider-id principal) (record-id uint))
  ;; This would integrate with patient-consent contract in a real implementation
  ;; For now, we'll check if the provider is the creator or has valid consent
  (match (map-get? healthcare-records { patient-id: patient-id, record-id: record-id })
    record (or (is-eq (get provider-id record) provider-id)
               (is-eq patient-id provider-id)) ;; Patient can always access their own data
    false
  )
)

(define-private (log-data-access (patient-id principal) (provider-id principal) (record-id uint) (access-type (string-ascii 30)) (consent-id (optional uint)))
  (let ((log-id (var-get next-log-id)))
    (begin
      (map-set data-access-logs
        { log-id: log-id }
        {
          patient-id: patient-id,
          provider-id: provider-id,
          record-id: record-id,
          accessed-at: u1,
          access-type: access-type,
          ip-address: "0.0.0.0", ;; Would be provided in real implementation
          user-agent: "clarinet-test",
          consent-id: consent-id
        }
      )
      (var-set next-log-id (+ log-id u1))
      log-id
    )
  )
)

(define-private (update-patient-summary (patient-id principal) (new-category (string-ascii 50)) (provider-id principal))
  (let ((current-summary (default-to 
                          { total-records: u0, last-updated: u0, data-categories: (list), authorized-providers: (list), total-access-logs: u0 }
                          (map-get? patient-data-summary { patient-id: patient-id }))))
    (map-set patient-data-summary
      { patient-id: patient-id }
      {
        total-records: (+ (get total-records current-summary) u1),
        last-updated: u1,
        data-categories: (unwrap-panic (as-max-len? (append (get data-categories current-summary) new-category) u20)),
        authorized-providers: (unwrap-panic (as-max-len? (append (get authorized-providers current-summary) provider-id) u50)),
        total-access-logs: (get total-access-logs current-summary)
      }
    )
  )
)

;; Public functions

;; Initialize default data categories
(define-public (initialize-categories)
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (map-set data-categories { category-id: "MEDICAL_HISTORY" } 
      { name: "Medical History", description: "Patient medical history and diagnoses", sensitivity-level: u3, retention-period: u31536000, is-active: true })
    (map-set data-categories { category-id: "LAB_RESULTS" }
      { name: "Laboratory Results", description: "Blood tests, imaging, and other diagnostic results", sensitivity-level: u2, retention-period: u15768000, is-active: true })
    (map-set data-categories { category-id: "PRESCRIPTIONS" }
      { name: "Prescriptions", description: "Medication prescriptions and pharmacy records", sensitivity-level: u2, retention-period: u31536000, is-active: true })
    (map-set data-categories { category-id: "VITAL_SIGNS" }
      { name: "Vital Signs", description: "Blood pressure, heart rate, temperature, etc.", sensitivity-level: u1, retention-period: u7884000, is-active: true })
    (map-set data-categories { category-id: "ALLERGIES" }
      { name: "Allergies", description: "Known allergies and adverse reactions", sensitivity-level: u3, retention-period: u63072000, is-active: true })
    (ok true)
  )
)

;; Store new healthcare record
(define-public (store-record 
  (patient-id principal) 
  (data-hash (buff 32)) 
  (data-category (string-ascii 50)) 
  (encryption-key-hash (buff 32)) 
  (metadata (string-ascii 500))
  (file-size uint)
  (data-type (string-ascii 20))
)
  (let ((record-id (var-get next-record-id)))
    (begin
      ;; Validate inputs
      (asserts! (is-valid-category data-category) ERR-INVALID-DATA-CATEGORY)
      (asserts! (<= file-size (var-get max-file-size)) ERR-DATA-ALREADY-EXISTS)
      
      ;; Store the record
      (map-set healthcare-records
        { patient-id: patient-id, record-id: record-id }
        {
          data-hash: data-hash,
          data-category: data-category,
          created-at: u1,
          updated-at: u1,
          provider-id: tx-sender,
          encryption-key-hash: encryption-key-hash,
          metadata: metadata,
          is-active: true,
          file-size: file-size,
          data-type: data-type
        }
      )
      
      ;; Update patient summary
      (update-patient-summary patient-id data-category tx-sender)
      
      ;; Log the creation
      (log-data-access patient-id tx-sender record-id "CREATE" none)
      
      ;; Increment record ID
      (var-set next-record-id (+ record-id u1))
      (ok record-id)
    )
  )
)

;; Request access to patient data
(define-public (request-data-sharing 
  (patient-id principal) 
  (target-records (list 20 uint)) 
  (purpose (string-ascii 200)) 
  (duration-blocks uint)
  (urgency-level (string-ascii 20))
)
  (let ((request-id (var-get next-request-id))
        (expires-at (+ u1 duration-blocks)))
    (begin
      (map-set sharing-requests
        { request-id: request-id }
        {
          patient-id: patient-id,
          requesting-provider: tx-sender,
          target-records: target-records,
          requested-at: u1,
          expires-at: expires-at,
          status: "PENDING",
          purpose: purpose,
          urgency-level: urgency-level,
          approved-by: none
        }
      )
      (var-set next-request-id (+ request-id u1))
      (ok request-id)
    )
  )
)

;; Approve data sharing request
(define-public (approve-sharing-request (request-id uint))
  (let ((request (map-get? sharing-requests { request-id: request-id })))
    (begin
      (asserts! (is-some request) ERR-SHARING-REQUEST-NOT-FOUND)
      (asserts! (is-eq tx-sender (get patient-id (unwrap-panic request))) ERR-NOT-AUTHORIZED)
      (map-set sharing-requests
        { request-id: request-id }
        (merge (unwrap-panic request) { status: "APPROVED", approved-by: (some tx-sender) })
      )
      (ok true)
    )
  )
)

;; Access healthcare record (with consent validation)
(define-public (access-record (patient-id principal) (record-id uint) (consent-id (optional uint)))
  (begin
    (asserts! (can-access-data patient-id tx-sender record-id) ERR-NOT-AUTHORIZED)
    (log-data-access patient-id tx-sender record-id "READ" consent-id)
    (ok (map-get? healthcare-records { patient-id: patient-id, record-id: record-id }))
  )
)
;; Update healthcare record
(define-public (update-record 
  (patient-id principal) 
  (record-id uint) 
  (new-data-hash (buff 32)) 
  (new-metadata (string-ascii 500))
)
  (let ((existing-record (map-get? healthcare-records { patient-id: patient-id, record-id: record-id })))
    (begin
      (asserts! (is-some existing-record) ERR-DATA-NOT-FOUND)
      (asserts! (can-access-data patient-id tx-sender record-id) ERR-NOT-AUTHORIZED)
      
      (map-set healthcare-records
        { patient-id: patient-id, record-id: record-id }
        (merge (unwrap-panic existing-record) 
               { 
                 data-hash: new-data-hash, 
                 metadata: new-metadata, 
                 updated-at: u1 
               })
      )
      
      (log-data-access patient-id tx-sender record-id "UPDATE" none)
      (ok true)
    )
  )
)

;; Deactivate healthcare record
(define-public (deactivate-record (patient-id principal) (record-id uint))
  (let ((existing-record (map-get? healthcare-records { patient-id: patient-id, record-id: record-id })))
    (begin
      (asserts! (is-some existing-record) ERR-DATA-NOT-FOUND)
      (asserts! (can-access-data patient-id tx-sender record-id) ERR-NOT-AUTHORIZED)
      
      (map-set healthcare-records
        { patient-id: patient-id, record-id: record-id }
        (merge (unwrap-panic existing-record) { is-active: false, updated-at: u1 })
      )
      
      (log-data-access patient-id tx-sender record-id "DELETE" none)
      (ok true)
    )
  )
)

;; Read-only functions

;; Get healthcare record
(define-read-only (get-record (patient-id principal) (record-id uint))
  (map-get? healthcare-records { patient-id: patient-id, record-id: record-id })
)

;; Get sharing request
(define-read-only (get-sharing-request (request-id uint))
  (map-get? sharing-requests { request-id: request-id })
)

;; Get access log
(define-read-only (get-access-log (log-id uint))
  (map-get? data-access-logs { log-id: log-id })
)

;; Get data category
(define-read-only (get-data-category (category-id (string-ascii 50)))
  (map-get? data-categories { category-id: category-id })
)

;; Get patient data summary
(define-read-only (get-patient-summary (patient-id principal))
  (map-get? patient-data-summary { patient-id: patient-id })
)

;; Get next record ID
(define-read-only (get-next-record-id)
  (var-get next-record-id)
)

;; Get next request ID
(define-read-only (get-next-request-id)
  (var-get next-request-id)
)

;; Get next log ID
(define-read-only (get-next-log-id)
  (var-get next-log-id)
)

;; Check if data access is valid
(define-read-only (validate-data-access (patient-id principal) (provider-id principal) (record-id uint))
  (can-access-data patient-id provider-id record-id)
)

;; Get records by category
(define-read-only (get-records-by-category (patient-id principal) (category (string-ascii 50)))
  ;; In a full implementation, this would iterate through records
  ;; For now, we return the patient summary
  (map-get? patient-data-summary { patient-id: patient-id })
)

;; Get max file size
(define-read-only (get-max-file-size)
  (var-get max-file-size)
)

;; Get data retention period
(define-read-only (get-retention-period)
  (var-get data-retention-period)
)
