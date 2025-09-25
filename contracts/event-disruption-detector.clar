;; event-disruption-detector
;; Book club event disruption detection and author appearance tracking
;; This contract monitors scheduled events for disruptions and manages author confirmations

;; constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u200))
(define-constant ERR_EVENT_NOT_FOUND (err u201))
(define-constant ERR_AUTHOR_NOT_FOUND (err u202))
(define-constant ERR_INVALID_DATE (err u203))
(define-constant ERR_EVENT_ALREADY_EXISTS (err u204))
(define-constant ERR_DISRUPTION_ALREADY_REPORTED (err u205))
(define-constant ERR_INVALID_SEVERITY (err u206))

;; disruption severity levels
(define-constant SEVERITY_LOW u1)
(define-constant SEVERITY_MEDIUM u2)
(define-constant SEVERITY_HIGH u3)
(define-constant SEVERITY_CRITICAL u4)

;; disruption types
(define-constant WEATHER_DISRUPTION "weather")
(define-constant AUTHOR_CANCELLATION "author-cancel")
(define-constant VENUE_ISSUE "venue-issue")
(define-constant TECHNICAL_PROBLEM "technical")
(define-constant OTHER_DISRUPTION "other")

;; data maps and vars
(define-map events
  { event-id: uint }
  {
    title: (string-ascii 100),
    book-club: principal,
    venue-id: uint,
    scheduled-date: uint,
    start-time: uint,
    end-time: uint,
    author-id: (optional uint),
    expected-attendees: uint,
    status: (string-ascii 20),
    created-at: uint
  }
)

(define-map authors
  { author-id: uint }
  {
    name: (string-ascii 50),
    contact-info: (string-ascii 100),
    reliability-score: uint,
    total-events: uint,
    cancelled-events: uint,
    verified: bool
  }
)

(define-map disruptions
  { disruption-id: uint }
  {
    event-id: uint,
    type: (string-ascii 20),
    severity: uint,
    description: (string-ascii 200),
    reported-by: principal,
    confirmed: bool,
    impact-assessment: uint,
    reported-at: uint
  }
)

(define-map author-confirmations
  { event-id: uint, author-id: uint }
  {
    confirmed: bool,
    confirmation-date: uint,
    cancellation-reason: (optional (string-ascii 100)),
    replacement-suggested: bool
  }
)

(define-map weather-alerts
  { alert-id: uint }
  {
    location: (string-ascii 50),
    alert-type: (string-ascii 30),
    severity: uint,
    start-time: uint,
    end-time: uint,
    affects-events: (list 10 uint),
    active: bool
  }
)

(define-data-var event-counter uint u0)
(define-data-var author-counter uint u0)
(define-data-var disruption-counter uint u0)
(define-data-var alert-counter uint u0)
(define-data-var authorized-reporters (list 20 principal) (list))

;; private functions
(define-private (is-authorized-reporter (sender principal))
  (or
    (is-eq sender CONTRACT_OWNER)
    (is-some (index-of (var-get authorized-reporters) sender))
  )
)

(define-private (calculate-reliability-score (total-events uint) (cancelled-events uint))
  (if (is-eq total-events u0)
    u100
    (- u100 (/ (* cancelled-events u100) total-events))
  )
)

(define-private (assess-disruption-impact (severity uint) (expected-attendees uint))
  (* severity expected-attendees)
)

(define-private (is-valid-severity (severity uint))
  (and (>= severity SEVERITY_LOW) (<= severity SEVERITY_CRITICAL))
)

(define-private (update-author-reliability (author-id uint) (cancelled bool))
  (match (map-get? authors { author-id: author-id })
    author-data
    (let
      ((new-total (+ (get total-events author-data) u1))
       (new-cancelled (if cancelled (+ (get cancelled-events author-data) u1) (get cancelled-events author-data))))
      (map-set authors
        { author-id: author-id }
        (merge author-data {
          total-events: new-total,
          cancelled-events: new-cancelled,
          reliability-score: (calculate-reliability-score new-total new-cancelled)
        })
      )
      true
    )
    false
  )
)

;; public functions
(define-public (create-event (title (string-ascii 100)) (venue-id uint) (scheduled-date uint) (start-time uint) (end-time uint) (expected-attendees uint))
  (let
    ((event-id (+ (var-get event-counter) u1)))
    (begin
      (asserts! (> (len title) u0) ERR_INVALID_DATE)
      (asserts! (> end-time start-time) ERR_INVALID_DATE)
      (asserts! (>= scheduled-date burn-burn-block-height) ERR_INVALID_DATE)
      (asserts! (> expected-attendees u0) ERR_INVALID_DATE)
      (map-set events
        { event-id: event-id }
        {
          title: title,
          book-club: tx-sender,
          venue-id: venue-id,
          scheduled-date: scheduled-date,
          start-time: start-time,
          end-time: end-time,
          author-id: none,
          expected-attendees: expected-attendees,
          status: "scheduled",
          created-at: burn-block-height
        }
      )
      (var-set event-counter event-id)
      (ok event-id)
    )
  )
)

(define-public (register-author (name (string-ascii 50)) (contact-info (string-ascii 100)))
  (let
    ((author-id (+ (var-get author-counter) u1)))
    (begin
      (asserts! (> (len name) u0) ERR_INVALID_DATE)
      (map-set authors
        { author-id: author-id }
        {
          name: name,
          contact-info: contact-info,
          reliability-score: u100,
          total-events: u0,
          cancelled-events: u0,
          verified: false
        }
      )
      (var-set author-counter author-id)
      (ok author-id)
    )
  )
)

