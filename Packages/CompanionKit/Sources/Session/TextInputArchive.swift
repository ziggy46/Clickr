import Foundation

/// The NSKeyedArchiver-format payloads ("RTI" remote text input) that `_tiStart` returns and
/// `_tiC` carries. Built by hand with the same object layout pyatv uses.
enum TextInputArchive {
    struct Session: Equatable {
        /// The text session's UUID bytes.
        let id: Data
        /// Text already in the TV's field (before the cursor).
        let currentText: String
    }

    /// Reads the session from a `_tiStart` reply or `_tiStarted` event (`_tiD`). Returns nil
    /// when there's no session UUID, which means no text field has focus.
    static func session(from archive: Data) throws -> Session? {
        let plist = try BinaryPlist.decode(archive)
        guard case .data(let id) = resolve(plist, path: ["sessionUUID"]) else { return nil }
        var text = ""
        if case .string(let current) = resolve(plist, path: ["documentState", "docSt", "contextBeforeInput"]) {
            text = current
        }
        return Session(id: id, currentText: text)
    }

    /// Text operations that type `text` at the cursor.
    static func insert(_ text: String, session: Data) -> Data {
        archive(objects: [
            .string("$null"),
            .dict(["keyboardOutput": .uid(2), "$class": .uid(7), "targetSessionUUID": .uid(5)]),
            .dict(["insertionText": .uid(3), "$class": .uid(4)]),
            .string(text),
            classInfo("TIKeyboardOutput"),
            .dict(["NS.uuidbytes": .data(session), "$class": .uid(6)]),
            classInfo("NSUUID"),
            classInfo("RTITextOperations"),
        ])
    }

    /// Text operations that empty the field.
    static func clear(session: Data) -> Data {
        archive(objects: [
            .string("$null"),
            .dict(["$class": .uid(7), "targetSessionUUID": .uid(5), "keyboardOutput": .uid(2), "textToAssert": .uid(4)]),
            .dict(["$class": .uid(3)]),
            classInfo("TIKeyboardOutput"),
            .string(""),
            .dict(["NS.uuidbytes": .data(session), "$class": .uid(6)]),
            classInfo("NSUUID"),
            classInfo("RTITextOperations"),
        ])
    }

    private static func archive(objects: [PlistValue]) -> Data {
        BinaryPlist.encode(.dict([
            "$version": .int(100_000),
            "$archiver": .string("RTIKeyedArchiver"),
            "$top": .dict(["textOperations": .uid(1)]),
            "$objects": .array(objects),
        ]))
    }

    private static func classInfo(_ name: String) -> PlistValue {
        .dict(["$classname": .string(name), "$classes": .array([.string(name), .string("NSObject")])])
    }

    /// Follows a key path from `$top`, looking up UIDs in `$objects` along the way (what
    /// pyatv's read_archive_properties does).
    static func resolve(_ archive: PlistValue, path: [String]) -> PlistValue? {
        guard case .array(let objects)? = archive["$objects"], var element = archive["$top"] else { return nil }
        for key in path {
            guard let next = element[key] else { return nil }
            element = next
            if case .uid(let index) = element {
                guard objects.indices.contains(index) else { return nil }
                element = objects[index]
            }
        }
        return element
    }
}
