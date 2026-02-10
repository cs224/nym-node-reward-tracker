# Notebook tests

Lightweight tests that avoid network calls.


```python
#| hide
from nym_node_reward_tracker.cli import build_parser
```


```python
parser = build_parser()
assert parser is not None
assert parser.prog
```
