# Cache history observer

The Cache pane optionally reads Cuttlefish's `cache-history-v1` endpoint at
`http://127.0.0.1:5555/cache/history?after=<sequence>&limit=128`. Older producers
can continue serving `/cache`; an unavailable history route remains unknown and
does not hide those independent measurements.

The reviewed producer contract is Cuttlefish #480 at
`8d19ab89904f7a7d1fe04a59bfddcfc8e73f948d`. This consumer is source qualification;
that producer's signed installed adoption and ordinary-attempt acceptance remain
separate gates.

## Bounded ingestion

Each page is limited to 128 KiB and 128 events. One visible refresh consumes at
most four pages, with the first response's `lastSequence` as its upper bound.
Writes beyond that sequence wait until another visible refresh. Page navigation
cancels the owning refresh task; no background history poller is created.

Only the v1 schema with `complete=false` and `leaseCoverage=unavailable` is
accepted. The consumer validates event kinds, identities, bounded attributed
facts, ordering and `nextAfter`. A failed schema/read/page retains earlier valid
observations with an explicit error. Empty pages never mean zero cache activity.
A changed history identity or cursor beyond the producer's sequence stages a
reset and fetch from zero; earlier observations remain until a valid replacement
page is consumed. Deduplication uses history identity and sequence. Reports still
join cache identity with runner identity, never a volume name across rigs.

Curated events and their cursor persist together in the observer file
`~/Library/Application Support/Micropod/cache-observations-v1.json`, limited to
2,048 events and 4 MiB encoded data. This is separate from the producer history
DB and cache volumes. Environment and unknown payload fields are neither decoded
nor retained. Invalid-measurement flags survive observer restarts. Unknown or
corrupt observer state is shown as unavailable and is not overwritten. Failed
writes leave cursor persistence unconfirmed.

## Coverage and retention

The UI shows source/history identity, consumed and producer sequences, producer
sessions, pending records, retained payload, eviction/loss counters, unpersisted
loss lower bounds, read time and coverage gaps. It distinguishes a limited
traversal and observer truncation from a fully consumed producer snapshot.
Restart, retention, failed-read and sequence gaps remain explicit. The producer
retains at most 2,048 events / 4 MiB payload; database overhead is additional and
there is no promise of multi-day coverage.

Persisted facts remain partial observations. Per-volume I/O, guest filesystem
used, compiler/package content hits, physical cache incarnation, unique or
reclaimable bytes, measured benefit and authoritative all-ingress leases remain
unknown. The local producer is not a confirmed join to the selected runtime or
inventory owner. Project filtering requires report attribution; an owner path
cannot substitute for a runner ID.

Incomplete cache-access history and unavailable authoritative lease coverage
always block retention qualification. This observer adds no prune, deletion,
compaction, mount, restart, threshold override or cache lifecycle API.

## Qualification

Fixture coverage includes exact JSON byte bounds, producer/observer restarts,
identity resets and failed reset fetches, fixed upper sequence, page budget,
empty pages, truncation/loss, invalid ordering, unknown schemas/state, quality
round trips, atomic cursor/fact persistence failures and off-page cancellation.
Native NSHostingView fixtures check 720/light and 1200/dark layouts. These are
synthetic renders, not acceptance of the installed desktop or a signed producer.
