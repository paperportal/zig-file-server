# Repository Guidelines
Always use Zig executable and standard libraries at `~/zig/zig`.

## Project Structure & Module Organization
TODO

## Build, Test, and Development Commands
- `~/zig/zig build`: Builds `ftp-server` application.
- `~/zig/zig build package`: Packages the `ftp-server` application to distributable papp package.

## Coding Style & Naming Conventions
Use Zig 0.16 APIs and keep code `~/zig/zig fmt` clean before opening a PR.
Follow existing naming:
- Types and public structs/enums: `UpperCamelCase` (for example `Session`, `TransferType`).
- Functions: `lowerCamelCase`, except functions that return a type (Zig) which use `PascalCase` (for example `parseCommand`, `Utf8Decoder`).
- File names: `lower_snake_case` (for example `mock_vfs.zig`).
- Keep modules focused by concern (`commands`, `control`, `transfer`, `replies`).
