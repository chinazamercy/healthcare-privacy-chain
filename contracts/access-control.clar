;; Access Control System Contract
;; Enforces access permissions and role-based access control for healthcare data

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u3001))
(define-constant ERR-INVALID-ROLE (err u3002))
(define-constant ERR-USER-NOT-FOUND (err u3003))
(define-constant ERR-ROLE-NOT-FOUND (err u3004))
(define-constant ERR-PERMISSION-DENIED (err u3005))
(define-constant ERR-SESSION-EXPIRED (err u3006))
(define-constant ERR-INVALID-MFA (err u3007))
(define-constant ERR-ACCOUNT-LOCKED (err u3008))

;; Data structures
(define-map user-roles
  { user-id: principal }
  {
    primary-role: (string-ascii 30),
    secondary-roles: (list 5 (string-ascii 30)),
    department: (string-ascii 50),
    is-active: bool,
    created-at: uint,
    last-login: uint,
    failed-attempts: uint,
    locked-until: uint
  }
)

(define-map role-permissions
  { role-id: (string-ascii 30) }
  {
    permissions: (list 20 (string-ascii 50)),
    data-categories: (list 10 (string-ascii 50)),
    max-access-level: uint,
    emergency-access: bool,
    is-active: bool,
    description: (string-ascii 200)
  }
)

(define-map active-sessions
  { session-id: (buff 32) }
  {
    user-id: principal,
    created-at: uint,
    expires-at: uint,
    ip-address: (string-ascii 45),
    last-activity: uint,
    mfa-verified: bool,
    role-context: (string-ascii 30)
  }
)

(define-map access-attempts
  { attempt-id: uint }
  {
    user-id: principal,
    resource-type: (string-ascii 50),
    resource-id: uint,
    attempted-at: uint,
    success: bool,
    reason: (string-ascii 200),
    ip-address: (string-ascii 45),
    risk-score: uint
  }
)

(define-map emergency-overrides
  { override-id: uint }
  {
    user-id: principal,
    authorized-by: principal,
    activated-at: uint,
    expires-at: uint,
    reason: (string-ascii 500),
    resources-accessed: (list 10 uint),
    is-active: bool
  }
)

(define-map audit-trail
  { audit-id: uint }
  {
    user-id: principal,
    action: (string-ascii 50),
    resource: (string-ascii 100),
    timestamp: uint,
    ip-address: (string-ascii 45),
    success: bool,
    details: (string-ascii 300)
  }
)

(define-map system-policies
  { policy-id: (string-ascii 50) }
  {
    name: (string-ascii 100),
    value: (string-ascii 200),
    is-active: bool,
    updated-at: uint
  }
)

;; Data variables
(define-data-var next-attempt-id uint u1)
(define-data-var next-override-id uint u1)
(define-data-var next-audit-id uint u1)
(define-data-var contract-owner principal tx-sender)
(define-data-var session-timeout uint u3600) ;; 1 hour
(define-data-var max-failed-attempts uint u5)
(define-data-var lockout-duration uint u1800) ;; 30 minutes
(define-data-var mfa-required bool true)

;; Private functions
(define-private (is-contract-owner)
  (is-eq tx-sender (var-get contract-owner))
)

(define-private (has-role (user-id principal) (required-role (string-ascii 30)))
  (match (map-get? user-roles { user-id: user-id })
    user-data (or 
                (is-eq (get primary-role user-data) required-role)
                (is-some (index-of (get secondary-roles user-data) required-role))
              )
    false
  )
)

(define-private (has-permission (role (string-ascii 30)) (permission (string-ascii 50)))
  (match (map-get? role-permissions { role-id: role })
    role-data (is-some (index-of (get permissions role-data) permission))
    false
  )
)

(define-private (is-account-locked (user-id principal))
  (match (map-get? user-roles { user-id: user-id })
    user-data (and 
                (>= (get failed-attempts user-data) (var-get max-failed-attempts))
                (< u1 (get locked-until user-data))
              )
    false
  )
)

