# Proposals to the Goose language

Honk works within Goose as it is today. In a few places that takes a
workaround, and these three proposals would make those workarounds
unnecessary. Each states the problem, shows the workaround Honk uses now,
and proposes a change sized to fit Goose's existing design notes.

| Proposal | Removes from Honk | Related Goose notes |
|---|---|---|
| [Whether a field has a default](01-field-defaults.md) | The "zero means required" guess | `docs/design/const_for.md` §10, "Defaults and annotations" |
| [Field types and size parameters](02-field-types-and-sizes.md) | The dispatch-token trick and the capacity list for `u8[..N]` | `const_for.md` §10, "Declared field types"; spec §3.3 |
| [Generic workers and addressed replies](03-generic-workers-and-replies.md) | The app's one-line worker, and the C reply mailboxes | Spec Appendix B, item 9 |

They are drafts and have not been filed with the Goose project.
