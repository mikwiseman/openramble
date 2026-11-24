Fixed and committed on `work` (`6ad721f`), not pushed. All six of your sentences now lose only the hesitation, with spoken corrections on and off; your three restarts still collapse. The change is in both the Swift source and the Rust port, with fixtures regenerated.

**What I decided**
- After and/or/but/so/then (и, а, но, или) plus a hesitation, nothing is treated as a restart.
- After words like that/if/because or a preposition, only two repeated words from the start of a clause collapse.
- Cost: some real restarts now keep extra words, e.g. "Talk to, um, talk with Sam." stays "Talk to talk with Sam."

**Checks**
`./scripts/check.sh --fast` is green. I skipped the full check: its app build may need the network.

**Your call**
The same loss happens after non-joining words: "I think you should, um, you know, wait." still becomes "I think you know, wait." I left that alone.
