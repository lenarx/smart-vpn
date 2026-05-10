## Notion Integration

This project is wired into the [`claude-notion-pipeline`] — a cron orchestrator that picks tasks from a shared Notion database and walks them through automated planning → human review → implementation → merge.

- **Project Slug**: `smart-vpn`  ← value of the Notion `Project` select on tasks belonging to this repo
- **Pipeline statuses (happy path)**:
  `Draft → To Do → Planning → Plan Ready → Plan Approved → In Progress → In Review → Done`
- **Revision loops**:
  - `Plan Ready → Plan Revision → Planning → Plan Ready` — request changes to a plan
  - `In Review → Changes Requested → In Progress → In Review` — request changes to a PR
- `Blocked` is a parking lot, can be entered from any active stage.

### Who moves the status

| Transition | Mover |
| --- | --- |
| Draft → To Do | human (Notion UI) |
| To Do → Planning | orchestrator (claims the task) |
| Planning → Plan Ready | Claude (`/plan-task` finishes) |
| Plan Ready → Plan Approved | human (after reviewing the plan) |
| **Plan Ready → Plan Revision** | human (after leaving Notion comments asking for changes) |
| **Plan Revision → Planning** | orchestrator (claims for re-plan) |
| Plan Approved → In Progress | orchestrator (claims the task) |
| In Progress → In Review | Claude (`/work-task` finishes, PR opened) |
| **In Review → Changes Requested** | human (after leaving PR comments asking for changes) |
| **Changes Requested → In Progress** | orchestrator (claims for re-work) |
| In Review → Done | orchestrator (detects merged PR) |
| any → Blocked | Claude / orchestrator on failure |

### Pipeline commands

User-level (`~/.claude/commands/`): `plan-task`, `work-task`, `submit-task`, `complete-task`, `pick-task`, `fix-bug`.

The orchestrator only invokes `plan-task` and `work-task`. The rest are manual helpers for interactive Claude Code use.

### Plan format

The plan lives in the page body under the `## 📋 План реализации` heading.

- If you want to **edit the plan yourself**: just edit it inline in `Plan Ready`, then move to `Plan Approved`. Claude will use the latest version when work begins.
- If you want **Claude to revise**: leave Notion comments on the parts you want changed (use the comment sidebar or inline thread on a specific block), then move the task `Plan Ready → Plan Revision`. Next orchestrator cycle, Claude reads the comments, writes a new revision (the previous version goes into a collapsible `<details>` block under "История планов"), and lands the task back in `Plan Ready`.

### Code-review loop

Same idea on the implementation side. Leave PR review comments on GitHub. To ask Claude to address them, move the task `In Review → Changes Requested`. The orchestrator will run `/work-task` again; Claude pulls the branch, reads the review comments via `gh`, addresses them with additional commits on the same branch (no force-push, no new PR), and lands the task back in `In Review`. Claude does NOT post replies on review threads — the new commits are the signal.