(define-public (assign-author-to-event (event-id uint) (author-id uint))
  (let
    ((event-data (unwrap! (map-get? events { event-id: event-id }) ERR_EVENT_NOT_FOUND)))
    (begin
      (asserts! (is-eq (get book-club event-data) tx-sender) ERR_UNAUTHORIZED)
      (asserts! (is-some (map-get? authors { author-id: author-id })) ERR_AUTHOR_NOT_FOUND)
      (map-set events
        { event-id: event-id }
        (merge event-data { author-id: (some author-id) })
      )
      (ok true)
    )
  )
)

(define-public (confirm-author-attendance (event-id uint) (author-id uint) (confirmed bool) (reason (optional (string-ascii 100))))
  (begin
    (asserts! (is-some (map-get? events { event-id: event-id })) ERR_EVENT_NOT_FOUND)
    (asserts! (is-some (map-get? authors { author-id: author-id })) ERR_AUTHOR_NOT_FOUND)
    (map-set author-confirmations
      { event-id: event-id, author-id: author-id }
      {
        confirmed: confirmed,
        confirmation-date: burn-block-height,
        cancellation-reason: reason,
        replacement-suggested: false
      }
    )
    (update-author-reliability author-id (not confirmed))
    (ok true)
  )
)

(define-public (report-disruption (event-id uint) (disruption-type (string-ascii 20)) (severity uint) (description (string-ascii 200)))
  (let
    ((disruption-id (+ (var-get disruption-counter) u1))
     (event-data (unwrap! (map-get? events { event-id: event-id }) ERR_EVENT_NOT_FOUND)))
    (begin
      (asserts! (is-authorized-reporter tx-sender) ERR_UNAUTHORIZED)
      (asserts! (is-valid-severity severity) ERR_INVALID_SEVERITY)
      (map-set disruptions
        { disruption-id: disruption-id }
        {
          event-id: event-id,
          type: disruption-type,
          severity: severity,
          description: description,
          reported-by: tx-sender,
          confirmed: false,
          impact-assessment: (assess-disruption-impact severity (get expected-attendees event-data)),
          reported-at: burn-block-height
        }
      )
      (var-set disruption-counter disruption-id)
      (ok disruption-id)
    )
  )
)

(define-public (confirm-disruption (disruption-id uint))
  (let
    ((disruption-data (unwrap! (map-get? disruptions { disruption-id: disruption-id }) ERR_EVENT_NOT_FOUND)))
    (begin
      (asserts! (is-authorized-reporter tx-sender) ERR_UNAUTHORIZED)
      (map-set disruptions
        { disruption-id: disruption-id }
        (merge disruption-data { confirmed: true })
      )
      (ok true)
    )
  )
)

(define-public (create-weather-alert (location (string-ascii 50)) (alert-type (string-ascii 30)) (severity uint) (start-time uint) (end-time uint) (affected-events (list 10 uint)))
  (let
    ((alert-id (+ (var-get alert-counter) u1)))
    (begin
      (asserts! (is-authorized-reporter tx-sender) ERR_UNAUTHORIZED)
      (asserts! (is-valid-severity severity) ERR_INVALID_SEVERITY)
      (asserts! (> end-time start-time) ERR_INVALID_DATE)
      (map-set weather-alerts
        { alert-id: alert-id }
        {
          location: location,
          alert-type: alert-type,
          severity: severity,
          start-time: start-time,
          end-time: end-time,
          affects-events: affected-events,
          active: true
        }
      )
      (var-set alert-counter alert-id)
      (ok alert-id)
    )
  )
)

(define-public (update-event-status (event-id uint) (status (string-ascii 20)))
  (let
    ((event-data (unwrap! (map-get? events { event-id: event-id }) ERR_EVENT_NOT_FOUND)))
    (begin
      (asserts! 
        (or
          (is-eq (get book-club event-data) tx-sender)
          (is-authorized-reporter tx-sender)
        )
        ERR_UNAUTHORIZED
      )
      (map-set events
        { event-id: event-id }
        (merge event-data { status: status })
      )
      (ok true)
    )
  )
)

(define-public (add-authorized-reporter (reporter principal))
  (let
    ((current-reporters (var-get authorized-reporters)))
    (begin
      (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
      (asserts! (is-none (index-of current-reporters reporter)) ERR_EVENT_ALREADY_EXISTS)
      (var-set authorized-reporters (unwrap! (as-max-len? (append current-reporters reporter) u20) ERR_INVALID_DATE))
      (ok true)
    )
  )
)

;; Read-only functions
(define-read-only (get-event (event-id uint))
  (map-get? events { event-id: event-id })
)

(define-read-only (get-author (author-id uint))
  (map-get? authors { author-id: author-id })
)

(define-read-only (get-disruption (disruption-id uint))
  (map-get? disruptions { disruption-id: disruption-id })
)

(define-read-only (get-author-confirmation (event-id uint) (author-id uint))
  (map-get? author-confirmations { event-id: event-id, author-id: author-id })
)

(define-read-only (get-weather-alert (alert-id uint))
  (map-get? weather-alerts { alert-id: alert-id })
)

(define-read-only (get-event-disruption-risk (event-id uint))
  ;; Calculate risk score based on author reliability, weather, and historical data
  (match (map-get? events { event-id: event-id })
    event-data
    (match (get author-id event-data)
      author-id
      (match (map-get? authors { author-id: author-id })
        author-data
        (some (- u100 (get reliability-score author-data)))
        (some u50) ;; Default risk if author not found
      )
      (some u30) ;; Lower risk if no author assigned
    )
    none ;; Event not found
  )
)

(define-read-only (get-event-count)
  (var-get event-counter)
)

(define-read-only (get-author-count)
  (var-get author-counter)
)

(define-read-only (get-disruption-count)
  (var-get disruption-counter)
)

(define-read-only (get-authorized-reporters)
  (var-get authorized-reporters)
)

