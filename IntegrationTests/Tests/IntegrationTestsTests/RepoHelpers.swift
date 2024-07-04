import Automerge
import AutomergeRepo
import AutomergeUtilities
import Foundation

public enum RepoHelpers {
    static func documentWithData() throws -> Document {
        let newDoc = Document()
        let txt = try newDoc.putObject(obj: .ROOT, key: "words", ty: .Text)
        try newDoc.updateText(obj: txt, value: "Hello World!")
        return newDoc
    }

    static func docHandleWithData() throws -> DocHandle {
        let newDoc = Document()
        let txt = try newDoc.putObject(obj: .ROOT, key: "words", ty: .Text)
        try newDoc.updateText(obj: txt, value: "Hello World!")
        return DocHandle(id: DocumentId(), doc: newDoc)
    }
}
