import Foundation
import Testing
@testable import PostfrauCore

@Suite("Sidebar row positions")
struct SidebarRowsTests {
    @Test func countsOnlyRowsInsideOpenContainers() {
        let deep = RequestItem(name: "deep")
        let inner = Folder(name: "inner", items: [.request(deep)])
        let outer = Folder(name: "outer", items: [.request(RequestItem(name: "a")), .folder(inner)])
        let first = RequestCollection(name: "one", items: [.folder(outer), .request(RequestItem(name: "b"))])
        let second = RequestCollection(name: "two", items: [.request(RequestItem(name: "c"))])

        // Everything open: one, outer, a, inner, deep, b, two, c.
        let all = SidebarRows.position(of: deep.id, in: [first, second]) { _ in true }
        #expect(all?.row == 4)
        #expect(all?.total == 8)

        // `inner` closed: deep has no row; `outer` closed hides a and inner.
        #expect(SidebarRows.position(of: deep.id, in: [first, second]) { $0 != inner.id } == nil)
        let closed = SidebarRows.position(of: second.id, in: [first, second]) { $0 != outer.id }
        #expect(closed?.row == 3)
        #expect(closed?.total == 5)
    }
}
