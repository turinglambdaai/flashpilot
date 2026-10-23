#lang racket/base

;; The support matrix as code: one machine-readable record of every
;; transport/adapter subset with its evidence level, consumed by the CLI
;; (`flashpilot transports`) so the matrix cannot rot away from reality.
;;
;; Evidence levels are honest by construction:
;;   "ci-simulated"          — the full loop runs against the simulated
;;                             ECU in CI on every push
;;   "implemented-unverified" — code ships and is unit-tested where
;;                             possible, but no real adapter/ECU has
;;                             confirmed it
;;   "planned"               — not implemented; named so agents and users
;;                             never guess
;;
;; Nothing in this matrix claims production flashing reliability; a
;; "hardware-in-loop verified" level will be added only with a versioned
;; adapter + reference-ECU reproduction report (issue #4 gate).

(require racket/contract
         racket/list
         racket/string)

(provide support-entries
         support-entry?
         support-entry-transport
         support-entry-platform
         support-entry-evidence
         support-entry-notes
         evidence-levels
         transports-json)

(struct support-entry (transport platform evidence notes) #:transparent)

(define evidence-levels '("ci-simulated" "implemented-unverified" "planned"))

(define entries
  (list
   (support-entry
    "socketcan" "Linux" "implemented-unverified"
    "Classic CAN 8-byte frames. Wire codec unit-tested on every platform; \
FD framing shares the code path. No physical adapter/ECU reproduction yet.")
   (support-entry
    "socketcan-fd" "Linux" "ci-simulated"
    "CAN FD data lengths up to 64, canfd_frame wire format, \
CAN_RAW_FD_FRAMES. The complete flash workflow runs over the simulated \
bus with FD framing in CI (examples/plan.sim-fd.json). Hardware \
reproduction pending.")
   (support-entry
    "pcan" "Windows" "implemented-unverified"
    "Classic CAN via the public PCAN-Basic DLL. No CI coverage (adapter \
required); no hardware reproduction report yet.")
   (support-entry
    "pcan-fd" "Windows" "planned"
    "CAN FD over PCAN waits on hardware qualification per the issue #4 \
gate — driver code is not shipped unverified.")
   (support-entry
    "doip" "cross-platform" "implemented-unverified"
    "ISO 13400 DoIP over TCP with a real gateway/ECU still to be \
reproduced; protocol unit-tested.")
   (support-entry
    "lin-simulated" "cross-platform" "ci-simulated"
    "UDS over LIN with ISO 17987-3 style diagnostic framing (0x3C/0x3D, \
NAD + PCI, 6-byte windows, master-paced). The full flash workflow runs \
over the simulated segment in CI (--transport lin). Hardware LIN \
adapters (PLIN/Kvaser and similar) are future work.")
   (support-entry
    "lin-hardware" "adapter-dependent" "planned"
    "Hardware LIN adapters wait on the same versioned adapter + \
reference-ECU reproduction gate as PCAN FD.")))

(define (support-entries) entries)

;; Deterministic JSON for the CLI contract.
(define (transports-json)
  (for/list ([e (in-list entries)])
    (hasheq 'transport (support-entry-transport e)
            'platform (support-entry-platform e)
            'evidence (support-entry-evidence e)
            'notes (string-trim (support-entry-notes e)))))
