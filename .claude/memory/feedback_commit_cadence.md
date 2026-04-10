---
name: Commit in small, topical chunks as work progresses
description: Don't batch many unrelated changes into one session-end commit; commit each logical change when it's done
type: feedback
---

Commit and push small, topical changes as soon as each logical unit of work is complete — don't accumulate many unrelated changes across the session and commit them all at the end.

**Why:** Big end-of-session dumps force painful splitting later (backing up files, reverting pieces, re-applying, staging partial hunks). Small incremental commits give clean history, easy rollback, and natural checkpoints if something breaks.

**How to apply:**
- When a logical unit of work is done (a bug fix, a feature, a refactor, a config addition) and verified working, propose a commit right then — don't wait for the next topic to come up.
- If the user asks for several changes in one message, commit each one separately as it's finished rather than bundling them.
- A "logical unit" usually touches 1-5 files with a single clear purpose. If you can write a one-sentence commit subject that covers it honestly, it's a commit.
- Still ask before committing (per the existing project convention of only committing when explicitly asked) — but ask *at the natural completion point*, not hours later.
- For multi-repo changes (home-server + home-server-private), commit each repo as its piece completes; don't wait for the other.
