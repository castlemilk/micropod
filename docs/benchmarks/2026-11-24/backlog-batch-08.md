# Micropod host-published TCP · Batch 8 in progress

24 November 2026 · 2 of 10 comparisons recorded. Seven earlier batches contain 70 comparisons. The cumulative count is 72 across 37 registered directions. [Previous batch](backlog-batch-07.md)

| # | Direction | Evidence tier | Comparison and verdict | Evidence |
| ---: | --- | --- | --- | --- |
| 1 | 231.08 | Source/fixture | Single-buffer dispatch versus Linux single-queue bulk dequeue. Grouping nine 63 KiB buffers cut modeled notifications from nine to one at identical admission and charge. The live queue still needs a receiver and latency measurement. | [Local receipt](batch08-qdisc/qdisc-bulk.receipt.md) · [Issue](https://github.com/castlemilk/micropod/issues/231#issuecomment-7120487723) |
| 2 | 231.08 | Source/fixture | Reducing initial fq credit from 15,140 to 3,028 bytes let a waiting short response follow two small bulk packets instead of ten. The new bulk flow finished eight places later. With 63 KiB bulk buffers the short response gained nothing. Keep stock pending a service-queue trace. | [Local receipt](batch08-initial-quantum/fq-initial.receipt.md) · [Issue](https://github.com/castlemilk/micropod/issues/231#issuecomment-7120803864) |
