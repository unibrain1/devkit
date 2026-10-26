# Registry agent rules removed from the flow agents

The 13 Registry agents in `.claude/agents/` (snapshot at commit 9c7a293) now
exist as generic agents in `plugins/flow/agents/`. The generic agents have no
PHP, UserSpice, or Registry rules. This file lists each rule that was removed,
grouped by agent. In phase 2 of the Registry migration, move these rules into
Registry `.claude/rules/` files. Each generic agent reads CLAUDE.md, the
`standards` files, and `.claude/rules/`, so the rules keep their effect after
the move. Then delete the Registry copies of the agents.

## Shared (in 9 agents)

The "UserSpice Prompts" block was in these 9 agents: code-reviewer,
code-simplifier, security-reviewer, senior-architect, senior-test-engineer,
silent-failure-hunter, software-developer, technical-documentation-writer, and
type-design-analyzer. Its text:

- Before UserSpice work, read `usersc/plugins/ai_prompts/prompts/00_start_here.md.php`.
- Then read the ElanRegistry overrides in
  `usersc/plugins/ai_prompts/custom_prompts/`: `elanregistry_overrides`,
  `elanregistry_classes`, `elanregistry_directories`, and
  `elanregistry_database`.
- Where two rules conflict, the overrides win.
- Use `ElanRegistry\Input::raw()` for values bound for the database. Never use
  `\Input::get()` for those values. It pre-encodes the value and causes double
  encoding.
- The documentation writer must document this rule correctly.

Suggested home: one rule file, for example `.claude/rules/userspice.md`.

## code-reviewer

- Authority sources: `CLAUDE.md`, `docs/development/CODING_STANDARDS.md`
  (PHP 8+ rules, type hints, `declare(strict_types=1)`, naming, organization,
  PHPDoc), and `docs/development/ERROR_HANDLING.md` (typed exceptions,
  ApiResponse, LogCategories, Pattern A AJAX response format).
- Project guideline checks:
  - PHP 8+ type hints on all parameters and return types.
  - `declare(strict_types=1)` in new PHP files.
  - PHPDoc on public methods (`@param`, `@return`, `@throws`).
  - Typed exceptions instead of generic `Exception`.
  - `ElanRegistryAPI` client for new AJAX endpoints.
  - Validated server globals (`$scheme`, `$is_https`, `$host`, and so on)
    instead of raw `$_SERVER`.
  - `securePage($php_self)` check on protected pages.
  - Update the `$path` array in `/z_us_root.php` for new PHP directories only
    when they contain files that call `securePage()`. Pure API endpoints and
    action handlers without `securePage()` (for example `app/api/cars/` and
    `app/api/shared/`) are left out on purpose.
  - Use `(new Owner($userId))->data()` for combined user and profile data.
- Code quality: check the Owner and User terminology boundary (`users` table
  for auth context, `owners` for the car registry domain).
- Static tools that already run in CI: PHPStan, ESLint, CodeQL, Semgrep.
- Overlap note: senior-architect reviews apply to Large-tier issues only (see
  `.claude/commands/start-issue.md`).
- PHP-specific path in the output format (`path/to/file.php:42`).
- UserSpice prompts block (see Shared).

## code-simplifier

- Role text: Elan Registry PHP / UserSpice 6 application.
- Follow `docs/development/CODING_STANDARDS.md`:
  - PHP 8+ type hints on all parameters and return types.
  - `declare(strict_types=1)` in new files.
  - Constructor promotion where it shortens the class.
  - Readonly properties for value objects.
  - Typed exception classes over generic `\Exception`.
  - `ApiResponse::success/error` for AJAX endpoints (Pattern A).
  - Validated server globals instead of raw `$_SERVER`.
- Prefer `match` over nested ternaries (PHP `match`).
- Do not cross the Users versus Owners terminology boundary.
- Verify with `composer test:quick` and the relevant Playwright suite.
- Leave alone: UserSpice framework files under `/users/`, and `vendor/`.
- UserSpice prompts block (see Shared).

