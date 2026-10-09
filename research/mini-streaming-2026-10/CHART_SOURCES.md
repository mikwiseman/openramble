# Chart references

Inspected in the browser on 9 October 2026 on the Mac Mini.

## Anthropic

[Introducing Claude Sonnet 5](https://www.anthropic.com/news/claude-sonnet-5),
30 June 2026. The agentic-search figure plots pass rate against cost per task.
It labels effort levels beside points, keeps model colors consistent and
places the benchmark name above the plot. The cost axis explicitly says it
is logarithmic. Its broken vertical axis is visible. A caption discloses that
the pricing changed after the figure was made; the change log also records a
methodology correction. These qualifications belong with a figure, not in a
separate page that readers may never open.

## OpenAI

[Introducing GPT-5.4 mini and nano](https://openai.com/index/introducing-gpt-5-4-mini-and-nano/),
17 March 2026. The coding figures put quality versus latency beside quality
versus cost, using the same quality scale. Marker shapes supplement color.
Axis labels include seconds and dollars. The caption explicitly identifies
latency as an estimate from offline simulation and explains its ingredients.

## Application to OpenRamble

Use separate figures for Stop latency, complete-file speed and word errors.
Use identical scales within language/condition panels and start bar axes at
zero. Label seconds, milliseconds, GiB and WER explicitly. Keep a consistent
color for OpenRamble; show alternate worker counts as one comparable series.
Place p50/p95 definitions, sample count, machine, version and measurement
boundary on each figure. Use a quality-versus-speed plot only for measurements
with matched input and timing scope. Preserve the mixed-language failure and
show memory beside any concurrency gain. Do not reuse the vendors' scores,
logos or graph styling as an endorsement.

Reference screenshots are retained in the private review evidence, outside
the public source repository. The rendered source pages were inspected, not
inferred from search snippets.
