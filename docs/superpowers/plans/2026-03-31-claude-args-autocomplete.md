# Claude CLI Args Autocomplete — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the plain text field for Claude CLI start parameters with a chip-based autocomplete field powered by `claude --help`.

**Architecture:** Two new files — `ClaudeCLIFlags.swift` (model + parser + singleton) and `ClaudeArgsField.swift` (custom NSView with chips, inline text field, and suggestion dropdown). Existing settings and per-session dialog swap in the new field. Fuse library (already a dependency) provides fuzzy matching.

**Tech Stack:** Swift, AppKit (NSView, NSTextField, NSWindow, NSTableView), Fuse (fuzzy search), Process (CLI invocation), XCTest

---

### Task 1: ClaudeFlag Model & Help Parser

**Files:**
- Create: `Sources/App/ClaudeCLIFlags.swift`
- Create: `Tests/ClaudeCLIFlagsTests.swift`

- [ ] **Step 1: Write failing tests for help output parsing**

Create `Tests/ClaudeCLIFlagsTests.swift`:

```swift
import XCTest
@testable import Deckard

final class ClaudeCLIFlagsTests: XCTestCase {

    // Sample help output (subset of real `claude --help`)
    private let sampleHelp = """
    Options:
      --add-dir <directories...>                        Additional directories to allow tool access to
      --verbose                                         Override verbose mode setting from config
      --permission-mode <mode>                          Permission mode to use for the session (choices: "acceptEdits", "bypassPermissions", "default", "dontAsk", "plan", "auto")
      --effort <level>                                  Effort level for the current session (low, medium, high, max)
      --model <model>                                   Model for the current session. Provide an alias for the latest model (e.g. 'sonnet' or 'opus') or a model's full name (e.g. 'claude-sonnet-4-6').
      -c, --continue                                    Continue the most recent conversation in the current directory
      -d, --debug [filter]                              Enable debug mode with optional category filtering (e.g., "api,hooks" or "!1p,!file")
      -p, --print                                       Print response and exit (useful for pipes).
      --allowedTools, --allowed-tools <tools...>        Comma or space-separated list of tool names to allow (e.g. "Bash(git:*) Edit")
      -v, --version                                     Output the version number
      -h, --help                                        Display help for command
      --resume [value]                                  Resume a conversation by session ID
    """

    func testParsesBooleanFlag() {
        let flags = ClaudeCLIFlags.parse(helpOutput: sampleHelp)
        let verbose = flags.first { $0.longName == "--verbose" }
        XCTAssertNotNil(verbose)
        XCTAssertEqual(verbose?.valueType, .boolean)
        XCTAssertNil(verbose?.shortName)
    }

    func testParsesFlagWithShortName() {
        let flags = ClaudeCLIFlags.parse(helpOutput: sampleHelp)
        let debug = flags.first { $0.longName == "--debug" }
        XCTAssertNotNil(debug)
        XCTAssertEqual(debug?.shortName, "-d")
    }

    func testParsesExplicitChoices() {
        let flags = ClaudeCLIFlags.parse(helpOutput: sampleHelp)
        let permMode = flags.first { $0.longName == "--permission-mode" }
        XCTAssertNotNil(permMode)
        guard case .enumeration(let values) = permMode?.valueType else {
            XCTFail("Expected enumeration"); return
        }
        XCTAssertEqual(values, ["acceptEdits", "bypassPermissions", "default", "dontAsk", "plan", "auto"])
    }

    func testParsesInformalEnum() {
        let flags = ClaudeCLIFlags.parse(helpOutput: sampleHelp)
        let effort = flags.first { $0.longName == "--effort" }
        XCTAssertNotNil(effort)
        guard case .enumeration(let values) = effort?.valueType else {
            XCTFail("Expected enumeration"); return
        }
        XCTAssertEqual(values, ["low", "medium", "high", "max"])
    }

    func testParsesFreeTextValue() {
        let flags = ClaudeCLIFlags.parse(helpOutput: sampleHelp)
        let model = flags.first { $0.longName == "--model" }
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.valueType, .freeText)
        XCTAssertEqual(model?.valuePlaceholder, "<model>")
    }

    func testBlocklistExcludesInternalFlags() {
        let flags = ClaudeCLIFlags.parse(helpOutput: sampleHelp)
        let longNames = flags.map(\.longName)
        XCTAssertFalse(longNames.contains("--continue"))
        XCTAssertFalse(longNames.contains("--print"))
        XCTAssertFalse(longNames.contains("--version"))
        XCTAssertFalse(longNames.contains("--help"))
        XCTAssertFalse(longNames.contains("--resume"))
    }

    func testParsesAliasedFlag() {
        let flags = ClaudeCLIFlags.parse(helpOutput: sampleHelp)
        // --allowedTools, --allowed-tools should produce one entry
        let allowed = flags.first { $0.longName == "--allowed-tools" }
        XCTAssertNotNil(allowed)
        XCTAssertEqual(allowed?.valueType, .freeText)
    }

    func testEmptyInputReturnsEmptyArray() {
        let flags = ClaudeCLIFlags.parse(helpOutput: "")
        XCTAssertTrue(flags.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard build 2>&1 | tail -5`
