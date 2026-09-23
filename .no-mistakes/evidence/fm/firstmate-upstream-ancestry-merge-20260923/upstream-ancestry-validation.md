# Upstream ancestry validation

Target: `9e2efd91c4c0ad43bb0e53ffb6e52bb222fc5c27`

## Merge topology

Command:

```text
git rev-list --parents -n 1 9e2efd91c4c0ad43bb0e53ffb6e52bb222fc5c27
```

Output:

```text
9e2efd91c4c0ad43bb0e53ffb6e52bb222fc5c27 0048023d79bdde4fb75d8e839b61289563443123 8c47279f54e379e8ffa86a8d3a5b568f23ccf281
```

The target is a genuine merge whose first parent is the fork reconciliation and whose second parent is upstream history.

## Reachability and retained fork history

Commands and outputs:

```text
$ git merge-base 9e2efd91c4c0ad43bb0e53ffb6e52bb222fc5c27 0048023d79bdde4fb75d8e839b61289563443123
0048023d79bdde4fb75d8e839b61289563443123

$ git merge-base 9e2efd91c4c0ad43bb0e53ffb6e52bb222fc5c27 8c47279f54e379e8ffa86a8d3a5b568f23ccf281
8c47279f54e379e8ffa86a8d3a5b568f23ccf281

$ git rev-list --left-right --count 0048023d79bdde4fb75d8e839b61289563443123...8c47279f54e379e8ffa86a8d3a5b568f23ccf281
22      69

$ git rev-list --left-right --count 9e2efd91c4c0ad43bb0e53ffb6e52bb222fc5c27...0048023d79bdde4fb75d8e839b61289563443123
70      0

$ git rev-list --left-right --count 9e2efd91c4c0ad43bb0e53ffb6e52bb222fc5c27...8c47279f54e379e8ffa86a8d3a5b568f23ccf281
23      0
```

These checks demonstrate that all commits from both parents are reachable from the target. The original comparison was 22 fork-only commits versus 69 missing upstream commits; after the merge, neither parent has commits missing from the target.

## Live upstream acceptance check

Command and output:

```text
$ git ls-remote https://github.com/kunchenguid/firstmate.git HEAD refs/heads/main
9296f9b9d2566797b9a9aecaa5956bb8e471d2cd  HEAD
9296f9b9d2566797b9a9aecaa5956bb8e471d2cd  refs/heads/main
```

GitHub's compare API reports that live upstream `9296f9b` is two commits ahead of the merge's upstream parent `8c47279`:

```json
{
  "status": "ahead",
  "ahead_by": 2,
  "behind_by": 0,
  "total_commits": 2,
  "commits": [
    {
      "sha": "7e0e60a26e719c5e1f007e5d6d103872011fe067",
      "date": "2026-09-23T10:28:33Z",
      "message": "fix(bin): prune a torn-down task's wake rows at teardown (#5390)"
    },
    {
      "sha": "9296f9b9d2566797b9a9aecaa5956bb8e471d2cd",
      "date": "2026-09-23T10:45:48Z",
      "message": "test: align portable test expectations with resolved host paths and fixture readiness (#5392)"
    }
  ]
}
```

Result: ancestry restoration and fork-history preservation are demonstrated, but the target does not include the current upstream tip and therefore does not yet satisfy the requirement to include the latest upstream changes.

## Focused behavior tests

The merge-conflict surfaces were exercised through their executable integration suites:

```text
bash tests/fm-bearings-board-render.test.sh  # exit 0
bash tests/fm-fleet-ledger.test.sh           # exit 0
bash tests/fm-pr-check-security.test.sh      # exit 0
bash tests/fm-wake-queue.test.sh             # exit 0
```

All four completed successfully.