## comment-analyzer

- Role text: Elan Registry PHP / UserSpice 6 application.
- `docs/development/CODING_STANDARDS.md` PHPDoc rules:
  - Public methods require `@param`, `@return`, and `@throws` tags.
  - Types in PHPDoc must match the PHP 8+ type hints on the signature.
  - Complex business logic (ownership transfers, auth flows) needs
    explanatory comments.
  - TODO and FIXME comments should reference a GitHub issue number.
  - `docs/development/*.md` files are the source of truth for architecture.
    Comments should not duplicate them, but may cross-reference them.

## pr-test-analyzer

- Project test stack:
  - PHPUnit in `tests/` (`composer test:quick`, `composer test:medium`,
    `composer test:full`).
  - Playwright browser and E2E tests (`npm run playwright:test`,
    `npm run test:e2e:test`).
  - ESLint for static JS checks, PHPStan for static PHP analysis.
- Critical gaps: missing tests for new public methods on `Car`, `Owner`, and
  `ApiResponse`. Business branches: ownership transfers, payment, auth,
  permissions.
- Project-specific concerns:
  - AJAX endpoint tests must assert the response format
    (`{success, message, ...}`).
  - Form tests must exercise the CSRF token path.
  - DB change tests must cover audit-trail trigger behavior where relevant.
  - UI pages need Playwright coverage for the golden path and at least one
    edge case.
- Do not suggest tests for UserSpice framework behavior.

## security-reviewer

- Role text: PHP web application security specialist.
- UserSpice prompts block (see Shared).
- PHP and UserSpice versions of the generic checks:
  - SQL: use `$db->query()` with bound parameters. Examples used `cars` table
    and `$_GET`, `$_POST`, `$_REQUEST`.
  - XSS: use `htmlspecialchars()` with `ENT_QUOTES` for HTML context.
  - CSRF: UserSpice `Token::generate()` and `Token::check()`.
  - Input: PHP type hints, `filter_input()`, `filter_var()`.
  - Auth: `securePage($php_self)` on protected pages. Session handling follows
    UserSpice patterns.
  - Passwords are handled by UserSpice (bcrypt hashing).
- Category 7, Server Globals: no direct `$_SERVER` access. Use the validated
  globals `$scheme`, `$host`, `$is_https`, `$method`, `$request_uri`,
  `$current_url`, `$current_origin`, `$php_self`, `$remote_addr`, `$referer`,
  `$user_agent`.
- Category 8, AJAX Endpoints (Pattern A):
  - Return `ApiResponse::success()` and `ApiResponse::error()` format.
  - Check `$method === 'POST'` for state-changing operations.
  - CSRF token check on all POST requests.
  - No sensitive data in error responses.
- Category 10, Error Handling: typed exception classes, and `LogCategories`
  constants for logs.
- The generic agent keeps the other categories, and numbers them 1 to 9 (the
  server globals category is gone, so the later numbers moved up).

## senior-architect

- Role text: PHP web applications on the UserSpice framework.
- Principle 2: use the `ApiResponse` and typed exception patterns.
- Principle 4: PHP 8+ type declarations, strict typing, PHPDoc.
- The "Project Context" block (Lotus Elan Registry, elanregistry.org):
  - PHP 8.2+ with `declare(strict_types=1)` in new files.
  - MySQL 8.0+ with audit trail tables (`*_hist`).
  - UserSpice handles auth. Custom classes are in `/usersc/classes/`.
  - Use `securePage()` for page protection.
  - Use `(new Owner($userId))->data()` for owner data access.
    `getUserWithProfile()` was removed in v2.26.2.
  - Use `ElanRegistryAPI` (fetch-based) for new AJAX endpoints, with the
    Pattern A response format.
  - Use `LogCategories` constants for all logging.
  - "Owner" terminology in UI and domain code, "User" in auth and UserSpice
    code.
  - Server environment globals (`$scheme`, `$host`, and so on) instead of raw
    `$_SERVER`.
