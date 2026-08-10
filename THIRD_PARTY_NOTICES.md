# Third-Party Notices

OwnFramework Loop is built on Claude Code (Anthropic), POSIX file
locking, and the Python standard library. It does not bundle or copy
any third-party source code.

## Architectural inspiration

The OwnFramework Loop architecture is inspired in part by the
**Finn-loop** project (MIT license), inspected at the upstream commit
`7941b62c946154d15c11b7f24931bb8b6e155f01`. The architectural
patterns (two-loop, exact-SHA review, work-packet binding) were
studied as references; no source code was reproduced.

Upstream MIT notice:

```text
MIT License

Copyright (c) 2024 finna

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

No source code from Finn-loop is reproduced in this repository. The
implementation, state machine, schemas, agents, hooks, and CLI are
written from the OwnFramework Loop design contract and do not copy
any upstream text or code.

## Standard library only

This plugin uses only the Python standard library (Python 3.12+).
It does not introduce any third-party Python package, npm dependency,
system service, or network dependency.

## Anthropic / Claude Code

OwnFramework Loop is built against the public Claude Code plugin API.
The Anthropic API and Claude Code are governed by their own terms.