Expected: Build FAILS — `ClaudeCLIFlags` not defined.

- [ ] **Step 3: Implement ClaudeCLIFlags model and parser**

Create `Sources/App/ClaudeCLIFlags.swift`:

```swift
import Foundation

/// Represents a single CLI flag parsed from `claude --help`.
struct ClaudeFlag {
    let longName: String
    let shortName: String?
    let description: String
    let valueType: ValueType
    let valuePlaceholder: String?

    enum ValueType: Equatable {
        case boolean
        case freeText
        case enumeration([String])
    }
}

/// Parses and caches CLI flags from `claude --help`.
final class ClaudeCLIFlags {

    static let shared = ClaudeCLIFlags()

    /// Parsed flags. Empty until `load()` completes (or if claude is not installed).
    private(set) var flags: [ClaudeFlag] = []

    /// Flags Deckard manages internally — excluded from suggestions.
    static let blocklist: Set<String> = [
        "--resume", "--continue", "--fork-session", "--print", "--version", "--help",
        "--output-format", "--input-format", "--include-partial-messages",
        "--replay-user-messages", "--json-schema", "--max-budget-usd",
        "--no-session-persistence", "--fallback-model", "--from-pr", "--session-id",
    ]

    /// Run `claude --help` asynchronously and parse the output.
    func load() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let output = Self.runClaudeHelp() else { return }
            let parsed = Self.parse(helpOutput: output)
            DispatchQueue.main.async {
                self?.flags = parsed
            }
        }
    }

    /// Parse `claude --help` output into structured flags.
    static func parse(helpOutput: String) -> [ClaudeFlag] {
        // Matches lines like:
        //   --flag <value>        Description text
        //   -s, --flag <value>    Description text
        //   --aliasA, --aliasB <value>  Description text
        let pattern = #"^\s+(?:(-\w),\s+)?(?:--[\w-]+,\s+)*(--[\w-]+)(?:\s+[\[<]([^\]>]+)[\]>](?:\.{3})?)?\s{2,}(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else {
            return []
        }

        var results: [ClaudeFlag] = []
        let nsString = helpOutput as NSString

        regex.enumerateMatches(in: helpOutput, range: NSRange(location: 0, length: nsString.length)) { match, _, _ in
            guard let match else { return }

            let shortName = match.range(at: 1).location != NSNotFound
                ? nsString.substring(with: match.range(at: 1)) : nil
            let longName = nsString.substring(with: match.range(at: 2))
            let placeholder = match.range(at: 3).location != NSNotFound
                ? nsString.substring(with: match.range(at: 3)) : nil
            let desc = nsString.substring(with: match.range(at: 4))
                // Collapse multi-space runs from column alignment
                .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)

            // Skip blocklisted flags
            if blocklist.contains(longName) { return }

            let valueType = Self.determineValueType(placeholder: placeholder, description: desc)

            results.append(ClaudeFlag(
                longName: longName,
                shortName: shortName,
                description: desc,
                valueType: valueType,
                valuePlaceholder: placeholder.map { "<\($0)>" }
            ))
        }

        return results
    }

    /// Determine the value type from the placeholder and description.
    private static func determineValueType(placeholder: String?, description: String) -> ClaudeFlag.ValueType {
        guard placeholder != nil else { return .boolean }

        // Explicit choices: (choices: "a", "b", "c")
        if let choicesMatch = description.range(of: #"\(choices:\s*(.+?)\)"#, options: .regularExpression) {
            let choicesStr = String(description[choicesMatch])
            // Extract quoted values
            let quotedPattern = #""([^"]+)""#
            if let quotedRegex = try? NSRegularExpression(pattern: quotedPattern) {
                let nsStr = choicesStr as NSString
                let matches = quotedRegex.matches(in: choicesStr, range: NSRange(location: 0, length: nsStr.length))
                let values = matches.map { nsStr.substring(with: $0.range(at: 1)) }
                if !values.isEmpty {
                    return .enumeration(values)
                }
            }
        }

        // Informal enum: description ends with (word, word, word)
        // Heuristic: parenthesized list at end, 2-8 items, each ≤20 chars, no spaces within items
        if let informalMatch = description.range(of: #"\(([a-zA-Z][\w-]{0,19}(?:,\s*[a-zA-Z][\w-]{0,19}){1,7})\)\s*$"#, options: .regularExpression) {
            let inner = description[informalMatch]
                .dropFirst().dropLast() // remove ( and )
                .trimmingCharacters(in: .whitespace)
            let items = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespace) }
            if items.count >= 2 && items.count <= 8 && items.allSatisfy({ !$0.contains(" ") && $0.count <= 20 }) {
                return .enumeration(items)
            }
        }

        return .freeText
    }

    /// Run `claude --help` and return its stdout, or nil on failure.
    private static func runClaudeHelp() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "--help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // discard stderr
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
```

