import AppKit
import CoreText
import Foundation
import os
import SwiftUI

enum RetroFont {
    static let postScriptName = "PxPlus_IBM_VGA_8x16"
    static let designSize: CGFloat = 16

    private static let logger = Logger(subsystem: "com.songer522.DOSCrate", category: "RetroFont")
    private static let loggedFailure = OSAllocatedUnfairLock(initialState: false)

    static var bundledURL: URL? {
        Bundle.main.url(forResource: "PxPlus_IBM_VGA_8x16", withExtension: "ttf")
    }

    @discardableResult
    static func register(url: URL? = bundledURL) -> Bool {
        guard let url else {
            logOnce("Bundled font PxPlus_IBM_VGA_8x16.ttf not found in bundle resources.")
            return false
        }
        var cfError: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &cfError) {
            return true
        }
        let error = cfError?.takeRetainedValue() as Error? as NSError?
        if let error,
           error.domain == kCTFontManagerErrorDomain as String,
           error.code == CTFontManagerError.alreadyRegistered.rawValue {
            return true
        }
        let message = error?.localizedDescription ?? "unknown error"
        logOnce("Failed to register font at \(url.path): \(message)")
        return false
    }

    static func font(scale: Int = 1) -> Font {
        let size = designSize * CGFloat(max(scale, 1))
        if NSFont(name: postScriptName, size: size) != nil {
            return .custom(postScriptName, fixedSize: size)
        }
        return .system(size: size, design: .monospaced)
    }

    private static func logOnce(_ message: String) {
        let shouldLog = loggedFailure.withLock { logged -> Bool in
            guard !logged else { return false }
            logged = true
            return true
        }
        if shouldLog {
            logger.error("\(message, privacy: .public)")
        }
    }
}
