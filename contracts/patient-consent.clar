;; Patient Consent Management Contract
;; Manages patient consent preferences and permissions for healthcare data access

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u1001))
(define-constant ERR-PATIENT-NOT-FOUND (err u1002))
(define-constant ERR-CONSENT-NOT-FOUND (err u1003))
(define-constant ERR-INVALID-PROVIDER (err u1004))
(define-constant ERR-CONSENT-EXPIRED (err u1005))
(define-constant ERR-EMERGENCY-ACCESS-DENIED (err u1006))

;; Data structures
(define-map patients 
  { patient-id: principal }
  {
    name: (string-ascii 100),
    date-of-birth: (string-ascii 20),
    emergency-contact: principal,
    created-at: uint,
    is-active: bool
  }
)

(define-map consents
  { patient-id: principal, provider-id: principal, consent-id: uint }
  {
    data-categories: (list 10 (string-ascii 50)),
    purpose: (string-ascii 200),
    granted-at: uint,
    expires-at: uint,
    is-active: bool,
    access-level: (string-ascii 20),
    emergency-override: bool
  }
)

(define-map consent-history
  { patient-id: principal, consent-id: uint, version: uint }
  {
    action: (string-ascii 20),
    provider-id: principal,
    timestamp: uint,
    reason: (string-ascii 200)
  }
)

(define-map healthcare-providers
  { provider-id: principal }
  {
    name: (string-ascii 100),
    license-number: (string-ascii 50),
    specialty: (string-ascii 100),
    verified: bool,
    registered-at: uint
  }
)

(define-map emergency-access-requests
  { patient-id: principal, provider-id: principal, request-id: uint }
  {
    requested-at: uint,
    reason: (string-ascii 500),
    approved: bool,
    expires-at: uint
  }
)

;; Data variables
(define-data-var next-consent-id uint u1)
(define-data-var next-request-id uint u1)
(define-data-var contract-owner principal tx-sender)
(define-data-var emergency-access-duration uint u86400) ;; 24 hours in seconds

;; Private functions
(define-private (is-contract-owner)
  (is-eq tx-sender (var-get contract-owner))
)

(define-private (is-patient (patient-id principal))
  (is-some (map-get? patients { patient-id: patient-id }))
)

(define-private (is-verified-provider (provider-id principal))
  (match (map-get? healthcare-providers { provider-id: provider-id })
    provider (get verified provider)
    false
  )
)

(define-private (consent-is-valid (patient-id principal) (provider-id principal) (consent-id uint))
  (let ((consent (map-get? consents { patient-id: patient-id, provider-id: provider-id, consent-id: consent-id })))
    (if (is-some consent)
        (and 
          (get is-active (unwrap-panic consent))
          (< u1 (get expires-at (unwrap-panic consent)))
        )
        false
    )
  )
)
(define-private (record-consent-action (patient-id principal) (consent-id uint) (action (string-ascii 20)) (provider-id principal) (reason (string-ascii 200)))
  (let ((version (+ (get-consent-version patient-id consent-id) u1)))
    (map-set consent-history
      { patient-id: patient-id, consent-id: consent-id, version: version }
      {
        action: action,
        provider-id: provider-id,
        timestamp: u1,
        reason: reason
      }
    )
  )
)

(define-private (get-consent-version (patient-id principal) (consent-id uint))
  u1
)
;; Public functions

;; Register a new patient
(define-public (register-patient (name (string-ascii 100)) (date-of-birth (string-ascii 20)) (emergency-contact principal))
  (begin
    (asserts! (not (is-patient tx-sender)) ERR-PATIENT-NOT-FOUND)
    (map-set patients
      { patient-id: tx-sender }
      {
        name: name,
        date-of-birth: date-of-birth,
        emergency-contact: emergency-contact,
        created-at: u1,
        is-active: true
      }
    )
    (ok true)
  )
)

;; Register a healthcare provider
(define-public (register-provider (name (string-ascii 100)) (license-number (string-ascii 50)) (specialty (string-ascii 100)))
  (begin
    (map-set healthcare-providers
      { provider-id: tx-sender }
      {
        name: name,
        license-number: license-number,
        specialty: specialty,
        verified: false,
        registered-at: u1
      }
    )
    (ok true)
  )
)