- [ ] **Step 4: Build and run tests to verify they pass**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Sources/App/ClaudeCLIFlags.swift Tests/ClaudeCLIFlagsTests.swift
git commit -m "feat: add ClaudeFlag model and help output parser"
```

---

### Task 2: Args String Serialization (Round-Trip)

**Files:**
- Modify: `Sources/App/ClaudeCLIFlags.swift`
- Modify: `Tests/ClaudeCLIFlagsTests.swift`

- [ ] **Step 1: Write failing tests for serialization**

Add to `Tests/ClaudeCLIFlagsTests.swift`:

```swift
final class ArgsSerializationTests: XCTestCase {

    func testSerializeChipsToString() {
        let chips = [
            ArgsChip(flag: "--permission-mode", value: "auto"),
            ArgsChip(flag: "--verbose", value: nil),
            ArgsChip(flag: "--model", value: "sonnet"),
        ]
        let result = ArgsChip.serialize(chips)
        XCTAssertEqual(result, "--permission-mode auto --verbose --model sonnet")
    }

    func testDeserializeStringToChips() {
        let input = "--permission-mode auto --verbose --model sonnet"
        let flags = ClaudeCLIFlags.parse(helpOutput: """
          --permission-mode <mode>   Permission mode (choices: "auto", "default")
          --verbose                  Verbose
          --model <model>            Model
        """)
        let chips = ArgsChip.deserialize(input, knownFlags: flags)
        XCTAssertEqual(chips.count, 3)
        XCTAssertEqual(chips[0].flag, "--permission-mode")
        XCTAssertEqual(chips[0].value, "auto")
        XCTAssertEqual(chips[1].flag, "--verbose")
        XCTAssertNil(chips[1].value)
        XCTAssertEqual(chips[2].flag, "--model")
        XCTAssertEqual(chips[2].value, "sonnet")
    }

    func testDeserializeUnknownFlags() {
        let input = "--unknown-flag some-value --verbose"
        let flags = ClaudeCLIFlags.parse(helpOutput: """
          --verbose   Verbose
        """)
        let chips = ArgsChip.deserialize(input, knownFlags: flags)
        XCTAssertEqual(chips.count, 2)
        XCTAssertEqual(chips[0].flag, "--unknown-flag")
        XCTAssertEqual(chips[0].value, "some-value")
        XCTAssertEqual(chips[1].flag, "--verbose")
    }

    func testRoundTrip() {
        let original = "--permission-mode auto --verbose"
        let flags = ClaudeCLIFlags.parse(helpOutput: """
          --permission-mode <mode>   Permission mode (choices: "auto", "default")
          --verbose                  Verbose
        """)
        let chips = ArgsChip.deserialize(original, knownFlags: flags)
        let serialized = ArgsChip.serialize(chips)
        XCTAssertEqual(serialized, original)
    }

