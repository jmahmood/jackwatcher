# Contributing

Before you start coding, read our Developer's Code.

# Developer’s Code: Instrument-Grade Software for Companion Devices

**Purpose:**
To build a suite of single-purpose, offline-first tools for low-power handhelds (e.g., RG35XX Plus) that behave like precision instruments — fast, durable, and humane — extending the user’s desktop without succumbing to the bloat and dependency traps of modern app ecosystems.

---

## 1. Speed as Integrity

* Slowness is a defect.
* Apps launch and respond at human speed — no artificial delays, splash screens, or network waits.
* If a cassette player could start instantly, so can we.

---

## 2. Offline-First, Mother–Child Model

* The desktop is the “mother”: gathers, processes, and curates.
* The handheld is the “child”: consumes, records, and carries.
* No direct internet access on the child — all network activity is user-initiated from the mother.

---

## 3. No Browser UIs

* No HTML, CSS, or browser-based shells.
* All interfaces are native to the device and tuned for immediacy.

---

## 4. Single-Purpose Tools

* Each app solves one problem well.
* No engagement loops, gamification, or retention metrics.
* Simplicity beats feature count.

---

## 5. Confidence Over Delight

* Interfaces must foster user trust and capability.
* Fun animations or clever gimmicks are secondary to reliability and predictability.

---

## 6. Durability & Ownership

* Apps and data should work for decades without updates or servers.
* Use human-readable formats when possible (TXT, Markdown, CSV, JSON).
* Backup is trivial: copy files via SD card, USB, or LAN.

---

## 7. AI as Curator

* AI runs on the mother device, never the child.
* AI’s role is to pre-process and deliver meaningful information offline.
* AI does not drive the interface, nor replace core app logic.

---

## 8. Avoid Modality

* Same actions should always yield the same results.
* If modes are unavoidable, make them visible and persistent.
* No hidden state changes.

---

## 9. Always Allow Undo

* All destructive actions must be reversible.
* Provide undo in-session and, where feasible, after the fact.
* Undo is a first-class function, not a hidden safety net.

---

### Design Litmus Test

Before shipping, ask:

1. Is it faster than the 2003 equivalent?
2. Will it still work if the internet disappears?
3. Does it make the user feel more *capable*?
4. Is the data still usable if the app vanishes tomorrow?
5. Would it be pleasant to use in 10 years?
6. Is there mode clarity and undo capability?

If **no** to any, revise.
