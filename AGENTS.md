# Repository Guidelines
Always use Zig executable and standard libraries at `~/zig/zig`.

## Project Structure & Module Organization
TODO

## Build, Test, and Development Commands

Requires Zig `0.16.0-dev.2565+684032671` or newer (see `build.zig.zon`).

- `~/zig/zig build`: Builds the application.
- `~/zig/zig build package`: Packages the application to distributable papp package.

## Coding Style & Naming Conventions

- Follow Zig coding conventions and let `zig fmt` enforce formatting (no manual alignment/formatting rules).
- Naming: files/modules in `snake_case`, types in `PascalCase` (e.g. `StdFs`), functions/vars in `camelCase`.
- Namespaces: prefer to use explicit namespaces. Do not do for example `const Io = std.Io;`. Simplifying namespaces is allowed, for example `const httpd = @import("adapters/mini_httpd.zig");`.
- Document code using Zig doc comments: `//!` for file/module docs and `///` for public declarations. Prefer documenting externally visible behavior (limits, error cases, invariants) over implementation details.
- Keep source files small and focused. If new logic doesn’t clearly belong in the current file, create a new module and refactor accordingly.
- After making changes add an entry to CHANGELOG.md file that briefly describes the changes.
- Maintaining backwards compatibility is a non-goal. It is more important to keep code clean and understandable. However when making breaking changes you must clearly mark it in CHANGELOG.md.
