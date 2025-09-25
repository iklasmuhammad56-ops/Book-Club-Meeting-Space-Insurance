;; book-club-claims
;; Automated compensation processing for covered incidents
;; This contract handles insurance claims, policy management, and payout distributions

;; constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u300))
(define-constant ERR_POLICY_NOT_FOUND (err u301))
(define-constant ERR_CLAIM_NOT_FOUND (err u302))
(define-constant ERR_INSUFFICIENT_FUNDS (err u303))
(define-constant ERR_POLICY_EXPIRED (err u304))
(define-constant ERR_CLAIM_ALREADY_PROCESSED (err u305))
(define-constant ERR_INVALID_AMOUNT (err u306))
(define-constant ERR_CLAIM_DENIED (err u307))

;; policy types
(define-constant BASIC_POLICY "basic")
(define-constant PREMIUM_POLICY "premium")
(define-constant EVENT_SPECIFIC_POLICY "event-specific")
(define-constant ANNUAL_POLICY "annual")

;; claim types
(define-constant VENUE_CANCELLATION "venue-cancel")
(define-constant AUTHOR_CANCELLATION "author-cancel")
(define-constant WEATHER_DISRUPTION "weather")
(define-constant PROPERTY_DAMAGE "property")
(define-constant TECHNICAL_ISSUE "technical")

;; claim status
(define-constant STATUS_PENDING "pending")
(define-constant STATUS_APPROVED "approved")
(define-constant STATUS_DENIED "denied")
(define-constant STATUS_PAID "paid")

;; data maps and vars
(define-map policies
  { policy-id: uint }
  {
    holder: principal,
    policy-type: (string-ascii 20),
    coverage-amount: uint,
    premium-paid: uint,
    start-date: uint,
    end-date: uint,
    venue-ids: (list 10 uint),
    active: bool,
    claims-count: uint
  }
)

(define-map claims
  { claim-id: uint }
  {
    policy-id: uint,
    claimant: principal,
    claim-type: (string-ascii 20),
    incident-date: uint,
    reported-date: uint,
    description: (string-ascii 300),
    requested-amount: uint,
    approved-amount: uint,
    status: (string-ascii 20),
    evidence-hash: (optional (buff 32)),
    processed-by: (optional principal),
    processed-at: (optional uint)
  }
)

(define-map coverage-limits
  { policy-type: (string-ascii 20), claim-type: (string-ascii 20) }
  {
    max-amount: uint,
    deductible: uint,
    coverage-percentage: uint
  }
)

(define-map premium-rates
  { policy-type: (string-ascii 20) }
  {
    base-rate: uint,
    per-venue-rate: uint,
    risk-multiplier: uint
  }
)

(define-map policy-holder-stats
  { holder: principal }
  {
    total-policies: uint,
    total-claims: uint,
    total-payouts: uint,
    risk-score: uint,
    member-since: uint
  }
)

(define-data-var policy-counter uint u0)
(define-data-var claim-counter uint u0)
(define-data-var total-reserves uint u0)
(define-data-var claims-assessors (list 10 principal) (list))
(define-data-var emergency-fund uint u0)

;; private functions
(define-private (is-authorized-assessor (sender principal))
  (or
    (is-eq sender CONTRACT_OWNER)
    (is-some (index-of (var-get claims-assessors) sender))
  )
)

(define-private (calculate-premium (policy-type (string-ascii 20)) (venues-count uint) (coverage-amount uint))
  (match (map-get? premium-rates { policy-type: policy-type })
    rate-data
    (let
      ((base-premium (* (get base-rate rate-data) coverage-amount))
       (venue-premium (* (get per-venue-rate rate-data) venues-count))
       (risk-adjusted (/ (* (+ base-premium venue-premium) (get risk-multiplier rate-data)) u100)))
      (some risk-adjusted)
    )
    none
  )
)

(define-private (min-uint (a uint) (b uint))
  (if (<= a b) a b)
)

(define-private (calculate-payout (claim-type (string-ascii 20)) (policy-type (string-ascii 20)) (requested-amount uint))
  (match (map-get? coverage-limits { policy-type: policy-type, claim-type: claim-type })
    coverage-data
    (let
      ((max-covered (min-uint requested-amount (get max-amount coverage-data)))
       (after-deductible (if (> max-covered (get deductible coverage-data)) 
                           (- max-covered (get deductible coverage-data))
                           u0))
       (final-amount (/ (* after-deductible (get coverage-percentage coverage-data)) u100)))
      (some final-amount)
    )
    none
  )
)

(define-private (is-policy-valid (policy-id uint))
  (match (map-get? policies { policy-id: policy-id })
    policy-data
    (and
      (get active policy-data)
      (>= (get end-date policy-data) burn-block-height)
    )
    false
  )
)

