# Sources

devkit copies its first version from these repos. Each base SHA is the
`main` HEAD on GitHub when rollout phase 1 recorded it.

| Repo | Local path | Base SHA (`main`) | Commit date (UTC) | HEAD commit |
| --- | --- | --- | --- | --- |
| [elan-registry/registry](https://github.com/elan-registry/registry) | `~/Developer/Web/ElanRegistry/Registry` | [`9c7a2939c91b680b70d09f1dcb442405465129a1`](https://github.com/elan-registry/registry/commit/9c7a2939c91b680b70d09f1dcb442405465129a1) | 2026-10-26 19:27:45 | #2543, bump `claude-code-action` to 1.0.261 |
| [unibrain1/MyGunLog](https://github.com/unibrain1/MyGunLog) | `~/Developer/Web/MyGunLog` | [`320d01c981b567f4f8e0c862913ba5726b13f045`](https://github.com/unibrain1/MyGunLog/commit/320d01c981b567f4f8e0c862913ba5726b13f045) | 2026-10-26 19:36:37 | #647, dependency updates 2026-10-26 |

Both repos pin `anthropics/claude-code-action@16f9f71ab9c490faf367f94dd294897edc25be33`
(v1.0.261) at these SHAs.

## CI freeze

The freeze started on 2026-10-26, when this file recorded the base SHAs. It
ends when devkit tags `v0.1.0`.

During the freeze, make no changes in `.github/`, `.claude/`, or `scripts/`
in Registry and MyGunLog. Other work in those repos continues. See
[design section 10](design.html#rollout).

| Event | Date | Link |
| --- | --- | --- |
| Freeze start | 2026-10-26 | this file |
| Freeze end (`v0.1.0`) | unknown | — |

## Third-party and global sources

| Item | Source | License | How devkit uses it |
| --- | --- | --- | --- |
| `asd-ste100` skill | [danyuchn/asd-ste100-skill](https://github.com/danyuchn/asd-ste100-skill) at [`8da6b63`](https://github.com/danyuchn/asd-ste100-skill/commit/8da6b6340aa22faf46fd07db8efbdea010cd38d9) (2026-10-26). | MIT, © 2026 Dustin Yuchen Teng | Listed in `.claude-plugin/marketplace.json` with upstream as the source, pinned to this SHA. No copy in devkit. `upstream-sync.yml` opens a PR when upstream moves. |

Short parts of two flow agents are adapted from MIT-licensed projects. Each
agent file names its source next to the adapted text. They came to devkit
with the Registry agents.

| Item | Source | License | Where |
| --- | --- | --- | --- |
| Test-first steps, failing-command rule | [mattpocock/skills](https://github.com/mattpocock/skills) (`tdd`) | MIT | `plugins/flow/agents/senior-test-engineer.md`, `software-developer.md` |
| Implementation steps 4 and 5 | [DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail) | MIT | `plugins/flow/agents/software-developer.md` |

`context-audit` is not in devkit. Its origin is not known.

## Global agents

Phase 1 step 5 compared the five agents in `~/.claude/agents` with the flow
versions. The flow versions were more complete. Jim approved these global
lines on 2026-10-27:

| Agent | Lines merged into flow |
| --- | --- |
| `senior-architect` | Design: plan for testability, consider security early, document trade-offs. A "When You're Uncertain" section. |
| `senior-product-manager` | Call the architect also for dependency updates and configuration changes. |
| `senior-test-engineer` | Debug step: check test data setup and teardown. Quality: tests are maintainable and easy to understand. |
| `software-developer` | API: proper HTTP status codes, meaningful error messages. Database: consider performance. A "When You're Uncertain" section. |
| `technical-documentation-writer` | Process step: assess consolidation. |

The flow models stay as they are. The fixed label list, the word target,
and capital MUST/NEVER rules are not merged. Phase 3 deletes
`~/.claude/agents`.

## Other repos read for comparison

Phase 1 step 4 compared the commands in these repos with the flow commands.
These repos are not frozen.

| Repo | Read at | Note |
| --- | --- | --- |
| unibrain1/MyGunLog | `320d01c` (base SHA) | 7 commands |
| unibrain1/TheSommelier | local files, 2026-10-26 | 10 commands. Git-ignored since v3.1.1 (#102), so not in `main` (`c4292e4`). |
| unibrain1/HomeLab | `f90f4f0` | 4 commands |
| elan-registry/elan-registry-monitoring | `7b440bf` | 8 commands |

Jim approved three extras on 2026-10-26: merge only the reviewed head
(MyGunLog), delete the local issue branch after a squash merge (MyGunLog and
TheSommelier, a bug in the Registry original), and read back the milestone
state after the close (Monitoring).
