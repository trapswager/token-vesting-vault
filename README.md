# Token Vesting Vault

A Solidity vault contract for project teams to manage ERC-20 token vesting with cliff and linear unlock for beneficiaries.

## Vesting Table

Example: `total = 1,000,000`, `cliff = 200` seconds, `duration = 1,000` seconds after `start`.

| Time (`t`) | Vested Tokens | What Happens |
|---|---|---|
| `t < start + cliff` | `0` | Nothing unlocks during cliff |
| `t = start + 200` | `200,000` | Cliff ends, unlocked amount is available |
| `t = start + 500` | `500,000` | Linear unlock (`total * (t - start) / duration`) |
| `t >= start + duration` | `1,000,000` | All tokens are vested |

## How to Run Tests

Run tests and check coverage with Foundry:

```bash
forge test
forge coverage
