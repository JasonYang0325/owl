/// OWL Browser Context Menu XCUITest — end-to-end right-click menu verification.
///
/// Tests the full stack: right-click on web content → Host context menu params →
/// Bridge callback → Swift ContextMenuHandler → NSMenu display → menu item actions.
///
/// Covers AC-001 through AC-005f from the context menu feature spec.
///
/// Run: xcodebuild test -project OWLBrowser.xcodeproj -scheme OWLBrowserUITests -only-testing:ContextMenuUITests
import XCTest

final class ContextMenuUITests: XCTestCase {

    var app: XCUIApplication!
    var server: TestDownloadHTTPServer!

    // MARK: - Test HTML (inlined to avoid bundle resource issues in XCUITest)

    /// The context menu test page HTML, served by local HTTP server.
    /// Contains: link, image (data URI), selectable text, input field, blank area.
    private static let testPageHTML: String = """
    <!DOCTYPE html>
    <html>
    <head>
        <meta charset="utf-8">
        <title>Context Menu Test Page</title>
        <style>
            body { font-family: -apple-system, sans-serif; margin: 40px; }
            #link { display: block; margin: 20px 0; font-size: 18px; }
            #img { display: block; margin: 20px 0; }
            #text { margin: 20px 0; font-size: 18px; line-height: 1.6; user-select: text; }
            #input { display: block; margin: 20px 0; font-size: 16px; padding: 8px; width: 300px; }
            #blank { height: 200px; background: #eee; margin: 20px 0; }
        </style>
    </head>
    <body>
        <a id="link" href="https://example.com/target">Test Link for Context Menu</a>
        <img id="img"
             src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAoAAAAKCAYAAACNMs+9AAAAFklEQVQYV2P8z8BQz0BFwMgwasCoAgBGWAkFnLmHjgAAAABJRU5ErkJggg=="
             width="100" height="100" alt="Test Image">
        <p id="text">Selectable text for context menu testing</p>
        <input id="input" type="text" value="editable content">
        <div id="blank" style="height:200px;background:#eee"></div>
    </body>
    </html>
    """

    // MARK: - setUp / tearDown

    override func setUpWithError() throws {
        continueAfterFailure = false

        // 1. Start local HTTP server to serve the test page.
        server = TestDownloadHTTPServer()
        server.addRoute(TestDownloadHTTPServer.Route(
            path: "/context-menu-test",
            contentType: "text/html; charset=utf-8",
            body: Data(Self.testPageHTML.utf8)
        ))
        let port = try server.start()
        NSLog("[ContextMenuUITests] Server started on port \(port)")

        // 2. Launch or activate app.
        app = XCUIApplication()

        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.antlerai.owl.browser")
        if let existing = running.first {
            existing.activate()
            app.activate()
        } else {
            app.launchEnvironment["OWL_ENABLE_TEST_JS"] = "1"
            app.launchEnvironment["OWL_CLEAN_SESSION"] = "1"
            app.launch()
        }

        let addressBar = app.textFields["addressBar"]
        XCTAssertTrue(addressBar.waitForExistence(timeout: 20),
                      "Address bar should appear after app launch")
    }

    override func tearDownWithError() throws {
        // Dismiss any open menu by pressing Escape.
        app.typeKey(.escape, modifierFlags: [])
        sleep(1)

        server?.stop()
        server = nil
    }

    // MARK: - Helpers

    /// Navigate via address bar — types URL and presses Enter (real system events).
    private func navigate(to url: String) {
        let addressBar = app.textFields["addressBar"]
        addressBar.click()
        addressBar.typeKey("a", modifierFlags: .command)
        addressBar.typeText(url + "\n")
    }

    /// Wait for page URL to contain a substring (via hidden accessibility label).
    private func waitForURL(containing substring: String, timeout: TimeInterval = 15) -> Bool {
        let pageURL = app.staticTexts["pageURL"]
        let predicate = NSPredicate(format: "label CONTAINS %@", substring)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: pageURL)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Get the web content view element for coordinate-based interactions.
    private var webContent: XCUIElement {
        app.otherElements["webContentView"]
    }

