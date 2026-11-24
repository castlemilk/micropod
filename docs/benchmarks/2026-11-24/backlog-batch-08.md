# Micropod host-published TCP · Batch 8 in progress

24 November 2026 · 1 of 10 comparisons recorded. Seven earlier batches contain 70 comparisons. The cumulative count is 71 across 37 registered directions. [Previous batch](backlog-batch-07.md)

| # | Direction | Evidence tier | Comparison and verdict | Evidence |
| ---: | --- | --- | --- | --- |
| 1 | 231.08 | Source/fixture | Single-buffer dispatch versus Linux single-queue bulk dequeue. Grouping nine 63 KiB buffers cut modeled notifications from nine to one at identical admission and charge. The live queue still needs a receiver and latency measurement. | [Local receipt](batch08-qdisc/qdisc-bulk.receipt.md) · [Issue](https://github.com/castlemilk/micropod/issues/231#issuecomment-7120487723) |
