# ``Log``

Store bounded, typed activity history shared by cooperating processes.

## Overview

The module is one in-process service over the local Persistence package. ``ActivityLog`` provides
asynchronous append, read, and Clear operations outside the caller's actor. Consumers own storage authorization,
namespace/schema stability, payload privacy, presentation, and change-notification transport.

Each ``ActivityEntry`` records identity, occurrence time, and increasing commit sequence. Retained history is
ordered by commit sequence, not occurrence time. The default retention is 500 entries (configurable from 1
through 500), with a 2 KiB encoded event limit and a 2 MiB Persistence envelope limit.

Operations acquire exclusive cross-process leases with approximately one second of cancellation-aware
contention retries. Generic operations propagate cancellation; cancellation after the final append check may
race with the atomic commit. Clear preserves the latest sequence and does not remove unrelated records.
Corrupt or unsupported history fails explicitly even on Clear; it is not silently replaced.

## Topics

### Activity history

- ``ActivityLog``
- ``ActivityEntry``
- ``ActivityLogError``
