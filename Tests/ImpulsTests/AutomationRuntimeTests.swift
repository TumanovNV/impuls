import XCTest
@testable import ImpulsCore

final class AutomationRuntimeTests: XCTestCase {
    @MainActor
    override func setUp() {
        super.setUp()
        ImpulsAutomationRuntime.shared.reset()
    }

    @MainActor
    override func tearDown() {
        ImpulsAutomationRuntime.shared.reset()
        super.tearDown()
    }

    @MainActor
    func testColdLaunchWaiterUsesInstalledAuthoritativeRuntime() async throws {
        var showCount = 0
        let task = Task { @MainActor in
            try await ImpulsAutomationRuntime.shared.show()
        }

        await Task.yield()
        ImpulsAutomationRuntime.shared.install(
            .init(
                show: {
                    showCount += 1
                    return true
                },
                open: { _ in true },
                addSnippet: { _, _ in true }
            )
        )

        try await task.value
        XCTAssertEqual(showCount, 1)
    }

    @MainActor
    func testOpenModuleRoutesOneRequestedModule() async throws {
        var opened: [ImpulsAutomationModule] = []
        install(open: {
            opened.append($0)
            return true
        })

        try await ImpulsAutomationRuntime.shared.open(module: .clipboard)

        XCTAssertEqual(opened, [.clipboard])
    }

    @MainActor
    func testUnavailableModuleUsesStableError() async {
        install(open: { _ in false })

        do {
            try await ImpulsAutomationRuntime.shared.open(module: .power)
            XCTFail("Expected moduleUnavailable")
        } catch let error as ImpulsAutomationError {
            XCTAssertEqual(error, .moduleUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testAddSnippetWritesExactlyOnceAfterTrimming() async throws {
        var writes: [(String, String)] = []
        install(addSnippet: { label, text in
            writes.append((label, text))
            return true
        })

        try await ImpulsAutomationRuntime.shared.addSnippet(
            text: "  value to keep  \n",
            label: "  Work  "
        )

        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.0, "Work")
        XCTAssertEqual(writes.first?.1, "value to keep")
    }

    @MainActor
    func testEmptySnippetFailsBeforeWrite() async {
        var writeCount = 0
        install(addSnippet: { _, _ in
            writeCount += 1
            return true
        })

        do {
            try await ImpulsAutomationRuntime.shared.addSnippet(text: " \n\t ")
            XCTFail("Expected invalidInput")
        } catch let error as ImpulsAutomationError {
            XCTAssertEqual(error, .invalidInput)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(writeCount, 0)
    }

    @MainActor
    func testOversizedSnippetFailsBeforeWrite() async {
        var writeCount = 0
        install(addSnippet: { _, _ in
            writeCount += 1
            return true
        })
        let tooLong = String(repeating: "a", count: ImpulsAutomationRuntime.maximumSnippetTextCharacters + 1)

        do {
            try await ImpulsAutomationRuntime.shared.addSnippet(text: tooLong)
            XCTFail("Expected invalidInput")
        } catch let error as ImpulsAutomationError {
            XCTAssertEqual(error, .invalidInput)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(writeCount, 0)
    }

    @MainActor
    func testPendingRequestFailsWhenRuntimeIsTornDown() async {
        let task = Task { @MainActor in
            try await ImpulsAutomationRuntime.shared.show()
        }
        await Task.yield()
        ImpulsAutomationRuntime.shared.reset()

        do {
            try await task.value
            XCTFail("Expected serviceUnavailable")
        } catch let error as ImpulsAutomationError {
            XCTAssertEqual(error, .serviceUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    private func install(
        show: @escaping @MainActor () -> Bool = { true },
        open: @escaping @MainActor (ImpulsAutomationModule) -> Bool = { _ in true },
        addSnippet: @escaping @MainActor (String, String) -> Bool = { _, _ in true }
    ) {
        ImpulsAutomationRuntime.shared.install(
            .init(show: show, open: open, addSnippet: addSnippet)
        )
    }
}
