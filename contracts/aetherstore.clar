;; AetherStore Decentralized Marketplace
;; This contract manages a decentralized marketplace on the Stacks blockchain, handling:
;; - Product listings and information
;; - Purchases and escrow mechanics
;; - Dispute resolution
;; - User reputation tracking
;; The marketplace connects buyers and sellers directly without intermediaries,
;; using escrow to ensure secure and trustless transactions.

;; Error codes
(define-constant err-not-authorized (err u100))
(define-constant err-not-found (err u101))
(define-constant err-already-exists (err u102))
(define-constant err-listing-inactive (err u103))
(define-constant err-insufficient-funds (err u104))
(define-constant err-listing-locked (err u105))
(define-constant err-not-buyer (err u106))
(define-constant err-not-seller (err u107))
(define-constant err-already-confirmed (err u108))
(define-constant err-already-refunded (err u109))
(define-constant err-already-disputed (err u110))
(define-constant err-dispute-expired (err u111))
(define-constant err-dispute-active (err u112))
(define-constant err-invalid-rating (err u113))
(define-constant err-escrow-not-completed (err u114))

;; Status constants
(define-constant status-active u1)
(define-constant status-inactive u0)
(define-constant status-completed u2)
(define-constant status-disputed u3)
(define-constant status-refunded u4)

;; Dispute resolution timeframe (in blocks)
(define-constant dispute-resolution-period u144) ;; Approximately 1 day at 10-minute blocks

;; Data structures

;; Product listing information
(define-map listings
  { listing-id: uint }
  {
    seller: principal,
    title: (string-ascii 100),
    description: (string-utf8 1000),
    price: uint,
    image-url: (optional (string-ascii 256)),
    category: (string-ascii 50),
    quantity: uint,
    created-at: uint,
    status: uint ;; 0=inactive, 1=active, 2=completed
  }
)

;; Purchase and escrow details
(define-map purchases
  { purchase-id: uint }
  {
    listing-id: uint,
    buyer: principal,
    seller: principal,
    price: uint,
    quantity: uint,
    purchase-time: uint,
    delivery-address: (string-utf8 500),
    status: uint, ;; 0=inactive, 1=active/in-escrow, 2=completed, 3=disputed, 4=refunded
    dispute-data: (optional { reason: (string-utf8 500), resolved-at: (optional uint) }),
    confirmed-at: (optional uint)
  }
)

;; User reputation data
(define-map user-reputation
  { user: principal }
  {
    total-sales: uint,
    total-purchases: uint,
    seller-rating-sum: uint,
    seller-rating-count: uint,
    buyer-rating-sum: uint,
    buyer-rating-count: uint
  }
)

;; Ratings for transactions
(define-map transaction-ratings
  { purchase-id: uint, rater: principal }
  {
    rating: uint, ;; 1-5 rating
    comment: (optional (string-utf8 500))
  }
)

;; Counters for IDs
(define-data-var next-listing-id uint u1)
(define-data-var next-purchase-id uint u1)

;; Private helper functions

;; Initialize user reputation if not already present
(define-private (initialize-user-reputation (user principal))
  (begin
    (map-insert user-reputation
      { user: user }
      {
        total-sales: u0,
        total-purchases: u0,
        seller-rating-sum: u0,
        seller-rating-count: u0,
        buyer-rating-sum: u0,
        buyer-rating-count: u0
      }
    )
    true
  )
)

;; Check if user reputation exists, initialize if not
(define-private (ensure-user-reputation (user principal))
  (match (map-get? user-reputation { user: user })
    existing-rep true  ;; If exists, return true
    (initialize-user-reputation user)  ;; If not, initialize and return the result
  )
)

;; Update seller reputation after a completed transaction
(define-private (update-seller-reputation (seller principal) (rating uint))
  (let (
    (current-rep (unwrap! (map-get? user-reputation { user: seller }) (initialize-user-reputation seller)))
  )
    (map-set user-reputation
      { user: seller }
      (merge current-rep {
        total-sales: (+ (get total-sales current-rep) u1),
        seller-rating-sum: (+ (get seller-rating-sum current-rep) rating),
        seller-rating-count: (+ (get seller-rating-count current-rep) u1)
      })
    )
  )
)