(define-private (record-audit (user-id principal) (action (string-ascii 50)) (resource (string-ascii 100)) (success bool) (details (string-ascii 300)))
  (let ((audit-id (var-get next-audit-id)))
    (begin
      (map-set audit-trail
        { audit-id: audit-id }
        {
          user-id: user-id,
          action: action,
          resource: resource,
          timestamp: u1,
          ip-address: "0.0.0.0", ;; Would be provided in real implementation
          success: success,
          details: details
        }
      )
      (var-set next-audit-id (+ audit-id u1))
      audit-id
    )
  )
)

(define-private (validate-session (session-id (buff 32)) (user-id principal))
  (match (map-get? active-sessions { session-id: session-id })
    session (and 
              (is-eq (get user-id session) user-id)
              (< u1 (get expires-at session))
              (< (- u1 (get last-activity session)) (var-get session-timeout))
            )
    false
  )
)

(define-private (calculate-risk-score (user-id principal) (resource-type (string-ascii 50)))
  ;; Simple risk calculation based on user behavior
  (let ((user-data (map-get? user-roles { user-id: user-id })))
    (if (is-some user-data)
      (if (> (get failed-attempts (unwrap-panic user-data)) u2) u7 u3)
      u10 ;; Unknown user gets highest risk
    )
  )
)

;; Public functions

;; Initialize default roles and policies
(define-public (initialize-system)
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    
    ;; Set up default roles
    (map-set role-permissions { role-id: "ADMIN" }
      { permissions: (list "CREATE_USER" "DELETE_USER" "MODIFY_ROLES" "ACCESS_ALL_DATA" "EMERGENCY_OVERRIDE"), 
        data-categories: (list), max-access-level: u5, emergency-access: true, is-active: true, 
        description: "System administrator with full access" })
    
    (map-set role-permissions { role-id: "DOCTOR" }
      { permissions: (list "READ_PATIENT_DATA" "WRITE_PATIENT_DATA" "REQUEST_DATA_SHARING" "CREATE_PRESCRIPTIONS"), 
        data-categories: (list "MEDICAL_HISTORY" "LAB_RESULTS" "PRESCRIPTIONS" "VITAL_SIGNS" "ALLERGIES"), 
        max-access-level: u4, emergency-access: true, is-active: true, 
        description: "Licensed physician with patient care access" })
    
    (map-set role-permissions { role-id: "NURSE" }
      { permissions: (list "READ_PATIENT_DATA" "UPDATE_VITAL_SIGNS" "VIEW_PRESCRIPTIONS"), 
        data-categories: (list "VITAL_SIGNS" "PRESCRIPTIONS"), max-access-level: u3, emergency-access: true, is-active: true, 
        description: "Registered nurse with limited patient data access" })
    
    (map-set role-permissions { role-id: "TECHNICIAN" }
      { permissions: (list "UPLOAD_LAB_RESULTS" "READ_LAB_DATA"), 
        data-categories: (list "LAB_RESULTS"), max-access-level: u2, emergency-access: false, is-active: true, 
        description: "Lab technician for diagnostic data" })
    
    (map-set role-permissions { role-id: "PATIENT" }
      { permissions: (list "READ_OWN_DATA" "GRANT_CONSENT" "REVOKE_CONSENT" "DOWNLOAD_DATA"), 
        data-categories: (list), max-access-level: u5, emergency-access: false, is-active: true, 
        description: "Patient with access to own healthcare data" })
    
    ;; Set up system policies
    (map-set system-policies { policy-id: "PASSWORD_POLICY" }
      { name: "Password Requirements", value: "min_length=12,complexity=high", is-active: true, updated-at: u1 })
    
    (map-set system-policies { policy-id: "SESSION_TIMEOUT" }
      { name: "Session Timeout", value: "3600", is-active: true, updated-at: u1 })
    
    (ok true)
  )
)

