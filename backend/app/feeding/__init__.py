"""The generic feed architecture (docs/GENERIC-FEED-ARCHITECTURE.md).

Feed Product describes what can be fed. Feed Formula describes how a
farm-produced feed is intended to be made. Feed Batch describes what was
actually made. Feeding Program describes what an animal or group should
receive. Feeding Event describes what was actually fed. Five concepts,
five tables — never one — and no species anywhere in the code: a
program's applicability is configuration evaluated against the livestock
subject's current state.
"""