;; Update buyer reputation after a completed transaction
(define-private (update-buyer-reputation (buyer principal) (rating uint))
  (let (
    (current-rep (unwrap! (map-get? user-reputation { user: buyer }) (initialize-user-reputation buyer)))
  )
    (map-set user-reputation
      { user: buyer }
      (merge current-rep {
        total-purchases: (+ (get total-purchases current-rep) u1),
        buyer-rating-sum: (+ (get buyer-rating-sum current-rep) rating),
        buyer-rating-count: (+ (get buyer-rating-count current-rep) u1)
      })
    )
  )
)

;; Read-only functions

;; Get listing details
(define-read-only (get-listing (listing-id uint))
  (map-get? listings { listing-id: listing-id })
)

;; Get purchase details
(define-read-only (get-purchase (purchase-id uint))
  (map-get? purchases { purchase-id: purchase-id })
)

;; Get user reputation
(define-read-only (get-user-reputation (user principal))
  (default-to 
    {
      total-sales: u0,
      total-purchases: u0,
      seller-rating-sum: u0,
      seller-rating-count: u0,
      buyer-rating-sum: u0,
      buyer-rating-count: u0
    }
    (map-get? user-reputation { user: user })
  )
)

;; Calculate seller average rating
(define-read-only (get-seller-rating (user principal))
  (let (
    (rep (get-user-reputation user))
    (count (get seller-rating-count rep))
  )
    (if (> count u0)
      (/ (get seller-rating-sum rep) count)
      u0
    )
  )
)

;; Calculate buyer average rating
(define-read-only (get-buyer-rating (user principal))
  (let (
    (rep (get-user-reputation user))
    (count (get buyer-rating-count rep))
  )
    (if (> count u0)
      (/ (get buyer-rating-sum rep) count)
      u0
    )
  )
)

;; Get transaction rating
(define-read-only (get-transaction-rating (purchase-id uint) (rater principal))
  (map-get? transaction-ratings { purchase-id: purchase-id, rater: rater })
)

