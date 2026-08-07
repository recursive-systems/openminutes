# Agent Skills for OpenMinutes

[`openminutes/`](openminutes/SKILL.md) teaches an AI assistant how to read
your OpenMinutes recordings: where the files are, what the frontmatter
means, and how to answer questions that span many meetings at once.

It follows the open [Agent Skills](https://agentskills.io) format, so it
works in any assistant that supports skills rather than only one.

## Installing

Copy the `openminutes` folder into wherever your assistant loads skills
from, then ask it something about your meetings. Consult your assistant's
own documentation for the location. The format is shared, the install path
is not.

## What it needs

Access to the folder OpenMinutes exports into. That is the one you chose
during onboarding: `iCloud Drive/OpenMinutes`, `On My iPhone/OpenMinutes`,
or a folder you picked yourself.

## The obvious question

OpenMinutes never uploads anything. It has no network code and no account,
and that does not change.

This skill is on the other side of that line, and deliberately so. It runs
in *your* assistant, on *your* files, when *you* ask it to. Whatever you
hand to an assistant goes wherever that assistant sends it, the same as any
other file you paste into a chat. OpenMinutes is not in that loop and never
sees it.

That is what owning the files is for. The app's job is to make sure nothing
moves without you; deciding what to do with your own notes is yours.

## What it is good at

Single recordings are easy: open the file. The reason this exists is the
questions that cross recordings, which no recording app can answer because
it only ever sees one at a time:

- What did I agree to in the last two weeks?
- Every time the migration came up, and what was said
- Which action items from last month are still open?

## Note on speaker labels

Speaker labelling is experimental in OpenMinutes and sometimes wrong. The
skill tells assistants to treat names as hints rather than facts and to cite
the line they drew a claim from. Keep that in mind before relying on who
said what.
