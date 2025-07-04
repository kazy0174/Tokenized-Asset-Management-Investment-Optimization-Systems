;; Strategy Engine Contract
;; Manages investment strategies and their execution

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-UNAUTHORIZED (err u200))
(define-constant ERR-STRATEGY-EXISTS (err u201))
(define-constant ERR-STRATEGY-NOT-FOUND (err u202))
(define-constant ERR-INVALID-PARAMETERS (err u203))
(define-constant ERR-INSUFFICIENT-BALANCE (err u204))
(define-constant ERR-STRATEGY-INACTIVE (err u205))

;; Data Variables
(define-data-var next-strategy-id uint u1)
(define-data-var rebalance-threshold uint u500) ;; 5% threshold

;; Data Maps
(define-map strategies
  { strategy-id: uint }
  {
    manager-id: uint,
    name: (string-ascii 50),
    description: (string-ascii 200),
    risk-level: uint,
    target-allocation: (list 10 { asset: (string-ascii 10), weight: uint }),
    current-allocation: (list 10 { asset: (string-ascii 10), weight: uint }),
    total-value: uint,
    creation-block: uint,
    last-rebalance: uint,
    is-active: bool,
    min-investment: uint,
    max-investment: uint,
    performance-fee: uint,
    management-fee: uint
  }
)

(define-map strategy-investors
  { strategy-id: uint, investor: principal }
  {
    investment-amount: uint,
    shares: uint,
    entry-block: uint,
    last-fee-payment: uint
  }
)

(define-map strategy-performance
  { strategy-id: uint, period: uint }
  {
    total-return: int,
    volatility: uint,
    sharpe-ratio: int,
    max-drawdown: uint,
    alpha: int,
    beta: uint
  }
)

(define-map asset-prices
  { asset: (string-ascii 10) }
  { price: uint, last-update: uint }
)

;; Public Functions

;; Create a new investment strategy
(define-public (create-strategy
  (manager-id uint)
  (name (string-ascii 50))
  (description (string-ascii 200))
  (risk-level uint)
  (target-allocation (list 10 { asset: (string-ascii 10), weight: uint }))
  (min-investment uint)
  (max-investment uint)
  (performance-fee uint)
  (management-fee uint))
  (let
    (
      (strategy-id (var-get next-strategy-id))
    )
    (asserts! (> (len name) u0) ERR-INVALID-PARAMETERS)
    (asserts! (<= risk-level u10) ERR-INVALID-PARAMETERS)
    (asserts! (<= performance-fee u2000) ERR-INVALID-PARAMETERS) ;; Max 20%
    (asserts! (<= management-fee u300) ERR-INVALID-PARAMETERS) ;; Max 3%
    (asserts! (is-valid-allocation target-allocation) ERR-INVALID-PARAMETERS)

    (map-set strategies
      { strategy-id: strategy-id }
      {
        manager-id: manager-id,
        name: name,
        description: description,
        risk-level: risk-level,
        target-allocation: target-allocation,
        current-allocation: target-allocation,
        total-value: u0,
        creation-block: block-height,
        last-rebalance: block-height,
        is-active: true,
        min-investment: min-investment,
        max-investment: max-investment,
        performance-fee: performance-fee,
        management-fee: management-fee
      }
    )

    (var-set next-strategy-id (+ strategy-id u1))
    (ok strategy-id)
  )
)

;; Invest in a strategy
(define-public (invest-in-strategy (strategy-id uint) (amount uint))
  (let
    (
      (strategy-data (unwrap! (map-get? strategies { strategy-id: strategy-id }) ERR-STRATEGY-NOT-FOUND))
      (investor tx-sender)
      (current-investment (default-to
        { investment-amount: u0, shares: u0, entry-block: u0, last-fee-payment: u0 }
        (map-get? strategy-investors { strategy-id: strategy-id, investor: investor })
      ))
    )
    (asserts! (get is-active strategy-data) ERR-STRATEGY-INACTIVE)
    (asserts! (>= amount (get min-investment strategy-data)) ERR-INVALID-PARAMETERS)
    (asserts! (<= (+ amount (get investment-amount current-investment)) (get max-investment strategy-data)) ERR-INVALID-PARAMETERS)

    ;; Calculate shares based on current strategy value
    (let
      (
        (shares-to-issue (calculate-shares strategy-id amount))
        (new-total-value (+ (get total-value strategy-data) amount))
      )

      ;; Update strategy total value
      (map-set strategies
        { strategy-id: strategy-id }
        (merge strategy-data { total-value: new-total-value })
      )

      ;; Update investor position
      (map-set strategy-investors
        { strategy-id: strategy-id, investor: investor }
        {
          investment-amount: (+ (get investment-amount current-investment) amount),
          shares: (+ (get shares current-investment) shares-to-issue),
          entry-block: block-height,
          last-fee-payment: block-height
        }
      )

      (ok shares-to-issue)
    )
  )
)

