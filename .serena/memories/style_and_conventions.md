# Style and conventions
- Language/style: modern Swift with small focused types, `struct` for value models/views, `actor` for async service isolation, and `final class` for stateful reference types like the view model and support services.
- Naming: UpperCamelCase type names, lowerCamelCase members, clear service-oriented file names (`ClaudeUsageService`, `NotificationService`, etc.).
- Imports are explicit and minimal per file.
- Error handling prefers typed `UsageError` values with user-facing messages instead of generic strings bubbling up from call sites.
- Dependency injection is used heavily for testability through initializer parameters and closure typealiases (network clients, command runners, clocks, binary locators, writers).
- Comments are sparse and practical; avoid adding noisy comments.
- Tests use XCTest with descriptive test names (`testXyz...`) and lightweight fakes/closures instead of heavy mocking frameworks.
- No formatter or linter configuration is present in the repo (no SwiftFormat/SwiftLint config found). Match existing formatting and keep changes minimal and consistent with surrounding code.