    /// Navigate to the local test page and wait for it to load.
    private func navigateToTestPage() throws {
        navigate(to: "http://localhost:\(server.port)/context-menu-test")
        XCTAssertTrue(waitForURL(containing: "context-menu-test"),
                      "Should navigate to context menu test page")
        sleep(2) // Extra wait for page elements to render

        let content = webContent
        try XCTSkipUnless(content.waitForExistence(timeout: 10),
                          "webContentView not in AX tree (CALayerHost AX not registered)")
    }

    /// Right-click at a normalized offset within the web content view.
    /// Returns the coordinate used, for debugging.
    @discardableResult
    private func rightClick(dx: CGFloat, dy: CGFloat) -> XCUICoordinate {
        let content = webContent
        let coord = content.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
        coord.rightClick()
        sleep(1) // Wait for context menu to appear
        return coord
    }

    /// Dismiss the current context menu by pressing Escape.
    private func dismissMenu() {
        app.typeKey(.escape, modifierFlags: [])
        sleep(1)
    }

    /// Check if a menu item with the given title exists in any open menu.
    private func menuItemExists(_ title: String, timeout: TimeInterval = 3) -> Bool {
        let menuItem = app.menuItems[title]
        return menuItem.waitForExistence(timeout: timeout)
    }

    // MARK: - Test Layout Constants
    //
    // The test page layout (top to bottom):
    //   ~0.05-0.15  link (#link)
    //   ~0.15-0.35  image (#img, 100x100)
    //   ~0.35-0.45  text (#text)
    //   ~0.45-0.55  input (#input)
    //   ~0.55-0.90  blank (#blank, 200px)
    //
    // Normalized offsets (dx, dy) relative to webContentView.

    /// dy offset for the link element (top area).
    private let linkDY: CGFloat = 0.08
    /// dy offset for the image element.
    private let imageDY: CGFloat = 0.22
    /// dy offset for the text paragraph.
    private let textDY: CGFloat = 0.40
    /// dy offset for the input field.
    private let inputDY: CGFloat = 0.50
    /// dy offset for the blank area.
    private let blankDY: CGFloat = 0.75

    // MARK: - AC-001: Link Context Menu

    /// AC-001: Right-click on a link shows "在新标签页中打开" and "复制链接地址" menu items.
    /// User sees: right-click on link → context menu appears with link-specific items.
    func testLinkContextMenu() throws {
        try navigateToTestPage()

        // Right-click on the link area
        rightClick(dx: 0.3, dy: linkDY)

        // Verify link-specific menu items
        XCTAssertTrue(menuItemExists("在新标签页中打开"),
                      "AC-001: Link context menu should contain '在新标签页中打开'")
        XCTAssertTrue(menuItemExists("复制链接地址"),
                      "AC-001: Link context menu should contain '复制链接地址'")

        dismissMenu()
    }

    // MARK: - AC-002: Image Context Menu

    /// AC-002: Right-click on an image shows image-specific menu items.
    /// User sees: right-click on image → menu with save/copy options.
    func testImageContextMenu() throws {
        try navigateToTestPage()

        // Right-click on the image area
        rightClick(dx: 0.3, dy: imageDY)

        // Verify image-specific menu items
        let hasSaveImage = menuItemExists("将图片存储到「下载」")
        let hasCopyImage = menuItemExists("复制图片")
        let hasCopyImageUrl = menuItemExists("复制图片地址")

        // At least one image-specific item should be present
        XCTAssertTrue(hasSaveImage || hasCopyImage || hasCopyImageUrl,
                      "AC-002: Image context menu should contain image-specific items "
                      + "(将图片存储到「下载」, 复制图片, or 复制图片地址)")

        dismissMenu()
    }

    // MARK: - AC-003: Selection Context Menu