;; Rebalance strategy portfolio
(define-public (rebalance-strategy (strategy-id uint))
  (let
    (
      (strategy-data (unwrap! (map-get? strategies { strategy-id: strategy-id }) ERR-STRATEGY-NOT-FOUND))
    )
    (asserts! (get is-active strategy-data) ERR-STRATEGY-INACTIVE)
    (asserts! (needs-rebalancing strategy-id) ERR-INVALID-PARAMETERS)

    ;; Update current allocation to match target allocation
    (map-set strategies
      { strategy-id: strategy-id }
      (merge strategy-data {
        current-allocation: (get target-allocation strategy-data),
        last-rebalance: block-height
      })
    )

    (ok true)
  )
)

;; Update asset price (oracle function)
(define-public (update-asset-price (asset (string-ascii 10)) (price uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (map-set asset-prices
      { asset: asset }
      { price: price, last-update: block-height }
    )
    (ok true)
  )
)

;; Record strategy performance
(define-public (record-strategy-performance
  (strategy-id uint)
  (period uint)
  (total-return int)
  (volatility uint)
  (sharpe-ratio int)
  (max-drawdown uint)
  (alpha int)
  (beta uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (is-some (map-get? strategies { strategy-id: strategy-id })) ERR-STRATEGY-NOT-FOUND)

    (map-set strategy-performance
      { strategy-id: strategy-id, period: period }
      {
        total-return: total-return,
        volatility: volatility,
        sharpe-ratio: sharpe-ratio,
        max-drawdown: max-drawdown,
        alpha: alpha,
        beta: beta
      }
    )
    (ok true)
  )
)

;; Read-only Functions

;; Get strategy details
(define-read-only (get-strategy (strategy-id uint))
  (map-get? strategies { strategy-id: strategy-id })
)

;; Get investor position
(define-read-only (get-investor-position (strategy-id uint) (investor principal))
  (map-get? strategy-investors { strategy-id: strategy-id, investor: investor })
)

;; Get strategy performance
(define-read-only (get-strategy-performance (strategy-id uint) (period uint))
  (map-get? strategy-performance { strategy-id: strategy-id, period: period })
)

;; Get asset price
(define-read-only (get-asset-price (asset (string-ascii 10)))
  (map-get? asset-prices { asset: asset })
)

;; Check if strategy needs rebalancing
(define-read-only (needs-rebalancing (strategy-id uint))
  (match (map-get? strategies { strategy-id: strategy-id })
    strategy-data (> (calculate-allocation-drift strategy-id) (var-get rebalance-threshold))
    false
  )
)

;; Calculate shares for investment amount
(define-read-only (calculate-shares (strategy-id uint) (amount uint))
  (match (map-get? strategies { strategy-id: strategy-id })
    strategy-data
      (if (is-eq (get total-value strategy-data) u0)
        amount ;; First investment, 1:1 ratio
        (/ (* amount u1000000) (get total-value strategy-data)) ;; Proportional shares
      )
    u0
  )
)

;; Private Functions

;; Validate allocation weights sum to 100%
(define-private (is-valid-allocation (allocation (list 10 { asset: (string-ascii 10), weight: uint })))
  (is-eq (fold + (map get-weight allocation) u0) u10000) ;; 100% = 10000 basis points
)

;; Get weight from allocation item
(define-private (get-weight (item { asset: (string-ascii 10), weight: uint }))
  (get weight item)
)

;; Calculate allocation drift from target
(define-private (calculate-allocation-drift (strategy-id uint))
  (match (map-get? strategies { strategy-id: strategy-id })
    strategy-data
      (let
        (
          (target (get target-allocation strategy-data))
          (current (get current-allocation strategy-data))
        )
        ;; Simplified drift calculation - would need more complex logic in practice
        u600 ;; Placeholder: 6% drift
      )
    u0
  )
)

;; Get total number of strategies
(define-read-only (get-total-strategies)
  (- (var-get next-strategy-id) u1)
)
