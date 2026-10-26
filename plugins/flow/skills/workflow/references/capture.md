# Capture

## 1. Capture

Never suppress a capture. The filter runs at planning.

`/flow:new-issue` captures one issue and stops.

- It searches for a duplicate.
- It records the issue.
- It does not write acceptance criteria, estimate size, run agents, or set a milestone.
- It does not offer `/flow:start-issue`. A captured issue has no milestone and cannot start.

Each issue gets one signal label:

| Label | Meaning | Weight at planning |
| --- | --- | --- |
| `signal:owner` | A named user asked: by email, contact form, or direct conversation | Strongest. A real person waits. |
| `signal:analytics` | Logs or usage data show a gap: failed searches, error rates, abandoned flows | Strong. Evidence without opinion. |
| `signal:operator` | Friction for the person who runs or edits the product | Weakest. Needs a second reason to exist. |
| `signal:defect` | Something is broken against its own stated behavior | Bypasses the theme test if a user can see it. |
| `signal:forced` | Security advisory, dependency end of life, platform change | Bypasses the theme test. Gets the housekeeping slot. |
| `signal:discovered` | Found while working another issue | Neutral. Must pass planning like any other issue. |

### The signal records origin, not every later measurement

- Set the label once, at capture. Use the origin of the idea.
- A later measurement corroborates or refutes the issue. It does not change the label.
- Record a corroborating measurement as a comment on the issue.
- Change a label in two cases only:
  1. A rescue. A new signal reopens the issue. The issue takes that signal's label.
  2. A mis-classification, proven by evidence. Not by impression.
- Never infer `signal:owner` or `signal:analytics`. Apply them only with a real message or a real measurement.
- For `signal:analytics`, the measurement must have produced the issue.
- `/flow:plan-milestone` flags a label that looks wrong. It does not relabel the issue.

### What an issue records at capture

`/flow:new-issue` records four things. It records nothing else.

- A title with a type prefix. A defect gets `bug:`. It has no acceptance criteria yet.
- One signal label. The issue also gets `triage`, and `bug` or `enhancement`.
- A one-line beneficiary. Example: "Customers who cannot export invoices cannot reconcile them."
- A verbatim quote or the evidence, if any. Paste the actual words, or the measurement or error.

If the user cannot name a beneficiary other than themselves, capture the issue anyway. It fails the gate later.

### The occasional contributor

A second contributor works a separate lane. This lane takes only issues labeled `help-wanted`.

- The lane has no plan gate.
- The user reviews each PR before merge.
- The lane never picks from the open milestone.