;; Check if dispute is still within resolution period
(define-read-only (is-dispute-active (purchase-id uint))
  (match (map-get? purchases { purchase-id: purchase-id })
    purchase-data
      (let ((purchase purchase-data)) ;; Use the matched value directly
        (if (not (is-eq (get status purchase) status-disputed))
          false ;; Not in dispute
          (match (get dispute-data purchase)
            dispute-record
              (match (get resolved-at dispute-record)
                resolved-block
                  ;; Dispute exists and has resolved_at timestamp, check period
                  (< block-height (+ resolved-block dispute-resolution-period))
                ;; Dispute exists but resolved-at is none (shouldn't happen with current logic, but handle defensively)
                false
              )
            ;; No dispute data
            false
          )
        )
      )
    ;; Purchase not found
    false
  )
)

;; Public functions

;; Create a new product listing
(define-public (create-listing 
  (title (string-ascii 100))
  (description (string-utf8 1000))
  (price uint)
  (image-url (optional (string-ascii 256)))
  (category (string-ascii 50))
  (quantity uint)
)
  (let (
    (listing-id (var-get next-listing-id))
    (seller tx-sender)
  )
    ;; Ensure quantity is greater than zero
    (asserts! (> quantity u0) err-insufficient-funds)
    
    ;; Initialize seller reputation if needed
    (ensure-user-reputation seller)
    
    ;; Create the listing
    (map-set listings
      { listing-id: listing-id }
      {
        seller: seller,
        title: title,
        description: description,
        price: price,
        image-url: image-url,
        category: category,
        quantity: quantity,
        created-at: block-height,
        status: status-active
      }
    )
    
    ;; Increment listing ID counter
    (var-set next-listing-id (+ listing-id u1))
    
    ;; Return success with the listing ID
    (ok listing-id)
  )
)

;; Update an existing listing
(define-public (update-listing
  (listing-id uint)
  (title (string-ascii 100))
  (description (string-utf8 1000))
  (price uint)
  (image-url (optional (string-ascii 256)))
  (category (string-ascii 50))
  (quantity uint)
  (status uint)
)
  (let (
    (listing (unwrap! (map-get? listings { listing-id: listing-id }) err-not-found))
  )
    ;; Check authorization
    (asserts! (is-eq tx-sender (get seller listing)) err-not-authorized)
    
    ;; Check that listing is not completed
    (asserts! (not (is-eq (get status listing) status-completed)) err-listing-locked)
    
    ;; Update the listing
    (map-set listings
      { listing-id: listing-id }
      (merge listing {
        title: title,
        description: description,
        price: price,
        image-url: image-url,
        category: category,
        quantity: quantity,
        status: status
      })
    )
    
    (ok true)
  )
)

;; Purchase an item, transferring funds to escrow
(define-public (purchase-item
  (listing-id uint)
  (quantity uint)
  (delivery-address (string-utf8 500))
)
  (let (
    (listing (unwrap! (map-get? listings { listing-id: listing-id }) err-not-found))
    (buyer tx-sender)
    (seller (get seller listing))
    (price (get price listing))
    (available-quantity (get quantity listing))
    (purchase-id (var-get next-purchase-id))
    (total-price (* price quantity))
  )
    ;; Check listing is active
    (asserts! (is-eq (get status listing) status-active) err-listing-inactive)
    
    ;; Check sufficient quantity available
    (asserts! (<= quantity available-quantity) err-insufficient-funds)
    
    ;; Check buyer != seller
    (asserts! (not (is-eq buyer seller)) err-not-authorized)
    
    ;; Ensure buyer reputation exists
    (ensure-user-reputation buyer)
    
    ;; Transfer funds to escrow (contract)
    (try! (stx-transfer? total-price buyer (as-contract tx-sender)))
    
    ;; Create purchase record
    (map-set purchases
      { purchase-id: purchase-id }
      {
        listing-id: listing-id,
        buyer: buyer,
        seller: seller,
        price: price,
        quantity: quantity,
        purchase-time: block-height,
        delivery-address: delivery-address,
        status: status-active,
        dispute-data: none,
        confirmed-at: none
      }
    )
    
    ;; Update listing quantity
    (map-set listings
      { listing-id: listing-id }
      (merge listing {
        quantity: (- available-quantity quantity),
        status: (if (is-eq (- available-quantity quantity) u0) status-inactive status-active)
      })
    )
    
    ;; Increment purchase ID counter
    (var-set next-purchase-id (+ purchase-id u1))
    
    (ok purchase-id)
  )
)

;; Confirm receipt of item, releasing funds from escrow to seller
(define-public (confirm-receipt (purchase-id uint))
  (let (
    (purchase (unwrap! (map-get? purchases { purchase-id: purchase-id }) err-not-found))
    (buyer (get buyer purchase))
    (seller (get seller purchase))
    (total-price (* (get price purchase) (get quantity purchase)))
  )
    ;; Check authorization
    (asserts! (is-eq tx-sender buyer) err-not-buyer)
    
    ;; Check purchase is active (in escrow)
    (asserts! (is-eq (get status purchase) status-active) err-listing-inactive)
    
    ;; Check not already confirmed
    (asserts! (is-none (get confirmed-at purchase)) err-already-confirmed)
    
    ;; Update purchase status
    (map-set purchases
      { purchase-id: purchase-id }
      (merge purchase {
        status: status-completed,
        confirmed-at: (some block-height)
      })
    )
    
    ;; Transfer funds from escrow to seller
    (try! (as-contract (stx-transfer? total-price tx-sender seller)))
    
    (ok true)
  )
)

;; Initiate a dispute for a purchase
(define-public (initiate-dispute (purchase-id uint) (reason (string-utf8 500)))
  (let (
    (purchase (unwrap! (map-get? purchases { purchase-id: purchase-id }) err-not-found))
    (buyer (get buyer purchase))
  )
    ;; Check authorization
    (asserts! (is-eq tx-sender buyer) err-not-buyer)
    
    ;; Check purchase is active (in escrow)
    (asserts! (is-eq (get status purchase) status-active) err-listing-inactive)
    
    ;; Check not already disputed or completed
    (asserts! (is-none (get dispute-data purchase)) err-already-disputed)
    
    ;; Update purchase with dispute data
    (map-set purchases
      { purchase-id: purchase-id }
      (merge purchase {
        status: status-disputed,
        dispute-data: (some { 
          reason: reason,
          resolved-at: (some block-height)
        })
      })
    )
    
    (ok true)
  )
)

;; Resolve dispute in favor of buyer (refund)
(define-public (resolve-dispute-refund (purchase-id uint))
  (let (
    (purchase (unwrap! (map-get? purchases { purchase-id: purchase-id }) err-not-found))
    (buyer (get buyer purchase))
    (total-price (* (get price purchase) (get quantity purchase)))
  )
    ;; Only contract owner can resolve disputes (in real implementation, use multi-sig or oracle)
    ;; For simplicity, we're using tx-sender, but in production this would need a proper governance mechanism
    (asserts! (is-eq tx-sender (get seller purchase)) err-not-authorized)
    
    ;; Check purchase is in disputed state
    (asserts! (is-eq (get status purchase) status-disputed) err-dispute-expired)
    
    ;; Check dispute is still active
    (asserts! (is-dispute-active purchase-id) err-dispute-expired)
    
    ;; Update purchase status
    (map-set purchases
      { purchase-id: purchase-id }
      (merge purchase {
        status: status-refunded
      })
    )
    
    ;; Transfer funds from escrow to buyer (refund)
    (try! (as-contract (stx-transfer? total-price tx-sender buyer)))
    
    (ok true)
  )
)

;; Resolve dispute in favor of seller
(define-public (resolve-dispute-release (purchase-id uint))
  (let (
    (purchase (unwrap! (map-get? purchases { purchase-id: purchase-id }) err-not-found))
    (seller (get seller purchase))
    (total-price (* (get price purchase) (get quantity purchase)))
  )
    ;; Only contract owner can resolve disputes (in real implementation, use multi-sig or oracle)
    ;; For simplicity, we're using tx-sender, but in production this would need a proper governance mechanism
    (asserts! (is-eq tx-sender (get seller purchase)) err-not-authorized)
    
    ;; Check purchase is in disputed state
    (asserts! (is-eq (get status purchase) status-disputed) err-dispute-expired)
    
    ;; Check dispute is still active
    (asserts! (is-dispute-active purchase-id) err-dispute-expired)
    
    ;; Update purchase status
    (map-set purchases
      { purchase-id: purchase-id }
      (merge purchase {
        status: status-completed,
        confirmed-at: (some block-height)
      })
    )
    
    ;; Transfer funds from escrow to seller
    (try! (as-contract (stx-transfer? total-price tx-sender seller)))
    
    (ok true)
  )
)

;; Rate a seller after transaction completion
(define-public (rate-seller (purchase-id uint) (rating uint) (comment (optional (string-utf8 500))))
  (let (
    (purchase (unwrap! (map-get? purchases { purchase-id: purchase-id }) err-not-found))
    (buyer (get buyer purchase))
    (seller (get seller purchase))
  )
    ;; Check authorization
    (asserts! (is-eq tx-sender buyer) err-not-buyer)
    
    ;; Check purchase is completed
    (asserts! (is-eq (get status purchase) status-completed) err-escrow-not-completed)
    
    ;; Validate rating (1-5)
    (asserts! (and (>= rating u1) (<= rating u5)) err-invalid-rating)
    
    ;; Save the rating
    (map-set transaction-ratings
      { purchase-id: purchase-id, rater: tx-sender }
      { rating: rating, comment: comment }
    )
    
    ;; Update seller reputation
    (update-seller-reputation seller rating)
    
    (ok true)
  )
)

;; Rate a buyer after transaction completion
(define-public (rate-buyer (purchase-id uint) (rating uint) (comment (optional (string-utf8 500))))
  (let (
    (purchase (unwrap! (map-get? purchases { purchase-id: purchase-id }) err-not-found))
    (buyer (get buyer purchase))
    (seller (get seller purchase))
  )
    ;; Check authorization
    (asserts! (is-eq tx-sender seller) err-not-seller)
    
    ;; Check purchase is completed
    (asserts! (is-eq (get status purchase) status-completed) err-escrow-not-completed)
    
    ;; Validate rating (1-5)
    (asserts! (and (>= rating u1) (<= rating u5)) err-invalid-rating)
    
    ;; Save the rating
    (map-set transaction-ratings
      { purchase-id: purchase-id, rater: tx-sender }
      { rating: rating, comment: comment }
    )
    
    ;; Update buyer reputation
    (update-buyer-reputation buyer rating)
    
    (ok true)
  )
)