;; Capacity Allocation Contract
;; Distributes bandwidth between service providers

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u500))
(define-constant ERR-PROVIDER-NOT-FOUND (err u501))
(define-constant ERR-INSUFFICIENT-CAPACITY (err u502))
(define-constant ERR-INVALID-ALLOCATION (err u503))
(define-constant ERR-INVALID-INPUT (err u504))
(define-constant ERR-PAYMENT-FAILED (err u505))

;; Data Variables
(define-data-var next-allocation-id uint u1)
(define-data-var total-allocations uint u0)
(define-data-var base-rate-per-gbps uint u1000) ;; Base rate in microSTX per Gbps per block

;; Data Maps
(define-map service-providers
  { provider-id: principal }
  {
    name: (string-ascii 100),
    tier: (string-ascii 20),
    total-allocated: uint,
    current-usage: uint,
    payment-balance: uint,
    reputation-score: uint,
    registration-date: uint,
    active: bool
  }
)

(define-map capacity-allocations
  { allocation-id: uint }
  {
    cable-id: uint,
    provider-id: principal,
    allocated-capacity: uint,
    reserved-capacity: uint,
    allocation-start: uint,
    allocation-end: uint,
    rate-per-gbps: uint,
    status: (string-ascii 20),
    usage-metrics: uint
  }
)

(define-map cable-capacity
  { cable-id: uint }
  {
    total-capacity: uint,
    allocated-capacity: uint,
    available-capacity: uint,
    reserved-capacity: uint,
    utilization-rate: uint,
    last-updated: uint
  }
)

(define-map billing-records
  { record-id: uint }
  {
    provider-id: principal,
    allocation-id: uint,
    billing-period-start: uint,
    billing-period-end: uint,
    usage-amount: uint,
    total-cost: uint,
    paid: bool,
    payment-date: (optional uint)
  }
)

(define-map authorized-allocators
  { allocator: principal }
  { authorized: bool }
)