- UserSpice prompts block (see Shared).
- Review checks:
  - Find duplicated UserSpice functionality, and code that the PHP standard
    library or MySQL already provides.
  - Do not flag typed exceptions, `ApiResponse`, `LogCategories`, validation,
    and tests as over-engineering.
  - New pages use `securePage()` and are registered in UserSpice.
- Design checks:
  - Check UserSpice first. It provides authentication, permissions, database
    operations, input handling, session management, CSRF protection, email,
    and validation.
  - Follow existing patterns (`Car` class, `Owner` class conventions).
  - Design APIs with the Pattern A response format.
  - Recommend schema changes with migration scripts that use the FIX script
    pattern.
- Output: always recommend running `composer test:quick`.
- GDPR wording in the description and principles became "privacy (for example
  GDPR)". The GDPR checks stay in the agent.

## senior-product-manager

- Role text: web applications for niche community platforms.
- Principle 5: "For a car registry handling owner data, security and GDPR
  compliance are non-negotiable."
- Project context: Lotus Elan Registry (elanregistry.org), PHP on UserSpice.
  Users are Lotus Elan car owners who:
  - register and document their cars (chassis numbers, specifications,
    history),
  - transfer ownership when cars are sold,
  - research car history and provenance,
  - connect with other owners,
  - use documentation and resources (paint colors, technical specs, FAQs).
- Domain concepts:
  - Owners (users with accounts and profiles).
  - Cars (chassis numbers, model years, specifications).
  - Transfers (ownership changes that need validation and approval).
  - Chassis validation (authentic, correctly formatted chassis numbers).
  - Paint colors (historical accuracy for restoration).
  - Documentation system (Markdown FAQ and technical docs).
- Development context:
  - Open milestones come from `gh api repos/elan-registry/registry/milestones`.
  - `/plan-milestone` seals the issue list. Work outside it goes to a later
    milestone, or to a patch release from `main` when production is broken
    (`.claude/commands/found.md`).
- Label command `gh label list -R elan-registry/registry`, and the label
  families:
  - Type: `bug`, `enhancement`, `refactor`, `tech-debt`.
  - Area: `component: *` (for example `component: security`,
    `component: ui`).
  - Signal and status: `signal: *`, `status: *`, `triage`, `gate-critical`.
