# StreamBudget: why we need `sync`

The setup: `demandPerFill = 100 B`, the market price is **1 A = 1 B**, and the stream grows by
**100 A per day**.

## Why a jump is a problem

In OpenFill, the B side is fixed and the A side grows:

```
price per A = demandPerFill / available
```

The more A on offer, the cheaper each A gets. This is a Dutch auction: the price falls slowly, and the
first filler for whom the deal is profitable takes it. If the price falls **gradually**, the DAO sells
at about the market price.

**Smooth growth (good):**

| available | price per A | filler's view        |
| --------- | ----------- | -------------------- |
| 50 A      | 2 B         | too expensive, wait  |
| 90 A      | 1.11 B      | still too expensive  |
| 101 A     | 0.99 B      | profitable, fill     |

The DAO gets 100 B for about 101 A, which is fair.

**A jump from 0 to 500 A (bad):**

| available | price per A | filler's view        |
| --------- | ----------- | -------------------- |
| 0 A       | n/a         | nothing to fill      |
| 500 A     | 0.2 B       | fill immediately     |

The filler pays 100 B for 500 A, which is worth 500 B. **The DAO loses about 400 B of value.** The jump
skipped every fair price in between.

> A jump is harmless for a plain payment (a Transfer leaf just pays more). It's harmful because here
> the amount sets a **price**.

## Why the jump happens

`accrued` depends **only on time**. It doesn't care whether the DAO has tokens. The balance only *caps*
what is shown.

Take a naive budget, `available = min(accrued, daoBalance)`, with the DAO empty at the checkpoint:

| day | event         | accrued | daoBalance | available | what's happening                           |
| --- | ------------- | ------- | ---------- | --------- | ------------------------------------------ |
| 0   | checkpoint    | 0       | 0          | 0         | the stream starts                          |
| 1   | time passes   | 100     | 0          | 0         | the cap hides 100                          |
| 3   | time passes   | 300     | 0          | 0         | the cap hides 300                          |
| 5   | time passes   | 500     | 0          | 0         | the cap hides 500                          |
| 5   | deposit 1000  | 500     | 1000       | **500**   | the cap rises: **all 500 appears at once** |

The deposit didn't create the 500. It **removed the cap**, and everything that built up behind it came
out together. Think of water running into a closed bucket: when someone opens the lid, it all pours out.

## How StreamBudget solves it

It uses two pieces that work together.

**Piece 1: `lastSeenBalance`, a cap a deposit can't move.**

```
available = min(accrued, lastSeenBalance, daoBalance, maxBudget)
```

`lastSeenBalance` is a stored number. A deposit only changes `daoBalance`, so the minimum stays 0. The
lid stays shut.

But now nothing can ever open it. `lastSeenBalance` only updates at a checkpoint, a checkpoint only
happens after a trigger, and a trigger with 0 available reverts. **This deadlock is why `sync` exists.**

**Piece 2: `sync()`, which deletes the backlog first and only then lifts the cap.**

```solidity
uint256 _amount = _available(_balance);    // what is visible now: 0
if (_amount < _accrued()) {                // something is hidden (0 < 500)
    baseAmount    = _amount;               // restart the curve from what is visible (0)...
    baseTimestamp = block.timestamp;       // ...starting now
}
lastSeenBalance = _balance;                // only now raise the cap to 1000
```

**The same scenario with StreamBudget:**

| day | event          | accrued                   | lastSeen | daoBalance | available                       |
| --- | -------------- | ------------------------- | -------- | ---------- | ------------------------------- |
| 0   | checkpoint     | 0                         | 0        | 0          | 0                               |
| 5   | time passes    | 500                       | 0        | 0          | 0                               |
| 5   | deposit 1000   | 500                       | 0        | 1000       | **0** (lastSeen holds the cap)  |
| 5   | `sync()`       | **0** (backlog deleted)   | 1000     | 1000       | **0** (no jump)                 |
| 6   | time passes    | 100                       | 1000     | 1000       | 100                             |
| 7   | time passes    | 200                       | 1000     | 1000       | 200                             |

Inside one transaction, `sync` does two things in a fixed order:

1. It deletes the hidden 500 by restarting the curve at the visible amount.
2. It raises the cap.

When the cap goes up, there's nothing left behind it. The amount is **the same just before and just
after** a sync, and from then on it grows smoothly.

## Why not just call `writeCheckpoint`?

A checkpoint also restarts the curve, but always **from 0**. If 300 A were visible and on offer, a
checkpoint would wipe that out too. `sync` restarts from the **currently visible amount**, so it only
throws away what was hidden and never takes away what is already on offer. That is why anyone may call
`sync`, while `writeCheckpoint` needs a permission.

The scenario: the DAO holds **300 A** at the checkpoint, so `lastSeenBalance = 300`. By day 5 the
stream has accrued 500, but only 300 is visible: the other 200 is hidden behind `lastSeen`. Then 1000 A
is deposited.

**With `sync()`: the 300 stays on offer.**

| day | event          | accrued                       | lastSeen | daoBalance | available                              |
| --- | -------------- | ----------------------------- | -------- | ---------- | -------------------------------------- |
| 0   | checkpoint     | 0                             | 300      | 300        | 0                                      |
| 3   | time passes    | 300                           | 300      | 300        | 300                                    |
| 5   | time passes    | 500                           | 300      | 300        | 300 (200 hidden)                       |
| 5   | deposit 1000   | 500                           | 300      | 1300       | 300 (lastSeen holds the cap)           |
| 5   | `sync()`       | **300** (restarts at visible) | 1300     | 1300       | **300** (hidden 200 deleted, 300 kept) |
| 6   | time passes    | 400                           | 1300     | 1300       | 400                                    |
| 7   | time passes    | 500                           | 1300     | 1300       | 500                                    |

In the sync step, `_amount = min(500, 300, 1300) = 300`, which is less than `accrued = 500`, so the curve
restarts with `baseAmount = 300`. Only the hidden 200 is gone.

**With `writeCheckpoint()` instead: the 300 is wiped out.**

| day | event               | accrued                | lastSeen | daoBalance | available             |
| --- | ------------------- | ---------------------- | -------- | ---------- | --------------------- |
| 5   | deposit 1000        | 500                    | 300      | 1300       | 300                   |
| 5   | `writeCheckpoint()` | **0** (always from 0)  | 1300     | 1300       | **0** (300 lost)      |
| 6   | time passes         | 100                    | 1300     | 1300       | 100                   |
| 7   | time passes         | 200                    | 1300     | 1300       | 200                   |

The checkpoint sets `baseAmount = 0`, so the 300 already on offer disappears, and the auction has to
climb back up from nothing: on day 7 it is at 200 instead of 500. If anyone could call it, they could
keep resetting the auction and stop it from ever reaching a fair price. So only `sync` is
permissionless, because it never lowers what is already on offer.

> **In one sentence:** `lastSeenBalance` stops a deposit from causing a jump, and `sync` is the only safe
> way to let the deposit in, because it deletes the hidden growth before it lifts the cap.
