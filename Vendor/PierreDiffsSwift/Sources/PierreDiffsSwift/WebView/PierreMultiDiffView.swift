//
//  PierreMultiDiffView.swift
//  PierreDiffsSwift
//

import SwiftUI
import WebKit

@MainActor
public final class PierreMultiDiffSurface {
  public fileprivate(set) var webView: WKWebView?
  fileprivate var coordinator: DiffWebViewCoordinator?

  public init() {}

  isolated deinit {
    coordinator?.cleanup()
  }

  fileprivate static func makeWebView(coordinator: DiffWebViewCoordinator) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.add(coordinator, name: "diffBridge")
    configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = coordinator
    webView.allowsMagnification = true
    webView.setValue(false, forKey: "drawsBackground")
    coordinator.webView = webView
    webView.loadHTMLString(DiffHTMLTemplate.generateHTML(), baseURL: nil)
    return webView
  }
}

private final class PierreMultiDiffContainer: NSView {
  let webView: WKWebView

  init(webView: WKWebView) {
    self.webView = webView
    super.init(frame: .zero)
    addSubview(webView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    needsLayout = true
  }

  override func layout() {
    super.layout()
    guard webView.superview === self, bounds.width > 0, bounds.height > 0 else { return }
    if webView.frame != bounds { webView.frame = bounds }
  }
}

/// A SwiftUI view that renders many file diffs stacked in one scroll surface —
/// the whole change set of a commit, branch, or working tree at once.
///
/// Unlike `PierreDiffView`, which renders a single `FileDiff`, this wraps
/// `@pierre/diffs`' `CodeView`: rows are virtualized, so only what is on screen
/// is rendered and a large change set stays responsive. Use `scrollRequest` to
/// jump to a particular file — for example from a file list beside the diff.
public struct PierreMultiDiffView: NSViewRepresentable {

  // MARK: - Properties

  /// The files to render, in display order.
  let files: [PierreDiffFile]
  private let surface: PierreMultiDiffSurface?

  /// The current diff view style
  @Binding var diffStyle: DiffStyle

  /// The current overflow mode (scroll or wrap)
  @Binding var overflowMode: OverflowMode

  /// Additional renderer options passed through to the underlying views
  var renderOptions: PierreDiffRenderOptions

  /// File to scroll to. Bump the request's `token` to scroll to the same file
  /// again; requests naming a file that has not rendered yet are applied once
  /// it does.
  var scrollRequest: PierreDiffScrollRequest?

  /// Callback when the user clicks on a line (lineNumber, side)
  var onLineClick: ((Int, String) -> Void)?

  /// Callback when a range of lines is selected via drag
  var onLineSelectionChange: ((LineSelectionRange) -> Void)?

  /// Callback on every edit (file ID, updated contents).
  var onFileEditChange: ((String, String) -> Void)?

  /// Callback when an edited item leaves edit mode (file ID, final contents).
  var onFileEditComplete: ((String, String) -> Void)?

  /// Callback when the WebView is ready to display content
  var onReady: (() -> Void)?

  // MARK: - Environment

  @Environment(\.colorScheme) private var colorScheme

  // MARK: - Initialization

  public init(
    files: [PierreDiffFile],
    surface: PierreMultiDiffSurface? = nil,
    diffStyle: Binding<DiffStyle>,
    overflowMode: Binding<OverflowMode>,
    renderOptions: PierreDiffRenderOptions = PierreDiffRenderOptions(),
    scrollRequest: PierreDiffScrollRequest? = nil,
    onLineClick: ((Int, String) -> Void)? = nil,
    onLineSelectionChange: ((LineSelectionRange) -> Void)? = nil,
    onFileEditChange: ((String, String) -> Void)? = nil,
    onFileEditComplete: ((String, String) -> Void)? = nil,
    onReady: (() -> Void)? = nil
  ) {
    self.files = files
    self.surface = surface
    self._diffStyle = diffStyle
    self._overflowMode = overflowMode
    self.renderOptions = renderOptions
    self.scrollRequest = scrollRequest
    self.onLineClick = onLineClick
    self.onLineSelectionChange = onLineSelectionChange
    self.onFileEditChange = onFileEditChange
    self.onFileEditComplete = onFileEditComplete
    self.onReady = onReady
  }

