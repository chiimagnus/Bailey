import AppKit
import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit
import XCTest
@testable import Bailey

@MainActor
final class MarkdownResourceScopeTests: XCTestCase {
    func testAuthorizedSSHMarkdownKeepsScopedResourcesAndOriginalBytes() async throws {
        guard let host = ProcessInfo.processInfo.environment["BAILEY_P4_TEST_SSH_HOST"] else {
            throw XCTSkip("Set BAILEY_P4_TEST_SSH_HOST to an explicitly authorized SSH test host")
        }
        let socket = "/tmp/bailey-md-\(UUID().uuidString.prefix(12)).sock"
        let backend = SSHWorkspaceBackend(runner: SSHHostCommandRunner(host: host, socket: socket))
        var verifiedFixture: String?

        func stopMaster() async throws {
            guard FileManager.default.fileExists(atPath: socket) else { return }
            let exited = try await Task.detached {
                try ProcessRemoteCommandRunner.launch(
                    sshPath: "/usr/bin/ssh", arguments: ["-S", socket, "-O", "exit", host],
                    stdin: nil, timeout: 10
                )
            }.value
            XCTAssertEqual(exited.status, 0)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while FileManager.default.fileExists(atPath: socket) {
                guard ContinuousClock.now < deadline else { throw WorkspaceError.timedOut }
                try await Task.sleep(for: .milliseconds(25))
            }
        }

        func cleanup() async {
            if let verifiedFixture {
                do { try await backend.delete(paths: [verifiedFixture]) }
                catch { XCTFail("Could not remove the isolated remote Markdown fixture: \(error)") }
            }
            do { try await stopMaster() }
            catch { XCTFail("Could not stop the test-owned SSH master: \(error)") }
        }

        func load(_ file: FileTab) async throws {
            file.loadIfNeeded()
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while case .loading = file.content {
                guard ContinuousClock.now < deadline else { throw WorkspaceError.timedOut }
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        func renderHTML(_ file: FileTab, directory: String) async throws -> [String] {
            let previous = file.htmlPreview?.webView.url
            await file.showHTMLPreview(request: file.textPreviewRequestID, in: directory)
            let preview = try XCTUnwrap(file.htmlPreview)
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while preview.webView.url == nil || preview.webView.url == previous || preview.webView.isLoading {
                guard !preview.failed else { throw CocoaError(.fileReadCorruptFile) }
                guard ContinuousClock.now < deadline else { throw WorkspaceError.timedOut }
                try await Task.sleep(for: .milliseconds(20))
            }
            let values = try await preview.webView.evaluateJavaScript("""
                [document.querySelector('h1').textContent, getComputedStyle(document.querySelector('h1')).color,
                 String(document.querySelector('img').naturalWidth)]
                """, contentWorld: .defaultClient)
            return try XCTUnwrap(values as? [String])
        }

        func assertRemoteMediaIsUnavailable(_ path: String, on channel: SSHWorkspaceBackend) async throws {
            let file = FileTab(path: path, backend: channel, workspaceIdentity: "ssh:\(host)")
            try await load(file)
            guard case .unavailable(let reason) = file.content else {
                return XCTFail("The SSH media must not load the Mac namesake: \(path)")
            }
            XCTAssertEqual(reason, String(localized: "Media playback is only available for files on this Mac.",
                                          table: "Editor"))
            XCTAssertNil(file.mediaPlayer)
            XCTAssertTrue(file.text.isEmpty)
        }

        func assertGIF(_ file: FileTab, frameCount: Int) async throws {
            let request = try XCTUnwrap(file.gifFramesRequest())
            let frames = try await request()
            XCTAssertEqual(frames.count, frameCount)
            let last = try await frames.read(frameCount - 1)
            XCTAssertEqual(last.image.width, 320)
            XCTAssertEqual(last.seconds, 0.12, accuracy: 0.001)
            let bitmap = NSBitmapImageRep(cgImage: last.image)
            let inside = 27 + (frameCount - 1) * 19 % 236 + 10
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: inside, y: 90)).alphaComponent, 0.9)
            XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 12, y: 90)).alphaComponent, 0.1)
            let playback = try XCTUnwrap(file.gifPlayback)
            let playing = Task { await playback.play(automaticallyPlays: true) { frames } }
            defer { playing.cancel() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            var first: CGImage?
            while !playback.failed {
                if let current = playback.image {
                    if let first, current !== first { return }
                    first = current
                }
                guard ContinuousClock.now < deadline else { throw WorkspaceError.timedOut }
                try await Task.sleep(for: .milliseconds(15))
            }
            XCTFail("Playback failed before presenting successive frames")
        }

        do {
            let prefix = "/tmp/bailey-markdown-"
            let created = try await backend.run(argv: ["mktemp", "-d", prefix + "XXXXXX"],
                                                cwd: nil, env: nil, stdin: nil, timeout: 25)
            let fixture = String(decoding: created.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard created.status == 0, fixture.hasPrefix(prefix),
                  fixture.utf8.count == prefix.utf8.count + 6,
                  fixture.utf8.dropFirst(prefix.utf8.count).allSatisfy({
                      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                  })
            else { throw WorkspaceError.notFound }
            verifiedFixture = fixture
            let directory = fixture + "/Project"
            let path = directory + "/Readme.md"
            let asset = directory + "/asset.svg"
            let sameSVGPath = directory + "/same.svg"
            let rasterPath = directory + "/wide.png"
            let gifPath = directory + "/动画 #100%.gif"
            let renamedGIF = directory + "/改名后 #100%.gif"
            let gifSamples = try ProcessInfo.processInfo.environment["BAILEY_IMAGE_ACCEPTANCE_ROOT"].map { root in
                let images = URL(fileURLWithPath: root).appending(path: "images")
                return (remote: try Data(contentsOf: images.appending(path: "动画-34帧.gif")),
                        mac: try Data(contentsOf: images.appending(path: "动画-局部帧.gif")))
            }
            let tablePath = directory + "/measurements.CSV"
            let htmlPath = directory + "/页面 #100%.html"
            let stylesPath = directory + "/preview.css"
            let htmlSVGPath = directory + "/preview.svg"
            let outside = fixture + "/outside.svg"
            let original = Data("\u{feff}# 测试 🧪\r\n\r\n![Scoped asset](asset.svg)\r\n".utf8)
            let svg = Data("""
                <svg xmlns="http://www.w3.org/2000/svg" width="40" height="20">
                  <defs><symbol id="tile" viewBox="0 0 4 2"><rect width="4" height="2"/></symbol></defs>
                  <use href="#tile" width="100%" height="100%" fill="#1a7f37"/>
                </svg>
                """.utf8)
            let made = try await backend.run(argv: ["mkdir", "--", directory],
                                             cwd: nil, env: nil, stdin: nil, timeout: 20)
            XCTAssertEqual(made.status, 0)
            try await backend.write(path: path, data: original)
            try await backend.write(path: asset, data: svg)
            try await backend.write(path: outside, data: svg)
            let canvas = try XCTUnwrap(CGContext(
                data: nil, width: 5000, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            let pngData = NSMutableData()
            let png = try XCTUnwrap(CGImageDestinationCreateWithData(pngData, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(png, try XCTUnwrap(canvas.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(png))
            let rasterBytes = pngData as Data
            try await backend.write(path: rasterPath, data: rasterBytes)
            let tableBytes = Data("# coding: gbk,样本😀\r\n1,\"多行\r\n数据\"\r\n".utf8)
            try await backend.write(path: tablePath, data: tableBytes)
            let htmlSource = """
                <!doctype html><style>h1 { color: black; }</style><link rel="stylesheet" href="preview.css">
                <h1>Windows 🧪</h1><img src="preview.svg">
                """
            let remoteHTML = Data(htmlSource.utf8)
            let remoteStyle = Data("h1 { color: rgb(1, 50, 90); }".utf8)
            try await backend.write(path: htmlPath, data: remoteHTML)
            try await backend.write(path: stylesPath, data: remoteStyle)
            try await backend.write(path: htmlSVGPath, data: svg)

            let connection = RemoteConnection(user: "", host: host, port: 22,
                                              controlSocket: URL(fileURLWithPath: socket), sshPID: 0)
            guard await connection.check() else { throw RemoteConnectionError.notConnected }
            let channel = SSHWorkspaceBackend(runner: connection)
            let tab = FileTab(path: path, backend: channel, workspaceIdentity: "ssh:\(host)")
            try await tab.waitForText()
            let document = try await MarkdownDocument.parse(tab.text)
            XCTAssertEqual(document.headingOutline.first?.title, "测试 🧪")
            let resource = tab.previewResource(in: directory)
            let table = FileTab(path: tablePath, backend: channel, workspaceIdentity: "ssh:\(host)")
            try await table.waitForText()
            let tableSnapshot = try await table.delimitedSnapshot()
            let tableIndex = try XCTUnwrap(tableSnapshot?.index)
            XCTAssertEqual(table.fileEncoding, .utf8)
            XCTAssertTrue(table.canEditDelimited(try XCTUnwrap(tableSnapshot)))
            XCTAssertEqual(tableIndex.fields(in: tableIndex.records[1]).last?.value(in: table.text as NSString),
                           "多行\r\n数据")
            let rasterURL = try XCTUnwrap(URL(string: "wide.png"))
            let rasterTab = FileTab(path: rasterPath, backend: channel, workspaceIdentity: "ssh:\(host)")
            try await load(rasterTab)
            guard case .image(let raster) = rasterTab.content else { throw CocoaError(.fileReadCorruptFile) }
            XCTAssertEqual(raster.poster.width, 4096)
            let embedded = try await resource.picture(rasterURL)
            XCTAssertEqual(embedded.poster.width, 2048)
            let originalImage = try XCTUnwrap(rasterTab.originalImageRequest())
            let originalRaster = try await originalImage()
            XCTAssertEqual(originalRaster.bounds.size, CGSize(width: 5000, height: 20))
            let renamedRaster = directory + "/wide raster #100%.txt"
            try await channel.rename(from: rasterPath, to: renamedRaster)
            let rasterPrefix = try await channel.readPrefix(path: renamedRaster, maxBytes: 64)
            XCTAssertEqual(rasterPrefix, Data(rasterBytes.prefix(64)))
            let renamedTab = FileTab(path: renamedRaster, backend: channel, workspaceIdentity: "ssh:\(host)")
            try await load(renamedTab)
            guard case .image(let renamedImage) = renamedTab.content else {
                throw CocoaError(.fileReadCorruptFile)
            }
            XCTAssertEqual(renamedImage.pixelSize, raster.pixelSize)
            try await channel.rename(from: renamedRaster, to: rasterPath)
            renamedTab.retireContent()
            let relative = try XCTUnwrap(URL(string: "asset.svg"))
            let picture = try await resource.picture(relative)
            XCTAssertEqual(picture.pointSize?.width, 40)
            let embeddedTile = try XCTUnwrap(NSBitmapImageRep(cgImage: picture.poster).colorAt(x: 20, y: 10))
            XCTAssertGreaterThan(embeddedTile.alphaComponent, 0.98)
            XCTAssertGreaterThan(embeddedTile.greenComponent, embeddedTile.redComponent)
            let standalone = FileTab(path: asset, backend: channel, workspaceIdentity: "ssh:\(host)")
            try await standalone.waitForText()
            XCTAssertTrue(standalone.showsFilePreview)
            let standaloneRevision = standalone.textPreviewRequestID
            let standaloneRaster = try SVGArtwork.render(Data(standalone.text.utf8))
            let green = try XCTUnwrap(NSBitmapImageRep(cgImage: standaloneRaster.image).colorAt(x: 20, y: 10))
            XCTAssertGreaterThan(green.greenComponent, green.redComponent)
            XCTAssertEqual(standaloneRaster.pointSize.width, 40)
            let resolved = try await resource.resolvedFile(relative)
            XCTAssertEqual(resolved, asset)
            do {
                _ = try await resource.read(relative, maxBytes: svg.count - 1)
                XCTFail("A real remote read must enforce its byte budget")
            } catch WorkspaceError.tooLarge {}
            do {
                _ = try await resource.read(try XCTUnwrap(URL(string: "../outside.svg")), maxBytes: 1024)
                XCTFail("A relative resource must not escape the authorized remote project")
            } catch let failure as CocoaError {
                XCTAssertEqual(failure.code, .fileReadNoPermission)
            }
            let stillOnDisk = try await backend.read(path: path, maxBytes: original.count)
            XCTAssertEqual(stillOnDisk, original, "Reading and parsing must preserve remote source bytes")

            guard mkdir(fixture, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { try? FileManager.default.removeItem(atPath: fixture) }
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
            let localTwin = Data("local twin must not be read or overwritten".utf8)
            try localTwin.write(to: URL(fileURLWithPath: path))
            try localTwin.write(to: URL(fileURLWithPath: asset))
            try localTwin.write(to: URL(fileURLWithPath: rasterPath))
            let compressedSVG = try SVGArtworkTests.compressedSVGBytes()
            try await channel.write(path: sameSVGPath, data: compressedSVG)
            try svg.write(to: URL(fileURLWithPath: sameSVGPath))
            let compressedRemoteTab = FileTab(path: sameSVGPath, backend: channel, workspaceIdentity: "ssh:\(host)")
            let uncompressedMacTab = FileTab(path: sameSVGPath, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            try await load(compressedRemoteTab)
            if case .unavailable(let reason) = compressedRemoteTab.content {
                XCTAssertEqual(reason, String(localized: "Compressed SVG is not supported. Open an uncompressed SVG file.",
                                               table: "Workspace"))
            } else {
                XCTFail("The SSH compressed SVG must not show the Mac namesake")
            }
            XCTAssertFalse(compressedRemoteTab.canPreviewFile)
            try await uncompressedMacTab.waitForText()
            XCTAssertTrue(uncompressedMacTab.canPreviewFile)
            XCTAssertEqual(try SVGArtwork.render(Data(uncompressedMacTab.text.utf8)).pointSize.width, 40)
            func rasterBytesForRegion(format: UTType, red: CGFloat, green: CGFloat) throws -> Data {
                canvas.setFillColor(red: red, green: green, blue: 0.07, alpha: 1)
                canvas.fill(CGRect(x: 0, y: 0, width: 5000, height: 20))
                let data = NSMutableData()
                let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
                    data, format.identifier as CFString, 1, nil
                ))
                let options: [CFString: Any]? = format == .tiff
                    ? [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] : nil
                CGImageDestinationAddImage(destination, try XCTUnwrap(canvas.makeImage()), options as CFDictionary?)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
                return data as Data
            }
            func redMinusGreen(_ read: () async throws -> RasterDetail) async throws -> CGFloat {
                let detail = try await read()
                let rect = CGRect(x: 4700, y: 2, width: 32, height: 8)
                let patch = try await detail.render(rect)
                XCTAssertEqual(patch.rect, rect)
                XCTAssertEqual(CGSize(width: patch.image.width, height: patch.image.height), rect.size)
                let bitmap = NSBitmapImageRep(cgImage: patch.image)
                let color = try XCTUnwrap(bitmap.colorAt(x: 3, y: 5)?.usingColorSpace(.sRGB))
                return color.redComponent - color.greenComponent
            }
            var regionalSamples: [(path: String, remoteBytes: Data, localBytes: Data,
                                   remote: FileTab, local: FileTab,
                                   read: () async throws -> RasterDetail, remoteColor: CGFloat)] = []
            defer {
                for sample in regionalSamples { sample.remote.retireContent(); sample.local.retireContent() }
            }
            for (format, suffix) in [(UTType.jpeg, "jpg"), (.png, "png"), (.tiff, "tiff")] {
                let regionalPath = directory + "/regions." + suffix
                let remoteBytes = try rasterBytesForRegion(format: format, red: 0.05, green: 0.9)
                let localBytes = try rasterBytesForRegion(format: format, red: 0.9, green: 0.05)
                try await channel.write(path: regionalPath, data: remoteBytes)
                try localBytes.write(to: URL(fileURLWithPath: regionalPath))
                let remote = FileTab(path: regionalPath, backend: channel, workspaceIdentity: "ssh:\(host)")
                let local = FileTab(path: regionalPath, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
                try await load(remote)
                try await load(local)
                let read = try XCTUnwrap(remote.originalImageRequest())
                let localRead = try XCTUnwrap(local.originalImageRequest())
                let remoteColor = try await redMinusGreen(read)
                let localColor = try await redMinusGreen(localRead)
                XCTAssertLessThan(remoteColor, -0.6, suffix)
                XCTAssertGreaterThan(localColor, 0.6, suffix)
                regionalSamples.append((regionalPath, remoteBytes, localBytes, remote, local, read, remoteColor))
            }
            let remoteGIF: FileTab?
            let gifBeforeDisconnect: (() async throws -> GIFPlayback.Frames)?
            if let gifSamples {
                try await channel.write(path: gifPath, data: gifSamples.remote)
                try gifSamples.mac.write(to: URL(fileURLWithPath: gifPath))
                try gifSamples.mac.write(to: URL(fileURLWithPath: renamedGIF))
                let gif = FileTab(path: gifPath, backend: channel, workspaceIdentity: "ssh:\(host)")
                let mac = FileTab(path: gifPath, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
                try await load(gif)
                try await load(mac)
                try await assertGIF(gif, frameCount: 34)
                try await assertGIF(mac, frameCount: 12)
                let prior = try XCTUnwrap(gif.gifFramesRequest())
                try await channel.rename(from: gifPath, to: renamedGIF)
                gif.updatePath(renamedGIF)
                do {
                    _ = try await prior()
                    XCTFail("A request for the old GIF identity survived rename")
                } catch WorkspaceError.changedExternally {}
                try await assertGIF(gif, frameCount: 34)
                remoteGIF = gif
                gifBeforeDisconnect = try XCTUnwrap(gif.gifFramesRequest())
            } else {
                remoteGIF = nil
                gifBeforeDisconnect = nil
            }
            let localHTML = Data(htmlSource.replacingOccurrences(of: "Windows", with: "Mac").utf8)
            let localStyle = Data("h1 { color: rgb(200, 40, 20); }".utf8)
            let localSVG = Data(String(decoding: svg, as: UTF8.self)
                .replacingOccurrences(of: "width=\"40\"", with: "width=\"17\"").utf8)
            try localHTML.write(to: URL(fileURLWithPath: htmlPath))
            try localStyle.write(to: URL(fileURLWithPath: stylesPath))
            try localSVG.write(to: URL(fileURLWithPath: htmlSVGPath))
            let remotePage = FileTab(path: htmlPath, backend: channel, workspaceIdentity: "ssh:\(host)")
            let localPage = FileTab(path: htmlPath, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
            try await remotePage.waitForText()
            try await localPage.waitForText()
            let remotePresentation = try await renderHTML(remotePage, directory: directory)
            let localPresentation = try await renderHTML(localPage, directory: directory)
            XCTAssertEqual(remotePresentation, ["Windows 🧪", "rgb(1, 50, 90)", "40"])
            XCTAssertEqual(localPresentation, ["Mac 🧪", "rgb(200, 40, 20)", "17"])
            let retainedWebView = try XCTUnwrap(remotePage.htmlPreview?.webView)
            XCTAssertFalse(retainedWebView === localPage.htmlPreview?.webView)

            let features = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: ".github/features")
            let sampleAudio = try Data(contentsOf: features.appending(path: "audio-file-playback/demo-audio.m4a"))
            let sampleVideo = try Data(contentsOf: features.appending(path: "video-file-playback/demo-video.mp4"))
            let tone = URL(fileURLWithPath: directory + "/generated.m4a")
            do {
                let writer = try AVAudioFile(forWriting: tone, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                ])
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: 44_100))
                buffer.frameLength = 44_100
                try XCTUnwrap(buffer.floatChannelData?.pointee).initialize(repeating: 0, count: 44_100)
                try writer.write(from: buffer)
            }
            let mediaFixtures: [(path: String, kind: NativeMedia.Kind, mac: Data, remote: Data)] = try [
                (directory + "/sample.m4a", .audio, Data(contentsOf: tone), sampleAudio),
                (directory + "/sample.mp4", .video, sampleVideo, sampleAudio),
            ]
            for sample in mediaFixtures {
                XCTAssertNotEqual(sample.mac, sample.remote)
                try await backend.write(path: sample.path, data: sample.remote)
                try sample.mac.write(to: URL(fileURLWithPath: sample.path))
                let remoteBytes = try await channel.read(path: sample.path, maxBytes: sample.remote.count)
                XCTAssertEqual(remoteBytes, sample.remote)
                let local = FileTab(path: sample.path, backend: LocalWorkspaceBackend.shared, workspaceIdentity: nil)
                try await load(local)
                guard case .media(let media) = local.content else {
                    XCTFail("The Mac media namesake must be playable")
                    throw CocoaError(.fileReadCorruptFile)
                }
                XCTAssertEqual(media.kind, sample.kind)
                XCTAssertNotNil(local.mediaPlayer?.currentItem)
                try await assertRemoteMediaIsUnavailable(sample.path, on: channel)
                local.retireContent()
            }

            try await stopMaster()
            if let remoteGIF, let gifBeforeDisconnect {
                do {
                    _ = try await gifBeforeDisconnect()
                    XCTFail("A disconnected GIF read must not use the playable Mac namesake")
                } catch RemoteConnectionError.notConnected {}
                remoteGIF.rebindWorkspace(to: nil)
                XCTAssertNil(remoteGIF.gifFramesRequest())
                XCTAssertNil(remoteGIF.gifPlayback?.image)
            }
            for sample in mediaFixtures {
                try await assertRemoteMediaIsUnavailable(sample.path, on: channel)
            }
            do {
                _ = try await resource.read(relative, maxBytes: 1024)
                XCTFail("A real disconnected channel must not read the same path on the Mac")
            } catch RemoteConnectionError.notConnected {}
            do {
                _ = try await originalImage()
                XCTFail("Original-size decoding must not read the local namesake after disconnect")
            } catch RemoteConnectionError.notConnected {}
            for sample in regionalSamples {
                do {
                    _ = try await sample.read()
                    XCTFail("A disconnected regional read must not use Mac pixels: \(sample.path)")
                } catch RemoteConnectionError.notConnected {}
                sample.remote.rebindWorkspace(to: nil)
                XCTAssertNil(sample.remote.originalImageRequest())
            }
            let disconnected = FileTab(path: asset, backend: channel, workspaceIdentity: "ssh:\(host)")
            do {
                try await disconnected.waitForText()
                XCTFail("Opening a remote SVG must not read the local namesake after disconnect")
            } catch {
                guard case .unavailable = disconnected.content else { throw error }
                XCTAssertTrue(disconnected.text.isEmpty)
            }
            XCTAssertEqual(connection.state, .disconnected)
            remotePage.rebindWorkspace(to: nil)
            let disconnectedPresentation = try await renderHTML(remotePage, directory: directory)
            XCTAssertEqual(disconnectedPresentation, ["Windows 🧪", "rgb(0, 0, 0)", "0"])
            XCTAssertTrue(remotePage.htmlPreview?.webView === retainedWebView)
            tab.autoSaveSuspendedForClose = true
            let draft = "\r\nDraft after disconnect"
            tab.nativeTextStorage.replaceCharacters(in: NSRange(location: tab.text.utf16.count, length: 0),
                                                    with: draft)
            await tab.save()
            XCTAssertTrue(tab.isDirty)
            XCTAssertNotNil(tab.saveError)
            XCTAssertTrue(tab.text.hasSuffix(draft))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), localTwin)

            let reopened = try await backend.read(path: path, maxBytes: original.count)
            XCTAssertEqual(reopened, original, "Reconnecting before retry must show the original remote bytes")
            for sample in regionalSamples {
                sample.remote.rebindWorkspace(to: channel)
                let restoredRead = try XCTUnwrap(sample.remote.originalImageRequest())
                let restoredColor = try await redMinusGreen(restoredRead)
                XCTAssertEqual(restoredColor, sample.remoteColor, accuracy: 0.01, sample.path)
                let remoteImageBytes = try await channel.read(path: sample.path, maxBytes: sample.remoteBytes.count)
                XCTAssertEqual(remoteImageBytes, sample.remoteBytes)
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sample.path)), sample.localBytes)
            }
            if let remoteGIF, let gifSamples {
                remoteGIF.rebindWorkspace(to: channel)
                try await assertGIF(remoteGIF, frameCount: 34)
                let disk = try await channel.read(path: renamedGIF, maxBytes: gifSamples.remote.count)
                XCTAssertEqual(disk, gifSamples.remote)
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: gifPath)), gifSamples.mac)
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: renamedGIF)), gifSamples.mac)
                remoteGIF.retireContent()
                XCTAssertNil(remoteGIF.gifPlayback)
            }
            let revisedSVG = Data(String(decoding: svg, as: UTF8.self)
                .replacingOccurrences(of: "width=\"40\"", with: "width=\"52\"").utf8)
            try await backend.write(path: asset, data: revisedSVG)
            let refreshed = try await resource.picture(relative)
            XCTAssertEqual(refreshed.pointSize?.width, 52, "Recovery must render the revised remote image")
            standalone.reloadFromDiskIfClean()
            try await standalone.waitForText()
            XCTAssertNotEqual(standalone.textPreviewRequestID, standaloneRevision)
            XCTAssertEqual(try SVGArtwork.render(Data(standalone.text.utf8)).pointSize.width, 52)
            try await backend.write(path: htmlSVGPath, data: revisedSVG)
            remotePage.rebindWorkspace(to: channel)
            let restoredPresentation = try await renderHTML(remotePage, directory: directory)
            XCTAssertEqual(restoredPresentation, ["Windows 🧪", "rgb(1, 50, 90)", "52"])
            XCTAssertTrue(remotePage.htmlPreview?.webView === retainedWebView)
            let retainedHTML = try await backend.read(path: htmlPath, maxBytes: remoteHTML.count)
            let retainedStyle = try await backend.read(path: stylesPath, maxBytes: remoteStyle.count)
            XCTAssertEqual(retainedHTML, remoteHTML)
            XCTAssertEqual(retainedStyle, remoteStyle)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: htmlPath)), localHTML)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: stylesPath)), localStyle)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: htmlSVGPath)), localSVG)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: asset)), localTwin)
            await tab.save()
            XCTAssertFalse(tab.isDirty)
            XCTAssertNil(tab.saveError)
            let updated = try await backend.read(path: path, maxBytes: original.count + draft.utf8.count)
            XCTAssertEqual(updated, original + Data(draft.utf8), "Retry saves only the remote BOM/CRLF Markdown")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), localTwin)
            let unchangedRaster = try await backend.read(path: rasterPath, maxBytes: rasterBytes.count)
            XCTAssertEqual(unchangedRaster, rasterBytes)
            let unchangedTable = try await backend.read(path: tablePath, maxBytes: tableBytes.count)
            XCTAssertEqual(unchangedTable, tableBytes)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: rasterPath)), localTwin)
            let retainedCompressedSVG = try await backend.read(path: sameSVGPath, maxBytes: compressedSVG.count)
            XCTAssertEqual(retainedCompressedSVG, compressedSVG)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sameSVGPath)), svg)
            for sample in mediaFixtures {
                let remoteBytes = try await backend.read(path: sample.path, maxBytes: sample.remote.count)
                XCTAssertEqual(remoteBytes, sample.remote)
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sample.path)), sample.mac)
                try await assertRemoteMediaIsUnavailable(sample.path, on: channel)
            }
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    func testFinderMarkdownOutsideCurrentProjectCanReadOwnAssetsAndLinksOnlyInsideItsFolder() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let projectRoot = temporary.appending(path: "Workspace")
        let importedFolder = temporary.appending(path: "External")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: importedFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let document = importedFolder.appending(path: "Readme.md")
        let linked = importedFolder.appending(path: "Guide.md")
        let asset = importedFolder.appending(path: "asset.txt")
        let outside = temporary.appending(path: "secret.md")
        try Data("# Readme".utf8).write(to: document)
        try Data("# Guide".utf8).write(to: linked)
        try Data("safe resource".utf8).write(to: asset)
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: importedFolder.appending(path: "escaped.md"), withDestinationURL: outside
        )

        let project = Project(customDirectory: projectRoot.path, layout: .init())
        project.openLocalFile(document.path)
        guard case .file(let source)? = project.focusedContent else {
            return XCTFail("Finder must deliver one local Markdown file tab")
        }
        try await source.waitForText()
        let resource = source.previewResource(in: project.customDirectory)
        let bytes = try await resource.read(try XCTUnwrap(URL(string: "asset.txt")), maxBytes: 128)
        XCTAssertEqual(bytes, Data("safe resource".utf8))
        let opened = await project.openMarkdownLink(try XCTUnwrap(URL(string: "Guide.md")), from: source) { true }
        XCTAssertTrue(opened)
        XCTAssertEqual(project.tabs.count, 2)
        guard case .file(let target)? = project.focusedContent else {
            return XCTFail("Opening a sibling link should reuse native FileTab")
        }
        try await target.waitForText()
        XCTAssertEqual(target.path, linked.path)
        XCTAssertNil(target.workspaceIdentity)
        let escaped = await project.openMarkdownLink(try XCTUnwrap(URL(string: "../secret.md")), from: source) { true }
        XCTAssertFalse(escaped)
        let symlinkEscape = await project.openMarkdownLink(
            try XCTUnwrap(URL(string: "escaped.md")), from: source
        ) { true }
        XCTAssertFalse(symlinkEscape)
        XCTAssertEqual(project.tabs.count, 2)
    }

    func testFinderFileInSSHProjectCannotBorrowTheRemoteRootByTextualPathCoincidence() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let docs = temporary.appending(path: "docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let document = docs.appending(path: "Readme.md")
        try Data("# Finder file".utf8).write(to: document)
        try Data("private".utf8).write(to: temporary.appending(path: "secret.md"))
        try Data("# Guide".utf8).write(to: docs.appending(path: "Guide.md"))

        let project = Project(customDirectory: temporary.path, sshHost: "unreachable-ssh-fixture", layout: .init())
        // Remote and local paths are strings, so they can coincide without
        // representing files on the same machine.
        project.openLocalFile(document.path)
        guard case .file(let source)? = project.focusedContent else {
            return XCTFail("Finder file must remain local even in an SSH project")
        }
        try await source.waitForText()
        XCTAssertNil(source.workspaceIdentity)
        XCTAssertNotNil(project.workspaceIdentity)

        let escaped = await project.openMarkdownLink(try XCTUnwrap(URL(string: "../secret.md")), from: source) { true }
        XCTAssertFalse(escaped, "The unrelated SSH project root must not authorize reading local parent files")
        XCTAssertEqual(project.tabs.count, 1)

        let sibling = await project.openMarkdownLink(try XCTUnwrap(URL(string: "Guide.md")), from: source) { true }
        XCTAssertTrue(sibling, "An explicitly Finder-opened local file should still open local sibling links")
        guard case .file(let target)? = project.focusedContent else {
            return XCTFail("Expected a local native file tab")
        }
        XCTAssertNil(target.workspaceIdentity)
    }

    func testAsyncMarkdownLinkCannotOpenOldTargetAfterSourceEdit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bailey-link-revision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let document = root.appendingPathComponent("Index.md")
        let target = root.appendingPathComponent("Guide.md")
        let original = Data("# Index\n\n[Open Guide](Guide.md)\n".utf8)
        try original.write(to: document)
        try Data("# Guide\n".utf8).write(to: target)

        let project = Project(customDirectory: root.path, layout: .init())
        project.openFile(document.path)
        guard case .file(let source)? = project.focusedContent else {
            return XCTFail("Project must open the native Markdown source")
        }
        try await source.waitForText()
        source.autoSaveSuspendedForClose = true
        let previousRequest = source.textPreviewRequestID
        var identityChecks = 0

        let opened = await project.openMarkdownLink(try XCTUnwrap(URL(string: "Guide.md")),
                                                    from: source) {
            identityChecks += 1
            if identityChecks == 2 {
                source.nativeTextStorage.replaceCharacters(
                    in: NSRange(location: source.text.utf16.count, length: 0),
                    with: "\nNew unsaved edit"
                )
            }
            return true
        }
        XCTAssertEqual(identityChecks, 2, "The link must recheck its source after authorization")
        XCTAssertNotEqual(source.textPreviewRequestID, previousRequest)
        XCTAssertFalse(opened, "An old link must not open after its source content changes")
        XCTAssertEqual(project.tabs.count, 1, "A stale async result cannot create a destination tab")
        XCTAssertTrue(source.isDirty)
        XCTAssertEqual(try Data(contentsOf: document), original)
    }

    func testMarkdownInsideProjectKeepsCrossFolderRelativeResources() async throws {
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let docs = temporary.appending(path: "docs")
        let assets = temporary.appending(path: "assets")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let document = docs.appending(path: "Readme.md")
        try Data("# Readme".utf8).write(to: document)
        try Data("safe".utf8).write(to: assets.appending(path: "image.dat"))
        let project = Project(customDirectory: temporary.path, layout: .init())
        project.openFile(document.path)
        guard case .file(let source)? = project.focusedContent else {
            return XCTFail("Project file must be a native FileTab")
        }
        try await source.waitForText()
        let bytes = try await source.previewResource(in: project.customDirectory)
            .read(try XCTUnwrap(URL(string: "../assets/image.dat")), maxBytes: 128)
        XCTAssertEqual(bytes, Data("safe".utf8))
    }
}
