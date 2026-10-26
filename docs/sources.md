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

`context-audit` is not in devkit. Its origin is not known.

## Other repos read for comparison

Phase 1 step 4 compares the commands in TheSommelier, HomeLab, and
Monitoring with the Registry versions. These repos are not frozen. When step
4 reads a repo, it adds the SHA that it read here.