;; Assign role to user
(define-public (assign-role 
  (user-id principal) 
  (primary-role (string-ascii 30)) 
  (secondary-roles (list 5 (string-ascii 30))) 
  (department (string-ascii 50))
)
  (begin
    (asserts! (or (is-contract-owner) (has-permission "ADMIN" "CREATE_USER")) ERR-NOT-AUTHORIZED)
    (asserts! (is-some (map-get? role-permissions { role-id: primary-role })) ERR-INVALID-ROLE)
    
    (map-set user-roles
      { user-id: user-id }
      {
        primary-role: primary-role,
        secondary-roles: secondary-roles,
        department: department,
        is-active: true,
        created-at: u1,
        last-login: u0,
        failed-attempts: u0,
        locked-until: u0
      }
    )
    
    (record-audit tx-sender "ASSIGN_ROLE" (unwrap-panic (as-max-len? primary-role u100)) true "Role assigned to user")
    (ok true)
  )
)

;; Create session for authenticated user
(define-public (create-session (session-id (buff 32)) (mfa-token (optional (string-ascii 10))))
  (let ((user-data (map-get? user-roles { user-id: tx-sender })))
    (begin
      (asserts! (is-some user-data) ERR-USER-NOT-FOUND)
      (asserts! (not (is-account-locked tx-sender)) ERR-ACCOUNT-LOCKED)
      
      ;; Validate MFA if required
      (asserts! (or (not (var-get mfa-required)) 
                    (is-some mfa-token)) ERR-INVALID-MFA)
      
      ;; Create session
      (map-set active-sessions
        { session-id: session-id }
        {
          user-id: tx-sender,
          created-at: u1,
          expires-at: (+ u1 (var-get session-timeout)),
          ip-address: "0.0.0.0",
          last-activity: u1,
          mfa-verified: (is-some mfa-token),
          role-context: (get primary-role (unwrap-panic user-data))
        }
      )
      
      ;; Update last login
      (map-set user-roles
        { user-id: tx-sender }
        (merge (unwrap-panic user-data) { last-login: u1, failed-attempts: u0 })
      )
      
      (record-audit tx-sender "LOGIN" "SYSTEM" true "User session created")
      (ok true)
    )
  )
)

;; Check access permission for resource
(define-public (check-access 
  (session-id (buff 32)) 
  (resource-type (string-ascii 50)) 
  (resource-id uint) 
  (required-permission (string-ascii 50))
)
  (let ((session (map-get? active-sessions { session-id: session-id }))
        (attempt-id (var-get next-attempt-id)))
    (begin
      (asserts! (is-some session) ERR-SESSION-EXPIRED)
      (asserts! (validate-session session-id (get user-id (unwrap-panic session))) ERR-SESSION-EXPIRED)
      
      (let ((user-id (get user-id (unwrap-panic session)))
            (role-context (get role-context (unwrap-panic session))))
        (begin
          ;; Check if user has required permission
          (asserts! (has-permission role-context required-permission) ERR-PERMISSION-DENIED)
          
          ;; Record access attempt
          (map-set access-attempts
            { attempt-id: attempt-id }
            {
              user-id: user-id,
              resource-type: resource-type,
              resource-id: resource-id,
              attempted-at: u1,
              success: true,
              reason: "Access granted",
              ip-address: "0.0.0.0",
              risk-score: (calculate-risk-score user-id resource-type)
            }
          )
          
          (var-set next-attempt-id (+ attempt-id u1))
          (record-audit user-id "ACCESS_GRANTED" resource-type true required-permission)
          (ok true)
        )
      )
    )
  )
)