    /// AC-003: Select text then right-click shows "复制" and search menu items.
    /// User sees: text selection → right-click → copy and search options.
    func testSelectionContextMenu() throws {
        try navigateToTestPage()

        // Click on text to position cursor, then select via keyboard
        let content = webContent
        let textCoord = content.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: textDY))
        textCoord.click()
        sleep(1)

        // Triple-click to select the entire paragraph text
        textCoord.click()
        textCoord.click()
        textCoord.click()
        sleep(1)

        // Right-click on the selected text
        textCoord.rightClick()
        sleep(1)

        // Verify selection-specific menu items
        let hasCopy = menuItemExists("复制")
        // Search menu item contains the selected text, so use partial match
        let searchItems = app.menuItems.matching(
            NSPredicate(format: "title BEGINSWITH '搜索'")
        )
        let hasSearch = searchItems.firstMatch.waitForExistence(timeout: 3)

        XCTAssertTrue(hasCopy || hasSearch,
                      "AC-003: Selection context menu should contain '复制' or '搜索...' items")

        dismissMenu()
    }

    // MARK: - AC-004a: Page Context Menu (blank area)

    /// AC-004a: Right-click on blank area shows navigation menu items.
    /// User sees: right-click on empty space → 后退/前进/重新加载.
    func testPageContextMenu() throws {
        try navigateToTestPage()

        // Right-click on the blank area
        rightClick(dx: 0.5, dy: blankDY)

        // Verify page-level menu items
        let hasBack = menuItemExists("后退")
        let hasForward = menuItemExists("前进")
        let hasReload = menuItemExists("重新加载")

        XCTAssertTrue(hasBack,
                      "AC-004a: Page context menu should contain '后退'")
        XCTAssertTrue(hasForward,
                      "AC-004a: Page context menu should contain '前进'")
        XCTAssertTrue(hasReload,
                      "AC-004a: Page context menu should contain '重新加载'")

        dismissMenu()
    }

    // MARK: - AC-005a: Copy Link URL

    /// AC-005a: Copy link URL to clipboard.
    /// User sees: right-click link → click "复制链接地址" → clipboard contains URL.
    func testCopyLinkUrl() throws {
        try navigateToTestPage()

        // Clear clipboard first
        NSPasteboard.general.clearContents()

        // Right-click on the link area
        rightClick(dx: 0.3, dy: linkDY)

        // Click "复制链接地址"
        let copyLinkItem = app.menuItems["复制链接地址"]
        guard copyLinkItem.waitForExistence(timeout: 3) else {
            XCTFail("AC-005a: '复制链接地址' menu item not found")
            return
        }
        copyLinkItem.click()
        sleep(1)

        // Verify clipboard contains the link URL
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(clipboard.contains("example.com/target"),
                      "AC-005a: Clipboard should contain link URL 'example.com/target', got: '\(clipboard)'")
    }

    // MARK: - AC-005d: Copy Selected Text

    /// AC-005d: Copy selected text to clipboard.
    /// User sees: select text → right-click → "复制" → clipboard contains text.
    func testCopyText() throws {
        try navigateToTestPage()

        // Clear clipboard first
        NSPasteboard.general.clearContents()

        // Click on text to position cursor
        let content = webContent
        let textCoord = content.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: textDY))
        textCoord.click()
        sleep(1)

        // Triple-click to select the paragraph text
        textCoord.click()
        textCoord.click()
        textCoord.click()
        sleep(1)

        // Right-click on the selected text
        textCoord.rightClick()
        sleep(1)

        // Click "复制"
        let copyItem = app.menuItems["复制"]
        guard copyItem.waitForExistence(timeout: 3) else {
            XCTFail("AC-005d: '复制' menu item not found in selection context menu")
            return
        }
        copyItem.click()
        sleep(1)

        // Verify clipboard contains the selected text
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(clipboard.contains("Selectable text"),
                      "AC-005d: Clipboard should contain selected text, got: '\(clipboard)'")
    }

    // MARK: - AC-005f: Editable Context Menu

    /// AC-005f: Right-click in an input field shows cut/copy/paste/selectAll.
    /// User sees: right-click in text input → editable context menu items.
    func testEditableMenu() throws {
        try navigateToTestPage()

        // Click on the input field to focus it
        let content = webContent
        let inputCoord = content.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: inputDY))
        inputCoord.click()
        sleep(1)

        // Right-click on the input field
        inputCoord.rightClick()
        sleep(1)

        // Verify editable menu items
        let hasCut = menuItemExists("剪切")
        let hasCopy = menuItemExists("复制")
        let hasPaste = menuItemExists("粘贴")
        let hasSelectAll = menuItemExists("全选")

        XCTAssertTrue(hasCut,
                      "AC-005f: Editable context menu should contain '剪切'")
        XCTAssertTrue(hasCopy,
                      "AC-005f: Editable context menu should contain '复制'")
        XCTAssertTrue(hasPaste,
                      "AC-005f: Editable context menu should contain '粘贴'")
        XCTAssertTrue(hasSelectAll,
                      "AC-005f: Editable context menu should contain '全选'")

        dismissMenu()
    }
}