;; Authorization Functions
(define-public (authorize-allocator (allocator principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (ok (map-set authorized-allocators { allocator: allocator } { authorized: true }))
  )
)

(define-private (is-authorized (allocator principal))
  (or
    (is-eq allocator CONTRACT-OWNER)
    (default-to false (get authorized (map-get? authorized-allocators { allocator: allocator })))
  )
)

;; Provider Management Functions
(define-public (register-service-provider
  (provider-id principal)
  (name (string-ascii 100))
  (tier (string-ascii 20)))
  (begin
    (asserts! (is-authorized tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (> (len name) u0) ERR-INVALID-INPUT)

    (ok (map-set service-providers
      { provider-id: provider-id }
      {
        name: name,
        tier: tier,
        total-allocated: u0,
        current-usage: u0,
        payment-balance: u0,
        reputation-score: u100,
        registration-date: block-height,
        active: true
      }
    ))
  )
)

(define-public (update-provider-balance (provider-id principal) (amount uint))
  (let
    (
      (provider-data (unwrap! (map-get? service-providers { provider-id: provider-id }) ERR-PROVIDER-NOT-FOUND))
    )
    (asserts! (is-authorized tx-sender) ERR-NOT-AUTHORIZED)

    (ok (map-set service-providers
      { provider-id: provider-id }
      (merge provider-data { payment-balance: (+ (get payment-balance provider-data) amount) })
    ))
  )
)

;; Capacity Management Functions
(define-public (initialize-cable-capacity (cable-id uint) (total-capacity uint))
  (begin
    (asserts! (is-authorized tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (> total-capacity u0) ERR-INVALID-INPUT)

    (ok (map-set cable-capacity
      { cable-id: cable-id }
      {
        total-capacity: total-capacity,
        allocated-capacity: u0,
        available-capacity: total-capacity,
        reserved-capacity: u0,
        utilization-rate: u0,
        last-updated: block-height
      }
    ))
  )
)

(define-public (allocate-capacity
  (cable-id uint)
  (provider-id principal)
  (requested-capacity uint)
  (allocation-duration uint))
  (let
    (
      (allocation-id (var-get next-allocation-id))
      (cable-data (unwrap! (map-get? cable-capacity { cable-id: cable-id }) ERR-PROVIDER-NOT-FOUND))
      (provider-data (unwrap! (map-get? service-providers { provider-id: provider-id }) ERR-PROVIDER-NOT-FOUND))
      (rate (var-get base-rate-per-gbps))
      (total-cost (* (* requested-capacity rate) allocation-duration))
    )
    (asserts! (is-authorized tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (> requested-capacity u0) ERR-INVALID-INPUT)
    (asserts! (> allocation-duration u0) ERR-INVALID-INPUT)
    (asserts! (<= requested-capacity (get available-capacity cable-data)) ERR-INSUFFICIENT-CAPACITY)
    (asserts! (>= (get payment-balance provider-data) total-cost) ERR-PAYMENT-FAILED)

    ;; Create allocation record
    (map-set capacity-allocations
      { allocation-id: allocation-id }
      {
        cable-id: cable-id,
        provider-id: provider-id,
        allocated-capacity: requested-capacity,
        reserved-capacity: u0,
        allocation-start: block-height,
        allocation-end: (+ block-height allocation-duration),
        rate-per-gbps: rate,
        status: "active",
        usage-metrics: u0
      }
    )

    ;; Update cable capacity
    (map-set cable-capacity
      { cable-id: cable-id }
      (merge cable-data {
        allocated-capacity: (+ (get allocated-capacity cable-data) requested-capacity),
        available-capacity: (- (get available-capacity cable-data) requested-capacity),
        utilization-rate: (/ (* (+ (get allocated-capacity cable-data) requested-capacity) u10000) (get total-capacity cable-data)),
        last-updated: block-height
      })
    )

    ;; Update provider data
    (map-set service-providers
      { provider-id: provider-id }
      (merge provider-data {
        total-allocated: (+ (get total-allocated provider-data) requested-capacity),
        payment-balance: (- (get payment-balance provider-data) total-cost)
      })
    )

    (var-set next-allocation-id (+ allocation-id u1))
    (var-set total-allocations (+ (var-get total-allocations) u1))
    (ok allocation-id)
  )
)

(define-public (release-capacity (allocation-id uint))
  (let
    (
      (allocation-data (unwrap! (map-get? capacity-allocations { allocation-id: allocation-id }) ERR-INVALID-ALLOCATION))
      (cable-id (get cable-id allocation-data))
      (provider-id (get provider-id allocation-data))
      (allocated-capacity (get allocated-capacity allocation-data))
      (cable-data (unwrap! (map-get? cable-capacity { cable-id: cable-id }) ERR-PROVIDER-NOT-FOUND))
      (provider-data (unwrap! (map-get? service-providers { provider-id: provider-id }) ERR-PROVIDER-NOT-FOUND))
    )
    (asserts! (is-authorized tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status allocation-data) "active") ERR-INVALID-ALLOCATION)

    ;; Update allocation status
    (map-set capacity-allocations
      { allocation-id: allocation-id }
      (merge allocation-data { status: "released" })
    )

    ;; Update cable capacity
    (map-set cable-capacity
      { cable-id: cable-id }
      (merge cable-data {
        allocated-capacity: (- (get allocated-capacity cable-data) allocated-capacity),
        available-capacity: (+ (get available-capacity cable-data) allocated-capacity),
        utilization-rate: (/ (* (- (get allocated-capacity cable-data) allocated-capacity) u10000) (get total-capacity cable-data)),
        last-updated: block-height
      })
    )

    ;; Update provider data
    (map-set service-providers
      { provider-id: provider-id }
      (merge provider-data {
        total-allocated: (- (get total-allocated provider-data) allocated-capacity)
      })
    )

    (ok true)
  )
)

;; Usage Monitoring Functions
(define-public (update-usage-metrics (allocation-id uint) (usage-amount uint))
  (let
    (
      (allocation-data (unwrap! (map-get? capacity-allocations { allocation-id: allocation-id }) ERR-INVALID-ALLOCATION))
      (provider-id (get provider-id allocation-data))
      (provider-data (unwrap! (map-get? service-providers { provider-id: provider-id }) ERR-PROVIDER-NOT-FOUND))
    )
    (asserts! (is-authorized tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (<= usage-amount (get allocated-capacity allocation-data)) ERR-INVALID-INPUT)

    ;; Update allocation usage
    (map-set capacity-allocations
      { allocation-id: allocation-id }
      (merge allocation-data { usage-metrics: usage-amount })
    )

    ;; Update provider current usage
    (map-set service-providers
      { provider-id: provider-id }
      (merge provider-data { current-usage: usage-amount })
    )

    (ok true)
  )
)

;; Billing Functions
(define-public (set-base-rate (new-rate uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (> new-rate u0) ERR-INVALID-INPUT)

    (ok (var-set base-rate-per-gbps new-rate))
  )
)

;; Read-only Functions
(define-read-only (get-provider-info (provider-id principal))
  (map-get? service-providers { provider-id: provider-id })
)

(define-read-only (get-allocation-info (allocation-id uint))
  (map-get? capacity-allocations { allocation-id: allocation-id })
)

(define-read-only (get-cable-capacity (cable-id uint))
  (map-get? cable-capacity { cable-id: cable-id })
)

(define-read-only (get-base-rate)
  (var-get base-rate-per-gbps)
)

(define-read-only (get-total-allocations)
  (var-get total-allocations)
)

(define-read-only (is-allocator-authorized (allocator principal))
  (is-authorized allocator)
)