;; Activate emergency override
(define-public (activate-emergency-override 
  (user-id principal) 
  (reason (string-ascii 300)) 
  (duration-blocks uint)
)
  (let ((override-id (var-get next-override-id))
        (expires-at (+ u1 duration-blocks)))
    (begin
      (asserts! (has-role tx-sender "ADMIN") ERR-NOT-AUTHORIZED)
      (asserts! (> duration-blocks u0) ERR-PERMISSION-DENIED)
      
      (map-set emergency-overrides
        { override-id: override-id }
        {
          user-id: user-id,
          authorized-by: tx-sender,
          activated-at: u1,
          expires-at: expires-at,
          reason: reason,
          resources-accessed: (list),
          is-active: true
        }
      )
      
      (var-set next-override-id (+ override-id u1))
      (record-audit tx-sender "EMERGENCY_OVERRIDE" "SYSTEM" true reason)
      (ok override-id)
    )
  )
)

;; Update session activity
(define-public (update-session-activity (session-id (buff 32)))
  (let ((session (map-get? active-sessions { session-id: session-id })))
    (begin
      (asserts! (is-some session) ERR-SESSION-EXPIRED)
      (asserts! (is-eq tx-sender (get user-id (unwrap-panic session))) ERR-NOT-AUTHORIZED)
      
      (map-set active-sessions
        { session-id: session-id }
        (merge (unwrap-panic session) { last-activity: u1 })
      )
      (ok true)
    )
  )
)

;; Revoke user access
(define-public (revoke-user-access (user-id principal) (reason (string-ascii 200)))
  (begin
    (asserts! (has-role tx-sender "ADMIN") ERR-NOT-AUTHORIZED)
    
    (let ((user-data (map-get? user-roles { user-id: user-id })))
      (begin
        (asserts! (is-some user-data) ERR-USER-NOT-FOUND)
        
        ;; Deactivate user
        (map-set user-roles
          { user-id: user-id }
          (merge (unwrap-panic user-data) { is-active: false })
        )
        
        (record-audit tx-sender "REVOKE_ACCESS" "USER" true reason)
        (ok true)
      )
    )
  )
)

;; Read-only functions

;; Get user role information
(define-read-only (get-user-role (user-id principal))
  (map-get? user-roles { user-id: user-id })
)

;; Get role permissions
(define-read-only (get-role-permissions (role-id (string-ascii 30)))
  (map-get? role-permissions { role-id: role-id })
)

;; Get active session
(define-read-only (get-session (session-id (buff 32)))
  (map-get? active-sessions { session-id: session-id })
)

;; Get access attempt
(define-read-only (get-access-attempt (attempt-id uint))
  (map-get? access-attempts { attempt-id: attempt-id })
)

;; Get emergency override
(define-read-only (get-emergency-override (override-id uint))
  (map-get? emergency-overrides { override-id: override-id })
)

;; Get audit record
(define-read-only (get-audit-record (audit-id uint))
  (map-get? audit-trail { audit-id: audit-id })
)

;; Get system policy
(define-read-only (get-policy (policy-id (string-ascii 50)))
  (map-get? system-policies { policy-id: policy-id })
)

;; Check if user has specific role
(define-read-only (user-has-role (user-id principal) (role (string-ascii 30)))
  (has-role user-id role)
)

;; Check if role has specific permission
(define-read-only (role-has-permission (role (string-ascii 30)) (permission (string-ascii 50)))
  (has-permission role permission)
)

;; Validate session without side effects
(define-read-only (is-session-valid (session-id (buff 32)) (user-id principal))
  (validate-session session-id user-id)
)

;; Check if account is locked
(define-read-only (is-user-locked (user-id principal))
  (is-account-locked user-id)
)

;; Get next IDs
(define-read-only (get-next-attempt-id)
  (var-get next-attempt-id)
)

(define-read-only (get-next-override-id)
  (var-get next-override-id)
)

(define-read-only (get-next-audit-id)
  (var-get next-audit-id)
)

;; Get system configuration
(define-read-only (get-session-timeout)
  (var-get session-timeout)
)

(define-read-only (get-max-failed-attempts)
  (var-get max-failed-attempts)
)

(define-read-only (is-mfa-required)
  (var-get mfa-required)
)