    func testDeserializeEmptyString() {
        let chips = ArgsChip.deserialize("", knownFlags: [])
        XCTAssertTrue(chips.isEmpty)
    }
}
```

- [ ] **Step 2: Run build to verify it fails**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard build 2>&1 | tail -5`
Expected: Build FAILS — `ArgsChip` not defined.

- [ ] **Step 3: Implement ArgsChip**

Add to `Sources/App/ClaudeCLIFlags.swift`:

```swift
/// A single chip representing one CLI argument (flag + optional value).
struct ArgsChip: Equatable {
    let flag: String     // e.g. "--permission-mode"
    let value: String?   // e.g. "auto", nil for boolean flags

    /// Join chips into a CLI argument string.
    static func serialize(_ chips: [ArgsChip]) -> String {
        chips.map { chip in
            if let value = chip.value {
                return "\(chip.flag) \(value)"
            }
            return chip.flag
        }.joined(separator: " ")
    }

    /// Parse a CLI argument string into chips, using known flags to determine
    /// which flags take values. Unknown flags are assumed to take a value if
    /// the next token doesn't start with "-".
    static func deserialize(_ string: String, knownFlags: [ClaudeFlag]) -> [ArgsChip] {
        let tokens = string.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !tokens.isEmpty else { return [] }

        let flagMap = Dictionary(uniqueKeysWithValues: knownFlags.map { ($0.longName, $0) })
        var chips: [ArgsChip] = []
        var i = 0

        while i < tokens.count {
            let token = tokens[i]
            guard token.hasPrefix("-") else {
                // Bare value without a flag — skip (shouldn't happen in well-formed input)
                i += 1
                continue
            }

            if let known = flagMap[token] {
                switch known.valueType {
                case .boolean:
                    chips.append(ArgsChip(flag: token, value: nil))
                    i += 1
                case .freeText, .enumeration:
                    let value = (i + 1 < tokens.count && !tokens[i + 1].hasPrefix("-"))
                        ? tokens[i + 1] : nil
                    chips.append(ArgsChip(flag: token, value: value))
                    i += (value != nil ? 2 : 1)
                }
            } else {
                // Unknown flag — assume it takes a value if next token doesn't start with "-"
                let value = (i + 1 < tokens.count && !tokens[i + 1].hasPrefix("-"))
                    ? tokens[i + 1] : nil
                chips.append(ArgsChip(flag: token, value: value))
                i += (value != nil ? 2 : 1)
            }
        }

        return chips
    }
}
```

- [ ] **Step 4: Build to verify tests pass**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Sources/App/ClaudeCLIFlags.swift Tests/ClaudeCLIFlagsTests.swift
git commit -m "feat: add ArgsChip serialization and deserialization"
```

---

### Task 3: Startup Loading in AppDelegate

**Files:**
- Modify: `Sources/App/AppDelegate.swift:61` (after hooks install)

- [ ] **Step 1: Add load call after hooks installation**

In `Sources/App/AppDelegate.swift`, after line 61 (`DeckardHooksInstaller.installIfNeeded()`), add:

```swift
        // Parse Claude CLI flags for autocomplete in settings.
        log.log("startup", "Loading Claude CLI flags...")
        ClaudeCLIFlags.shared.load()
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/App/AppDelegate.swift
git commit -m "feat: load Claude CLI flags at startup for autocomplete"
```

---

### Task 4: ClaudeArgsField — Chip Layout & Inline Text Field

**Files:**
- Create: `Sources/Window/ClaudeArgsField.swift`

This task builds the core view: the container with chips and an inline text field. No dropdown yet.

- [ ] **Step 1: Create ClaudeArgsField with chip rendering and text input**

Create `Sources/Window/ClaudeArgsField.swift`:

```swift
import AppKit

/// A chip-based text field for entering Claude CLI arguments with autocomplete.
///
/// Displays accepted arguments as chips (small rounded tags) and provides an
/// inline text field for typing new arguments. Backed by a plain string in
/// UserDefaults for backward compatibility.
final class ClaudeArgsField: NSView {

    /// Called whenever the argument string changes.
    var onChange: ((String) -> Void)?

    private var chips: [ArgsChip] = []
    private let chipContainer = NSView()
    private let textField = NSTextField()
    private var chipViews: [NSView] = []
    private var selectedChipIndex: Int?
    /// When non-nil, the user has selected a valued flag and is now typing its value.
    private var pendingFlag: ClaudeFlag?