  // MARK: - NSViewRepresentable

  public func makeNSView(context: Context) -> NSView {
    let webView = surface?.webView
      ?? PierreMultiDiffSurface.makeWebView(coordinator: context.coordinator)
    surface?.webView = webView
    return PierreMultiDiffContainer(webView: webView)
  }

  public func updateNSView(_ view: NSView, context: Context) {
    let coordinator = context.coordinator
    let currentTheme = colorScheme == .dark ? "dark" : "light"

    let filesChanged = coordinator.lastFiles != files
    let styleChanged = coordinator.lastDiffStyle != diffStyle
    let overflowChanged = coordinator.lastOverflowMode != overflowMode
    let themeChanged = coordinator.lastTheme != currentTheme

    let previousRenderOptions = coordinator.lastRenderOptions
    let renderOptionsChanged = previousRenderOptions != renderOptions
    let nonFontRenderOptionsChanged: Bool = {
      guard let previousRenderOptions else { return renderOptionsChanged }
      var normalizedPrevious = previousRenderOptions
      normalizedPrevious.font = renderOptions.font
      return normalizedPrevious != renderOptions
    }()
    let fontOnlyChanged = renderOptionsChanged && !nonFontRenderOptionsChanged
    let requiresFullRender = filesChanged || nonFontRenderOptionsChanged

    if requiresFullRender {
      coordinator.lastFiles = files
      coordinator.lastDiffStyle = diffStyle
      coordinator.lastOverflowMode = overflowMode
      coordinator.lastTheme = currentTheme
      coordinator.lastRenderOptions = renderOptions
      coordinator.renderFiles(
        files,
        theme: currentTheme,
        diffStyle: diffStyle,
        overflowMode: overflowMode,
        renderOptions: renderOptions
      )
    } else if styleChanged {
      coordinator.lastDiffStyle = diffStyle
      coordinator.setDiffStyle(diffStyle)
    } else if overflowChanged {
      coordinator.lastOverflowMode = overflowMode
      coordinator.setOverflow(overflowMode)
    } else if themeChanged {
      coordinator.lastTheme = currentTheme
      coordinator.setTheme(currentTheme)
    }

    if !requiresFullRender && fontOnlyChanged {
      coordinator.lastRenderOptions = renderOptions
      coordinator.setFont(renderOptions.font)
    }

    // Ordered after the render so a request arriving with new files lands on
    // the freshly rendered list rather than the one it replaced.
    if let scrollRequest, coordinator.lastScrollRequest != scrollRequest {
      coordinator.lastScrollRequest = scrollRequest
      coordinator.scrollToFile(scrollRequest)
    }
  }

  public func makeCoordinator() -> DiffWebViewCoordinator {
    if let coordinator = surface?.coordinator { return coordinator }
    let coordinator = DiffWebViewCoordinator(
      onLineClick: onLineClick,
      onLineSelectionChange: onLineSelectionChange,
      onFileEditChange: onFileEditChange,
      onFileEditComplete: onFileEditComplete,
      onReady: onReady
    )
    coordinator.retainedSurface = surface
    surface?.coordinator = coordinator
    return coordinator
  }

  public static func dismantleNSView(_ nsView: NSView, coordinator: DiffWebViewCoordinator) {
    if let container = nsView as? PierreMultiDiffContainer,
      container.webView.superview === container {
      container.webView.removeFromSuperview()
    }
    guard coordinator.retainedSurface == nil else { return }
    coordinator.cleanup()
  }
}
