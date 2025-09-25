;; venue-availability-oracle
;; Meeting venue availability tracking and booking confirmation monitoring
;; This contract manages venue bookings, availability status, and conflict detection

;; constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_VENUE_NOT_FOUND (err u101))
(define-constant ERR_BOOKING_CONFLICT (err u102))
(define-constant ERR_INVALID_TIME (err u103))
(define-constant ERR_VENUE_ALREADY_EXISTS (err u104))
(define-constant ERR_BOOKING_NOT_FOUND (err u105))
(define-constant ERR_BOOKING_EXPIRED (err u106))

;; data maps and vars
(define-map venues 
  { venue-id: uint }
  {
    name: (string-ascii 50),
    address: (string-ascii 100),
    capacity: uint,
    hourly-rate: uint,
    owner: principal,
    active: bool
  }
)

(define-map bookings
  { booking-id: uint }
  {
    venue-id: uint,
    booker: principal,
    start-time: uint,
    end-time: uint,
    total-cost: uint,
    status: (string-ascii 20),
    created-at: uint
  }
)

(define-map venue-availability
  { venue-id: uint, date: uint }
  {
    available-slots: (list 24 bool),
    blocked-hours: (list 24 uint),
    maintenance: bool
  }
)

(define-data-var venue-counter uint u0)
(define-data-var booking-counter uint u0)
(define-data-var oracle-operators (list 10 principal) (list))

;; private functions
(define-private (is-authorized (sender principal))
  (or 
    (is-eq sender CONTRACT_OWNER)
    (is-some (index-of (var-get oracle-operators) sender))
  )
)

(define-private (check-time-overlap (start1 uint) (end1 uint) (start2 uint) (end2 uint))
  (or
    (and (>= start1 start2) (< start1 end2))
    (and (>= start2 start1) (< start2 end1))
  )
)

(define-private (validate-booking-time (start-time uint) (end-time uint))
  (and
    (> end-time start-time)
    (>= start-time burn-block-height)
    (<= (- end-time start-time) u24) ;; Max 24 hours
  )
)

(define-private (calculate-booking-cost (venue-id uint) (duration uint))
  (match (map-get? venues { venue-id: venue-id })
    venue-data (ok (* (get hourly-rate venue-data) duration))
    ERR_VENUE_NOT_FOUND
  )
)

(define-private (check-venue-conflicts (venue-id uint) (start-time uint) (end-time uint))
  ;; Simplified conflict check - in real implementation would iterate through bookings
  true ;; For now, assume no conflicts
)

;; public functions
(define-public (register-venue (name (string-ascii 50)) (address (string-ascii 100)) (capacity uint) (hourly-rate uint))
  (let
    ((venue-id (+ (var-get venue-counter) u1)))
    (begin
      (asserts! (> (len name) u0) ERR_INVALID_TIME)
      (asserts! (> capacity u0) ERR_INVALID_TIME)
      (asserts! (> hourly-rate u0) ERR_INVALID_TIME)
      (map-set venues
        { venue-id: venue-id }
        {
          name: name,
          address: address,
          capacity: capacity,
          hourly-rate: hourly-rate,
          owner: tx-sender,
          active: true
        }
      )
      (var-set venue-counter venue-id)
      (ok venue-id)
    )
  )
)

(define-public (create-booking (venue-id uint) (start-time uint) (end-time uint))
  (let
    ((booking-id (+ (var-get booking-counter) u1))
     (duration (- end-time start-time)))
    (begin
      (asserts! (is-some (map-get? venues { venue-id: venue-id })) ERR_VENUE_NOT_FOUND)
      (asserts! (validate-booking-time start-time end-time) ERR_INVALID_TIME)
      (match (calculate-booking-cost venue-id duration)
        total-cost
        (begin
          (asserts! (check-venue-conflicts venue-id start-time end-time) ERR_BOOKING_CONFLICT)
          (map-set bookings
            { booking-id: booking-id }
            {
              venue-id: venue-id,
              booker: tx-sender,
              start-time: start-time,
              end-time: end-time,
              total-cost: total-cost,
              status: "pending",
          created-at: burn-block-height
            }
          )
          (var-set booking-counter booking-id)
          (ok booking-id)
        )
        error error
      )
    )
  )
)