(define-private (update-holder-stats (holder principal) (claim-payout uint))
  (match (map-get? policy-holder-stats { holder: holder })
    current-stats
    (map-set policy-holder-stats
      { holder: holder }
      (merge current-stats {
        total-claims: (+ (get total-claims current-stats) u1),
        total-payouts: (+ (get total-payouts current-stats) claim-payout)
      })
    )
    (map-set policy-holder-stats
      { holder: holder }
      {
        total-policies: u1,
        total-claims: u1,
        total-payouts: claim-payout,
        risk-score: u50,
        member-since: burn-block-height
      }
    )
  )
  true
)

;; public functions
(define-public (create-policy (policy-type (string-ascii 20)) (coverage-amount uint) (venue-ids (list 10 uint)) (duration uint))
  (let
    ((policy-id (+ (var-get policy-counter) u1))
     (venues-count (len venue-ids))
     (end-date (+ burn-block-height duration)))
    (begin
      (asserts! (> coverage-amount u0) ERR_INVALID_AMOUNT)
      (asserts! (> venues-count u0) ERR_INVALID_AMOUNT)
      (match (calculate-premium policy-type venues-count coverage-amount)
        premium-amount
        (begin
          ;; In a real implementation, would collect premium payment here
          (map-set policies
            { policy-id: policy-id }
            {
              holder: tx-sender,
              policy-type: policy-type,
              coverage-amount: coverage-amount,
              premium-paid: premium-amount,
              start-date: burn-block-height,
              end-date: end-date,
              venue-ids: venue-ids,
              active: true,
              claims-count: u0
            }
          )
          (var-set policy-counter policy-id)
          (var-set total-reserves (+ (var-get total-reserves) premium-amount))
          (ok policy-id)
        )
        ERR_INVALID_AMOUNT
      )
    )
  )
)

(define-public (submit-claim (policy-id uint) (claim-type (string-ascii 20)) (incident-date uint) (description (string-ascii 300)) (requested-amount uint) (evidence-hash (optional (buff 32))))
  (let
    ((claim-id (+ (var-get claim-counter) u1))
     (policy-data (unwrap! (map-get? policies { policy-id: policy-id }) ERR_POLICY_NOT_FOUND)))
    (begin
      (asserts! (is-eq (get holder policy-data) tx-sender) ERR_UNAUTHORIZED)
      (asserts! (is-policy-valid policy-id) ERR_POLICY_EXPIRED)
      (asserts! (> requested-amount u0) ERR_INVALID_AMOUNT)
      (asserts! (<= incident-date burn-block-height) ERR_INVALID_AMOUNT)
      (map-set claims
        { claim-id: claim-id }
        {
          policy-id: policy-id,
          claimant: tx-sender,
          claim-type: claim-type,
          incident-date: incident-date,
          reported-date: burn-block-height,
          description: description,
          requested-amount: requested-amount,
          approved-amount: u0,
          status: STATUS_PENDING,
          evidence-hash: evidence-hash,
          processed-by: none,
          processed-at: none
        }
      )
      (map-set policies
        { policy-id: policy-id }
        (merge policy-data { claims-count: (+ (get claims-count policy-data) u1) })
      )
      (var-set claim-counter claim-id)
      (ok claim-id)
    )
  )
)

(define-public (assess-claim (claim-id uint) (approved bool) (approved-amount uint) (notes (string-ascii 200)))
  (let
    ((claim-data (unwrap! (map-get? claims { claim-id: claim-id }) ERR_CLAIM_NOT_FOUND))
     (policy-data (unwrap! (map-get? policies { policy-id: (get policy-id claim-data) }) ERR_POLICY_NOT_FOUND)))
    (begin
      (asserts! (is-authorized-assessor tx-sender) ERR_UNAUTHORIZED)
      (asserts! (is-eq (get status claim-data) STATUS_PENDING) ERR_CLAIM_ALREADY_PROCESSED)
      (let
        ((final-status (if approved STATUS_APPROVED STATUS_DENIED))
         (final-amount (if approved approved-amount u0)))
        (map-set claims
          { claim-id: claim-id }
          (merge claim-data {
            approved-amount: final-amount,
            status: final-status,
            processed-by: (some tx-sender),
            processed-at: (some burn-block-height)
          })
        )
        (ok true)
      )
    )
  )
)

