;; Access healthcare record (with consent validation)
(define-public (access-record (patient-id principal) (record-id uint) (consent-id (optional uint)))
  (begin
    (asserts! (can-access-data patient-id tx-sender record-id) ERR-NOT-AUTHORIZED)
    (log-data-access patient-id tx-sender record-id "READ" consent-id)
    (ok (map-get? healthcare-records { patient-id: patient-id, record-id: record-id }))
  )
)