- Registry-domain examples in acceptance criteria, decomposition, and
  interview questions (CSV export of a car's maintenance history, paint color
  FAQ page, transfer request form with chassis validation, "all car models or
  specific ones", "archived/sold cars", invalid chassis number, "Improve car
  search", overlap with issue about paint colors). The generic agent has
  neutral examples.
- Decision framework 1 named CSRF and SQL injection. The generic text says
  "attack prevention (for example CSRF and injection)".
- Dependency list: "Framework upgrades (UserSpice updates)".
- Strategic alignment example: "historical accuracy".

## senior-test-engineer

- Role text: specialist in PHP/PHPUnit and JavaScript/Playwright.
- Core expertise:
  - PHPUnit: unit, integration, regression, mocking, data providers,
    fixtures, coverage.
  - Playwright: end-to-end, security, UI consistency, navigation, CSP tests.
  - PHP 8+ testing patterns: strict typing in tests, typed exceptions, null
    safety.
- Project-specific context:
  - PHP commands: `composer test:quick` (unit), `composer test:medium`
    (unit and integration), `composer test:full` (all), `composer
    test:coverage`.
  - Playwright commands: `npm run playwright:test`, plus the suites
    `:security`, `:ui`, `:navigation`, `:functionality`, `:maps`, `:csp`.
  - Test locations: `/tests/` with PHPUnit and Playwright subdirectories.
  - Testing documentation: `docs/testing/TESTING.md`.
- UserSpice prompts block (see Shared).
- Anti-pattern evidence and details:
  - "A test that cannot fail": see `.claude/rules/playwright-tests.md`, issues
    #1949 and #1950, and the empty-loop case in issue #2189.
  - "Coupled to the implementation": a live test database is the right check
    for SQL, triggers, and `*_hist` audit rows.
  - Tautological example used PHPUnit `assertSame(array_sum($prices),
    $cart->total())`.
- PHPUnit writing rules:
  - `declare(strict_types=1)`.
  - Test names `test_methodName_condition_expectedResult()`.
  - Use data providers.
  - Verify audit logging where applicable.
- Playwright writing rules: page objects, CSRF and security header checks,
  responsive checks, selectors (data-testid, role, text).
- Quality standard: run `composer test:quick` for fast feedback.

## senior-ux-designer

- Role text: PHP/Bootstrap 5 web application for a community of classic car
  enthusiasts.
- Principle 3 examples: "Update Car" over "Edit", "Contact Owner" over "Send
  Message".
- Project context:
  - Audience: two personas. Owners (registered members who manage their cars)
    and Enthusiasts (logged-in or guest visitors who browse the registry).
  - Template: Bootstrap 5.3.8, self-hosted. jQuery is available (UserSpice
    dependency). Font Awesome icons.
  - UI standards file `docs/development/UI_STANDARDS.md`: colour tokens
    (`--er-accent`, `--er-primary`), card hierarchy (`registry-card`,
    `card-header-er-primary`, `card-header-er-l2`), component patterns.
    Always read it before recommending new components.
  - Page types: public car listing (`app/owner/cars/index.php`), public car
    detail (`app/owner/cars/details.php`), owner account
    (`usersc/account.php`), car edit form (`app/owner/cars/edit.php`), admin
    pages (`app/admin/`).
  - Terminology: "Owner" in UI copy, "User" only in auth and system contexts.
- Section "Button Contexts — Car Hero Card": the hero card renders one of five
  contexts, chosen by the `switch` in `app/views/cars/_car_hero_actions.php`
  (read that file for the current button sets):

  | Context | User | Primary goal | Actions rendered |
  |---|---|---|---|
  | `owner_detail` | Owner viewing their car | Verify public display | Update Car |
  | `admin_detail` | Admin or editor viewing any car | Manage registry data | Admin Edit Car, Contact Owner |
  | `visitor_detail` | Logged-in enthusiast | Learn about / contact | Contact Owner |
  | `guest_detail` | Anonymous visitor | Browse | Log in to contact owner |
  | `owner_account` | Owner on their own account page | Manage their car | Update Car, View Details |

- Review checks: colour use against `--er-accent` and Bootstrap semantic
  colours. Mobile layout against Bootstrap grid breakpoints.
- Partials: `$context` string or `$options` array, and the `$showAdminButtons`
  versus `$isAdmin && $showButtons` example.
- New screens: use the card patterns in `docs/development/UI_STANDARDS.md`.
- Output: name the Bootstrap variant (`btn-primary`, `btn-outline-light`).

## silent-failure-hunter

- Role text: Elan Registry PHP / UserSpice 6 application.
- UserSpice prompts block (see Shared).
- Project-specific patterns (`docs/development/ERROR_HANDLING.md`):
  - Typed exception classes (project custom exceptions).
  - AJAX endpoints return `ApiResponse::error($message, $context)` in Pattern
    A format `{success: false, message, ...}`.
  - Log via UserSpice `logger()` with a `LogCategories` constant.
  - `logger($user_id, 'category', 'message')` must carry enough context (IDs,
    operation) to debug six months later.
- Handler checks: logging through `logger()` with the `LogCategories`
  constant. AJAX errors as `ApiResponse::error()`.
- Hidden-failure patterns: the PHP `@` error suppression operator. PDO calls
  without error checking (the project uses prepared statements, but verify).
- Catch rule named `\Throwable` and bare `\Exception`.
- Example output uses `ApiResponse`, `logger()`, and typed exceptions.

## software-developer

- Role text: PHP web applications. Principle 4 "PHP 8+ Strict Typing":
  `declare(strict_types=1)` in all new files, complete type hints, typed
  exceptions, PHPDoc on public methods.
- Project context (Lotus Elan Registry, elanregistry.org, UserSpice):
  - Authentication: `securePage($php_self)` on all protected pages.
  - Database: MySQL 8.0+, prepared statements only, audit trails via `*_hist`
    trigger tables.
  - Classes in `/usersc/classes/` (Car, CarView, Owner, ChassisValidator).
  - Owner data: `(new Owner($userId))->data()`. `getUserWithProfile()` was
    removed in v2.26.2. "Owner" in UI and domain, "User" in auth and
    framework code.
  - AJAX: Pattern A response format with the `ApiResponse` class. The frontend
    uses the `ElanRegistryAPI` client.
  - Error handling: typed exceptions, `LogCategories` constants, central
    `ApiResponse`. See `docs/development/ERROR_HANDLING.md`.
  - Server globals instead of raw `$_SERVER`: `$scheme`, `$host`, `$is_https`,
    `$method`, `$request_uri`, `$current_url`, `$current_origin`,
    `$php_self`, `$remote_addr`, `$referer`, `$user_agent`.
  - Logging: `logger()` with `LogCategories::LOG_CATEGORY_*` constants.
  - New directories: register in the `$path` array in `/z_us_root.php` only
    if the directory has files that call `securePage()`. API endpoints and
    action handlers without it (`app/api/cars/`, `app/api/shared/`) stay out.
- UserSpice framework section: check UserSpice before custom code. It
  provides authentication, permissions, database operations (`$db`), the
  `Input` class, sessions, CSRF protection, email, and validation. Never
  duplicate it.
- UserSpice prompts block (see Shared).
- Frontend conventions: Bootstrap for layout. DataTables for tables
  (`docs/development/DATATABLES.md`). `ElanRegistryAPI` (fetch-based) for all
  new AJAX calls. CDN assets per `docs/development/CSS_AND_ASSETS.md`. Prefer
  `ElanRegistryAPI` over `$.ajax()`.
- Solution ladder step 3: UserSpice (`users/helpers/`, `users/classes/`) and
  the `userspice-helper-lookup` skill. Required structure: `ElanRegistry\Input`
  and `ApiResponse`, `LogCategories`.
- Bug fix: example reproducers were a PHPUnit test, a `curl`, or a Playwright
  script.
- Coding standards list: add `declare(strict_types=1)`, replace raw `$_SERVER`
  with server globals, add try-catch around database operations.
- Database: `$db->query()`, `*_hist` tables and triggers, migration patterns in
  `docs/development/FIX_SCRIPTS.md`.
- AJAX endpoints: `ApiResponse::success()` and `ApiResponse::error()`,
  `$method === 'POST'`, `LogCategories`.
- Output: recommend `composer test:quick`.

## technical-documentation-writer

- UserSpice prompts block, in the "document correctly" wording (see Shared).
- Audience text: "Two mid-level software engineers" (team size is a project
  fact. The generic agent says "Mid-level software engineers").

## type-design-analyzer

- Role text: PHP class and type design for Elan Registry PHP / UserSpice 6.
- Scope: `/usersc/classes/` (Car, Owner, ApiResponse, exception classes).
- Reference `docs/development/CLASSES.md` for project type patterns.
- UserSpice prompts block (see Shared).
- PHP conventions:
  - `readonly` promoted properties for value objects (PHP 8.2+).
  - PHP 8+ constructor promotion check.
  - `enum` for closed sets of states.
  - Typed exceptions per `docs/development/ERROR_HANDLING.md`, not `\Exception`.
  - Keep UserSpice framework types as they are.
  - Respect the Users (auth context) versus Owners (car registry domain)
    terminology boundary.
- Usefulness: invariants aligned with ownership, registry state, and audit
  trail.