(define-public (process-payout (claim-id uint))
  (let
    ((claim-data (unwrap! (map-get? claims { claim-id: claim-id }) ERR_CLAIM_NOT_FOUND)))
    (begin
      (asserts! (is-authorized-assessor tx-sender) ERR_UNAUTHORIZED)
      (asserts! (is-eq (get status claim-data) STATUS_APPROVED) ERR_CLAIM_DENIED)
      (asserts! (>= (var-get total-reserves) (get approved-amount claim-data)) ERR_INSUFFICIENT_FUNDS)
      ;; In a real implementation, would transfer tokens here
      (var-set total-reserves (- (var-get total-reserves) (get approved-amount claim-data)))
      (map-set claims
        { claim-id: claim-id }
        (merge claim-data { status: STATUS_PAID })
      )
      (update-holder-stats (get claimant claim-data) (get approved-amount claim-data))
      (ok true)
    )
  )
)

(define-public (renew-policy (policy-id uint) (additional-duration uint))
  (let
    ((policy-data (unwrap! (map-get? policies { policy-id: policy-id }) ERR_POLICY_NOT_FOUND)))
    (begin
      (asserts! (is-eq (get holder policy-data) tx-sender) ERR_UNAUTHORIZED)
      (let
        ((new-end-date (+ (get end-date policy-data) additional-duration)))
        (match (calculate-premium (get policy-type policy-data) (len (get venue-ids policy-data)) (get coverage-amount policy-data))
          renewal-premium
          (begin
            ;; In a real implementation, would collect renewal premium here
            (map-set policies
              { policy-id: policy-id }
              (merge policy-data { 
                end-date: new-end-date,
                premium-paid: (+ (get premium-paid policy-data) renewal-premium)
              })
            )
            (var-set total-reserves (+ (var-get total-reserves) renewal-premium))
            (ok true)
          )
          ERR_INVALID_AMOUNT
        )
      )
    )
  )
)

(define-public (cancel-policy (policy-id uint))
  (let
    ((policy-data (unwrap! (map-get? policies { policy-id: policy-id }) ERR_POLICY_NOT_FOUND)))
    (begin
      (asserts! 
        (or
          (is-eq (get holder policy-data) tx-sender)
          (is-eq tx-sender CONTRACT_OWNER)
        )
        ERR_UNAUTHORIZED
      )
      (map-set policies
        { policy-id: policy-id }
        (merge policy-data { active: false })
      )
      (ok true)
    )
  )
)

(define-public (add-claims-assessor (assessor principal))
  (let
    ((current-assessors (var-get claims-assessors)))
    (begin
      (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
      (asserts! (is-none (index-of current-assessors assessor)) ERR_INVALID_AMOUNT)
      (var-set claims-assessors (unwrap! (as-max-len? (append current-assessors assessor) u10) ERR_INVALID_AMOUNT))
      (ok true)
    )
  )
)

(define-public (set-coverage-limit (policy-type (string-ascii 20)) (claim-type (string-ascii 20)) (max-amount uint) (deductible uint) (coverage-percentage uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (> max-amount u0) ERR_INVALID_AMOUNT)
    (asserts! (<= coverage-percentage u100) ERR_INVALID_AMOUNT)
    (map-set coverage-limits
      { policy-type: policy-type, claim-type: claim-type }
      {
        max-amount: max-amount,
        deductible: deductible,
        coverage-percentage: coverage-percentage
      }
    )
    (ok true)
  )
)

(define-public (deposit-emergency-fund (amount uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    ;; In a real implementation, would transfer tokens from sender
    (var-set emergency-fund (+ (var-get emergency-fund) amount))
    (ok true)
  )
)

;; Read-only functions
(define-read-only (get-policy (policy-id uint))
  (map-get? policies { policy-id: policy-id })
)

(define-read-only (get-claim (claim-id uint))
  (map-get? claims { claim-id: claim-id })
)

(define-read-only (get-coverage-limit (policy-type (string-ascii 20)) (claim-type (string-ascii 20)))
  (map-get? coverage-limits { policy-type: policy-type, claim-type: claim-type })
)

(define-read-only (get-holder-stats (holder principal))
  (map-get? policy-holder-stats { holder: holder })
)

(define-read-only (calculate-claim-payout (claim-id uint))
  (match (map-get? claims { claim-id: claim-id })
    claim-data
    (match (map-get? policies { policy-id: (get policy-id claim-data) })
      policy-data
      (calculate-payout (get claim-type claim-data) (get policy-type policy-data) (get requested-amount claim-data))
      none
    )
    none
  )
)

(define-read-only (get-policy-premium (policy-type (string-ascii 20)) (venues-count uint) (coverage-amount uint))
  (calculate-premium policy-type venues-count coverage-amount)
)

(define-read-only (get-total-reserves)
  (var-get total-reserves)
)

(define-read-only (get-emergency-fund)
  (var-get emergency-fund)
)

(define-read-only (get-policy-count)
  (var-get policy-counter)
)

(define-read-only (get-claim-count)
  (var-get claim-counter)
)

(define-read-only (get-claims-assessors)
  (var-get claims-assessors)
)