(define-public (confirm-booking (booking-id uint))
  (let
    ((booking-data (unwrap! (map-get? bookings { booking-id: booking-id }) ERR_BOOKING_NOT_FOUND)))
    (begin
      (asserts! (is-authorized tx-sender) ERR_UNAUTHORIZED)
      (asserts! (is-eq (get status booking-data) "pending") ERR_BOOKING_CONFLICT)
      (map-set bookings
        { booking-id: booking-id }
        (merge booking-data { status: "confirmed" })
      )
      (ok true)
    )
  )
)

(define-public (cancel-booking (booking-id uint))
  (let
    ((booking-data (unwrap! (map-get? bookings { booking-id: booking-id }) ERR_BOOKING_NOT_FOUND)))
    (begin
      (asserts! 
        (or 
          (is-eq (get booker booking-data) tx-sender)
          (is-authorized tx-sender)
        ) 
        ERR_UNAUTHORIZED
      )
      (map-set bookings
        { booking-id: booking-id }
        (merge booking-data { status: "cancelled" })
      )
      (ok true)
    )
  )
)

(define-public (update-venue-availability (venue-id uint) (date uint) (available-slots (list 24 bool)))
  (begin
    (asserts! (is-authorized tx-sender) ERR_UNAUTHORIZED)
    (asserts! (is-some (map-get? venues { venue-id: venue-id })) ERR_VENUE_NOT_FOUND)
    (map-set venue-availability
      { venue-id: venue-id, date: date }
      {
        available-slots: available-slots,
        blocked-hours: (list),
        maintenance: false
      }
    )
    (ok true)
  )
)

(define-public (set-venue-maintenance (venue-id uint) (date uint) (maintenance bool))
  (begin
    (asserts! (is-authorized tx-sender) ERR_UNAUTHORIZED)
    (asserts! (is-some (map-get? venues { venue-id: venue-id })) ERR_VENUE_NOT_FOUND)
    (match (map-get? venue-availability { venue-id: venue-id, date: date })
      existing-data
      (map-set venue-availability
        { venue-id: venue-id, date: date }
        (merge existing-data { maintenance: maintenance })
      )
      (map-set venue-availability
        { venue-id: venue-id, date: date }
        {
          available-slots: (list true true true true true true true true true true true true true true true true true true true true true true true true),
          blocked-hours: (list),
          maintenance: maintenance
        }
      )
    )
    (ok true)
  )
)

(define-public (add-oracle-operator (operator principal))
  (let
    ((current-operators (var-get oracle-operators)))
    (begin
      (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
      (asserts! (is-none (index-of current-operators operator)) ERR_VENUE_ALREADY_EXISTS)
      (var-set oracle-operators (unwrap! (as-max-len? (append current-operators operator) u10) ERR_INVALID_TIME))
      (ok true)
    )
  )
)

;; Read-only functions
(define-read-only (get-venue (venue-id uint))
  (map-get? venues { venue-id: venue-id })
)

(define-read-only (get-booking (booking-id uint))
  (map-get? bookings { booking-id: booking-id })
)

(define-read-only (get-venue-availability (venue-id uint) (date uint))
  (map-get? venue-availability { venue-id: venue-id, date: date })
)

(define-read-only (check-availability (venue-id uint) (start-time uint) (end-time uint))
  (and
    (is-some (map-get? venues { venue-id: venue-id }))
    (validate-booking-time start-time end-time)
    (check-venue-conflicts venue-id start-time end-time)
  )
)

(define-read-only (get-venue-count)
  (var-get venue-counter)
)

(define-read-only (get-booking-count)
  (var-get booking-counter)
)

(define-read-only (get-oracle-operators)
  (var-get oracle-operators)
)

