# KipuBank — V2 (Student Project)

[![Open in Remix](https://img.shields.io/badge/Open%20in-Remix-2E9AFE?logo=ethereum&logoColor=white)](https://remix.ethereum.org/#github=renatoribeiroqc/kipu-bank)
**Live Demo (GitHub Pages):** https://renatoribeiroqc.github.io/kipu-bank-v2/  
*(mobile-first UI under `/docs`)*
  
> **What is this?**  
> A student-grade upgrade of the original **KipuBank** vault. V2 adds **access control**, **multi-token** support (ETH + ERC-20), a **global bank cap in USD (USDC-6)** using **Chainlink** data feeds, proper **decimal conversion**, and improved **security** / **observability** — while keeping the **same repo layout** as v1 for continuity.

---

## Improvements vs. KipuBank v1 (What & Why)

- **Access Control (OpenZeppelin)** — An `ADMIN_ROLE` manages cap and token registry. This mirrors real-world operational controls.
- **Multi-Token Accounting** — Store balances by **token + user**. ETH is represented by `address(0)`, ERC-20s by their contract address.
- **USD-Denominated Bank Cap** — Enforce a global cap in **USDC-style 6 decimals** (`USD-6`) using Chainlink feeds at **transaction time**.
- **Decimal Conversion** — Normalize various token decimals + feed decimals into `USD-6` for consistent internal accounting.
- **Custom Errors & Rich Events** — Cheaper, clearer reverts; detailed `Deposited` / `Withdrawn` payloads for debugging & UI.
- **Security & Reliability** — Checks-Effects-Interactions, `ReentrancyGuard`, `SafeERC20`, explicit ETH payout checks, and disabled direct ETH transfers.
- **Docs + UI** — README with design notes/trade-offs, simple mobile-first UI (Bootstrap) supporting **ETH or ERC-20** interactions.

---

## Repository Structure (same layout as v1)

```text
kipu-bank/
├─ contracts/
│  └─ KipuBank.sol              # v2 implementation (replaces v1 file)
├─ tests/
│  └─ KipuBank_test.sol         # Remix Solidity unit tests with mocks
├─ docs/
│  └─ index.html                # multi-token demo UI (GitHub Pages)
├─ README.md
├─ LICENSE                      # MIT recommended
└─ .gitignore
```