    /// The current argument string.
    var stringValue: String {
        get { ArgsChip.serialize(chips) }
        set { loadChips(from: newValue) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        updateBorderColor()

        chipContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chipContainer)

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textField.focusRingType = .none
        textField.placeholderString = "Type a flag name..."
        textField.delegate = self
        textField.cell?.sendsActionOnEndEditing = false
        addSubview(textField)

        NSLayoutConstraint.activate([
            chipContainer.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            chipContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            chipContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),

            textField.topAnchor.constraint(equalTo: chipContainer.bottomAnchor, constant: 2),
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            textField.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    // MARK: - Chip Management

    private func loadChips(from string: String) {
        chips = ArgsChip.deserialize(string, knownFlags: ClaudeCLIFlags.shared.flags)
        rebuildChipViews()
    }

    func addChip(_ chip: ArgsChip) {
        chips.append(chip)
        rebuildChipViews()
        onChange?(stringValue)
    }

    private func removeChip(at index: Int) {
        guard index >= 0 && index < chips.count else { return }
        chips.remove(at: index)
        selectedChipIndex = nil
        rebuildChipViews()
        onChange?(stringValue)
    }

    private func rebuildChipViews() {
        chipViews.forEach { $0.removeFromSuperview() }
        chipViews.removeAll()

        // Remove existing height constraint on chipContainer
        chipContainer.constraints.filter { $0.firstAttribute == .height }.forEach { $0.isActive = false }

        guard !chips.isEmpty else {
            chipContainer.heightAnchor.constraint(equalToConstant: 0).isActive = true
            textField.placeholderString = "Type a flag name..."
            return
        }

        textField.placeholderString = ""

        // Flow layout: lay out chip views left-to-right, wrapping
        var x: CGFloat = 0
        var y: CGFloat = 0
        let spacing: CGFloat = 4
        let maxWidth = bounds.width - 12 // account for container insets

        for (i, chip) in chips.enumerated() {
            let view = makeChipView(chip, index: i)
            let size = view.fittingSize
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += size.height + spacing
            }
            view.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            chipContainer.addSubview(view)
            chipViews.append(view)
            x += size.width + spacing
        }

        let totalHeight = y + (chipViews.last?.frame.height ?? 0)
        chipContainer.heightAnchor.constraint(equalToConstant: totalHeight).isActive = true
    }

    private func makeChipView(_ chip: ArgsChip, index: Int) -> NSView {
        let label: String
        if let value = chip.value {
            label = "\(chip.flag) \(value)"
        } else {
            label = chip.flag
        }

        let button = NSButton(title: label, target: self, action: #selector(chipClicked(_:)))
        button.tag = index
        button.bezelStyle = .inline
        button.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        button.isBordered = true
        button.wantsLayer = true
        button.layer?.cornerRadius = 4

        if selectedChipIndex == index {
            button.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
            button.contentTintColor = .white
        }

        return button
    }

    @objc private func chipClicked(_ sender: NSButton) {
        if selectedChipIndex == sender.tag {
            // Already selected — deselect
            selectedChipIndex = nil
        } else {
            selectedChipIndex = sender.tag
        }
        rebuildChipViews()
        window?.makeFirstResponder(textField)
    }

    // MARK: - Keyboard Handling

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 /* Backspace */ {
            if let idx = selectedChipIndex {
                removeChip(at: idx)
                return
            }
            if textField.stringValue.isEmpty && !chips.isEmpty {
                selectedChipIndex = chips.count - 1
                rebuildChipViews()
                return
            }
        }
        if event.keyCode == 53 /* Escape */ {
            selectedChipIndex = nil
            rebuildChipViews()
        }
        super.keyDown(with: event)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        rebuildChipViews()
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/Window/ClaudeArgsField.swift
git commit -m "feat: add ClaudeArgsField with chip layout and inline text field"
```

---

### Task 5: Suggestion Dropdown Window

**Files:**
- Modify: `Sources/Window/ClaudeArgsField.swift`

Add the floating suggestion dropdown that shows filtered flag suggestions.

- [ ] **Step 1: Add NSTextFieldDelegate and suggestion window to ClaudeArgsField**

Add to `Sources/Window/ClaudeArgsField.swift`, below the existing code:

```swift
// MARK: - Suggestion Dropdown

extension ClaudeArgsField: NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {

    private static var suggestionWindowKey: UInt8 = 0
    private static var suggestionTableKey: UInt8 = 0
    private static var filteredFlagsKey: UInt8 = 0
    private static var selectedRowKey: UInt8 = 0

    private var suggestionWindow: NSWindow {
        if let w = objc_getAssociatedObject(self, &Self.suggestionWindowKey) as? NSWindow { return w }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                         styleMask: .borderless, backing: .buffered, defer: true)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .floating

        let visual = NSVisualEffectView(frame: w.contentView!.bounds)
        visual.autoresizingMask = [.width, .height]
        visual.material = .popover
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 8
        visual.layer?.masksToBounds = true
        w.contentView?.addSubview(visual)

        let scroll = NSScrollView(frame: visual.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 36
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Flag"))
        col.width = 380
        table.addTableColumn(col)
        table.dataSource = self
        table.delegate = self

        scroll.documentView = table
        visual.addSubview(scroll)

        objc_setAssociatedObject(self, &Self.suggestionTableKey, table, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(self, &Self.suggestionWindowKey, w, .OBJC_ASSOCIATION_RETAIN)
        return w
    }

    private var suggestionTable: NSTableView? {
        objc_getAssociatedObject(self, &Self.suggestionTableKey) as? NSTableView
    }

    private var filteredFlags: [ClaudeFlag] {
        get { (objc_getAssociatedObject(self, &Self.filteredFlagsKey) as? [ClaudeFlag]) ?? [] }
        set { objc_setAssociatedObject(self, &Self.filteredFlagsKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    private var selectedSuggestionRow: Int {
        get { (objc_getAssociatedObject(self, &Self.selectedRowKey) as? Int) ?? -1 }
        set { objc_setAssociatedObject(self, &Self.selectedRowKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        selectedChipIndex = nil
        let query = textField.stringValue.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "^-+", with: "", options: .regularExpression) // strip leading dashes

        if pendingFlag != nil {
            // User is typing a value for a pending flag — don't show flag suggestions
            hideSuggestions()
            return
        }

        guard !query.isEmpty else {
            hideSuggestions()
            return
        }

        let existingFlags = Set(chips.map(\.flag))
        let allFlags = ClaudeCLIFlags.shared.flags.filter { !existingFlags.contains($0.longName) }

        // Fuzzy match using Fuse
        let fuse = Fuse(threshold: 0.4)
        let scored = allFlags.compactMap { flag -> (ClaudeFlag, Double)? in
            // Match against the long name without dashes
            let name = flag.longName.replacingOccurrences(of: "^-+", with: "", options: .regularExpression)
            if let result = fuse.search(query, in: name) {
                return (flag, result.score)
            }
            // Also try substring match for short queries
            if name.localizedCaseInsensitiveContains(query) {
                return (flag, 0.5)
            }
            return nil
        }.sorted { $0.1 < $1.1 }

        filteredFlags = scored.map(\.0)
        selectedSuggestionRow = filteredFlags.isEmpty ? -1 : 0
        suggestionTable?.reloadData()

        if filteredFlags.isEmpty {
            hideSuggestions()
        } else {
            showSuggestions()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(moveUp(_:)) {
            if selectedSuggestionRow > 0 {
                selectedSuggestionRow -= 1
                suggestionTable?.selectRowIndexes(IndexSet(integer: selectedSuggestionRow), byExtendingSelection: false)
                suggestionTable?.scrollRowToVisible(selectedSuggestionRow)
            }
            return true
        }
        if commandSelector == #selector(moveDown(_:)) {
            if selectedSuggestionRow < filteredFlags.count - 1 {
                selectedSuggestionRow += 1
                suggestionTable?.selectRowIndexes(IndexSet(integer: selectedSuggestionRow), byExtendingSelection: false)
                suggestionTable?.scrollRowToVisible(selectedSuggestionRow)
            }
            return true
        }
        if commandSelector == #selector(insertTab(_:)) || commandSelector == #selector(insertNewline(_:)) {
            if pendingFlag != nil {
                commitPendingFlag()
                return true
            }
            if selectedSuggestionRow >= 0 && selectedSuggestionRow < filteredFlags.count {
                acceptSuggestion(filteredFlags[selectedSuggestionRow])
                return true
            }
            // If there's typed text that looks like a flag but isn't in suggestions, accept as unknown
            let typed = textField.stringValue.trimmingCharacters(in: .whitespaces)
            if typed.hasPrefix("-") {
                acceptUnknownFlag(typed)
                return true
            }
            return false
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            if pendingFlag != nil {
                pendingFlag = nil
                textField.stringValue = ""
                textField.placeholderString = chips.isEmpty ? "Type a flag name..." : ""
            }
            hideSuggestions()
            return true
        }
        if commandSelector == #selector(deleteBackward(_:)) {
            if textField.stringValue.isEmpty {
                if let idx = selectedChipIndex {
                    removeChip(at: idx)
                    return true
                }
                if !chips.isEmpty {
                    selectedChipIndex = chips.count - 1
                    rebuildChipViews()
                    return true
                }
            }
            return false
        }
        return false
    }

    private func acceptSuggestion(_ flag: ClaudeFlag) {
        hideSuggestions()
        textField.stringValue = ""

        switch flag.valueType {
        case .boolean:
            addChip(ArgsChip(flag: flag.longName, value: nil))
        case .enumeration(let values):
            pendingFlag = flag
            filteredFlags = [] // will be replaced with enum values
            showEnumChoices(values, for: flag)
        case .freeText:
            pendingFlag = flag
            textField.placeholderString = flag.valuePlaceholder ?? "<value>"
        }
    }

    private func showEnumChoices(_ values: [String], for flag: ClaudeFlag) {
        // Reuse the suggestion window to show enum values
        // Store enum values as pseudo-flags for table display
        filteredFlags = values.map { value in
            ClaudeFlag(longName: value, shortName: nil, description: "Set \(flag.longName) to \(value)",
                       valueType: .boolean, valuePlaceholder: nil)
        }
        selectedSuggestionRow = 0
        suggestionTable?.reloadData()
        showSuggestions()
    }

    private func commitPendingFlag() {
        guard let flag = pendingFlag else { return }

        if case .enumeration(let values) = flag.valueType,
           selectedSuggestionRow >= 0 && selectedSuggestionRow < values.count {
            addChip(ArgsChip(flag: flag.longName, value: values[selectedSuggestionRow]))
        } else {
            let value = textField.stringValue.trimmingCharacters(in: .whitespaces)
            addChip(ArgsChip(flag: flag.longName, value: value.isEmpty ? nil : value))
        }

        pendingFlag = nil
        textField.stringValue = ""
        textField.placeholderString = ""
        hideSuggestions()
    }

    private func acceptUnknownFlag(_ text: String) {
        hideSuggestions()
        addChip(ArgsChip(flag: text, value: nil))
        textField.stringValue = ""
    }

    // MARK: Suggestion Window Positioning

    private func showSuggestions() {
        guard let parentWindow = window else { return }
        let fieldRect = textField.convert(textField.bounds, to: nil)
        let screenRect = parentWindow.convertToScreen(fieldRect)
        let rows = min(filteredFlags.count, 6)
        let height = CGFloat(rows) * 36 + 4
        suggestionWindow.setFrame(NSRect(x: screenRect.minX, y: screenRect.minY - height - 2,
                                         width: max(screenRect.width, 400), height: height), display: true)
        if !suggestionWindow.isVisible {
            parentWindow.addChildWindow(suggestionWindow, ordered: .above)
        }
        if selectedSuggestionRow >= 0 {
            suggestionTable?.selectRowIndexes(IndexSet(integer: selectedSuggestionRow), byExtendingSelection: false)
        }
    }

    private func hideSuggestions() {
        if suggestionWindow.isVisible {
            suggestionWindow.parent?.removeChildWindow(suggestionWindow)
            suggestionWindow.orderOut(nil)
        }
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredFlags.count
    }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let flag = filteredFlags[row]
        let cell = NSTableCellView()

        let nameLabel = NSTextField(labelWithString: flag.longName)
        nameLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = .labelColor

        let descLabel = NSTextField(labelWithString: flag.description)
        descLabel.font = .systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        descLabel.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [nameLabel, descLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = suggestionTable else { return }
        let row = table.selectedRow
        if row >= 0 {
            selectedSuggestionRow = row
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        true
    }
}
```

Note: This uses associated objects for the suggestion window state to keep the extension clean. The `Fuse` import needs to be added at the top of the file.

- [ ] **Step 2: Add Fuse import at the top of ClaudeArgsField.swift**

Add `import Fuse` after `import AppKit` at the top of the file.

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Sources/Window/ClaudeArgsField.swift
git commit -m "feat: add suggestion dropdown with fuzzy matching to ClaudeArgsField"
```

---

### Task 6: Integrate into Settings General Pane

**Files:**
- Modify: `Sources/Window/SettingsWindow.swift:123-141`

- [ ] **Step 1: Replace NSTextField with ClaudeArgsField in settings**

In `Sources/Window/SettingsWindow.swift`, replace lines 123-134 (the `extraArgsField` creation block):

Old code:
```swift
        // Extra arguments
        let extraArgsLabel = NSTextField(labelWithString: "Extra arguments:")
        extraArgsLabel.alignment = .right

        let extraArgsField = NSTextField()
        extraArgsField.stringValue = UserDefaults.standard.string(forKey: "claudeExtraArgs") ?? ""
        extraArgsField.placeholderString = "--permission-mode auto"
        extraArgsField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        objc_setAssociatedObject(extraArgsField, &settingsKeyAssoc, "claudeExtraArgs", .OBJC_ASSOCIATION_RETAIN)
        extraArgsField.delegate = self
        extraArgsField.target = self
        extraArgsField.action = #selector(textFieldChanged(_:))

        grid.addRow(with: [extraArgsLabel, extraArgsField])
```

New code:
```swift
        // Extra arguments
        let extraArgsLabel = NSTextField(labelWithString: "Extra arguments:")
        extraArgsLabel.alignment = .right

        let extraArgsField = ClaudeArgsField(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        extraArgsField.stringValue = UserDefaults.standard.string(forKey: "claudeExtraArgs") ?? ""
        extraArgsField.translatesAutoresizingMaskIntoConstraints = false
        extraArgsField.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        extraArgsField.onChange = { newValue in
            UserDefaults.standard.set(newValue, forKey: "claudeExtraArgs")
        }

        grid.addRow(with: [extraArgsLabel, extraArgsField])
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/Window/SettingsWindow.swift
git commit -m "feat: use ClaudeArgsField in settings general pane"
```

---

### Task 7: Integrate into Per-Session Dialog

**Files:**
- Modify: `Sources/Window/DeckardWindowController.swift:744-769`

- [ ] **Step 1: Replace NSTextField with ClaudeArgsField in per-session dialog**

In `Sources/Window/DeckardWindowController.swift`, replace the field creation in `promptForClaudeArgs()` (lines 751-754):

Old code:
```swift
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.stringValue = UserDefaults.standard.string(forKey: "claudeExtraArgs") ?? ""
        field.placeholderString = "--permission-mode auto"
        alert.accessoryView = field
```

New code:
```swift
        let field = ClaudeArgsField(frame: NSRect(x: 0, y: 0, width: 400, height: 60))
        field.stringValue = UserDefaults.standard.string(forKey: "claudeExtraArgs") ?? ""
        alert.accessoryView = field
```

And update the completion call (line 763) to use `field.stringValue` (this already works since `ClaudeArgsField.stringValue` returns the serialized string):

```swift
            completion(field.stringValue)
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/Window/DeckardWindowController.swift
git commit -m "feat: use ClaudeArgsField in per-session args dialog"
```

---

### Task 8: Manual Testing & Polish

**Files:**
- Possibly modify: `Sources/Window/ClaudeArgsField.swift` (visual tweaks)

- [ ] **Step 1: Build the app**

Run: `xcodebuild -project Deckard.xcodeproj -scheme Deckard -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 2: Manual test checklist**

After launching the app (with user permission), verify:

1. Open Settings → General pane → "Extra arguments" field shows chips for any previously saved args
2. Click in the field and type "perm" → dropdown shows `--permission-mode`
3. Select `--permission-mode` → dropdown shows enum values (auto, default, etc.)
4. Select "auto" → chip `--permission-mode auto` appears
5. Type "verb" → dropdown shows `--verbose`, select it → chip appears immediately (boolean)
6. Press Backspace on empty field → last chip becomes selected
7. Press Backspace again → selected chip is deleted
8. Blocked flags (--resume, --print, etc.) do not appear in suggestions
9. Close settings → reopen → chips persist correctly
10. Test per-session dialog (enable "Customize arguments per session", create new Claude tab)

- [ ] **Step 3: Fix any visual or behavioral issues found**

Address issues found in manual testing.

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "fix: polish ClaudeArgsField visual and interaction issues"
```