;; Verify a healthcare provider (only contract owner)
(define-public (verify-provider (provider-id principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (asserts! (is-some (map-get? healthcare-providers { provider-id: provider-id })) ERR-INVALID-PROVIDER)
    (map-set healthcare-providers
      { provider-id: provider-id }
      (merge (unwrap-panic (map-get? healthcare-providers { provider-id: provider-id }))
             { verified: true }
      )
    )
    (ok true)
  )
)

;; Grant consent to a healthcare provider
(define-public (grant-consent 
  (provider-id principal) 
  (data-categories (list 10 (string-ascii 50))) 
  (purpose (string-ascii 200)) 
  (duration-blocks uint)
  (access-level (string-ascii 20))
  (emergency-override bool)
)
  (let ((consent-id (var-get next-consent-id))
        (expires-at (+ u1 duration-blocks)))
    (begin
      (asserts! (is-patient tx-sender) ERR-PATIENT-NOT-FOUND)
      (asserts! (is-verified-provider provider-id) ERR-INVALID-PROVIDER)
      (map-set consents
        { patient-id: tx-sender, provider-id: provider-id, consent-id: consent-id }
        {
          data-categories: data-categories,
          purpose: purpose,
          granted-at: u1,
          expires-at: expires-at,
          is-active: true,
          access-level: access-level,
          emergency-override: emergency-override
        }
      )
      (record-consent-action tx-sender consent-id "GRANTED" provider-id "Initial consent grant")
      (var-set next-consent-id (+ consent-id u1))
      (ok consent-id)
    )
  )
)

;; Revoke consent
(define-public (revoke-consent (provider-id principal) (consent-id uint) (reason (string-ascii 200)))
  (begin
    (asserts! (is-patient tx-sender) ERR-PATIENT-NOT-FOUND)
    (asserts! (is-some (map-get? consents { patient-id: tx-sender, provider-id: provider-id, consent-id: consent-id })) ERR-CONSENT-NOT-FOUND)
    (map-set consents
      { patient-id: tx-sender, provider-id: provider-id, consent-id: consent-id }
      (merge (unwrap-panic (map-get? consents { patient-id: tx-sender, provider-id: provider-id, consent-id: consent-id }))
             { is-active: false }
      )
    )
    (record-consent-action tx-sender consent-id "REVOKED" provider-id reason)
    (ok true)
  )
)

;; Request emergency access
(define-public (request-emergency-access (patient-id principal) (reason (string-ascii 500)))
  (let ((request-id (var-get next-request-id))
        (expires-at (+ u1 (var-get emergency-access-duration))))
    (begin
      (asserts! (is-verified-provider tx-sender) ERR-INVALID-PROVIDER)
      (asserts! (is-patient patient-id) ERR-PATIENT-NOT-FOUND)
      (map-set emergency-access-requests
        { patient-id: patient-id, provider-id: tx-sender, request-id: request-id }
        {
          requested-at: u1,
          reason: reason,
          approved: false,
          expires-at: expires-at
        }
      )
      (var-set next-request-id (+ request-id u1))
      (ok request-id)
    )
  )
)

;; Approve emergency access (by patient or emergency contact)
(define-public (approve-emergency-access (patient-id principal) (provider-id principal) (request-id uint))
  (let ((patient-data (map-get? patients { patient-id: patient-id })))
    (begin
      (asserts! (is-some patient-data) ERR-PATIENT-NOT-FOUND)
      (asserts! (or (is-eq tx-sender patient-id) 
                   (is-eq tx-sender (get emergency-contact (unwrap-panic patient-data)))) 
                ERR-NOT-AUTHORIZED)
      (asserts! (is-some (map-get? emergency-access-requests { patient-id: patient-id, provider-id: provider-id, request-id: request-id })) ERR-CONSENT-NOT-FOUND)
      (map-set emergency-access-requests
        { patient-id: patient-id, provider-id: provider-id, request-id: request-id }
        (merge (unwrap-panic (map-get? emergency-access-requests { patient-id: patient-id, provider-id: provider-id, request-id: request-id }))
               { approved: true }
        )
      )
      (ok true)
    )
  )
)

;; Read-only functions

;; Check if consent is valid
(define-read-only (check-consent (patient-id principal) (provider-id principal) (consent-id uint))
  (consent-is-valid patient-id provider-id consent-id)
)

;; Get patient information
(define-read-only (get-patient-info (patient-id principal))
  (map-get? patients { patient-id: patient-id })
)

;; Get provider information  
(define-read-only (get-provider-info (provider-id principal))
  (map-get? healthcare-providers { provider-id: provider-id })
)

;; Get consent details
(define-read-only (get-consent-details (patient-id principal) (provider-id principal) (consent-id uint))
  (map-get? consents { patient-id: patient-id, provider-id: provider-id, consent-id: consent-id })
)

;; Get consent history entry
(define-read-only (get-consent-history (patient-id principal) (consent-id uint) (version uint))
  (map-get? consent-history { patient-id: patient-id, consent-id: consent-id, version: version })
)

;; Get emergency access request
(define-read-only (get-emergency-request (patient-id principal) (provider-id principal) (request-id uint))
  (map-get? emergency-access-requests { patient-id: patient-id, provider-id: provider-id, request-id: request-id })
)

;; Check if emergency access is valid
(define-read-only (check-emergency-access (patient-id principal) (provider-id principal) (request-id uint))
  (match (map-get? emergency-access-requests { patient-id: patient-id, provider-id: provider-id, request-id: request-id })
    request (and 
              (get approved request)
              (< u1 (get expires-at request))
            )
    false
  )
)

;; Get next consent ID
(define-read-only (get-next-consent-id)
  (var-get next-consent-id)
)

;; Get next request ID
(define-read-only (get-next-request-id)
  (var-get next-request-id)
)
