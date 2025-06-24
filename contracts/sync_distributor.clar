;; Sync Distributor - Decentralized Transaction Synchronization
;; This contract manages a secure, trustless distribution mechanism for transactions
;; Handles escrow, synchronization, and dispute resolution processes

;; Error Codes
(define-constant err-not-authorized (err u100))
(define-constant err-not-found (err u101))
(define-constant err-already-exists (err u102))
(define-constant err-transaction-inactive (err u103))
(define-constant err-insufficient-funds (err u104))
(define-constant err-transaction-locked (err u105))
(define-constant err-not-participant (err u106))
(define-constant err-already-confirmed (err u108))
(define-constant err-already-disputed (err u110))
(define-constant err-dispute-expired (err u111))

;; Status Constants
(define-constant status-pending u0)
(define-constant status-active u1)
(define-constant status-completed u2)
(define-constant status-disputed u3)
(define-constant status-resolved u4)

;; Dispute Resolution Timeframe
(define-constant dispute-resolution-window u144) ;; Approximately 1 day at 10-minute blocks

;; Transaction Data Structure
(define-map transactions
  { transaction-id: uint }
  {
    sender: principal,
    recipient: principal,
    amount: uint,
    metadata: (string-utf8 500),
    created-at: uint,
    status: uint,
    dispute-details: (optional {
      reason: (string-utf8 500),
      initiated-at: uint
    })
  }
)

;; Transaction ID Counter
(define-data-var next-transaction-id uint u1)

;; Private Helper Functions

;; Validate transaction participants
(define-private (validate-participants (sender principal) (recipient principal))
  (and (not (is-eq sender recipient)) true)
)

;; Read-Only Functions

;; Retrieve transaction details
(define-read-only (get-transaction (transaction-id uint))
  (map-get? transactions { transaction-id: transaction-id })
)

;; Check if dispute is still active
(define-read-only (is-dispute-active (transaction-id uint))
  (match (map-get? transactions { transaction-id: transaction-id })
    transaction
      (match (get dispute-details transaction)
        details
          (< block-height (+ (get initiated-at details) dispute-resolution-window))
        false
      )
    false
  )
)

;; Public Functions

;; Initiate a new synchronized transaction
(define-public (create-transaction
  (recipient principal)
  (amount uint)
  (metadata (string-utf8 500))
)
  (let (
    (sender tx-sender)
    (transaction-id (var-get next-transaction-id))
  )
    ;; Validate transaction participants
    (asserts! (validate-participants sender recipient) err-not-authorized)
    
    ;; Ensure sufficient funds
    (asserts! (>= (stx-get-balance sender) amount) err-insufficient-funds)
    
    ;; Transfer funds to contract escrow
    (try! (stx-transfer? amount sender (as-contract tx-sender)))
    
    ;; Create transaction record
    (map-set transactions
      { transaction-id: transaction-id }
      {
        sender: sender,
        recipient: recipient,
        amount: amount,
        metadata: metadata,
        created-at: block-height,
        status: status-active,
        dispute-details: none
      }
    )
    
    ;; Increment transaction ID
    (var-set next-transaction-id (+ transaction-id u1))
    
    (ok transaction-id)
  )
)

;; Confirm and release transaction
(define-public (confirm-transaction (transaction-id uint))
  (let (
    (transaction (unwrap! (map-get? transactions { transaction-id: transaction-id }) err-not-found))
    (recipient (get recipient transaction))
    (amount (get amount transaction))
  )
    ;; Verify caller is the recipient
    (asserts! (is-eq tx-sender recipient) err-not-authorized)
    
    ;; Ensure transaction is active
    (asserts! (is-eq (get status transaction) status-active) err-transaction-inactive)
    
    ;; Update transaction status
    (map-set transactions
      { transaction-id: transaction-id }
      (merge transaction { status: status-completed })
    )
    
    ;; Release funds to recipient
    (try! (as-contract (stx-transfer? amount tx-sender recipient)))
    
    (ok true)
  )
)

;; Initiate dispute for a transaction
(define-public (initiate-dispute 
  (transaction-id uint)
  (reason (string-utf8 500))
)
  (let (
    (transaction (unwrap! (map-get? transactions { transaction-id: transaction-id }) err-not-found))
    (sender (get sender transaction))
  )
    ;; Verify caller is the sender
    (asserts! (is-eq tx-sender sender) err-not-authorized)
    
    ;; Ensure transaction is active
    (asserts! (is-eq (get status transaction) status-active) err-transaction-inactive)
    
    ;; Prevent multiple disputes
    (asserts! (is-none (get dispute-details transaction)) err-already-disputed)
    
    ;; Update transaction with dispute details
    (map-set transactions
      { transaction-id: transaction-id }
      (merge transaction {
        status: status-disputed,
        dispute-details: (some {
          reason: reason,
          initiated-at: block-height
        })
      })
    )
    
    (ok true)
  )
)

;; Resolve dispute in favor of sender (refund)
(define-public (resolve-dispute-refund (transaction-id uint))
  (let (
    (transaction (unwrap! (map-get? transactions { transaction-id: transaction-id }) err-not-found))
    (sender (get sender transaction))
    (amount (get amount transaction))
  )
    ;; Only sender can resolve their own dispute
    (asserts! (is-eq tx-sender sender) err-not-authorized)
    
    ;; Ensure transaction is in disputed state
    (asserts! (is-eq (get status transaction) status-disputed) err-dispute-expired)
    
    ;; Check dispute is still active
    (asserts! (is-dispute-active transaction-id) err-dispute-expired)
    
    ;; Update transaction status
    (map-set transactions
      { transaction-id: transaction-id }
      (merge transaction { status: status-resolved })
    )
    
    ;; Refund sender
    (try! (as-contract (stx-transfer? amount tx-sender sender)))
    
    (ok true)
  )
)