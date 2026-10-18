//  Created by Marcin Krzyzanowski
//  https://github.com/krzyzanowskim/STTextView/blob/main/LICENSE.md

import AppKit
import STTextKitPlus

extension STTextView: NSTextViewportLayoutControllerDelegate {

    public func textViewportLayoutControllerWillLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
        captureViewportTextAnchor()
        lastUsedFragmentViews = Set(contentViewportView.subviews.compactMap { $0 as? STTextLayoutFragmentView })

        if ProcessInfo().environment["ST_LAYOUT_DEBUG"] == "YES" {
            let viewportDebugView = NSView(frame: viewportBounds(for: textViewportLayoutController))
            viewportDebugView.clipsToBounds = true
            viewportDebugView.wantsLayer = true
            viewportDebugView.layer?.borderColor = NSColor.magenta.cgColor
            viewportDebugView.layer?.borderWidth = 4
            contentViewportView.addSubview(viewportDebugView)
        }
    }

    public func viewportBounds(for textViewportLayoutController: NSTextViewportLayoutController) -> CGRect {
        let gutterWidth = gutterView?.frame.width ?? 0

        // preparedContentRect is in STTextView (documentView) coords — shift to contentView coords
        var prepared = preparedContentRect
        prepared.origin.x += gutterWidth
        prepared.size.width -= gutterWidth
        prepared.origin.y += contentView.bounds.minY

        // visibleRect is already in contentView coords (contentView.origin.x = gutterWidth)
        var visible = contentView.visibleRect

        // Clamp negative origins to 0 (handles overscroll bounce)
        if visible.minX < 0 {
            visible.size.width += visible.minX
            visible.origin.x = 0
        }
        if visible.minY < 0 {
            visible.size.height += visible.minY
            visible.origin.y = 0
        }

        // Y-only union, width from contentView bounds
        if prepared.intersects(visible) {
            let minY = max(0, min(prepared.minY, visible.minY))
            let maxY = max(prepared.maxY, visible.maxY)
            return CGRect(x: 0, y: minY, width: contentView.bounds.width, height: maxY - minY)
        } else {
            return visible
        }
    }

    public func textViewportLayoutController(_ textViewportLayoutController: NSTextViewportLayoutController, configureRenderingSurfaceFor textLayoutFragment: NSTextLayoutFragment) {
        var needsDisplay = false
        if let textLayoutFragment = textLayoutFragment as? STTextLayoutFragment,
           textLayoutFragment.showsInvisibleCharacters != showsInvisibleCharacters {
            textLayoutFragment.showsInvisibleCharacters = showsInvisibleCharacters
            needsDisplay = true
        }

        // textLayoutFragment.layoutFragmentFrame is calculated in `self` coordinates,
        // but we use it in contentViewportView coordinates. contentViewportView frame is offset by gutterWidth
        let layoutFragmentFrame = textLayoutFragment.layoutFragmentFrame
        let fragmentView: STTextLayoutFragmentView
        if let cachedFragmentView = fragmentViewMap.object(forKey: textLayoutFragment) {
            cachedFragmentView.layoutFragment = textLayoutFragment
            fragmentView = cachedFragmentView
            lastUsedFragmentViews.remove(cachedFragmentView)
        } else {
            fragmentView = STTextLayoutFragmentView(layoutFragment: textLayoutFragment, frame: layoutFragmentFrame.pixelAligned)
            fragmentViewMap.setObject(fragmentView, forKey: textLayoutFragment)
        }

        // Adjust fragment view frame
        if !fragmentView.frame.isAlmostEqual(to: layoutFragmentFrame.pixelAligned) {
            fragmentView.frame = textLayoutFragment.layoutFragmentFrame.pixelAligned
            fragmentView.needsLayout = true
            needsDisplay = true
        }

        if needsDisplay {
            fragmentView.needsDisplay = true
        }

        if fragmentView.superview != contentViewportView {
            contentViewportView.addSubview(fragmentView)
        }
    }

    public func textViewportLayoutControllerDidLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
        for staleView in lastUsedFragmentViews {
            staleView.removeFromSuperview()
        }
        lastUsedFragmentViews.removeAll()

        if let viewportRange = textViewportLayoutController.viewportRange {
            textLayoutManager.ensureLayout(for: viewportRange)
        }

        updateUniformLineHeight()
        correctUniformViewportOrigin()
        updateContentSizeIfNeeded()
        restoreViewportTextAnchor()

        updateSelectedRangeHighlight()
        updateSelectedLineHighlight()
        layoutGutter()

        if let viewportRange = textViewportLayoutController.viewportRange {
            for events in plugins.events {
                events.didLayoutViewportHandler?(viewportRange)
            }
        }
    }
}
