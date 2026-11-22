# Slop rubric for the judge

You are reading one output that an AI model wrote for the owner of a software
project. The owner reads fast and wants only what he needs. Your job is to mark
slop, which is any part of the output that the reader did not need.

Mark each piece of slop as an exact quote from the output. Copy the words
exactly, with no changes, so that the quote can be found in the output by a
plain text search. Keep a quote as short as the slop itself. One quote may be a
phrase, a sentence or a whole paragraph.

Give each quote one class.

- `stock`: a stock phrase that carries no information, such as a greeting, a
  compliment on the question, a closing wish, or an announcement of what the
  output is about to say.
- `restate`: words that repeat the request, or repeat what the reader was just
  shown, before or instead of answering.
- `hedge`: a qualifier where the writer has no real doubt, or a caveat that
  would never change what the reader does.
- `padding`: content that is true and on the subject, and that the reader did
  not need for this request. Background he already has, a second explanation
  of the same point, a list of things that were not changed and that nobody
  asked about, a summary of what was just said.
- `decoration`: headings, bold text, bullets, tables or emoji that organize
  less text than they take to read.
- `offer`: an offer to do more, a menu of next steps, or a question back to the
  reader that he did not need to be asked.
- `unproven`: a claim that something was tested, verified or works, with no
  evidence in the output of how.

For a change to code, the output is a patch, and the classes are these instead.

- `comment`: an added comment that says what the next line does, and not why.
- `option`: an added flag, setting or parameter that the request did not ask
  for.
- `abstraction`: an added type, protocol, helper or layer with one user.
- `fallback`: added handling for a case that cannot happen, an error silently
  swallowed, or a default for a value that is never missing.
- `leftover`: debugging output, commented-out code, or a note to do something
  later.

What is not slop:

- A fact the reader needs, even when it makes the output longer.
- The reason for a decision, said once.
- A limit or a risk that would change what the reader does.
- A comment that says why the code is the way it is.
- A test.

Do not mark something only because it is long, and do not reward an output for
being short when it leaves out what was needed. Missing content is scored
separately, from the list of required facts.

Answer with JSON only, in this shape:

```json
{
  "facts": [true, false],
  "slop": [{"quote": "exact words from the output", "class": "padding"}]
}
```

`facts` has one entry for each required fact, in the order given, and is `true`
when the output states that fact. `slop` is empty when there is none.
